# Identity & Access diagnostics: pure functions (no I/O) shared by the web UI, the service planner and the tests.
#
#   Browser -> Cloudflare (DNS, HTTPS, tunnel) -> Traefik -> authentik ForwardAuth -> application
#
# - Which authentication gateways sit in front of an application (authentik, Cloudflare Access, both, the
#   application's own login, nothing), derived from the service definition and the Cloudflare Access applications
#   that really cover its hostname (exact, path-scoped, wildcard or multi-domain).
# - One diagnosis per application, so a stopped container is reported as an availability problem and never as an
#   authentication failure, and a redundant Cloudflare login is reported as such.
# - Classification of redirect hops (which component asked for authentication) and URL redaction: diagnostics never
#   carry query strings, fragments, cookies or authorization codes.

Set-StrictMode -Version 2.0

# Whether a fact was supplied at all (an empty list is a fact; a missing key means "not checked").
function Test-DiagHas($Object, [string]$Name) {
  if ($null -eq $Object) { return $false }
  if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
  return [bool]$Object.PSObject.Properties[$Name]
}

function Get-DiagProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# --- Cloudflare Access coverage ----------------------------------------------------------------------------------------

# Whether one Access pattern ("host", "host/path", "*.zone", "*-suffix.zone", "*.zone/path") covers a hostname. A
# path-scoped pattern covers only part of the site; it still shows Cloudflare's login for those paths.
function Test-AccessPatternCovers([string]$Pattern, [string]$Hostname) {
  if (-not $Pattern -or -not $Hostname) { return $false }
  $p = $Pattern.Trim().ToLowerInvariant() -replace '^https?://', ''
  $h = $Hostname.Trim().ToLowerInvariant().TrimEnd('.')
  $hostPart = ($p -split '/', 2)[0]
  if ($hostPart -eq $h) { return $true }
  if ($hostPart.Contains('*')) {
    # Cloudflare wildcards match within one label set: "*.example.com" covers "a.example.com" and "a.b.example.com",
    # not "example.com"; "*-x.example.com" covers "a-x.example.com".
    $rx = '^' + ([regex]::Escape($hostPart) -replace '\\\*', '[a-z0-9.-]+') + '$'
    return [bool]($h -match $rx)
  }
  return $false
}

# Every Access application that covers $Hostname. $ManagedAppId is the id this tool recorded when it created one.
function Get-AccessCoverage {
  param($Apps, [string]$Hostname, [string]$ManagedAppId = '')
  $out = @()
  foreach ($a in @($Apps)) {
    if ($null -eq $a) { continue }
    $patterns = @()
    $d = [string](Get-DiagProp $a 'domain' '')
    if ($d) { $patterns += $d }
    foreach ($x in @(Get-DiagProp $a 'self_hosted_domains' @())) { if ($x) { $patterns += [string]$x } }
    foreach ($x in @(Get-DiagProp $a 'destinations' @())) { $u = [string](Get-DiagProp $x 'uri' ''); if ($u) { $patterns += $u } }
    $hits = @($patterns | Select-Object -Unique | Where-Object { Test-AccessPatternCovers $_ $Hostname })
    if (-not $hits.Count) { continue }
    $type = [string](Get-DiagProp $a 'type' 'self_hosted')
    if ($type -notin 'self_hosted', '') { continue }   # SaaS/SSH/VNC/app-launcher entries do not sit in front of a website
    $id = [string](Get-DiagProp $a 'id' '')
    $wild = [bool]@($hits | Where-Object { $_ -match '\*' }).Count
    $pathOnly = -not @($hits | Where-Object { ($_ -replace '^https?://', '') -notmatch '/.' }).Count
    $out += [pscustomobject][ordered]@{
      Id = $id; Name = [string](Get-DiagProp $a 'name' ''); Pattern = $hits[0]; Wildcard = $wild; PathOnly = $pathOnly
      CreatedByTool = [bool]($ManagedAppId -and $id -eq $ManagedAppId)
      Policies = @(@(Get-DiagProp $a 'policies' @()) | ForEach-Object { [string](Get-DiagProp $_ 'decision' '') })
    }
  }
  return $out
}

# --- Authentication modes ---------------------------------------------------------------------------------------------

# One explicit mode per service:
#   authentik          authentik ForwardAuth (the normal, reusable path)
#   cloudflare-access  Cloudflare Access only
#   layered            authentik AND Cloudflare Access, chosen explicitly (two interactive sign-ins)
#   native             no gateway; the application's own login (declared)
#   none               no gateway and nothing declared (warned about when published)
function Get-ServiceAuthMode($Service) {
  $auth = Get-DiagProp $Service 'auth' $null
  $provider = [string](Get-DiagProp $auth 'provider' '')
  $cf = Get-DiagProp $Service 'cloudflare' $null
  $access = [bool](Get-DiagProp $cf 'access' $false)
  $layered = [bool](Get-DiagProp $auth 'layered' $false)
  if ($provider -eq 'authentik' -and $access) { return $(if ($layered) { 'layered' } else { 'layered-unconfirmed' }) }
  if ($provider -eq 'authentik') { return 'authentik' }
  if ($access) { return 'cloudflare-access' }
  if ($provider -eq 'native') { return 'native' }
  return 'none'
}

function Get-AuthModeLabel([string]$Mode) {
  switch ($Mode) {
    'authentik' { 'authentik ForwardAuth' }
    'cloudflare-access' { 'Cloudflare Access' }
    'layered' { 'Layered: Cloudflare Access + authentik' }
    'layered-unconfirmed' { 'Cloudflare Access + authentik (not confirmed as layered)' }
    'native' { "Application's own login" }
    default { 'No external sign-in' }
  }
}

# --- Per-application diagnosis ------------------------------------------------------------------------------------------

# $F: facts gathered by the caller (all optional):
#   hostname, enabled, publish, authMode, container (running|exited|created|paused|missing|host|unknown),
#   router (enabled|disabled|missing|unknown), forwardAuthConfigured, forwardAuthLoaded, authentikApp (bool|$null),
#   providerExternalHost, providerMode, outpostAssigned (bool|$null), expectedExternalHost, challenge (auth|open|
#   misrouted|failed|...|''), backend (ok|unreachable|''), accessCoverage (Get-AccessCoverage), oauthError ('' or text)
# Returns the most important problem first, plus every warning. States:
#   missing-hostname, disabled, missing-route, missing-container, stopped, backend-unreachable, missing-protection,
#   provider-error, outpost-error, forwardauth-error, redundant-access, access-conflict, oauth-error, unpublished,
#   healthy, healthy-public-unprotected, healthy-access
function Get-AppAccessDiagnosis($F) {
  $hostname = [string](Get-DiagProp $F 'hostname' '')
  $mode = [string](Get-DiagProp $F 'authMode' 'none')
  $publish = [bool](Get-DiagProp $F 'publish' $false)
  $container = [string](Get-DiagProp $F 'container' 'unknown')
  $router = [string](Get-DiagProp $F 'router' 'unknown')
  $coverage = @(Get-DiagProp $F 'accessCoverage' @())
  $warnings = New-Object System.Collections.ArrayList
  $add = { param($state, $tone, $label, $message, $fix) $null = $warnings.Add([pscustomobject][ordered]@{ state = $state; tone = $tone; label = $label; message = $message; fix = $fix }) }
  $protectedByAuthentik = $mode -in 'authentik', 'layered', 'layered-unconfirmed'

  if (-not $hostname) { & $add 'missing-hostname' 'err' 'No hostname' 'The service has no hostname, so it cannot be opened or protected.' 'Give it a hostname on the Services page.' }
  if (-not [bool](Get-DiagProp $F 'enabled' $true)) { & $add 'disabled' 'neutral' 'Disabled' 'The route is turned off in DTC.' 'Enable it on the Services page.' }
  elseif ($router -eq 'missing') { & $add 'missing-route' 'err' 'Route missing' 'Traefik has not loaded a route for this service.' 'Open the service on the Services page and save it again, or run Repair on the Routing page.' }
  elseif ($router -eq 'disabled') { & $add 'missing-route' 'err' 'Route has errors' 'Traefik loaded the route but disabled it (a middleware or service is missing).' 'See the Traefik dashboard or the Routing page for the error.' }

  # Availability is its own concern: reported after authentication, never as an authentication failure.
  switch ($container) {
    'missing' { & $add 'missing-container' 'err' 'Container missing' 'The target container does not exist. After signing in, visitors get "Bad gateway".' 'Install or start the application, or point the service at the right container.' }
    { $_ -in 'exited', 'created', 'dead', 'paused', 'restarting' } { & $add 'stopped' 'warn' 'Stopped' "The container is $container. After signing in, visitors get ""Bad gateway"" (an availability error, not a sign-in problem)." 'Start the application on the Installed apps page.' }
  }
  if ([string](Get-DiagProp $F 'backend' '') -eq 'unreachable' -and $container -notin 'missing', 'exited', 'created', 'dead', 'paused', 'restarting') { & $add 'backend-unreachable' 'err' 'Backend unreachable' 'Traefik cannot reach the application address.' 'Check the target address and port on the Services page.' }

  if ($protectedByAuthentik) {
    $akApp = Get-DiagProp $F 'authentikApp' $null
    $ext = [string](Get-DiagProp $F 'providerExternalHost' '')
    $want = [string](Get-DiagProp $F 'expectedExternalHost' '')
    $pmode = [string](Get-DiagProp $F 'providerMode' '')
    if ($akApp -eq $false) { & $add 'provider-error' 'err' 'authentik application missing' "authentik has no application/provider for $hostname; ForwardAuth cannot authorize anyone." 'Protect it again on this page (nothing is created twice).' }
    elseif ($ext -and $want -and $ext.TrimEnd('/') -ne $want.TrimEnd('/')) { & $add 'provider-error' 'err' 'Provider address wrong' "The authentik provider expects $ext but the application is served at $want, so sign-in returns to the wrong address." 'Protect it again on this page to correct the provider.' }
    elseif ($pmode -and $pmode -notin 'forward_single', 'forward_domain') { & $add 'provider-error' 'err' 'Provider mode wrong' "The authentik provider is in '$pmode' mode, not ForwardAuth." 'Protect it again on this page.' }
    if ((Get-DiagProp $F 'outpostAssigned' $null) -eq $false) { & $add 'outpost-error' 'err' 'Not on the outpost' "authentik's embedded outpost does not serve this provider, so Traefik's ForwardAuth check answers 404." 'Protect it again on this page (assigns it to the embedded outpost).' }
    if ((Get-DiagProp $F 'forwardAuthConfigured' $true) -eq $false) { & $add 'missing-protection' 'err' 'ForwardAuth not configured' 'The service says authentik, but its route does not ask authentik.' 'Protect it again on this page.' }
    elseif ((Get-DiagProp $F 'forwardAuthLoaded' $true) -eq $false) { & $add 'forwardauth-error' 'err' 'ForwardAuth not loaded' 'Traefik has not loaded the authentik middleware for this route.' 'See the Routing page.' }
    $ch = [string](Get-DiagProp $F 'challenge' '')
    if ($ch -eq 'open') { & $add 'forwardauth-error' 'err' 'Not enforced' 'An anonymous request reached the application without signing in.' 'Protect it again on this page.' }
    elseif ($ch -eq 'misrouted') { & $add 'forwardauth-error' 'err' 'Sign-in address wrong' 'Anonymous visitors are sent to a sign-in address that is not the public authentik address.' 'Point the embedded outpost at the public address (Identity & Access, authentik step).' }
    elseif ($ch -eq 'failed') { & $add 'forwardauth-error' 'err' 'ForwardAuth failing' 'authentik did not answer the ForwardAuth check; Traefik refuses the request (fails closed).' 'Check that authentik is running.' }
  }

  # Cloudflare Access in front of an authentik application: a second, different interactive login.
  $live = @($coverage | Where-Object { -not $_.PathOnly })
  if ($protectedByAuthentik -and $publish -and $live.Count -and $mode -ne 'layered') {
    $byTool = @($live | Where-Object { $_.CreatedByTool })
    $names = (@($live | ForEach-Object { "'$($_.Name)'" + $(if ($_.Wildcard) { " (wildcard $($_.Pattern))" } else { '' }) }) -join ', ')
    if ($byTool.Count) { & $add 'redundant-access' 'warn' 'Redundant Cloudflare login' "Cloudflare Access application $names asks for its own login (email code) before authentik. It was created by DTC and is no longer wanted: authentik protects this application." 'Remove the redundant Cloudflare Access (preview first).' }
    else { & $add 'access-conflict' 'warn' 'Cloudflare Access also applies' "Cloudflare Access application $names (not created by DTC) covers this hostname, so visitors sign in twice." 'Narrow or remove it in Cloudflare Zero Trust > Access > Applications, or mark the service as layered on purpose.' }
  }
  if ($mode -eq 'cloudflare-access' -and $publish -and -not $live.Count -and (Test-DiagHas $F 'accessCoverage')) {
    & $add 'access-missing' 'err' 'Cloudflare Access missing' 'The service expects Cloudflare Access, but no Access application covers the hostname: it is public without a sign-in.' 'Save the service again on the Services page to recreate it.'
  }
  if ($mode -in 'none' -and $publish) { & $add 'missing-protection' 'warn' 'Public without sign-in' 'Anyone on the Internet can open it; only the application''s own login (if any) protects it.' 'Protect it with authentik on this page, or mark it as using its own login.' }
  $oauth = [string](Get-DiagProp $F 'oauthError' '')
  if ($oauth) { & $add 'oauth-error' 'err' 'Sign-in configuration' $oauth 'See the Google step of Identity & Access.' }

  $order = @('missing-hostname', 'missing-route', 'provider-error', 'outpost-error', 'missing-protection', 'forwardauth-error', 'oauth-error', 'access-missing', 'redundant-access', 'access-conflict', 'missing-container', 'backend-unreachable', 'stopped', 'disabled')
  $first = $null
  foreach ($o in $order) { $first = @($warnings | Where-Object { $_.state -eq $o })[0]; if ($first) { break } }
  if (-not $first) {
    $state = $(if (-not $publish) { 'unpublished' } elseif ($protectedByAuthentik) { 'healthy' } elseif ($mode -eq 'cloudflare-access') { 'healthy-access' } else { 'healthy-public-unprotected' })
    $label = @{ unpublished = 'Local only (not published)'; healthy = 'Healthy, protected'; 'healthy-access' = 'Healthy (Cloudflare Access)'; 'healthy-public-unprotected' = 'Healthy (own login)' }[$state]
    $first = [pscustomobject][ordered]@{ state = $state; tone = $(if ($state -eq 'unpublished') { 'neutral' } else { 'ok' }); label = $label; message = ''; fix = '' }
  }
  return [pscustomobject][ordered]@{ state = $first.state; tone = $first.tone; label = $first.label; message = $first.message; fix = $first.fix; problems = @($warnings) }
}

# --- Redirect tracing ----------------------------------------------------------------------------------------------------

# A URL without query, fragment or user info: diagnostics never carry codes, states, tokens or cookies.
function ConvertTo-SafeUrl([string]$Url) {
  if (-not $Url) { return '' }
  $u = $null
  if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return (($Url -split '[?#]', 2)[0]) }
  $port = $(if ($u.IsDefaultPort) { '' } else { ":$($u.Port)" })
  return "$($u.Scheme)://$($u.Host)$port$($u.AbsolutePath)"
}

# Which component a response comes from / which one asked for authentication.
function Get-RedirectHopKind {
  param([int]$Status, [string]$Location = '', [string]$AuthHostname = '', [hashtable]$Headers = @{}, [string]$RequestHost = '')
  $loc = $Location.ToLowerInvariant()
  $mitigated = [string]$(if ($Headers.ContainsKey('cf-mitigated')) { $Headers['cf-mitigated'] } else { '' })
  if ($mitigated -eq 'challenge') { return 'cloudflare-challenge' }
  if ($Status -in 301, 302, 303, 307, 308) {
    if ($loc -match '\.cloudflareaccess\.com/' -or $loc -match '/cdn-cgi/access/login') { return 'cloudflare-access' }
    if ($loc -match '^https?://accounts\.google\.com/') { return 'google' }
    if ($AuthHostname -and $loc -match ('^https?://' + [regex]::Escape($AuthHostname.ToLowerInvariant()) + '(:\d+)?/')) { return 'authentik' }
    if ($loc -match '/application/o/authorize/' -or $loc -match '/outpost\.goauthentik\.io/') { return 'authentik' }
    if ($loc -match '^https?://(127\.0\.0\.1|localhost)(:\d+)?/') { return 'local-address' }
    return 'redirect'
  }
  if ($Status -eq 530 -or $Status -eq 1033) { return 'tunnel-error' }
  if ($Status -in 502, 503, 504) { return 'backend-error' }
  if ($Status -eq 404) { return 'not-routed' }
  if ($Status -eq 403 -and $mitigated) { return 'cloudflare-challenge' }
  if ($Status -ge 500) { return 'error' }
  if ($Status -ge 200 -and $Status -lt 300) { return 'app' }
  if ($Status -eq 0) { return 'unreachable' }
  return 'other'
}

# Plain-language verdict for a traced chain of hops (each: kind, status, url).
function Get-RedirectVerdict($Hops, [string]$Mode = '') {
  $kinds = @(@($Hops) | ForEach-Object { [string](Get-DiagProp $_ 'kind' '') })
  $first = $(if ($kinds.Count) { $kinds[0] } else { 'unreachable' })
  switch ($first) {
    'cloudflare-access' { $msg = 'Cloudflare Access answers first and asks for its own login (email code or its identity providers), before Traefik and authentik see the request.'; if ($Mode -in 'authentik') { $msg += ' This is a redundant second login: authentik already protects this application.' }; return [pscustomobject]@{ component = 'Cloudflare Access'; message = $msg } }
    'cloudflare-challenge' { return [pscustomobject]@{ component = 'Cloudflare security challenge'; message = 'Cloudflare shows a security challenge (WAF / bot rule), not a login.' } }
    'authentik' { return [pscustomobject]@{ component = 'authentik'; message = 'Traefik asked authentik (ForwardAuth); an anonymous visitor is sent to the central authentik sign-in. With an existing authentik session this step is passed without a prompt.' } }
    'local-address' { return [pscustomobject]@{ component = 'misconfiguration'; message = 'The visitor is sent to an address that only works on this PC (127.0.0.1/localhost). Google sign-in fails there with redirect_uri_mismatch.' } }
    'google' { return [pscustomobject]@{ component = 'Google'; message = 'The request goes to Google directly.' } }
    'tunnel-error' { return [pscustomobject]@{ component = 'Cloudflare Tunnel'; message = 'Cloudflare cannot reach the tunnel (530): cloudflared is down or the hostname has no tunnel route.' } }
    'backend-error' { return [pscustomobject]@{ component = 'application'; message = 'The request passed authentication but the application did not answer (Bad gateway): it is stopped or unreachable. This is an availability problem, not a sign-in problem.' } }
    'not-routed' { return [pscustomobject]@{ component = 'Traefik'; message = 'Traefik has no route for this hostname (404).' } }
    'app' { return [pscustomobject]@{ component = 'application'; message = $(if ($Mode -in 'authentik', 'layered', 'cloudflare-access') { 'The application answered an anonymous request without any sign-in: protection is NOT enforced.' } else { 'The application answers directly (no external sign-in).' }) } }
    'unreachable' { return [pscustomobject]@{ component = 'network'; message = 'The hostname did not answer (DNS or network).' } }
    default { return [pscustomobject]@{ component = 'unknown'; message = "First answer: $first." } }
  }
}

# Browser-facing authentik base: the public address when there is one, else the local one. The local address works
# only on this PC and Google sign-in fails there (its callback is not registered with Google).
function Get-AuthentikBrowserBase([string]$PublicUrl, [string]$LocalUrl) {
  if ($PublicUrl) { return [pscustomobject]@{ Base = $PublicUrl.TrimEnd('/'); Public = $true } }
  if ($LocalUrl) { return [pscustomobject]@{ Base = $LocalUrl.TrimEnd('/'); Public = $false } }
  return [pscustomobject]@{ Base = ''; Public = $false }
}

# The address an application is opened at in a browser: its public https URL when published, else http on the local
# Traefik entry point (local-only routes are reached through the PC's Traefik port with the hostname).
function Get-ServiceOpenUrl($Service, [int]$HttpPort = 80) {
  $h = [string]@(Get-DiagProp $Service 'hostnames' @())[0]
  if (-not $h) { return '' }
  $prefix = [string](Get-DiagProp $Service 'pathPrefix' '')
  $path = $(if ($prefix) { '/' + $prefix.Trim('/') + '/' } else { '/' })
  $cf = Get-DiagProp $Service 'cloudflare' $null
  if ([bool](Get-DiagProp $cf 'publish' $false)) { return "https://$h$path" }
  return $(if ($HttpPort -eq 80) { "http://$h$path" } else { "http://${h}:$HttpPort$path" })
}

Export-ModuleMember -Function Test-AccessPatternCovers, Get-AccessCoverage, Get-ServiceAuthMode, Get-AuthModeLabel, Get-AppAccessDiagnosis, ConvertTo-SafeUrl, Get-RedirectHopKind, Get-RedirectVerdict, Get-AuthentikBrowserBase, Get-ServiceOpenUrl
