#requires -version 5.1
<#
.SYNOPSIS
  End-to-end test in a disposable, fully isolated instance: install -> live tests -> services.ps1 walkthrough
  -> teardown. Existing stacks on this Docker engine are not started, stopped, recreated or reconfigured.

.DESCRIPTION
  The instance gets its own temporary install folder, STACK_NAME, loopback ports, proxy network and tunnel
  subnet, so it cannot collide with a production instance. The test backend has no Traefik labels, so no other
  Traefik on the engine routes it. Before/after snapshots prove other containers were not restarted.

  Steps
    1. install.ps1 -Start into %TEMP% (socket-proxy + traefik; no cloudflared, no token)
    2. tests\Test-Stack.ps1 against the instance
    3. services.ps1: preview-only add, apply, docker / lan / Windows-host targets, edit, disable, enable,
       rollback, remove, invalid input rejected, validate -Deep
    4. Teardown: compose down, remove the instance's proxy network and folder

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Invoke-IsolatedTest.ps1
#>
[CmdletBinding()]
param(
  [int]$HttpPort = 18280,
  [int]$DashboardPort = 18281,
  [string]$TunnelSubnet = '172.31.251.0/28',
  [switch]$KeepInstance
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow'; WARN = 'Yellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail }
}
function Invoke-Ps([string]$Script, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Text = (@($out) -join "`n") }
}
function Get-Http([string]$HostHeader, [string]$Path = '/') {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = (& curl.exe -s --max-time 15 -w "`n%{http_code}" -H "Host: $HostHeader" "http://127.0.0.1:$HttpPort$Path" 2>&1 | ForEach-Object { "$_" }) -join "`n" }
  finally { $ErrorActionPreference = $previous }
  $lines = $out -split "`n"
  return [pscustomobject]@{ Code = $lines[-1].Trim(); Body = (($lines | Select-Object -SkipLast 1) -join "`n") }
}
# Polls until the route answers as expected (Traefik reloads asynchronously after an apply).
function Wait-Http([string]$HostHeader, [string]$Path, [scriptblock]$Until, [int]$Seconds = 20) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do { $r = Get-Http $HostHeader $Path; if (& $Until $r) { return $r }; Start-Sleep -Milliseconds 700 } while ((Get-Date) -lt $deadline)
  return $r
}
# Every container on the engine with its ID and start time: proves nothing else was restarted or recreated.
function Get-EngineSnapshot([string]$ExcludePrefix) {
  $map = @{}
  foreach ($line in (Invoke-Docker ps -a --format '{{.Names}}').Output) {
    if (-not $line -or $line.StartsWith($ExcludePrefix)) { continue }
    $map[$line] = ((Invoke-Docker inspect $line --format '{{.Id}} {{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim()
  }
  return $map
}

# --- Instance parameters --------------------------------------------------------------------------------
$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$stack = "tpx-it-$id"
$network = "$stack-proxy"
$installPath = Join-Path ([IO.Path]::GetTempPath()) $stack
$range = ConvertTo-IPv4Range $TunnelSubnet
$octets = $TunnelSubnet.Split('/')[0].Split('.')
$ipRange = "$($octets[0]).$($octets[1]).$($octets[2]).$($octets[3])/29"
$cfIp = "$($octets[0]).$($octets[1]).$($octets[2]).$([int]$octets[3] + 10)"
foreach ($p in @($HttpPort, $DashboardPort)) {
  if (@(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue).Count -gt 0) { throw "Port $p is in use; pass -HttpPort/-DashboardPort." }
}
$envFile = Join-Path ([IO.Path]::GetTempPath()) "$stack.env"
@(
  "STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$HttpPort", "TRAEFIK_DASHBOARD_PORT=$DashboardPort", "PROXY_NETWORK=$network",
  "TUNNEL_SUBNET=$TunnelSubnet", "TUNNEL_IP_RANGE=$ipRange", "CLOUDFLARED_IP=$cfIp", 'TRAEFIK_LOG_LEVEL=INFO', 'TRAEFIK_READ_TIMEOUT=300s'
) | Set-Content -LiteralPath $envFile -Encoding ASCII
Write-Host "Isolated instance '$stack' in $installPath (ports $HttpPort/$DashboardPort, network $network, subnet $TunnelSubnet)" -ForegroundColor Cyan

$before = Get-EngineSnapshot $stack
$installed = $false
try {
  # --- 1. Install -------------------------------------------------------------------------------------------
  $dry = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-DryRun')
  Test-Condition 'install -DryRun succeeds and changes nothing' ($dry.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $installPath) -and ((Invoke-Docker network inspect $network).ExitCode -ne 0)) $dry.Text
  $install = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-Start')
  $installed = Test-Path -LiteralPath $installPath
  Test-Condition 'install -Start (isolated instance)' ($install.ExitCode -eq 0) ($install.Text -split "`n" | Select-Object -Last 15 | Out-String)
  if ($install.ExitCode -ne 0) { throw 'Install failed; skipping the remaining steps.' }
  $settings = Get-StackSettings -InstallPath $installPath
  Test-Condition 'instance containers are namespaced' ((Test-ContainerRunning "$stack-traefik") -and (Test-ContainerRunning "$stack-socket-proxy"))
  $reinstall = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-Start')
  Test-Condition 'install is idempotent (re-run with the stack running)' ($reinstall.ExitCode -eq 0 -and $reinstall.Text -match 'same    compose.yaml') ($reinstall.Text -split "`n" | Select-Object -Last 10 | Out-String)

  # --- 2. Live stack tests ------------------------------------------------------------------------------------
  $stackTest = Invoke-Ps (Join-Path $installPath 'tests\Test-Stack.ps1') @('-ProjectPath', $installPath)
  Write-Host ($stackTest.Text -split "`n" | ForEach-Object { "    $_" } | Out-String)
  Test-Condition 'tests\Test-Stack.ps1 on the isolated instance' ($stackTest.ExitCode -eq 0) ''

  # --- 3. services.ps1 walkthrough -----------------------------------------------------------------------------
  $svc = Join-Path $installPath 'services.ps1'
  $common = @('-InstallPath', $installPath)
  $up = Invoke-Docker @((Get-ComposeArgs -Settings $settings -Profiles @('test')) + @('up', '-d', 'whoami'))
  Test-Condition 'disposable whoami backend started' ($up.ExitCode -eq 0) ($up.Output -join ' ')
  $whoamiIp = ((Invoke-Docker inspect "$stack-whoami" --format "{{(index .NetworkSettings.Networks `"$network`").IPAddress}}").Output -join '').Trim()
  if ($whoamiIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    $nets = ((Invoke-Docker inspect "$stack-whoami" --format '{{json .NetworkSettings.Networks}}').Output -join '') | ConvertFrom-Json
    $whoamiIp = $nets.$network.IPAddress
  }

  $preview = Invoke-Ps $svc (@('add', '-Name', 'demo', '-Hostname', 'demo.test.example', '-TargetType', 'docker', '-TargetHost', "$stack-whoami", '-Port', '80') + $common)
  Test-Condition 'add without -Apply only previews' ($preview.ExitCode -eq 0 -and $preview.Text -match 'ADD\s+traefik\\dynamic\\svc-demo.yml' -and $preview.Text -match 'Nothing was changed' -and -not (Test-Path (Join-Path $installPath 'traefik\dynamic\svc-demo.yml'))) $preview.Text

  $add = Invoke-Ps $svc (@('add', '-Name', 'demo', '-Hostname', 'demo.test.example', '-TargetType', 'docker', '-TargetHost', "$stack-whoami", '-Port', '80', '-Apply') + $common)
  Test-Condition 'add -Apply: validated in Traefik, applied, loaded' ($add.ExitCode -eq 0 -and $add.Text -match 'Traefik accepted' -and $add.Text -match 'loaded every enabled service') $add.Text
  $r = Wait-Http 'demo.test.example' '/' { param($x) $x.Code -eq '200' }
  Test-Condition 'docker target answers through Traefik' ($r.Code -eq '200' -and $r.Body -match "Hostname:") "HTTP $($r.Code)"

  $lan = Invoke-Ps $svc (@('add', '-Name', 'lan-demo', '-Hostname', 'lan.test.example', '-TargetType', 'lan', '-TargetHost', $whoamiIp, '-Port', '80', '-LocalOnly', '-Apply') + $common)
  $r = Wait-Http 'lan.test.example' '/' { param($x) $x.Code -eq '200' }
  Test-Condition "LAN (IP address) target answers through Traefik ($whoamiIp)" ($lan.ExitCode -eq 0 -and $r.Code -eq '200' -and $r.Body -match 'Hostname:') "HTTP $($r.Code) $($lan.Text)"

  # A Windows-host target: this instance's own loopback dashboard port, reached via host.docker.internal.
  $hostAdd = Invoke-Ps $svc (@('add', '-Name', 'host-demo', '-Hostname', 'host.test.example', '-TargetType', 'host', '-Port', "$DashboardPort", '-LocalOnly', '-Apply') + $common)
  $r = Wait-Http 'host.test.example' '/api/version' { param($x) $x.Code -eq '200' }
  Test-Condition 'Windows host target (host.docker.internal) answers' ($hostAdd.ExitCode -eq 0 -and $r.Code -eq '200' -and $r.Body -match '"Version"') "HTTP $($r.Code) $($hostAdd.Text)"
  $null = Invoke-Ps $svc (@('remove', '-Name', 'host-demo', '-Apply') + $common)

  $bad = Invoke-Ps $svc (@('add', '-Name', 'bad', '-Hostname', 'demo.test.example', '-TargetType', 'lan', '-TargetHost', '127.0.0.1', '-Port', '80', '-Apply') + $common)
  Test-Condition 'invalid service rejected, nothing written' ($bad.ExitCode -ne 0 -and $bad.Text -match 'already routed' -and $bad.Text -match 'Loopback' -and -not (Test-Path (Join-Path $installPath 'traefik\dynamic\svc-bad.yml'))) $bad.Text

  $set = Invoke-Ps $svc (@('set', '-Name', 'demo', '-Port', '8080', '-Apply') + $common)
  $r = Wait-Http 'demo.test.example' '/' { param($x) $x.Code -eq '502' }
  Test-Condition 'set -Port shows a diff and applies (wrong port -> 502)' ($set.Text -match '\+\s+- url: http://.*:8080' -and $r.Code -eq '502') "HTTP $($r.Code)"

  $rb = Invoke-Ps $svc (@('rollback', '-Apply') + $common)
  $r = Wait-Http 'demo.test.example' '/' { param($x) $x.Code -eq '200' }
  Test-Condition 'rollback -Apply restores the previous route' ($rb.ExitCode -eq 0 -and $r.Code -eq '200') "HTTP $($r.Code) $($rb.Text)"

  $dis = Invoke-Ps $svc (@('disable', '-Name', 'demo', '-Apply') + $common)
  $r = Wait-Http 'demo.test.example' '/' { param($x) $x.Code -eq '404' }
  $list = Invoke-Ps $svc (@('list') + $common)
  Test-Condition 'disable removes the route but keeps the definition' ($dis.ExitCode -eq 0 -and $r.Code -eq '404' -and $list.Text -match 'demo\s+False') "HTTP $($r.Code)"
  $en = Invoke-Ps $svc (@('enable', '-Name', 'demo', '-Apply') + $common)
  $r = Wait-Http 'demo.test.example' '/' { param($x) $x.Code -eq '200' }
  Test-Condition 'enable restores the route' ($en.ExitCode -eq 0 -and $r.Code -eq '200') "HTTP $($r.Code)"

  $deep = Invoke-Ps $svc (@('validate', '-Deep') + $common)
  Test-Condition 'validate -Deep on the live registry' ($deep.ExitCode -eq 0 -and $deep.Text -match 'svc-demo@file\s+enabled') $deep.Text

  $routersLive = @(Get-TraefikApi $settings '/api/http/routers' | Where-Object { $_.name -like 'svc-*' } | ForEach-Object { $_.name })
  Test-Condition 'Traefik serves exactly the registry routes' ((($routersLive | Sort-Object) -join ',') -eq 'svc-demo@file,svc-lan-demo@file') ($routersLive -join ',')

  foreach ($n in @('demo', 'lan-demo')) { $null = Invoke-Ps $svc (@('remove', '-Name', $n, '-Apply') + $common) }
  $r = Wait-Http 'demo.test.example' '/' { param($x) $x.Code -eq '404' }
  Test-Condition 'remove deletes routes and definitions' ($r.Code -eq '404' -and @(Get-ChildItem (Join-Path $installPath 'traefik\dynamic') -Filter 'svc-*.yml').Count -eq 0) "HTTP $($r.Code)"

  $diag = Invoke-Ps (Join-Path $installPath 'scripts\Get-Diagnostics.ps1') @('-ProjectPath', $installPath)
  Test-Condition 'diagnostics run against the instance' ($diag.ExitCode -eq 0 -and $diag.Text -match "stack=$stack" -and $diag.Text -match 'Service registry') ''
} finally {
  # --- 4. Teardown ----------------------------------------------------------------------------------------------
  if ($installed -and -not $KeepInstance) {
    $stop = Invoke-Ps (Join-Path $installPath 'install.ps1') @('-InstallPath', $installPath, '-Stop')
    $null = Invoke-Docker network rm $network
    $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
    $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
    Test-Condition 'teardown: no instance containers or networks left' ($stop.ExitCode -eq 0 -and $left.Count -eq 0 -and $leftNets.Count -eq 0) (($left + $leftNets) -join ', ')
    Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $envFile -ErrorAction SilentlyContinue
  $after = Get-EngineSnapshot $stack
  $changed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) -or $after[$_] -ne $before[$_] })
  $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
  Test-Condition "other containers untouched ($($before.Count) checked: same IDs, start times, states)" ($changed.Count -eq 0 -and $added.Count -eq 0) ("changed: $($changed -join ', ') added: $($added -join ', ')")
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
