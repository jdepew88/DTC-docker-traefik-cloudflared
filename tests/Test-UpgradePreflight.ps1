#requires -version 5.1
<#
.SYNOPSIS
  Upgrade preflight: opens this (new) manager against a COPY of an existing deployment and records every change it makes.

.DESCRIPTION
  Answers "does merely opening the new manager change the existing installation?" without touching it:
  - the deployment folder is copied to %TEMP%\<prefix> without secrets\, backups\ and logs\ (no credential is copied,
    so no Cloudflare or authentik API call can be authenticated);
  - every project folder under -ProjectsRoot is copied one level deep (Compose files, .env, metadata; no data folders);
  - the copied manager reaches Docker only through a disposable read-only socket proxy (GET/HEAD only): any write the
    manager attempts is refused by the proxy and reported instead of reaching Docker;
  - Cloudflare calls go to a closed loopback port.
  First this version's install.ps1 upgrades the copy (as the real upgrade would, without -Start); then the copy's
  upgraded manager is started. The script calls every GET endpoint the pages use (and the per-application ones for each application), then reports
  the files the manager created or changed in the copy, every refused Docker write, and checks that the real deployment
  folder, the project folders and every container are unchanged. The copy is deleted afterwards.

.EXAMPLE
  .\tests\Test-UpgradePreflight.ps1 -SourceInstall "$env:USERPROFILE\.docker\projects\traefik-proxy"
#>
param(
  [string]$SourceInstall = (Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy'),
  [string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.docker\projects'),
  # Open this repository's manager on the unchanged copy instead of first upgrading the copy with install.ps1.
  [switch]$SkipInstall
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TestResources.psm1') -Force

$script:Pass = 0; $script:Fail = 0
function Check([bool]$Ok, [string]$What) { if ($Ok) { $script:Pass++; Write-Host "[PASS] $What" -ForegroundColor Green } else { $script:Fail++; Write-Host "[FAIL] $What" -ForegroundColor Red } }
function Note([string]$Text) { Write-Host "  $Text" }
# Native docker call whose stderr is expected (refused writes, proxy logs): output lines and exit code, never a terminating error.
function Invoke-DockerRaw {
  $a = @($args | ForEach-Object { [string]$_ })
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = @(& docker @a 2>&1 | ForEach-Object { "$_" }); return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $o } } finally { $ErrorActionPreference = $prev }
}

# Hashes of every file below $Root (relative path -> SHA-256), skipping the named top-level folders.
function Get-TreeHashes([string]$Root, [string[]]$SkipDirs = @(), [int]$Depth = 99) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $Root)) { return $map }
  $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
  $walk = $null
  $walk = {
    param($dir, $level)
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
      $rel = $f.FullName.Substring($rootFull.Length + 1)
      if ($f.PSIsContainer) {
        if ($level -eq 0 -and $SkipDirs -contains $f.Name) { continue }
        if ($level + 1 -lt $Depth) { & $walk $f.FullName ($level + 1) }
      } else {
        try { $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { $map[$rel] = 'unreadable' }
      }
    }
  }
  & $walk $rootFull 0
  return $map
}
function Compare-TreeHashes($Before, $After) {
  $changes = New-Object System.Collections.ArrayList
  foreach ($k in $After.Keys) { if (-not $Before.ContainsKey($k)) { $null = $changes.Add("created  $k") } elseif ($Before[$k] -ne $After[$k]) { $null = $changes.Add("changed  $k") } }
  foreach ($k in $Before.Keys) { if (-not $After.ContainsKey($k)) { $null = $changes.Add("deleted  $k") } }
  return @($changes | Sort-Object)
}
function Get-ContainerFingerprint {
  $ids = @(Invoke-TrDocker ps -aq)
  if (-not $ids.Count) { return @() }
  return @(Invoke-TrDocker inspect -f '{{.Name}} {{.Id}} {{.State.Status}} {{.State.StartedAt}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}' @ids | Where-Object { $_ -notmatch '^/tp[xm]-' } | Sort-Object)
}

if (-not (Test-Path -LiteralPath (Join-Path $SourceInstall '.env'))) { throw "Not a deployment folder: $SourceInstall" }
$installName = Split-Path -Leaf $SourceInstall
$prefix = 'tpx-up-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) $prefix
Register-TestRun -Prefix $prefix -Suite 'Test-UpgradePreflight'
$proxyName = "$prefix-ro-proxy"
$server = $null
$prodSkip = @('logs')

try {
  Write-Host "Upgrade preflight of $SourceInstall (copy in $work)" -ForegroundColor Cyan
  $realInstallBefore = Get-TreeHashes $SourceInstall $prodSkip
  $realProjectsBefore = @{}
  foreach ($d in @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory)) { if ($d.Name -ne $installName) { $realProjectsBefore[$d.Name] = Get-TreeHashes $d.FullName @() 1 } }
  $containersBefore = Get-ContainerFingerprint

  # The copy: deployment without secrets/backups/logs, projects one level deep.
  $projCopy = Join-Path $work 'projects'
  $instCopy = Join-Path $projCopy $installName
  New-Item -ItemType Directory -Force -Path $instCopy | Out-Null
  $null = & robocopy $SourceInstall $instCopy /E /XD (Join-Path $SourceInstall 'secrets') (Join-Path $SourceInstall 'backups') (Join-Path $SourceInstall 'logs') /NFL /NDL /NJH /NJS /NP
  if ($LASTEXITCODE -ge 8) { throw "Copying the deployment failed (robocopy $LASTEXITCODE)." }
  foreach ($d in @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory)) {
    if ($d.Name -eq $installName) { continue }
    $to = Join-Path $projCopy $d.Name
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Force)) { if ($f.Length -lt 5MB) { Copy-Item -LiteralPath $f.FullName -Destination $to } }
  }
  Check (-not (Test-Path -LiteralPath (Join-Path $instCopy 'secrets'))) 'the copy holds no credentials (secrets\ left out)'
  $copyBefore = Get-TreeHashes $projCopy

  # Read-only Docker access.
  $proxyPort = Get-FreeTcpPort
  $null = Invoke-TrDocker run -d --name $proxyName --label "org.traefik-proxy.test=$prefix" -e LOG_LEVEL=info -e PING=1 -e VERSION=1 -e INFO=1 -e CONTAINERS=1 -e NETWORKS=1 -e VOLUMES=1 -e IMAGES=1 -e EVENTS=1 -e SYSTEM=1 -e POST=0 -v /var/run/docker.sock:/var/run/docker.sock:ro -p "127.0.0.1:${proxyPort}:2375" tecnativa/docker-socket-proxy:v0.5.0
  if (-not (Wait-TcpPort $proxyPort 30)) { throw 'The read-only Docker proxy did not start.' }
  Start-Sleep -Seconds 2
  $env:DOCKER_HOST = "tcp://127.0.0.1:$proxyPort"
  try {
    $ps = Invoke-DockerRaw ps --format '{{.Names}}'
    Check ($ps.ExitCode -eq 0 -and @($ps.Output).Count -gt 0) 'Docker reads work through the read-only proxy'
    $probe = Invoke-DockerRaw network create "$prefix-probe"
    Check ($probe.ExitCode -ne 0 -and ($probe.Output -join ' ') -match '403') 'Docker writes are refused by the proxy (probe: network create -> 403)'

    # Step 1: the upgrade itself, install.ps1 of this version over the copy (no -Start).
    if (-not $SkipInstall) {
      Start-Sleep -Seconds 2   # --since has one-second resolution: keep the probe above out of this window
      $installMark = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      $instOut = Join-Path $work 'install.out'
      $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardOutput $instOut -RedirectStandardError "$instOut.err" -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $repo 'install.ps1')`"", '-InstallPath', "`"$instCopy`"")
      $null = $p.Handle   # Windows PowerShell 5.1 reports ExitCode only when the handle was opened before the exit.
      if (-not $p.WaitForExit(300000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw 'install.ps1 did not finish within 5 minutes (waiting for input?).' }
      Get-Content -LiteralPath "$instOut.err" -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { Note "stderr: $_" }
      $copyInstalled = Get-TreeHashes $projCopy
      $instWrites = @(Compare-TreeHashes $copyBefore $copyInstalled)
      Write-Host "install.ps1 over the copy: exit code $($p.ExitCode)" -ForegroundColor Cyan
      Get-Content -LiteralPath $instOut -ErrorAction SilentlyContinue | Where-Object { $_ -match 'WARN|Updated|Kept|\.dist|backup|error|failed' } | Select-Object -First 40 | ForEach-Object { Note $_ }
      Write-Host "Files install.ps1 created or changed: $($instWrites.Count) ($(@($instWrites | Where-Object { $_ -match '^changed' }).Count) changed, $(@($instWrites | Where-Object { $_ -match '^created' }).Count) created, $(@($instWrites | Where-Object { $_ -match '^deleted' }).Count) deleted)" -ForegroundColor Cyan
      $instWrites | Where-Object { $_ -notmatch '^created  [^\\]+\\(lib|webui|catalog|tests|docs|launcher|scripts|examples)\\' } | ForEach-Object { Note $_ }
      $instRefused = @((Invoke-DockerRaw logs --since $installMark $proxyName).Output | Where-Object { $_ -match '\s403\s|"(POST|PUT|DELETE)\s' -and $_ -notmatch $prefix })
      Write-Host 'Docker writes install.ps1 attempted (refused by the read-only proxy):' -ForegroundColor Cyan
      if ($instRefused.Count) { $instRefused | Select-Object -First 20 | ForEach-Object { Note $_ } } else { Note '(none)' }
      # Expected: one unnamed throwaway container (Traefik image, --network none) that touches traefik\dynamic\.reload so
      # Traefik re-reads its unchanged route files (Sync-TraefikDynamic). Anything else is unexpected.
      $instOther = @($instRefused | Where-Object { $_ -notmatch '"POST /v[0-9.]+/containers/create HTTP' })
      Check ($instOther.Count -eq 0 -and @($instRefused).Count -le 1) "install.ps1 attempts no Docker write except the Traefik reload helper container$(if ($instOther.Count) { ': ' + ($instOther -join ' | ') })"
      Check ($p.ExitCode -eq 0) 'install.ps1 (upgrade without -Start) completes on the copy'
      Check (-not @($instWrites | Where-Object { $_ -match '^deleted' }).Count) 'the upgrade deletes no file'
      $cfgTouched = @($instWrites | Where-Object { $_ -match '^changed  [^\\]+\\(config|traefik\\dynamic\\svc-|\.env$)' })
      Check ($cfgTouched.Count -eq 0) "the upgrade changes no configuration, route or .env file$(if ($cfgTouched.Count) { ': ' + ($cfgTouched -join '; ') })"
      $copyBefore = $copyInstalled
    }
    $webuiScript = $(if ($SkipInstall) { Join-Path $repo 'webui.ps1' } else { Join-Path $instCopy 'webui.ps1' })
    $server = Start-WebUiServer -Script $webuiScript -InstallPath $instCopy -WorkDir $work -ApiBase 'http://127.0.0.1:9' -ExtraArgs @('-ProjectsRoot', "`"$projCopy`"")
  } finally { Remove-Item Env:\DOCKER_HOST -ErrorAction SilentlyContinue }
  $null = Connect-WebUi $server
  $proxyLogMark = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

  # Every GET endpoint the pages use.
  $gets = '/api/session', '/api/status', '/api/overview', '/api/services', '/api/backups', '/api/projects', '/api/launcher', '/api/dashboard',
  '/api/infrastructure', '/api/docker/containers', '/api/docker/claims', '/api/catalog', '/api/catalog/defaults', '/api/apps', '/api/system/resources',
  '/api/identity', '/api/identity?deep=1', '/api/identity?deep=1&probe=apps', '/api/routing', '/api/applications', '/api/managers', '/api/applications/repairs',
  '/api/provision', '/api/provision/recipes', '/api/environment', '/api/expert/config', '/api/logs', '/api/audit', '/api/cloudflare', '/api/setup'
  $bad = @()
  foreach ($g in $gets) {
    $r = Invoke-WebUi $server GET $g
    if ($r.Status -ge 500) { $bad += "$g -> $($r.Status) $([string]$r.Body | Select-Object -First 1)" }
  }
  $apps = @()
  $ar = Invoke-WebUi $server GET '/api/apps'
  if ($ar.Data -and $ar.Data.PSObject.Properties['apps']) { $apps = @($ar.Data.apps | ForEach-Object { [string]$_.project } | Where-Object { $_ }) }
  foreach ($p in $apps) {
    foreach ($g in "/api/apps/detail?project=$p", "/api/apps/stack?project=$p", "/api/apps/backups?project=$p", "/api/apps/logs?project=$p&tail=5") {
      $r = Invoke-WebUi $server GET $g
      if ($r.Status -ge 500) { $bad += "$g -> $($r.Status)" }
    }
  }
  Note "$($gets.Count) page endpoints and $($apps.Count) application(s) x 4 detail endpoints called."
  Check ($bad.Count -eq 0) "no endpoint failed with a server error$(if ($bad.Count) { ': ' + ($bad -join '; ') })"
  Stop-TestServer $server; $server = $null

  # What the manager did.
  $copyAfter = Get-TreeHashes $projCopy
  $writes = @(Compare-TreeHashes $copyBefore $copyAfter | Where-Object { $_ -notmatch '\\logs\\' })
  Write-Host 'Files the new manager created or changed in the copy by being opened:' -ForegroundColor Cyan
  if ($writes.Count) { $writes | ForEach-Object { Note $_ } } else { Note '(none)' }
  $proxyLog = @((Invoke-DockerRaw logs --since $proxyLogMark $proxyName).Output)
  $refused = @($proxyLog | Where-Object { $_ -match '\s403\s|"(POST|PUT|DELETE)\s' -and $_ -notmatch $prefix })
  # Expected: health probes, i.e. short-lived containers '<stack>-validate-probe-<8 hex>' (wget from the Traefik image,
  # --rm --read-only --cap-drop ALL, 32 MB) on the application's network. They change no container, volume or network.
  $probes = @($refused | Where-Object { $_ -match '"POST /v[0-9.]+/containers/create\?name=[a-z0-9_.-]+-validate-probe-[0-9a-f]{8} HTTP' })
  $other = @($refused | Where-Object { $probes -notcontains $_ })
  Write-Host "Docker writes the new manager attempted (refused by the read-only proxy): $($refused.Count), of which $($probes.Count) health-probe containers" -ForegroundColor Cyan
  if ($other.Count) { $other | Select-Object -First 30 | ForEach-Object { Note $_ } }
  Check ($other.Count -eq 0) "opening the new manager attempts no Docker write other than short-lived health-probe containers$(if ($other.Count) { ' (see above)' })"
  Check ($probes.Count -le ($apps.Count * 2 + 10)) "page views probe each application at most a few times (no retry loop; $($probes.Count) probe attempts for $($apps.Count) applications)"

  # The real installation is untouched.
  $realInstallAfter = Get-TreeHashes $SourceInstall $prodSkip
  $instChanges = @(Compare-TreeHashes $realInstallBefore $realInstallAfter)
  Check ($instChanges.Count -eq 0) "the real deployment folder is unchanged$(if ($instChanges.Count) { ': ' + ($instChanges -join '; ') })"
  $projChanges = @()
  foreach ($k in $realProjectsBefore.Keys) { $projChanges += @(Compare-TreeHashes $realProjectsBefore[$k] (Get-TreeHashes (Join-Path $ProjectsRoot $k) @() 1) | ForEach-Object { "$k\$_" }) }
  Check ($projChanges.Count -eq 0) "the real project folders are unchanged$(if ($projChanges.Count) { ': ' + ($projChanges -join '; ') })"
  $containersAfter = Get-ContainerFingerprint
  Check ((@(Compare-Object $containersBefore $containersAfter).Count) -eq 0) "every container is unchanged (id, state, start time, restarts, restart policy; $($containersBefore.Count) checked)"
} finally {
  if ($server) { Stop-TestServer $server }
  Remove-Item Env:\DOCKER_HOST -ErrorAction SilentlyContinue
  $null = Invoke-TrDocker rm -f $proxyName
  if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
  $left = @(Complete-TestRun $prefix)
  if ($left.Count) { Write-Host "Leftovers: $($left -join ', ')" -ForegroundColor Yellow }
}
Write-Host ''
Write-Host "Upgrade preflight: $script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
