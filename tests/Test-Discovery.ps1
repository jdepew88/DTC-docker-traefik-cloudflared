#requires -version 5.1
<#
.SYNOPSIS
  Docker discovery and publishing tests: parsing and classification (unit), then a disposable instance with
  throwaway application containers (discovery, port probes, hostname claims, publishing through the shared network and
  through a published port, conflict blocking, request-path health, failure states) and the browser workflow.

.DESCRIPTION
  Nothing outside the disposable instance is changed: every container and network it creates carries the instance's
  unique prefix and is removed at the end; every other container on the engine must keep its ID, start time and state.
  No real Cloudflare call is made (the Cloudflare API mock is used and the instance is local only).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Discovery.ps1 -ScreenshotDir $env:TEMP\tpm-discovery-shots
#>
[CmdletBinding()]
param([string]$ScreenshotDir, [switch]$SkipBrowser, [switch]$SkipInstance, [string]$TunnelSubnet = '172.31.246.0/28')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\Dashboard.psm1') -Force
Import-Module (Join-Path $repo 'lib\DockerDiscovery.psm1') -Force
Import-Module (Join-Path $repo 'lib\ServiceHealth.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\EdgeCdp.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Invoke-Ps([string]$Script, [string[]]$Arguments) {
  $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Text = (@($out) -join "`n") }
}
function Get-EngineSnapshot([string]$ExcludePrefix) {
  $map = @{}
  foreach ($line in (Invoke-Docker ps -a --format '{{.Names}}').Output) {
    if (-not $line -or $line.StartsWith($ExcludePrefix) -or $line -match '-validate-') { continue }
    $map[$line] = ((Invoke-Docker inspect $line --format '{{.Id}} {{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim()
  }
  return $map
}
function Get-Check($Health, [string]$Id) { return @($Health.checks | Where-Object { $_.id -eq $Id })[0] }

# --- Part 1: unit tests ---------------------------------------------------------------------------------------------------
$fixture = @'
{ "Id": "0123456789abcdef0123", "Name": "/media-prowlarr-1",
  "Config": { "Image": "ghcr.io/hotio/prowlarr:release-1.2", "Env": ["API_KEY=super-secret-value"], "Cmd": ["--password", "hunter2"],
    "ExposedPorts": { "9696/tcp": {}, "53/udp": {} },
    "Labels": { "com.docker.compose.project": "media", "com.docker.compose.service": "prowlarr", "com.docker.compose.project.working_dir": "D:\\media",
      "traefik.http.routers.prow.rule": "Host(`prow.example.com`)", "traefik.http.services.prow.loadbalancer.server.port": "9696" } },
  "State": { "Status": "running", "Health": { "Status": "healthy" } },
  "HostConfig": { "RestartPolicy": { "Name": "unless-stopped" } },
  "Mounts": [ { "Source": "C:\\secret\\path" } ],
  "NetworkSettings": { "Networks": { "media_default": { "IPAddress": "172.40.0.5", "Aliases": ["prowlarr"] } },
    "Ports": { "9696/tcp": [ { "HostIp": "0.0.0.0", "HostPort": "9696" } ], "53/udp": null, "2375/tcp": [ { "HostIp": "127.0.0.1", "HostPort": "2375" } ] } } }
'@ | ConvertFrom-Json
$c = ConvertFrom-DockerInspect $fixture
$json = $c | ConvertTo-Json -Depth 8 -Compress
Test-Condition 'inspect: name, image, tag, compose project/service, health, restart policy' ($c.name -eq 'media-prowlarr-1' -and $c.tag -eq 'release-1.2' -and $c.compose.project -eq 'media' -and $c.compose.service -eq 'prowlarr' -and $c.health -eq 'healthy' -and $c.restart -eq 'unless-stopped') $json
Test-Condition 'inspect: environment, command line and mount sources are never returned' ($json -notmatch 'super-secret-value' -and $json -notmatch 'hunter2' -and $json -notmatch 'secret\\\\path' -and $json -notmatch '"Env"') $json
Test-Condition 'inspect: networks, exposed and published ports (published-only ports included)' (@($c.networks).Count -eq 1 -and $c.networks[0].ipv4 -eq '172.40.0.5' -and @($c.exposed | ForEach-Object { "$($_.port)/$($_.proto)" }) -join ',' -eq '53/udp,2375/tcp,9696/tcp' -and @($c.published | Where-Object { $_.port -eq 9696 -and $_.hostPort -eq 9696 }).Count -eq 1) ($c.exposed | ConvertTo-Json -Compress)
Test-Condition 'inspect: Traefik labels -> router hosts and service port' ($c.traefik.routers[0].hosts[0] -eq 'prow.example.com' -and @($c.traefik.servicePorts) -contains 9696) ''
$ports = Get-PortCandidates $c
Test-Condition 'ports: the labelled port ranks first as HTTP; UDP is never HTTP; the Docker API is blocked' ($ports[0].port -eq 9696 -and $ports[0].guess -eq 'http' -and @($ports | Where-Object { $_.port -eq 53 })[0].guess -eq 'not-http' -and @($ports | Where-Object { $_.port -eq 2375 })[0].guess -eq 'blocked') ($ports | ConvertTo-Json -Compress)
$db = [ordered]@{ exposed = @([ordered]@{ port = 5432; proto = 'tcp' }, [ordered]@{ port = 8443; proto = 'tcp' }, [ordered]@{ port = 8191; proto = 'tcp' }); published = @(); traefik = [ordered]@{ servicePorts = @() } }
$dp = Get-PortCandidates $db
Test-Condition 'ports: HTTPS and unknown ports rank above database ports' (($dp | ForEach-Object { "$($_.port):$($_.guess)" }) -join ',' -eq '8443:https,8191:unknown,5432:not-http') (($dp | ForEach-Object { "$($_.port):$($_.guess)" }) -join ',')
$priv = @('valkey/valkey:9', 'postgres:16-alpine', 'ghcr.io/immich-app/postgres:14-vectorchord0.4.3', 'mongodb/mongodb-community-server:8.2-ubi8', 'lldap/lldap:v0.6.3', 'nats:2.11-alpine', 'ghcr.io/hotio/prowlarr:latest', 'traefik/whoami:v1.12.0') | ForEach-Object { $x = ConvertFrom-DockerInspect ("{`"Id`":`"p`",`"Name`":`"/p`",`"Config`":{`"Image`":`"$_`"},`"State`":{`"Status`":`"running`"},`"NetworkSettings`":{}}" | ConvertFrom-Json); "$($_)=$($x.privateService)" }
Test-Condition 'inspect: databases, caches, brokers and directory servers are private services; applications are not' (($priv -join ',') -eq 'valkey/valkey:9=True,postgres:16-alpine=True,ghcr.io/immich-app/postgres:14-vectorchord0.4.3=True,mongodb/mongodb-community-server:8.2-ubi8=True,lldap/lldap:v0.6.3=True,nats:2.11-alpine=True,ghcr.io/hotio/prowlarr:latest=False,traefik/whoami:v1.12.0=False') ($priv -join ', ')
$infra = ConvertFrom-DockerInspect ('{"Id":"a","Name":"/x-traefik","Config":{"Image":"traefik:v3.7.15"},"State":{"Status":"running"},"NetworkSettings":{}}' | ConvertFrom-Json)
$who = ConvertFrom-DockerInspect ('{"Id":"b","Name":"/who","Config":{"Image":"traefik/whoami:v1.12.0"},"State":{"Status":"running"},"NetworkSettings":{}}' | ConvertFrom-Json)
Test-Condition 'inspect: reverse proxies and tunnel connectors are infrastructure; whoami is an application' ($infra.infrastructure -and -not $who.infrastructure) ''

$services = @([pscustomobject]@{ name = 'mediabox'; hostnames = @('mediabox.example.com') })
$routers = @([pscustomobject]@{ name = 'manual@file'; rule = 'Host(`manual.example.com`)'; provider = 'file' }, [pscustomobject]@{ name = 'svc-mediabox@file'; rule = 'Host(`mediabox.example.com`)'; provider = 'file' })
$claims = @(Find-HostnameClaims -Hostname 'mediabox.example.com' -Services $services -Routers $routers -Containers @($c))
Test-Condition 'claims: a hostname of another registry service is an error' (@($claims).Count -eq 1 -and $claims[0].source -eq 'registry' -and $claims[0].level -eq 'error') ($claims | ConvertTo-Json -Compress)
Test-Condition 'claims: editing the owning service itself is not a conflict' (@(Find-HostnameClaims -Hostname 'mediabox.example.com' -Services $services -Routers $routers -OwnService 'mediabox').Count -eq 0) ''
$m = @(Find-HostnameClaims -Hostname 'MANUAL.example.com' -Services $services -Routers $routers)
Test-Condition 'claims: a router of another provider in this Traefik is an error (case-insensitive)' (@($m).Count -eq 1 -and $m[0].source -eq 'traefik:file' -and $m[0].level -eq 'error') ($m | ConvertTo-Json -Compress)
$l = @(Find-HostnameClaims -Hostname 'prow.example.com' -Containers @($c))
Test-Condition 'claims: container labels are reported as a warning (they may belong to another Traefik)' (@($l).Count -eq 1 -and $l[0].source -eq 'labels' -and $l[0].level -eq 'warning') ''
Test-Condition 'claims: the public dashboard hostname is reserved' (@(Find-HostnameClaims -Hostname 't.example.com' -DashboardHostname 't.example.com').Count -eq 1) ''
Test-Condition 'claims: a free hostname has no claims' (@(Find-HostnameClaims -Hostname 'free.example.com' -Services $services -Routers $routers -Containers @($c)).Count -eq 0) ''

$pn = Get-ProbeNetwork ([ordered]@{ name = 'x'; networks = @([ordered]@{ name = 'other'; ipv4 = '1.2.3.4' }, [ordered]@{ name = 'proxy'; ipv4 = '5.6.7.8' }) }) 'proxy'
$pb = Get-ProbeNetwork ([ordered]@{ name = 'x'; networks = @([ordered]@{ name = 'bridge'; ipv4 = '172.17.0.9' }) }) 'proxy'
$ph = Get-ProbeNetwork ([ordered]@{ name = 'x'; networks = @([ordered]@{ name = 'host'; ipv4 = '' }) }) 'proxy'
Test-Condition 'probe network: the shared network first; the default bridge by address; host network: none' ($pn.network -eq 'proxy' -and $pn.target -eq 'x' -and $pb.network -eq 'bridge' -and $pb.target -eq '172.17.0.9' -and $null -eq $ph) ''
$ok = ConvertFrom-ProbeOutput @('Connecting to x:80 (172.20.0.3:80)', '  HTTP/1.1 200 OK', '  Content-Type: text/plain') 0
$err404 = ConvertFrom-ProbeOutput @('Connecting to x:80', 'wget: server returned error: HTTP/1.1 404 Not Found') 1
$refused = ConvertFrom-ProbeOutput @('wget: can''t connect to remote host (172.20.0.3): Connection refused') 1
$raw = ConvertFrom-ProbeOutput @('Connecting to x:5432', 'wget: bad header line: hello') 1
Test-Condition 'probe output: HTTP status (also 404), refused, not HTTP' ($ok.result -eq 'http' -and $ok.status -eq 200 -and $err404.result -eq 'http' -and $err404.status -eq 404 -and $refused.result -eq 'closed' -and $raw.result -eq 'not-http') ''
$t404 = ConvertFrom-RoutedStatus 404 "404 page not found`n" '' 'a.example.com'
$a404 = ConvertFrom-RoutedStatus 404 '<html>Not here</html>' '' 'a.example.com'
Test-Condition 'routed status: Traefik''s own 404 fails (no router), an app''s 404 means the app answered' ($t404[0] -eq 'failed' -and $a404[0] -eq 'ok') ''
Test-Condition 'routed status: 502 and 504 fail with the backend named; 401 means the app answered and asks for a login' ((ConvertFrom-RoutedStatus 502 'Bad Gateway' '' 'a')[0] -eq 'failed' -and (ConvertFrom-RoutedStatus 504 '' '' 'a')[0] -eq 'failed' -and (ConvertFrom-RoutedStatus 401 '' '' 'a')[0] -eq 'auth' -and (ConvertFrom-RoutedStatus 0 '' 'refused' 'a')[0] -eq 'failed') ''
Test-Condition 'routed status: a timeout names the backend, not Traefik, as the waiting side' ((ConvertFrom-RoutedStatus 0 '' 'The operation has timed out.' 'a')[1] -match 'waiting for the backend') ''
$login = ConvertFrom-PublicProbe 302 'https://team.cloudflareaccess.com/cdn-cgi/access/login/a' '' 'access'
Test-Condition 'public URL: an Access login redirect verifies Access only, never the application' ($login.access -eq 'ok' -and $login.app -eq 'auth' -and $login.message -match 'not reached') ''
Test-Condition 'public URL: 200 without a login on an Access-protected service fails Access' ((ConvertFrom-PublicProbe 200 '' '' 'access').access -eq 'failed') ''
Test-Condition 'public URL: Cloudflare 530 / 502 fail the application path' ((ConvertFrom-PublicProbe 530 '' '' 'public').app -eq 'failed' -and (ConvertFrom-PublicProbe 502 '' '' 'public').app -eq 'failed' -and (ConvertFrom-PublicProbe 200 '' '' 'public').app -eq 'ok') ''

# --- Part 2: disposable instance ----------------------------------------------------------------------------------------------
if ($SkipInstance) { Add-Result 'SKIP' 'disposable instance' '-SkipInstance' }
elseif (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'disposable instance' 'Docker engine not running' }
else {
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
  $stack = "tpx-dc-$id"; $network = "$stack-proxy"; $appsNet = "$stack-apps"
  $work = Join-Path ([IO.Path]::GetTempPath()) $stack
  $installPath = Join-Path $work 'instance'
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
  $o = $TunnelSubnet.Split('/')[0].Split('.')
  $envFile = Join-Path $work 'instance.env'
  $httpPort = Get-FreeTcpPort
  @("STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$httpPort", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$network", "TUNNEL_SUBNET=$TunnelSubnet",
    "TUNNEL_IP_RANGE=$($o[0]).$($o[1]).$($o[2]).$($o[3])/29", "CLOUDFLARED_IP=$($o[0]).$($o[1]).$($o[2]).$([int]$o[3] + 10)", 'TRAEFIK_LOG_LEVEL=INFO') | Set-Content -LiteralPath $envFile -Encoding ASCII
  $apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N')
  $secretEnv = 'SECRET_' + [Guid]::NewGuid().ToString('N')
  $whoami = 'traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44'
  $traefikImage = (Get-StackSettings -InstallPath $repo).TraefikImage
  $before = Get-EngineSnapshot $stack
  $installed = $false; $ui = $null; $mock = $null; $cdp = $null
  $app1 = "$stack-web1"; $app2 = "$stack-web2"; $dbc = "$stack-db"; $lab = "$stack-labelled"; $cache = "$stack-cache"; $cacheImage = "$stack/valkey:test"
  $pubPort = Get-FreeTcpPort
  try {
    $install = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-Start')
    $installed = Test-Path -LiteralPath $installPath
    Test-Condition 'instance: install -Start (local only, disposable)' ($install.ExitCode -eq 0) ($install.Text -split "`n" | Select-Object -Last 12 | Out-String)
    if ($install.ExitCode -ne 0) { throw 'Install failed.' }
    $null = Invoke-Docker network create $appsNet
    $r1 = Invoke-Docker run -d --name $app1 --network $appsNet -p "0.0.0.0:${pubPort}:80" -e "TOKEN=$secretEnv" --pull missing $whoami
    $r2 = Invoke-Docker run -d --name $app2 --network $appsNet $whoami
    $r3 = Invoke-Docker run -d --name $dbc --network $appsNet --expose 5432 --entrypoint sh $traefikImage -c 'while true; do echo hello | nc -l -p 5432; done'
    $r4 = Invoke-Docker run -d --name $lab --network $appsNet --label 'traefik.http.routers.lab.rule=Host(`taken.example.test`)' $whoami
    Test-Condition 'fixtures: throwaway application containers on their own network' ($r1.ExitCode -eq 0 -and $r2.ExitCode -eq 0 -and $r3.ExitCode -eq 0 -and $r4.ExitCode -eq 0) (($r1.Output + $r2.Output + $r3.Output + $r4.Output) -join ' ')
    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
    $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $installPath -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
    $null = Connect-WebUi $ui

    $d = Invoke-WebUi $ui GET '/api/docker/containers'
    $w1 = @($d.Data.containers | Where-Object { $_.name -eq $app1 })[0]
    $own = @($d.Data.containers | Where-Object { $_.name -eq "$stack-traefik" })[0]
    Test-Condition 'discovery: containers with networks, ports (guess + published port) and proxy-network flag' ($d.Status -eq 200 -and $w1 -and $w1.state -eq 'running' -and $w1.networks[0].name -eq $appsNet -and -not $w1.onProxyNetwork -and $w1.ports[0].port -eq 80 -and $w1.ports[0].guess -eq 'http' -and $w1.ports[0].hostPort -eq $pubPort) "HTTP $($d.Status)"
    Test-Condition 'discovery: this deployment''s own containers are marked (and are infrastructure)' ($own -and $own.ownInstance -and $own.infrastructure) ''
    Test-Condition 'discovery: no environment values reach the browser' ($d.Body -notmatch [regex]::Escape($secretEnv) -and $d.Body -notmatch '"Env"') ''
    Test-Condition 'discovery: label claims are listed per container' (@(@($d.Data.containers | Where-Object { $_.name -eq $lab })[0].traefik.routers)[0].hosts[0] -eq 'taken.example.test') ''

    $pr = Invoke-WebUi $ui POST '/api/docker/probe' @{ container = $app1; port = 80 }
    Test-Condition 'probe: HTTP on the app network via a short-lived probe container (status 200)' ($pr.Status -eq 200 -and $pr.Data.result -eq 'http' -and $pr.Data.status -eq 200 -and $pr.Data.method -eq 'probe-container' -and $pr.Data.network -eq $appsNet) ($pr.Body)
    $pd = Invoke-WebUi $ui POST '/api/docker/probe' @{ container = $dbc; port = 5432 }
    Test-Condition 'probe: a TCP service that is not HTTP is reported as such' ($pd.Status -eq 200 -and $pd.Data.result -in 'not-http', 'closed') ($pd.Body)
    $pc = Invoke-WebUi $ui POST '/api/docker/probe' @{ container = $app1; port = 8999 }
    Test-Condition 'probe: a port nothing listens on is closed' ($pc.Data.result -eq 'closed') ($pc.Body)
    $pz = Invoke-WebUi $ui POST '/api/docker/probe' @{ container = $app1; port = 2375 }
    $pn2 = Invoke-WebUi $ui POST '/api/docker/probe' @{ container = 'bad name;rm'; port = 80 }
    Test-Condition 'probe: the Docker API port and invalid names are refused' ($pz.Status -eq 400 -and $pn2.Status -eq 400) "$($pz.Status) $($pn2.Status)"
    $leftProbes = @((Invoke-Docker ps -a --filter 'label=org.traefik-proxy.probe=1' --format '{{.Names}}').Output | Where-Object { $_ })
    Test-Condition 'probe: probe containers are removed after use' ($leftProbes.Count -eq 0) ($leftProbes -join ', ')

    $cl = Invoke-WebUi $ui GET '/api/docker/claims?hostname=taken.example.test'
    $cf = Invoke-WebUi $ui GET '/api/docker/claims?hostname=free.example.test'
    Test-Condition 'claims API: label claim reported; a free hostname is free' ($cl.Status -eq 200 -and @($cl.Data.claims).Count -eq 1 -and $cl.Data.claims[0].source -eq 'labels' -and $cf.Data.free -and @($cf.Data.claims).Count -eq 0) "$($cl.Body) $($cf.Body)"

    # Publish through the published port (no Docker change).
    $p1 = Invoke-WebUiChange $ui @{ op = 'add'; name = 'web-hostport'; service = @{ name = 'web-hostport'; hostnames = @('hp.example.test'); middlewares = @('default-headers@file'); target = @{ type = 'host'; host = 'host.docker.internal'; port = $pubPort; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    Test-Condition 'publish: through the published port (host.docker.internal), no Docker change' ($p1.Apply -and $p1.Apply.Data.ok -and -not (@((Invoke-Docker inspect $app1 --format '{{json .NetworkSettings.Networks}}').Output) -join '' -match [regex]::Escape($network))) "$($p1.Plan.Status) $(if ($p1.Apply) { $p1.Apply.Body })"
    Start-Sleep -Seconds 2
    $h1 = Invoke-WebUi $ui POST '/api/services/health' @{ name = 'web-hostport' }
    Test-Condition 'health: router and service loaded; Docker Desktop''s host address answers from Traefik''s network; the app answers through Traefik' ($h1.Status -eq 200 -and (Get-Check $h1.Data 'router').state -eq 'ok' -and (Get-Check $h1.Data 'service').state -eq 'ok' -and (Get-Check $h1.Data 'backend').performed -and (Get-Check $h1.Data 'backend').state -eq 'ok' -and (Get-Check $h1.Data 'backend').message -match 'host\.docker\.internal' -and (Get-Check $h1.Data 'http').state -eq 'ok' -and $null -eq $h1.Data.firstFailure) ($h1.Body)
    Test-Condition 'publish: the apply reports the backend reachable from Traefik as its own step' (@($p1.Apply.Data.steps | Where-Object { $_.name -eq 'Backend reachable from Traefik' -and $_.status -eq 'Done' }).Count -eq 1) ($p1.Apply.Body)
    Test-Condition 'health: local only, so DNS, Access and tunnel are reported as not performed (never as passed)' (@($h1.Data.checks | Where-Object { $_.id -in 'dns', 'access', 'tunnel' -and (-not $_.performed) -and $_.state -eq 'skipped' }).Count -eq 3 -and $h1.Data.performed -lt $h1.Data.total) ''

    # Attach to the shared network (explicit confirmation) and publish over it.
    $nc0 = Invoke-WebUi $ui POST '/api/docker/connect' @{ container = $app1 }
    $ncOwn = Invoke-WebUi $ui POST '/api/docker/connect' @{ container = "$stack-traefik"; confirm = $true }
    # A cache (image named like valkey: a local tag of an image already here) is never attached to the shared network.
    $null = Invoke-Docker tag $traefikImage $cacheImage
    $null = Invoke-Docker run -d --name $cache --network $appsNet --entrypoint sh $cacheImage -c 'sleep 600'
    $ncCache = Invoke-WebUi $ui POST '/api/docker/connect' @{ container = $cache; confirm = $true }
    $cacheNets = (@((Invoke-Docker inspect $cache --format '{{json .NetworkSettings.Networks}}').Output) -join '')
    Test-Condition 'network: a database or cache container is refused and stays off the shared network' ($ncCache.Status -eq 400 -and $ncCache.Body -match 'private network' -and $cacheNets -notmatch [regex]::Escape($network)) "$($ncCache.Status) $($ncCache.Body)"
    Test-Condition 'network: attaching needs confirmation; the deployment''s own containers are refused' ($nc0.Status -eq 400 -and $ncOwn.Status -eq 400) "$($nc0.Status) $($ncOwn.Status)"
    $nc = Invoke-WebUi $ui POST '/api/docker/connect' @{ container = $app1; confirm = $true }
    $nets = (@((Invoke-Docker inspect $app1 --format '{{json .NetworkSettings.Networks}}').Output) -join '')
    Test-Condition 'network: attached with confirmation; the response includes the compose lines to keep it' ($nc.Status -eq 200 -and $nc.Data.changed -and $nets -match [regex]::Escape($network) -and (@($nc.Data.composeSnippet) -join "`n") -match 'external: true') $nc.Body
    $p2 = Invoke-WebUiChange $ui @{ op = 'add'; name = 'web-net'; service = @{ name = 'web-net'; hostnames = @('net.example.test'); middlewares = @('default-headers@file'); target = @{ type = 'docker'; host = $app1; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    Test-Condition 'publish: over the shared network by container name' ($p2.Apply -and $p2.Apply.Data.ok) "$($p2.Plan.Status) $(if ($p2.Apply) { $p2.Apply.Body })"
    Start-Sleep -Seconds 2
    $h2 = Invoke-WebUi $ui POST '/api/services/health' @{ name = 'web-net' }
    Test-Condition 'health: backend running on the shared network and HTTP 200 through Traefik' ((Get-Check $h2.Data 'backend').state -eq 'ok' -and (Get-Check $h2.Data 'http').state -eq 'ok' -and (Get-Check $h2.Data 'http').message -match '200') ($h2.Body)

    # Backend diagnosis before anything is applied (one request from Traefik's network namespace per preview).
    $diagPlan = { param($Target) Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'add'; name = 'diag'; service = @{ name = 'diag'; hostnames = @('diag.example.test'); middlewares = @('default-headers@file'); target = $Target; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } } }
    $wp = & $diagPlan @{ type = 'docker'; host = $app1; port = 8081; protocol = 'http' }
    Test-Condition 'diagnosis: a wrong backend port is reported before applying (connection refused from Traefik''s network)' ((@($wp.Data.notes) -join ' ') -match 'Connection refused') ($wp.Body)
    $wpr = & $diagPlan @{ type = 'docker'; host = $app1; port = 80; protocol = 'https' }
    Test-Condition 'diagnosis: HTTPS to a plain HTTP backend is reported as a protocol mismatch' ((@($wpr.Data.notes) -join ' ') -match 'speaks HTTP,') ($wpr.Body)
    $app2Ip = ((Invoke-Docker inspect $app2 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}').Output -join '').Trim()
    $wsub = & $diagPlan @{ type = 'lan'; host = $app2Ip; port = 80; protocol = 'http' }
    Test-Condition 'diagnosis: a LAN address inside a Docker network''s subnet is reported with the network''s name' ((@($wsub.Data.notes) -join ' ') -match ([regex]::Escape("inside Docker network '$appsNet'"))) ($wsub.Body)
    $wlo = & $diagPlan @{ type = 'lan'; host = '127.0.0.1'; port = $pubPort; protocol = 'http' }
    Test-Condition 'diagnosis: 127.0.0.1 (Windows localhost) as a target is refused: inside a container it is the container itself' (-not $wlo.Data.canApply -and (@($wlo.Data.traefik.issues | ForEach-Object { $_.Message }) -join ' ') -match 'Loopback') ($wlo.Body)
    $wto = & $diagPlan @{ type = 'lan'; host = '192.0.2.10'; port = 80; protocol = 'http' }
    Test-Condition 'diagnosis: a backend that never answers is reported as a timeout' ((@($wto.Data.notes) -join ' ') -match 'No answer from 192\.0\.2\.10:80 within') ($wto.Body)
    Test-Condition 'readiness: the preview carries the verdict (Timeout) and asks for an acknowledgment before saving a failing backend' ($wto.Data.backend.result -eq 'timeout' -and $wto.Data.needsBackendAck) ($wto.Body)

    # Automatic backend selection (POST /api/services/backend), verified from Traefik's network.
    $rb = Invoke-WebUi $ui POST '/api/services/backend' @{ location = 'docker'; address = $app1; hostname = 'pick.example.test'; test = $true }
    Test-Condition 'resolver: a container on the shared network -> its name and internal port, verified from Traefik''s network' ($rb.Status -eq 200 -and $rb.Data.resolution.recommended.url -eq "http://${app1}:80" -and $rb.Data.verification.result -eq 'verified' -and $rb.Data.verification.state -eq 'ok' -and $rb.Data.traefikYaml -match [regex]::Escape("http://${app1}:80")) ($rb.Body)
    Test-Condition 'resolver: Docker Desktop is recognised and host.docker.internal is verified inside this Traefik' ($rb.Data.environment.adapter.id -eq 'docker-desktop' -and $rb.Data.environment.hostGatewayVerified -eq $true -and @($rb.Data.environment.traefikNetworks) -contains $network) ($rb.Data.environment | ConvertTo-Json -Compress -Depth 4)
    $rpub = Invoke-WebUi $ui POST '/api/services/backend' @{ location = 'this-computer'; address = "http://127.0.0.1:$pubPort/"; test = $true }
    Test-Condition 'resolver: a Windows address whose port a container publishes -> that container by name, verified' ($rpub.Data.resolution.recommended.url -eq "http://${app1}:80" -and @($rpub.Data.resolution.guidance | Where-Object { $_.id -eq 'published-by-container' }).Count -eq 1 -and $rpub.Data.verification.result -eq 'verified') ($rpub.Body)
    $freePort = Get-FreeTcpPort
    $rwin = Invoke-WebUi $ui POST '/api/services/backend' @{ location = 'this-computer'; address = "127.0.0.1:$freePort"; test = $true }
    Test-Condition 'resolver: a Windows-hosted app typed as 127.0.0.1 -> host.docker.internal with "Use the Docker host address instead"; nothing listening is not green' ($rwin.Data.resolution.suggested.url -eq "http://host.docker.internal:$freePort" -and @($rwin.Data.resolution.guidance | Where-Object { $_.title -eq 'Use the Docker host address instead' }).Count -eq 1 -and $rwin.Data.verification.state -eq 'failed' -and $rwin.Data.verification.result -in 'refused', 'timeout') ($rwin.Body)
    $rlan = Invoke-WebUi $ui POST '/api/services/backend' @{ location = 'lan'; address = '192.0.2.44:32400' }
    Test-Condition 'resolver: another LAN device is kept as typed, without a local-host warning' ($rlan.Data.resolution.recommended.url -eq 'http://192.0.2.44:32400' -and -not @($rlan.Data.resolution.guidance | Where-Object { $_.id -in 'loopback', 'own-lan-ip' }).Count) ($rlan.Body)
    $roth = Invoke-WebUi $ui POST '/api/services/backend' @{ location = 'docker'; address = $app2 }
    Test-Condition 'resolver: a container on another network gets the options (its compose attachment), not a silent pick' (@($roth.Data.resolution.candidates | Where-Object { $_.action -eq 'attach' }).Count -eq 1 -and @($roth.Data.resolution.guidance | Where-Object { $_.id -eq 'not-shared' }).Count -eq 1) ($roth.Body)

    # Readiness: applying a route whose backend fails needs an explicit acknowledgment; the plan stays valid meanwhile.
    $gp = Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'add'; name = 'gate'; service = @{ name = 'gate'; hostnames = @('gate.example.test'); target = @{ type = 'lan'; host = '192.0.2.10'; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    $ga = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $gp.Data.planId; confirm = $true }
    $gExists = Test-Path -LiteralPath (Join-Path $installPath 'traefik\dynamic\svc-gate.yml')
    $gb = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $gp.Data.planId; confirm = $true; acceptUnverifiedBackend = $true }
    Test-Condition 'readiness: a failing backend is not saved without acknowledgment (409, nothing written); with it, saved and reported as not ready' ($ga.Status -eq 409 -and $ga.Data.needsBackendAck -and -not $gExists -and $gb.Status -eq 200 -and @($gb.Data.steps | Where-Object { $_.name -eq 'Backend reachable from Traefik' -and $_.status -eq 'Warning' -and $_.message -match 'Timeout' }).Count -eq 1) "$($ga.Status) $($ga.Body) | $($gb.Body)"
    $null = Invoke-WebUiChange $ui @{ op = 'remove'; name = 'gate'; cloudflare = @{ automate = $false } }

    # Recreating a container keeps its shared-network membership only when its compose file declares the network.
    $composeDir = Join-Path $work 'composed'; New-Item -ItemType Directory -Force -Path $composeDir | Out-Null
    $composed = "$stack-composed"
    [IO.File]::WriteAllText((Join-Path $composeDir 'compose.yaml'), "name: $composed`nservices:`n  web:`n    image: $whoami`n    container_name: $composed`n    networks: [proxy]`nnetworks:`n  proxy:`n    name: $network`n    external: true`n")
    $cu = Invoke-Docker compose -f (Join-Path $composeDir 'compose.yaml') up -d
    $pc3 = Invoke-WebUiChange $ui @{ op = 'add'; name = 'composed'; service = @{ name = 'composed'; hostnames = @('composed.example.test'); middlewares = @('default-headers@file'); target = @{ type = 'docker'; host = $composed; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    $cr = Invoke-Docker compose -f (Join-Path $composeDir 'compose.yaml') up -d --force-recreate
    Start-Sleep -Seconds 2
    $hc = Invoke-WebUi $ui POST '/api/services/health' @{ name = 'composed' }
    Test-Condition 'recreation: a compose-declared container is back on the shared network after --force-recreate and still answers through Traefik' ($cu.ExitCode -eq 0 -and $pc3.Apply -and $pc3.Apply.Data.ok -and $cr.ExitCode -eq 0 -and (Get-Check $hc.Data 'backend').state -eq 'ok' -and (Get-Check $hc.Data 'http').state -eq 'ok') "$($cr.Output -join ' ') $($hc.Body)"
    $null = Invoke-Docker network connect $network $app2
    $null = Invoke-Docker rm -f $app2
    $null = Invoke-Docker run -d --name $app2 --network $appsNet $whoami
    $pc4 = & $diagPlan @{ type = 'docker'; host = $app2; port = 80; protocol = 'http' }
    Test-Condition 'recreation: an attachment made only with docker network connect is lost on recreation, and the preview says so' ((@($pc4.Data.notes) -join ' ') -match 'is not attached to') ($pc4.Body)
    $null = Invoke-Docker compose -f (Join-Path $composeDir 'compose.yaml') down

    # One owner per hostname.
    [IO.File]::WriteAllText((Join-Path $installPath 'traefik\dynamic\manual.local.yml'), "http:`n  routers:`n    manual:`n      rule: 'Host(``manual.example.test``)'`n      entryPoints: [web]`n      service: manual`n  services:`n    manual:`n      loadBalancer:`n        servers:`n          - url: http://127.0.0.1:9`n")
    $null = Sync-TraefikDynamic -Settings (Get-StackSettings -InstallPath $installPath)
    $deadline = (Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 800; $rt = Invoke-WebUi $ui GET '/api/infrastructure' } while ((Get-Date) -lt $deadline -and -not ($rt.Body -match 'manual@file'))
    $dup = Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'add'; name = 'dup'; service = @{ name = 'dup'; hostnames = @('manual.example.test'); target = @{ type = 'docker'; host = $app1; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    Test-Condition 'conflicts: a hostname another router already serves cannot be applied' ($dup.Status -eq 200 -and -not $dup.Data.canApply -and (@($dup.Data.traefik.issues | ForEach-Object { $_.Message }) -join ' ') -match 'already routed elsewhere') ($dup.Body)
    $dupReg = Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'add'; name = 'dup2'; service = @{ name = 'dup2'; hostnames = @('net.example.test'); target = @{ type = 'docker'; host = $app1; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    Test-Condition 'conflicts: a hostname of another service of this deployment cannot be applied' (-not $dupReg.Data.canApply) ($dupReg.Body)
    $labWarn = Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'add'; name = 'lab'; service = @{ name = 'lab'; hostnames = @('taken.example.test'); target = @{ type = 'docker'; host = $app1; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    Test-Condition 'conflicts: label claims of other containers are shown as a note before applying' ((@($labWarn.Data.notes) -join ' ') -match 'Traefik router for it in its labels') ($labWarn.Body)

    if ($SkipBrowser -or -not (Get-EdgePath)) { Add-Result 'SKIP' 'browser checks' $(if ($SkipBrowser) { '-SkipBrowser' } else { 'Edge not found' }) }
    else {
      $base = "http://127.0.0.1:$($ui.Port)"
      $cdp = Start-EdgeSession -WorkDir $work
      Set-Viewport $cdp 1366 900
      Open-Page $cdp $ui.LaunchUrl
      $null = Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && document.querySelector('main h1')" 30
      $go = { param($hash, $ready) Open-Page $cdp "$base/#$hash"; Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && ($ready)" 40 }
      $ok = & $go 'services' "document.querySelector('.entry-cards')"
      $entry = [string](Invoke-PageScript $cdp "document.querySelector('.entry-cards').innerText")
      Test-Condition 'services: three entry points (discover, install, manual)' ($ok -and $entry -match 'Discover running containers' -and $entry -match 'Install a new application' -and $entry -match 'Enter an HTTP backend manually') $entry
      $ok = & $go 'discover' "document.querySelector('.disc-card')"
      $names = @(Invoke-PageScript $cdp "[...document.querySelectorAll('.disc-card')].map((a) => a.getAttribute('aria-label'))")
      Test-Condition 'discover: application containers listed; infrastructure and stopped hidden by default' ($ok -and $names -contains $app2 -and $names -notcontains "$stack-traefik") ($names -join ', ')
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('.disc-toolbar label')].find((l) => l.textContent.includes('infrastructure')).querySelector('input').click(); true"
      Start-Sleep -Milliseconds 300
      $names2 = @(Invoke-PageScript $cdp "[...document.querySelectorAll('.disc-card')].map((a) => a.getAttribute('aria-label'))")
      $ownText = [string](Invoke-PageScript $cdp "(() => { const a = [...document.querySelectorAll('.disc-card')].find((x) => x.getAttribute('aria-label') === '$stack-traefik'); return a ? a.innerText : ''; })()")
      Test-Condition 'discover: infrastructure can be shown, and is never offered for publishing' ($names2 -contains "$stack-traefik" -and $ownText -cnotmatch 'Publish' -and $ownText -match 'Part of this deployment') $ownText
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'discover-1366.png') }
      $ok = & $go "publish/$app2" "document.querySelector('form.wizard') && document.querySelector('#pub-sub')"
      $sub0 = [string](Invoke-PageScript $cdp "document.querySelector('#pub-sub').value")
      Test-Condition 'wizard: the hostname is suggested from the application name' ($ok -and $sub0 -eq ($app2.ToLowerInvariant())) $sub0
      $null = Invoke-PageScript $cdp "(() => { const s = document.querySelector('#pub-sub'); s.value = 'mysite'; s.dispatchEvent(new Event('input', { bubbles: true })); const d = document.querySelector('#pub-display'); d.value = 'My Site'; d.dispatchEvent(new Event('input', { bubbles: true })); })(); true"
      $sub1 = [string](Invoke-PageScript $cdp "document.querySelector('#pub-sub').value")
      $null = Invoke-PageScript $cdp "(() => { const d = document.querySelector('[aria-label=Domain]'); d.value = 'example.test'; d.dispatchEvent(new Event('input', { bubbles: true })); })(); true"
      Test-Condition 'wizard: a manual hostname is kept when the name changes' ($sub1 -eq 'mysite') $sub1
      $ok = Wait-PageCondition $cdp "document.querySelector('.claims') && document.querySelector('.claims').innerText.includes('not used by anything else')" 15
      Test-Condition 'wizard: the hostname is checked against every existing definition' $ok ([string](Invoke-PageScript $cdp "document.querySelector('.claims').innerText"))
      $null = Invoke-PageScript $cdp "document.querySelector('[aria-label=""Test port 80""]').click(); true"
      $ok = Wait-PageCondition $cdp "document.querySelector('.port-choice') && document.querySelector('.port-choice').innerText.includes('HTTP answers')" 40
      Test-Condition 'wizard: Test validates the port with a real HTTP request' $ok ([string](Invoke-PageScript $cdp "document.querySelector('.port-choices').innerText"))
      $reachText = [string](Invoke-PageScript $cdp "document.querySelector('[aria-label=""How Traefik reaches it""]').innerText")
      Test-Condition 'wizard: a container off the shared network offers attaching it (a Docker change asked separately)' ($reachText -match 'Attach to' -and $reachText -match 'docker network connect') $reachText
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'publish-wizard-1366.png') }
      $null = Invoke-PageScript $cdp "(() => { const d = document.querySelector('[aria-label=Domain]'); d.value = 'example.test'; d.dispatchEvent(new Event('input', { bubbles: true })); document.querySelector('form.wizard').requestSubmit(); })(); true"
      $ok = Wait-PageCondition $cdp "document.querySelector('#confirm-dialog').open && document.querySelector('#confirm-title').textContent.includes('Attach')" 15
      $okDisabled = [bool](Invoke-PageScript $cdp "document.querySelector('#confirm-ok').disabled")
      Test-Condition 'wizard: attaching asks for an explicit confirmation first (button disabled until confirmed)' ($ok -and $okDisabled) ''
      $null = Invoke-PageScript $cdp "document.querySelector('#confirm-check').click(); document.querySelector('#confirm-ok').click(); true"
      $ok = Wait-PageCondition $cdp "document.querySelector('#plan-dialog').open && document.querySelector('#plan-title').textContent.includes('my-site')" 60
      Test-Condition 'wizard: then the usual change preview opens (nothing applied yet)' ($ok -and -not (Test-Path -LiteralPath (Join-Path $installPath 'traefik\dynamic\svc-my-site.yml'))) ([string](Invoke-PageScript $cdp "document.querySelector('#plan-title').textContent"))
      $null = Invoke-PageScript $cdp "document.querySelector('#plan-reviewed').click(); [...document.querySelectorAll('#plan-dialog button')].find((b) => b.textContent.includes('Apply changes')).click(); true"
      $ok = Wait-PageCondition $cdp "document.querySelector('#plan-title').textContent.includes('Changes applied')" 120
      $null = Invoke-PageScript $cdp "document.querySelector('#plan-dialog .btn.primary').click(); true"
      $ok = $ok -and (Wait-PageCondition $cdp "location.hash.startsWith('#services/health/my-site') && document.querySelector('#health-host .health-path')" 60)
      $ht = [string](Invoke-PageScript $cdp "document.querySelector('#health-host') ? document.querySelector('#health-host').innerText : ''")
      Test-Condition 'wizard: after publishing, the request-path health is shown (app answers; Cloudflare checks not performed)' ($ok -and $ht -match 'Application HTTP response' -and $ht -match 'answered HTTP 200' -and $ht -match 'not checked') $ht
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'service-health-1366.png') }
      $ok = & $go 'explorer' "document.querySelector('#xp-follow') && document.querySelector('[data-xp-ready]')"
      $null = Invoke-PageScript $cdp "(() => { const s = document.querySelector('#xp-follow'); s.value = 'my-site'; s.dispatchEvent(new Event('change')); })(); true"
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('.xp-toolbar button')].find((b) => b.textContent.includes('Check health')).click(); true"
      $ok = Wait-PageCondition $cdp "document.querySelector('.xp-node[data-id=app].ok')" 40
      Test-Condition 'explorer: following a service and checking health marks the application verified' $ok ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'explorer-health-1366.png') }
      $bad = @()
      foreach ($pg in @(@('discover', "document.querySelector('.disc-card')"), @("publish/$app2", "document.querySelector('form.wizard')"), @('services', "document.querySelector('.entry-cards')"))) {
        foreach ($w in @(390, 820)) {
          Set-Viewport $cdp $w 900 -Mobile:($w -lt 800)
          $null = & $go $pg[0] $pg[1]; Start-Sleep -Milliseconds 300
          $ov = [int](Invoke-PageScript $cdp "document.documentElement.scrollWidth - window.innerWidth")
          if ($ov -gt 1) { $wide = [string](Invoke-PageScript $cdp "[...document.querySelectorAll('main *')].filter((e) => e.getBoundingClientRect().right > window.innerWidth + 1).slice(-3).map((e) => e.tagName.toLowerCase() + '.' + String(e.className).replace(/ /g, '.') + ': ' + (e.textContent || '').trim().slice(0, 60)).join(' | ')"); $bad += "$($pg[0]) at $w px overflows by $ov px ($wide)" }
          if ($ScreenshotDir -and $w -eq 390) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$(($pg[0] -split '/')[0])-390.png") }
        }
        Set-Viewport $cdp 1366 900
        $null = & $go $pg[0] $pg[1]
        $unnamed = @(Invoke-PageScript $cdp "[...document.querySelectorAll('button, a[href], select, input')].filter((e) => e.checkVisibility() && !(e.getAttribute('aria-label') || e.textContent.trim() || (e.id && document.querySelector('label[for=' + JSON.stringify(e.id) + ']')) || e.closest('label'))).map((e) => e.outerHTML.slice(0, 80))")
        if ($unnamed.Count) { $bad += "$($pg[0]) unnamed: $($unnamed -join ' | ')" }
      }
      Test-Condition 'responsive and accessible: discover, wizard and services at 390 / 820 / 1366 px, all controls named' ($bad.Count -eq 0) ($bad -join '; ')
      Test-Condition 'no JavaScript errors' ($cdp.Errors.Count -eq 0) ($cdp.Errors -join ' | ')
    }

    # Failure: the backend stops.
    $null = Invoke-Docker stop $app1
    $h3 = Invoke-WebUi $ui POST '/api/services/health' @{ name = 'web-net' }
    Test-Condition 'health: a stopped backend fails "backend" and the HTTP check reports Bad Gateway' ((Get-Check $h3.Data 'backend').state -eq 'failed' -and (Get-Check $h3.Data 'http').state -eq 'failed' -and (Get-Check $h3.Data 'http').message -match 'Bad Gateway|Gateway Timeout') ($h3.Body)
    # Removing a route never removes the container or its data.
    $rm = Invoke-WebUiChange $ui @{ op = 'remove'; name = 'web-net'; cloudflare = @{ automate = $false } }
    Test-Condition 'remove: deleting the route leaves the application container in place' ($rm.Apply -and $rm.Apply.Data.ok -and (Invoke-Docker inspect $app1).ExitCode -eq 0) ''
  } catch {
    Add-Result 'FAIL' 'discovery test run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
  } finally {
    if ($cdp) { Stop-EdgeSession $cdp }
    Stop-TestServer $ui; Stop-TestServer $mock
    foreach ($n in @($app1, $app2, $dbc, $lab, $cache, "$stack-composed")) { $null = Invoke-Docker rm -f $n }
    $null = Invoke-Docker rmi $cacheImage
    if ($installed) {
      $null = Invoke-Ps (Join-Path $installPath 'install.ps1') @('-InstallPath', $installPath, '-Stop')
      $null = Invoke-Docker rm -f "$stack-whoami"
    }
    $null = Invoke-Docker network rm $network
    $null = Invoke-Docker network rm $appsNet
    $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
    $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
    Test-Condition 'teardown: no disposable containers or networks left' ($left.Count -eq 0 -and $leftNets.Count -eq 0) (($left + $leftNets) -join ', ')
    $after = Get-EngineSnapshot $stack
    $changed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) -or $after[$_] -ne $before[$_] })
    $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
    Test-Condition "other containers untouched ($($before.Count) checked: same IDs, start times, states)" ($changed.Count -eq 0 -and $added.Count -eq 0) ("changed: $($changed -join ', ') added: $($added -join ', ')")
    Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
