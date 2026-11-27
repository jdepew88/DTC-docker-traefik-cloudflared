#requires -version 5.1
<#
.SYNOPSIS
  Request-path diagnosis unit tests (no Docker, no network): how each hop's answer is classified, so the first
  failing segment is named correctly. Windows localhost versus container localhost, Docker Desktop's host address, LAN
  addresses captured by a Docker network, wrong ports, wrong HTTP/HTTPS protocol, backend timeouts, apps refusing the
  public hostname, missing Traefik routers, Cloudflare tunnel route mismatches and Cloudflare Access login redirects.
  The live counterparts run in Test-Discovery.ps1's disposable instance.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Routing.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\DockerDiscovery.psm1') -Force
Import-Module (Join-Path $repo 'lib\ServiceHealth.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  $status = $(if ($Condition) { 'PASS' } else { 'FAIL' })
  $null = $script:Results.Add([pscustomobject]@{ Status = $status; Test = $Name })
  Write-Host ('[{0}] {1}  {2}' -f $status, $Name, $(if ($Condition) { '' } else { $Detail })) -ForegroundColor $(if ($Condition) { 'Green' } else { 'Red' })
}
function New-Svc([string]$Type, [string]$TargetHost, [int]$Port, [string]$Protocol = 'http') {
  return [pscustomobject]@{ name = 'x'; hostnames = @('app.example.com'); pathPrefix = ''; stripPrefix = $false; enabled = $true
    target = [pscustomobject]@{ type = $Type; host = $TargetHost; port = $Port; protocol = $Protocol; tlsSkipVerify = $false } }
}
function New-Try([string]$Scheme, [string]$Result, [int]$Status = 0, [string]$Detail = '') { return [ordered]@{ scheme = $Scheme; url = "${Scheme}://h:1/"; result = $Result; status = $Status; detail = $Detail } }

# --- Application answers -------------------------------------------------------------------------------------------------
$a401 = ConvertFrom-AppStatus 401 '' 'app.example.com'
$a403 = ConvertFrom-AppStatus 403 '' 'app.example.com'
Test-Condition 'app answer: 401 and 403 are "authentication required", distinct from passed' ($a401[0] -eq 'auth' -and $a403[0] -eq 'auth' -and $a401[1] -match 'login') ($a401 -join ' ')
$hv = ConvertFrom-AppStatus 400 '{"error":"Host validation failed. See logs for more details."}' 'home.example.com'
Test-Condition 'app answer: Homepage''s host validation 400 fails and names HOMEPAGE_ALLOWED_HOSTS and the hostname' ($hv[0] -eq 'failed' -and $hv[1] -match 'HOMEPAGE_ALLOWED_HOSTS' -and $hv[1] -match 'home\.example\.com') ($hv -join ' ')
$vite = ConvertFrom-AppStatus 403 'Blocked request. This host ("x") is not allowed.' 'x'
Test-Condition 'app answer: other host allow-lists are recognised too (Vite''s 403 "Blocked request" is a rejected hostname, not a login)' ($vite[0] -eq 'failed' -and $vite[1] -match 'rejected the hostname') ($vite -join ' ')
$tls = ConvertFrom-AppStatus 400 'Client sent an HTTP request to an HTTPS server.' 'x'
Test-Condition 'app answer: "HTTP request to an HTTPS server" is a protocol mismatch' ($tls[0] -eq 'failed' -and $tls[1] -match 'speaks HTTPS') ($tls -join ' ')
Test-Condition 'app answer: a plain 400 fails (the app refuses the request), an app 404 and 2xx/3xx pass' ((ConvertFrom-AppStatus 400 '' 'x')[0] -eq 'failed' -and (ConvertFrom-AppStatus 404 '' 'x')[0] -eq 'ok' -and (ConvertFrom-AppStatus 200 '' 'x')[0] -eq 'ok' -and (ConvertFrom-AppStatus 302 '' 'x')[0] -eq 'ok') ''

# --- Through Traefik -----------------------------------------------------------------------------------------------------
Test-Condition 'routed: Traefik''s own 404 means no router matched (missing router)' ((ConvertFrom-RoutedStatus 404 "404 page not found`n" '' 'a.example.com')[0] -eq 'failed' -and (ConvertFrom-RoutedStatus 404 "404 page not found`n" '' 'a.example.com')[1] -match 'No Traefik router') ''
Test-Condition 'routed: 502 / 504 / timeout fail at the backend' ((ConvertFrom-RoutedStatus 502 'Bad Gateway' '' 'a')[0] -eq 'failed' -and (ConvertFrom-RoutedStatus 504 '' '' 'a')[0] -eq 'failed' -and (ConvertFrom-RoutedStatus 0 '' 'The operation has timed out.' 'a')[1] -match 'waiting for the backend') ''
Test-Condition 'routed: 401 through Traefik is "authentication required"' ((ConvertFrom-RoutedStatus 401 '' '' 'a')[0] -eq 'auth') ''
Test-Condition 'routed: Homepage''s host validation through Traefik fails' ((ConvertFrom-RoutedStatus 400 '{"error":"Host validation failed. See logs for more details."}' '' 'home.example.com')[0] -eq 'failed') ''
$int = ConvertFrom-RoutedStatus 302 '' '' 'app.example.com' 'http://homepage:3000/login'
$ext = ConvertFrom-RoutedStatus 302 '' '' 'app.example.com' 'https://app.example.com/home'
$rel = ConvertFrom-RoutedStatus 302 '' '' 'app.example.com' '/dashboard'
Test-Condition 'routed: a redirect to an internal address (container name / port) is a warning; to the public host or a path it passes' ($int[0] -eq 'warning' -and $int[1] -match 'internal address' -and $ext[0] -eq 'ok' -and $rel[0] -eq 'ok') "$($int -join ' ') | $($ext -join ' ')"
$lg = ConvertFrom-RoutedStatus 302 '' '' 'app.example.com' '/login?next=/'
$lgx = ConvertFrom-RoutedStatus 302 '' '' 'app.example.com' 'https://app.example.com/login'
Test-Condition 'routed: a redirect to the app''s own login page is "authentication required", not passed' ($lg[0] -eq 'auth' -and $lg[1] -match 'login page' -and $lgx[0] -eq 'auth') ($lg -join ' ')

# --- Windows localhost, Docker Desktop host address, LAN subnet capture -----------------------------------------------------
$lo = @(Get-LanTargetIssues '127.0.0.1')
$lh = @(Get-LanTargetIssues 'localhost')
Test-Condition 'LAN target: 127.0.0.1 / localhost inside a container is the container itself; host.docker.internal is suggested' ($lo.Count -eq 1 -and $lo[0].state -eq 'failed' -and $lo[0].message -match 'host\.docker\.internal' -and $lh.Count -eq 1) ''
$own = @(Get-LanTargetIssues '10.20.30.11' @('10.20.30.11', '192.168.56.1') @())
Test-Condition 'LAN target: this PC''s own LAN address is a warning pointing at host.docker.internal' ($own.Count -eq 1 -and $own[0].state -eq 'warning' -and $own[0].message -match 'host\.docker\.internal') ''
$cap = @(Get-LanTargetIssues '10.20.30.11' @('10.20.30.11') @([ordered]@{ name = 'unifi-lan_unifi_net'; subnet = '10.20.30.0/24' }, [ordered]@{ name = 'proxynet'; subnet = '172.25.0.0/16' }))
Test-Condition 'LAN target: an address inside a Docker network''s subnet fails and names that network' (@($cap | Where-Object { $_.state -eq 'failed' -and $_.message -match 'unifi-lan_unifi_net' -and $_.message -match '10.20.30.0/24' }).Count -eq 1) ($cap | ConvertTo-Json -Compress)
Test-Condition 'LAN target: an ordinary LAN device raises nothing' (@(Get-LanTargetIssues '10.20.30.50' @('10.20.30.11') @([ordered]@{ name = 'proxynet'; subnet = '172.25.0.0/16' })).Count -eq 0) ''
$sd = Test-ServiceDefinition -Service ([pscustomobject]@{ name = 'loop'; hostnames = @('a.example.com'); target = [pscustomobject]@{ type = 'lan'; host = '127.0.0.1'; port = 80; protocol = 'http' } })
$sh = Test-ServiceDefinition -Service ([pscustomobject]@{ name = 'hst'; hostnames = @('a.example.com'); target = [pscustomobject]@{ type = 'host'; host = '127.0.0.1'; port = 80; protocol = 'http' } })
Test-Condition 'validation: a loopback LAN target and a Windows-host target other than host.docker.internal are errors' (@($sd | Where-Object { $_.Level -eq 'Error' -and $_.Field -eq 'target.host' }).Count -eq 1 -and @($sh | Where-Object { $_.Level -eq 'Error' -and $_.Message -match 'host\.docker\.internal' }).Count -eq 1) ''

# --- Traefik -> backend probe ------------------------------------------------------------------------------------------------
$svc = New-Svc 'docker' 'web' 8080
$probe = { param($Tries) [ordered]@{ performed = $true; tries = @($Tries); timeout = 5; hostname = 'app.example.com' } }
$closed = ConvertFrom-BackendProbe (& $probe @(New-Try 'http' 'closed')) $svc 'proxynet'
Test-Condition 'backend: connection refused names a wrong port (inside the container, not the published Windows port)' ($closed[0] -eq 'failed' -and $closed[1] -match 'refused' -and $closed[1] -match 'inside its container') ($closed -join ' ')
$to = ConvertFrom-BackendProbe (& $probe @(New-Try 'http' 'timeout')) (New-Svc 'lan' '10.20.30.11' 4119) 'proxynet'
Test-Condition 'backend: a timeout names Docker routing, Windows Firewall and loopback-only listeners' ($to[0] -eq 'failed' -and $to[1] -match 'within 5 seconds' -and $to[1] -match 'Firewall' -and $to[1] -match 'captures') ($to -join ' ')
$dns = ConvertFrom-BackendProbe (& $probe @(New-Try 'http' 'error' 0 'The container name does not resolve on that network.')) $svc 'proxynet'
Test-Condition 'backend: a name that does not resolve points at the shared network' ($dns[0] -eq 'failed' -and $dns[1] -match "not attached to 'proxynet'") ($dns -join ' ')
$h2s = ConvertFrom-BackendProbe (& $probe @((New-Try 'http' 'http' 400), (New-Try 'https' 'http' 200))) (New-Svc 'docker' 'portainer' 9443) 'proxynet'
Test-Condition 'backend: http to an HTTPS port (400, then 200 over https) is a protocol mismatch -> https' ($h2s[0] -eq 'failed' -and $h2s[1] -match 'speaks HTTPS' -and $h2s[1] -match 'protocol to https') ($h2s -join ' ')
$s2h = ConvertFrom-BackendProbe (& $probe @((New-Try 'https' 'not-http' 0 'TLS handshake failed.'), (New-Try 'http' 'http' 200))) (New-Svc 'docker' 'web' 80 'https') 'proxynet'
Test-Condition 'backend: https to a plain HTTP port is a protocol mismatch -> http' ($s2h[0] -eq 'failed' -and $s2h[1] -match 'speaks HTTP,' -and $s2h[1] -match 'protocol to http') ($s2h -join ' ')
$hv400 = ConvertFrom-BackendProbe (& $probe @((New-Try 'http' 'http' 400), (New-Try 'https' 'not-http'))) (New-Svc 'docker' 'homepage' 3000) 'proxynet'
Test-Condition 'backend: a 400 that is not a protocol mismatch says the app refuses the hostname' ($hv400[0] -eq 'failed' -and $hv400[1] -match 'allowed-hosts' -and $hv400[1] -match 'app\.example\.com') ($hv400 -join ' ')
$ok = ConvertFrom-BackendProbe (& $probe @(New-Try 'http' 'http' 302)) $svc 'proxynet'
$au = ConvertFrom-BackendProbe (& $probe @(New-Try 'http' 'http' 401)) $svc 'proxynet'
Test-Condition 'backend: a redirect passes; 401 is authentication required' ($ok[0] -eq 'ok' -and $au[0] -eq 'auth') "$($ok -join ' ') | $($au -join ' ')"
$sk = ConvertFrom-BackendProbe ([ordered]@{ performed = $false; tries = @(); detail = 'Traefik is not running.' }) $svc 'proxynet'
Test-Condition 'backend: a probe that could not run is "skipped", never passed' ($sk[0] -eq 'skipped') ''

# --- Cloudflare tunnel route --------------------------------------------------------------------------------------------------
$rule = { param($Svc, $Path = '') $o = [pscustomobject]@{ hostname = 'app.example.com'; service = $Svc }; if ($Path) { $o | Add-Member -NotePropertyName path -NotePropertyValue $Path }; @($o, [pscustomobject]@{ service = 'http_status:404' }) }
Test-Condition 'tunnel route: missing hostname fails (catch-all 404)' ((ConvertFrom-TunnelRoute @([pscustomobject]@{ service = 'http_status:404' }) 'app.example.com' 4 't')[0] -eq 'failed') ''
$tl = ConvertFrom-TunnelRoute (& $rule 'http://localhost:8180') 'app.example.com' 4 't'
$t127 = ConvertFrom-TunnelRoute (& $rule 'http://127.0.0.1:8180') 'app.example.com' 4 't'
Test-Condition 'tunnel route: localhost / 127.0.0.1 is cloudflared''s own container, not Windows' ($tl[0] -eq 'failed' -and $tl[1] -match 'cloudflared itself' -and $t127[0] -eq 'failed') ($tl -join ' ')
$ts = ConvertFrom-TunnelRoute (& $rule 'https://traefik:443') 'app.example.com' 4 't'
Test-Condition 'tunnel route: https to Traefik fails (HTTPS ends at Cloudflare; Traefik''s web entry point is HTTP)' ($ts[0] -eq 'failed' -and $ts[1] -match 'plain HTTP') ($ts -join ' ')
Test-Condition 'tunnel route: another origin fails; a path restriction warns; no connector fails; the right route passes' ((ConvertFrom-TunnelRoute (& $rule 'http://10.0.0.5:80') 'app.example.com' 4 't')[0] -eq 'failed' -and (ConvertFrom-TunnelRoute (& $rule 'http://traefik:80' '/api') 'app.example.com' 4 't')[0] -eq 'warning' -and (ConvertFrom-TunnelRoute (& $rule 'http://traefik:80') 'app.example.com' 0 't' 'down')[0] -eq 'failed' -and (ConvertFrom-TunnelRoute (& $rule 'http://traefik:80') 'app.example.com' 4 't')[0] -eq 'ok') ''

# --- Cloudflare Access and the first failing hop -----------------------------------------------------------------------------
$login = ConvertFrom-PublicProbe 302 'https://team.cloudflareaccess.com/cdn-cgi/access/login/app.example.com' '' 'access'
Test-Condition 'public URL: an Access login redirect proves Access; the application is "authentication required", not passed' ($login.access -eq 'ok' -and $login.app -eq 'auth' -and $login.message -match 'not reached') ($login | ConvertTo-Json -Compress)
$checks = @((New-HealthCheck 'dns' 'DNS record' 'ok' ''), (New-HealthCheck 'router' 'Traefik router' 'ok' ''), (New-HealthCheck 'http' 'Application HTTP response' 'failed' 'b'), (New-HealthCheck 'backend' 'Traefik to backend' 'failed' 'a'), (New-HealthCheck 'public' 'Public URL' 'auth' ''))
$ff = Get-FirstFailure $checks
Test-Condition 'first failure: the earliest failed hop in request order (backend before the HTTP check), auth is not a failure' ($ff.id -eq 'backend' -and $null -eq (Get-FirstFailure @((New-HealthCheck 'public' 'Public URL' 'auth' '')))) ($ff | ConvertTo-Json -Compress)

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
