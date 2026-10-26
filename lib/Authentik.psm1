#requires -version 5.1
# authentik integration: health and first-setup detection, a small API client (/api/v3, token auth) and idempotent
# "sync" functions for the Google OAuth source, the embedded outpost and per-application ForwardAuth protection.
#
# Division of responsibility: the manager sets authentik up once (Google source, owner-only enrollment, the
# "DTC owners" group) and connects applications to it (proxy provider, application, outpost, Traefik ForwardAuth).
# Who may sign in and open what is authentik's: users, groups, invitations, flows and access rules are created at most
# once as safe defaults and never changed by the manager afterwards, so edits made in authentik always stand.
#
# Every sync function has a dry-run mode (-WhatIf) that returns the actions it would take without changing anything;
# the web UI shows that as the preview and applies the same function without -WhatIf after approval. Objects this
# manager creates carry the "dm-" prefix (slugs/names), so they are found again and never duplicated.

Import-Module (Join-Path $PSScriptRoot 'RoutingModel.psm1')
#
# Endpoints and fields were verified against the OpenAPI schema of authentik 2026.8.5 (/api/v3/schema/).
Set-StrictMode -Version 2.0

$script:Prefix = 'dm-'
# Flows an installation creates on first start (blueprints); configuration waits until they exist.
$script:RequiredFlows = @('default-authentication-flow', 'default-source-authentication', 'default-source-enrollment',
  'default-provider-authorization-implicit-consent', 'default-provider-invalidation-flow')
$script:EmailPattern = '^[A-Za-z0-9._%+-]{1,64}@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
$script:DomainPattern = '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
$script:SlugPattern = '^[a-z0-9][a-z0-9_-]{0,48}$'
$script:GoogleClientIdPattern = '^[0-9]{6,20}-[a-z0-9]{8,64}\.apps\.googleusercontent\.com$'
$script:GoogleSecretPattern = '^[A-Za-z0-9_-]{16,128}$'

function Get-AkProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# --- HTTP -------------------------------------------------------------------------------------------------------------

# One HTTP request without following redirects. Returns Status, Body, Location and Error; never throws for HTTP errors.
function Invoke-AkHttp {
  param([Parameter(Mandatory = $true)][string]$Url, [string]$Method = 'GET', [string]$Token, $Body, [hashtable]$Headers = @{}, [int]$TimeoutMs = 15000)
  $res = [pscustomobject]@{ Status = 0; Body = ''; Location = ''; Error = ''; ContentType = '' }
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method; $req.AllowAutoRedirect = $false; $req.Proxy = $null; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
    $req.Accept = 'application/json'
    if ($Token) { $req.Headers.Add('Authorization', "Bearer $Token") }
    foreach ($k in $Headers.Keys) { if ($k -ieq 'Host') { $req.Host = [string]$Headers[$k] } else { $req.Headers.Add($k, [string]$Headers[$k]) } }
    if ($null -ne $Body) {
      $json = $(if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 12 -Compress })
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      $req.ContentType = 'application/json'; $req.ContentLength = $bytes.Length
      $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    }
    try { $r = $req.GetResponse() } catch [Net.WebException] { if ($_.Exception.Response) { $r = $_.Exception.Response } else { throw } }
    $res.Status = [int]$r.StatusCode
    $res.Location = [string]$r.Headers['Location']
    $res.ContentType = [string]$r.ContentType
    $sr = New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8)
    $res.Body = $sr.ReadToEnd(); $sr.Close(); $r.Close()
  } catch { $res.Error = $_.Exception.Message -replace 'Bearer\s+\S+', 'Bearer <redacted>' }
  return $res
}

# --- Health and first setup (no token) ----------------------------------------------------------------------------------

# live/ready (docs: /-/health/live/ = process up, /-/health/ready/ = database reachable) and the first-setup state from
# GET /setup (authentik 2026.x): a redirect to /if/flow/initial-setup/ means nobody has claimed the instance yet, a
# redirect to / means it is set up, 503 means the worker has not created the setup flow yet (still starting).
function Get-AuthentikHealth {
  param([Parameter(Mandatory = $true)][string]$BaseUrl)
  $b = $BaseUrl.TrimEnd('/')
  $live = Invoke-AkHttp -Url "$b/-/health/live/" -TimeoutMs 5000
  $ready = $null; $setup = 'unknown'
  if ($live.Status -eq 200) {
    $ready = Invoke-AkHttp -Url "$b/-/health/ready/" -TimeoutMs 5000
    $s = Invoke-AkHttp -Url "$b/setup" -TimeoutMs 8000
    if ($s.Status -in 301, 302) { $setup = $(if ($s.Location -match '/if/flow/initial-setup/') { 'pending' } else { 'done' }) }
    elseif ($s.Status -eq 503) { $setup = 'starting' }
  }
  return [pscustomobject]@{
    Live = ($live.Status -eq 200); Ready = [bool]($ready -and $ready.Status -eq 200); Setup = $setup
    Message = $(if ($live.Status -ne 200) { "authentik does not answer at $b ($(if ($live.Error) { $live.Error } else { "HTTP $($live.Status)" }))." } elseif (-not ($ready -and $ready.Status -eq 200)) { 'authentik runs but is not ready (database not reachable yet).' } else { '' })
  }
}

# --- API client ----------------------------------------------------------------------------------------------------------

function New-AuthentikConnection {
  param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Token)
  return [pscustomobject]@{ BaseUrl = $BaseUrl.TrimEnd('/'); Token = $Token; Calls = (New-Object System.Collections.ArrayList) }
}

# Calls /api/v3$Path. Returns the parsed JSON (or $null for 204). Throws a readable error that never contains the token
# or request body (which may hold the Google client secret).
function Invoke-AuthentikApi {
  param([Parameter(Mandatory = $true)]$Conn, [string]$Method = 'GET', [Parameter(Mandatory = $true)][string]$Path, $Body)
  $r = Invoke-AkHttp -Url "$($Conn.BaseUrl)/api/v3$Path" -Method $Method -Token $Conn.Token -Body $Body
  $null = $Conn.Calls.Add("$Method $Path $($r.Status)")
  if ($r.Status -ge 200 -and $r.Status -lt 300) { if ($r.Body) { return ($r.Body | ConvertFrom-Json) }; return $null }
  $detail = ''
  try {
    $j = $r.Body | ConvertFrom-Json
    $detail = (@($j.PSObject.Properties | ForEach-Object { "$($_.Name): $(@($_.Value) -join ' ')" }) -join '; ')
  } catch { $detail = [string]$r.Body; if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) } }
  if ($r.Status -eq 0) { $detail = $r.Error }
  $err = New-Object System.Exception ("authentik API $Method $($Path -replace '\?.*$', ''): HTTP $($r.Status) $detail".Trim())
  $err.Data['Status'] = $r.Status
  throw $err
}

# Every item of a paginated list (page_size 100).
function Get-AuthentikList {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$Path)
  $sep = $(if ($Path.Contains('?')) { '&' } else { '?' })
  $page = 1; $items = New-Object System.Collections.ArrayList
  do {
    $d = Invoke-AuthentikApi $Conn GET "$Path${sep}page_size=100&page=$page"
    foreach ($x in @($d.results)) { $null = $items.Add($x) }
    $next = [int](Get-AkProp $d.pagination 'next' 0)
    $page = $next
  } while ($next -gt 0 -and $page -lt 50)
  return $items.ToArray()
}

# Checks a token: who it belongs to and whether it can administer authentik. The token itself is never returned.
function Test-AuthentikToken {
  param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Token)
  $conn = New-AuthentikConnection -BaseUrl $BaseUrl -Token $Token
  try {
    $me = Invoke-AuthentikApi $conn GET '/core/users/me/'
    $v = Invoke-AuthentikApi $conn GET '/admin/version/'
    $u = $me.user
    return [pscustomobject]@{ Ok = $true; Username = [string]$u.username; IsSuperuser = [bool]$u.is_superuser; Version = [string]$v.version_current; Message = '' }
  } catch {
    $status = $_.Exception.Data['Status']
    $msg = $(if ($status -in 401, 403) { 'authentik rejected this token (wrong, expired or without API access). Create an API token in authentik: Directory > Tokens and App passwords > Create, intent "API Token".' } else { $_.Exception.Message })
    return [pscustomobject]@{ Ok = $false; Username = ''; IsSuperuser = $false; Version = ''; Message = $msg }
  }
}

# API areas the Deployment Manager reads and changes; a token must be able to list each of them.
$script:RequiredApi = [ordered]@{
  'flows' = '/flows/instances/?page_size=1'; 'stages' = '/stages/identification/?page_size=1'; 'sources' = '/sources/oauth/?page_size=1'
  'providers' = '/providers/proxy/?page_size=1'; 'applications' = '/core/applications/?page_size=1'; 'policies' = '/policies/expression/?page_size=1'
  'policy bindings' = '/policies/bindings/?page_size=1'; 'groups' = '/core/groups/?page_size=1'; 'outposts' = '/outposts/instances/?page_size=1'; 'events' = '/events/events/?page_size=1'
}

# Credential validator for CredentialManager.psm1: is this token usable by the Deployment Manager on this authentik?
# Status: valid | rejected (wrong, expired or deleted) | insufficient (works, but not for an administrator or
# missing API access) | unreachable (authentik does not answer: says nothing about the token). Also returns the
# account, the server version and, when authentik lists it, the token's expiry date. The token is never returned.
function Test-AuthentikCredential {
  param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Token)
  $base = $BaseUrl.TrimEnd('/')
  $out = [ordered]@{ Ok = $false; Status = 'rejected'; Message = ''; Account = ''; Server = $base; Version = ''; ExpiresAt = ''; Details = $null }
  if ($Token -notmatch '^[A-Za-z0-9._-]{20,256}$') { $out.Message = 'That does not look like an authentik API token (letters, digits, . _ - only, at least 20 characters).'; return $out }
  $live = Invoke-AkHttp -Url "$base/-/health/live/" -TimeoutMs 5000
  if ($live.Status -ne 200) { $out.Status = 'unreachable'; $out.Message = "authentik does not answer at $base$(if ($live.Error) { " ($($live.Error))" } else { " (HTTP $($live.Status))" }); the token was not checked."; return $out }
  $conn = New-AuthentikConnection -BaseUrl $base -Token $Token
  $me = $null
  try { $me = Invoke-AuthentikApi $conn GET '/core/users/me/' }
  catch {
    $st = $_.Exception.Data['Status']
    if ($st -in 401, 403) { $out.Message = 'authentik rejected this token: it is wrong, has expired or was deleted (revoked). Create a new API token in authentik (Directory > Tokens and App passwords) for akadmin or another administrator.' }
    else { $out.Status = 'unreachable'; $out.Message = "authentik could not check the token: $($_.Exception.Message)" }
    return $out
  }
  $u = $me.user
  $out.Account = [string]$u.username
  $type = [string](Get-AkProp $u 'type' '')
  try { $out.Version = [string](Invoke-AuthentikApi $conn GET '/admin/version/').version_current } catch { }
  if ($type -eq 'internal_service_account' -and $out.Account -like 'ak-outpost-*') {
    $out.Status = 'insufficient'
    $out.Message = "This is the token of authentik's own outpost (user $($out.Account)). It only lets the outpost read its configuration and must stay with the outpost. Create an API token for akadmin (or another administrator) and use that instead; the outpost token is not changed."
    return $out
  }
  if (-not [bool](Get-AkProp $u 'is_superuser' $false)) {
    $out.Status = 'insufficient'
    $out.Message = "The token belongs to '$($out.Account)', who is not an authentik administrator. The manager creates sources, applications, providers and policies, which needs an administrator's API token."
    return $out
  }
  $missing = @()
  foreach ($k in $script:RequiredApi.Keys) { try { $null = Invoke-AuthentikApi $conn GET $script:RequiredApi[$k] } catch { if ($_.Exception.Data['Status'] -in 401, 403) { $missing += $k } } }
  if ($missing.Count) { $out.Status = 'insufficient'; $out.Message = "The token cannot read: $($missing -join ', '). Use an administrator's API token without restrictions."; return $out }
  # Expiry: find this token among the account's API tokens (keys are compared here, in memory, and never returned).
  try {
    foreach ($t in @(Get-AuthentikList $conn "/core/tokens/?user__username=$([Uri]::EscapeDataString($out.Account))&intent=api")) {
      $k = $null; try { $k = [string](Invoke-AuthentikApi $conn GET "/core/tokens/$([Uri]::EscapeDataString([string]$t.identifier))/view_key/").key } catch { }
      if ($k -and $k -ceq $Token) {
        $out.Details = [ordered]@{ identifier = [string]$t.identifier; description = [string](Get-AkProp $t 'description' ''); expiring = [bool](Get-AkProp $t 'expiring' $false) }
        if ([bool](Get-AkProp $t 'expiring' $false) -and (Get-AkProp $t 'expires' $null)) { $out.ExpiresAt = [string]$t.expires }
        break
      }
      $k = $null
    }
  } catch { }
  $out.Ok = $true; $out.Status = 'valid'
  $out.Message = "Connected as $($out.Account) (administrator) to authentik $($out.Version)$(if ($out.Details) { ", token '$($out.Details.identifier)'" })."
  return $out
}

# Read-only snapshot of everything the integration depends on.
function Get-AuthentikOverview {
  param([Parameter(Mandatory = $true)]$Conn)
  $flows = @{}
  foreach ($f in @(Get-AuthentikList $Conn '/flows/instances/')) { $flows[[string]$f.slug] = [pscustomobject]@{ Pk = [string]$f.pk; Pbm = [string]$f.policybindingmodel_ptr_id; Designation = [string]$f.designation } }
  $outposts = @(Get-AuthentikList $Conn '/outposts/instances/')
  $embedded = @($outposts | Where-Object { [string](Get-AkProp $_ 'managed' '') -eq 'goauthentik.io/outposts/embedded' })[0]
  $settings = $null; try { $settings = Invoke-AuthentikApi $Conn GET '/admin/settings/' } catch { }
  $sources = @(Get-AuthentikList $Conn '/sources/oauth/')
  $me = Invoke-AuthentikApi $Conn GET '/core/users/me/'
  $version = Invoke-AuthentikApi $Conn GET '/admin/version/'
  $ident = Get-AuthentikLoginStage $Conn $flows
  return [pscustomobject]@{
    Version = [string]$version.version_current
    User = [pscustomobject]@{ Username = [string]$me.user.username; IsSuperuser = [bool]$me.user.is_superuser }
    Flows = $flows
    MissingFlows = @($script:RequiredFlows | Where-Object { -not $flows.ContainsKey($_) })
    Outpost = $(if ($embedded) { [pscustomobject]@{ Pk = [string]$embedded.pk; Name = [string]$embedded.name; Providers = @($embedded.providers | ForEach-Object { [int]$_ }); AuthentikHost = [string](Get-AkProp $embedded.config 'authentik_host' ''); Config = $embedded.config } } else { $null })
    Settings = [pscustomobject]@{ ChangeEmail = [bool](Get-AkProp $settings 'default_user_change_email' $true); ChangeUsername = [bool](Get-AkProp $settings 'default_user_change_username' $true); DefaultAppAccess = [bool](Get-AkProp (Get-AkProp $settings 'flags' $null) 'core_default_app_access' $true) }
    OAuthSources = @($sources | ForEach-Object { ConvertTo-AuthentikSourceView $_ })
    LoginStage = $ident
  }
}

# The identification stage of the default authentication flow (where social login buttons appear).
function Get-AuthentikLoginStage($Conn, $Flows) {
  if (-not $Flows.ContainsKey('default-authentication-flow')) { return $null }
  $bindings = @(Get-AuthentikList $Conn "/flows/bindings/?target=$($Flows['default-authentication-flow'].Pk)&ordering=order")
  foreach ($b in $bindings) {
    if ([string](Get-AkProp $b.stage_obj 'component' '') -eq 'ak-stage-identification-form') {
      $st = Invoke-AuthentikApi $Conn GET "/stages/identification/$($b.stage)/"
      return [pscustomobject]@{ Pk = [string]$st.pk; Name = [string]$st.name; Sources = @($st.sources | ForEach-Object { [string]$_ }) }
    }
  }
  return $null
}

function ConvertTo-AuthentikSourceView($S) {
  return [pscustomobject]@{
    Pk = [string]$S.pk; Name = [string]$S.name; Slug = [string]$S.slug; Enabled = [bool]$S.enabled; Promoted = [bool](Get-AkProp $S 'promoted' $false)
    ProviderType = [string]$S.provider_type; ConsumerKey = [string](Get-AkProp $S 'consumer_key' ''); UserMatchingMode = [string](Get-AkProp $S 'user_matching_mode' '')
    AuthenticationFlow = [string](Get-AkProp $S 'authentication_flow' ''); EnrollmentFlow = [string](Get-AkProp $S 'enrollment_flow' ''); CallbackUrl = [string](Get-AkProp $S 'callback_url' '')
    Managed = ([string]$S.slug).StartsWith($script:Prefix) -or [string]$S.name -match '\(Deployment Manager\)$'
  }
}

# --- Values ---------------------------------------------------------------------------------------------------------------

# The Google values for a public authentik URL and a source slug (shown in the wizard with copy buttons).
function Get-GoogleOAuthSettings {
  param([Parameter(Mandatory = $true)][string]$PublicUrl, [string]$Slug = 'google', [string]$Domain = '', [string]$AppName = '')
  $base = $PublicUrl.TrimEnd('/')
  $u = [Uri]$base
  # One name for the Google app and its client, ASCII only (Google rejects some punctuation and the word "Google").
  if (-not $AppName) { $AppName = "$(if ($Domain) { $Domain } else { $u.Host }) Sign-in" }
  $AppName = ($AppName -replace '[^A-Za-z0-9 ._-]', '-').Trim()
  $parts = $u.Host.Split('.')
  $authorized = $(if ($parts.Count -ge 2) { ($parts[($parts.Count - 2)..($parts.Count - 1)]) -join '.' } else { $u.Host })
  return [pscustomobject]@{
    AppName = $AppName; ClientType = 'Web application'; ClientName = $AppName; Slug = $Slug
    PublicUrl = $base; RedirectUri = "$base/source/oauth/callback/$Slug/"; JavascriptOrigins = @()
    AuthorizedDomain = $authorized
    Scopes = @('openid', 'https://www.googleapis.com/auth/userinfo.email', 'https://www.googleapis.com/auth/userinfo.profile')
    ScopeNames = @('openid', 'email', 'profile')
    ConsoleUrls = [ordered]@{
      projects = 'https://console.cloud.google.com/projectcreate'; overview = 'https://console.cloud.google.com/auth/overview'; branding = 'https://console.cloud.google.com/auth/branding'
      audience = 'https://console.cloud.google.com/auth/audience'; dataAccess = 'https://console.cloud.google.com/auth/scopes'; clients = 'https://console.cloud.google.com/auth/clients'
    }
  }
}

# Google's downloaded OAuth client file ("Download JSON"): {"web": {"client_id", "client_secret", "redirect_uris", "auth_uri",
# "token_uri", ...}}. Returns ClientId/ClientSecret (server side only), ProjectId, RedirectUris and Errors/Warnings with
# instructions. Never throws with the secret in the message.
function ConvertFrom-GoogleClientJson {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json, [string]$ExpectedRedirectUri = '')
  $out = [pscustomobject][ordered]@{ Ok = $false; ClientId = ''; ClientSecret = ''; ProjectId = ''; RedirectUris = @(); Errors = @(); Warnings = @() }
  if ($Json.Length -gt 20000) { $out.Errors = @('That file is too large to be a Google OAuth client file.'); return $out }
  $doc = $null
  try { $doc = $Json | ConvertFrom-Json } catch { $out.Errors = @('That is not a valid JSON file. Download it again from Google Cloud (Clients > your client > Download JSON).'); return $out }
  if ($null -eq $doc -or -not ($doc -is [pscustomobject])) { $out.Errors = @('That is not a Google OAuth client file.'); return $out }
  if ($doc.PSObject.Properties['installed']) { $out.Errors = @('This client is of type "Desktop app" (or another installed-app type). Create a client of type "Web application" instead.'); return $out }
  $w = $doc.PSObject.Properties['web']
  if (-not $w -or -not ($w.Value -is [pscustomobject])) { $out.Errors = @('The file has no "web" section: it is not the OAuth client file of a "Web application" client. In Google Cloud open Clients, choose your Web application client and use Download JSON.'); return $out }
  $web = $w.Value
  $get = { param($n) if ($web.PSObject.Properties[$n] -and $null -ne $web.$n) { $web.$n } else { $null } }
  $errors = @(); $warnings = @()
  $id = ([string](& $get 'client_id')).Trim(); $secret = ([string](& $get 'client_secret')).Trim()
  if (-not $id) { $errors += 'The file contains no client_id.' } elseif (-not (Test-GoogleClientId $id)) { $errors += 'The client_id is not a Google OAuth client ID (it should end in .apps.googleusercontent.com).' }
  if (-not $secret) { $errors += 'The file contains no client_secret. Google shows and downloads the secret only right after the client is created: add a new secret to the client (Clients > your client > Add secret), then download the JSON again.' }
  elseif (-not (Test-GoogleClientSecret $secret)) { $errors += 'The client_secret has an unexpected format.' }
  $auth = [string](& $get 'auth_uri'); $token = [string](& $get 'token_uri')
  if ($auth -and $auth -notin 'https://accounts.google.com/o/oauth2/auth', 'https://accounts.google.com/o/oauth2/v2/auth') { $errors += "auth_uri is '$auth', not Google's sign-in endpoint: this file does not come from Google." }
  if ($token -and $token -notin 'https://oauth2.googleapis.com/token', 'https://accounts.google.com/o/oauth2/token') { $errors += "token_uri is '$token', not Google's token endpoint: this file does not come from Google." }
  $uris = @(@(& $get 'redirect_uris') | ForEach-Object { [string]$_ } | Where-Object { $_ })
  $out.RedirectUris = $uris
  if ($ExpectedRedirectUri) {
    if (-not $uris.Count) { $errors += "The client has no authorized redirect URI. In Google Cloud open Clients > your client > Authorized redirect URIs > Add URI, enter $ExpectedRedirectUri exactly, Save, then download the JSON again." }
    elseif ($uris -cnotcontains $ExpectedRedirectUri) {
      $near = @($uris | Where-Object { $_.TrimEnd('/').ToLowerInvariant() -eq $ExpectedRedirectUri.TrimEnd('/').ToLowerInvariant() })
      $errors += "The client's authorized redirect URIs ($($uris -join ', ')) do not include $ExpectedRedirectUri$(if ($near.Count) { ' exactly (Google compares them character by character, including the trailing slash)' }). In Google Cloud open Clients > your client > Authorized redirect URIs, add $ExpectedRedirectUri, Save, then download the JSON again."
    }
  }
  if (& $get 'javascript_origins') { $warnings += 'JavaScript origins are set; authentik does not need them (harmless).' }
  $out.ClientId = $id; $out.ClientSecret = $secret; $out.ProjectId = [string](& $get 'project_id'); $out.Errors = $errors; $out.Warnings = $warnings; $out.Ok = -not $errors.Count
  return $out
}

function Test-GoogleClientId([string]$Value) { return ([string]$Value).Trim() -match $script:GoogleClientIdPattern }
function Test-GoogleClientSecret([string]$Value) { return ([string]$Value).Trim() -match $script:GoogleSecretPattern }

# The initial owner's Google address (asked once during setup). Returns the normalized address or throws.
function ConvertTo-OwnerEmail([string]$Value) {
  $e = ([string]$Value).Trim().ToLowerInvariant()
  if ($e -notmatch $script:EmailPattern) { throw "'$Value' is not a valid email address." }
  return $e
}

# Expression policy on the Google enrollment flow: only the initial owner's verified Google address may create an
# account. Created once during setup; afterwards it belongs to authentik (edit it there to let others enroll).
# oauth_userinfo is what Google returned (verified_email from the userinfo endpoint, email_verified from OpenID Connect).
function New-OwnerEnrollmentExpression([string]$OwnerEmail) {
  $e = ConvertTo-OwnerEmail $OwnerEmail
  return @(
    '# Created by the Deployment Manager (DTC) during setup: only the initial owner may create an account with Google.',
    '# This policy now belongs to authentik: edit it here, or use invitations, to let other people enroll.',
    "owner_email = `"$e`"",
    'info = request.context.get("oauth_userinfo") or {}',
    'email = str(info.get("email") or "").strip().lower()',
    'verified = info.get("verified_email", info.get("email_verified", False)) in (True, "true", "True")',
    'if not verified:',
    '    ak_message("Your Google address is not verified.")',
    '    return False',
    'if email == owner_email:',
    '    return True',
    'ak_message("This Google account may not create an account here. Ask the administrator for an invitation.")',
    'return False'
  ) -join "`n"
}

# --- Action recording ---------------------------------------------------------------------------------------------------

function New-AkActionList { return ,(New-Object System.Collections.ArrayList) }
function Add-AkAction($List, [string]$Kind, [string]$Object, [string]$Name, [string]$Summary, [string]$Detail = '') {
  $null = $List.Add([pscustomobject]@{ Kind = $Kind; Object = $Object; Name = $Name; Summary = $Summary; Detail = $Detail; Status = $(if ($Kind -eq 'none') { 'Unchanged' } else { 'Planned' }); Message = '' })
}
function Set-AkActionDone($List, [string]$Status = 'Done', [string]$Message = '') { $a = $List[$List.Count - 1]; $a.Status = $Status; $a.Message = $Message }

# Field-by-field differences between an existing object and the desired values (secrets shown as "(changed)").
function Get-AkChanges($Existing, [hashtable]$Desired, [string[]]$SecretFields = @()) {
  $diff = @()
  foreach ($k in $Desired.Keys) {
    if ($SecretFields -contains $k) { $diff += "$k (new value)"; continue }
    $cur = Get-AkProp $Existing $k $null
    $want = $Desired[$k]
    $a = $(if ($cur -is [System.Collections.IEnumerable] -and -not ($cur -is [string])) { (@($cur | ForEach-Object { [string]$_ }) | Sort-Object) -join ',' } else { [string]$cur })
    $b = $(if ($want -is [System.Collections.IEnumerable] -and -not ($want -is [string])) { (@($want | ForEach-Object { [string]$_ }) | Sort-Object) -join ',' } else { [string]$want })
    if ($a -cne $b) { $diff += "$k`: '$a' -> '$b'" }
  }
  return $diff
}

# Generic upsert: finds $Existing (or $null), compares, and creates/updates unless -WhatIf. Returns the object (or a
# placeholder in dry-run mode) so later steps can reference its primary key.
function Sync-AkObject {
  param($Conn, $Actions, [string]$Object, [string]$Name, $Existing, [string]$CollectionPath, [string]$ItemPath, [hashtable]$Desired, [string[]]$SecretFields = @(), [switch]$WhatIf, [switch]$NoUpdate)
  if ($null -eq $Existing) {
    Add-AkAction $Actions 'create' $Object $Name "Create $Object '$Name'"
    if ($WhatIf) { return [pscustomobject]@{ pk = "<new $Object>"; name = $Name; pbm_uuid = "<new $Object>"; policybindingmodel_ptr_id = "<new $Object>"; planned = $true } }
    $o = Invoke-AuthentikApi $Conn POST $CollectionPath $Desired
    Set-AkActionDone $Actions
    return $o
  }
  $changes = @(Get-AkChanges $Existing $Desired $SecretFields)
  if ($changes.Count -eq 0 -or $NoUpdate) { Add-AkAction $Actions 'none' $Object $Name "$Object '$Name' is up to date"; return $Existing }
  Add-AkAction $Actions 'update' $Object $Name "Update $Object '$Name'" ($changes -join '; ')
  if ($WhatIf) { return $Existing }
  $o = Invoke-AuthentikApi $Conn PATCH $ItemPath $Desired
  Set-AkActionDone $Actions
  return $o
}

# --- Embedded outpost ---------------------------------------------------------------------------------------------------

# The address the embedded outpost sends browsers to for signing in: authentik_host_browser when set, else
# authentik_host. Traefik reaches the outpost separately (http://<authentik container>:9000, inside Docker).
function Get-AkOutpostBrowserHost($Outpost) {
  $cfg = $Outpost.Config
  $b = [string](Get-AkProp $cfg 'authentik_host_browser' '')
  if ($b) { return $b }
  return [string](Get-AkProp $cfg 'authentik_host' '')
}

# Public sign-in address for the outpost: must be a public hostname (https; plain http only for disposable test setups
# on a dotted name). A loopback, LAN or Docker-only address works on this PC only, so it is refused.
function Assert-AkPublicSignInUrl([string]$PublicUrl) {
  $t = Test-BrowserEndpoint $PublicUrl -AllowHttp
  if (-not $t.ok) { throw "The public sign-in address '$PublicUrl' cannot be used for browsers: $($t.problems[0])" }
}

# Adds (and, without -WhatIf, applies) the outpost change that makes sign-in redirects use $PublicUrl.
function Sync-AkOutpostBrowserHost($Conn, $Outpost, [string]$PublicUrl, $Actions, [switch]$WhatIf) {
  Assert-AkPublicSignInUrl $PublicUrl
  $want = $PublicUrl.TrimEnd('/') + '/'
  $now = Get-AkOutpostBrowserHost $Outpost
  if ($now.TrimEnd('/') -eq $want.TrimEnd('/')) { Add-AkAction $Actions 'none' 'outpost' $Outpost.Name "Embedded outpost already sends browsers to $want"; return }
  $why = $(if ($now) { $k = Test-BrowserEndpoint $now -AllowHttp; if ($k.ok) { '' } else { " ($($k.problems[0]))" } } else { '' })
  Add-AkAction $Actions 'update' 'outpost' $Outpost.Name "Embedded outpost: send browsers to $want for signing in" "Sign-in redirects currently go to '$now'$why. Traefik keeps reaching authentik internally."
  if (-not $WhatIf) {
    $cfg = $Outpost.Config
    $cfg.authentik_host = $want
    if ($cfg.PSObject.Properties['authentik_host_browser'] -and [string]$cfg.authentik_host_browser -and ([string]$cfg.authentik_host_browser).TrimEnd('/') -ne $want.TrimEnd('/')) { $cfg.authentik_host_browser = '' }
    $null = Invoke-AuthentikApi $Conn PATCH "/outposts/instances/$($Outpost.Pk)/" @{ config = $cfg }
    Set-AkActionDone $Actions
  }
}

# Sets the embedded outpost's sign-in address to the public URL, so sign-in redirects send browsers to
# https://auth.<domain>/ (not to an internal address).
function Sync-AuthentikOutpost {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$PublicUrl, [switch]$WhatIf)
  Assert-AkPublicSignInUrl $PublicUrl
  $actions = New-AkActionList
  $ov = Get-AuthentikOverview $Conn
  if (-not $ov.Outpost) { throw 'authentik has no embedded outpost (it is created on first start). Wait until authentik is ready.' }
  Sync-AkOutpostBrowserHost $Conn $ov.Outpost $PublicUrl $actions -WhatIf:$WhatIf
  return $actions.ToArray()
}

# --- Initial owner, Google source -----------------------------------------------------------------------------------

$script:OwnersGroup = 'DTC owners'
$script:AdminsGroup = 'authentik Admins'
function Get-AuthentikOwnersGroupName { return $script:OwnersGroup }

function Get-AuthentikGroup($Conn, [string]$Name) {
  return @(Get-AuthentikList $Conn "/core/groups/?name=$([Uri]::EscapeDataString($Name))" | Where-Object { [string]$_.name -eq $Name })[0]
}

# One-time setup in authentik (each object only created when missing; existing ones are never changed):
#   - group "DTC owners" (the initial owner-only access rule for protected applications), with the administrator whose
#     token the manager uses (akadmin, the local recovery account) as its first member;
#   - enrollment flow dm-<slug>-enrollment (the default enrollment stages) with a policy that admits only the owner's
#     verified Google address; while the owner has not signed in yet, a changed owner address updates that policy;
#   - the Google OAuth source (client ID/secret; identifier matching: never linked to an existing account by email) and
#     its button on the login page.
# Desired: Slug, ClientId, ClientSecret (optional when the source exists), OwnerEmail, OwnerVerified (bool), Replace
# (bool: allow changing the client of an existing Google source), Repair (bool: fix a flow from an earlier version).
#
# Users created by the enrollment flow are Internal (a dedicated write stage): authentik's default source enrollment
# stage creates External users, who are refused by authentik's own user interface ("Interface can only be accessed by
# internal users"). Google Cloud's "External" audience is unrelated: it only means "any Google account".
function Sync-AuthentikGoogleSource {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Desired, [switch]$WhatIf)
  $actions = New-AkActionList
  $slug = [string](Get-AkProp $Desired 'Slug' 'google')
  if ($slug -notmatch $script:SlugPattern) { throw "Invalid source slug '$slug'." }
  if (-not (Test-GoogleClientId (Get-AkProp $Desired 'ClientId' ''))) { throw 'The client ID does not look like a Google OAuth client ID (ending in .apps.googleusercontent.com).' }
  $secret = [string](Get-AkProp $Desired 'ClientSecret' '')
  if ($secret -and -not (Test-GoogleClientSecret $secret)) { throw 'The client secret contains unexpected characters. Copy it again from Google Cloud.' }
  $owner = ConvertTo-OwnerEmail (Get-AkProp $Desired 'OwnerEmail' '')
  $ownerVerified = [bool](Get-AkProp $Desired 'OwnerVerified' $false)
  $ov = Get-AuthentikOverview $Conn
  if ($ov.MissingFlows.Count) { throw "authentik is not fully initialized yet (missing flows: $($ov.MissingFlows -join ', ')). Wait a minute and try again." }
  $existing = @(Get-AuthentikList $Conn "/sources/oauth/?slug=$slug")[0]
  if ($existing -and [string]$existing.provider_type -ne 'google') { throw "A source with the slug '$slug' already exists and is not a Google source. Choose another slug." }
  if (-not $existing -and -not $secret) { throw 'Enter the client secret.' }
  $replace = [bool](Get-AkProp $Desired 'Replace' $false)
  if ($existing -and -not $replace -and ($secret -or [string]$existing.consumer_key -ne ([string]$Desired.ClientId).Trim())) {
    $err = New-Object System.Exception ("authentik already has a Google connection (client $($existing.consumer_key)). Choose 'Replace the Google client' to change it; until then it stays as it is.")
    $err.Data['Status'] = 409; $err.Data['NeedsReplace'] = $true; throw $err
  }

  # Owner group with the administrator as first member.
  $grp = Get-AuthentikGroup $Conn $script:OwnersGroup
  if ($grp) { Add-AkAction $actions 'none' 'group' $script:OwnersGroup "Group '$($script:OwnersGroup)' exists (members are managed in authentik)" }
  else {
    Add-AkAction $actions 'create' 'group' $script:OwnersGroup "Create group '$($script:OwnersGroup)' with $($ov.User.Username) as first member" 'The initial owner-only access rule for protected applications. Add or remove people in authentik.'
    if (-not $WhatIf) {
      $me = Invoke-AuthentikApi $Conn GET '/core/users/me/'
      $grp = Invoke-AuthentikApi $Conn POST '/core/groups/' @{ name = $script:OwnersGroup; is_superuser = $false; users = @([int]$me.user.pk); attributes = @{ 'created-by' = 'traefik-deployment-manager' } }
      Set-AkActionDone $actions
    }
  }

  # Owner-only enrollment flow.
  $fslug = "$($script:Prefix)$slug-enrollment"
  $flow = $(if ($ov.Flows.ContainsKey($fslug)) { Invoke-AuthentikApi $Conn GET "/flows/instances/$fslug/" } else { $null })
  if ($flow) { Add-AkAction $actions 'none' 'flow' $fslug "Enrollment flow '$fslug' exists" }
  else {
    Add-AkAction $actions 'create' 'flow' $fslug "Create enrollment flow '$fslug' (default enrollment stages)"
    if (-not $WhatIf) { $flow = Invoke-AuthentikApi $Conn POST '/flows/instances/' @{ name = 'Google enrollment (Deployment Manager)'; slug = $fslug; title = 'Create your account'; designation = 'enrollment'; authentication = 'none'; denied_action = 'message'; policy_engine_mode = 'any' }; Set-AkActionDone $actions }
    else { $flow = [pscustomobject]@{ pk = '<new flow>'; policybindingmodel_ptr_id = '<new flow>'; planned = $true } }
  }
  # The flow's stages: the default enrollment stages, except that users are written by our own stage as Internal users.
  $repair = [bool](Get-AkProp $Desired 'Repair' $false)
  $defWrite = $null
  $defBindings = @(Get-AuthentikList $Conn "/flows/bindings/?target=$($ov.Flows['default-source-enrollment'].Pk)&ordering=order")
  foreach ($b in $defBindings) { if ([string](Get-AkProp $b.stage_obj 'component' '') -like '*user-write*') { $defWrite = Invoke-AuthentikApi $Conn GET "/stages/user_write/$($b.stage)/" } }
  $wname = "$($script:Prefix)$slug-owner-write"
  $wstage = @(Get-AuthentikList $Conn "/stages/user_write/?name=$([Uri]::EscapeDataString($wname))" | Where-Object { [string]$_.name -eq $wname })[0]
  if ($wstage) { Add-AkAction $actions 'none' 'stage' $wname "Write stage '$wname' exists" }
  else {
    Add-AkAction $actions 'create' 'stage' $wname "Create write stage '$wname': accounts created through Google are Internal users" 'Internal users can open their authentik dashboard; External users are refused by it. No group and no administrator right is given here.'
    if (-not $WhatIf) {
      $wstage = Invoke-AuthentikApi $Conn POST '/stages/user_write/' @{ name = $wname; user_type = 'internal'; create_users_as_inactive = $false
        user_creation_mode = [string](Get-AkProp $defWrite 'user_creation_mode' 'create_when_required'); user_path_template = [string](Get-AkProp $defWrite 'user_path_template' 'goauthentik.io/sources/%(slug)s') }
      Set-AkActionDone $actions
    } else { $wstage = [pscustomobject]@{ pk = '<new stage>'; planned = $true } }
  }
  if (-not $flow.PSObject.Properties['planned']) {
    $have = @(Get-AuthentikList $Conn "/flows/bindings/?target=$($flow.pk)&ordering=order")
    if (-not $have.Count) {
      foreach ($b in $defBindings) {
        $isWrite = [string](Get-AkProp $b.stage_obj 'component' '') -like '*user-write*'
        Add-AkAction $actions 'create' 'flow stage' $(if ($isWrite) { $wname } else { $b.stage_obj.name }) "Bind stage '$(if ($isWrite) { $wname } else { $b.stage_obj.name })' (order $($b.order))"
        if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST '/flows/bindings/' @{ target = $flow.pk; stage = $(if ($isWrite) { $wstage.pk } else { $b.stage }); order = [int]$b.order; evaluate_on_plan = [bool]$b.evaluate_on_plan; re_evaluate_policies = [bool]$b.re_evaluate_policies }; Set-AkActionDone $actions }
      }
    } else {
      # A flow from an earlier version writes External users through the shared default stage: repaired only during setup
      # (owner not verified yet) or on explicit request.
      $wrong = @($have | Where-Object { [string](Get-AkProp $_.stage_obj 'component' '') -like '*user-write*' -and [string]$_.stage -ne [string](Get-AkProp $wstage 'pk' '') })
      $wrongExternal = @(foreach ($b in $wrong) { $st = $null; try { $st = Invoke-AuthentikApi $Conn GET "/stages/user_write/$($b.stage)/" } catch { }; if (-not $st -or [string]$st.user_type -ne 'internal') { $b } })
      if ($wrongExternal.Count -and (-not $ownerVerified -or $repair)) {
        foreach ($b in $wrongExternal) {
          Add-AkAction $actions 'update' 'flow stage' $fslug "Repair: let '$fslug' create Internal users (stage '$($b.stage_obj.name)' -> '$wname')" 'Fixes "Interface can only be accessed by internal users" for accounts created through Google.'
          if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/flows/bindings/$($b.pk)/" @{ stage = $wstage.pk }; Set-AkActionDone $actions }
        }
      } elseif ($wrongExternal.Count) { Add-AkAction $actions 'none' 'flow stage' $fslug 'The enrollment flow creates External users; it belongs to authentik now (use "Repair" to fix it)' }
      else { Add-AkAction $actions 'none' 'flow stage' $fslug "The enrollment flow has its stages ($($have.Count)) and creates Internal users" }
    }
  } else { Add-AkAction $actions 'create' 'flow stage' $fslug 'Bind the enrollment stages (prompt, write Internal user, log in)' }
  $pname = "$($script:Prefix)$slug-initial-owner"
  $pol = @(Get-AuthentikList $Conn "/policies/expression/?name=$([Uri]::EscapeDataString($pname))")[0]
  $expr = New-OwnerEnrollmentExpression $owner
  if (-not $pol) {
    Add-AkAction $actions 'create' 'policy' $pname "Only $owner may create an account with Google"
    if (-not $WhatIf) { $pol = Invoke-AuthentikApi $Conn POST '/policies/expression/' @{ name = $pname; expression = $expr; execution_logging = $false }; Set-AkActionDone $actions }
    else { $pol = [pscustomobject]@{ pk = '<new policy>'; planned = $true } }
  } elseif ($ownerVerified -or [string]$pol.expression -eq $expr) { Add-AkAction $actions 'none' 'policy' $pname $(if ($ownerVerified) { 'The enrollment policy belongs to authentik now (not changed)' } else { "Only $owner may create an account with Google" }) }
  else {
    Add-AkAction $actions 'update' 'policy' $pname "Change the initial owner to $owner (the owner has not signed in yet)"
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/policies/expression/$($pol.pk)/" @{ expression = $expr }; Set-AkActionDone $actions }
  }
  $flowPbm = [string](Get-AkProp $flow 'policybindingmodel_ptr_id' $flow.pk)
  $bound = @()
  if (-not $flow.PSObject.Properties['planned'] -and -not $pol.PSObject.Properties['planned']) { $bound = @(Get-AuthentikList $Conn "/policies/bindings/?target=$flowPbm") }
  if ($bound.Count) { Add-AkAction $actions 'none' 'policy binding' $fslug 'The enrollment flow has its access rule' }
  else {
    Add-AkAction $actions 'create' 'policy binding' $fslug 'Bind the owner-only rule to the enrollment flow'
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST '/policies/bindings/' @{ policy = $pol.pk; target = $flowPbm; order = 0; enabled = $true; negate = $false; timeout = 30; failure_result = $false }; Set-AkActionDone $actions }
  }

  # The source: client ID and secret are DTC's to set (the user rotates them here); flows and matching only on creation.
  $src = $existing
  if (-not $existing) {
    Add-AkAction $actions 'create' 'Google source' $slug "Create the Google source '$slug' (never linked to existing accounts by email)"
    if (-not $WhatIf) {
      $src = Invoke-AuthentikApi $Conn POST '/sources/oauth/' @{ name = 'Google'; slug = $slug; enabled = $true; promoted = $true; provider_type = 'google'; consumer_key = ([string]$Desired.ClientId).Trim(); consumer_secret = $secret
        authentication_flow = $ov.Flows['default-source-authentication'].Pk; enrollment_flow = [string]$flow.pk; user_matching_mode = 'identifier'; policy_engine_mode = 'any' }
      Set-AkActionDone $actions
    }
  } else {
    $patch = @{}
    if ([string]$existing.consumer_key -ne ([string]$Desired.ClientId).Trim()) { $patch.consumer_key = ([string]$Desired.ClientId).Trim() }
    if ($secret) { $patch.consumer_secret = $secret }
    if (-not [string](Get-AkProp $existing 'enrollment_flow' '') -and -not $ownerVerified -and -not $flow.PSObject.Properties['planned']) { $patch.enrollment_flow = [string]$flow.pk }
    if ($patch.Count) {
      Add-AkAction $actions 'update' 'Google source' $slug "Update the Google source '$slug'" (@($patch.Keys | ForEach-Object { if ($_ -eq 'consumer_secret') { 'client secret (new value)' } elseif ($_ -eq 'consumer_key') { 'client ID' } else { $_ } }) -join ', ')
      if (-not $WhatIf) { $src = Invoke-AuthentikApi $Conn PATCH "/sources/oauth/$slug/" $patch; Set-AkActionDone $actions }
    } else { Add-AkAction $actions 'none' 'Google source' $slug "The Google source '$slug' is configured" }
  }

  # Login page button (added once; removing it later in authentik is respected only after setup).
  $stage = $ov.LoginStage
  $srcPk = [string](Get-AkProp $src 'pk' '')
  if (-not $stage) { Add-AkAction $actions 'none' 'login page' '(identification stage)' 'The login page''s identification stage was not found: add the Google button in authentik by hand.' }
  elseif ($srcPk -and $stage.Sources -contains $srcPk) { Add-AkAction $actions 'none' 'login page' $stage.Name 'The login page shows "Sign in with Google"' }
  elseif ($ownerVerified) { Add-AkAction $actions 'none' 'login page' $stage.Name 'The login page is managed in authentik (not changed)' }
  else {
    Add-AkAction $actions 'update' 'login page' $stage.Name "Show 'Sign in with Google' on the login page"
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/stages/identification/$($stage.Pk)/" @{ sources = @(@($stage.Sources) + $srcPk) }; Set-AkActionDone $actions }
  }
  return [pscustomobject]@{ Actions = $actions.ToArray(); SourcePk = $srcPk; EnrollmentFlow = [string]$flow.pk; GroupPk = [string](Get-AkProp $grp 'pk' '') }
}

# The "DTC owners" group (owner-only access rule) with the API token's administrator as first member: created once, the
# same way the Google setup does, for installations that sign in with local accounts only.
function Sync-AuthentikOwnersGroup {
  param([Parameter(Mandatory = $true)]$Conn, [switch]$WhatIf)
  $actions = New-AkActionList
  $grp = Get-AuthentikGroup $Conn $script:OwnersGroup
  if ($grp) { Add-AkAction $actions 'none' 'group' $script:OwnersGroup "Group '$($script:OwnersGroup)' exists (members are managed in authentik)" }
  else {
    $me = Invoke-AuthentikApi $Conn GET '/core/users/me/'
    Add-AkAction $actions 'create' 'group' $script:OwnersGroup "Create group '$($script:OwnersGroup)' with $($me.user.username) as first member" 'The initial owner-only access rule for protected applications. Add or remove people in authentik.'
    if (-not $WhatIf) { $grp = Invoke-AuthentikApi $Conn POST '/core/groups/' @{ name = $script:OwnersGroup; is_superuser = $false; users = @([int]$me.user.pk); attributes = @{ 'created-by' = 'traefik-deployment-manager' } }; Set-AkActionDone $actions }
  }
  return [pscustomobject]@{ Actions = $actions.ToArray(); Group = $grp }
}

# The owner's account after their first Google sign-in: users connected to the Google source whose email is the
# owner's address. (The enrollment policy already required Google to have verified that address.)
function Find-AuthentikOwner {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$OwnerEmail, [string]$Slug = 'google')
  $e = ConvertTo-OwnerEmail $OwnerEmail
  $out = @()
  foreach ($c in @(Get-AuthentikList $Conn "/sources/user_connections/oauth/?source__slug=$Slug")) {
    $u = $null; try { $u = Invoke-AuthentikApi $Conn GET "/core/users/$($c.user)/" } catch { continue }
    if (([string]$u.email).Trim().ToLowerInvariant() -eq $e) {
      $out += [pscustomobject]@{ Pk = [int]$u.pk; Username = [string]$u.username; Email = [string]$u.email; IsActive = [bool]$u.is_active; IsSuperuser = [bool]$u.is_superuser
        Type = [string](Get-AkProp $u 'type' ''); Subject = [string]$c.identifier
        LastLogin = $(if ($u.last_login) { ([datetime]::Parse([string]$u.last_login, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString('s') } else { '' })
        Groups = @(@(Get-AkProp $u 'groups_obj' @()) | ForEach-Object { [string]$_.name }) }
    }
  }
  return $out
}

# The owner's state, item by item, for the verification step (read only). $Owner: the user (Find-AuthentikOwner) or, for
# local sign-in, the administrator account; $Since: the sign-in must be newer (local path); $ExpectSubject: the Google
# subject recorded at the first verification (a different Google identity is refused).
function Get-AuthentikOwnerCheck {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Owner, [switch]$MakeAdmin, [string]$ExpectSubject = '', [datetime]$Since = [datetime]::MinValue, [switch]$Local)
  $u = Invoke-AuthentikApi $Conn GET "/core/users/$($Owner.Pk)/"
  $groups = @(@(Get-AkProp $u 'groups_obj' @()) | ForEach-Object { [string]$_.name })
  $last = $null; if ($u.last_login) { $last = [datetime]::Parse([string]$u.last_login, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
  $items = @(
    [ordered]@{ id = 'identity'; label = $(if ($Local) { 'Local administrator account' } else { 'Google identity' }); ok = $(if ($Local) { [bool]$u.is_active } else { -not $ExpectSubject -or $ExpectSubject -eq [string](Get-AkProp $Owner 'Subject' '') })
      message = $(if ($Local) { "$($u.username) (local password sign-in)" } elseif ($ExpectSubject -and $ExpectSubject -ne [string](Get-AkProp $Owner 'Subject' '')) { 'A different Google identity than the one verified first signed in with this address.' } else { "$($u.email): verified by Google, signed in as '$($u.username)'" }) }
    [ordered]@{ id = 'internal'; label = 'Internal authentik account'; ok = ([string](Get-AkProp $u 'type' '') -eq 'internal'); message = "Account type: $([string](Get-AkProp $u 'type' ''))$(if ([string](Get-AkProp $u 'type' '') -ne 'internal') { ' (External accounts cannot open their authentik dashboard)' })" }
    [ordered]@{ id = 'owners'; label = "Member of '$($script:OwnersGroup)'"; ok = ($groups -contains $script:OwnersGroup); message = $(if ($groups -contains $script:OwnersGroup) { 'Can open protected applications.' } else { 'Not a member yet.' }) }
  )
  if ($MakeAdmin) { $items += [ordered]@{ id = 'admin'; label = 'authentik administrator'; ok = ([bool]$u.is_superuser -or $groups -contains $script:AdminsGroup); message = $(if ([bool]$u.is_superuser) { 'Has administrator rights.' } else { 'Not an administrator yet.' }) } }
  $loginOk = [bool]($last -and $last.ToUniversalTime() -ge $Since.ToUniversalTime())
  $items += [ordered]@{ id = 'login'; label = 'Sign-in completed'; ok = $loginOk; message = $(if ($last) { "Last sign-in $($last.ToLocalTime().ToString('s'))$(if (-not $loginOk) { ' (before this check started: sign in again)' })" } else { 'Has never signed in.' }) }
  return [pscustomobject]@{ Ok = -not @($items | Where-Object { -not $_.ok }).Count; Items = $items; Username = [string]$u.username; Type = [string](Get-AkProp $u 'type' ''); LastLogin = $(if ($last) { $last.ToLocalTime().ToString('s') } else { '' }) }
}

# Explicit repair for an owner account created by an earlier version as an External user.
function Set-AuthentikUserInternal {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][int]$UserPk)
  $u = Invoke-AuthentikApi $Conn GET "/core/users/$UserPk/"
  if ([string]$u.type -eq 'internal') { return $false }
  $null = Invoke-AuthentikApi $Conn PATCH "/core/users/$UserPk/" @{ type = 'internal' }
  return $true
}

# Completes the one-time owner setup: adds the verified owner account to "DTC owners" and, if chosen, to the
# authentik administrators. Only adds memberships (never removes anything).
function Complete-AuthentikOwner {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][int]$UserPk, [switch]$MakeAdmin, [switch]$WhatIf)
  $actions = New-AkActionList
  $names = @($script:OwnersGroup) + $(if ($MakeAdmin) { @($script:AdminsGroup) } else { @() })
  foreach ($n in $names) {
    $g = Get-AuthentikGroup $Conn $n
    if (-not $g) { Add-AkAction $actions 'none' 'group' $n "Group '$n' does not exist (skipped)"; continue }
    if (@($g.users | ForEach-Object { [int]$_ }) -contains $UserPk) { Add-AkAction $actions 'none' 'group' $n "Already a member of '$n'"; continue }
    Add-AkAction $actions 'update' 'group' $n "Add the owner to '$n'"
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST "/core/groups/$($g.pk)/add_user/" @{ pk = $UserPk }; Set-AkActionDone $actions }
  }
  return $actions.ToArray()
}

# --- Sign-in page (Google first) -------------------------------------------------------------------------------------------

# A separate authentication flow dm-authentication, cloned from default-authentication-flow, whose identification stage
# shows the Google button first ("promoted", with its label) above the email/password form; the brand uses it and gets
# a title for the domain. The default flow is left exactly as it is: it stays the local recovery route
# (/if/flow/default-authentication-flow/), and "Restore" points the brand back. Previous brand values are returned so
# the caller can record them.
function Sync-AuthentikLoginPage {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$Title, [string]$Slug = 'google', [switch]$WhatIf)
  $actions = New-AkActionList
  $ov = Get-AuthentikOverview $Conn
  if (-not $ov.Flows.ContainsKey('default-authentication-flow')) { throw 'authentik has no default-authentication-flow to start from.' }
  $src = @(Get-AuthentikList $Conn "/sources/oauth/?slug=$Slug")[0]
  if (-not $src) { throw 'Turn on Google sign-in first.' }
  $defPk = $ov.Flows['default-authentication-flow'].Pk
  $defBindings = @(Get-AuthentikList $Conn "/flows/bindings/?target=$defPk&ordering=order")
  $identBinding = @($defBindings | Where-Object { [string](Get-AkProp $_.stage_obj 'component' '') -eq 'ak-stage-identification-form' })[0]
  if (-not $identBinding) { throw 'The default sign-in flow has no identification stage to start from.' }
  $defIdent = Invoke-AuthentikApi $Conn GET "/stages/identification/$($identBinding.stage)/"
  $iname = "$($script:Prefix)identification"
  $ident = @(Get-AuthentikList $Conn "/stages/identification/?name=$([Uri]::EscapeDataString($iname))" | Where-Object { [string]$_.name -eq $iname })[0]
  if ($ident) { Add-AkAction $actions 'none' 'stage' $iname "Identification stage '$iname' exists (managed in authentik)" }
  else {
    Add-AkAction $actions 'create' 'stage' $iname 'Create the sign-in form: "Google" first, email or username with password below'
    if (-not $WhatIf) {
      $ident = Invoke-AuthentikApi $Conn POST '/stages/identification/' @{ name = $iname; user_fields = @($defIdent.user_fields); password_stage = (Get-AkProp $defIdent 'password_stage' $null); captcha_stage = (Get-AkProp $defIdent 'captcha_stage' $null)
        case_insensitive_matching = $true; show_matched_user = [bool](Get-AkProp $defIdent 'show_matched_user' $true); enrollment_flow = $null; recovery_flow = (Get-AkProp $defIdent 'recovery_flow' $null)
        passwordless_flow = (Get-AkProp $defIdent 'passwordless_flow' $null); sources = @([string]$src.pk); show_source_labels = $true; pretend_user_exists = $true; enable_remember_me = [bool](Get-AkProp $defIdent 'enable_remember_me' $false) }
      Set-AkActionDone $actions
    } else { $ident = [pscustomobject]@{ pk = '<new stage>'; planned = $true } }
  }
  $fslug = "$($script:Prefix)authentication"
  $flow = $(if ($ov.Flows.ContainsKey($fslug)) { Invoke-AuthentikApi $Conn GET "/flows/instances/$fslug/" } else { $null })
  if ($flow) { Add-AkAction $actions 'none' 'flow' $fslug "Sign-in flow '$fslug' exists (managed in authentik)" }
  else {
    Add-AkAction $actions 'create' 'flow' $fslug "Create sign-in flow '$fslug' (a copy of the default flow with the Google-first form)"
    if (-not $WhatIf) {
      $def = Invoke-AuthentikApi $Conn GET "/flows/instances/default-authentication-flow/"
      $flow = Invoke-AuthentikApi $Conn POST '/flows/instances/' @{ name = "Sign in ($Title)"; slug = $fslug; title = $Title; designation = 'authentication'; authentication = [string](Get-AkProp $def 'authentication' 'none'); denied_action = [string](Get-AkProp $def 'denied_action' 'message_continue'); policy_engine_mode = [string](Get-AkProp $def 'policy_engine_mode' 'any') }
      foreach ($b in $defBindings) {
        $isIdent = [string]$b.stage -eq [string]$identBinding.stage
        $null = Invoke-AuthentikApi $Conn POST '/flows/bindings/' @{ target = $flow.pk; stage = $(if ($isIdent) { $ident.pk } else { $b.stage }); order = [int]$b.order; evaluate_on_plan = [bool]$b.evaluate_on_plan; re_evaluate_policies = [bool]$b.re_evaluate_policies; policy_engine_mode = [string](Get-AkProp $b 'policy_engine_mode' 'any'); invalid_response_action = [string](Get-AkProp $b 'invalid_response_action' 'retry') }
      }
      Set-AkActionDone $actions
    } else { $flow = [pscustomobject]@{ pk = '<new flow>'; planned = $true } }
  }
  $brand = @(Get-AuthentikList $Conn '/core/brands/' | Where-Object { [bool]$_.default })[0]
  if (-not $brand) { $brand = @(Get-AuthentikList $Conn '/core/brands/')[0] }
  $prev = [ordered]@{ brand = [string]$brand.brand_uuid; flow = [string](Get-AkProp $brand 'flow_authentication' ''); title = [string](Get-AkProp $brand 'branding_title' '') }
  $patch = @{}
  if ([string](Get-AkProp $brand 'flow_authentication' '') -ne [string]$flow.pk) { $patch.flow_authentication = $flow.pk }
  if ([string](Get-AkProp $brand 'branding_title' '') -ne $Title) { $patch.branding_title = $Title }
  if ($patch.Count) {
    Add-AkAction $actions 'update' 'brand' $brand.domain "Use the Google-first sign-in page$(if ($patch.ContainsKey('branding_title')) { " titled '$Title'" })" 'The default sign-in flow stays unchanged and reachable for local recovery.'
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/core/brands/$($brand.brand_uuid)/" $patch; Set-AkActionDone $actions }
  } else { Add-AkAction $actions 'none' 'brand' $brand.domain 'The sign-in page already uses the Google-first form' }
  return [pscustomobject]@{ Actions = $actions.ToArray(); Previous = $prev; FlowSlug = $fslug }
}

# Points the brand back to its previous sign-in flow and title. The dm-authentication flow is kept (unused).
function Restore-AuthentikLoginPage {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Previous)
  $patch = @{ flow_authentication = $(if ($Previous.flow) { $Previous.flow } else { $null }); branding_title = $(if ($Previous.title) { $Previous.title } else { 'authentik' }) }
  $null = Invoke-AuthentikApi $Conn PATCH "/core/brands/$($Previous.brand)/" $patch
}

# --- Application protection (ForwardAuth, single application) -----------------------------------------------------------

# Creates or reuses, for one application: the proxy provider dm-<service> (forward_single), the application dm-<service>
# and the embedded outpost assignment. Access: when the application has no binding yet, the "DTC owners" group is bound
# (the owner-only rule); an application that already has bindings keeps exactly those. Existing objects are not changed
# except what the proxy integration needs (provider mode and external address, provider link, outpost assignment).
# Desired: Service, DisplayName, Hostname, ExternalUrl (optional).
function Sync-AuthentikAppProtection {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Desired, [switch]$WhatIf)
  $actions = New-AkActionList
  $svc = ([string]$Desired.Service).ToLowerInvariant()
  $slug = "$($script:Prefix)$svc"
  if ($slug -notmatch $script:SlugPattern) { throw "Invalid application name '$svc'." }
  $hostname = ([string]$Desired.Hostname).ToLowerInvariant()
  if ($hostname -notmatch $script:DomainPattern) { throw "Invalid hostname '$hostname'." }
  $display = [string](Get-AkProp $Desired 'DisplayName' $svc)
  $external = [string](Get-AkProp $Desired 'ExternalUrl' "https://$hostname")
  if ($external -notmatch '^https?://[a-z0-9.-]+(:\d{1,5})?$') { throw "Invalid application address '$external'." }
  if ([string](Get-AkProp $Desired 'PublicUrl' '')) { Assert-AkPublicSignInUrl ([string]$Desired.PublicUrl) }
  $ov = Get-AuthentikOverview $Conn
  if ($ov.MissingFlows.Count) { throw "authentik is not fully initialized yet (missing flows: $($ov.MissingFlows -join ', '))." }
  if (-not $ov.Outpost) { throw 'authentik has no embedded outpost yet.' }

  # Proxy provider.
  $prov = @(Get-AuthentikList $Conn "/providers/proxy/?name=$([Uri]::EscapeDataString($slug))" | Where-Object { [string]$_.name -eq $slug })[0]
  if (-not $prov) {
    Add-AkAction $actions 'create' 'proxy provider' $slug "Create proxy provider '$slug' (single application, $external)"
    if (-not $WhatIf) {
      $prov = Invoke-AuthentikApi $Conn POST '/providers/proxy/' @{ name = $slug; mode = 'forward_single'; external_host = $external
        authorization_flow = $ov.Flows['default-provider-authorization-implicit-consent'].Pk; invalidation_flow = $ov.Flows['default-provider-invalidation-flow'].Pk }
      Set-AkActionDone $actions
    } else { $prov = [pscustomobject]@{ pk = $null; planned = $true } }
  } elseif ([string]$prov.mode -ne 'forward_single' -or [string]$prov.external_host -ne $external) {
    Add-AkAction $actions 'update' 'proxy provider' $slug "Point '$slug' at $external (forward auth, single application)" "mode: '$($prov.mode)' -> 'forward_single'; address: '$($prov.external_host)' -> '$external'"
    if (-not $WhatIf) { $prov = Invoke-AuthentikApi $Conn PATCH "/providers/proxy/$($prov.pk)/" @{ mode = 'forward_single'; external_host = $external }; Set-AkActionDone $actions }
  } else { Add-AkAction $actions 'none' 'proxy provider' $slug "Proxy provider '$slug' is reused" }
  $provPk = $(if ($prov.PSObject.Properties['planned']) { $null } else { [int]$prov.pk })

  # Application.
  $app = $null; try { $app = Invoke-AuthentikApi $Conn GET "/core/applications/$slug/" } catch { if ($_.Exception.Data['Status'] -ne 404) { throw } }
  if (-not $app) {
    Add-AkAction $actions 'create' 'application' $slug "Create application '$display' ($slug)"
    if (-not $WhatIf) {
      $body = @{ name = $display; slug = $slug; meta_launch_url = "$external/"; policy_engine_mode = 'any'; meta_description = 'Protected by authentik forward auth (set up by the Deployment Manager). Who may open it is managed here in authentik.' }
      if ($null -ne $provPk) { $body.provider = $provPk }
      $app = Invoke-AuthentikApi $Conn POST '/core/applications/' $body
      Set-AkActionDone $actions
    } else { $app = [pscustomobject]@{ pk = $null; pbm_uuid = $null; planned = $true } }
  } elseif ($null -ne $provPk -and [int](Get-AkProp $app 'provider' 0) -ne $provPk) {
    Add-AkAction $actions 'update' 'application' $slug "Link application '$slug' to its proxy provider"
    if (-not $WhatIf) { $app = Invoke-AuthentikApi $Conn PATCH "/core/applications/$slug/" @{ provider = $provPk }; Set-AkActionDone $actions }
  } else { Add-AkAction $actions 'none' 'application' $slug "Application '$slug' is reused" }

  # Access: owner-only on a new (unbound) application; existing rules are authentik's and stay as they are.
  $have = @(); if (-not $app.PSObject.Properties['planned']) { $have = @(Get-AuthentikList $Conn "/policies/bindings/?target=$([string](Get-AkProp $app 'pbm_uuid' $app.pk))") }
  $access = 'existing'
  if ($have.Count) { Add-AkAction $actions 'none' 'access' $slug "Keeps its $($have.Count) access rule(s) in authentik (not changed)" }
  else {
    $access = 'owner-only'
    $grp = Get-AuthentikGroup $Conn $script:OwnersGroup
    if (-not $grp) { throw "The group '$($script:OwnersGroup)' does not exist in authentik. Finish the Google sign-in setup first (it creates the owner-only rule), or bind an access rule to '$slug' in authentik." }
    Add-AkAction $actions 'create' 'access' $slug "Only '$($script:OwnersGroup)' may open it (change this in authentik at any time)"
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST '/policies/bindings/' @{ group = $grp.pk; target = [string](Get-AkProp $app 'pbm_uuid' $app.pk); order = 0; enabled = $true; negate = $false; timeout = 30 }; Set-AkActionDone $actions }
  }

  # Embedded outpost: the sign-in address browsers are sent to, then serving this provider. Without a public sign-in
  # address the redirect would only work on this PC, so protection is refused instead of half-working.
  $pub = [string](Get-AkProp $Desired 'PublicUrl' '')
  if ($pub) { Sync-AkOutpostBrowserHost $Conn $ov.Outpost $pub $actions -WhatIf:$WhatIf }
  else {
    $now = Get-AkOutpostBrowserHost $ov.Outpost
    $k = Test-BrowserEndpoint $now -AllowHttp
    if (-not $now -or -not $k.ok) { throw "authentik's embedded outpost sends browsers to '$now' for signing in$(if ($k.problems.Count) { ": $($k.problems[0])" } else { '' }) Set the public sign-in address first (Identity & Access, Public sign-in address)." }
  }
  if ($null -ne $provPk -and $ov.Outpost.Providers -contains $provPk) { Add-AkAction $actions 'none' 'outpost' $ov.Outpost.Name 'The embedded outpost serves this provider' }
  else {
    Add-AkAction $actions 'update' 'outpost' $ov.Outpost.Name "Assign '$slug' to the embedded outpost"
    if (-not $WhatIf) {
      $now = @(Get-AuthentikList $Conn '/outposts/instances/' | Where-Object { [string]$_.pk -eq $ov.Outpost.Pk })[0]
      $null = Invoke-AuthentikApi $Conn PATCH "/outposts/instances/$($ov.Outpost.Pk)/" @{ providers = @(@($now.providers | ForEach-Object { [int]$_ }) + [int]$prov.pk | Select-Object -Unique) }
      Set-AkActionDone $actions
    }
  }
  return [pscustomobject]@{ Actions = $actions.ToArray(); Slug = $slug; ProviderPk = $provPk; ApplicationPk = [string](Get-AkProp $app 'pk' ''); Access = $access }
}

# Removing protection: the outpost stops serving the application's provider. The authentik application, its provider
# and its access rules stay in authentik (they are authentik's; protecting again reuses them). -DeleteObjects also
# deletes the application and the provider created for it.
function Remove-AuthentikAppProtection {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$Service, [switch]$DeleteObjects, [switch]$WhatIf)
  $actions = New-AkActionList
  $slug = "$($script:Prefix)$($Service.ToLowerInvariant())"
  $ov = Get-AuthentikOverview $Conn
  $prov = @(Get-AuthentikList $Conn "/providers/proxy/?name=$([Uri]::EscapeDataString($slug))" | Where-Object { [string]$_.name -eq $slug })[0]
  if ($prov -and $ov.Outpost -and $ov.Outpost.Providers -contains [int]$prov.pk) {
    Add-AkAction $actions 'update' 'outpost' $ov.Outpost.Name "Unassign '$slug' from the embedded outpost"
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/outposts/instances/$($ov.Outpost.Pk)/" @{ providers = @($ov.Outpost.Providers | Where-Object { $_ -ne [int]$prov.pk }) }; Set-AkActionDone $actions }
  }
  if ($DeleteObjects) {
    $app = $null; try { $app = Invoke-AuthentikApi $Conn GET "/core/applications/$slug/" } catch { }
    if ($app) { Add-AkAction $actions 'delete' 'application' $slug "Delete application '$slug' (and its access rules)"; if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn DELETE "/core/applications/$slug/"; Set-AkActionDone $actions } }
    if ($prov) { Add-AkAction $actions 'delete' 'proxy provider' $slug "Delete proxy provider '$slug'"; if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn DELETE "/providers/proxy/$($prov.pk)/"; Set-AkActionDone $actions } }
  } elseif ($prov) { Add-AkAction $actions 'none' 'application' $slug "Application '$slug', its provider and its access rules stay in authentik (protecting again reuses them)" }
  if (-not $actions.Count) { Add-AkAction $actions 'none' 'application' $slug 'Nothing to change in authentik' }
  return $actions.ToArray()
}

# --- Verification -------------------------------------------------------------------------------------------------------

# Asks authentik to start a Google sign-in (as a browser on the public hostname would) and checks the redirect to
# Google: client ID, redirect URI and scopes. Nothing is sent to Google and no account is touched.
function Test-AuthentikGoogleRedirect {
  param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$PublicHost, [string]$Slug = 'google', [string]$ExpectClientId = '')
  $r = Invoke-AkHttp -Url "$($BaseUrl.TrimEnd('/'))/source/oauth/login/$Slug/" -Headers @{ Host = $PublicHost; 'X-Forwarded-Proto' = 'https' }
  $out = [ordered]@{ ok = $false; status = $r.Status; location = ''; clientId = ''; redirectUri = ''; scopes = @(); message = '' }
  if ($r.Status -notin 301, 302 -or $r.Location -notmatch '^https://accounts\.google\.com/') {
    $out.message = $(if ($r.Status -eq 404) { "authentik has no source '$Slug'." } elseif ($r.Status -eq 0) { "authentik did not answer: $($r.Error)" } else { "Expected a redirect to accounts.google.com, got HTTP $($r.Status)." })
    return [pscustomobject]$out
  }
  $q = @{}
  foreach ($pair in ([Uri]$r.Location).Query.TrimStart('?').Split('&')) { $kv = $pair.Split('=', 2); if ($kv.Count -eq 2) { $q[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } }
  $out.location = 'https://accounts.google.com/...'
  $out.clientId = [string]$q['client_id']; $out.redirectUri = [string]$q['redirect_uri']; $out.scopes = @(([string]$q['scope']).Split(' ') | Where-Object { $_ })
  $want = "https://$PublicHost/source/oauth/callback/$Slug/"
  $problems = @()
  if ($out.redirectUri -ne $want) { $problems += "authentik sends the redirect URI '$($out.redirectUri)', expected '$want' (check AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS and the public hostname)." }
  if ($ExpectClientId -and $out.clientId -ne $ExpectClientId) { $problems += 'authentik uses a different client ID than the one saved here.' }
  $out.ok = -not $problems.Count
  $out.message = $(if ($problems.Count) { $problems -join ' ' } else { "authentik redirects to Google with the expected client ID and redirect URI $want." })
  return [pscustomobject]$out
}

# Real Google sign-ins through this source after $Since: users with a Google connection whose last login is newer.
function Get-AuthentikSourceLogins {
  param([Parameter(Mandatory = $true)]$Conn, [string]$Slug = 'google', [datetime]$Since = [datetime]::MinValue)
  $conns = @(Get-AuthentikList $Conn "/sources/user_connections/oauth/?source__slug=$Slug")
  $out = @()
  foreach ($c in $conns) {
    $u = $null; try { $u = Invoke-AuthentikApi $Conn GET "/core/users/$($c.user)/" } catch { continue }
    $last = $null; if ($u.last_login) { $last = [datetime]::Parse([string]$u.last_login, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    if ($last -and $last.ToUniversalTime() -ge $Since.ToUniversalTime()) { $out += [pscustomobject]@{ Username = [string]$u.username; Email = [string]$u.email; LastLogin = $last.ToString('s'); IsSuperuser = [bool]$u.is_superuser } }
  }
  return $out
}

# Waits until the embedded outpost knows the application's hostname (it reloads its providers a few seconds after a
# change). Asks the ForwardAuth endpoint directly, as Traefik will: a redirect to sign in means the provider is
# loaded, 404 means not yet. Called before the Traefik route switches to ForwardAuth, so there is no window in which
# the application answers 404.
function Wait-AuthentikOutpost {
  param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Hostname, [int]$Seconds = 60)
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    $r = Invoke-AkHttp -Url "$($BaseUrl.TrimEnd('/'))/outpost.goauthentik.io/auth/traefik" -TimeoutMs 8000 -Headers @{ 'X-Forwarded-Host' = $Hostname; 'X-Forwarded-Proto' = 'https'; 'X-Forwarded-Uri' = '/'; 'X-Forwarded-Method' = 'GET' }
    if ($r.Status -in 302, 401) { return [pscustomobject]@{ Ready = $true; Status = $r.Status } }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return [pscustomobject]@{ Ready = $false; Status = $r.Status }
}

# Evidence that a person actually passed ForwardAuth for an application: authentik's own "authorize_application"
# events (written when the outpost authorizes a signed-in user) for that application after $Since.
function Get-AuthentikAppAccessEvidence {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$ApplicationPk, [datetime]$Since = [datetime]::MinValue)
  $want = $ApplicationPk.Replace('-', '').ToLowerInvariant()
  $d = Invoke-AuthentikApi $Conn GET "/events/events/?action=authorize_application&ordering=-created&page_size=50"
  foreach ($e in @($d.results)) {
    $app = Get-AkProp (Get-AkProp $e 'context' $null) 'authorized_application' $null
    if (-not $app -or ([string](Get-AkProp $app 'pk' '')).Replace('-', '').ToLowerInvariant() -ne $want) { continue }
    $at = [datetime]::Parse([string]$e.created, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if ($at.ToUniversalTime() -lt $Since.ToUniversalTime()) { continue }
    return [pscustomobject]@{ Username = [string](Get-AkProp $e.user 'username' ''); At = $at.ToLocalTime().ToString('s') }
  }
  return $null
}

# One unauthenticated request through Traefik to a protected hostname, following same-host redirects up to 8 times.
# Expected: a redirect into authentik (the outpost's /outpost.goauthentik.io/start or authentik's authorize URL).
# Reports 'auth' (authentication required), 'open' (the app answered without sign-in), 'loop', or 'failed'.
function Test-ForwardAuthChallenge {
  param([Parameter(Mandatory = $true)][int]$TraefikPort, [Parameter(Mandatory = $true)][string]$Hostname, [string]$AuthHostname = '', [string]$Path = '/', [int]$HostPort = 0)
  # Tests that publish on a non-standard port send Host with that port, as a browser would.
  $sfx = $(if ($HostPort) { ":$HostPort" } else { '' })
  $seen = @{}
  $url = "http://127.0.0.1:$TraefikPort$Path"; $hostHeader = "$Hostname$sfx"
  $chain = @()
  for ($i = 0; $i -lt 8; $i++) {
    $key = "$hostHeader$(([Uri]$url).PathAndQuery)"
    if ($seen.ContainsKey($key)) { return [pscustomobject]@{ State = 'loop'; Status = 0; Location = ''; Chain = $chain; Message = "Redirect loop: $key was requested twice. Check that the authentik hostname itself is not protected and that the outpost route exists." } }
    $seen[$key] = $true
    $r = Invoke-AkHttp -Url $url -Headers @{ Host = $hostHeader } -TimeoutMs 10000
    $chain += "$hostHeader$(([Uri]$url).PathAndQuery) -> $($r.Status)"
    if ($r.Status -in 301, 302, 303, 307, 308) {
      $loc = New-Object Uri ([Uri]"http://$hostHeader"), $r.Location
      if ($loc.AbsolutePath -match '^/(application/o/authorize|flows/-/default/authentication|if/flow/)' -or ($AuthHostname -and $loc.Host -eq $AuthHostname)) {
        # ForwardAuth works; whether the browser can follow the redirect is a separate question (the outpost's
        # authentik_host): a loopback, LAN or Docker-only address, or another host than the sign-in page, fails.
        $b = Test-BrowserEndpoint $loc.AbsoluteUri $AuthHostname -AllowHttp
        if (-not $b.ok -or ($AuthHostname -and $loc.Host -ne $AuthHostname)) {
          $why = $(if ($b.problems.Count) { $b.problems[0] } else { "The sign-in page is $AuthHostname." })
          return [pscustomobject]@{ State = 'misrouted'; Status = $r.Status; Location = (Get-RedactedUrl $loc.AbsoluteUri); Chain = $chain; Message = "ForwardAuth works, but browsers are sent to $($loc.Scheme)://$($loc.Authority) to sign in. $why Set authentik's embedded outpost to the public sign-in address." }
        }
        return [pscustomobject]@{ State = 'auth'; Status = $r.Status; Location = (Get-RedactedUrl $loc.AbsoluteUri); Chain = $chain; Message = "Sign-in required: redirected to $($loc.Host)$($loc.AbsolutePath)." }
      }
      if ($loc.Host -ne $Hostname -and $loc.Host -ne $AuthHostname) { return [pscustomobject]@{ State = 'failed'; Status = $r.Status; Location = $loc.AbsoluteUri; Chain = $chain; Message = "Unexpected redirect to $($loc.Host)." } }
      $hostHeader = $loc.Authority; $url = "http://127.0.0.1:$TraefikPort$($loc.PathAndQuery)"
      continue
    }
    if ($r.Status -in 401, 403) { return [pscustomobject]@{ State = 'auth'; Status = $r.Status; Location = ''; Chain = $chain; Message = "Sign-in required (HTTP $($r.Status))." } }
    if ($r.Status -ge 200 -and $r.Status -lt 300) { return [pscustomobject]@{ State = 'open'; Status = $r.Status; Location = ''; Chain = $chain; Message = 'The application answered without asking anyone to sign in.' } }
    if ($r.Status -eq 0) { return [pscustomobject]@{ State = 'failed'; Status = 0; Location = ''; Chain = $chain; Message = "Traefik did not answer: $($r.Error)" } }
    $hint = $(if ($r.Status -eq 500) { ' Traefik could not reach authentik (fails closed).' } elseif ($r.Status -eq 404) { ' No route, or authentik does not know this hostname (provider not assigned to the outpost?).' } else { '' })
    return [pscustomobject]@{ State = 'failed'; Status = $r.Status; Location = ''; Chain = $chain; Message = "HTTP $($r.Status).$hint" }
  }
  return [pscustomobject]@{ State = 'loop'; Status = 0; Location = ''; Chain = $chain; Message = 'More than 8 redirects without reaching a sign-in page.' }
}

Export-ModuleMember -Function Invoke-AkHttp, Get-AuthentikHealth, New-AuthentikConnection, Invoke-AuthentikApi, Get-AuthentikList, Test-AuthentikToken, Test-AuthentikCredential, Get-AuthentikOverview,
  Get-GoogleOAuthSettings, ConvertFrom-GoogleClientJson, Test-GoogleClientId, Test-GoogleClientSecret, ConvertTo-OwnerEmail, New-OwnerEnrollmentExpression, Get-AuthentikOwnersGroupName, Get-AuthentikGroup, Sync-AuthentikOwnersGroup,
  Sync-AuthentikOutpost, Sync-AuthentikGoogleSource, Find-AuthentikOwner, Get-AuthentikOwnerCheck, Set-AuthentikUserInternal, Complete-AuthentikOwner, Sync-AuthentikLoginPage, Restore-AuthentikLoginPage, Sync-AuthentikAppProtection, Remove-AuthentikAppProtection, Test-AuthentikGoogleRedirect,
  Get-AuthentikSourceLogins, Get-AuthentikAppAccessEvidence, Wait-AuthentikOutpost, Test-ForwardAuthChallenge
