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
  if (-not $AppName) { $AppName = "authentik - $(if ($Domain) { $Domain } else { $u.Host })" }
  $parts = $u.Host.Split('.')
  $authorized = $(if ($parts.Count -ge 2) { ($parts[($parts.Count - 2)..($parts.Count - 1)]) -join '.' } else { $u.Host })
  return [pscustomobject]@{
    AppName = $AppName; ClientType = 'Web application'; ClientName = "$AppName (sign-in)"; Slug = $Slug
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

# Sets the embedded outpost's authentik_host to the public URL, so sign-in redirects send browsers to
# https://auth.<domain>/ (not to an internal address).
function Sync-AuthentikOutpost {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$PublicUrl, [switch]$WhatIf)
  $actions = New-AkActionList
  $ov = Get-AuthentikOverview $Conn
  if (-not $ov.Outpost) { throw 'authentik has no embedded outpost (it is created on first start). Wait until authentik is ready.' }
  $want = $PublicUrl.TrimEnd('/') + '/'
  if ($ov.Outpost.AuthentikHost.TrimEnd('/') -eq $want.TrimEnd('/')) { Add-AkAction $actions 'none' 'outpost' $ov.Outpost.Name "Embedded outpost already uses $want" }
  else {
    Add-AkAction $actions 'update' 'outpost' $ov.Outpost.Name "Embedded outpost: send browsers to $want" "authentik_host: '$($ov.Outpost.AuthentikHost)' -> '$want'"
    if (-not $WhatIf) {
      $cfg = $ov.Outpost.Config
      $cfg.authentik_host = $want
      $null = Invoke-AuthentikApi $Conn PATCH "/outposts/instances/$($ov.Outpost.Pk)/" @{ config = $cfg }
      Set-AkActionDone $actions
    }
  }
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
# Desired: Slug, ClientId, ClientSecret (optional when the source exists), OwnerEmail, OwnerVerified (bool).
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
  if (-not $flow.PSObject.Properties['planned']) {
    $have = @(Get-AuthentikList $Conn "/flows/bindings/?target=$($flow.pk)&ordering=order")
    if (-not $have.Count) {
      foreach ($b in @(Get-AuthentikList $Conn "/flows/bindings/?target=$($ov.Flows['default-source-enrollment'].Pk)&ordering=order")) {
        Add-AkAction $actions 'create' 'flow stage' $b.stage_obj.name "Bind stage '$($b.stage_obj.name)' (order $($b.order))"
        if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST '/flows/bindings/' @{ target = $flow.pk; stage = $b.stage; order = [int]$b.order; evaluate_on_plan = [bool]$b.evaluate_on_plan; re_evaluate_policies = [bool]$b.re_evaluate_policies }; Set-AkActionDone $actions }
      }
    } else { Add-AkAction $actions 'none' 'flow stage' $fslug "The enrollment flow has its stages ($($have.Count))" }
  } else { Add-AkAction $actions 'create' 'flow stage' $fslug 'Bind the default enrollment stages (prompt, write user, log in)' }
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
        LastLogin = $(if ($u.last_login) { ([datetime]::Parse([string]$u.last_login, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString('s') } else { '' })
        Groups = @(@(Get-AkProp $u 'groups_obj' @()) | ForEach-Object { [string]$_.name }) }
    }
  }
  return $out
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

  # Embedded outpost.
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
        return [pscustomobject]@{ State = 'auth'; Status = $r.Status; Location = $loc.GetLeftPart([UriPartial]::Path); Chain = $chain; Message = "Sign-in required: redirected to $($loc.Host)$($loc.AbsolutePath)." }
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
  Get-GoogleOAuthSettings, Test-GoogleClientId, Test-GoogleClientSecret, ConvertTo-OwnerEmail, New-OwnerEnrollmentExpression, Get-AuthentikOwnersGroupName, Get-AuthentikGroup,
  Sync-AuthentikOutpost, Sync-AuthentikGoogleSource, Find-AuthentikOwner, Complete-AuthentikOwner, Sync-AuthentikAppProtection, Remove-AuthentikAppProtection, Test-AuthentikGoogleRedirect,
  Get-AuthentikSourceLogins, Get-AuthentikAppAccessEvidence, Wait-AuthentikOutpost, Test-ForwardAuthChallenge
