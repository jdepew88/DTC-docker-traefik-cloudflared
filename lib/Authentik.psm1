#requires -version 5.1
# authentik integration: health and first-setup detection, a small API client (/api/v3, token auth) and idempotent
# "sync" functions for the Google OAuth source, the embedded outpost and per-application ForwardAuth protection.
#
# Every sync function has a dry-run mode (-WhatIf) that returns the actions it would take without changing anything;
# the web UI shows that as the preview and applies the same function without -WhatIf after approval. Objects this
# manager creates carry the "dm-" prefix (slugs/names) and are recorded in config\identity.json, so they can be found
# again, updated in place (never duplicated) and removed without touching objects created by hand.
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

# Normalized, validated allow-lists. Returns Emails, Domains and Errors.
function ConvertTo-AccessList {
  param($Emails = @(), $Domains = @())
  $errors = @()
  $e = @(@($Emails) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
  $d = @(@($Domains) | ForEach-Object { ([string]$_).Trim().TrimStart('@').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
  foreach ($x in $e) { if ($x -notmatch $script:EmailPattern) { $errors += "'$x' is not a valid email address." } }
  foreach ($x in $d) { if ($x -notmatch $script:DomainPattern) { $errors += "'$x' is not a valid domain (for example example.com)." } }
  if ($e.Count -gt 200 -or $d.Count -gt 50) { $errors += 'At most 200 email addresses and 50 domains.' }
  return [pscustomobject]@{ Emails = $e; Domains = $d; Errors = $errors }
}

# Python literal list of validated strings (the patterns above exclude quotes and backslashes).
function ConvertTo-PyList([string[]]$Items) { return '[' + ((@($Items) | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']' }

# Expression policy: who may open an application (by their authentik email, which users cannot change themselves while
# "Allow users to change email" is off - checked before this policy is used).
function New-AppAccessExpression([string[]]$Emails, [string[]]$Domains) {
  return @(
    '# Managed by the Deployment Manager: edits are replaced on the next change from the manager.',
    "allowed_emails = $(ConvertTo-PyList $Emails)",
    "allowed_domains = $(ConvertTo-PyList $Domains)",
    'email = (request.user.email or "").strip().lower()',
    'if not email or not request.user.is_active:',
    '    return False',
    'if email in allowed_emails:',
    '    return True',
    'return email.rsplit("@", 1)[-1] in allowed_domains'
  ) -join "`n"
}

# Expression policy on the Google enrollment flow: only verified Google addresses on the allow-list may create an account.
# oauth_userinfo is what Google returned (verified_email from the userinfo endpoint, email_verified from OpenID Connect).
function New-EnrollmentExpression([string[]]$Emails, [string[]]$Domains) {
  return @(
    '# Managed by the Deployment Manager: who may create an account by signing in with Google.',
    "allowed_emails = $(ConvertTo-PyList $Emails)",
    "allowed_domains = $(ConvertTo-PyList $Domains)",
    'info = request.context.get("oauth_userinfo") or {}',
    'email = str(info.get("email") or "").strip().lower()',
    'verified = info.get("verified_email", info.get("email_verified", False)) in (True, "true", "True")',
    'if not email or not verified:',
    '    ak_message("Your Google address is not verified.")',
    '    return False',
    'if email in allowed_emails or email.rsplit("@", 1)[-1] in allowed_domains:',
    '    return True',
    'ak_message("This Google account is not allowed to create an account here. Ask the administrator to add it.")',
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

# --- Google source ------------------------------------------------------------------------------------------------------

# Desired: Slug, Name, ClientId, ClientSecret (optional when the source exists: the stored secret is kept), Signup
# ('allowlist' | 'open' | 'existing'), Emails, Domains, Matching ('identifier' | 'email_deny'), ShowOnLogin.
function Sync-AuthentikGoogleSource {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Desired, [switch]$WhatIf)
  $actions = New-AkActionList
  $slug = [string]$Desired.Slug
  if ($slug -notmatch $script:SlugPattern) { throw "Invalid source slug '$slug'." }
  if (-not (Test-GoogleClientId $Desired.ClientId)) { throw 'The client ID does not look like a Google OAuth client ID (ending in .apps.googleusercontent.com).' }
  $secret = [string](Get-AkProp $Desired 'ClientSecret' '')
  if ($secret -and -not (Test-GoogleClientSecret $secret)) { throw 'The client secret contains unexpected characters. Copy it again from Google Cloud.' }
  $ov = Get-AuthentikOverview $Conn
  if ($ov.MissingFlows.Count) { throw "authentik is not fully initialized yet (missing flows: $($ov.MissingFlows -join ', ')). Wait a minute and try again." }
  $existing = @(Get-AuthentikList $Conn "/sources/oauth/?slug=$slug")[0]
  if ($existing -and [string]$existing.provider_type -ne 'google') { throw "A source with the slug '$slug' already exists and is not a Google source. Choose another slug." }
  if (-not $existing -and -not $secret) { throw 'Enter the client secret.' }
  $list = ConvertTo-AccessList $Desired.Emails $Desired.Domains
  if ($list.Errors.Count) { throw ($list.Errors -join ' ') }
  $signup = [string]$Desired.Signup
  if ($signup -notin 'allowlist', 'open', 'existing') { throw "Unknown sign-up mode '$signup'." }
  if ($signup -eq 'allowlist' -and -not ($list.Emails.Count + $list.Domains.Count)) { throw 'Add at least one email address or domain that may create an account, or choose another sign-up option.' }
  $matching = $(if ([string](Get-AkProp $Desired 'Matching' 'identifier') -eq 'email_deny') { 'email_deny' } else { 'identifier' })

  # Enrollment flow.
  $enrollPk = $null
  switch ($signup) {
    'open' { $enrollPk = $ov.Flows['default-source-enrollment'].Pk; Add-AkAction $actions 'none' 'flow' 'default-source-enrollment' 'New Google users enroll through the default source enrollment flow (they get no application access until you grant it)' }
    'existing' { Add-AkAction $actions 'none' 'flow' '(none)' 'No enrollment: only users who connected Google to their existing authentik account can sign in with Google' }
    'allowlist' {
      $fslug = "$($script:Prefix)$slug-enrollment"
      $flow = $(if ($ov.Flows.ContainsKey($fslug)) { Invoke-AuthentikApi $Conn GET "/flows/instances/$fslug/" } else { $null })
      $flow = Sync-AkObject -Conn $Conn -Actions $actions -Object 'flow' -Name $fslug -Existing $flow -CollectionPath '/flows/instances/' -ItemPath "/flows/instances/$fslug/" -WhatIf:$WhatIf -Desired @{
        name = 'Google enrollment (Deployment Manager)'; slug = $fslug; title = 'Create your account'; designation = 'enrollment'; authentication = 'none'; denied_action = 'message'; policy_engine_mode = 'any' }
      # Same stages, same order as the default source enrollment flow (prompt, write user, log in): the stages are shared.
      $def = $ov.Flows['default-source-enrollment'].Pk
      $want = @(Get-AuthentikList $Conn "/flows/bindings/?target=$def&ordering=order")
      $have = @(); if (-not $flow.PSObject.Properties['planned']) { $have = @(Get-AuthentikList $Conn "/flows/bindings/?target=$($flow.pk)&ordering=order") }
      foreach ($b in $want) {
        if (@($have | Where-Object { [string]$_.stage -eq [string]$b.stage }).Count) { Add-AkAction $actions 'none' 'flow stage' $b.stage_obj.name "Stage '$($b.stage_obj.name)' is bound"; continue }
        Add-AkAction $actions 'create' 'flow stage' $b.stage_obj.name "Bind stage '$($b.stage_obj.name)' (order $($b.order))"
        if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST '/flows/bindings/' @{ target = $flow.pk; stage = $b.stage; order = [int]$b.order; evaluate_on_plan = [bool]$b.evaluate_on_plan; re_evaluate_policies = [bool]$b.re_evaluate_policies }; Set-AkActionDone $actions }
      }
      $pname = "$($script:Prefix)$slug-enrollment-allowlist"
      $pol = @(Get-AuthentikList $Conn "/policies/expression/?name=$([Uri]::EscapeDataString($pname))")[0]
      $pol = Sync-AkObject -Conn $Conn -Actions $actions -Object 'policy' -Name $pname -Existing $pol -CollectionPath '/policies/expression/' -ItemPath "/policies/expression/$(Get-AkProp $pol 'pk' '')/" -WhatIf:$WhatIf -Desired @{
        name = $pname; expression = (New-EnrollmentExpression $list.Emails $list.Domains); execution_logging = $false }
      $flowPbm = [string](Get-AkProp $flow 'policybindingmodel_ptr_id' $flow.pk)
      $bound = @(); if (-not $flow.PSObject.Properties['planned'] -and -not $pol.PSObject.Properties['planned']) { $bound = @(Get-AuthentikList $Conn "/policies/bindings/?target=$flowPbm" | Where-Object { [string]$_.policy -eq [string]$pol.pk }) }
      if ($bound.Count) { Add-AkAction $actions 'none' 'policy binding' $pname 'The allow-list is bound to the enrollment flow' }
      else {
        Add-AkAction $actions 'create' 'policy binding' $pname 'Bind the allow-list to the enrollment flow'
        if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST '/policies/bindings/' @{ policy = $pol.pk; target = $flowPbm; order = 0; enabled = $true; negate = $false; timeout = 30; failure_result = $false }; Set-AkActionDone $actions }
      }
      $enrollPk = [string]$flow.pk
    }
  }

  # The source itself.
  $desiredSource = @{
    name = [string](Get-AkProp $Desired 'Name' 'Google'); slug = $slug; enabled = $true; promoted = $true; provider_type = 'google'
    consumer_key = ([string]$Desired.ClientId).Trim(); authentication_flow = $ov.Flows['default-source-authentication'].Pk; enrollment_flow = $enrollPk
    user_matching_mode = $matching; policy_engine_mode = 'any'
  }
  $secretFields = @()
  if ($secret) { $desiredSource['consumer_secret'] = $secret.Trim(); $secretFields = @('consumer_secret') }
  $src = Sync-AkObject -Conn $Conn -Actions $actions -Object 'Google source' -Name $slug -Existing $existing -CollectionPath '/sources/oauth/' -ItemPath "/sources/oauth/$slug/" -Desired $desiredSource -SecretFields $secretFields -WhatIf:$WhatIf

  # Login page button.
  $stage = $ov.LoginStage
  $show = [bool](Get-AkProp $Desired 'ShowOnLogin' $true)
  if (-not $stage) { Add-AkAction $actions 'none' 'login page' '(identification stage)' 'The login page''s identification stage was not found: add the Google button in authentik by hand (Flows > default-authentication-flow > identification stage > Sources).' }
  else {
    $srcPk = [string](Get-AkProp $src 'pk' '')
    $has = $stage.Sources -contains $srcPk
    if ($show -and -not $has) {
      Add-AkAction $actions 'update' 'login page' $stage.Name "Show 'Sign in with Google' on the login page (stage '$($stage.Name)')"
      if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/stages/identification/$($stage.Pk)/" @{ sources = @(@($stage.Sources) + $srcPk) }; Set-AkActionDone $actions }
    } elseif (-not $show -and $has) {
      Add-AkAction $actions 'update' 'login page' $stage.Name "Hide the Google button on the login page (stage '$($stage.Name)')"
      if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/stages/identification/$($stage.Pk)/" @{ sources = @($stage.Sources | Where-Object { $_ -ne $srcPk }) }; Set-AkActionDone $actions }
    } else { Add-AkAction $actions 'none' 'login page' $stage.Name $(if ($show) { 'The login page shows the Google button' } else { 'The login page does not show the Google button' }) }
  }
  return [pscustomobject]@{ Actions = $actions.ToArray(); SourcePk = [string](Get-AkProp $src 'pk' ''); EnrollmentFlow = $enrollPk }
}

# --- Application protection (ForwardAuth, single application) -----------------------------------------------------------

# Desired: Service (registry name), DisplayName, Hostname, Emails, Domains, Groups (existing group names), CreateGroup.
# Creates or updates: an optional group, an expression policy (emails/domains), a proxy provider in forward_single mode,
# the application with its bindings, and assigns the provider to the embedded outpost. At least one binding is required:
# an application without bindings is open to every authentik user.
function Sync-AuthentikAppProtection {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Desired, $Known = $null, [switch]$WhatIf)
  $actions = New-AkActionList
  $svc = ([string]$Desired.Service).ToLowerInvariant()
  $slug = "$($script:Prefix)$svc"
  if ($slug -notmatch $script:SlugPattern) { throw "Invalid application name '$svc'." }
  $hostname = ([string]$Desired.Hostname).ToLowerInvariant()
  if ($hostname -notmatch $script:DomainPattern) { throw "Invalid hostname '$hostname'." }
  $display = [string](Get-AkProp $Desired 'DisplayName' $svc)
  $list = ConvertTo-AccessList (Get-AkProp $Desired 'Emails' @()) (Get-AkProp $Desired 'Domains' @())
  if ($list.Errors.Count) { throw ($list.Errors -join ' ') }
  $groupNames = @(@(Get-AkProp $Desired 'Groups' @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
  $createGroup = [bool](Get-AkProp $Desired 'CreateGroup' $false)
  $ownGroup = "$svc users"
  if ($createGroup -and $groupNames -notcontains $ownGroup) { $groupNames += $ownGroup }
  if (-not ($list.Emails.Count + $list.Domains.Count + $groupNames.Count)) { throw 'Choose who may open this application: email addresses, domains or groups. Without any, authentik would let every signed-in user in.' }
  $ov = Get-AuthentikOverview $Conn
  if ($ov.MissingFlows.Count) { throw "authentik is not fully initialized yet (missing flows: $($ov.MissingFlows -join ', '))." }
  if (-not $ov.Outpost) { throw 'authentik has no embedded outpost yet.' }
  if (($list.Emails.Count + $list.Domains.Count) -and $ov.Settings.ChangeEmail) {
    throw 'authentik lets users change their own email address (System > Settings > "Allow users to change email"), so an email allow-list could be bypassed. Turn that setting off, or use groups only.'
  }

  # Groups (existing ones are reused; only the app's own group is created).
  $groups = @()
  foreach ($gn in $groupNames) {
    $g = @(Get-AuthentikList $Conn "/core/groups/?name=$([Uri]::EscapeDataString($gn))" | Where-Object { [string]$_.name -eq $gn })[0]
    if (-not $g -and $gn -ne $ownGroup) { throw "authentik has no group named '$gn'." }
    if ($g -and [bool](Get-AkProp $g 'is_superuser' $false) -and $gn -eq $ownGroup) { throw "The group '$gn' grants authentik administrator rights; choose another name." }
    $g = Sync-AkObject -Conn $Conn -Actions $actions -Object 'group' -Name $gn -Existing $g -CollectionPath '/core/groups/' -ItemPath "/core/groups/$(Get-AkProp $g 'pk' '')/" -Desired @{ name = $gn; is_superuser = $false } -NoUpdate -WhatIf:$WhatIf
    $groups += $g
  }

  # Email/domain policy.
  $pname = "$slug-access"
  $pol = @(Get-AuthentikList $Conn "/policies/expression/?name=$([Uri]::EscapeDataString($pname))")[0]
  if ($list.Emails.Count + $list.Domains.Count) {
    $pol = Sync-AkObject -Conn $Conn -Actions $actions -Object 'policy' -Name $pname -Existing $pol -CollectionPath '/policies/expression/' -ItemPath "/policies/expression/$(Get-AkProp $pol 'pk' '')/" -WhatIf:$WhatIf -Desired @{
      name = $pname; expression = (New-AppAccessExpression $list.Emails $list.Domains); execution_logging = $false }
  }

  # Proxy provider (single application ForwardAuth).
  $prov = @(Get-AuthentikList $Conn "/providers/proxy/?name=$([Uri]::EscapeDataString($slug))" | Where-Object { [string]$_.name -eq $slug })[0]
  # The public address of the application (https via Cloudflare); tests use a local http address with a port.
  $external = [string](Get-AkProp $Desired 'ExternalUrl' "https://$hostname")
  if ($external -notmatch '^https?://[a-z0-9.-]+(:\d{1,5})?$') { throw "Invalid application address '$external'." }
  $prov = Sync-AkObject -Conn $Conn -Actions $actions -Object 'proxy provider' -Name $slug -Existing $prov -CollectionPath '/providers/proxy/' -ItemPath "/providers/proxy/$(Get-AkProp $prov 'pk' '')/" -WhatIf:$WhatIf -Desired @{
    name = $slug; mode = 'forward_single'; external_host = $external
    authorization_flow = $ov.Flows['default-provider-authorization-implicit-consent'].Pk; invalidation_flow = $ov.Flows['default-provider-invalidation-flow'].Pk }

  # Application.
  $app = $null; try { $app = Invoke-AuthentikApi $Conn GET "/core/applications/$slug/" } catch { if ($_.Exception.Data['Status'] -ne 404) { throw } }
  $provPk = $(if ($prov.PSObject.Properties['planned']) { $null } else { [int]$prov.pk })
  $appDesired = @{ name = $display; slug = $slug; meta_launch_url = "$external/"; policy_engine_mode = 'any'; meta_description = 'Protected by authentik ForwardAuth (Deployment Manager).' }
  if ($null -ne $provPk) { $appDesired['provider'] = $provPk }
  $app = Sync-AkObject -Conn $Conn -Actions $actions -Object 'application' -Name $slug -Existing $app -CollectionPath '/core/applications/' -ItemPath "/core/applications/$slug/" -Desired $appDesired -WhatIf:$WhatIf

  # Bindings: one per group and one for the email policy. Bindings created earlier by this manager that are no longer
  # wanted are removed; bindings added by hand in authentik are left alone.
  $target = [string](Get-AkProp $app 'pbm_uuid' $app.pk)
  $have = @(); if (-not $app.PSObject.Properties['planned']) { $have = @(Get-AuthentikList $Conn "/policies/bindings/?target=$target") }
  $order = 0; $keep = @()
  foreach ($g in $groups) {
    $order++
    $b = @($have | Where-Object { [string](Get-AkProp $_ 'group' '') -eq [string]$g.pk })[0]
    if ($b) { $keep += [string]$b.pk; Add-AkAction $actions 'none' 'binding' "group $($g.name)" "Group '$($g.name)' may open it"; continue }
    Add-AkAction $actions 'create' 'binding' "group $($g.name)" "Allow group '$($g.name)'"
    if (-not $WhatIf) { $nb = Invoke-AuthentikApi $Conn POST '/policies/bindings/' @{ group = $g.pk; target = $target; order = $order; enabled = $true; negate = $false; timeout = 30 }; $keep += [string]$nb.pk; Set-AkActionDone $actions }
  }
  if ($list.Emails.Count + $list.Domains.Count) {
    $order++
    $b = @($have | Where-Object { [string](Get-AkProp $_ 'policy' '') -eq [string]$pol.pk })[0]
    if ($b) { $keep += [string]$b.pk; Add-AkAction $actions 'none' 'binding' $pname 'The email/domain policy is bound' }
    else {
      Add-AkAction $actions 'create' 'binding' $pname "Allow $(@($list.Emails).Count) email address(es) and $(@($list.Domains).Count) domain(s)"
      if (-not $WhatIf) { $nb = Invoke-AuthentikApi $Conn POST '/policies/bindings/' @{ policy = $pol.pk; target = $target; order = $order; enabled = $true; negate = $false; timeout = 30; failure_result = $false }; $keep += [string]$nb.pk; Set-AkActionDone $actions }
    }
  }
  $knownBindings = @(@(Get-AkProp $Known 'bindings' @()) | ForEach-Object { [string]$_ })
  foreach ($b in $have) {
    if ($keep -contains [string]$b.pk -or $knownBindings -notcontains [string]$b.pk) { continue }
    Add-AkAction $actions 'delete' 'binding' ([string]$b.pk) 'Remove an access rule this manager created earlier'
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn DELETE "/policies/bindings/$($b.pk)/"; Set-AkActionDone $actions }
  }
  if ($pol -and -not ($list.Emails.Count + $list.Domains.Count) -and -not $pol.PSObject.Properties['planned']) {
    Add-AkAction $actions 'delete' 'policy' $pname 'Remove the email/domain policy (no longer used)'
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn DELETE "/policies/expression/$($pol.pk)/"; Set-AkActionDone $actions }
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
  return [pscustomobject]@{
    Actions = $actions.ToArray(); Slug = $slug; ProviderPk = $provPk; ApplicationPk = [string](Get-AkProp $app 'pk' ''); PolicyPk = [string](Get-AkProp $pol 'pk' '')
    Bindings = $keep; Groups = @($groups | ForEach-Object { [string]$_.name }); Emails = $list.Emails; Domains = $list.Domains
  }
}

# Removes what Sync-AuthentikAppProtection created for a service: outpost assignment, application, provider and policy.
# Groups are kept (they may hold users); objects not named dm-<service> are never touched.
function Remove-AuthentikAppProtection {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$Service, [switch]$WhatIf)
  $actions = New-AkActionList
  $slug = "$($script:Prefix)$($Service.ToLowerInvariant())"
  $ov = Get-AuthentikOverview $Conn
  $prov = @(Get-AuthentikList $Conn "/providers/proxy/?name=$([Uri]::EscapeDataString($slug))" | Where-Object { [string]$_.name -eq $slug })[0]
  if ($prov -and $ov.Outpost -and $ov.Outpost.Providers -contains [int]$prov.pk) {
    Add-AkAction $actions 'update' 'outpost' $ov.Outpost.Name "Unassign '$slug' from the embedded outpost"
    if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn PATCH "/outposts/instances/$($ov.Outpost.Pk)/" @{ providers = @($ov.Outpost.Providers | Where-Object { $_ -ne [int]$prov.pk }) }; Set-AkActionDone $actions }
  }
  $app = $null; try { $app = Invoke-AuthentikApi $Conn GET "/core/applications/$slug/" } catch { }
  if ($app) { Add-AkAction $actions 'delete' 'application' $slug "Delete application '$slug' (and its access rules)"; if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn DELETE "/core/applications/$slug/"; Set-AkActionDone $actions } }
  if ($prov) { Add-AkAction $actions 'delete' 'proxy provider' $slug "Delete proxy provider '$slug'"; if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn DELETE "/providers/proxy/$($prov.pk)/"; Set-AkActionDone $actions } }
  $pol = @(Get-AuthentikList $Conn "/policies/expression/?name=$([Uri]::EscapeDataString("$slug-access"))")[0]
  if ($pol) { Add-AkAction $actions 'delete' 'policy' "$slug-access" "Delete policy '$slug-access'"; if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn DELETE "/policies/expression/$($pol.pk)/"; Set-AkActionDone $actions } }
  if (-not $actions.Count) { Add-AkAction $actions 'none' 'application' $slug 'Nothing to remove in authentik' }
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

Export-ModuleMember -Function Invoke-AkHttp, Get-AuthentikHealth, New-AuthentikConnection, Invoke-AuthentikApi, Get-AuthentikList, Test-AuthentikToken, Get-AuthentikOverview,
  Get-GoogleOAuthSettings, Test-GoogleClientId, Test-GoogleClientSecret, ConvertTo-AccessList, New-AppAccessExpression, New-EnrollmentExpression,
  Sync-AuthentikOutpost, Sync-AuthentikGoogleSource, Sync-AuthentikAppProtection, Remove-AuthentikAppProtection, Test-AuthentikGoogleRedirect,
  Get-AuthentikSourceLogins, Get-AuthentikAppAccessEvidence, Wait-AuthentikOutpost, Test-ForwardAuthChallenge
