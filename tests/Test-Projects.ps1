#requires -version 5.1
<#
.SYNOPSIS
  Tests of the one-click launcher and of discovering / attaching existing deployments.

.DESCRIPTION
  Everything runs on throwaway folders in %TEMP% and the Cloudflare API mock; no container is created, started or
  stopped and no real Cloudflare resource is read or changed (unless -LiveReadOnly is given, see below).
    - discovery in a limited set of places; kinds: installed, setup draft, earlier (legacy) layout, program copy,
      unrelated and missing folders; nothing changes before a deployment is chosen
    - inspection: settings, files, services, Docker, secrets (presence/readability only, never values), Cloudflare
      ids verified read-only, upgrade status; attach without changing files, Docker or Cloudflare
    - Cloudflare needing reconnection, multiple independent deployments, recent projects (persisted, moved/deleted
      folders, removal from the list), Windows path validation, the folder picker, new deployments refused over an
      existing one, upgrade preview (dry run) and a confirmed upgrade that keeps the configuration
    - launcher: required files, Docker missing, single-use sign-in link in a user-only file (never on a command
      line), duplicate start, port collision, status, stop, START-HERE.cmd
    - browser: chooser, review and open, overview of the attached deployment, layout at 390/820/1366 px, names
  -LiveReadOnly additionally inspects the real installation at %USERPROFILE%\.docker\projects\traefik-proxy
  (read-only, including read-only Cloudflare requests with its own stored token) and proves nothing changed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Projects.ps1 -ScreenshotDir .\screens
#>
[CmdletBinding()]
param([string]$ScreenshotDir, [switch]$LiveReadOnly, [switch]$SkipBrowser)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $repo 'lib\Dashboard.psm1') -Force
Import-Module (Join-Path $repo 'lib\ProjectDiscovery.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\EdgeCdp.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Short($r) { if ($null -eq $r) { return '(no response)' }; return "HTTP $($r.Status) $($r.Body.Substring(0, [Math]::Min(500, $r.Body.Length)))" }
function Get-FolderSnapshot([string]$Path) { return (@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" } | Sort-Object) -join "`n") }
function Get-DockerSnapshot { return ((@((Invoke-Docker ps -a --format '{{.ID}} {{.Names}} {{.State}}').Output | Where-Object { $_ -and $_ -notmatch '-validate-' } | Sort-Object) + @((Invoke-Docker network ls --format '{{.ID}} {{.Name}}').Output | Sort-Object)) -join '|') }
function Get-Writes { return @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' -and $_.path -notmatch '/_state$' }) }
function New-FakeTunnelToken([string]$TunnelId) {
  $json = ConvertTo-Json -Compress -InputObject ([ordered]@{ a = 'acc0000000000000000000000000001'; t = $TunnelId; s = 'dGVzdC1zZWNyZXQtbm90LXJlYWwtMDEyMzQ1Njc4OWFiY2RlZg==' })
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}
function Test-PortOpen([int]$Port) { $c = New-Object System.Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', $Port); return $true } catch { return $false } finally { $c.Close() } }
function Wait-File([string]$Path, [int]$Seconds = 40) { $d = (Get-Date).AddSeconds($Seconds); while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $d) { Start-Sleep -Milliseconds 250 }; return (Test-Path -LiteralPath $Path) }
function Invoke-Launcher([string[]]$Arguments, [int]$Seconds = 60) {
  $out = Join-Path $work ("launcher-" + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.out')
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError "$out.err" -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $repo 'Start-DeploymentManager.ps1')`"") + $Arguments)
  $null = $p.Handle   # Windows PowerShell 5.1 only keeps ExitCode when the handle was read early
  $null = $p.WaitForExit($Seconds * 1000)
  return [pscustomobject]@{ Process = $p; Exited = $p.HasExited; Code = $(if ($p.HasExited) { $p.ExitCode } else { $null }); Text = ((Get-Content -Raw $out -ErrorAction SilentlyContinue) + (Get-Content -Raw "$out.err" -ErrorAction SilentlyContinue)) }
}
function Start-LauncherServer([string]$StateDir, [int]$Port, [string[]]$More = @()) {
  $out = Join-Path $work ("server-" + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.out')
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError "$out.err" -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $repo 'Start-DeploymentManager.ps1')`"",
    '-NoBrowser', '-StateDir', "`"$StateDir`"", '-Port', $Port, '-ProjectsRoot', "`"$root`"", '-CloudflareApiBase', $mock.Base) + $More)
  $ok = Wait-File (Join-Path $StateDir 'launch.url')
  return [pscustomobject]@{ Process = $p; Ready = $ok; Out = $out }
}

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpx-projects-$id"
$root = Join-Path $work 'projects'
$pathA = Join-Path $root 'alpha'; $pathB = Join-Path $root 'beta'; $pathC = Join-Path $root 'draft'; $pathL = Join-Path $root 'old-layout'
$pathX = Join-Path $root 'unrelated'; $pathP = Join-Path $root 'program-copy'; $pathE = Join-Path $root 'empty'
$stackA = "tpx-pj-a-$id"; $stackB = "tpx-pj-b-$id"
$acct = 'acc0000000000000000000000000001'; $tunnel = '11111111-2222-3333-4444-555555555555'; $zone1 = 'zone00000000000000000000000000001'
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$tunnelToken = New-FakeTunnelToken $tunnel
New-Item -ItemType Directory -Force -Path $work, $root | Out-Null
$mock = $null; $ui = $null; $cdp = $null; $servers = New-Object System.Collections.ArrayList

try {
  $dockerBefore = Get-DockerSnapshot
  # --- Fixtures --------------------------------------------------------------------------------------------------------
  # A: an installed deployment whose application files are older than this manager (version 1.1.0), Cloudflare connected.
  # Test subnets stay in 172.31.238-241: Docker hands out whole /16s from 172.17 upwards to new networks (immich_internal
  # took 172.30.0.0/16 on a real PC), and install.ps1 rightly refuses a tunnel subnet that overlaps one.
  $null = New-TestInstance -Repo $repo -Path $pathA -StackName $stackA -Subnet '172.31.238.0/28'
  (Get-Content -Raw (Join-Path $pathA '.env')).Replace("PROXY_NETWORK=$stackA-proxy", 'PROXY_NETWORK=bridge') | Set-Content -NoNewline (Join-Path $pathA '.env')
  $manifest = [ordered]@{}
  foreach ($rel in (Get-ManagedFileList $repo)) {
    $src = Join-Path $repo $rel; $dst = Join-Path $pathA $rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
  $mod = Join-Path $pathA 'lib\TraefikProxy.psm1'
  [IO.File]::WriteAllText($mod, ([IO.File]::ReadAllText($mod) -replace "ManagerVersion = '[^']+'", "ManagerVersion = '1.1.0'"))
  foreach ($rel in (Get-ManagedFileList $repo)) { $dst = Join-Path $pathA $rel; if (Test-Path -LiteralPath $dst) { $manifest[$rel] = Get-FileSha256 $dst } }
  $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pathA '.install-manifest.json') -Encoding ASCII
  $sA = Get-StackSettings -InstallPath $pathA
  Save-CloudflareApiToken -Settings $sA -Token $apiToken
  New-Item -ItemType Directory -Force -Path (Join-Path $pathA 'secrets') | Out-Null
  [IO.File]::WriteAllText((Join-Path $pathA 'secrets\cloudflare_tunnel_token'), $tunnelToken)
  $cfA = [ordered]@{ version = 1; accountId = $acct; accountName = 'Test Account'; tunnelId = $tunnel; tunnelName = 'existing-tunnel'
    domains = @([ordered]@{ id = $zone1; name = 'example.test'; accountId = $acct })
    managed = [ordered]@{ 'keep.example.test' = [ordered]@{ service = 'mediabox'; dnsRecordId = 'rec-keep'; accessAppId = '' }; 'protected.example.test' = [ordered]@{ service = 'traefik-dashboard'; dnsRecordId = ''; accessAppId = 'app-existing' } } }
  ($cfA | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $pathA 'config\cloudflare.json') -Encoding UTF8
  '{ "version": 1, "enabled": true, "subdomain": "protected", "zoneId": "zone00000000000000000000000000001", "zoneName": "example.test", "hostname": "protected.example.test", "accessEmails": ["owner@example.test"], "enabledAt": "2026-10-21T05:46:40" }' | Set-Content -LiteralPath (Join-Path $pathA 'config\dashboard.json')
  '{ "version": 1, "settings": null, "deployment": { "mode": "tunnel", "tunnelChoice": "existing", "tunnelId": "11111111-2222-3333-4444-555555555555", "tunnelName": "existing-tunnel", "newTunnelName": "" }, "installedAt": "2026-10-21T04:00:03" }' | Set-Content -LiteralPath (Join-Path $pathA 'config\setup.json')
  $svc = New-ServiceDefinition -Name 'mediabox' -Hostname 'keep.example.test' -TargetType lan -TargetHost '10.20.30.11' -Port 4119
  $svc | Add-Member -NotePropertyName displayName -NotePropertyValue 'Mediabox' -Force
  $null = Invoke-ServicePlan -Settings $sA -Plan (Get-ServicePlan -Settings $sA -Services @($svc)) -NoReload
  Remove-Item -LiteralPath (Join-Path $pathA 'backups') -Recurse -Force -ErrorAction SilentlyContinue
  # B: a second, independent installed deployment whose token was saved by another Windows account (unreadable).
  $null = New-TestInstance -Repo $repo -Path $pathB -StackName $stackB -Subnet '172.31.239.0/28'
  '{}' | Set-Content -LiteralPath (Join-Path $pathB '.install-manifest.json')
  New-Item -ItemType Directory -Force -Path (Join-Path $pathB 'secrets') | Out-Null
  '{"version":1,"scope":"DPAPI-CurrentUser","user":"OTHERPC\\someone","savedAt":"2026-01-01T00:00:00","data":"AQAAANCMnd8BFdERjHoAwE"}' | Set-Content -LiteralPath (Join-Path $pathB 'secrets\cloudflare_api.dpapi')
  '{ "version": 1, "accountId": "acc0000000000000000000000000001", "accountName": "Test Account", "tunnelId": "11111111-2222-3333-4444-555555555555", "tunnelName": "existing-tunnel", "domains": [], "managed": {} }' | Set-Content -LiteralPath (Join-Path $pathB 'config\cloudflare.json')
  # C: setup choices saved, not installed.  L: the earlier single-app layout.  X: unrelated.  P: a copy of the program.  E: empty.
  New-Item -ItemType Directory -Force -Path (Join-Path $pathC 'config'), (Join-Path $pathL 'traefik'), $pathX, $pathP, $pathE | Out-Null
  '{ "version": 1, "settings": { "STACK_NAME": "draft-one", "TRAEFIK_HTTP_PORT": "18480", "TRAEFIK_DASHBOARD_PORT": "18481", "PROXY_NETWORK": "draft-one-proxy", "TUNNEL_SUBNET": "172.31.240.0/28", "TUNNEL_IP_RANGE": "172.31.240.0/29", "CLOUDFLARED_IP": "172.31.240.10" }, "deployment": { "mode": "local" } }' | Set-Content -LiteralPath (Join-Path $pathC 'config\setup.json')
  "name: legacy-proxy`nservices:`n  traefik:`n    image: traefik:v3.1`n    container_name: traefik`n" | Set-Content -LiteralPath (Join-Path $pathL 'compose.yaml')
  'api: {}' | Set-Content -LiteralPath (Join-Path $pathL 'traefik\traefik.yml')
  'hello' | Set-Content -LiteralPath (Join-Path $pathX 'readme.txt')
  Copy-Item -LiteralPath (Join-Path $repo 'compose.yaml') -Destination $pathP
  $snapA = Get-FolderSnapshot $pathA; $snapL = Get-FolderSnapshot $pathL; $snapB = Get-FolderSnapshot $pathB

  # --- Module-level discovery -------------------------------------------------------------------------------------------
  $kinds = @{}; foreach ($p in @($pathA, $pathB, $pathC, $pathL, $pathX, $pathP, $pathE, (Join-Path $root 'nope'))) { $kinds[(Split-Path -Leaf $p)] = Get-ProjectKind $p }
  Test-Condition 'kinds: installed, draft, legacy layout, program copy, unrelated, missing' ($kinds.alpha -eq 'manager' -and $kinds.beta -eq 'manager' -and $kinds.draft -eq 'draft' -and $kinds['old-layout'] -eq 'legacy' -and
    $kinds['program-copy'] -eq 'package' -and $kinds.unrelated -eq 'other' -and $kinds.empty -eq 'other' -and $kinds.nope -eq 'missing') ($kinds | ConvertTo-Json -Compress)
  $bad = @()
  foreach ($p in @('\\server\share\x', '//server/share', 'relative\path', 'C:', 'C:\', "$env:windir\System32", 'C:\a|b', ('C:\' + ('x' * 250)))) { try { $null = ConvertTo-ProjectPath $p; $bad += $p } catch { } }
  $norm = ConvertTo-ProjectPath " `"$pathA\sub\..\`" "
  Test-Condition 'paths: UNC, relative, drive roots, the Windows folder and invalid names are refused; quotes, .. and trailing \ are normalized' ($bad.Count -eq 0 -and $norm -eq $pathA) "accepted: $($bad -join ', '); normalized: $norm"

  # --- Website in chooser mode -----------------------------------------------------------------------------------------------
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $stateFile = Join-Path $work 'state\webui.json'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stateFile) | Out-Null
  ('{"installPath":"' + ($pathE -replace '\\', '\\') + '"}') | Set-Content -LiteralPath $stateFile   # the folder used "last time"
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -WorkDir $work -ApiBase $mock.Base -StateFile $stateFile -ExtraArgs @('-ProjectsRoot', "`"$root`"")
  $null = Connect-WebUi $ui
  $s = Invoke-WebUi $ui GET '/api/session'
  $blocked = Invoke-WebUi $ui POST '/api/setup/settings' @{ settings = @{ STACK_NAME = 'x' } }
  Test-Condition 'first launch: the chooser comes first; nothing can change a folder before a deployment is chosen' ($s.Data.chosen -eq $false -and $blocked.Status -eq 409) (Short $blocked)
  $st = Invoke-WebUi $ui GET '/api/status'
  Test-Condition 'first launch: status works without choosing (read-only)' ($st.Status -eq 200) (Short $st)
  $pr = Invoke-WebUi $ui GET '/api/projects'
  $byName = @{}; foreach ($p in @($pr.Data.projects)) { $byName[(Split-Path -Leaf $p.summary.path)] = $p }
  Test-Condition 'discovery: deployments, draft and legacy layout listed; unrelated and program-copy folders not (the empty folder only as the remembered one)' ($pr.Status -eq 200 -and $byName.ContainsKey('alpha') -and $byName.ContainsKey('beta') -and $byName.ContainsKey('draft') -and
    $byName.ContainsKey('old-layout') -and -not $byName.ContainsKey('unrelated') -and -not $byName.ContainsKey('program-copy') -and (-not $byName.ContainsKey('empty') -or $byName.empty.recent)) (($byName.Keys | Sort-Object) -join ', ')
  $sa = $byName.alpha.summary
  Test-Condition 'discovery summary of A: name, tunnel, domain, dashboard, services, token readable, upgrade available' ($sa.stackName -eq $stackA -and $sa.mode -eq 'tunnel' -and $sa.tunnelName -eq 'existing-tunnel' -and @($sa.domains) -contains 'example.test' -and
    $sa.dashboardUrl -eq 'https://protected.example.test/dashboard/' -and $sa.services -eq 1 -and $sa.tokenReadable -and $sa.upgrade -eq 'available' -and $sa.installedVersion -eq '1.1.0') ($sa | ConvertTo-Json -Compress)
  Test-Condition 'discovery summary of B: separate instance, token needs reconnection; legacy layout is not usable' ($byName.beta.summary.stackName -eq $stackB -and $byName.beta.summary.tokenStored -and -not $byName.beta.summary.tokenReadable -and
    -not $byName['old-layout'].summary.usable -and $byName['old-layout'].summary.kind -eq 'legacy') ''

  # --- Inspection ---------------------------------------------------------------------------------------------------------
  $writes0 = @(Get-Writes).Count
  $ia = Invoke-WebUi $ui POST '/api/projects/inspect' @{ path = $pathA; cloudflare = $true }
  $it = @{}; foreach ($x in @($ia.Data.items)) { $it[$x.id] = $x }
  Test-Condition 'inspect A: settings, saved files and the service (with display name) are detected' ($ia.Status -eq 200 -and $ia.Data.usable -and $it['instance'].message -eq $stackA -and $it['.env'].status -eq 'detected' -and
    $it['config\dashboard.json'].status -eq 'detected' -and $it['config\services.json'].status -eq 'detected' -and $it['mediabox'].label -eq 'Mediabox (mediabox)' -and $it['mediabox'].status -eq 'detected') (Short $ia)
  Test-Condition 'inspect A: Cloudflare account, tunnel, zone, DNS record and Access app verified with read-only requests' ($ia.Data.cloudflareChecked -and $it['account'].status -eq 'verified' -and $it['tunnel'].status -eq 'verified' -and
    $it["zone-$zone1"].status -eq 'verified' -and $it['res-keep.example.test-DNS record'].status -eq 'verified' -and $it['res-protected.example.test-Access application'].status -eq 'verified' -and @(Get-Writes).Count -eq $writes0) (Short $ia)
  Test-Condition 'inspect A: secrets reported as present/readable only; the connector token matches the tunnel' ($it['token'].status -eq 'detected' -and $it['connector-token'].status -eq 'detected' -and
    -not $ia.Body.Contains($apiToken) -and -not $ia.Body.Contains($tunnelToken) -and -not $ia.Body.Contains('dGVzdC1zZWNyZXQ')) ''
  Test-Condition 'inspect A: upgrade available (1.1.0 -> this manager), lib\TraefikProxy.psm1 listed; not required to open' ($it['version'].status -eq 'upgrade' -and @($ia.Data.upgrade.changed) -contains 'lib\TraefikProxy.psm1' -and
    $ia.Data.upgrade.installedVersion -eq '1.1.0' -and $it['version'].message -match 'does not require an upgrade') ($it['version'] | ConvertTo-Json -Compress)
  Test-Condition 'inspect A: containers of a never-started instance are reported missing (not invented)' ($it['traefik'].status -eq 'missing') ($it['traefik'] | ConvertTo-Json -Compress)
  # A real-world token limited to account resources cannot list /accounts but works on the account.
  $pathD = Join-Path $work 'no-accounts'
  $null = New-TestInstance -Repo $repo -Path $pathD -StackName "tpx-pj-d-$id" -Subnet '172.31.241.0/28'
  Copy-Item -LiteralPath (Join-Path $pathA 'config\cloudflare.json') -Destination (Join-Path $pathD 'config\cloudflare.json')
  Save-CloudflareApiToken -Settings (Get-StackSettings -InstallPath $pathD) -Token ('mockNoAccounts_' + [Guid]::NewGuid().ToString('N'))
  $idd = Invoke-WebUi $ui POST '/api/projects/inspect' @{ path = $pathD; cloudflare = $true }
  $td = @{}; foreach ($x in @($idd.Data.items)) { $td[$x.id] = $x }
  Test-Condition 'inspect: a token that cannot list accounts still verifies the account and tunnel through the account''s resources' ($idd.Status -eq 200 -and $td['account'].status -eq 'verified' -and $td['tunnel'].status -eq 'verified') (Short $idd)
  $ib = Invoke-WebUi $ui POST '/api/projects/inspect' @{ path = $pathB; cloudflare = $true }
  $tb = @($ib.Data.items | Where-Object { $_.id -eq 'token' })[0]
  Test-Condition 'inspect B: unreadable token -> "Needs reconnection", configuration kept and still usable' ($ib.Status -eq 200 -and $ib.Data.usable -and $tb.status -eq 'reconnect' -and $tb.message -match 'nothing is deleted') (Short $ib)
  $il = Invoke-WebUi $ui POST '/api/projects/inspect' @{ path = $pathL }
  Test-Condition 'inspect legacy layout: recognized, not usable, left alone' ($il.Status -eq 200 -and -not $il.Data.usable -and $il.Data.legacy) (Short $il)

  # --- Attach -------------------------------------------------------------------------------------------------------------
  $r = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = $pathL }
  $r2 = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = $pathX }
  $r3 = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = (Join-Path $root 'nope') }
  $r4 = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = '\\server\share\proxy' }
  Test-Condition 'attach refused for the legacy layout (409), unrelated folders (409), missing folders (404) and network paths (400)' ($r.Status -eq 409 -and $r2.Status -eq 409 -and $r3.Status -eq 404 -and $r4.Status -eq 400) "$($r.Status) $($r2.Status) $($r3.Status) $($r4.Status)"
  $r = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = $pathA }
  $s = Invoke-WebUi $ui GET '/api/session'
  $st = Invoke-WebUi $ui GET '/api/status'
  $sv = Invoke-WebUi $ui GET '/api/services'
  $da = Invoke-WebUi $ui GET '/api/dashboard'
  $cfd = Invoke-WebUi $ui GET '/api/cloudflare'
  $ov = Invoke-WebUi $ui GET '/api/overview'
  Test-Condition 'attach A: becomes the active deployment with its own instance, services, dashboard and Cloudflare selections' ($r.Status -eq 200 -and $s.Data.chosen -and $st.Data.instance.stackName -eq $stackA -and
    @($sv.Data.services | Where-Object { $_.service.displayName -eq 'Mediabox' }).Count -eq 1 -and $da.Data.publicUrl -eq 'https://protected.example.test/dashboard/' -and $cfd.Data.config.tunnelName -eq 'existing-tunnel' -and $cfd.Data.token.Readable -and
    $ov.Data.upgrade.state -eq 'available') "$(Short $r) $(Short $ov)"
  Test-Condition 'attach A: no file in the deployment folder, no Docker resource and nothing in Cloudflare changed' ((Get-FolderSnapshot $pathA) -eq $snapA -and (Get-DockerSnapshot) -eq $dockerBefore -and @(Get-Writes).Count -eq 0) "writes: $(@(Get-Writes).Count)"
  $state = Get-Content -Raw $stateFile | ConvertFrom-Json
  Test-Condition 'recent projects: stored outside the deployment (user profile state file), A on top with its name' ((Test-SamePath $state.installPath $pathA) -and (Test-SamePath @($state.recent)[0].path $pathA) -and @($state.recent)[0].stackName -eq $stackA -and
    -not (Test-Path (Join-Path $pathA 'webui.json'))) ($state | ConvertTo-Json -Compress -Depth 4)
  $r = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = $pathB }
  $cfb = Invoke-WebUi $ui GET '/api/cloudflare'
  $stb = Invoke-WebUi $ui GET '/api/status'
  $null = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = $pathA }
  $cfa2 = Invoke-WebUi $ui GET '/api/cloudflare'
  Test-Condition 'multiple deployments: switching keeps settings and credentials apart (B unreadable, A readable)' ($r.Status -eq 200 -and $stb.Data.instance.stackName -eq $stackB -and $cfb.Data.token.Stored -and -not $cfb.Data.token.Readable -and $cfa2.Data.token.Readable) ''
  Test-Condition 'attach B and switching back: B files unchanged as well' ((Get-FolderSnapshot $pathB) -eq $snapB) ''

  # --- New deployment, folder picker -------------------------------------------------------------------------------------
  $n1 = Invoke-WebUi $ui POST '/api/projects/new' @{ path = $pathA }
  $n2 = Invoke-WebUi $ui POST '/api/projects/new' @{ path = $pathX }
  $n3 = Invoke-WebUi $ui POST '/api/projects/new' @{ path = $pathE }
  $su = Invoke-WebUi $ui GET '/api/setup'
  Test-Condition 'new deployment: refused over an existing deployment (open it instead) and in a non-empty folder; allowed in an empty one, nothing written' ($n1.Status -eq 409 -and $n1.Data.needsAttach -and $n2.Status -eq 409 -and $n3.Status -eq 200 -and
    (Test-SamePath $su.Data.installPath $pathE) -and -not $su.Data.installed -and @(Get-ChildItem -LiteralPath $pathE -Force).Count -eq 0) "$($n1.Status) $($n2.Status) $($n3.Status)"
  $b = Invoke-WebUi $ui GET "/api/projects/browse?path=$([Uri]::EscapeDataString($root))"
  $ek = @{}; foreach ($e in @($b.Data.entries)) { $ek[$e.name] = $e.kind }
  $bu = Invoke-WebUi $ui GET "/api/projects/browse?path=$([Uri]::EscapeDataString('\\server\share'))"
  $bf = Invoke-WebUi $ui GET "/api/projects/browse?path=$([Uri]::EscapeDataString((Join-Path $pathX 'readme.txt')))"
  Test-Condition 'folder picker: subfolders only (no files), deployments marked; network paths and files refused' ($b.Status -eq 200 -and $ek.alpha -eq 'manager' -and $ek.draft -eq 'draft' -and $ek['old-layout'] -eq 'legacy' -and $b.Body -notmatch 'readme\.txt' -and
    $bu.Status -eq 400 -and $bf.Status -eq 400 -and @($b.Data.roots).Count -ge 1) "$($b.Status) $($bu.Status) $($bf.Status)"

  # --- Upgrade preview and apply (A) ----------------------------------------------------------------------------------------
  $null = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = $pathA }
  $pv = Invoke-WebUi $ui POST '/api/projects/upgrade/preview' @{ path = $pathA }
  Test-Condition 'upgrade preview: a dry run lists the file update and changes nothing' ($pv.Status -eq 200 -and $pv.Data.ok -and @($pv.Data.files | Where-Object { $_.action -eq 'update' -and $_.file -eq 'lib\TraefikProxy.psm1' }).Count -eq 1 -and
    (Get-FolderSnapshot $pathA) -eq $snapA -and (Get-DockerSnapshot) -eq $dockerBefore) (Short $pv)
  $ap0 = Invoke-WebUi $ui POST '/api/projects/upgrade/apply' @{ path = $pathA; confirm = $true; previewKey = 'nope' }
  $ap1 = Invoke-WebUi $ui POST '/api/projects/upgrade/apply' @{ path = $pathA; previewKey = $pv.Data.previewKey }
  Test-Condition 'upgrade apply: needs the preview and an explicit confirmation' ($ap0.Status -eq 409 -and $ap1.Status -eq 400 -and (Get-FolderSnapshot $pathA) -eq $snapA) "$($ap0.Status) $($ap1.Status)"
  $cfgBefore = (@('.env', 'config\cloudflare.json', 'config\dashboard.json', 'config\services.json', 'config\setup.json', 'secrets\cloudflare_api.dpapi', 'secrets\cloudflare_tunnel_token', 'traefik\dynamic\svc-mediabox.yml') | ForEach-Object { Get-FileSha256 (Join-Path $pathA $_) }) -join ','
  $ap = Invoke-WebUi $ui POST '/api/projects/upgrade/apply' @{ path = $pathA; confirm = $true; previewKey = $pv.Data.previewKey }
  $cfgAfter = (@('.env', 'config\cloudflare.json', 'config\dashboard.json', 'config\services.json', 'config\setup.json', 'secrets\cloudflare_api.dpapi', 'secrets\cloudflare_tunnel_token', 'traefik\dynamic\svc-mediabox.yml') | ForEach-Object { Get-FileSha256 (Join-Path $pathA $_) }) -join ','
  Test-Condition 'upgrade apply: application files updated, configuration and secrets untouched, recovery point and previous copies kept, no Docker change' ($ap.Status -eq 200 -and $ap.Data.ok -and $ap.Data.upgrade.state -eq 'current' -and
    (Get-FileSha256 (Join-Path $pathA 'lib\TraefikProxy.psm1')) -eq (Get-FileSha256 (Join-Path $repo 'lib\TraefikProxy.psm1')) -and $cfgBefore -eq $cfgAfter -and $ap.Data.recoveryPoint -and
    @(Get-ChildItem -LiteralPath (Join-Path $pathA 'backups') -Recurse -Filter 'TraefikProxy.psm1').Count -eq 1 -and (Get-DockerSnapshot) -eq $dockerBefore -and @(Get-Writes).Count -eq 0) (Short $ap)

  # --- Recent projects across restarts --------------------------------------------------------------------------------------
  Stop-TestServer $ui; $ui = $null
  Remove-Item -LiteralPath $pathB -Recurse -Force
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -WorkDir $work -ApiBase $mock.Base -StateFile $stateFile -ExtraArgs @('-ProjectsRoot', "`"$root`"")
  $null = Connect-WebUi $ui
  $pr = Invoke-WebUi $ui GET '/api/projects'
  $rb = @($pr.Data.projects | Where-Object { (Split-Path -Leaf $_.summary.path) -eq 'beta' })
  $ra = @($pr.Data.projects | Where-Object { (Split-Path -Leaf $_.summary.path) -eq 'alpha' })
  Test-Condition 'recent projects: remembered after a restart; a deleted folder is shown as missing' ($ra.Count -eq 1 -and $ra[0].recent -and $rb.Count -eq 1 -and $rb[0].summary.kind -eq 'missing' -and -not $rb[0].summary.usable) ''
  $fg = Invoke-WebUi $ui POST '/api/projects/forget' @{ path = $pathB }
  $pr = Invoke-WebUi $ui GET '/api/projects'
  $fa = Invoke-WebUi $ui POST '/api/projects/forget' @{ path = $pathA }
  Test-Condition 'recent projects: removing from the list keeps the deployment files' ($fg.Status -eq 200 -and @($pr.Data.projects | Where-Object { (Split-Path -Leaf $_.summary.path) -eq 'beta' }).Count -eq 0 -and $fa.Status -eq 200 -and
    (Test-Path (Join-Path $pathA '.env')) -and (Test-Path (Join-Path $pathA 'config\cloudflare.json'))) ''
  Stop-TestServer $ui; $ui = $null

  # --- Launcher -------------------------------------------------------------------------------------------------------------
  $sd1 = Join-Path $work 'launcher-1'
  $port1 = Get-FreeTcpPort
  $l1 = Start-LauncherServer $sd1 $port1
  $null = $servers.Add($l1)
  $info = Get-Content -Raw (Join-Path $sd1 'manager.json') | ConvertFrom-Json
  $url1 = ([IO.File]::ReadAllText((Join-Path $sd1 'launch.url'))).Trim()
  $acl = (& icacls (Join-Path $sd1 'launch.url')) -join ' '
  $cmdLines = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object { [string]$_.CommandLine } | Where-Object { $_ -match 'Start-DeploymentManager|webui\.ps1' })
  $key1 = ([Uri]$url1).Query
  Test-Condition 'launcher: starts the website; manager.json holds process, port and folder only; the sign-in link file is readable by this user only' ($l1.Ready -and [int]$info.port -eq $port1 -and
    ((Get-Content -Raw (Join-Path $sd1 'manager.json')) -notmatch '\?k=') -and $acl -notmatch 'BUILTIN\\Users|Everyone|\(I\)') "$acl"
  Test-Condition 'launcher: the sign-in key never appears on a command line' (@($cmdLines | Where-Object { $_.Contains($key1.Substring(3)) }).Count -eq 0 -and $cmdLines.Count -ge 1) ''
  $u = [Uri]$url1
  $h1 = Invoke-RawHttp -Port $port1 -Path $u.PathAndQuery
  $h2 = Invoke-RawHttp -Port $port1 -Path $u.PathAndQuery
  $url2 = ([IO.File]::ReadAllText((Join-Path $sd1 'launch.url'))).Trim()
  $h3 = Invoke-RawHttp -Port $port1 -Path ([Uri]$url2).PathAndQuery
  Test-Condition 'launcher: each sign-in link works once; the next one is written for "open again"' ($h1.Status -eq 303 -and $h2.Status -eq 403 -and $url2 -ne $url1 -and $h3.Status -eq 303) "$($h1.Status) $($h2.Status) $($h3.Status)"
  $dup = Invoke-Launcher @('-NoBrowser', '-StateDir', "`"$sd1`"", '-IfRunning', 'open', '-ProjectsRoot', "`"$root`"")
  $info2 = Get-Content -Raw (Join-Path $sd1 'manager.json') | ConvertFrom-Json
  Test-Condition 'launcher: a second start finds the running manager and reopens it instead of starting another' ($dup.Exited -and $dup.Code -eq 0 -and [int]$info2.pid -eq [int]$info.pid -and $dup.Text -match 'running') $dup.Text
  $stat = Invoke-Launcher @('-Status', '-StateDir', "`"$sd1`"")
  Test-Condition 'launcher: -Status reports the running manager' ($stat.Code -eq 0 -and $stat.Text -match "Running: http://127.0.0.1:$port1/") $stat.Text
  # Port collision: another program holds the port -> the next free one is used.
  $sd2 = Join-Path $work 'launcher-2'
  $busy = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $busy.Start(); $busyPort = $busy.LocalEndpoint.Port
  $l2 = Start-LauncherServer $sd2 $busyPort
  $null = $servers.Add($l2)
  $info3 = $null; if ($l2.Ready) { $info3 = Get-Content -Raw (Join-Path $sd2 'manager.json') | ConvertFrom-Json }
  $busy.Stop()
  Test-Condition 'launcher: when the port is used by another program, a free one is chosen' ($l2.Ready -and $info3 -and [int]$info3.port -ne $busyPort -and (Get-Content -Raw $l2.Out) -match 'used by another program') ''
  $stop2 = Invoke-Launcher @('-Stop', '-StateDir', "`"$sd2`"")
  $stop1 = Invoke-Launcher @('-Stop', '-StateDir', "`"$sd1`"")
  $null = $l1.Process.WaitForExit(15000); $null = $l2.Process.WaitForExit(15000)
  Test-Condition 'launcher: -Stop stops the manager and cleans up its state files' ($stop1.Code -eq 0 -and $stop2.Code -eq 0 -and $l1.Process.HasExited -and $l2.Process.HasExited -and
    -not (Test-Path (Join-Path $sd1 'manager.json')) -and -not (Test-Path (Join-Path $sd1 'launch.url')) -and -not (Test-PortOpen $port1)) "$($stop1.Text) $($stop2.Text)"
  # Docker missing from PATH: the website still starts.
  $sd3 = Join-Path $work 'launcher-3'
  $oldPath = $env:PATH
  $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and -not (Test-Path (Join-Path $_ 'docker.exe')) }) -join ';'
  try { $port3 = Get-FreeTcpPort; $l3 = Start-LauncherServer $sd3 $port3; $null = $servers.Add($l3) } finally { $env:PATH = $oldPath }
  $txt3 = Get-Content -Raw $l3.Out -ErrorAction SilentlyContinue
  $sess3 = Invoke-RawHttp -Port $port3 -Path '/api/session'
  Test-Condition 'first launch without Docker: the website starts and says Docker Desktop was not found' ($l3.Ready -and $txt3 -match 'Docker Desktop: not found' -and $sess3.Status -eq 401) $txt3
  $null = Invoke-Launcher @('-Stop', '-StateDir', "`"$sd3`"")
  # Missing program files: a readable message, no start.
  $copy = Join-Path $work 'broken-copy'
  New-Item -ItemType Directory -Force -Path $copy | Out-Null
  Copy-Item -LiteralPath (Join-Path $repo 'Start-DeploymentManager.ps1') -Destination $copy
  $p = Start-Process powershell.exe -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'broken.out') -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $copy 'Start-DeploymentManager.ps1')`"", '-NoBrowser', '-StateDir', "`"$(Join-Path $work 'launcher-4')`"")
  $txt4 = Get-Content -Raw (Join-Path $work 'broken.out')
  Test-Condition 'launcher: missing program files -> exit code 1 and a plain explanation' ($p.ExitCode -eq 1 -and $txt4 -match 'program files are missing' -and $txt4 -match 'Extract the whole ZIP') $txt4
  # START-HERE.cmd passes its arguments through and starts the same launcher.
  $sd5 = Join-Path $work 'launcher-5'; $port5 = Get-FreeTcpPort
  # cmd /c needs the whole command in one more pair of quotes when the path contains spaces.
  $cmd = Start-Process cmd.exe -PassThru -WindowStyle Hidden -ArgumentList @('/c', "`"`"$(Join-Path $repo 'START-HERE.cmd')`" -NoBrowser -StateDir `"$sd5`" -Port $port5 -ProjectsRoot `"$root`"`"")
  $null = $cmd.Handle
  $ok5 = Wait-File (Join-Path $sd5 'launch.url')
  $sess5 = if ($ok5) { Invoke-RawHttp -Port $port5 -Path '/api/session' } else { [pscustomobject]@{ Status = 0 } }
  $null = Invoke-Launcher @('-Stop', '-StateDir', "`"$sd5`"")
  $null = $cmd.WaitForExit(15000)
  Test-Condition 'START-HERE.cmd: starts the manager (paths relative to itself) and ends cleanly after Stop' ($ok5 -and $sess5.Status -eq 401 -and $cmd.HasExited -and $cmd.ExitCode -eq 0) "ready=$ok5 session=$($sess5.Status) exit=$($cmd.ExitCode)"
  Test-Condition 'START-HERE.cmd and STOP-MANAGER.cmd use Windows line endings' ([IO.File]::ReadAllText((Join-Path $repo 'START-HERE.cmd')).Contains("`r`n") -and [IO.File]::ReadAllText((Join-Path $repo 'STOP-MANAGER.cmd')).Contains("`r`n")) ''

  # --- Browser ------------------------------------------------------------------------------------------------------------------
  if ($SkipBrowser -or -not (Get-EdgePath)) { Add-Result 'SKIP' 'browser checks' 'skipped or Edge not found' }
  else {
    # The upgrade test above brought A up to date; make its files older again for the browser review.
    [IO.File]::WriteAllText($mod, ([IO.File]::ReadAllText($mod) -replace "ManagerVersion = '[^']+'", "ManagerVersion = '1.1.0'"))
    $mf = Get-Content -Raw (Join-Path $pathA '.install-manifest.json') | ConvertFrom-Json; $mf.'lib\TraefikProxy.psm1' = Get-FileSha256 $mod; $mf | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pathA '.install-manifest.json') -Encoding ASCII
    $stateFile2 = Join-Path $work 'state2\webui.json'
    $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui-browser')).FullName -ApiBase $mock.Base -StateFile $stateFile2 -ExtraArgs @('-ProjectsRoot', "`"$root`"")
    $cdp = Start-EdgeSession -WorkDir $work
    Set-Viewport $cdp 1366 900
    Open-Page $cdp $ui.LaunchUrl
    $ok = Wait-PageCondition $cdp "document.querySelector('main h1') && document.querySelector('main h1').textContent === 'Choose a deployment' && document.querySelectorAll('main article.rv').length >= 2" 40
    $txt = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
    Test-Condition 'browser: the first launch shows the chooser with the found deployments and both actions' ($ok -and $txt -match 'Continue where you left off' -and $txt -match 'Start a new deployment' -and $txt -match [regex]::Escape($stackA) -and $txt -match 'We found') ($txt.Substring(0, [Math]::Min(600, $txt.Length)))
    if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'first-launch-chooser-1366.png') }
    $bad = @()
    foreach ($w in @(390, 820, 1366)) {
      Set-Viewport $cdp $w 900 -Mobile:($w -lt 800)
      Start-Sleep -Milliseconds 400
      $o = [int](Invoke-PageScript $cdp 'document.documentElement.scrollWidth - window.innerWidth')
      if ($o -gt 1) { $bad += "$w px: $o" }
      if ($w -eq 390 -and $ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'first-launch-chooser-phone-390.png') }
    }
    Set-Viewport $cdp 1366 900
    Test-Condition 'browser: the chooser fits phone, tablet and desktop widths' ($bad.Count -eq 0) ($bad -join '; ')
    $unnamed = @(Invoke-PageScript $cdp "[...document.querySelectorAll('button, a[href], input, select')].filter((el) => el.checkVisibility() && !(el.getAttribute('aria-label') || el.getAttribute('title') || (el.id && document.querySelector('label[for=\'' + el.id + '\']')) || el.closest('label') || el.textContent.trim())).map((el) => el.outerHTML.slice(0, 80))")
    Test-Condition 'browser: chooser controls have accessible names; one h1' ($unnamed.Count -eq 0 -and [int](Invoke-PageScript $cdp "document.querySelectorAll('main h1').length") -eq 1) ($unnamed -join ' | ')
    $null = Invoke-PageScript $cdp "[...document.querySelectorAll('main article.rv')].find((a) => a.innerText.includes('$stackA')).querySelector('button').click(); true"
    $ok = Wait-PageCondition $cdp "document.querySelector('main h1') && document.querySelector('main h1').textContent === '$stackA' && document.querySelector('#rv-attach-cloudflare')" 60
    $rt = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
    Test-Condition 'browser: the review shows sections with Detected / Verified / Upgrade available and the two separate actions' ($ok -and $rt -match 'Verified' -and $rt -match 'Detected' -and $rt -match 'Upgrade available' -and $rt -match 'Open existing deployment' -and $rt -match 'Preview upgrade' -and $rt -match 'reads only') ($rt.Substring(0, [Math]::Min(700, $rt.Length)))
    if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'attach-review-1366.png') }
    $null = Invoke-PageScript $cdp "document.querySelector('input[name=detail-level][value=expert]').click(); true"
    $null = Wait-PageCondition $cdp "document.querySelector('main').innerText.includes('Raw inspection result')" 30
    $exp = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
    Test-Condition 'browser: Expert shows exact paths and identifiers' ($exp -match 'Raw inspection result' -and $exp -match [regex]::Escape($pathA)) ''
    $null = Invoke-PageScript $cdp "document.querySelector('input[name=detail-level][value=beginner]').click(); true"
    $null = Wait-PageCondition $cdp "[...document.querySelectorAll('main button')].some((b) => b.textContent.includes('Open existing deployment'))" 30
    $null = Invoke-PageScript $cdp "[...document.querySelectorAll('main button')].find((b) => b.textContent.includes('Open existing deployment')).click(); true"
    $ok = Wait-PageCondition $cdp "location.hash.startsWith('#overview') && document.querySelector('.tiles') && !document.querySelector('main').innerText.includes('Loading')" 60
    Start-Sleep -Seconds 1
    $ot = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText + ' ' + document.querySelector('#instance-pill').innerText")
    Test-Condition 'browser: after opening, the Overview shows the instance, domain, dashboard URL, services and the upgrade offer' ($ok -and $ot -match [regex]::Escape($stackA) -and $ot -match 'example\.test' -and $ot -match 'protected\.example\.test/dashboard' -and $ot -match 'Newer application files') ($ot.Substring(0, [Math]::Min(700, $ot.Length)))
    if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'attached-overview-1366.png') }
    Test-Condition 'browser: no JavaScript errors' ($cdp.Errors.Count -eq 0) ($cdp.Errors -join ' | ')
  }
  Test-Condition 'the legacy layout folder was never changed' ((Get-FolderSnapshot $pathL) -eq $snapL) ''
  Test-Condition 'no Docker resource was created, started, stopped or removed' ((Get-DockerSnapshot) -eq $dockerBefore) ''

  # --- Optional: the real installation, read-only --------------------------------------------------------------------------------
  if ($LiveReadOnly) {
    $live = Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy'
    if (-not (Test-Path -LiteralPath $live)) { Add-Result 'SKIP' 'live installation' "$live not found" }
    else {
      $liveBefore = Get-FolderSnapshot $live
      $liveDocker = Get-DockerSnapshot
      $job = Start-Job -ScriptBlock { param($repo, $live)
        Import-Module (Join-Path $repo 'lib\ProjectDiscovery.psm1')
        Get-ProjectInspection -Path $live -SourceRoot $repo -Cloudflare | ConvertTo-Json -Depth 8 } -ArgumentList $repo, $live
      $json = Receive-Job -Job $job -Wait -AutoRemoveJob
      $li = $json | ConvertFrom-Json
      $lt = @{}; foreach ($x in @($li.items)) { $lt[$x.id] = $x }
      $names = (@($li.items | ForEach-Object { "$($_.id)=$($_.status)" }) -join ', ')
      Test-Condition 'live (read-only): the installed deployment is discovered from its files and Docker metadata' ($li.usable -and [string]$lt['instance'].message -and $lt['proxy-network'].label -match 'proxynet' -and
        [string]$lt['tunnel'].message -and [string]$lt['dashboard'].message -match '\.' -and $lt['token'].status -in @('detected', 'verified') -and
        $lt['traefik'].status -eq 'verified' -and $lt['socket-proxy'].status -eq 'verified' -and $lt['cloudflared'].status -eq 'verified') $names
      Test-Condition 'live (read-only): Cloudflare account and tunnel verified with read-only requests' ($li.cloudflareChecked -and $lt['account'].status -eq 'verified' -and $lt['tunnel'].status -eq 'verified') $names
      Test-Condition 'live (read-only): no secret in the result; nothing in the folder or Docker changed' ($json -notmatch 'eyJ[A-Za-z0-9_-]{20,}' -and (Get-FolderSnapshot $live) -eq $liveBefore -and (Get-DockerSnapshot) -eq $liveDocker) ''
    }
  }
} catch {
  Add-Result 'FAIL' 'test run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
} finally {
  Stop-EdgeSession $cdp
  Stop-TestServer $ui
  foreach ($srv in $servers) { if ($srv -and -not $srv.Process.HasExited) { Stop-Process -Id $srv.Process.Id -Force -ErrorAction SilentlyContinue } }
  Stop-TestServer $mock
  Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
