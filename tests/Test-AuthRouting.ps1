#requires -version 5.1
<#
.SYNOPSIS
  Authentication & Routing unit tests (no Docker, no authentik, no real Cloudflare): browser-facing versus internal
  addresses, sign-in redirects that leak a local, LAN or Docker-only address, the original application address after
  signing in, redaction, the routing model's states for healthy and broken paths, the ForwardAuth probe (against a
  stub that answers like authentik's outpost), the public sign-in address guard, and Cloudflare Access cleanup.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-AuthRouting.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\RoutingModel.psm1') -Force
Import-Module (Join-Path $repo 'lib\Authentik.psm1') -Force
Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $repo 'lib\ServiceHealth.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }

# The anonymous answer of authentik's outpost for mediabox, as observed with authentik_host = http://127.0.0.1:9000.
$state = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.c2VjcmV0LXN0YXRl.c2lnbmF0dXJl'
$leak = "http://127.0.0.1:9000/application/o/authorize/?client_id=TpxTestClient00Abcd1&redirect_uri=https%3A%2F%2Fmediabox.example.com%2Foutpost.goauthentik.io%2Fcallback%3FX-authentik-auth-callback%3Dtrue&response_type=code&scope=openid+profile&state=$state"
$good = $leak.Replace('http://127.0.0.1:9000', 'https://auth.example.com')

# Healthy facts for mediabox; scenarios change one thing each.
function New-Facts {
  $f = [ordered]@{
    service = [ordered]@{ name = 'mediabox'; displayName = 'Mediabox'; hostname = 'mediabox.example.com'; enabled = $true; publish = $true; access = $false; authProvider = 'authentik'; targetUrl = 'http://host.docker.internal:4119'; targetType = 'host'; targetHost = 'host.docker.internal' }
    route = [ordered]@{ fileExists = $true; rule = 'Host(`mediabox.example.com`)'; entryPoints = @('web'); middlewares = @('svc-mediabox-authentik', 'default-headers@file'); forwardAuthAddress = 'http://authentik-server:9000/outpost.goauthentik.io/auth/traefik'; outpostRouter = $true; backendUrl = 'http://host.docker.internal:4119' }
    traefik = [ordered]@{ apiOk = $true; routers = @{ 'svc-mediabox@file' = 'enabled'; 'svc-mediabox-outpost@file' = 'enabled' } }
    identity = [ordered]@{ publicUrl = 'https://auth.example.com'; authHostname = 'auth.example.com'; serverContainer = 'authentik-server'; onProxyNetwork = $true; googleConfigured = $true; appVerifiedAt = '' }
    authentik = [ordered]@{ connected = $true; error = ''; outpostName = 'authentik Embedded Outpost'; outpostHost = 'https://auth.example.com/'; outpostBrowserHost = ''; providerFound = $true; providerExternalHost = 'https://mediabox.example.com'; providerMode = 'forward_single'; providerAssigned = $true; applicationFound = $true; rules = 1 }
    cloudflare = [ordered]@{ connected = $true; tunnelName = 'home'; accessAppName = ''; accessAppByDtc = $false }
    networks = [ordered]@{ proxy = 'proxynet'; traefik = @('proxynet', 'tunnel'); authentik = @('proxynet', 'authentik_internal'); backend = $null }
    health = [ordered]@{ checks = @(
        [ordered]@{ id = 'dns'; state = 'ok'; performed = $true; message = 'mediabox.example.com is a proxied CNAME to this tunnel.' }
        [ordered]@{ id = 'access'; state = 'skipped'; performed = $false; message = 'Not used: authentik is the login.' }
        [ordered]@{ id = 'tunnel'; state = 'ok'; performed = $true; message = "Tunnel 'home' sends mediabox.example.com to traefik:80; 4 connection(s)." }
        [ordered]@{ id = 'router'; state = 'ok'; performed = $true; message = 'svc-mediabox@file is loaded and enabled.' }
        [ordered]@{ id = 'service'; state = 'ok'; performed = $true; message = 'Loaded.' }
        [ordered]@{ id = 'backend'; state = 'ok'; performed = $true; message = 'The application answered HTTP 200 from Traefik''s network.' }
        [ordered]@{ id = 'http'; state = 'auth'; performed = $true; message = 'Login redirect.' }
        [ordered]@{ id = 'public'; state = 'ok'; performed = $true; message = 'The public URL answered HTTP 302.' }) }
    challenge = [pscustomobject]@{ State = 'auth'; Status = 302; Location = (Get-RedactedUrl $good); Chain = @('mediabox.example.com/ -> 302'); Message = 'Sign-in required.' }
    publicAuth = [ordered]@{ status = 204; location = ''; error = '' }
    checkedAt = '2026-10-25T20:00:00'
  }
  return $f
}
function Get-Stage($Model, [string]$Id) { return @($Model.stages | Where-Object { $_.id -eq $Id })[0] }
function Set-Check($Facts, [string]$Id, [string]$State, [string]$Message) { foreach ($c in $Facts.health.checks) { if ($c.id -eq $Id) { $c.state = $State; $c.message = $Message; $c.performed = $true } } }

try {
  # --- Browser versus internal addresses -----------------------------------------------------------------------------------
  $kinds = [ordered]@{ 'http://127.0.0.1:9000/' = 'loopback'; 'http://localhost:9000' = 'loopback'; 'http://192.168.1.20:9000' = 'private'; 'http://10.0.0.5' = 'private'; 'http://172.25.0.11:9000' = 'private'
    'http://authentik-server:9000' = 'internal-name'; 'http://host.docker.internal:4119' = 'internal-name'; 'http://nas.local' = 'internal-name'; 'https://203.0.113.7' = 'public-ip'; 'https://auth.example.com/' = 'public'; 'ftp://x.example.com' = 'invalid' }
  $wrong = @($kinds.Keys | Where-Object { (Get-EndpointKind $_).kind -ne $kinds[$_] } | ForEach-Object { "$_ -> $((Get-EndpointKind $_).kind)" })
  Test-Condition 'endpoints: loopback, LAN, Docker-only, raw IP and public addresses are told apart' ($wrong.Count -eq 0) ($wrong -join '; ')
  $bad = @('http://127.0.0.1:9000/', 'http://192.168.1.20:9000/', 'http://authentik-server:9000/', 'https://203.0.113.7/', 'http://auth.example.com/') | Where-Object { (Test-BrowserEndpoint $_ 'auth.example.com').ok }
  Test-Condition 'browser endpoints: local, LAN, Docker-only, raw-IP and plain-http addresses are refused for browsers' (@($bad).Count -eq 0) (@($bad) -join ', ')
  Test-Condition 'browser endpoints: the public HTTPS sign-in address is accepted; another public host is not' ((Test-BrowserEndpoint 'https://auth.example.com/' 'auth.example.com').ok -and -not (Test-BrowserEndpoint 'https://login.other.example/' 'auth.example.com').ok) ''

  # --- Sign-in redirect and return address ---------------------------------------------------------------------------------
  $r1 = ConvertFrom-AuthRedirect $leak 'https://auth.example.com' 'mediabox.example.com'
  Test-Condition 'redirect: http://127.0.0.1:9000 in the sign-in redirect is detected (the Mediabox failure)' (-not $r1.ok -and $r1.kind -eq 'loopback' -and $r1.problems[0] -match 'only works on the PC') ($r1 | ConvertTo-Json -Compress)
  $r2 = ConvertFrom-AuthRedirect $good 'https://auth.example.com' 'mediabox.example.com'
  Test-Condition 'redirect: the public sign-in page is accepted and the original application address comes back after signing in' ($r2.ok -and $r2.returnOk -and $r2.returnUrl -eq 'https://mediabox.example.com/outpost.goauthentik.io/callback?X-authentik-auth-callback=true') ($r2 | ConvertTo-Json -Compress)
  $r3 = ConvertFrom-AuthRedirect $good.Replace('mediabox.example.com%2F', 'other.example.com%2F') 'https://auth.example.com' 'mediabox.example.com'
  $r4 = ConvertFrom-AuthRedirect $good.Replace('https%3A%2F%2Fmediabox', 'http%3A%2F%2Fmediabox') 'https://auth.example.com' 'mediabox.example.com'
  Test-Condition 'redirect: a return to another host or to plain http is reported' (-not $r3.returnOk -and $r3.returnProblem -match 'other\.example\.com' -and -not $r4.returnOk) "$($r3.returnProblem) / $($r4.returnProblem)"
  $r5 = ConvertFrom-AuthRedirect $good.Replace('https://auth.example.com', 'http://authentik-server:9000') 'https://auth.example.com' 'mediabox.example.com'
  Test-Condition 'redirect: the internal ForwardAuth address leaking into the browser redirect is detected' (-not $r5.ok -and $r5.kind -eq 'internal-name') ''
  $red = Get-RedactedUrl $leak
  Test-Condition 'redaction: state and client id are removed, the return address is kept' ($red -notmatch [regex]::Escape($state) -and $red -notmatch 'TpxTestClient' -and $red -match 'state=\[redacted\]' -and $red -match 'redirect_uri=https://mediabox\.example\.com/outpost\.goauthentik\.io/callback') $red

  # --- Routing model ------------------------------------------------------------------------------------------------------
  $m = Get-RoutingModel (New-Facts)
  $notOk = @($m.stages | Where-Object { $_.state -notin 'verified', 'na', 'configured' } | ForEach-Object { "$($_.id)=$($_.state)" })
  Test-Condition 'model (healthy): no problem; ForwardAuth, redirect, sign-in page, return and backend are verified by requests' ($notOk.Count -eq 0 -and -not $m.firstProblem -and @(@('forwardauth', 'redirect', 'signin', 'callback', 'backend', 'router') | Where-Object { (Get-Stage $m $_).state -ne 'verified' }).Count -eq 0) ($notOk -join ', ')
  Test-Condition 'model: ten browser-journey steps, the redirect and return marked as browser hops, ForwardAuth as server to server' (@($m.journey).Count -eq 10 -and (@($m.journey | Where-Object { $_.id -eq 'redirect' })[0].path -eq 'browser') -and (@($m.journey | Where-Object { $_.id -eq 'forwardauth' })[0].path -eq 'server') -and (@($m.journey | Where-Object { $_.id -eq 'return' })[0].path -eq 'browser')) ''
  $fa = Get-Stage $m 'forwardauth'; $rd = Get-Stage $m 'redirect'; $si = Get-Stage $m 'signin'
  Test-Condition 'model: public addresses are browser endpoints, Docker addresses are internal endpoints' (@($fa.endpoints | Where-Object { $_.value -match 'authentik-server:9000' -and $_.audience -eq 'internal' }).Count -eq 1 -and @($si.endpoints | Where-Object { $_.value -eq 'https://auth.example.com' -and $_.audience -eq 'browser' }).Count -eq 1 -and @($si.endpoints | Where-Object { $_.value -match 'authentik-server' -and $_.audience -eq 'internal' }).Count -eq 1) ''

  $f = New-Facts; $f.challenge = [pscustomobject]@{ State = 'misrouted'; Status = 302; Location = (Get-RedactedUrl $leak); Chain = @(); Message = 'x' }; $f.authentik.outpostHost = 'http://127.0.0.1:9000'
  $m = Get-RoutingModel $f; $rd = Get-Stage $m 'redirect'
  Test-Condition 'model (Mediabox): the browser redirect fails and is the first problem; ForwardAuth itself still works' ($rd.state -eq 'failed' -and $m.firstProblem.id -eq 'redirect' -and (Get-Stage $m 'forwardauth').state -eq 'verified' -and @($m.journey | Where-Object { $_.id -eq 'redirect' })[0].state -eq 'failed') ($rd.summary)
  Test-Condition 'model (Mediabox): the failed step shows endpoint, expected, actual, explanation and the fix (public sign-in address)' ($rd.detail.endpoint -match 'Location' -and $rd.detail.expected -match '^https://auth\.example\.com/application/o/authorize' -and $rd.detail.actual -match '^http://127\.0\.0\.1:9000/' -and $rd.detail.explanation -match 'authentik_host' -and $rd.detail.fix -match 'https://auth\.example\.com/') ($rd.detail | ConvertTo-Json -Compress)

  $f = New-Facts; $f.health = $null; $f.challenge = $null; $f.publicAuth = $null; $f.authentik.outpostHost = 'http://127.0.0.1:9000'
  $m = Get-RoutingModel $f
  Test-Condition 'model (configuration only): nothing is "verified" without a request; the local outpost address already fails from configuration' (@($m.stages | Where-Object { $_.state -eq 'verified' }).Count -eq 0 -and (Get-Stage $m 'redirect').state -eq 'failed' -and (Get-Stage $m 'forwardauth').state -eq 'configured' -and -not $m.probed) (($m.stages | ForEach-Object { "$($_.id)=$($_.state)" }) -join ', ')

  $f = New-Facts; $f.challenge = [pscustomobject]@{ State = 'failed'; Status = 500; Location = ''; Chain = @('mediabox.example.com/ -> 500'); Message = 'HTTP 500. Traefik could not reach authentik (fails closed).' }
  $m = Get-RoutingModel $f; $fa = Get-Stage $m 'forwardauth'
  Test-Condition 'model: an unhealthy authentication endpoint (HTTP 500) fails ForwardAuth with the fail-closed explanation' ($fa.state -eq 'failed' -and $fa.detail.explanation -match 'fails closed' -and $fa.detail.fix -match 'authentik-server') ($fa | ConvertTo-Json -Compress -Depth 4)
  $f = New-Facts; $f.challenge = [pscustomobject]@{ State = 'open'; Status = 200; Location = ''; Chain = @(); Message = 'open' }
  Test-Condition 'model: an application that answers without sign-in fails "ForwardAuth enforced"' ((Get-Stage (Get-RoutingModel $f) 'forwardauth').state -eq 'failed') ''
  $f = New-Facts; $f.route.forwardAuthAddress = 'http://127.0.0.1:9000/outpost.goauthentik.io/auth/traefik'
  Test-Condition 'model: a ForwardAuth address of 127.0.0.1 (Traefik itself) fails' ((Get-Stage (Get-RoutingModel $f) 'forwardauth').state -eq 'failed') ''
  $f = New-Facts; $f.identity.onProxyNetwork = $false; $f.networks.authentik = @('authentik_internal'); $f.challenge = $null
  $m = Get-RoutingModel $f
  Test-Condition 'model: authentik missing from the shared Docker network fails the network and ForwardAuth stages' ((Get-Stage $m 'networks').state -eq 'failed' -and (Get-Stage $m 'forwardauth').state -eq 'failed') ''
  $f = New-Facts; $f.route.fileExists = $false; $f.challenge = $null
  Test-Condition 'model: a missing Traefik route fails the router stage' ((Get-Stage (Get-RoutingModel $f) 'router').state -eq 'failed') ''
  $f = New-Facts; $f.traefik.routers['svc-mediabox@file'] = 'disabled'; $f.challenge = $null; Set-Check $f 'router' 'failed' 'Traefik reports svc-mediabox@file as disabled.'
  $m = Get-RoutingModel $f
  Test-Condition 'model: a router Traefik reports as broken fails, with what was expected' ((Get-Stage $m 'router').state -eq 'failed' -and (Get-Stage $m 'router').detail.expected -match 'Host\(`mediabox\.example\.com`\)') ''
  $f = New-Facts; $f.route.middlewares = @('default-headers@file', 'svc-mediabox-authentik'); $f.challenge = $null
  Test-Condition 'model: the sign-in middleware not first in the chain is a warning' ((Get-Stage (Get-RoutingModel $f) 'middlewares').state -eq 'warning') ''
  $f = New-Facts; $f.networks.backend = @('bridge'); $f.service.targetType = 'docker'; $f.service.targetHost = 'mediabox'
  Test-Condition 'model: an application container without the shared network fails the network stage' ((Get-Stage (Get-RoutingModel $f) 'networks').state -eq 'failed') ''
  $f = New-Facts; Set-Check $f 'tunnel' 'failed' 'The tunnel sends mediabox.example.com to http://localhost:80.'; Set-Check $f 'public' 'failed' 'HTTP 502 at Cloudflare.'
  $m = Get-RoutingModel $f
  Test-Condition 'model: a tunnel route to localhost fails the tunnel stage and shows the fix' ((Get-Stage $m 'tunnel').state -eq 'failed' -and (Get-Stage $m 'tunnel').detail.expected -eq 'http://traefik:80') ''
  $f = New-Facts; $f.cloudflare.accessAppName = 'mediabox.example.com (traefik-home)'; $f.cloudflare.accessAppByDtc = $true; Set-Check $f 'public' 'auth' 'Cloudflare Access shows its login page, although this service is not set to use Cloudflare Access.'
  $m = Get-RoutingModel $f; $ac = Get-Stage $m 'access'
  Test-Condition 'model: a leftover Access application is reported as the source of the Cloudflare challenge (warning, not removed)' ($ac.state -eq 'warning' -and $ac.summary -match 'challenge' -and $ac.detail.explanation -match 'created by this manager' -and $ac.detail.fix -match 'without your explicit confirmation' -and (Get-Stage $m 'public-url').state -eq 'warning') ($ac | ConvertTo-Json -Compress -Depth 4)
  $f = New-Facts; $f.service.access = $true; Set-Check $f 'public' 'auth' 'Cloudflare Access shows its login page (authentication required).'
  Test-Condition 'model: Cloudflare Access that is wanted is verified from its login redirect' ((Get-Stage (Get-RoutingModel $f) 'access').state -eq 'verified') ''
  $f = New-Facts; $f.publicAuth = [ordered]@{ status = 502; location = ''; error = '' }
  Test-Condition 'model: an unreachable public sign-in page fails' ((Get-Stage (Get-RoutingModel $f) 'signin').state -eq 'failed') ''
  $f = New-Facts; $f.identity.publicUrl = 'http://192.168.1.20:9000'
  Test-Condition 'model: a LAN address as the public sign-in page fails' ((Get-Stage (Get-RoutingModel $f) 'signin').state -eq 'failed') ''
  # Applications share the entry point of the sign-in page: a sign-in address with a port expects the provider on that port.
  $f = New-Facts; $f.identity.publicUrl = 'http://auth.example.com:8080'; $f.authentik.providerExternalHost = 'http://mediabox.example.com:8080'
  $mp = Get-RoutingModel $f
  Test-Condition 'model: on an entry point with a port the provider address with that port is accepted (authentik stage not failed)' ((Get-Stage $mp 'authentik').state -ne 'failed' -and $mp.appUrl -eq 'http://mediabox.example.com:8080') "$((Get-Stage $mp 'authentik').summary) $($mp.appUrl)"
  $f = New-Facts; $f.identity.publicUrl = 'http://auth.example.com:8080'
  Test-Condition 'model: on an entry point with a port a provider without that port fails (authentik answers 404 for the real Host)' ((Get-Stage (Get-RoutingModel $f) 'authentik').state -eq 'failed') ''
  $f = New-Facts
  Test-Condition 'model: in production the application address stays https://<host>' ((Get-RoutingModel $f).appUrl -eq 'https://mediabox.example.com' -and (Get-Stage (Get-RoutingModel $f) 'authentik').state -ne 'failed') ''
  $f = New-Facts; $f.challenge.Location = (Get-RedactedUrl $good.Replace('mediabox.example.com%2F', 'other.example.com%2F'))
  Test-Condition 'model: a return address other than the original application fails "Return to the application"' ((Get-Stage (Get-RoutingModel $f) 'callback').state -eq 'failed') ''
  $f = New-Facts; $f.route.outpostRouter = $false
  Test-Condition 'model: no /outpost.goauthentik.io/ route fails the return step (404 after signing in)' ((Get-Stage (Get-RoutingModel $f) 'callback').state -eq 'failed') ''
  $f = New-Facts; $f.authentik.providerAssigned = $false; $f.challenge = $null
  Test-Condition 'model: a provider not assigned to the outpost fails the authentik stage' ((Get-Stage (Get-RoutingModel $f) 'authentik').state -eq 'failed') ''
  $f = New-Facts; $f.service.authProvider = ''; $f.challenge = $null
  $m = Get-RoutingModel $f
  Test-Condition 'model: an unprotected application has no sign-in stages; those journey steps are not applicable' (-not (Get-Stage $m 'redirect') -and (Get-Stage $m 'forwardauth').state -eq 'na' -and @($m.journey | Where-Object { $_.id -in 'redirect', 'choose', 'policies', 'return' -and $_.state -ne 'na' }).Count -eq 0) ''
  $f = New-Facts; $f.service.publish = $false
  Test-Condition 'model: a local-only application has no Cloudflare stages' ((Get-Stage (Get-RoutingModel $f) 'public-url').state -eq 'na' -and -not (Get-Stage (Get-RoutingModel $f) 'tunnel')) ''
  $f = New-Facts; $f.challenge = [pscustomobject]@{ State = 'misrouted'; Status = 302; Location = (Get-RedactedUrl $leak); Chain = @(); Message = 'x' }
  $json = Get-RoutingModel $f | ConvertTo-Json -Depth 10
  Test-Condition 'model: no state token, client id or cookie in what is sent to the browser' ($json -notmatch [regex]::Escape($state) -and $json -notmatch 'TpxTestClient' -and $json -notmatch '(?i)set-cookie|authentik_proxy') ''

  # --- Public probe ----------------------------------------------------------------------------------------------------------
  $pp = ConvertFrom-PublicProbe 302 'https://team.cloudflareaccess.com/cdn-cgi/access/login/mediabox.example.com?kid=1' '' 'public'
  Test-Condition 'health: a Cloudflare Access login on a service that does not use Access is a warning, not "Access OK"' ($pp.access -eq 'warning' -and $pp.message -match 'not set to use Cloudflare Access') ($pp | ConvertTo-Json -Compress)

  # --- ForwardAuth probe against a stub outpost ------------------------------------------------------------------------------
  $port = Get-FreeTcpPort
  $job = Start-Job -ArgumentList $port, $leak, $good -ScriptBlock {
    param($Port, $Leak, $Good)
    $l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port); $l.Start()
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
      if (-not $l.Pending()) { Start-Sleep -Milliseconds 50; continue }
      $c = $l.AcceptTcpClient(); $s = $c.GetStream(); $r = New-Object IO.StreamReader($s)
      $hostLine = ''; while (($line = $r.ReadLine())) { if ($line -match '^Host:\s*(.+)$') { $hostLine = $Matches[1].Trim() } }
      $loc = $(if ($hostLine -like 'leaky.*') { $Leak } else { $Good })
      $resp = "HTTP/1.1 302 Found`r`nLocation: $loc`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
      $b = [Text.Encoding]::ASCII.GetBytes($resp); $s.Write($b, 0, $b.Length); $s.Flush(); $c.Close()
    }
    $l.Stop()
  }
  try {
    $null = Wait-TcpPort $port 15
    $c1 = Test-ForwardAuthChallenge -TraefikPort $port -Hostname 'leaky.example.com' -AuthHostname 'auth.example.com'
    Test-Condition 'probe: a sign-in redirect to 127.0.0.1:9000 is "misrouted", never "sign-in required"' ($c1.State -eq 'misrouted' -and $c1.Message -match '127\.0\.0\.1:9000' -and $c1.Message -match 'public sign-in address') ($c1 | ConvertTo-Json -Compress)
    Test-Condition 'probe: the redirect it reports is redacted (no state token, no client id)' ($c1.Location -notmatch [regex]::Escape($state) -and $c1.Location -notmatch 'TpxTestClient' -and $c1.Location -match 'redirect_uri=https://mediabox') $c1.Location
    $c2 = Test-ForwardAuthChallenge -TraefikPort $port -Hostname 'mediabox.example.com' -AuthHostname 'auth.example.com'
    Test-Condition 'probe: a redirect to the public sign-in page is "sign-in required"' ($c2.State -eq 'auth') ($c2 | ConvertTo-Json -Compress)
  } finally { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }

  # --- Public sign-in address guard (refused before authentik is contacted) ----------------------------------------------------
  foreach ($u in 'http://127.0.0.1:9000', 'http://authentik-server:9000', 'http://192.168.1.20:9000') {
    $conn = New-AuthentikConnection -BaseUrl "http://127.0.0.1:$(Get-FreeTcpPort)" -Token 'unused'
    $msg = ''; try { $null = Sync-AuthentikOutpost -Conn $conn -PublicUrl $u -WhatIf } catch { $msg = $_.Exception.Message }
    Test-Condition "outpost: '$u' is refused as the browser sign-in address" ($msg -match 'cannot be used for browsers' -and @($conn.Calls).Count -eq 0) $msg
    $msg = ''; try { $null = Sync-AuthentikAppProtection -Conn $conn -Desired ([pscustomobject]@{ Service = 'mediabox'; Hostname = 'mediabox.example.com'; PublicUrl = $u }) -WhatIf } catch { $msg = $_.Exception.Message }
    Test-Condition "protect: refused when the sign-in address would be '$u'" ($msg -match 'cannot be used for browsers' -and @($conn.Calls).Count -eq 0) $msg
  }

  # --- Cloudflare Access: turning it off removes the application the manager created; a leftover is only reported -------------
  $work = Join-Path ([IO.Path]::GetTempPath()) ('tpx-authrt-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Force -Path (Join-Path $work 'config') | Out-Null
  $tok = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $mock = $null
  try {
    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $tok
    Set-CloudflareApiBase $mock.Base
    $settings = [pscustomobject]@{ InstallPath = $work; StackName = 'tpx-authrt' }
    Save-CloudflareApiToken -Settings $settings -Token $tok
    $acct = 'acc0000000000000000000000000001'; $tid = '11111111-2222-3333-4444-555555555555'
    $cfg = Read-CloudflareConfig -Settings $settings
    $cfg.accountId = $acct; $cfg.tunnelId = $tid; $cfg.tunnelName = 'mock'
    $cfg.domains = @([pscustomobject]@{ id = 'zone00000000000000000000000000001'; name = 'example.test'; accountId = $acct })
    $app = Invoke-CloudflareApi -Settings $settings -Method POST -Path "/accounts/$acct/access/apps" -Body @{ name = 'app.example.test (tpx-authrt)'; domain = 'app.example.test'; type = 'self_hosted'; policies = @() }
    $cfg.managed | Add-Member -NotePropertyName 'app.example.test' -NotePropertyValue ([pscustomobject]@{ service = 'app'; dnsRecordId = ''; accessAppId = [string]$app.id }) -Force
    Save-CloudflareConfig -Settings $settings -Config $cfg
    $on = [pscustomobject]@{ name = 'app'; enabled = $true; hostnames = @('app.example.test'); cloudflare = [pscustomobject]@{ publish = $true; access = $true } }
    $off = [pscustomobject]@{ name = 'app'; enabled = $true; hostnames = @('app.example.test'); cloudflare = [pscustomobject]@{ publish = $true; access = $false } }
    $p1 = Get-CloudflareServicePlan -Settings $settings -Service $off -PreviousService $on
    $del = @($p1.Actions | Where-Object { $_.Step -eq 'access' -and $_.Kind -eq 'delete' })
    Test-Condition 'cloudflare: turning Access off removes the Access application this tool created (listed in the preview)' ($del.Count -eq 1 -and $del[0].Data.AppId -eq $app.id -and -not $del[0].Overwrite) (($p1.Actions | ForEach-Object { "$($_.Step):$($_.Kind)" }) -join ', ')
    $p2 = Get-CloudflareServicePlan -Settings $settings -Service $off -PreviousService $off
    Test-Condition 'cloudflare: a leftover Access application is reported, never removed without an explicit change' (@($p2.Actions | Where-Object { $_.Step -eq 'access' -and $_.Kind -eq 'delete' }).Count -eq 0 -and @($p2.Notes | Where-Object { $_ -match 'still asks visitors' }).Count -eq 1) (($p2.Notes) -join ' | ')
    # A leftover from an earlier change that turned Access off (the registry already says off): removed only when the
    # change explicitly asks for cleanup, and only because this tool recorded creating it.
    $offAk = [pscustomobject]@{ name = 'app'; enabled = $true; hostnames = @('app.example.test'); cloudflare = [pscustomobject]@{ publish = $true; access = $false }; auth = [pscustomobject]@{ provider = 'authentik'; endpoint = 'http://authentik-server:9000' } }
    $p3 = Get-CloudflareServicePlan -Settings $settings -Service $offAk -PreviousService $offAk -Cleanup
    $del3 = @($p3.Actions | Where-Object { $_.Step -eq 'access' -and $_.Kind -eq 'delete' })
    Test-Condition 'cloudflare: with cleanup, a leftover Access application this tool created is removed (stale drift repaired, authentik stays)' ($del3.Count -eq 1 -and $del3[0].Data.AppId -eq $app.id -and $del3[0].Detail -match 'left behind' -and $del3[0].Detail -match 'authentik stays') (($p3.Actions | ForEach-Object { "$($_.Step):$($_.Kind) $($_.Detail)" }) -join ' | ')
    $wild = Invoke-CloudflareApi -Settings $settings -Method POST -Path "/accounts/$acct/access/apps" -Body @{ name = 'Everything'; domain = '*.example.test'; type = 'self_hosted'; policies = @() }
    $p4 = Get-CloudflareServicePlan -Settings $settings -Service $offAk -PreviousService $offAk -Cleanup
    Test-Condition 'cloudflare: a wildcard Access application not created by this tool is detected (sign in twice) and never deleted' (@($p4.Notes | Where-Object { $_ -match "wildcard Access application 'Everything'" -and $_ -match 'sign in twice' }).Count -eq 1 -and @($p4.Actions | Where-Object { $_.Kind -eq 'delete' -and $_.Data.AppId -eq $wild.id }).Count -eq 0) (($p4.Notes) -join ' | ')
    $null = Invoke-CloudflareApi -Settings $settings -Method DELETE -Path "/accounts/$acct/access/apps/$($wild.id)"
    $r = Invoke-CloudflareServicePlan -Settings $settings -Plan $p1 -ServiceName 'app'
    $left = @((Get-MockState $mock).apps | Where-Object { $_.id -eq $app.id })
    Test-Condition 'cloudflare: applying the turn-off deletes the Access application and forgets it' ($left.Count -eq 0 -and -not (Get-ManagedResource (Read-CloudflareConfig -Settings $settings) 'app.example.test' 'accessAppId')) ($r | ConvertTo-Json -Compress -Depth 4)
  } catch { Add-Result 'FAIL' 'cloudflare access cleanup' "$($_.Exception.Message) $($_.ScriptStackTrace)" }
  finally { if ($mock) { Stop-TestServer $mock }; Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
catch { Add-Result 'FAIL' 'auth routing run' "$($_.Exception.Message) $($_.ScriptStackTrace)" }

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
