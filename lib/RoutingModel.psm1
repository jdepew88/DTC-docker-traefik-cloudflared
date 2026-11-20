Set-StrictMode -Version 2.0

# The request path of one published application as a model: browser endpoints (what a visitor's browser is sent to)
# versus internal endpoints (server-to-server inside Docker), each stage with a state and the evidence behind it.
# Pure: facts in, model out. webui.ps1 gathers the facts (Get-RoutingFacts); the Authentication & Routing page draws
# the model, and a future manual editor can reuse the same stages and checks.
#
# States: verified (a real request proved it), configured (configuration found, connectivity not tested), warning,
# failed, na. A configuration file or an API object alone never makes a stage "verified".

# --- Endpoints ------------------------------------------------------------------------------------------------------------

# Pure: what kind of address a URL is. public = a dotted DNS name a browser anywhere can resolve; loopback = the device
# itself (in a browser: the visitor's own computer; in a container: the container); private = LAN/link-local/CGNAT
# addresses; internal-name = a name only Docker's DNS or the LAN resolves (authentik-server, host.docker.internal,
# *.local); public-ip = a raw internet address (bypasses Cloudflare).
function Get-EndpointKind([string]$Url) {
  $u = $null
  if (-not $Url -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin 'http', 'https') {
    return [ordered]@{ url = $Url; scheme = ''; host = ''; port = 0; kind = 'invalid' }
  }
  $h = $u.Host.ToLowerInvariant().Trim('[', ']')
  $kind = $(
    if ($h -match '^(localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|::1|0\.0\.0\.0)$' -or $h.EndsWith('.localhost')) { 'loopback' }
    elseif ($h -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)' -or $h -match '^(f[cd][0-9a-f]{2}|fe80):') { 'private' }
    elseif ($h -match '^\d{1,3}(\.\d{1,3}){3}$' -or $h.Contains(':')) { 'public-ip' }
    elseif ($h -notmatch '\.' -or $h -match '\.(internal|local|lan|home|docker|localdomain|home\.arpa)$') { 'internal-name' }
    else { 'public' })
  return [ordered]@{ url = $Url; scheme = $u.Scheme; host = $h; port = $u.Port; kind = $kind }
}

# Pure: problems with an address that a browser is sent to (a redirect target, a sign-in page). ExpectedHost: the public
# host it should be. AllowHttp: disposable test setups without TLS.
function Test-BrowserEndpoint([string]$Url, [string]$ExpectedHost = '', [switch]$AllowHttp) {
  $e = Get-EndpointKind $Url
  $problems = New-Object System.Collections.ArrayList
  switch ($e.kind) {
    'invalid' { $null = $problems.Add("'$Url' is not an http(s) address.") }
    'loopback' { $null = $problems.Add("$($e.host) is a loopback address. In a browser it means the visitor's own device, so it only works on the PC that runs authentik and fails everywhere else (other devices, phones, outside your home).") }
    'private' { $null = $problems.Add("$($e.host) is a private (LAN) address. It only works inside your home network, not through Cloudflare.") }
    'internal-name' { $null = $problems.Add("$($e.host) is a name only Docker or your LAN can resolve. Browsers outside cannot find it; it belongs on the internal side (Traefik to authentik), not in a browser redirect.") }
    'public-ip' { $null = $problems.Add("$($e.host) is a raw IP address. It bypasses Cloudflare and its HTTPS certificate; use the public hostname.") }
  }
  if ($e.kind -ne 'invalid' -and $e.scheme -eq 'http' -and -not $AllowHttp) { $null = $problems.Add("$Url uses plain http. Cloudflare serves your hostnames over https; browsers should be sent to https.") }
  if ($ExpectedHost -and $e.host -and $e.host -ne $ExpectedHost.ToLowerInvariant() -and $e.kind -eq 'public') { $null = $problems.Add("Browsers are sent to $($e.host), but the public sign-in address is $ExpectedHost.") }
  return [ordered]@{ ok = ($problems.Count -eq 0); kind = $e.kind; host = $e.host; scheme = $e.scheme; problems = $problems.ToArray() }
}

# Pure: an address with query values removed (state, codes, client ids, tokens), keeping the ones that explain routing
# (redirect_uri, rd, next). Never returns cookies or fragments.
function Get-RedactedUrl([string]$Url) {
  if (-not $Url) { return '' }
  $u = $null
  if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return '[unparsable address]' }
  $base = $u.GetLeftPart([UriPartial]::Path)
  if (-not $u.Query) { return $base }
  $keep = @('redirect_uri', 'rd', 'next', 'redirect', 'redirect_url', 'response_type', 'scope')
  $parts = foreach ($p in $u.Query.TrimStart('?').Split('&')) {
    if (-not $p) { continue }
    $kv = $p.Split('=', 2); $k = [Uri]::UnescapeDataString($kv[0])
    if ($keep -contains $k.ToLowerInvariant() -and $kv.Count -eq 2) { "$k=$([Uri]::UnescapeDataString($kv[1].Replace('+', ' ')))" } else { "$k=[redacted]" }
  }
  return "${base}?$(@($parts) -join '&')"
}

# Pure: one query value of an address ('' when absent).
function Get-UrlQueryValue([string]$Url, [string]$Name) {
  $u = $null
  if (-not $Url -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or -not $u.Query) { return '' }
  foreach ($p in $u.Query.TrimStart('?').Split('&')) {
    $kv = $p.Split('=', 2)
    if ($kv.Count -eq 2 -and [Uri]::UnescapeDataString($kv[0]) -eq $Name) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
  }
  return ''
}

# Pure: the outpost's answer to an anonymous request (Location header) -> where the browser is sent and whether the
# original application address comes back afterwards.
function ConvertFrom-AuthRedirect([string]$Location, [string]$PublicAuthUrl, [string]$AppHostname, [switch]$AllowHttp) {
  $want = Get-EndpointKind $PublicAuthUrl
  $b = Test-BrowserEndpoint $Location $(if ($want.kind -eq 'public') { $want.host } else { '' }) -AllowHttp:$AllowHttp
  $back = Get-UrlQueryValue $Location 'redirect_uri'
  $backKind = Get-EndpointKind $back
  $backOk = [bool]($back -and $backKind.host -eq $AppHostname.ToLowerInvariant() -and ($backKind.scheme -eq 'https' -or $AllowHttp) -and $back -match '/outpost\.goauthentik\.io/callback')
  return [ordered]@{
    ok = $b.ok; host = $b.host; kind = $b.kind; problems = $b.problems; redacted = (Get-RedactedUrl $Location)
    returnUrl = $back; returnOk = $backOk
    returnProblem = $(if (-not $back) { 'The sign-in redirect carries no return address (redirect_uri).' } elseif (-not $backOk) { "After signing in, the browser would return to $back instead of https://$AppHostname/outpost.goauthentik.io/callback." } else { '' })
  }
}

# --- Model ------------------------------------------------------------------------------------------------------------

function Get-Fact($Object, [string]$Path, $Default = $null) {
  $cur = $Object
  foreach ($k in $Path.Split('.')) {
    if ($null -eq $cur) { return $Default }
    if ($cur -is [System.Collections.IDictionary]) { if ($cur.Contains($k)) { $cur = $cur[$k] } else { return $Default } }
    elseif ($cur.PSObject.Properties[$k]) { $cur = $cur.$k } else { return $Default }
  }
  if ($null -eq $cur) { return $Default }
  return $cur
}

function New-RoutingStage([string]$Id, [string]$Side, [string]$Title, [string]$State, [string]$Evidence, [string]$Summary, $Endpoints = @(), $Detail = $null, $Values = $null) {
  return [ordered]@{ id = $Id; side = $Side; title = $Title; state = $State; evidence = $Evidence; summary = $Summary; endpoints = @($Endpoints); detail = $Detail; values = $Values }
}
function New-RoutingEndpoint([string]$Label, [string]$Value, [string]$Audience) { return [ordered]@{ label = $Label; value = $Value; audience = $Audience } }
function New-RoutingDetail([string]$Endpoint, [string]$Expected, [string]$Actual, [string]$Explanation, [string]$Fix) {
  return [ordered]@{ endpoint = $Endpoint; expected = $Expected; actual = $Actual; explanation = $Explanation; fix = $Fix }
}

# ServiceHealth check (ok/auth/warning/failed/skipped) -> stage state. Only checks that made a real request prove
# connectivity; the others prove configuration at most.
function ConvertFrom-HealthState($Check, [bool]$ProvesConnectivity) {
  if (-not $Check) { return 'configured' }
  switch ([string]$Check.state) {
    'ok' { if ($ProvesConnectivity) { return 'verified' } else { return 'configured' } }
    'auth' { if ($ProvesConnectivity) { return 'verified' } else { return 'configured' } }
    'warning' { return 'warning' }
    'failed' { return 'failed' }
    default { return 'configured' }
  }
}

$script:StateRank = @{ failed = 4; warning = 3; configured = 2; verified = 1; na = 0 }
function Get-WorstState([string[]]$States) {
  $s = @($States | Where-Object { $_ -and $_ -ne 'na' })
  if (-not $s.Count) { return 'na' }
  return @($s | Sort-Object { - $script:StateRank[$_] })[0]
}

# Facts (see Get-RoutingFacts in webui.ps1):
#   service    @{ name; displayName; hostname; enabled; publish; access; authProvider; targetUrl; targetType; targetHost }
#   route      @{ fileExists; rule; middlewares[]; forwardAuthAddress; outpostRouter; backendUrl }
#   traefik    @{ apiOk; routers @{ name = status } }  or $null
#   identity   @{ publicUrl; authHostname; serverContainer; onProxyNetwork; googleConfigured; appVerifiedAt }
#   authentik  @{ connected; error; outpostName; outpostHost; outpostBrowserHost; providerFound; providerExternalHost;
#                 providerMode; providerAssigned; applicationFound; rules }  or $null
#   cloudflare @{ connected; tunnelName; accessAppName; accessAppByDtc }
#   networks   @{ proxy; traefik[]; authentik[]; backend[] }
#   health     Get-ServiceHealth result (checks) or $null; challenge  Test-ForwardAuthChallenge result or $null
#   publicAuth @{ status; location; error } or $null;  allowHttp (tests)
# The address browsers use for a protected application. Applications are served by the same Traefik entry point as
# the sign-in page, so they share the scheme and port of the public sign-in address (https://auth.<domain> in
# production: https://<host>, no port). authentik's outpost matches the forwarded Host, port included, against the
# provider's address, so the provider (Url) and every probe through Traefik (HostPort, HostHeader) must use the same one.
function Get-IdentityAppAddress([string]$PublicUrl, [string]$Hostname) {
  $scheme = 'https'; $port = 0
  $u = $null
  if ($PublicUrl -and [Uri]::TryCreate($PublicUrl, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -in 'http', 'https') {
    $scheme = $u.Scheme
    if (-not $u.IsDefaultPort) { $port = $u.Port }
  }
  $sfx = $(if ($port) { ":$port" } else { '' })
  return [pscustomobject]@{ Url = "${scheme}://$Hostname$sfx"; HostPort = $port; HostHeader = "$Hostname$sfx" }
}

function Get-RoutingModel {
  param([Parameter(Mandatory = $true)]$Facts)
  $svc = $Facts.service
  $h = [string]$svc.hostname
  $appUrl = (Get-IdentityAppAddress ([string](Get-Fact (Get-Fact $Facts 'identity' $null) 'publicUrl' '')) $h).Url
  $probed = [bool](Get-Fact $Facts 'health' $null)
  $allowHttp = [bool](Get-Fact $Facts 'allowHttp' $false)
  $chk = @{}; foreach ($c in @(Get-Fact $Facts 'health.checks' @())) { $chk[[string]$c.id] = $c }
  $ch = Get-Fact $Facts 'challenge' $null
  $ak = Get-Fact $Facts 'authentik' $null
  $id = Get-Fact $Facts 'identity' $null
  $route = Get-Fact $Facts 'route' $null
  $protectedByAk = ([string]$svc.authProvider -eq 'authentik')
  $publicUrl = [string](Get-Fact $id 'publicUrl' '')
  $authHost = [string](Get-Fact $id 'authHostname' '')
  $routers = Get-Fact $Facts 'traefik.routers' $null
  $routerName = "svc-$($svc.name)@file"
  $publicCheck = $chk['public']
  $publicPerformed = [bool]($publicCheck -and $publicCheck.performed)
  $publicMsg = [string](Get-Fact $publicCheck 'message' '')
  $accessSeen = $publicPerformed -and $publicMsg -match 'Cloudflare Access'
  $stages = New-Object System.Collections.ArrayList
  $add = { param($s) $null = $stages.Add($s) }

  # 1. Public address (browser).
  if (-not $svc.publish) {
    & $add (New-RoutingStage 'public-url' 'browser' 'Public address' 'na' 'none' "Local only: $h is not published through Cloudflare." @((New-RoutingEndpoint 'Address' "http://$h" 'browser')))
  } else {
    $st = $(if ($publicPerformed) { ConvertFrom-HealthState $publicCheck $true } else { 'configured' })
    if ($accessSeen -and -not $svc.access) { $st = 'warning'; $publicMsg = 'Cloudflare answers for this address, but with its own login page first (see Cloudflare Access below).' }
    & $add (New-RoutingStage 'public-url' 'browser' 'Public address' $st $(if ($publicPerformed) { 'connectivity' } else { 'configuration' }) $(if ($publicPerformed) { $publicMsg } else { "Published as $appUrl. Not tested yet (Run checks sends one GET from this PC)." }) @((New-RoutingEndpoint 'Browser opens' $appUrl 'browser')) `
      $(if ($st -in 'failed', 'warning') { New-RoutingDetail $appUrl 'An answer from Cloudflare (a sign-in redirect)' $publicMsg 'The public address did not behave as expected.' 'Look at the first failed stage below; it is usually the cause.' } else { $null }))
  }

  # 2. DNS.
  if ($svc.publish) {
    $d = $chk['dns']
    $st = $(if (-not $d) { 'configured' } elseif ($d.state -eq 'ok' -and $publicPerformed -and $publicCheck.state -ne 'failed') { 'verified' } else { ConvertFrom-HealthState $d $false })
    & $add (New-RoutingStage 'dns' 'browser' 'DNS (Cloudflare)' $st $(if ($st -eq 'verified') { 'connectivity' } else { 'configuration' }) $(if ($d) { [string]$d.message } else { "$h should be a proxied CNAME to the tunnel." }) @() `
      $(if ($st -eq 'failed') { New-RoutingDetail "DNS record $h" "CNAME to <tunnel id>.cfargotunnel.com, proxied" ([string]$d.message) 'Without this record the browser cannot find Cloudflare for this name.' 'Publish the service again from the Services page (the preview shows the DNS change).' } else { $null }))
  }

  # 3. Cloudflare Access.
  if ($svc.publish) {
    $appName = [string](Get-Fact $Facts 'cloudflare.accessAppName' '')
    $byDtc = [bool](Get-Fact $Facts 'cloudflare.accessAppByDtc' $false)
    $a = $chk['access']
    if ($svc.access) {
      $st = $(if ($accessSeen) { 'verified' } elseif ($a) { ConvertFrom-HealthState $a $false } else { 'configured' })
      & $add (New-RoutingStage 'access' 'browser' 'Cloudflare Access' $st $(if ($accessSeen) { 'connectivity' } else { 'configuration' }) 'Cloudflare asks for its own login first (by design for this service). With authentik as well, visitors sign in twice.' @())
    } elseif ($appName -or $accessSeen -or ($a -and $a.state -eq 'warning')) {
      $who = $(if ($byDtc) { 'created by this manager when Cloudflare Access was turned on, and not removed when it was turned off' } else { 'not created by this manager' })
      & $add (New-RoutingStage 'access' 'browser' 'Cloudflare Access' 'warning' $(if ($accessSeen) { 'connectivity' } else { 'configuration' }) `
        "Cloudflare shows its own login (Access application '$(if ($appName) { $appName } else { $h })') before the request reaches your network, although this service is set to use authentik only. This is the Cloudflare challenge visitors see." @() `
        (New-RoutingDetail $appUrl 'No Cloudflare login: the request goes straight through the tunnel to Traefik and authentik.' $(if ($accessSeen) { $publicMsg } else { "Access application '$appName' covers $h." }) "The Access application was $who. It is not an error in Traefik or authentik, but it adds a second login and can break returning from Google." "If authentik alone should protect $h, delete the Access application '$appName' (Cloudflare Zero Trust > Access > Applications). The manager does not remove Access applications without your explicit confirmation."))
    } else {
      & $add (New-RoutingStage 'access' 'browser' 'Cloudflare Access' 'na' 'none' $(if ($protectedByAk) { 'Not used: authentik is the login.' } else { 'Not used.' }) @())
    }
  }

  # 4. Tunnel.
  if ($svc.publish) {
    $t = $chk['tunnel']
    $reached = $publicPerformed -and -not $accessSeen -and $publicCheck.state -in 'ok', 'auth'
    $st = $(if ($t -and $t.state -eq 'failed') { 'failed' } elseif ($reached) { 'verified' } elseif ($t) { ConvertFrom-HealthState $t $false } else { 'configured' })
    & $add (New-RoutingStage 'tunnel' 'internal' "Cloudflare Tunnel$(if ($Facts.cloudflare.tunnelName) { " '$($Facts.cloudflare.tunnelName)'" })" $st $(if ($reached) { 'connectivity' } else { 'configuration' }) `
      $(if ($t) { [string]$t.message } else { 'Cloudflare sends the request through the tunnel to http://traefik:80.' }) @((New-RoutingEndpoint 'Tunnel origin' 'http://traefik:80' 'internal')) `
      $(if ($st -eq 'failed') { New-RoutingDetail "Tunnel route for $h" 'http://traefik:80' ([string]$t.message) 'cloudflared runs in its own container; it must forward to Traefik by its Docker name.' 'Publish the service again; the preview corrects the tunnel route.' } else { $null }))
  }

  # 5. Traefik router.
  $routerStatus = $(if ($routers -and $routers.Contains($routerName)) { [string]$routers[$routerName] } else { '' })
  $routerCheck = $chk['router']
  $chRouted = $ch -and $ch.Status -ne 0 -and -not ($ch.Status -eq 404 -and $ch.State -eq 'failed')
  $st = $(if (-not $route -or -not $route.fileExists) { 'failed' } elseif ($routerCheck -and $routerCheck.state -eq 'failed') { 'failed' } elseif ($chRouted) { 'verified' } elseif ($routerStatus -and $routerStatus -ne 'enabled') { 'failed' } else { 'configured' })
  & $add (New-RoutingStage 'router' 'internal' 'Traefik router' $st $(if ($st -eq 'verified') { 'connectivity' } else { 'configuration' }) `
    $(if (-not $route -or -not $route.fileExists) { "No route file svc-$($svc.name).yml." } elseif ($chRouted) { "A request for $h through Traefik reached router svc-$($svc.name) (HTTP $($ch.Status))." } else { "Router svc-$($svc.name): $([string]$route.rule)$(if ($routerStatus) { ", $routerStatus in Traefik" })." }) `
    @((New-RoutingEndpoint 'Rule' ([string](Get-Fact $route 'rule' '')) 'internal')) `
    $(if ($st -eq 'failed') { New-RoutingDetail "Traefik router svc-$($svc.name)" "Loaded and enabled, matching Host(``$h``)" $(if ($routerCheck) { [string]$routerCheck.message } else { "Route file present: $([bool](Get-Fact $route 'fileExists' $false)); status: $routerStatus" }) 'Traefik decides by hostname which application gets the request; without a loaded router it answers 404.' 'Open the service on the Services page and save it again (the preview validates the route).' } else { $null }) `
    ([ordered]@{ rule = [string](Get-Fact $route 'rule' ''); entryPoints = @(Get-Fact $route 'entryPoints' @()) }))

  # 6. Middleware chain.
  $mws = @(Get-Fact $route 'middlewares' @())
  $authMw = "svc-$($svc.name)-authentik"
  if ($protectedByAk) {
    $first = $(if ($mws.Count) { [string]$mws[0] } else { '' })
    $st = $(if ($mws -notcontains $authMw) { 'failed' } elseif ($first -ne $authMw) { 'warning' } elseif ($ch -and $ch.State -in 'auth', 'misrouted') { 'verified' } else { 'configured' })
    & $add (New-RoutingStage 'middlewares' 'internal' 'Middleware chain' $st $(if ($st -eq 'verified') { 'connectivity' } else { 'configuration' }) "In order: $(if ($mws.Count) { $mws -join ' -> ' } else { '(none)' })." @() `
      $(if ($st -in 'failed', 'warning') { New-RoutingDetail "Router svc-$($svc.name)" "$authMw first" ($mws -join ', ') 'The sign-in check must run before anything else touches the request.' 'Protect the application again on Identity & Access (it regenerates the route).' } else { $null }) ([ordered]@{ middlewares = $mws }))
  } else {
    & $add (New-RoutingStage 'middlewares' 'internal' 'Middleware chain' 'configured' 'configuration' "In order: $(if ($mws.Count) { $mws -join ' -> ' } else { '(none)' }). No sign-in middleware: the application is not protected by authentik." @() $null ([ordered]@{ middlewares = $mws }))
  }

  # 7. ForwardAuth endpoint (internal, Traefik -> authentik outpost).
  if ($protectedByAk) {
    $fa = [string](Get-Fact $route 'forwardAuthAddress' '')
    $faKind = Get-EndpointKind $fa
    $onNet = [bool](Get-Fact $id 'onProxyNetwork' $true)
    $st = 'configured'; $sum = "Traefik asks $fa for every request (server to server, inside Docker)."; $det = $null
    if (-not $fa) { $st = 'failed'; $sum = 'The route has no ForwardAuth address.' }
    elseif ($faKind.kind -eq 'loopback') { $st = 'failed'; $sum = "ForwardAuth points at $fa. Inside the Traefik container that is Traefik itself, not authentik."
      $det = New-RoutingDetail $fa "http://$((Get-Fact $id 'serverContainer' 'authentik-server')):9000/outpost.goauthentik.io/auth/traefik" $fa 'Containers have their own loopback address.' 'Protect the application again; the manager uses authentik''s container name on the shared network.' }
    elseif (-not $onNet) { $st = 'failed'; $sum = "authentik is not on the shared network '$($Facts.networks.proxy)', so Traefik cannot reach $fa." }
    elseif ($ch) {
      if ($ch.State -in 'auth', 'misrouted') { $st = 'verified'; $sum = "Traefik reached the authentik outpost at $fa; it answered for $h (HTTP $($ch.Status))." }
      elseif ($ch.State -eq 'open') { $st = 'failed'; $sum = 'The application answered without asking anyone to sign in: ForwardAuth is not enforced.'
        $det = New-RoutingDetail "GET http://$h/ through Traefik (anonymous)" 'A redirect to the sign-in page (or 401)' "HTTP $($ch.Status)" 'Traefik passed the request through without asking authentik.' 'Protect the application again on Identity & Access.' }
      else { $st = 'failed'; $sum = [string]$ch.Message
        $det = New-RoutingDetail "GET http://$h/ through Traefik (anonymous)" 'A redirect to the sign-in page (or 401)' "HTTP $($ch.Status) $(@($ch.Chain) -join ' ; ')" $(if ($ch.Status -eq 500) { 'Traefik could not get an answer from authentik and refused the request (fails closed, as intended).' } elseif ($ch.Status -eq 404) { 'authentik''s outpost does not know this hostname.' } else { 'The sign-in check did not behave as expected.' }) $(if ($ch.Status -eq 500) { "Check that $((Get-Fact $id 'serverContainer' 'authentik-server')) runs and is on '$($Facts.networks.proxy)'." } elseif ($ch.Status -eq 404) { 'Protect the application again (assigns the provider to the embedded outpost).' } else { 'Run the checks again; if it persists, protect the application again.' }) }
    }
    & $add (New-RoutingStage 'forwardauth' 'internal' 'ForwardAuth (authentik outpost)' $st $(if ($st -eq 'verified') { 'connectivity' } else { 'configuration' }) $sum @((New-RoutingEndpoint 'Internal endpoint' $fa 'internal')) $det)
  } else {
    & $add (New-RoutingStage 'forwardauth' 'internal' 'ForwardAuth (authentik outpost)' 'na' 'none' 'Not protected by authentik.' @())
  }

  # 8. authentik application / provider / outpost.
  if ($protectedByAk) {
    $st = 'configured'; $sum = ''; $det = $null
    if (-not $ak -or -not $ak.connected) { $st = 'configured'; $sum = "authentik objects not read$(if ($ak -and $ak.error) { ": $($ak.error)" } else { ' (the manager is not connected to authentik)' })." }
    else {
      $ext = [string]$ak.providerExternalHost
      $extOk = $ext.TrimEnd('/') -eq $appUrl -or ($allowHttp -and (Get-EndpointKind $ext).host -eq $h)
      if (-not $ak.providerFound) { $st = 'failed'; $sum = "No proxy provider dm-$($svc.name) in authentik." }
      elseif (-not $extOk) { $st = 'failed'; $sum = "Provider dm-$($svc.name) is set to $ext, not $appUrl."
        $det = New-RoutingDetail "Provider dm-$($svc.name) external host" $appUrl $ext 'authentik matches requests and builds the return address from this value.' 'Protect the application again; the manager corrects the provider.' }
      elseif (-not $ak.providerAssigned) { $st = 'failed'; $sum = "Provider dm-$($svc.name) is not assigned to '$($ak.outpostName)'; the outpost answers 404 for $h." }
      elseif (-not $ak.applicationFound) { $st = 'failed'; $sum = "No authentik application dm-$($svc.name)." }
      else {
        $rules = Get-Fact $ak 'rules' $null
        $sum = "Application dm-$($svc.name) -> provider dm-$($svc.name) ($ext, forward auth) -> '$($ak.outpostName)'. $(if ($null -eq $rules) { '' } elseif ([int]$rules -eq 0) { 'No access rule: everyone who signs in may open it.' } else { "$rules access rule(s) in authentik decide who may open it." })"
        if ([string](Get-Fact $id 'appVerifiedAt' '')) { $st = 'verified'; $sum += " Someone opened it through authentik on $($id.appVerifiedAt)." }
        elseif ($ch -and $ch.State -in 'auth', 'misrouted') { $st = 'verified'; $sum += ' The outpost recognised the hostname.' }
      }
    }
    & $add (New-RoutingStage 'authentik' 'internal' 'authentik application, provider and outpost' $st $(if ($st -eq 'verified') { 'connectivity' } else { 'configuration' }) $sum @() $det)
  }

  # 9. Browser redirect to the sign-in page (the address the outpost sends browsers to).
  if ($protectedByAk) {
    $configured = $(if ($ak -and $ak.connected) { if ([string]$ak.outpostBrowserHost) { [string]$ak.outpostBrowserHost } else { [string]$ak.outpostHost } } else { '' })
    $cfgTest = $(if ($configured) { Test-BrowserEndpoint $configured $authHost -AllowHttp:$allowHttp } else { $null })
    $st = 'configured'; $sum = ''; $det = $null; $actual = ''; $ev = 'configuration'
    if ($ch -and $ch.Location) {
      $r = ConvertFrom-AuthRedirect $ch.Location $publicUrl $h -AllowHttp:$allowHttp
      $actual = $r.redacted; $ev = 'connectivity'
      if ($r.ok) { $st = 'verified'; $sum = "Anonymous visitors are sent to $($r.host) (the public sign-in page)." }
      else { $u = [Uri]$ch.Location; $st = 'failed'; $sum = "Anonymous visitors are sent to $($u.Scheme)://$($u.Authority) to sign in. $($r.problems[0])" }
    } elseif ($cfgTest) {
      if ($cfgTest.ok) { $sum = "The outpost sends browsers to $configured (not tested yet)." } else { $st = 'failed'; $sum = "The outpost would send browsers to $configured`: $($cfgTest.problems[0])" }
      $actual = $configured
    } else { $sum = 'Where browsers are sent is known after Run checks (or when the manager is connected to authentik).' }
    if ($st -eq 'failed') {
      $det = New-RoutingDetail "Location header of an anonymous request for $h (made by the authentik outpost)" "$(if ($publicUrl) { $publicUrl.TrimEnd('/') } else { 'https://auth.<your domain>' })/application/o/authorize/..." $actual `
        "The outpost builds this redirect from its authentik_host setting ($(if ($configured) { $configured } else { 'unknown' })). It is the browser's address for the sign-in page, so it must be the public HTTPS hostname. Traefik keeps reaching authentik internally at its Docker name; that part is correct and separate." `
        $(if ($publicUrl) { "Set the embedded outpost's authentik_host to $($publicUrl.TrimEnd('/'))/ (Identity & Access > Public sign-in address > update the outpost, or authentik Admin > Outposts > Embedded Outpost). Protecting an application now does this automatically." } else { 'Set the public sign-in address first (Identity & Access > Public sign-in address).' })
    }
    & $add (New-RoutingStage 'redirect' 'browser' 'Redirect to the sign-in page' $st $ev $sum @((New-RoutingEndpoint 'Browser is sent to' $(if ($actual) { $actual } else { $configured }) 'browser'), (New-RoutingEndpoint 'Expected' $publicUrl 'browser')) $det)
  }

  # 10. Public sign-in page.
  if ($protectedByAk) {
    $pa = Get-Fact $Facts 'publicAuth' $null
    $pk = Test-BrowserEndpoint $publicUrl -AllowHttp:$allowHttp
    $st = 'configured'; $sum = "Browsers sign in at $publicUrl (not tested yet)."; $det = $null; $ev = 'configuration'
    if (-not $publicUrl) { $st = 'failed'; $sum = 'No public sign-in address is set.' }
    elseif (-not $pk.ok) { $st = 'failed'; $sum = $pk.problems[0] }
    elseif ($pa) {
      $ev = 'connectivity'
      if ($pa.status -in 200, 204) { $st = 'verified'; $sum = "$publicUrl answers through Cloudflare (authentik health: HTTP $($pa.status))." }
      elseif ($pa.status -ge 300 -and $pa.status -lt 400 -and [string]$pa.location -match 'cloudflareaccess\.com') { $st = 'warning'; $sum = 'Cloudflare Access is in front of the sign-in page: visitors log in twice and Google''s return to authentik must pass Access.' }
      else { $st = 'failed'; $sum = "$publicUrl did not answer as expected (HTTP $($pa.status)$(if ($pa.error) { ": $($pa.error)" }))."
        $det = New-RoutingDetail "GET $($publicUrl.TrimEnd('/'))/-/health/live/" 'HTTP 200 or 204 from authentik' "HTTP $($pa.status) $($pa.error)" 'The sign-in page itself must be reachable from the internet.' 'Check the authentik route on the Services page and that authentik runs.' }
    }
    & $add (New-RoutingStage 'signin' 'browser' 'Public sign-in page' $st $ev $sum @((New-RoutingEndpoint 'Browser endpoint' $publicUrl 'browser'), (New-RoutingEndpoint 'Internal endpoint (Traefik to authentik)' "http://$((Get-Fact $id 'serverContainer' 'authentik-server')):9000" 'internal')) $det)
  }

  # 11. Return to the application (callback through the outpost route).
  if ($protectedByAk) {
    $st = 'configured'; $sum = "After signing in, the browser returns to $appUrl/outpost.goauthentik.io/callback, then to the page it asked for."; $det = $null; $ev = 'configuration'
    $hasOutpostRoute = [bool](Get-Fact $route 'outpostRouter' $false)
    $outStatus = $(if ($routers -and $routers.Contains("svc-$($svc.name)-outpost@file")) { [string]$routers["svc-$($svc.name)-outpost@file"] } else { '' })
    if (-not $hasOutpostRoute) { $st = 'failed'; $sum = "No route for $h/outpost.goauthentik.io/: the return from the sign-in page would end in a 404." }
    elseif ($outStatus -and $outStatus -ne 'enabled') { $st = 'failed'; $sum = "Traefik reports the outpost route for $h as $outStatus." }
    elseif ($ch -and $ch.Location) {
      $r = ConvertFrom-AuthRedirect $ch.Location $publicUrl $h -AllowHttp:$allowHttp
      $ev = 'connectivity'
      if ($r.returnOk) { $st = 'verified'; $sum = "The sign-in redirect returns to $($r.returnUrl) (the original application address)." }
      else { $st = 'failed'; $sum = $r.returnProblem
        $det = New-RoutingDetail 'redirect_uri in the sign-in redirect' "$appUrl/outpost.goauthentik.io/callback?X-authentik-auth-callback=true" $r.returnUrl 'authentik sends the browser back to this address after signing in.' 'Protect the application again; the manager sets the provider to the public https address.' }
    }
    & $add (New-RoutingStage 'callback' 'browser' 'Return to the application' $st $ev $sum @((New-RoutingEndpoint 'Browser returns to' "$appUrl/outpost.goauthentik.io/callback" 'browser')) $det)
  }

  # 12. Traefik service and backend.
  $backendUrl = [string](Get-Fact $route 'backendUrl' $svc.targetUrl)
  $bk = $chk['backend']; $http = $chk['http']
  $st = $(if ($bk) { ConvertFrom-HealthState $bk ([bool]$bk.performed) } else { 'configured' })
  & $add (New-RoutingStage 'backend' 'internal' 'Application backend' $st $(if ($st -eq 'verified') { 'connectivity' } else { 'configuration' }) $(if ($bk) { [string]$bk.message } else { "Traefik forwards authorised requests to $backendUrl." }) @((New-RoutingEndpoint 'Internal endpoint' $backendUrl 'internal')) `
    $(if ($st -eq 'failed') { New-RoutingDetail $backendUrl 'An HTTP answer from the application, requested from inside the Traefik container' ([string]$bk.message) 'Traefik reaches applications by Docker name on the shared network, or through host.docker.internal for programs on Windows.' 'Open the service on the Services page; the backend finder suggests a working address.' } else { $null }))

  # 13. Docker networks.
  $nets = Get-Fact $Facts 'networks' $null
  $proxy = [string](Get-Fact $nets 'proxy' '')
  $tn = @(Get-Fact $nets 'traefik' @()); $an = @(Get-Fact $nets 'authentik' @()); $bn = Get-Fact $nets 'backend' $null
  $issues = @()
  if ($tn.Count -and $tn -notcontains $proxy) { $issues += "Traefik is not on '$proxy'." }
  if ($protectedByAk -and $an.Count -and $an -notcontains $proxy) { $issues += "authentik is not on '$proxy'." }
  if ($null -ne $bn -and @($bn).Count -and @($bn) -notcontains $proxy) { $issues += "$($svc.targetHost) is not on '$proxy'." }
  & $add (New-RoutingStage 'networks' 'internal' 'Docker networks' $(if ($issues.Count) { 'failed' } elseif ($tn.Count) { 'configured' } else { 'configured' }) 'configuration' `
    $(if ($issues.Count) { $issues -join ' ' } else { "Traefik, authentik$(if ($svc.targetType -eq 'docker') { " and $($svc.targetHost)" }) meet on '$proxy'. Only Traefik's port is published to this PC; authentik and the application are not exposed directly." }) @() `
    $(if ($issues.Count) { New-RoutingDetail "Network '$proxy'" 'Traefik, authentik and container backends attached' ($issues -join ' ') 'Containers only reach each other by name on a network they share.' 'Connect the container to the shared network (the Services page offers it for backends; authentik is attached by Identity & Access).' } else { $null }) `
    ([ordered]@{ proxy = $proxy; traefik = $tn; authentik = $an; backend = $bn }))

  $byId = @{}; foreach ($s in $stages) { $byId[$s.id] = $s }
  $pick = { param([string[]]$ids) Get-WorstState @($ids | Where-Object { $byId.ContainsKey($_) } | ForEach-Object { $byId[$_].state }) }
  $google = [bool](Get-Fact $id 'googleConfigured' $false)
  $journey = @(
    [ordered]@{ n = 1; id = 'open'; path = 'browser'; from = 'Browser'; to = 'Cloudflare'; title = 'You open the application'; text = "The browser asks Cloudflare for $appUrl over HTTPS."; stages = @('public-url', 'dns') }
    [ordered]@{ n = 2; id = 'cloudflare'; path = 'server'; from = 'Cloudflare'; to = 'Traefik'; title = 'Cloudflare forwards it through the tunnel'; text = 'Cloudflare passes the request through the outbound tunnel to cloudflared on this PC, which hands it to Traefik (http://traefik:80). No port of your router is opened.'; stages = @('access', 'tunnel') }
    [ordered]@{ n = 3; id = 'router'; path = 'server'; from = 'Traefik'; to = 'Traefik'; title = 'Traefik finds the route'; text = "Traefik matches the hostname $h to its router."; stages = @('router', 'middlewares') }
    [ordered]@{ n = 4; id = 'forwardauth'; path = 'server'; from = 'Traefik'; to = 'authentik outpost'; title = 'Traefik asks authentik'; text = "Server to server inside Docker: Traefik asks the authentik outpost whether this visitor is signed in. The browser never talks to this internal address."; stages = @('forwardauth', 'authentik') }
    [ordered]@{ n = 5; id = 'redirect'; path = 'browser'; from = 'Browser'; to = 'Sign-in page'; title = 'Not signed in: the browser goes to the sign-in page'; text = "authentik answers with a redirect, and the browser opens $(if ($publicUrl) { $publicUrl } else { 'the public sign-in page' })."; stages = @('redirect', 'signin') }
    [ordered]@{ n = 6; id = 'choose'; path = 'browser'; from = 'Browser'; to = $(if ($google) { 'Google' } else { 'authentik' }); title = $(if ($google) { 'You choose Continue with Google' } else { 'You sign in' }); text = $(if ($google) { 'The browser goes to Google''s own page and comes back to the sign-in page. Username and password stay available for local accounts.' } else { 'Username and password on the sign-in page.' }); stages = @('signin') }
    [ordered]@{ n = 7; id = 'policies'; path = 'server'; from = 'authentik'; to = 'authentik'; title = 'authentik checks who you are and whether you may enter'; text = 'Inside authentik: the account, its groups and the access rules (policies) of this application.'; stages = @('authentik') }
    [ordered]@{ n = 8; id = 'return'; path = 'browser'; from = 'Browser'; to = 'Cloudflare'; title = 'The browser returns to the application'; text = "Back to $appUrl/outpost.goauthentik.io/callback through Cloudflare and Traefik, then to the page you first asked for."; stages = @('callback', 'tunnel') }
    [ordered]@{ n = 9; id = 'recheck'; path = 'server'; from = 'Traefik'; to = 'Application'; title = 'Traefik checks again and forwards'; text = 'Traefik asks authentik once more (now the answer is yes) and passes the request to the application.'; stages = @('forwardauth', 'backend', 'networks') }
    [ordered]@{ n = 10; id = 'content'; path = 'browser'; from = 'Application'; to = 'Browser'; title = 'The application answers'; text = 'The page comes back the same way. If the application has its own login, it may still ask for it.'; stages = @('backend') }
  )
  foreach ($j in $journey) { $j.state = (& $pick $j.stages) }
  # Choosing Google and authentik's access decision need a real sign-in, which these checks never do: reachable is not
  # verified. Evidence of a real sign-in to this application (authentik's own event) does count.
  $signedIn = [bool][string](Get-Fact $id 'appVerifiedAt' '')
  foreach ($j in $journey) { if ($j.id -in 'choose', 'policies' -and $j.state -eq 'verified' -and -not $signedIn) { $j.state = 'configured' } }
  if (-not $protectedByAk) { foreach ($j in $journey) { if ($j.id -in 'redirect', 'choose', 'policies', 'return') { $j.state = 'na' } } }
  $first = @($stages | Where-Object { $_.state -eq 'failed' })[0]
  if (-not $first) { $first = @($stages | Where-Object { $_.state -eq 'warning' })[0] }
  return [ordered]@{
    service = $svc.name; displayName = $svc.displayName; hostname = $h; appUrl = $appUrl; protected = $protectedByAk; probed = $probed
    checkedAt = [string](Get-Fact $Facts 'checkedAt' ''); stages = $stages.ToArray(); journey = $journey
    firstProblem = $(if ($first) { [ordered]@{ id = $first.id; title = $first.title; state = $first.state; summary = $first.summary } } else { $null })
    counts = [ordered]@{ verified = @($stages | Where-Object { $_.state -eq 'verified' }).Count; configured = @($stages | Where-Object { $_.state -eq 'configured' }).Count; warning = @($stages | Where-Object { $_.state -eq 'warning' }).Count; failed = @($stages | Where-Object { $_.state -eq 'failed' }).Count }
  }
}

Export-ModuleMember -Function Get-IdentityAppAddress, Get-EndpointKind, Test-BrowserEndpoint, Get-RedactedUrl, Get-UrlQueryValue, ConvertFrom-AuthRedirect, Get-RoutingModel, Get-WorstState, New-RoutingStage
