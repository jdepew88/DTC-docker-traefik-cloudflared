#requires -version 5.1
<#
.SYNOPSIS
  Regression tests for the Cloudflare-first onboarding wizard (web UI setup steps), against a Cloudflare API mock.

.DESCRIPTION
  Starts webui.ps1 from this source folder for an install folder that does not exist yet (no .env, no token, no
  Traefik) and walks the wizard the way the browser does:
    - the "Create Cloudflare API Token" template link (host, path, permission keys, scope parameters)
    - token verification and discovery: one domain (auto-selected), several domains, missing Zone / Tunnel /
      Access permissions, a disabled token, a rejected token
    - token replacement (needs confirmation) and removal; the token never appears in responses or files
    - the domain allowlist
    - skipping Cloudflare for a local-only installation; unsupported methods are refused
    - instance settings (suggested free values, validation), moving the install folder
    - preview: no Docker or Cloudflare change before the installation is confirmed
    - a confirmed local-only installation of a uniquely named disposable instance, removed again afterwards
  Tunnel-mode installation is previewed but not run (cloudflared would try to reach the real Cloudflare).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Onboarding.ps1
#>
[CmdletBinding()]
param([switch]$KeepFiles)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail }
}
function Short($r) { if ($null -eq $r) { return '(no response)' }; return "HTTP $($r.Status) $($r.Body.Substring(0, [Math]::Min(500, $r.Body.Length)))" }
function Ui([string]$Method, [string]$Path, $Body) { return Invoke-WebUi $ui $Method $Path $Body }
function Get-Perm($Data, [string]$Id) { return @($Data.permissions | Where-Object { $_.id -eq $Id })[0] }
function New-MockToken([string]$TokenProfile) { return "mock${TokenProfile}_" + [Guid]::NewGuid().ToString('N') }
# Containers and networks on this engine (to prove that nothing changed).
function Get-DockerSnapshot {
  $c = @((Invoke-Docker ps -a --format '{{.ID}} {{.Names}} {{.State}}').Output | Where-Object { $_ } | Sort-Object)
  $n = @((Invoke-Docker network ls --format '{{.ID}} {{.Name}}').Output | Where-Object { $_ } | Sort-Object)
  return [pscustomobject]@{ Containers = $c; Networks = $n }
}
function Get-Writes { return @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' -and $_.path -ne '/_state' }) }

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpx-onboarding-$id"
$install = Join-Path $work 'first\traefik-proxy'
$install2 = Join-Path $work 'second\proxy'
$stateFile = Join-Path $work 'webui-state.json'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$usedTokens = New-Object System.Collections.ArrayList
$null = $usedTokens.Add($apiToken)
$stack = "tpx-onb-$id"
$mock = $null; $ui = $null; $installedSettings = $null; $createdNetwork = $false

try {
  $dockerBefore = Get-DockerSnapshot
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir $work -ApiBase $mock.Base
  $null = Connect-WebUi $ui

  # --- Fresh installation --------------------------------------------------------------------------------------
  $r = Ui GET '/api/setup'
  Test-Condition 'fresh install: no .env, defaults, nothing installed, no token' ($r.Status -eq 200 -and -not $r.Data.installed -and $r.Data.settingsSource -eq 'defaults' -and
    -not $r.Data.cloudflare.tokenStored -and -not (Test-Path -LiteralPath $install)) (Short $r)
  $setup = $r.Data

  # --- Token creation link ---------------------------------------------------------------------------------------
  foreach ($variant in @(@{ Url = $setup.cloudflare.tokenLink; Access = $false }, @{ Url = $setup.cloudflare.tokenLinkWithAccess; Access = $true })) {
    $u = [Uri]$variant.Url
    $q = @{}
    foreach ($pair in $u.Query.TrimStart('?').Split('&')) { $kv = $pair.Split('=', 2); $q[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1]) }
    $parsed = ConvertFrom-Json $q['permissionGroupKeys']
    $keys = @(foreach ($k in $parsed) { "$($k.key):$($k.type)" })
    $expected = @('zone:read', 'dns:edit', 'argotunnel:edit')
    if ($variant.Access) { $expected += 'access:edit' }
    $label = if ($variant.Access) { 'with Access' } else { 'without Access' }
    Test-Condition "token link ($label): https://dash.cloudflare.com/profile/api-tokens" ($u.Scheme -eq 'https' -and $u.Host -eq 'dash.cloudflare.com' -and $u.AbsolutePath -eq '/profile/api-tokens') $variant.Url
    Test-Condition "token link ($label): exactly the needed permissions" (($keys -join ',') -eq ($expected -join ',')) ($keys -join ',')
    Test-Condition "token link ($label): documented scope values, a name, nothing else" ($q['accountId'] -eq '*' -and $q['zoneId'] -eq 'all' -and $q['name'] -and
      (@($q.Keys | Sort-Object) -join ',') -eq 'accountId,name,permissionGroupKeys,zoneId') (($q.Keys | Sort-Object) -join ',')
  }
  Test-Condition 'permission list: 4 entries, Access optional' (@($setup.cloudflare.permissions).Count -eq 4 -and
    @($setup.cloudflare.permissions | Where-Object { $_.optional }).Count -eq 1 -and @($setup.cloudflare.permissions | Where-Object { $_.optional })[0].id -eq 'access') (Short $r)

  # --- Token with one domain ---------------------------------------------------------------------------------------
  $r = Ui POST '/api/cloudflare/token' @{ token = 'not a token' }
  Test-Condition 'malformed token refused, nothing written' ($r.Status -eq 400 -and -not (Test-Path -LiteralPath $install)) (Short $r)
  $r = Ui POST '/api/cloudflare/token' @{ token = ('wrongTok_' + [Guid]::NewGuid().ToString('N')) }
  Test-Condition 'token rejected by Cloudflare: 400, not stored' ($r.Status -eq 400 -and $r.Data.error -match 'not saved' -and -not (Test-Path -LiteralPath $install)) (Short $r)
  $t = New-MockToken 'Disabled'; $null = $usedTokens.Add($t)
  $r = Ui POST '/api/cloudflare/token' @{ token = $t }
  Test-Condition 'disabled token: 400 with the reason, not stored' ($r.Status -eq 400 -and $r.Data.error -match 'disabled' -and -not (Test-Path -LiteralPath $install)) (Short $r)

  $t = New-MockToken 'One'; $null = $usedTokens.Add($t)
  $r = Ui POST '/api/cloudflare/token' @{ token = $t }
  Test-Condition 'one-domain token: verified and saved before installation' ($r.Status -eq 200 -and $r.Data.saved -and (Test-Path -LiteralPath (Join-Path $install 'secrets\cloudflare_api.dpapi'))) (Short $r)
  Test-Condition 'one domain: selected automatically' (@($r.Data.zones).Count -eq 1 -and @($r.Data.domains).Count -eq 1 -and $r.Data.domains[0].name -eq 'example.test' -and $r.Data.zones[0].allowed) (Short $r)
  Test-Condition 'single account selected automatically' ($r.Data.accountId -eq 'acc0000000000000000000000000001') (Short $r)
  Test-Condition 'all permissions detected (zone, dns, tunnel, access)' (((@('zone', 'dns', 'tunnel', 'access') | ForEach-Object { (Get-Perm $r.Data $_).state }) -join ',') -eq 'ok,ok,ok,ok') (($r.Data.permissions | ForEach-Object { "$($_.id)=$($_.state)" }) -join ',')
  Test-Condition 'tunnels discovered' (@($r.Data.tunnels).Count -eq 2) (Short $r)
  Test-Condition 'saving the token wrote only the secret and Cloudflare selections (no .env, no stack files)' (-not (Test-Path (Join-Path $install '.env')) -and -not (Test-Path (Join-Path $install 'compose.yaml')) -and
    (Test-Path (Join-Path $install 'config\cloudflare.json'))) ((Get-ChildItem -LiteralPath $install -Recurse -File | ForEach-Object { $_.FullName.Substring($install.Length) }) -join ', ')
  Test-Condition 'install folder remembered for the next start' ((Test-Path $stateFile) -and ([IO.File]::ReadAllText($stateFile) | ConvertFrom-Json).installPath -eq $install) ''

  # --- Replacement, several domains ------------------------------------------------------------------------------------
  $r = Ui POST '/api/cloudflare/token' @{ token = $apiToken }
  Test-Condition 'replacing needs confirmation (409)' ($r.Status -eq 409 -and $r.Data.needsConfirm -eq 'replace') (Short $r)
  $r = Ui POST '/api/cloudflare/token' @{ token = $apiToken; confirmReplace = $true }
  Test-Condition 'replacement: two domains visible, previous allowlist kept, other.test not added' ($r.Status -eq 200 -and @($r.Data.zones).Count -eq 2 -and
    (@($r.Data.domains | ForEach-Object { $_.name }) -join ',') -eq 'example.test') (Short $r)
  $r = Ui POST '/api/cloudflare/domains' @{ zoneIds = @('zone00000000000000000000000000001', 'zone00000000000000000000000000002') }
  Test-Condition 'several domains: both allowed on request' ($r.Status -eq 200 -and @($r.Data.domains).Count -eq 2) (Short $r)
  $r = Ui GET '/api/cloudflare/discovery'
  Test-Condition 'discovery with the stored token: both domains allowed, DNS readable' ($r.Status -eq 200 -and @($r.Data.zones | Where-Object { $_.allowed -and $_.dns -eq 'ok' }).Count -eq 2) (Short $r)

  # --- Missing permissions ------------------------------------------------------------------------------------------------
  $t = New-MockToken 'NoTunnel'; $null = $usedTokens.Add($t)
  $r = Ui POST '/api/cloudflare/token' @{ token = $t; confirmReplace = $true }
  $p = Get-Perm $r.Data 'tunnel'
  Test-Condition 'no Tunnel permission: saved, reported as missing with advice' ($r.Status -eq 200 -and $p.state -eq 'missing' -and $p.message -match 'Cloudflare Tunnel' -and (Get-Perm $r.Data 'zone').state -eq 'ok') (Short $r)
  $t = New-MockToken 'NoAccess'; $null = $usedTokens.Add($t)
  $r = Ui POST '/api/cloudflare/token' @{ token = $t; confirmReplace = $true }
  $p = Get-Perm $r.Data 'access'
  Test-Condition 'no Access permission: optional, explained' ($r.Status -eq 200 -and $p.state -eq 'missing' -and $p.optional -and (Get-Perm $r.Data 'tunnel').state -eq 'ok') (Short $r)
  $t = New-MockToken 'NoZone'; $null = $usedTokens.Add($t)
  $r = Ui POST '/api/cloudflare/token' @{ token = $t; confirmReplace = $true }
  Test-Condition 'no Zone permission: no domains, explained, allowlist emptied' ($r.Status -eq 200 -and @($r.Data.zones).Count -eq 0 -and (Get-Perm $r.Data 'zone').state -eq 'missing' -and
    (Get-Perm $r.Data 'zone').message -match 'Zone > Zone > Read' -and @($r.Data.domains).Count -eq 0) (Short $r)
  $r = Ui GET '/api/cloudflare/discovery'
  Test-Condition 'discovery never fails on missing permissions' ($r.Status -eq 200) (Short $r)

  # --- Removal ---------------------------------------------------------------------------------------------------------------
  $r = Ui POST '/api/cloudflare/token/delete' @{}
  Test-Condition 'removal needs confirmation' ($r.Status -eq 400 -and (Test-Path (Join-Path $install 'secrets\cloudflare_api.dpapi'))) (Short $r)
  $r = Ui POST '/api/cloudflare/token/delete' @{ confirm = $true }
  $s = Ui GET '/api/setup'
  Test-Condition 'token removed' ($r.Status -eq 200 -and -not (Test-Path (Join-Path $install 'secrets\cloudflare_api.dpapi')) -and -not $s.Data.cloudflare.tokenStored) (Short $r)

  # --- Local only, without Cloudflare ------------------------------------------------------------------------------------------
  $r = Ui POST '/api/setup/deployment' @{ mode = 'tunnel'; tunnelChoice = 'new'; newTunnelName = 'x' }
  Test-Condition 'tunnel mode without a token is refused' ($r.Status -eq 409) (Short $r)
  $r = Ui POST '/api/setup/deployment' @{ mode = 'public-ip' }
  Test-Condition 'unsupported public-IP mode is refused, with the reason' ($r.Status -eq 400 -and $r.Data.error -match 'Not supported') (Short $r)
  $r = Ui POST '/api/setup/deployment' @{ mode = 'local' }
  Test-Condition 'Cloudflare skipped: local-only mode saved without a token' ($r.Status -eq 200 -and $r.Data.deployment.mode -eq 'local' -and -not $r.Data.cloudflare.tokenStored) (Short $r)
  Test-Condition 'unsupported features are labeled, not claimed' (@($r.Data.modes | Where-Object { $_.id -eq 'public-ip' -and -not $_.supported }).Count -eq 1 -and $r.Data.tls.letsEncryptSupported -eq $false) (Short $r)

  # --- Instance settings and install folder ------------------------------------------------------------------------------------
  $r = Ui POST '/api/setup/suggest' @{}
  Test-Condition 'suggested settings have no conflicts' ($r.Status -eq 200 -and @($r.Data.conflicts | Where-Object { $_.Level -eq 'error' }).Count -eq 0) (Short $r)
  $values = @{}; foreach ($p in $r.Data.settings.PSObject.Properties) { $values[$p.Name] = $p.Value }
  $bad = @{} + $values; $bad['TRAEFIK_HTTP_PORT'] = 'abc'
  $r = Ui POST '/api/setup/settings' @{ settings = $bad }
  Test-Condition 'invalid settings refused' ($r.Status -eq 400) (Short $r)
  $bad = @{} + $values; $bad['CLOUDFLARED_IP'] = '10.0.0.1'
  $r = Ui POST '/api/setup/settings' @{ settings = $bad }
  Test-Condition 'inconsistent tunnel addresses refused' ($r.Status -eq 400 -and $r.Data.error -match 'CLOUDFLARED_IP') (Short $r)
  # A unique name and free ports, so the disposable instance can never collide with a real one.
  $values['STACK_NAME'] = $stack; $values['PROXY_NETWORK'] = "$stack-proxy"
  $values['TRAEFIK_HTTP_PORT'] = [string](Get-FreeTcpPort); $values['TRAEFIK_DASHBOARD_PORT'] = [string](Get-FreeTcpPort)
  $r = Ui POST '/api/setup/settings' @{ settings = $values }
  Test-Condition 'settings saved as a draft (no .env yet)' ($r.Status -eq 200 -and @($r.Data.conflicts | Where-Object { $_.Level -eq 'error' }).Count -eq 0 -and -not (Test-Path (Join-Path $install '.env'))) (Short $r)

  $r = Ui POST '/api/setup/path' @{ path = 'relative\folder' }
  Test-Condition 'install folder must be a full local path' ($r.Status -eq 400) (Short $r)
  $r = Ui POST '/api/setup/path' @{ path = $install2 }
  Test-Condition 'install folder changed; wizard files moved along' ($r.Status -eq 200 -and $r.Data.installPath -eq $install2 -and (Test-Path (Join-Path $install2 'config\setup.json')) -and
    -not (Test-Path (Join-Path $install 'config\setup.json')) -and $r.Data.settings.STACK_NAME -eq $stack -and $r.Data.deployment.mode -eq 'local') (Short $r)
  Test-Condition 'new install folder remembered' (([IO.File]::ReadAllText($stateFile) | ConvertFrom-Json).installPath -eq $install2) ''

  # --- Preview: nothing changes before confirmation -------------------------------------------------------------------------------
  $r = Ui POST '/api/setup/preview' @{}
  $plan = $r.Data
  Test-Condition 'preview: installable, steps listed, dry run ran' ($r.Status -eq 200 -and $plan.canInstall -and @($plan.steps).Count -ge 2 -and ((@($plan.dryRun) -join "`n") -match 'Dry run complete')) (Short $r)
  Test-Condition 'local-only preview: no Cloudflare step, no tunnel' (@($plan.steps | Where-Object { $_.kind -eq 'cloudflare' }).Count -eq 0 -and ((@($plan.steps | ForEach-Object { $_.text }) -join ' ') -notmatch 'EnableTunnel')) (($plan.steps | ForEach-Object { $_.text }) -join ' | ')
  $r = Ui POST '/api/setup/install' @{ planKey = $plan.planKey }
  Test-Condition 'install without confirmation -> 400' ($r.Status -eq 400) (Short $r)
  $r = Ui POST '/api/setup/install' @{ confirm = $true; planKey = 'stale' }
  Test-Condition 'install with a stale preview -> 409' ($r.Status -eq 409) (Short $r)
  $dockerMid = Get-DockerSnapshot
  Test-Condition 'no Docker change before confirmation (containers and networks identical)' ((($dockerMid.Containers -join '|') -eq ($dockerBefore.Containers -join '|')) -and (($dockerMid.Networks -join '|') -eq ($dockerBefore.Networks -join '|'))) ''
  Test-Condition 'no Cloudflare change before confirmation (only GET requests)' (@(Get-Writes).Count -eq 0) ((Get-Writes | ConvertTo-Json -Compress -Depth 4))
  Test-Condition 'no .env or stack files before confirmation' (-not (Test-Path (Join-Path $install2 '.env')) -and -not (Test-Path (Join-Path $install2 'compose.yaml'))) ''

  # --- Tunnel-mode preview (not installed) ----------------------------------------------------------------------------------------
  $r = Ui POST '/api/cloudflare/token' @{ token = $apiToken }
  Test-Condition 'token saved again for the tunnel preview' ($r.Status -eq 200) (Short $r)
  $r = Ui POST '/api/setup/deployment' @{ mode = 'tunnel'; tunnelChoice = 'existing'; tunnelId = '99999999-2222-3333-4444-555555555555' }
  Test-Condition 'locally managed tunnel cannot be chosen' ($r.Status -eq 400) (Short $r)
  $r = Ui POST '/api/setup/deployment' @{ mode = 'tunnel'; tunnelChoice = 'new'; newTunnelName = 'existing-tunnel' }
  Test-Condition 'new tunnel name that already exists is refused' ($r.Status -eq 400) (Short $r)
  $r = Ui POST '/api/setup/deployment' @{ mode = 'tunnel'; tunnelChoice = 'new'; newTunnelName = "onboarding-$id" }
  Test-Condition 'tunnel mode with a new tunnel saved (not created yet)' ($r.Status -eq 200 -and $r.Data.deployment.tunnelChoice -eq 'new' -and
    @((Get-MockState $mock).tunnels | Where-Object { $_.name -eq "onboarding-$id" }).Count -eq 0) (Short $r)
  $r = Ui POST '/api/setup/preview' @{}
  Test-Condition 'tunnel preview lists the tunnel creation as a Cloudflare step' ($r.Status -eq 200 -and @($r.Data.steps | Where-Object { $_.kind -eq 'cloudflare' -and $_.text -match "onboarding-$id" }).Count -eq 1 -and
    ((@($r.Data.steps | ForEach-Object { $_.text }) -join ' ') -match 'EnableTunnel')) (Short $r)
  Test-Condition 'tunnel preview warns that no domain is allowed yet' ((@($r.Data.warnings) -join ' ') -match 'allowed domain') (Short $r)
  Test-Condition 'still no Cloudflare writes' (@(Get-Writes).Count -eq 0) ((Get-Writes | ConvertTo-Json -Compress -Depth 4))
  $r = Ui POST '/api/setup/deployment' @{ mode = 'local' }
  $r = Ui POST '/api/cloudflare/token/delete' @{ confirm = $true }

  # --- Confirmed local-only installation ----------------------------------------------------------------------------------------
  $r = Ui POST '/api/setup/preview' @{}
  $plan = $r.Data
  $netExisted = (Invoke-Docker network inspect "$stack-proxy").ExitCode -eq 0
  $r = Ui POST '/api/setup/install' @{ confirm = $true; planKey = $plan.planKey }
  $installedSettings = Get-StackSettings -InstallPath $install2
  $createdNetwork = -not $netExisted
  Test-Condition 'confirmed install: ok' ($r.Status -eq 200 -and $r.Data.ok) ((Short $r) + ' ' + ((@($r.Data.lines) | Select-Object -Last 8) -join ' | '))
  Test-Condition '.env written with the chosen settings' ($installedSettings.StackName -eq $stack -and $installedSettings.HttpPort -eq [int]$values['TRAEFIK_HTTP_PORT']) ''
  Test-Condition "this instance's Traefik runs; no cloudflared" ((Test-ContainerRunning "$stack-traefik") -and -not (Test-ContainerRunning "$stack-cloudflared")) ''
  $s = Ui GET '/api/setup'
  Test-Condition 'wizard shows the instance as installed; settings locked' ($s.Data.installed -and -not $s.Data.canChangePath) (Short $s)
  $r = Ui POST '/api/setup/settings' @{ settings = $values }
  Test-Condition 'settings cannot be changed through the wizard after installation' ($r.Status -eq 409) (Short $r)
  Test-Condition 'no Cloudflare writes during a local-only install' (@(Get-Writes).Count -eq 0) ''

  # --- Secrets ------------------------------------------------------------------------------------------------------------------------
  $all = ($ui.Bodies -join "`n")
  $leaks = @($usedTokens | Where-Object { $all.Contains($_) })
  Test-Condition 'no API token in any web UI response' ($leaks.Count -eq 0) ''
  $fileLeaks = @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 5MB } | Where-Object {
      $fs = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
      try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
      @($usedTokens | Where-Object { $text.Contains($_) }).Count -gt 0 })
  Test-Condition 'no API token in any file (config, audit log, state, mock log)' ($fileLeaks.Count -eq 0) (($fileLeaks | ForEach-Object { $_.FullName }) -join ', ')
} finally {
  Stop-TestServer $ui
  Stop-TestServer $mock
  if ($installedSettings -and $installedSettings.StackName -eq $stack) {
    $down = Invoke-Docker @((Get-ComposeArgs -Settings $installedSettings -Profiles @('tunnel', 'test')) + @('down', '--remove-orphans'))
    if ($createdNetwork) { $null = Invoke-Docker network rm "$stack-proxy" }
  }
  $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
  $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
  Test-Condition 'teardown: no test containers or networks left' ($left.Count -eq 0 -and $leftNets.Count -eq 0) (($left + $leftNets) -join ', ')
  $after = Get-DockerSnapshot
  Test-Condition 'other containers and networks unchanged (IDs, names, states)' ((($after.Containers -join '|') -eq ($dockerBefore.Containers -join '|')) -and (($after.Networks -join '|') -eq ($dockerBefore.Networks -join '|'))) ''
  if (-not $KeepFiles) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "Files kept in $work" }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count -gt 0) { exit 1 }
