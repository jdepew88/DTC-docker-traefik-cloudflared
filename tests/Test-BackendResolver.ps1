#requires -version 5.1
<#
.SYNOPSIS
  Backend address selection and connection-test classification, without Docker or a network: Windows apps typed as
  127.0.0.1 or as this PC's LAN address, host.docker.internal on Docker Desktop and on native Linux / Podman / Unraid,
  other LAN devices, containers on the shared network, on several networks or on none, Docker subnets that capture a
  LAN address, deliberate overrides; then HTTP success, redirects, logins, rejected hostnames, HTTP/HTTPS mismatches,
  wrong ports, DNS failures, refusals, timeouts, invalid certificates and unavailable apps. The live counterparts run
  in Test-Discovery.ps1's disposable instance.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-BackendResolver.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\DockerDiscovery.psm1') -Force
Import-Module (Join-Path $repo 'lib\ServiceHealth.psm1') -Force
Import-Module (Join-Path $repo 'lib\BackendResolver.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  $status = $(if ($Condition) { 'PASS' } else { 'FAIL' })
  $null = $script:Results.Add([pscustomobject]@{ Status = $status; Test = $Name })
  Write-Host ('[{0}] {1}  {2}' -f $status, $Name, $(if ($Condition) { '' } else { $Detail })) -ForegroundColor $(if ($Condition) { 'Green' } else { 'Red' })
}
function Show($R) { return ($R | ConvertTo-Json -Depth 6 -Compress) }

# A container as Get-DockerContainerInventory returns it. $Nets: @(@(name, ip, aliases...)). $Pub: @(@(port, hostIp, hostPort)).
function New-Container([string]$Name, [string]$Image, $Nets, [int[]]$Ports, $Pub = @(), [string]$State = 'running') {
  $c = [ordered]@{ name = $Name; image = $Image; state = $State; networks = @(); exposed = @(); published = @(); privateService = $false; infrastructure = $false; traefik = [ordered]@{ routers = @(); servicePorts = @() } }
  foreach ($n in @($Nets)) { $c.networks += [ordered]@{ name = $n[0]; ipv4 = $n[1]; aliases = @(@($n) | Select-Object -Skip 2) } }
  foreach ($p in $Ports) { $c.exposed += [ordered]@{ port = $p; proto = 'tcp' } }
  foreach ($p in @($Pub)) { $c.published += [ordered]@{ port = [int]$p[0]; proto = 'tcp'; hostIp = [string]$p[1]; hostPort = [int]$p[2] } }
  $c.privateService = [bool]($Image -match '(^|/)(postgres|redis|mariadb|mysql)(:|@|$)')
  $c.ports = @(Get-PortCandidates $c)
  return $c
}

$subnets = @([ordered]@{ name = 'proxynet'; subnet = '172.25.0.0/16' }, [ordered]@{ name = 'unifi-lan_unifi_net'; subnet = '10.10.0.0/24' }, [ordered]@{ name = 'apps'; subnet = '172.30.0.0/16' })
$desktop = [ordered]@{ adapter = (Get-HostAdapter 'Docker Desktop 4.50.0 (200000)' 'Docker Desktop'); hostGateway = 'host.docker.internal'; hostGatewayVerified = $true
  localAddresses = @('10.10.0.11', '192.168.86.1'); dockerSubnets = $subnets; proxyNetwork = 'proxynet'; traefikNetworks = @('proxynet', 'traefik-ext1_tunnel', 'traefik-ext1_socket-internal') }
$plain = [ordered]@{ adapter = $desktop.adapter; hostGateway = 'host.docker.internal'; hostGatewayVerified = $true; localAddresses = @('192.168.1.20'); dockerSubnets = @($subnets[0]); proxyNetwork = 'proxynet'; traefikNetworks = @('proxynet') }
$containers = @(
  (New-Container 'uptime-kuma' 'louislam/uptime-kuma:2' @(, @('proxynet', '172.25.0.4', 'uptime-kuma', 'app')) @(3001) @(, @(3001, '127.0.0.1', 3001))),
  (New-Container 'traefik-manager' 'ghcr.io/x/traefik-manager:1' @(, @('proxynet', '172.25.0.5', 'traefik-manager')) @(5000) @(, @(5000, '127.0.0.1', 5000))),
  (New-Container 'homepage' 'ghcr.io/gethomepage/homepage:v2' @(, @('proxynet', '172.25.0.6', 'homepage', 'app')) @(3000) @(, @(3000, '127.0.0.1', 3010))),
  (New-Container 'portainer' 'portainer/portainer-ce:2.45.2' @(, @('proxynet', '172.25.0.7', 'portainer')) @(8000, 9000, 9443) @(, @(9443, '127.0.0.1', 9443))),
  (New-Container 'multi' 'nginx:1' @(@('backend', '172.31.0.3', 'multi'), @('proxynet', '172.25.0.9', 'multi', 'web')) @(80)),
  (New-Container 'isolated' 'nginx:1' @(, @('apps', '172.30.0.2', 'isolated')) @(80) @(, @(80, '0.0.0.0', 8088))),
  (New-Container 'isolated-local' 'nginx:1' @(, @('apps', '172.30.0.3', 'isolated-local')) @(80) @(, @(80, '127.0.0.1', 8089))),
  (New-Container 'db' 'postgres:16' @(, @('apps', '172.30.0.4', 'db')) @(5432)),
  (New-Container 'bridged' 'nginx:1' @(, @('bridge', '172.17.0.5')) @(80))
)
$resolve = { param($Loc, $Addr, $Env = $desktop, [int]$Port = 0, [switch]$Override) Resolve-BackendAddress -Location $Loc -Address $Addr -Port $Port -Environment $Env -Containers $containers -Override:$Override }

# --- Parsing -----------------------------------------------------------------------------------------------------------------------
$sp = Split-BackendAddress 'HTTP://LocalHost:4119/x?y'
Test-Condition 'parse: scheme, host and port from a pasted URL; a bare host has port 0' ($sp.scheme -eq 'http' -and $sp.host -eq 'localhost' -and $sp.port -eq 4119 -and (Split-BackendAddress 'uptime-kuma').port -eq 0) (Show $sp)

# --- Windows-hosted applications -----------------------------------------------------------------------------------------------
$r = & $resolve 'this-computer' '127.0.0.1:4119'
$g = @($r.guidance | Where-Object { $_.id -eq 'loopback' })
Test-Condition 'Windows app typed as 127.0.0.1:4119 -> host.docker.internal:4119, with "Use the Docker host address instead"' ($r.recommended.url -eq 'http://host.docker.internal:4119' -and $r.recommended.type -eq 'host' -and $g.Count -eq 1 -and $g[0].title -eq 'Use the Docker host address instead' -and $g[0].text -match 'own container' -and $g[0].action -eq 'use-recommended' -and $r.detectedLocation -eq 'this-computer') (Show $r)
$r = & $resolve 'auto' 'http://localhost:4119'
Test-Condition 'Windows app typed as localhost (any location) is also recognised as this computer' ($r.recommended.url -eq 'http://host.docker.internal:4119' -and $r.kind -eq 'loopback') (Show $r)
$r = & $resolve 'auto' '10.10.0.11:4119'
$g = @($r.guidance | Where-Object { $_.id -eq 'own-lan-ip' })
Test-Condition 'Windows app typed as the host''s LAN IP 10.10.0.11:4119 -> host.docker.internal:4119, naming the capturing Docker network' ($r.recommended.url -eq 'http://host.docker.internal:4119' -and $r.kind -eq 'this-pc-ip' -and $g.Count -eq 1 -and $g[0].text -match 'unifi-lan_unifi_net' -and $g[0].text -match "this computer's own address") (Show $r)
$r = & $resolve 'lan' '10.10.0.11:4119'
Test-Condition 'chosen "another device" but the address is this PC: treated as this computer (after confirming it is a local address)' ($r.recommended.type -eq 'host' -and $r.detectedLocation -eq 'this-computer' -and (@($r.evidence) -join ' ') -match 'treated as an app on this computer') (Show $r)
$r = & $resolve 'this-computer' '' $desktop 4119
Test-Condition 'host.docker.internal: just a port on this computer -> the verified host gateway, no correction to explain' ($r.recommended.url -eq 'http://host.docker.internal:4119' -and -not @($r.guidance | Where-Object { $_.action -eq 'use-recommended' }).Count) (Show $r)
$r = & $resolve 'auto' 'host.docker.internal:9696'
Test-Condition 'host.docker.internal typed directly is kept (kind host-gateway)' ($r.kind -eq 'host-gateway' -and $r.recommended.url -eq 'http://host.docker.internal:9696') (Show $r)

# --- Ports that containers publish on Windows ------------------------------------------------------------------------------------
$r = & $resolve 'this-computer' '127.0.0.1:3010'
Test-Condition 'a Windows port published by a container (127.0.0.1:3010) -> that container by name and internal port (homepage:3000)' ($r.recommended.url -eq 'http://homepage:3000' -and $r.recommended.type -eq 'docker' -and @($r.guidance | Where-Object { $_.id -eq 'published-by-container' }).Count -eq 1 -and $r.detectedLocation -eq 'docker') (Show $r)
$r = & $resolve 'docker' 'homepage:3010'
Test-Condition 'a container with its published Windows port -> its internal port, explained' ($r.recommended.port -eq 3000 -and @($r.guidance | Where-Object { $_.id -eq 'published-port' }).Count -eq 1) (Show $r)

# --- Containers ----------------------------------------------------------------------------------------------------------------------
$r = & $resolve 'docker' 'uptime-kuma'
Test-Condition 'Uptime Kuma container on proxynet -> uptime-kuma:3001 (Docker DNS name, internal port)' ($r.recommended.url -eq 'http://uptime-kuma:3001' -and $r.recommended.via -eq 'proxynet' -and -not $r.ambiguous) (Show $r)
$r = & $resolve 'docker' 'traefik-manager'
Test-Condition 'Traefik Manager container -> its verified DNS name on port 5000' ($r.recommended.url -eq 'http://traefik-manager:5000') (Show $r)
$r = & $resolve 'docker' 'portainer'
Test-Condition 'Portainer: its plain-HTTP UI port 9000 is chosen (not the Edge tunnel 8000, not the self-signed 9443)' ($r.recommended.url -eq 'http://portainer:9000' -and -not $r.ambiguous) (Show $r)
$r = & $resolve 'docker' 'multi'
Test-Condition 'a container on several networks: the network shared with Traefik (proxynet) is used, and the choice is explained' ($r.recommended.via -eq 'proxynet' -and (@($r.evidence) -join ' ') -match 'on 2 networks') (Show $r)
$r = & $resolve 'docker' 'web'
Test-Condition 'a network alias finds its container' ($r.container -eq 'multi' -and $r.recommended.host -eq 'multi') (Show $r)
$r = & $resolve 'docker' '172.25.0.4:3001'
Test-Condition 'a container''s internal IP -> its name (IPs change on recreation)' ($r.recommended.host -eq 'uptime-kuma' -and @($r.guidance | Where-Object { $_.id -eq 'container-ip' }).Count -eq 1) (Show $r)
$r = & $resolve 'docker' 'isolated'
Test-Condition 'a container on another network, published on all interfaces: options (published port via the host gateway, or a persistent Compose attachment), not a silent pick' ($r.ambiguous -and @($r.candidates).Count -eq 2 -and $r.candidates[0].url -eq 'http://host.docker.internal:8088' -and $r.candidates[1].action -eq 'attach' -and $r.candidates[1].reason -match 'compose file' -and @($r.guidance | Where-Object { $_.id -eq 'not-shared' }).Count -eq 1) (Show $r)
$r = & $resolve 'docker' 'isolated-local'
Test-Condition 'a container on another network published on 127.0.0.1 only: only the Compose attachment is offered' (@($r.candidates).Count -eq 1 -and $r.candidates[0].action -eq 'attach' -and (@($r.evidence) -join ' ') -match 'cannot reach') (Show $r)
$r = & $resolve 'docker' 'db'
Test-Condition 'a database on another network is never offered for attachment or publishing' (-not $r.recommended -and @($r.guidance | Where-Object { $_.id -eq 'private' -and $_.severity -eq 'error' }).Count -eq 1) (Show $r)
$r = & $resolve 'docker' 'bridged'
Test-Condition 'a container on the default bridge only: no shared network, attachment offered' (@($r.candidates | Where-Object { $_.action -eq 'attach' }).Count -eq 1) (Show $r)
$r = & $resolve 'docker' 'nosuch'
Test-Condition 'an unknown container name is reported, kept as typed' ($r.kind -eq 'unknown-name' -and @($r.guidance | Where-Object { $_.id -eq 'no-container' }).Count -eq 1) (Show $r)
$amb = New-Container 'two' 'x/app:1' @(, @('proxynet', '172.25.0.20', 'two')) @(8080, 8081)
$r = Resolve-BackendAddress -Location 'docker' -Address 'two' -Environment $desktop -Containers @($amb)
Test-Condition 'two equally likely web ports and none typed: ambiguous, both offered as port choices' ($r.ambiguous -and @($r.portChoices).Count -eq 2) (Show $r)
$stopped = New-Container 'sleepy' 'nginx:1' @(, @('proxynet', '172.25.0.21', 'sleepy')) @(80) @() 'exited'
$r = Resolve-BackendAddress -Location 'docker' -Address 'sleepy' -Environment $desktop -Containers @($stopped)
Test-Condition 'a stopped container is reported' (@($r.guidance | Where-Object { $_.id -eq 'stopped' }).Count -eq 1) (Show $r)

# --- Other LAN devices ---------------------------------------------------------------------------------------------------------------
$r = & $resolve 'lan' '10.10.0.8:32800' $plain
Test-Condition 'a remote LAN device (Plex 10.10.0.8:32800) is kept as typed, with no local-host warning' ($r.recommended.url -eq 'http://10.10.0.8:32800' -and $r.recommended.type -eq 'lan' -and @($r.guidance).Count -eq 0) (Show $r)
$r = & $resolve 'lan' 'nas.home.arpa:5000' $plain
Test-Condition 'a LAN DNS name is kept as typed' ($r.recommended.url -eq 'http://nas.home.arpa:5000' -and $r.kind -eq 'lan-name') (Show $r)
$r = & $resolve 'lan' '10.10.0.8:32800'
Test-Condition 'a LAN address inside an overlapping Docker subnet: reported (names the network), not recommended, never replaced by host.docker.internal' (-not $r.recommended -and @($r.guidance | Where-Object { $_.id -eq 'subnet-overlap' -and $_.text -match 'unifi-lan_unifi_net' }).Count -eq 1 -and -not @($r.candidates | Where-Object { $_.host -eq 'host.docker.internal' }).Count) (Show $r)
$r = & $resolve 'this-computer' '10.10.0.8:32800' $plain
Test-Condition 'chosen "this computer" but the address is another device: kept, with a note' ($r.recommended.type -eq 'lan' -and @($r.guidance | Where-Object { $_.id -eq 'not-this-pc' }).Count -eq 1) (Show $r)

# --- Native Linux, Podman, Unraid -------------------------------------------------------------------------------------------------
$deb = Get-HostAdapter 'Docker Engine - Community' 'Debian GNU/Linux 12 (bookworm)'
$pod = Get-HostAdapter 'Podman Engine' 'fedora'
$unr = Get-HostAdapter 'Docker Engine - Community' 'Unraid OS 7.1'
Test-Condition 'host adapters: Docker Desktop has a built-in host gateway; Debian, Podman and Unraid need a verified mapping' ($desktop.adapter.builtIn -and -not $deb.builtIn -and $deb.id -eq 'linux' -and $pod.id -eq 'podman' -and $unr.id -eq 'unraid' -and $deb.hint -match 'host-gateway') ''
$linux = [ordered]@{ adapter = $deb; hostGateway = 'host.docker.internal'; hostGatewayVerified = $false; localAddresses = @('192.168.1.20'); dockerSubnets = @($subnets[0]); proxyNetwork = 'proxynet'; traefikNetworks = @('proxynet') }
$r = & $resolve 'this-computer' '127.0.0.1:4119' $linux
Test-Condition 'native Linux without the host-gateway mapping: host.docker.internal is not assumed; the options are shown' (-not @($r.candidates | Where-Object { $_.host -eq 'host.docker.internal' }).Count -and $r.ambiguous -and @($r.guidance | Where-Object { $_.id -eq 'no-host-gateway' -and $_.text -match 'extra_hosts' }).Count -eq 1 -and @($r.candidates | Where-Object { $_.host -eq '192.168.1.20' }).Count -eq 1) (Show $r)
$linux.hostGatewayVerified = $true
$r = & $resolve 'this-computer' '127.0.0.1:4119' $linux
Test-Condition 'native Linux with a verified mapping: host.docker.internal is recommended' ($r.recommended.url -eq 'http://host.docker.internal:4119') (Show $r)

# --- Overrides -----------------------------------------------------------------------------------------------------------------------
$r = & $resolve 'lan' '10.20.0.5:8080' $plain -Override
Test-Condition 'a deliberate override is kept as typed; the resolver''s own suggestion stays available' ($r.override -and $r.recommended.url -eq 'http://10.20.0.5:8080' -and $r.recommended.via -eq 'override' -and $r.suggested.url -eq 'http://10.20.0.5:8080') (Show $r)
$r = & $resolve 'this-computer' '10.10.0.11:4119' $desktop -Override
Test-Condition 'an override of this PC''s LAN address is kept (with the explanation), the suggestion remains host.docker.internal' ($r.override -and $r.recommended.host -eq '10.10.0.11' -and $r.suggested.url -eq 'http://host.docker.internal:4119' -and @($r.guidance | Where-Object { $_.id -eq 'own-lan-ip' }).Count -eq 1) (Show $r)
$r = & $resolve 'this-computer' '127.0.0.1:4119' $desktop -Override
Test-Condition 'an override to 127.0.0.1 is refused: inside Traefik it is Traefik' (-not $r.override -and $r.recommended.url -eq 'http://host.docker.internal:4119' -and @($r.guidance | Where-Object { $_.id -eq 'override-loopback' }).Count -eq 1) (Show $r)

# --- Connection test classification -----------------------------------------------------------------------------------------------
function New-Try([string]$Scheme, [string]$Result, [int]$Status = 0, [string]$Detail = '', [string]$Location = '', [int]$Final = 0) {
  return [ordered]@{ scheme = $Scheme; url = "${Scheme}://h:1/"; result = $Result; status = $Status; detail = $Detail; location = $Location; finalStatus = $(if ($Final) { $Final } else { $Status }); verified = $false; evidence = @("HTTP/1.1 $Status") }
}
function New-Svc([string]$Type = 'docker', [string]$TargetHost = 'web', [int]$Port = 80, [string]$Protocol = 'http', [bool]$Skip = $false) {
  return [pscustomobject]@{ name = 'x'; hostnames = @('app.example.com'); pathPrefix = ''; stripPrefix = $false; enabled = $true
    target = [pscustomobject]@{ type = $Type; host = $TargetHost; port = $Port; protocol = $Protocol; tlsSkipVerify = $Skip } }
}
$probe = { param($Tries) [ordered]@{ performed = $true; tries = @($Tries); timeout = 5; hostname = 'app.example.com' } }
$v = { param($Tries, $Svc = (New-Svc), [int[]]$Known = @()) Get-BackendVerdict (& $probe @($Tries)) $Svc 'proxynet' $Known }

$x = & $v @(New-Try 'http' 'http' 200)
Test-Condition 'connection: HTTP 200 is "Verified reachable" (green)' ($x.result -eq 'verified' -and $x.state -eq 'ok' -and $x.label -eq 'Verified reachable') (Show $x)
$x = & $v @(New-Try 'http' 'http' 302 '' '/dashboard' 200)
Test-Condition 'connection: a redirect to a page that answers is an application redirect (passes)' ($x.result -eq 'redirect' -and $x.state -eq 'ok' -and $x.message -match '/dashboard') (Show $x)
$x = & $v @(New-Try 'http' 'http' 302 '' '/login?next=/' 200)
Test-Condition 'connection: a redirect to a login page is "authentication required", not green' ($x.result -eq 'auth' -and $x.state -eq 'auth') (Show $x)
$x = & $v @(New-Try 'http' 'http' 302 '' 'http://web:8080/start' 0)
Test-Condition 'connection: a redirect to an internal address is a warning' ($x.result -eq 'redirect' -and $x.state -eq 'warning') (Show $x)
$x = & $v @(New-Try 'http' 'http' 401)
Test-Condition 'connection: 401 is "Reachable, authentication required"' ($x.result -eq 'auth' -and $x.label -match 'authentication required') (Show $x)
$x = & $v @((New-Try 'http' 'http' 400), (New-Try 'https' 'not-http'))
Test-Condition 'connection: HTTP 400 is "Hostname rejected" (never healthy), naming the allowed-hosts settings' ($x.result -eq 'host-rejected' -and $x.state -eq 'failed' -and $x.message -match 'HOMEPAGE_ALLOWED_HOSTS') (Show $x)
$x = & $v @((New-Try 'http' 'http' 400), (New-Try 'https' 'http' 200)) (New-Svc 'docker' 'portainer' 9443)
$y = & $v @((New-Try 'https' 'not-http' 0 'TLS handshake failed.'), (New-Try 'http' 'http' 200)) (New-Svc 'docker' 'web' 80 'https')
Test-Condition 'connection: HTTP to an HTTPS port and HTTPS to an HTTP port are "Wrong protocol"' ($x.result -eq 'wrong-protocol' -and $x.message -match 'protocol to https' -and $y.result -eq 'wrong-protocol' -and $y.message -match 'protocol to http') "$(Show $x) $(Show $y)"
$x = & $v @(New-Try 'http' 'closed') (New-Svc 'docker' 'web' 8081) @(80)
Test-Condition 'connection: refused on a port the container does not declare is "Wrong port", naming the declared ports' ($x.result -eq 'wrong-port' -and $x.message -match 'declares port\(s\) 80' -and $x.message -match 'Connection refused') (Show $x)
$x = & $v @(New-Try 'http' 'closed') (New-Svc 'host' 'host.docker.internal' 4119)
Test-Condition 'connection: refused on a Windows host port is "Connection refused"' ($x.result -eq 'refused' -and $x.label -eq 'Connection refused') (Show $x)
$x = & $v @(New-Try 'http' 'error' 0 'The container name does not resolve on that network.')
Test-Condition 'connection: a name that does not resolve is "DNS resolution failure"' ($x.result -eq 'dns' -and $x.state -eq 'failed') (Show $x)
$x = & $v @(New-Try 'http' 'timeout') (New-Svc 'lan' '10.10.0.11' 4119)
Test-Condition 'connection: no answer is "Timeout" (Docker routing, Firewall, loopback-only listener)' ($x.result -eq 'timeout' -and $x.message -match 'Firewall') (Show $x)
$x = & $v @((New-Try 'https' 'tls' 0 'The certificate could not be verified.'), (New-Try 'https' 'http' 200)) (New-Svc 'docker' 'portainer' 9443 'https')
Test-Condition 'connection: a self-signed certificate is "TLS verification failure" and suggests the plain-HTTP port, not skipping verification' ($x.result -eq 'tls' -and $x.state -eq 'failed' -and $x.message -match 'Portainer: 9000') (Show $x)
$x = & $v @((New-Try 'https' 'tls' 0 'The certificate could not be verified.'), (New-Try 'https' 'http' 200)) (New-Svc 'docker' 'portainer' 9443 'https' $true)
Test-Condition 'connection: with skip verification set deliberately, the answer counts and the unverified certificate is noted' ($x.result -eq 'verified' -and $x.message -match 'not verified') (Show $x)
$x = & $v @(New-Try 'http' 'http' 503)
$z = & $v @(New-Try 'http' 'http' 404)
Test-Condition 'connection: 503 is "Application error" and 404 an unexpected answer: warnings, never green' ($x.result -eq 'unavailable' -and $x.state -eq 'warning' -and $z.result -eq 'http-error' -and $z.state -eq 'warning') "$(Show $x) $(Show $z)"
$x = Get-BackendVerdict ([ordered]@{ performed = $false; tries = @(); detail = 'Traefik is not running.' }) (New-Svc) 'proxynet'
Test-Condition 'connection: a test that could not run is "Not tested" (skipped), never passed' ($x.result -eq 'not-tested' -and $x.state -eq 'skipped') (Show $x)
$ev = Get-ProbeEvidence @('  HTTP/1.1 302 Found', '  Set-Cookie: session=abc123', '  Location: /login?next=/&token=s3cr3t', '  WWW-Authenticate: Basic realm="x"', 'wget: server returned error: HTTP/1.1 401')
Test-Condition 'evidence: cookies are dropped, secret-looking query values are masked, auth challenges keep only the scheme' (($ev -join '|') -notmatch 'abc123|s3cr3t|realm' -and ($ev -join '|') -match 'token=<redacted>' -and ($ev -join '|') -match 'WWW-Authenticate: Basic') ($ev -join ' | ')

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
