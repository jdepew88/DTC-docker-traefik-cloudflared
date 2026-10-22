#requires -version 5.1
<#
.SYNOPSIS
  App Catalog tests: the shipped manifests, template resolution, Compose generation and secret handling (unit), then a
  disposable instance with a fixture catalog of images already on this PC: install, health, logs (secrets redacted),
  start / stop / restart, volume persistence across removal and reinstallation, manager restart, update, publishing,
  removal with and without data, and the browser workflow.

.DESCRIPTION
  The shipped catalog's real images are validated with `docker compose config` but never pulled. Everything the test
  creates (instance, app projects, volumes, folders) carries a unique prefix and is removed at the end; every other
  container must keep its ID, start time and state.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Catalog.ps1 -ScreenshotDir $env:TEMP\tpm-catalog-shots
#>
[CmdletBinding()]
param([string]$ScreenshotDir, [switch]$SkipBrowser, [switch]$SkipInstance, [string]$TunnelSubnet = '172.31.245.0/28')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\AppCatalog.psm1') -Force
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

# --- Part 1: unit tests ---------------------------------------------------------------------------------------------------
$catalogDir = Join-Path $repo 'catalog'
$apps = @(Get-CatalogApps -CatalogDir $catalogDir)
$ids = @($apps | ForEach-Object { $_.id })
Test-Condition 'catalog: the curated apps are present' (@(@('echo', 'uptime-kuma', 'jellyfin', 'portainer', 'arcane', 'authelia', 'authentik') | Where-Object { $ids -notcontains $_ }).Count -eq 0) ($ids -join ', ')
$bad = @($apps | Where-Object { @($_.errors).Count } | ForEach-Object { "$($_.id): $($_.errors -join '; ')" })
Test-Condition 'catalog: every shipped manifest is valid (pinned digests, licence, https docs, one primary port)' ($bad.Count -eq 0) ($bad -join ' | ')
$inst = @($apps | Where-Object { $_.manifest.installable })
Test-Condition 'catalog: installable apps use digest-pinned images only; authentication providers wait for their own setup' ($inst.Count -eq 5 -and -not @($apps | Where-Object { $_.id -in 'authelia', 'authentik' -and $_.manifest.installable }).Count) ''
$sock = @($inst | Where-Object { @($_.manifest.services.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties['dockerSocket'] -and $_.Value.dockerSocket }).Count } | ForEach-Object { $_.id })
Test-Condition 'catalog: only Portainer and Arcane mount the Docker socket, and both declare it as a privilege and refuse public exposure' ((($sock | Sort-Object) -join ',') -eq 'arcane,portainer' -and -not @($inst | Where-Object { $_.id -in $sock -and $_.manifest.exposure.allowPublic -ne $false }).Count) ($sock -join ',')
Test-Condition 'catalog: Jellyfin defaults to local only and warns about streaming through Cloudflare' ((Get-CatalogApp $catalogDir 'jellyfin').exposure.default -eq 'local' -and (Get-CatalogApp $catalogDir 'jellyfin').exposure.warning -match 'Cloudflare') ''

$base = '{"schema":1,"id":"x","name":"X","description":"d","license":"MIT","maintainer":"m","category":"tools","docs":[{"title":"t","url":"https://e.example"}],"platforms":{"windows-docker-desktop":"supported"},"installable":true,"inputs":[],"services":{"app":{"image":"nginx:1.27@sha256:' + ('a' * 64) + '","ports":[{"container":80,"protocol":"http","primary":true}],"volumes":[],"environment":{}}},"privileges":[],"web":{"service":"app"},"exposure":{"default":"access"}}'
function New-Manifest([scriptblock]$Change) { $m = $base | ConvertFrom-Json; & $Change $m; return $m }
Test-Condition 'manifest: a valid minimal manifest passes' (@(Test-AppManifest ($base | ConvertFrom-Json)).Count -eq 0) ((Test-AppManifest ($base | ConvertFrom-Json)) -join '; ')
$e1 = Test-AppManifest (New-Manifest { param($m) $m.services.app.image = 'nginx:latest' })
$e2 = Test-AppManifest (New-Manifest { param($m) $m.services.app.ports[0].primary = $false })
$e3 = Test-AppManifest (New-Manifest { param($m) $m.services.app.environment = [pscustomobject]@{ A = '{{input:nope}}'; B = '{{shell}}' } })
$e4 = Test-AppManifest (New-Manifest { param($m) $m.services.app | Add-Member dockerSocket $true })
$e5 = Test-AppManifest (New-Manifest { param($m) $m.services.app.volumes = @([pscustomobject]@{ name = 'data'; target = 'relative/path' }) })
Test-Condition 'manifest: unpinned images, no primary port, unknown template variables, undeclared socket and bad volume targets are rejected' (($e1 -join ' ') -match 'pinned' -and ($e2 -join ' ') -match 'primary' -and ($e3 -join ' ') -match 'input:nope' -and ($e3 -join ' ') -match 'shell' -and ($e4 -join ' ') -match 'docker-socket' -and ($e5 -join ' ') -match 'absolute') (($e1 + $e2 + $e3 + $e4 + $e5) -join ' | ')

$t = Resolve-TemplateValue 'http://{{project}}:{{webPort}}/{{input:x}}' @{ project = 'p'; webPort = 3552; 'input:x' = 'y' }
$threw = $false; try { $null = Resolve-TemplateValue '{{input:missing}}' @{} } catch { $threw = $true }
Test-Condition 'templates: variables resolve; a missing value throws (nothing is left unresolved)' ($t -eq 'http://p:3552/y' -and $threw) $t
$arc = Get-CatalogApp $catalogDir 'arcane'
$r1 = Resolve-AppValues -Manifest $arc -Project 'arc-t' -AppUrl 'https://arc.example.com' -TimeZone 'Europe/Berlin'
$r2 = Resolve-AppValues -Manifest $arc -Project 'arc-t' -AppUrl 'https://arc.example.com' -Existing $r1.Values
$k1 = $r1.Env['app']['ENCRYPTION_KEY']; $j1 = $r1.Env['app']['JWT_SECRET']
Test-Condition 'secrets: generated server-side (32 random bytes as hex), distinct, kept on re-resolution; secret keys identified' ($k1 -match '^[0-9a-f]{64}$' -and $j1 -match '^[0-9a-f]{64}$' -and $k1 -ne $j1 -and $r2.Env['app']['ENCRYPTION_KEY'] -eq $k1 -and ((@($r1.Secrets) | Sort-Object) -join ',') -eq 'ENCRYPTION_KEY,JWT_SECRET' -and $r1.Env['app']['APP_URL'] -eq 'https://arc.example.com') ''
$compose = ConvertTo-AppCompose -Manifest $arc -Project 'arc-t' -Resolved $r1 -ProxyNetwork 'proxynet'
Test-Condition 'compose: secrets are referenced as ${VAR}, never written into compose.yaml' ($compose -match 'ENCRYPTION_KEY: \$\{ENCRYPTION_KEY\}' -and $compose -notmatch $k1 -and $compose -notmatch $j1) ''
Test-Condition 'compose: pinned image, external shared network, named volume, labels, no published port by default' ($compose -match [regex]::Escape($arc.services.app.image) -and $compose -match "name: proxynet\s+external: true" -and $compose -match 'name: arc-t_data' -and $compose -match 'org.traefik-proxy.app: arcane' -and $compose -notmatch 'ports:' -and $compose -match 'no-new-privileges' -and $compose -match '/var/run/docker.sock' -and $compose -match "test: \['CMD', './arcane', 'health'") ''
$composeLocal = ConvertTo-AppCompose -Manifest $arc -Project 'arc-t' -Resolved $r1 -ProxyNetwork 'proxynet' -LocalPort 18552
Test-Condition 'compose: the optional local port binds to 127.0.0.1 only' ($composeLocal -match "- '127\.0\.0\.1:18552:3552'") ''
$mediaDir = Join-Path ([IO.Path]::GetTempPath()) ("tpm-media-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $mediaDir | Out-Null
try {
  $jf = Get-CatalogApp $catalogDir 'jellyfin'
  $rj = Resolve-AppValues -Manifest $jf -Inputs @{ mediaFolder = $mediaDir } -Project 'jf-t'
  $cj = ConvertTo-AppCompose -Manifest $jf -Project 'jf-t' -Resolved $rj -ProxyNetwork 'proxynet'
  Test-Condition 'compose: a chosen folder becomes a read-only bind mount with a quoted Windows path' (@($rj.Errors).Count -eq 0 -and $cj -match "source: '$([regex]::Escape($mediaDir))'" -and $cj -match 'target: /media\s+read_only: true' -and $cj -match 'name: jf-t_config') ''
  $rjm = Resolve-AppValues -Manifest $jf -Project 'jf-t'
  Test-Condition 'inputs: a required folder must be given' ((@($rjm.Errors) -join ' ') -match 'Media folder is required') ''
  $fails = @()
  foreach ($p in @('\\server\share', 'C:\', 'relative\path', "C:\it's", (Join-Path $mediaDir 'missing'))) { try { $null = ConvertTo-HostFolder $p; $fails += $p } catch { } }
  Test-Condition 'folders: network paths, drive roots, relative paths, quotes and missing folders are refused' ($fails.Count -eq 0) ($fails -join ', ')
  # docker compose config on the real catalog output (no images are pulled).
  if ((Get-DockerStatus).CliFound) {
    $cfgBad = @()
    foreach ($pair in @(@($arc, $r1, 'arc-t'), @($jf, $rj, 'jf-t'))) {
      $dir = Join-Path $mediaDir "cfg-$($pair[2])"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
      [IO.File]::WriteAllText((Join-Path $dir 'compose.yaml'), (ConvertTo-AppCompose -Manifest $pair[0] -Project $pair[2] -Resolved $pair[1] -ProxyNetwork 'proxynet'))
      $envAll = [ordered]@{}; foreach ($svc in $pair[1].Env.Keys) { foreach ($k in $pair[1].Env[$svc].Keys) { $envAll[$k] = $pair[1].Env[$svc][$k] } }
      [IO.File]::WriteAllText((Join-Path $dir '.env'), (ConvertTo-EnvFileText $envAll))
      $v = Invoke-Docker compose --project-directory $dir -f (Join-Path $dir 'compose.yaml') config -q
      if ($v.ExitCode -ne 0) { $cfgBad += "$($pair[2]): $($v.Output -join ' ')" }
    }
    Test-Condition 'compose: generated projects pass docker compose config (Arcane, Jellyfin)' ($cfgBad.Count -eq 0) ($cfgBad -join ' | ')
  }
} finally { Remove-Item -LiteralPath $mediaDir -Recurse -Force -ErrorAction SilentlyContinue }
$envText = ConvertTo-EnvFileText ([ordered]@{ A = 'plain-1.2'; B = 'has space'; C = 'x$y' })
$q = $false; try { $null = ConvertTo-EnvFileText ([ordered]@{ D = "it's" }) } catch { $q = $true }
Test-Condition '.env: plain values unquoted, others single-quoted; values with a quote are refused' ($envText -match "(?m)^A=plain-1\.2$" -and $envText -match "(?m)^B='has space'$" -and $envText -match "(?m)^C='x\`$y'$" -and $q) $envText
$hid = Hide-SecretValues @("token=$k1 ok", 'nothing here') @($k1, 'abc')
Test-Condition 'logs: secret values are replaced by [redacted] (short values are left alone)' ($hid[0] -eq 'token=[redacted] ok' -and $hid[1] -eq 'nothing here') ($hid -join ' / ')
$diff = @(Get-AppUpdateDiff $arc ($compose.Replace($arc.services.app.image, 'getarcaneapp/manager:v2.15.0@sha256:' + ('b' * 64))))
Test-Condition 'updates: the diff names the service with installed and catalog image' ($diff.Count -eq 1 -and $diff[0].service -eq 'app' -and $diff[0].to -eq $arc.services.app.image -and $diff[0].from -match 'v2\.15\.0') ''
Test-Condition 'updates: an unchanged project has no diff' (@(Get-AppUpdateDiff $arc $compose).Count -eq 0) ''
Test-Condition 'platform: Windows / Docker Desktop support is read from the manifest' ((Get-PlatformSupport $arc).installable -and -not (Get-PlatformSupport (Get-CatalogApp $catalogDir 'authelia') ).installable) ''

# --- Part 2: disposable instance with a fixture catalog ---------------------------------------------------------------------
if ($SkipInstance) { Add-Result 'SKIP' 'disposable instance' '-SkipInstance' }
elseif (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'disposable instance' 'Docker engine not running' }
else {
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
  $stack = "tpx-ct-$id"; $network = "$stack-proxy"
  $work = Join-Path ([IO.Path]::GetTempPath()) $stack
  $installPath = Join-Path $work 'instance'
  $appsRoot = Join-Path $work 'apps'
  New-Item -ItemType Directory -Force -Path (Join-Path $work 'catalog\apps'), $appsRoot | Out-Null
  if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
  $o = $TunnelSubnet.Split('/')[0].Split('.')
  $envFile = Join-Path $work 'instance.env'
  @("STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$(Get-FreeTcpPort)", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$network", "TUNNEL_SUBNET=$TunnelSubnet",
    "TUNNEL_IP_RANGE=$($o[0]).$($o[1]).$($o[2]).$($o[3])/29", "CLOUDFLARED_IP=$($o[0]).$($o[1]).$($o[2]).$([int]$o[3] + 10)", 'TRAEFIK_LOG_LEVEL=INFO') | Set-Content -LiteralPath $envFile -Encoding ASCII
  # Fixture catalog: the shipped echo app (image already on this PC) and a "notes" app with a data volume and a secret.
  $fixtureDir = Join-Path $work 'catalog'
  Copy-Item -LiteralPath (Join-Path $catalogDir 'apps\echo.json') -Destination (Join-Path $fixtureDir 'apps\echo.json')
  $traefikRef = ([regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'compose.yaml')), 'image: (traefik:v[0-9.]+@sha256:[0-9a-f]{64})')).Groups[1].Value
  $notes = [ordered]@{ schema = 1; id = 'notes'; name = 'Notes (test)'; description = 'Test app: serves an id stored in its data volume.'; license = 'MIT'; maintainer = 'tests'; category = 'tools'
    docs = @([ordered]@{ title = 'tests'; url = 'https://example.invalid/' }); platforms = [ordered]@{ 'windows-docker-desktop' = 'supported' }; installable = $true
    inputs = @([ordered]@{ id = 'token'; type = 'generated'; bytes = 24; label = 'Token' })
    services = [ordered]@{ app = [ordered]@{ image = $traefikRef; ports = @([ordered]@{ container = 8080; protocol = 'http'; primary = $true })
        volumes = @([ordered]@{ name = 'data'; target = '/data'; kind = 'volume'; description = 'ids' }); environment = [ordered]@{ NOTE_TOKEN = '{{input:token}}' }
        command = @('sh', '-c', 'echo starting with token $$NOTE_TOKEN; mkdir -p /data; [ -f /data/id ] || cat /proc/sys/kernel/random/uuid > /data/id; while true; do { printf ''HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n''; cat /data/id; } | nc -l -p 8080; done') } }
    privileges = @(); security = @(); update = [ordered]@{ strategy = 'pinned-digest'; notes = 'test' }; web = [ordered]@{ service = 'app' }; exposure = [ordered]@{ default = 'local' } }
  [IO.File]::WriteAllText((Join-Path $fixtureDir 'apps\notes.json'), ($notes | ConvertTo-Json -Depth 8))
  [IO.File]::WriteAllText((Join-Path $fixtureDir 'apps\broken.json'), '{"schema":1,"id":"broken","name":"Broken"}')
  $before = Get-EngineSnapshot $stack
  $installed = $false; $ui = $null; $mock = $null; $cdp = $null
  $apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N')
  $p1 = "$stack-notes"; $p2 = "$stack-echo"
  $startUi = { Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $installPath -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work "ui-$([Guid]::NewGuid().ToString('N').Substring(0, 4))")).FullName -ApiBase $mock.Base -ExtraArgs @('-CatalogDir', "`"$fixtureDir`"") }
  try {
    $install = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-Start')
    $installed = Test-Path -LiteralPath $installPath
    Test-Condition 'instance: install -Start (local only, disposable)' ($install.ExitCode -eq 0) ($install.Text -split "`n" | Select-Object -Last 12 | Out-String)
    if ($install.ExitCode -ne 0) { throw 'Install failed.' }
    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
    $ui = & $startUi
    $null = Connect-WebUi $ui
    $c = Invoke-WebUi $ui GET '/api/catalog'
    Test-Condition 'api: the catalog lists valid apps and reports invalid manifests separately' ($c.Status -eq 200 -and @($c.Data.apps | ForEach-Object { $_.id }) -contains 'notes' -and @($c.Data.invalid).Count -eq 1 -and $c.Data.invalid[0].file -eq 'broken.json') $c.Body.Substring(0, [Math]::Min(300, $c.Body.Length))
    $folder1 = Join-Path $appsRoot 'notes'
    $plan = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'notes'; project = $p1; folder = $folder1 }
    Test-Condition 'plan: compose.yaml, masked .env, checks; nothing written yet' ($plan.Status -eq 200 -and $plan.Data.canApply -and $plan.Data.compose -match "name: $p1" -and $plan.Data.envPreview -match 'NOTE_TOKEN=<generated secret' -and -not (Test-Path -LiteralPath $folder1)) ($plan.Body.Substring(0, [Math]::Min(600, $plan.Body.Length)))
    Test-Condition 'plan: docker compose config ran and passed' (@($plan.Data.checks | Where-Object { $_.label -eq 'docker compose config' -and $_.state -eq 'ok' }).Count -eq 1) ''
    $pUnc = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'notes'; project = "$stack-x"; folder = '\\server\share\x' }
    $pTaken = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'notes'; project = $stack; folder = (Join-Path $appsRoot 'y') }
    $pInside = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'notes'; project = "$stack-z"; folder = (Join-Path $installPath 'apps\z') }
    $pAuth = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'authelia' }
    Test-Condition 'plan: network paths refused; an existing project name and folders inside the deployment block the plan; unknown apps 404' ($pUnc.Status -eq 400 -and -not $pTaken.Data.canApply -and -not $pInside.Data.canApply -and $pAuth.Status -eq 404) "$($pUnc.Status) $($pTaken.Data.canApply) $($pInside.Data.canApply) $($pAuth.Status)"
    $noConfirm = Invoke-WebUi $ui POST '/api/catalog/apply' @{ planId = $plan.Data.planId }
    $apply = Invoke-WebUi $ui POST '/api/catalog/apply' @{ planId = $plan.Data.planId; confirm = $true }
    Test-Condition 'apply: needs confirmation, then deploys an ordinary Compose project' ($noConfirm.Status -eq 400 -and $apply.Status -eq 200 -and $apply.Data.ok -and (Test-Path -LiteralPath (Join-Path $folder1 'compose.yaml')) -and (Test-Path -LiteralPath (Join-Path $folder1 'README.md'))) ($apply.Body)
    $again = Invoke-WebUi $ui POST '/api/catalog/apply' @{ planId = $plan.Data.planId; confirm = $true }
    Test-Condition 'apply: a preview can be applied once' ($again.Status -eq 409) "$($again.Status)"
    Test-Condition 'health: the container runs and its web port answers HTTP (probe on the shared network)' ($apply.Data.health.running -and $apply.Data.health.http.result -eq 'http' -and $apply.Data.health.http.network -eq $network) ($apply.Data.health | ConvertTo-Json -Depth 6 -Compress)
    $envPath = Join-Path $folder1 '.env'
    $token = (Read-AppEnv $envPath)['NOTE_TOKEN']
    $acl = (Get-Acl -LiteralPath $envPath).Access | ForEach-Object { $_.IdentityReference.Value }
    Test-Condition '.env: holds the generated secret, readable by the current user, SYSTEM and Administrators only' ($token -match '^[0-9a-f]{48}$' -and -not @($acl | Where-Object { $_ -match 'Users$|Everyone|Authenticated' }).Count -and [IO.File]::ReadAllText((Join-Path $folder1 'compose.yaml')) -notmatch $token) ($acl -join ', ')
    Test-Condition 'api: the secret never reaches the browser (plan, apply)' ($plan.Body -notmatch $token -and $apply.Body -notmatch $token) ''
    $list = Invoke-WebUi $ui GET '/api/apps'
    $a1 = @($list.Data.apps | Where-Object { $_.project -eq $p1 })[0]
    Test-Condition 'apps: the installed app is listed, running 1/1, with its folder' ($a1 -and $a1.running -eq 1 -and $a1.total -eq 1 -and $a1.folder -eq $folder1 -and -not $a1.updateAvailable) ($list.Body)
    Start-Sleep -Seconds 2
    $logs = Invoke-WebUi $ui GET "/api/apps/logs?project=$p1&tail=50"
    Test-Condition 'logs: shown with the secret redacted' ($logs.Status -eq 200 -and (@($logs.Data.lines) -join "`n") -match 'starting with token \[redacted\]' -and $logs.Body -notmatch $token) ((@($logs.Data.lines) -join ' / '))
    $id0 = ((Invoke-Docker exec $p1 cat /data/id).Output -join '').Trim()
    $started0 = ((Invoke-Docker inspect $p1 --format '{{.State.StartedAt}}').Output -join '').Trim()
    $st = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $p1; action = 'stop'; confirm = $true }
    $state1 = ((Invoke-Docker inspect $p1 --format '{{.State.Status}}').Output -join '').Trim()
    $sa = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $p1; action = 'start'; confirm = $true }
    $rs = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $p1; action = 'restart'; confirm = $true }
    $id1 = ((Invoke-Docker exec $p1 cat /data/id).Output -join '').Trim()
    Test-Condition 'lifecycle: stop, start and restart; data in the volume survives' ($st.Data.ok -and $state1 -eq 'exited' -and $sa.Data.ok -and $rs.Data.ok -and $id0 -and $id1 -eq $id0) "$state1 $id0 $id1"
    $nc = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $p1; action = 'stop' }
    $ext = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $stack; action = 'stop'; confirm = $true }
    $badA = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $p1; action = 'rm'; confirm = $true }
    Test-Condition 'lifecycle: needs confirmation; projects not installed by the manager (e.g. the proxy stack) are refused' ($nc.Status -eq 400 -and $ext.Status -eq 404 -and $badA.Status -eq 400) "$($nc.Status) $($ext.Status) $($badA.Status)"

    # The manager stops and starts again: the app keeps running untouched.
    $started1 = ((Invoke-Docker inspect $p1 --format '{{.State.StartedAt}}').Output -join '').Trim()
    Stop-TestServer $ui; $ui = $null
    Start-Sleep -Seconds 2
    $startedAfterStop = ((Invoke-Docker inspect $p1 --format '{{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim()
    $ui = & $startUi; $null = Connect-WebUi $ui
    $list2 = Invoke-WebUi $ui GET '/api/apps'
    Test-Condition 'manager restart: the app keeps running (same start time) and is listed again' ($startedAfterStop -eq "$started1 running" -and @($list2.Data.apps | Where-Object { $_.project -eq $p1 -and $_.running -eq 1 }).Count -eq 1) $startedAfterStop

    # Update: the catalog now references the same image by digest only (a new reference for the same content).
    $digestOnly = 'traefik@' + ($traefikRef -split '@')[1]
    $notes.services.app.image = $digestOnly
    [IO.File]::WriteAllText((Join-Path $fixtureDir 'apps\notes.json'), ($notes | ConvertTo-Json -Depth 8))
    $pv = Invoke-WebUi $ui POST '/api/apps/update/preview' @{ project = $p1 }
    Test-Condition 'update: the preview names the image change and what is kept' ($pv.Status -eq 200 -and @($pv.Data.changes).Count -eq 1 -and $pv.Data.changes[0].to -eq $digestOnly -and $pv.Data.previewKey) ($pv.Body)
    $stale = Invoke-WebUi $ui POST '/api/apps/update/apply' @{ project = $p1; previewKey = 'x'; confirm = $true }
    $up = Invoke-WebUi $ui POST '/api/apps/update/apply' @{ project = $p1; previewKey = $pv.Data.previewKey; confirm = $true }
    $id2 = ((Invoke-Docker exec $p1 cat /data/id).Output -join '').Trim()
    $img = ((Invoke-Docker inspect $p1 --format '{{.Config.Image}}').Output -join '').Trim()
    Test-Condition 'update: a stale preview is refused; applying backs up compose.yaml, recreates the container and keeps the data' ($stale.Status -eq 409 -and $up.Data.ok -and (Test-Path -LiteralPath (Join-Path $folder1 $up.Data.backup)) -and $img -eq $digestOnly -and $id2 -eq $id0) "$($stale.Status) $img $id2"

    # Publish it through Traefik, then removal is blocked until the route is gone.
    $pub = Invoke-WebUiChange $ui @{ op = 'add'; name = 'notes'; service = @{ name = 'notes'; hostnames = @('notes.example.test'); target = @{ type = 'docker'; host = $p1; port = 8080; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    Start-Sleep -Seconds 2
    $hh = Invoke-WebUi $ui POST '/api/services/health' @{ name = 'notes' }
    $http = @($hh.Data.checks | Where-Object { $_.id -eq 'http' })[0]
    Test-Condition 'publish: the installed app is already on the shared network; the route answers through Traefik' ($pub.Apply -and $pub.Apply.Data.ok -and $http.state -eq 'ok') ($hh.Body)
    $rmBlocked = Invoke-WebUi $ui POST '/api/apps/remove' @{ project = $p1; confirm = $true }
    Test-Condition 'remove: blocked while a service route points at the app' ($rmBlocked.Status -eq 409 -and $rmBlocked.Body -match 'notes') $rmBlocked.Body
    $null = Invoke-WebUiChange $ui @{ op = 'remove'; name = 'notes'; cloudflare = @{ automate = $false } }
    $rmWrong = Invoke-WebUi $ui POST '/api/apps/remove' @{ project = $p1; confirm = $true; deleteFolder = $true; confirmText = 'nope' }
    $rmKeep = Invoke-WebUi $ui POST '/api/apps/remove' @{ project = $p1; confirm = $true; deleteFolder = $true; confirmText = $p1 }
    $volLeft = (Invoke-Docker volume inspect "${p1}_data").ExitCode -eq 0
    Test-Condition 'remove: deleting files needs the typed project name; by default the data volume is kept' ($rmWrong.Status -eq 400 -and $rmKeep.Status -eq 200 -and $volLeft -and $rmKeep.Data.folderRemoved -and (Invoke-Docker inspect $p1).ExitCode -ne 0) ($rmKeep.Body)
    $re = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'notes'; project = $p1; folder = $folder1 }
    $reuse = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'notes'; project = $p1; folder = $folder1; reuseData = $true }
    Test-Condition 'reinstall: an existing data volume blocks the plan unless reusing it is chosen' (-not $re.Data.canApply -and @($re.Data.existingVolumes) -contains "${p1}_data" -and $reuse.Data.canApply) ''
    $ap2 = Invoke-WebUi $ui POST '/api/catalog/apply' @{ planId = $reuse.Data.planId; confirm = $true }
    $id3 = ((Invoke-Docker exec $p1 cat /data/id).Output -join '').Trim()
    Test-Condition 'reinstall: the kept data is found again' ($ap2.Data.ok -and $id3 -eq $id0) "$id3 vs $id0"
    $rmAll = Invoke-WebUi $ui POST '/api/apps/remove' @{ project = $p1; confirm = $true; deleteVolumes = $true; deleteFolder = $true; confirmText = $p1 }
    Test-Condition 'remove: with the typed project name, the data volume and the files are deleted' ($rmAll.Status -eq 200 -and $rmAll.Data.volumesDeleted -and (Invoke-Docker volume inspect "${p1}_data").ExitCode -ne 0 -and -not (Test-Path -LiteralPath $folder1)) ($rmAll.Body)

    # Echo with a local port.
    $folder2 = Join-Path $appsRoot 'echo'
    $lp = Get-FreeTcpPort
    $pe = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'echo'; project = $p2; folder = $folder2; localPort = $lp }
    $ae = Invoke-WebUi $ui POST '/api/catalog/apply' @{ planId = $pe.Data.planId; confirm = $true }
    $local = $null; try { $local = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "http://127.0.0.1:$lp/" } catch { }
    $bindIp = ((Invoke-Docker port $p2 80).Output -join ' ')
    Test-Condition 'local port: the app answers on 127.0.0.1 only' ($ae.Data.ok -and $local -and $local.StatusCode -eq 200 -and $bindIp -match '^127\.0\.0\.1:' -and $bindIp -notmatch '0\.0\.0\.0') $bindIp

    if ($SkipBrowser -or -not (Get-EdgePath)) { Add-Result 'SKIP' 'browser checks' $(if ($SkipBrowser) { '-SkipBrowser' } else { 'Edge not found' }) }
    else {
      $base = "http://127.0.0.1:$($ui.Port)"
      $cdp = Start-EdgeSession -WorkDir $work
      Set-Viewport $cdp 1366 900
      Open-Page $cdp $ui.LaunchUrl
      $null = Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && document.querySelector('main h1')" 30
      $go = { param($hash, $ready) Open-Page $cdp "$base/#$hash"; Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && ($ready)" 40 }
      $ok = & $go 'catalog' "document.querySelectorAll('.cat-card').length >= 2"
      $cards = @(Invoke-PageScript $cdp "[...document.querySelectorAll('.cat-card')].map((c) => c.getAttribute('aria-label'))")
      Test-Condition 'browser: the catalog shows the valid apps as cards with an Install action' ($ok -and $cards -contains 'Notes (test)' -and $cards -contains 'HTTP echo (whoami)' -and [bool](Invoke-PageScript $cdp "!!document.querySelector('a[aria-label=""Install Notes (test)""]')")) ($cards -join ', ')
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'catalog-1366.png') }
      $ok = & $go 'install/notes' "document.querySelector('#inst-project')"
      $null = Invoke-PageScript $cdp "(() => { const p = document.querySelector('#inst-project'); p.value = '$stack-ui'; p.dispatchEvent(new Event('input', { bubbles: true })); p.dispatchEvent(new Event('change', { bubbles: true })); })(); true"
      $null = Invoke-PageScript $cdp "(() => { const f = document.querySelector('#inst-folder'); f.value = $(ConvertTo-Json (Join-Path $appsRoot 'ui')); f.dispatchEvent(new Event('input', { bubbles: true })); f.dispatchEvent(new Event('change', { bubbles: true })); })(); true"
      $storage = [string](Invoke-PageScript $cdp "document.querySelector('#inst-3').closest('section').innerText")
      Test-Condition 'browser: storage and networking follow the project name' ($storage -match "$stack-ui_data") $storage
      $steps = [int](Invoke-PageScript $cdp "document.querySelectorAll('.wizard .wiz-step').length")
      Test-Condition 'browser: the installation wizard has the eleven steps' ($ok -and $steps -eq 11) "$steps"
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('.wizard button')].find((b) => b.textContent.includes('Preview the Compose project')).click(); true"
      $ok = Wait-PageCondition $cdp "(document.querySelector('.wizard .form-error') && document.querySelector('.wizard .form-error').textContent) || [...document.querySelectorAll('.wizard summary')].some((s) => s.textContent.includes('compose.yaml'))" 120
      $wt = [string](Invoke-PageScript $cdp "document.querySelector('form.wizard').innerText")
      if (-not $ok -or $wt -notmatch 'secrets masked') { Write-Host ('  wizard state: ' + [string](Invoke-PageScript $cdp "[...document.querySelectorAll('.wizard button')].map((b) => b.textContent + ':' + b.getAttribute('aria-busy')).join(', ') + ' | ' + (document.querySelector('.wizard .form-error') || {}).textContent")) }
      Test-Condition 'browser: preview shows compose.yaml, the masked .env and the validation' ($ok -and $wt -match 'compose.yaml' -and $wt -match 'secrets masked' -and $wt -match 'Installation folder is new or empty') ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'install-preview-1366.png') }
      $dis = [bool](Invoke-PageScript $cdp "[...document.querySelectorAll('.wizard button')].find((b) => b.textContent.includes('Deploy')).disabled")
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('#inst-9 ~ * input[type=checkbox], .wizard input[type=checkbox]')].find((b) => b.closest('label').textContent.includes('I reviewed')).click(); true"
      $en = -not [bool](Invoke-PageScript $cdp "[...document.querySelectorAll('.wizard button')].find((b) => b.textContent.includes('Deploy')).disabled")
      Test-Condition 'browser: Deploy stays disabled until the preview is reviewed' ($dis -and $en) "$dis $en"
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('.wizard button')].find((b) => b.textContent.includes('Deploy')).click(); true"
      $null = Wait-PageCondition $cdp "document.querySelector('#confirm-dialog').open" 10
      $null = Invoke-PageScript $cdp "document.querySelector('#confirm-ok').click(); true"
      $ok = Wait-PageCondition $cdp "document.querySelector('#inst-10') && document.querySelector('#inst-10').closest('section').innerText.includes('Web interface answers')" 120
      $ht = [string](Invoke-PageScript $cdp "document.querySelector('#inst-10').closest('section').innerText")
      $pubLink = [bool](Invoke-PageScript $cdp "!!document.querySelector('a[href=""#publish/$stack-ui""]')")
      Test-Condition 'browser: deploy, then health (container running, web interface answers) and the offer to publish' ($ok -and $ht -match 'Container running' -and $ht -match 'Answers HTTP 200' -and $pubLink) $ht
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'install-done-1366.png') }
      $ok = & $go 'apps' "document.querySelector('.disc-card')"
      $at = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
      Test-Condition 'browser: installed apps with status and actions' ($ok -and $at -match 'Notes \(test\)' -and $at -match 'running 1/1' -and $at -match 'Restart' -and $at -match 'Logs' -and $at -match 'Updates' -and $at -match 'Remove') ''
      $null = Invoke-PageScript $cdp "document.querySelector('button[aria-label=""Logs of Notes (test)""]').click(); true"
      $ok = Wait-PageCondition $cdp "document.querySelector('article[aria-label=""Notes (test)""] .app-out details')" 20
      $lt = [string](Invoke-PageScript $cdp "document.querySelector('article[aria-label=""Notes (test)""] .app-out').innerText")
      Test-Condition 'browser: logs open with secrets redacted' ($ok -and $lt -match '\[redacted\]') $lt
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'installed-apps-1366.png') }
      $bad = @()
      foreach ($pg in @(@('catalog', "document.querySelector('.cat-card')"), @('install/echo', "document.querySelector('#inst-project')"), @('apps', "document.querySelector('.disc-card')"))) {
        foreach ($w in @(390, 820)) {
          Set-Viewport $cdp $w 900 -Mobile:($w -lt 800)
          $null = & $go $pg[0] $pg[1]; Start-Sleep -Milliseconds 300
          $ov = [int](Invoke-PageScript $cdp "document.documentElement.scrollWidth - window.innerWidth")
          if ($ov -gt 1) { $bad += "$($pg[0]) at $w px overflows by $ov px" }
          if ($ScreenshotDir -and $w -eq 390) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$(($pg[0] -split '/')[0])-390.png") }
        }
        Set-Viewport $cdp 1366 900
        $null = & $go $pg[0] $pg[1]
        $unnamed = @(Invoke-PageScript $cdp "[...document.querySelectorAll('button, a[href], select, input')].filter((e) => e.checkVisibility() && !(e.getAttribute('aria-label') || e.textContent.trim() || (e.id && document.querySelector('label[for=' + JSON.stringify(e.id) + ']')) || e.closest('label'))).map((e) => e.outerHTML.slice(0, 80))")
        if ($unnamed.Count) { $bad += "$($pg[0]) unnamed: $($unnamed -join ' | ')" }
      }
      Test-Condition 'responsive and accessible: catalog, wizard and installed apps at 390 / 820 / 1366 px, all controls named' ($bad.Count -eq 0) ($bad -join '; ')
      Test-Condition 'no JavaScript errors' ($cdp.Errors.Count -eq 0) ($cdp.Errors -join ' | ')
    }
  } catch {
    Add-Result 'FAIL' 'catalog test run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
  } finally {
    if ($cdp) { Stop-EdgeSession $cdp }
    Stop-TestServer $ui; Stop-TestServer $mock
    foreach ($proj in @($p1, $p2, "$stack-ui")) {
      $f = $(if ($proj -eq $p1) { Join-Path $appsRoot 'notes' } elseif ($proj -eq $p2) { Join-Path $appsRoot 'echo' } else { Join-Path $appsRoot 'ui' })
      if (Test-Path -LiteralPath (Join-Path $f 'compose.yaml')) { $null = Invoke-Docker compose --project-directory $f -f (Join-Path $f 'compose.yaml') down -v }
      $null = Invoke-Docker rm -f $proj
      foreach ($v in @((Invoke-Docker volume ls -q --filter "name=${proj}_").Output | Where-Object { $_ })) { $null = Invoke-Docker volume rm $v }
    }
    if ($installed) {
      $null = Invoke-Ps (Join-Path $installPath 'install.ps1') @('-InstallPath', $installPath, '-Stop')
    }
    $null = Invoke-Docker network rm $network
    $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
    $leftVols = @((Invoke-Docker volume ls -q --filter "name=$stack").Output | Where-Object { $_ })
    $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
    Test-Condition 'teardown: no disposable containers, volumes or networks left' ($left.Count -eq 0 -and $leftVols.Count -eq 0 -and $leftNets.Count -eq 0) (($left + $leftVols + $leftNets) -join ', ')
    $after = Get-EngineSnapshot $stack
    $changed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) -or $after[$_] -ne $before[$_] })
    $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
    Test-Condition "other containers untouched ($($before.Count) checked: same IDs, start times, states)" ($changed.Count -eq 0 -and $added.Count -eq 0) ("changed: $($changed -join ', ') added: $($added -join ', ')")
    Get-ChildItem -LiteralPath $work -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
