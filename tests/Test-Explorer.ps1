#requires -version 5.1
<#
.SYNOPSIS
  Infrastructure Explorer tests: the component model (unit tests with fixture facts), the /api/infrastructure data
  of a disposable running instance, and the Explorer and Overview pages in headless Edge.

.DESCRIPTION
  Part 1 (no Docker): configuration alone never verifies a component; failures are reported per dimension; local-only
  deployments mark the Cloudflare components as not used; competing hostname definitions are detected (but path
  variants of one owner are not); Traefik rules are parsed.
  Part 2 (disposable instance, local only, own stack name, ports, network and subnet): install.ps1 -Start, a throwaway
  whoami backend, a service routed to it, then GET /api/infrastructure while it runs and after the backend stops.
  Part 3 (browser, unless -SkipBrowser): Explorer at 390 / 820 / 1366 px, the four detail levels (Intermediate is the
  default for a new browser profile), keyboard navigation between components, the details panel, following one
  request, pausing the animation, accessible names, and the Overview's small diagram and quick actions.
  Teardown removes the instance; every other container on the engine must be unchanged (same IDs, start times, states).
  Part 4 (-LiveReadOnly): the Explorer model, discovery, hostname claims and the request-path health of every service
  of a real installation, read-only; its files and all containers must be unchanged afterwards.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Explorer.ps1 -ScreenshotDir $env:TEMP\tpm-explorer-shots
#>
[CmdletBinding()]
param([string]$ScreenshotDir, [switch]$SkipBrowser, [switch]$SkipInstance, [string]$TunnelSubnet = '172.31.247.0/28',
  # Read-only checks of a real installation (Docker inspect, Traefik's local API, Cloudflare GET requests with its own
  # stored token, one GET through its Traefik). Asserts that no file and no container changed.
  [switch]$LiveReadOnly, [string]$LivePath = (Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\Infrastructure.psm1') -Force
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
function Get-Component($Model, [string]$Id) { return @($Model.components | Where-Object { $_.id -eq $Id })[0] }
function Get-Dim($Model, [string]$Id, [string]$Dim) { return (Get-Component $Model $Id).dims.$Dim }
function Get-Check2($Health, [string]$Id) { return @($Health.checks | Where-Object { $_.id -eq $Id })[0] }

# --- Part 1: model unit tests -------------------------------------------------------------------------------------------
function New-Facts([hashtable]$Over = @{}) {
  $f = [ordered]@{
    mode = 'tunnel'; installed = $true; stackName = 'demo'; httpPort = 8180; dashboardPort = 8181; proxyNetwork = 'proxy'; cloudflaredIp = '172.31.250.10'
    docker = [pscustomobject]@{ CliFound = $true; EngineRunning = $true; ServerVersion = '29.0'; OsType = 'linux'; ComposeVersion = '2.40'; ComposeOk = $true; Context = 'desktop-linux' }
    stack = [pscustomobject]@{ TraefikApi = $true; TraefikVersion = '3.7.15'; TunnelTokenPresent = $true; Containers = @(
        [pscustomobject]@{ Role = 'traefik'; Name = 'demo-traefik'; Exists = $true; State = 'running'; Health = ''; Image = 'traefik:v3.7.15'; StartedAt = '' },
        [pscustomobject]@{ Role = 'socket-proxy'; Name = 'demo-socket-proxy'; Exists = $true; State = 'running'; Health = ''; Image = 'socket-proxy'; StartedAt = '' },
        [pscustomobject]@{ Role = 'cloudflared'; Name = 'demo-cloudflared'; Exists = $true; State = 'running'; Health = ''; Image = 'cloudflared'; StartedAt = '' }) }
    services = @([pscustomobject]@{ name = 'kuma'; displayName = 'Uptime Kuma'; enabled = $true; hostnames = @('kuma.example.com'); pathPrefix = ''; middlewares = @('default-headers@file')
        target = [pscustomobject]@{ type = 'docker'; host = 'uptime-kuma'; port = 3001; protocol = 'http' }; cloudflare = [pscustomobject]@{ publish = $true; access = $true } })
    cloudflare = [pscustomobject]@{ accountId = 'acc1'; accountName = 'Acc'; tunnelId = 'tun1'; tunnelName = 'home'; domains = @([pscustomobject]@{ id = 'z1'; name = 'example.com' }); managed = [pscustomobject]@{ 'kuma.example.com' = [pscustomobject]@{ accessAppId = 'app1' } } }
    token = [pscustomobject]@{ Stored = $true; Readable = $true }
    tunnel = [ordered]@{ name = 'home'; status = 'healthy'; connections = 4; error = '' }
    tunnelTokenPresent = $true
    dashboard = [ordered]@{ enabled = $false; hostname = ''; router = 'public-dashboard@file' }
    traefikApi = [ordered]@{ ok = $true; version = '3.7.15'; entryPoints = @([ordered]@{ name = 'web'; address = ':80' }, [ordered]@{ name = 'traefik'; address = ':8080' })
      routers = @([ordered]@{ name = 'svc-kuma@file'; status = 'enabled'; rule = 'Host(`kuma.example.com`)'; service = 'svc-kuma'; provider = 'file'; entryPoints = @('web'); middlewares = @('default-headers@file') })
      services = @([ordered]@{ name = 'svc-kuma@file'; status = 'enabled'; provider = 'file'; type = 'loadbalancer'; servers = @('http://uptime-kuma:3001'); serverStatus = @{} })
      middlewares = @([ordered]@{ name = 'default-headers@file'; status = 'enabled'; type = 'headers'; provider = 'file' }) }
    networks = [ordered]@{ proxy = [ordered]@{ name = 'proxy'; exists = $true; driver = 'bridge'; internal = $false; subnets = @('172.20.0.0/16'); containers = @([ordered]@{ name = 'demo-traefik'; ipv4 = '172.20.0.2' }, [ordered]@{ name = 'uptime-kuma'; ipv4 = '172.20.0.3' }) }
      socket = [ordered]@{ name = 'demo_socket-internal'; exists = $true; internal = $true; subnets = @(); containers = @(); driver = 'bridge' } }
    targets = [ordered]@{ 'uptime-kuma' = [ordered]@{ exists = $true; state = 'running'; health = 'healthy'; image = 'louislam/uptime-kuma:1' } }
  }
  foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
  return $f
}

$m = ConvertTo-InfrastructureModel -Facts (New-Facts)
Test-Condition 'model: every path component and tool is present, in order' ((@($m.components | ForEach-Object { $_.id }) -join ',') -eq 'browser,dns,edge,access,tunnel,cloudflared,traefik,router,middleware,identity,service,network,app,docker,compose,socket-proxy,manager') (@($m.components | ForEach-Object { $_.id }) -join ',')
Test-Condition 'model: a healthy tunnel is verified with Cloudflare (connections), cloudflared is reachable' ((Get-Dim $m 'tunnel' 'verified') -eq $true -and (Get-Dim $m 'cloudflared' 'reachable') -eq $true) ''
Test-Condition 'model: Traefik is running, its API reachable and its web entry point verified' ((Get-Dim $m 'traefik' 'running') -eq $true -and (Get-Dim $m 'traefik' 'reachable') -eq $true -and (Get-Dim $m 'traefik' 'verified') -eq $true) ''
Test-Condition 'model: a loaded router is running but NOT verified until a request is tested' ((Get-Dim $m 'router' 'running') -eq $true -and $null -eq (Get-Dim $m 'router' 'verified')) ''
Test-Condition 'model: the application is running and attached, but not verified without an HTTP request' ((Get-Dim $m 'app' 'running') -eq $true -and (Get-Dim $m 'app' 'reachable') -eq $true -and $null -eq (Get-Dim $m 'app' 'verified')) ''
Test-Condition 'model: Access is configured per service; verification is left to the per-service check' ((Get-Dim $m 'access' 'configured') -eq $true -and $null -eq (Get-Dim $m 'access' 'verified')) ''
Test-Condition 'model: one flow per service with its router, middlewares and backend' (@($m.flows).Count -eq 1 -and $m.flows[0].router.status -eq 'enabled' -and $m.flows[0].service.servers[0] -eq 'http://uptime-kuma:3001' -and $m.flows[0].exposure -eq 'access') ''

# Configuration only: files exist, nothing runs, Cloudflare not asked.
$cfgOnly = New-Facts @{
  stack = [pscustomobject]@{ TraefikApi = $false; TraefikVersion = ''; TunnelTokenPresent = $true; Containers = @(
      [pscustomobject]@{ Role = 'traefik'; Name = 'demo-traefik'; Exists = $false; State = 'missing'; Health = ''; Image = ''; StartedAt = '' },
      [pscustomobject]@{ Role = 'socket-proxy'; Name = 'demo-socket-proxy'; Exists = $false; State = 'missing'; Health = ''; Image = ''; StartedAt = '' },
      [pscustomobject]@{ Role = 'cloudflared'; Name = 'demo-cloudflared'; Exists = $false; State = 'missing'; Health = ''; Image = ''; StartedAt = '' }) }
  traefikApi = [ordered]@{ ok = $false; version = ''; entryPoints = @(); routers = @(); services = @(); middlewares = @() }; tunnel = $null; targets = [ordered]@{}; networks = [ordered]@{}
}
$m2 = ConvertTo-InfrastructureModel -Facts $cfgOnly
$verified = @($m2.components | Where-Object { $_.dims.verified -eq $true } | ForEach-Object { $_.id })
Test-Condition 'model: configuration files alone never verify any component' ($verified.Count -eq 0) ($verified -join ', ')
Test-Condition 'model: configured but stopped Traefik is reported as not running (a problem), not as healthy' ((Get-Dim $m2 'traefik' 'configured') -eq $true -and (Get-Dim $m2 'traefik' 'running') -eq $false -and (Get-Dim $m2 'traefik' 'reachable') -eq $false) ''
Test-Condition 'model: without asking Cloudflare, the tunnel is configured but its state is "not checked"' ((Get-Dim $m2 'tunnel' 'configured') -eq $true -and $null -eq (Get-Dim $m2 'tunnel' 'running') -and $null -eq (Get-Dim $m2 'tunnel' 'verified')) ''
$m3 = ConvertTo-InfrastructureModel -Facts (New-Facts @{ tunnel = [ordered]@{ name = 'home'; status = 'down'; connections = 0; error = '' } })
Test-Condition 'model: a tunnel without connectors is a problem (running and verified false)' ((Get-Dim $m3 'tunnel' 'running') -eq $false -and (Get-Dim $m3 'tunnel' 'verified') -eq $false -and (Get-Dim $m3 'cloudflared' 'reachable') -eq $false) ''
$m4 = ConvertTo-InfrastructureModel -Facts (New-Facts @{ targets = [ordered]@{ 'uptime-kuma' = [ordered]@{ exists = $true; state = 'exited'; health = ''; image = 'x' } } })
Test-Condition 'model: a stopped application container is reported as not running' ((Get-Dim $m4 'app' 'running') -eq $false) ''
$net = New-Facts
$net.networks.proxy.containers = @([ordered]@{ name = 'demo-traefik'; ipv4 = '172.20.0.2' })
$m5 = ConvertTo-InfrastructureModel -Facts $net
Test-Condition 'model: an application container that is not on the shared network is unreachable' ((Get-Dim $m5 'app' 'reachable') -eq $false) ''
$m6 = ConvertTo-InfrastructureModel -Facts (New-Facts @{ mode = 'local'; tunnel = $null })
$offIds = @($m6.components | Where-Object { -not $_.applicable } | ForEach-Object { $_.id })
Test-Condition 'model: local only marks DNS, edge, Access, tunnel and cloudflared as not used (and sign-in, when no app is protected)' (($offIds -join ',') -eq 'dns,edge,access,tunnel,cloudflared,identity') ($offIds -join ',')
$bad = New-Facts
$bad.traefikApi.routers = @($bad.traefikApi.routers[0], [ordered]@{ name = 'svc-x@file'; status = 'disabled'; rule = 'Host(`x.example.com`)'; service = 'svc-x'; provider = 'file'; entryPoints = @('web'); middlewares = @('missing@file') })
$bad.services = @($bad.services[0], [pscustomobject]@{ name = 'x'; enabled = $true; hostnames = @('x.example.com'); middlewares = @(); target = [pscustomobject]@{ type = 'lan'; host = '10.0.0.5'; port = 80; protocol = 'http' }; cloudflare = [pscustomobject]@{ publish = $false; access = $false } })
$m7 = ConvertTo-InfrastructureModel -Facts $bad
Test-Condition 'model: a router Traefik disabled is a problem (verified false)' ((Get-Dim $m7 'router' 'verified') -eq $false) ''

$routers = @(
  [ordered]@{ name = 'svc-a@file'; rule = 'Host(`a.example.com`)'; provider = 'file' }, [ordered]@{ name = 'whoami@docker'; rule = 'Host(`a.example.com`)'; provider = 'docker' },
  [ordered]@{ name = 'public-dashboard@file'; rule = 'Host(`t.example.com`) && PathPrefix(`/api`)'; provider = 'file' }, [ordered]@{ name = 'public-dashboard-root@file'; rule = 'Host(`t.example.com`) && Path(`/`)'; provider = 'file' },
  [ordered]@{ name = 'svc-b@file'; rule = 'Host(`b.example.com`) || Host(`www.b.example.com`)'; provider = 'file' }, [ordered]@{ name = 'svc-b-strip@file'; rule = 'Host(`b.example.com`) && PathPrefix(`/x`)'; provider = 'file' })
$cf = New-Facts; $cf.traefikApi.routers = $routers
$m8 = ConvertTo-InfrastructureModel -Facts $cf
Test-Condition 'conflicts: a hostname claimed by a file router and Docker labels is reported' (@($m8.conflicts).Count -eq 1 -and $m8.conflicts[0].hostname -eq 'a.example.com' -and @($m8.conflicts[0].routers).Count -eq 2) ($m8.conflicts | ConvertTo-Json -Compress -Depth 4)
Test-Condition 'conflicts: path variants of one owner (dashboard pair, service + strip) are not conflicts' (-not @($m8.conflicts | Where-Object { $_.hostname -in 't.example.com', 'b.example.com' }).Count) ''
Test-Condition 'rules: every Host() of a rule is found, case-insensitively' ((@(Get-RouterHosts 'Host(`B.example.com`) || Host(`www.b.example.com`) && PathPrefix(`/x`)') -join ',') -eq 'b.example.com,www.b.example.com') ''

# --- Part 2 and 3: disposable instance --------------------------------------------------------------------------------------
if ($SkipInstance) { Add-Result 'SKIP' 'disposable instance and browser' '-SkipInstance' }
elseif (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'disposable instance and browser' 'Docker engine not running' }
else {
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
  $stack = "tpx-xp-$id"; $network = "$stack-proxy"
  $work = Join-Path ([IO.Path]::GetTempPath()) $stack
  $installPath = Join-Path $work 'instance'
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
  $o = $TunnelSubnet.Split('/')[0].Split('.')
  $envFile = Join-Path $work 'instance.env'
  @("STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$(Get-FreeTcpPort)", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$network", "TUNNEL_SUBNET=$TunnelSubnet",
    "TUNNEL_IP_RANGE=$($o[0]).$($o[1]).$($o[2]).$($o[3])/29", "CLOUDFLARED_IP=$($o[0]).$($o[1]).$($o[2]).$([int]$o[3] + 10)", 'TRAEFIK_LOG_LEVEL=INFO') | Set-Content -LiteralPath $envFile -Encoding ASCII
  $apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N')
  $before = Get-EngineSnapshot $stack
  $installed = $false; $ui = $null; $mock = $null; $cdp = $null
  try {
    $install = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-Start')
    $installed = Test-Path -LiteralPath $installPath
    Test-Condition 'instance: install -Start (local only, disposable)' ($install.ExitCode -eq 0) ($install.Text -split "`n" | Select-Object -Last 12 | Out-String)
    if ($install.ExitCode -ne 0) { throw 'Install failed.' }
    $settings = Get-StackSettings -InstallPath $installPath
    $up = Invoke-Docker @((Get-ComposeArgs -Settings $settings -Profiles @('test')) + @('up', '-d', 'whoami'))
    Test-Condition 'instance: throwaway whoami backend started on the instance network' ($up.ExitCode -eq 0) ($up.Output -join ' ')
    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
    $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $installPath -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
    $null = Connect-WebUi $ui
    $add = Invoke-WebUiChange $ui @{ op = 'add'; name = 'echo'; service = @{ name = 'echo'; displayName = 'Echo'; hostnames = @('echo.example.test'); middlewares = @('default-headers@file')
        target = @{ type = 'docker'; host = "$stack-whoami"; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    Test-Condition 'instance: a local service routed to the backend is applied' ($add.Apply -and $add.Apply.Status -eq 200 -and $add.Apply.Data.ok) "plan $($add.Plan.Status) apply $(if ($add.Apply) { $add.Apply.Status })"
    $deadline = (Get-Date).AddSeconds(25)
    do { $r = Invoke-WebUi $ui GET '/api/infrastructure'; if ((Get-Dim $r.Data 'router' 'running') -eq $true) { break }; Start-Sleep -Milliseconds 800 } while ((Get-Date) -lt $deadline)
    $x = $r.Data
    Test-Condition 'api: /api/infrastructure answers with components, flows and instance data' ($r.Status -eq 200 -and @($x.components).Count -eq 17 -and $x.instance.stackName -eq $stack) "HTTP $($r.Status)"
    Test-Condition 'api: local-only instance marks the Cloudflare components as not used' (-not (Get-Component $x 'tunnel').applicable -and -not (Get-Component $x 'dns').applicable) ''
    Test-Condition 'api: Traefik running, API reachable, web entry point verified (live)' ((Get-Dim $x 'traefik' 'running') -eq $true -and (Get-Dim $x 'traefik' 'reachable') -eq $true -and (Get-Dim $x 'traefik' 'verified') -eq $true) (((Get-Component $x 'traefik').evidence | ForEach-Object { $_.text }) -join ' | ')
    Test-Condition 'api: the router of the new service is loaded (running) and not claimed as verified' ((Get-Dim $x 'router' 'running') -eq $true -and $null -eq (Get-Dim $x 'router' 'verified')) (((Get-Component $x 'router').evidence | ForEach-Object { $_.text }) -join ' | ')
    Test-Condition 'api: the shared network exists and Traefik is attached; the backend is running and attached' ((Get-Dim $x 'network' 'reachable') -eq $true -and (Get-Dim $x 'app' 'running') -eq $true -and (Get-Dim $x 'app' 'reachable') -eq $true) (((Get-Component $x 'app').evidence | ForEach-Object { $_.text }) -join ' | ')
    Test-Condition 'api: the socket proxy network is verified as internal' ((Get-Dim $x 'socket-proxy' 'verified') -eq $true) ''
    Test-Condition 'api: the flow names router svc-echo@file and backend http://<whoami>:80' (@($x.flows).Count -eq 1 -and $x.flows[0].router.name -eq 'svc-echo@file' -and $x.flows[0].service.servers[0] -eq "http://${stack}-whoami:80") ($x.flows | ConvertTo-Json -Depth 5 -Compress)
    $json = $r.Body
    if (-not $json) { $json = $x | ConvertTo-Json -Depth 12 -Compress }
    Test-Condition 'api: the explorer data contains no API token and no environment variables' ($json -notmatch [regex]::Escape($apiToken) -and $json -notmatch '"Env"' -and $json -notmatch 'TUNNEL_TOKEN=') ''

    if ($SkipBrowser -or -not (Get-EdgePath)) { Add-Result 'SKIP' 'browser checks' $(if ($SkipBrowser) { '-SkipBrowser' } else { 'Edge not found' }) }
    else {
      $base = "http://127.0.0.1:$($ui.Port)"
      $cdp = Start-EdgeSession -WorkDir $work
      Set-Viewport $cdp 1366 900
      Open-Page $cdp $ui.LaunchUrl
      $null = Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && document.querySelector('main h1')" 30
      $level = [string](Invoke-PageScript $cdp "document.body.dataset.level")
      Test-Condition 'levels: a new browser profile starts at Intermediate' ($level -eq 'intermediate') $level
      $go = { param($hash, $ready) Open-Page $cdp "$base/#$hash"; Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && ($ready)" 30 }
      $ok = & $go 'explorer' "document.querySelectorAll('.xp-node').length >= 12 && document.querySelector('[data-xp-ready]')"
      $nodes = [int](Invoke-PageScript $cdp "document.querySelectorAll('.xp-diagram .xp-node').length")
      $offNodes = [int](Invoke-PageScript $cdp "document.querySelectorAll('.xp-diagram .xp-node.off').length")
      $collapsed = [string](Invoke-PageScript $cdp "document.querySelector('.xp-lane.cloudflare.collapsed') ? document.querySelector('.xp-lane.cloudflare.collapsed').innerText : ''")
      Test-Condition 'explorer: local only collapses the Cloudflare lane; the other cards render, unused ones marked' ($ok -and $nodes -eq 10 -and $offNodes -eq 3 -and $collapsed -match 'not used by this deployment') "nodes $nodes off $offNodes"
      $tools = [string](Invoke-PageScript $cdp "document.querySelector('.xp-tools') ? document.querySelector('.xp-tools').innerText : ''")
      Test-Condition 'explorer: Docker Desktop, Compose, socket proxy and the manager are shown apart from the path' ($tools -match 'Docker Desktop' -and $tools -match 'Docker Compose' -and $tools -match 'No request passes through them') ''
      $verifiedNodes = @(Invoke-PageScript $cdp "[...document.querySelectorAll('.xp-diagram .xp-node.ok')].map((b) => b.dataset.id)")
      Test-Condition 'explorer: only components with a real verification show the green "Verified" state' (@($verifiedNodes | Where-Object { $_ -notin 'traefik' }).Count -eq 0) ($verifiedNodes -join ',')
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'explorer-intermediate-1366.png') }
      # Keyboard: focus the first card, move with the arrow keys, open with Enter.
      $null = Invoke-PageScript $cdp "document.querySelector('.xp-diagram .xp-node').focus(); true"
      Send-Key $cdp 'ArrowRight'; Send-Key $cdp 'ArrowRight'; Send-Key $cdp 'ArrowRight'
      $focused = [string](Invoke-PageScript $cdp "document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.id : ''")
      Send-Key $cdp 'Enter'
      $null = Wait-PageCondition $cdp "document.querySelector('#xp-detail-title')" 10
      $title = [string](Invoke-PageScript $cdp "document.querySelector('#xp-detail-title') ? document.querySelector('#xp-detail-title').textContent : ''")
      Test-Condition 'keyboard: arrow keys move between components and Enter opens the details' ($focused -eq 'traefik' -and $title -match 'Traefik') "focused $focused title $title"
      Test-Condition 'details: the panel is hidden until a component is selected' ([bool](Invoke-PageScript $cdp "!document.querySelector('#xp-detail').hidden")) ''
      $null = Invoke-PageScript $cdp "document.querySelector('.xp-node[data-id=traefik]').click(); true"
      $null = Wait-PageCondition $cdp "document.querySelector('#xp-detail-title') && document.querySelector('#xp-detail-title').textContent.includes('Traefik')" 10
      $d = [string](Invoke-PageScript $cdp "document.querySelector('#xp-detail').innerText")
      Test-Condition 'details: what it does, why, connections, established dimensions, failures, diagnosis, documentation' ($d -match 'reverse proxy' -and $d -match 'Why it is here' -and $d -match 'Connects to' -and $d -match 'Verified' -and $d -match 'How it can fail' -and $d -match 'How to diagnose' -and $d -match 'Documentation') $d.Substring(0, [Math]::Min(400, $d.Length))
      Test-Condition 'details: live evidence of the running instance is shown' ($d -match "$stack-traefik" -and $d -match 'API answers') ''
      $null = Invoke-PageScript $cdp "(() => { const s = document.querySelector('#xp-follow'); s.value = 'echo'; s.dispatchEvent(new Event('change')); })(); true"
      $null = Wait-PageCondition $cdp "document.querySelector('.xp-node[data-id=router] .xp-sub') && document.querySelector('.xp-node[data-id=router] .xp-sub').textContent.includes('svc-echo')" 10
      Test-Condition 'follow: a followed service shows every hop, with the Cloudflare ones not used (local only)' ([int](Invoke-PageScript $cdp "document.querySelectorAll('.xp-diagram .xp-node').length") -eq 13) ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'explorer-follow-service-1366.png') }
      $sub = [string](Invoke-PageScript $cdp "document.querySelector('.xp-node[data-id=app] .xp-sub').textContent")
      Test-Condition 'follow: choosing a service shows its router and backend on the path' ($sub -match "$stack-whoami:80") $sub
      $null = Invoke-PageScript $cdp "__x = [...document.querySelectorAll('.xp-toolbar button')].find((b) => b.textContent.includes('Pause')); __x.click(); true"
      $paused = [bool](Invoke-PageScript $cdp "!!document.querySelector('.xp-diagram.paused') && [...document.querySelectorAll('.xp-toolbar button')].some((b) => b.getAttribute('aria-pressed') === 'true')")
      Test-Condition 'animation: packet flow can be paused (state announced with aria-pressed)' $paused ''
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('.xp-toolbar button')].find((b) => b.getAttribute('aria-pressed') === 'true').click(); true"
      # Detail levels.
      $null = Invoke-PageScript $cdp "TPMUI.setLevel('beginner'); true"; Start-Sleep -Milliseconds 600
      $null = & $go 'explorer' "document.querySelectorAll('.xp-node').length >= 12"
      $easy = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
      $dimsShown = [bool](Invoke-PageScript $cdp "[...document.querySelectorAll('.dim-strip')].some((e) => e.checkVisibility())")
      Test-Condition 'beginner: plain names ("Your browser", "Your app"), no dimension strips, routes table hidden' ($easy -match 'Your browser' -and $easy -match 'Your app' -and -not $dimsShown -and $easy -notmatch 'Routes: router') ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'explorer-beginner-1366.png') }
      $null = Invoke-PageScript $cdp "TPMUI.setLevel('advanced'); true"; Start-Sleep -Milliseconds 600
      $null = & $go 'explorer' "document.querySelectorAll('.xp-node').length >= 12"
      $adv = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
      Test-Condition 'advanced: routes (router -> middlewares -> service) and networking are shown' ($adv -match 'Routes: router' -and $adv -match 'svc-echo@file' -and $adv -match 'Attached containers' -and $adv -match "$stack-whoami") ''
      $null = Invoke-PageScript $cdp "TPMUI.setLevel('expert'); true"; Start-Sleep -Milliseconds 600
      $null = & $go 'explorer/traefik' "document.querySelector('#xp-detail-title') && document.querySelector('[data-xp-ready]')"
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('main button')].find((b) => b.textContent.includes('Show the files')).click(); true"
      $ok = Wait-PageCondition $cdp "[...document.querySelectorAll('main details summary')].some((s) => s.textContent.includes('compose.yaml') || s.textContent.includes('.env'))" 30
      $exp = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
      Test-Condition 'expert: identifiers, raw facts and the generated configuration are inspectable, without secrets' ($ok -and $exp -match 'Identifiers and raw facts' -and $exp -match 'Raw explorer data' -and $exp -notmatch [regex]::Escape($apiToken)) ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'explorer-expert-1366.png') }
      $null = Invoke-PageScript $cdp "TPMUI.setLevel('intermediate'); true"
      # Responsive and accessible.
      $bad = @()
      foreach ($w in @(390, 820, 1366)) {
        Set-Viewport $cdp $w 900 -Mobile:($w -lt 800)
        $null = & $go 'explorer' "document.querySelectorAll('.xp-node').length >= 12"
        Start-Sleep -Milliseconds 300
        $ov = [int](Invoke-PageScript $cdp "document.documentElement.scrollWidth - window.innerWidth")
        if ($ov -gt 1) { $bad += "$w px overflows by $ov px" }
        if ($ScreenshotDir -and $w -ne 1366) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "explorer-$w.png") }
      }
      Set-Viewport $cdp 1366 900
      Test-Condition 'responsive: the Explorer fits 390 / 820 / 1366 px without horizontal scrolling' ($bad.Count -eq 0) ($bad -join '; ')
      $null = & $go 'explorer' "document.querySelectorAll('.xp-node').length >= 12"
      $unnamed = @(Invoke-PageScript $cdp "[...document.querySelectorAll('button, a[href], select, input')].filter((e) => e.checkVisibility() && !(e.getAttribute('aria-label') || e.textContent.trim() || (e.id && document.querySelector('label[for=' + JSON.stringify(e.id) + ']')) || e.closest('label'))).map((e) => e.outerHTML.slice(0, 80))")
      $h1 = [int](Invoke-PageScript $cdp "document.querySelectorAll('main h1').length")
      Test-Condition 'accessibility: every control is named, one h1, the diagram is a labelled group' ($unnamed.Count -eq 0 -and $h1 -eq 1 -and [bool](Invoke-PageScript $cdp "!!document.querySelector('.xp-diagram[role=group][aria-label]')")) ($unnamed -join ' | ')
      $null = & $go 'overview' "document.querySelector('.tiles') && document.querySelector('.xp-mini .xp-diagram')"
      $ovText = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
      Test-Condition 'overview: small diagram and the quick actions (view infrastructure, add, publish, dashboard, check health)' ([bool](Invoke-PageScript $cdp "!!document.querySelector('.xp-mini .xp-diagram.compact')") -and $ovText -match 'View infrastructure' -and $ovText -match 'Add application' -and $ovText -match 'Publish service' -and $ovText -match 'Open Traefik dashboard' -and $ovText -match 'Check health') ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'overview-mini-diagram-1366.png') }
      $null = Invoke-PageScript $cdp "document.querySelector('.xp-mini .xp-node[data-id=network]').click(); true"
      $ok = Wait-PageCondition $cdp "location.hash === '#explorer/network' && document.querySelector('#xp-detail-title')" 15
      Test-Condition 'overview: selecting a component in the small diagram opens it in the Explorer' $ok ''
      # The backend stops: the path is blocked at the application.
      $null = Invoke-Docker stop "$stack-whoami"
      $null = & $go 'explorer' "document.querySelectorAll('.xp-node').length >= 12"
      $null = Wait-PageCondition $cdp "document.querySelector('.xp-node[data-id=app].err')" 15
      $blockedText = [string](Invoke-PageScript $cdp "document.querySelector('.callout.err') ? document.querySelector('.callout.err').innerText : ''")
      Test-Condition 'failure: a stopped backend marks the application as a problem and explains where requests stop' ([bool](Invoke-PageScript $cdp "!!document.querySelector('.xp-node[data-id=app].err')") -and $blockedText -match 'needs attention') $blockedText
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'explorer-backend-stopped-1366.png') }
      Test-Condition 'no JavaScript errors' ($cdp.Errors.Count -eq 0) ($cdp.Errors -join ' | ')
    }
  } catch {
    Add-Result 'FAIL' 'explorer test run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
  } finally {
    if ($cdp) { Stop-EdgeSession $cdp }
    Stop-TestServer $ui; Stop-TestServer $mock
    if ($installed) {
      $null = Invoke-Ps (Join-Path $installPath 'install.ps1') @('-InstallPath', $installPath, '-Stop')
      $null = Invoke-Docker rm -f "$stack-whoami"
      $null = Invoke-Docker network rm $network
      $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
      $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
      Test-Condition 'teardown: no instance containers or networks left' ($left.Count -eq 0 -and $leftNets.Count -eq 0) (($left + $leftNets) -join ', ')
    }
    $after = Get-EngineSnapshot $stack
    $changed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) -or $after[$_] -ne $before[$_] })
    $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
    Test-Condition "other containers untouched ($($before.Count) checked: same IDs, start times, states)" ($changed.Count -eq 0 -and $added.Count -eq 0) ("changed: $($changed -join ', ') added: $($added -join ', ')")
    Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- Part 4: read-only checks of a real installation --------------------------------------------------------------------------
if ($LiveReadOnly) {
  if (-not (Test-Path -LiteralPath (Join-Path $LivePath '.env'))) { Add-Result 'SKIP' 'live read-only checks' "No installation at $LivePath" }
  else {
    Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
    Import-Module (Join-Path $repo 'lib\Dashboard.psm1') -Force
    Import-Module (Join-Path $repo 'lib\DockerDiscovery.psm1') -Force
    Import-Module (Join-Path $repo 'lib\ServiceHealth.psm1') -Force
    $snap = { Get-ChildItem -LiteralPath $LivePath -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } }
    $filesBefore = (& $snap) -join "`n"
    $engineBefore = Get-EngineSnapshot '~none~'
    try {
      $s = Get-StackSettings -InstallPath $LivePath
      $docker = Get-DockerStatus; $stack = Get-StackStatus -Settings $s
      $cfg = Read-CloudflareConfig -Settings $s; $tok = Get-CloudflareApiTokenInfo -Settings $s
      $registry = @((Read-ServiceRegistry -Settings $s).services)
      $tunnel = $null
      if ($tok.Stored -and $tok.Readable -and $cfg.accountId -and $cfg.tunnelId) {
        $t = Invoke-CloudflareApi -Settings $s -Path "/accounts/$($cfg.accountId)/cfd_tunnel/$($cfg.tunnelId)"
        $tunnel = [ordered]@{ name = [string]$t.name; status = [string]$t.status; connections = @($(if ($t.PSObject.Properties['connections']) { $t.connections } else { @() })).Count; error = '' }
      }
      $dash = Read-DashboardConfig -Settings $s
      $base = [ordered]@{ mode = $(if ($stack.TunnelTokenPresent) { 'tunnel' } else { 'local' }); installed = $true; stackName = $s.StackName; httpPort = $s.HttpPort; dashboardPort = $s.DashboardPort; proxyNetwork = $s.ProxyNetwork
        cloudflaredIp = $s.CloudflaredIp; docker = $docker; stack = $stack; services = $registry; cloudflare = $cfg; token = $tok; tunnel = $tunnel; tunnelTokenPresent = $stack.TunnelTokenPresent
        dashboard = [ordered]@{ enabled = [bool]$dash.enabled; hostname = [string]$dash.hostname; router = (Get-DashboardRouterName) } }
      $lm = ConvertTo-InfrastructureModel -Facts (Get-InfrastructureFacts -Settings $s -Base $base)
      Write-Host "  live: $($s.StackName), network $($s.ProxyNetwork), tunnel $($cfg.tunnelName), dashboard $($dash.hostname), services $(($registry | ForEach-Object { $_.name }) -join ',')" -ForegroundColor Cyan
      Test-Condition 'live: tunnel mode; the tunnel is verified with Cloudflare (connected connector)' ($lm.mode -eq 'tunnel' -and (Get-Dim $lm 'tunnel' 'verified') -eq $true -and (Get-Dim $lm 'cloudflared' 'reachable') -eq $true) (((Get-Component $lm 'tunnel').evidence | ForEach-Object { $_.text }) -join ' | ')
      Test-Condition 'live: Traefik running with a reachable API; its routers loaded; the shared network exists with Traefik attached' ((Get-Dim $lm 'traefik' 'verified') -eq $true -and (Get-Dim $lm 'router' 'running') -eq $true -and (Get-Dim $lm 'network' 'reachable') -eq $true) (((Get-Component $lm 'router').evidence | ForEach-Object { $_.text }) -join ' | ')
      Test-Condition 'live: every saved service has a flow with its loaded router' (@($lm.flows).Count -eq $registry.Count -and -not @($lm.flows | Where-Object { $_.enabled -and (-not $_.router -or $_.router.status -ne 'enabled') }).Count) (($lm.flows | ForEach-Object { "$($_.name):$(if ($_.router) { $_.router.status } else { 'none' })" }) -join ', ')
      Test-Condition 'live: no competing hostname definitions' (@($lm.conflicts).Count -eq 0) ($lm.conflicts | ConvertTo-Json -Compress -Depth 4)
      Test-Condition 'live: configuration alone verified nothing (Access and applications await a per-service check)' ($null -eq (Get-Dim $lm 'app' 'verified') -and $null -eq (Get-Dim $lm 'access' 'verified')) ''
      $inv = @(Get-DockerContainerInventory -ProxyNetwork $s.ProxyNetwork)
      $mine = @($inv | Where-Object { $_.name -like "$($s.StackName)-*" })
      Test-Condition 'live: discovery lists the deployment''s containers as infrastructure (never offered for publishing)' ($mine.Count -ge 3 -and -not @($mine | Where-Object { -not $_.infrastructure }).Count) (($mine | ForEach-Object { "$($_.name):$($_.infrastructure)" }) -join ', ')
      $invJson = $inv | ConvertTo-Json -Depth 8 -Compress
      Test-Condition 'live: the inventory contains no environment variables' ($invJson -notmatch '"Env"' -and $invJson -notmatch 'TUNNEL_TOKEN=') ''
      foreach ($svc in $registry) {
        $claims = @(Find-HostnameClaims -Hostname @($svc.hostnames)[0] -Services $registry -Routers (Get-TraefikApi $s '/api/http/routers') -Containers $inv -OwnService $svc.name -DashboardHostname $(if ($dash.enabled) { $dash.hostname } else { '' }))
        Test-Condition "live: $($svc.name) is the only owner of $(@($svc.hostnames)[0])" ($claims.Count -eq 0) ($claims | ConvertTo-Json -Compress)
        $hh = Get-ServiceHealth -Settings $s -Service $svc
        $line = ($hh.checks | ForEach-Object { "$($_.id)=$($_.state)$(if (-not $_.performed) { '(not performed)' })" }) -join ' '
        Write-Host "  live health $($svc.name): $line" -ForegroundColor Cyan
        Test-Condition "live: $($svc.name) request path - DNS, Access, tunnel route, router and service verified with read-only requests" (@($hh.checks | Where-Object { $_.id -in 'dns', 'tunnel', 'router', 'service' -and $_.state -ne 'ok' }).Count -eq 0 -and ($svc.cloudflare.access -eq $false -or (Get-Check2 $hh 'access').state -eq 'ok')) $line
        Test-Condition "live: $($svc.name) application check reports what it saw (performed, with an HTTP result)" ((Get-Check2 $hh 'http').performed -and (Get-Check2 $hh 'http').message -match 'HTTP|answer') (Get-Check2 $hh 'http').message
      }
    } catch { Add-Result 'FAIL' 'live read-only checks' ($_.Exception.Message + ' ' + $_.ScriptStackTrace) }
    $filesAfter = (& $snap) -join "`n"
    $engineAfter = Get-EngineSnapshot '~none~'
    $changed = @($engineBefore.Keys | Where-Object { -not $engineAfter.ContainsKey($_) -or $engineAfter[$_] -ne $engineBefore[$_] })
    Test-Condition 'live: the installation''s files are unchanged (names, sizes, write times)' ($filesBefore -eq $filesAfter) ''
    Test-Condition "live: every container is unchanged ($($engineBefore.Count) checked)" ($changed.Count -eq 0 -and $engineAfter.Count -eq $engineBefore.Count) ($changed -join ', ')
  }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
