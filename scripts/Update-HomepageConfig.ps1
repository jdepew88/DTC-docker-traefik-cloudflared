#requires -version 5.1
<#
.SYNOPSIS
  Generates or merges the configuration of a Homepage installed from the App Catalog: cards for the installed apps,
  the Traefik dashboard, the Deployment Manager, the Cloudflare Tunnel and services published through Traefik.

  Without -Apply it only shows what would change. Generated text sits between marker comments; everything else in the
  files is kept, and cards whose names already exist outside the markers are not added again. Homepage reloads its
  files by itself: the container is not restarted. Public addresses are listed only when the Cloudflare edge answers
  and Traefik routes the hostname to a working backend. No secrets or API keys are written.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Update-HomepageConfig.ps1 -ProjectPath $env:USERPROFILE\.docker\projects\traefik-proxy
  powershell -ExecutionPolicy Bypass -File .\scripts\Update-HomepageConfig.ps1 -ProjectPath ... -Apply
#>
[CmdletBinding()]
param(
  [string]$ProjectPath,
  [string]$HomepageFolder,
  [string]$ManagerUrl = 'http://127.0.0.1:8190/',
  [string[]]$NotInstalled = @('jellyfin', 'channels-dvr'),
  [switch]$SkipPublicCheck,
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $ProjectPath) { $ProjectPath = $toolRoot }
$ProjectPath = [IO.Path]::GetFullPath($ProjectPath)
Import-Module (Join-Path $toolRoot 'lib\TraefikProxy.psm1'), (Join-Path $toolRoot 'lib\AppCatalog.psm1'), (Join-Path $toolRoot 'lib\ComposeLifecycle.psm1'), (Join-Path $toolRoot 'lib\HomepageConfig.psm1') -Force
$s = Get-StackSettings -InstallPath $ProjectPath
# Archived records are hidden; two installations of the same app get their label or project in the card name.
$apps = @(Read-AppsRegistry $s | Where-Object { -not ($_.PSObject.Properties['archived'] -and $_.archived) } | ForEach-Object { $_.PSObject.Copy() })
foreach ($a in $apps) {
  if (@($apps | Where-Object { $_.name -eq $a.name }).Count -gt 1) { $a.name = "$($a.name) ($(if ($a.PSObject.Properties['label'] -and $a.label) { $a.label } else { $a.project }))" }
}
if (-not $HomepageFolder) {
  $hp = @($apps | Where-Object { $_.appId -eq 'homepage' })
  if (-not $hp.Count) { throw "Homepage is not installed by this manager ($ProjectPath\config\apps.json). Pass -HomepageFolder." }
  $HomepageFolder = [string]$hp[0].folder
}
$cfg = Join-Path $HomepageFolder 'config'
if (-not (Test-Path -LiteralPath (Join-Path $cfg 'services.yaml'))) { throw "No Homepage configuration in $cfg." }

$manifests = @{}
foreach ($c in @(Get-CatalogApps -CatalogDir (Join-Path $toolRoot 'catalog') | Where-Object { -not @($_.errors).Count })) {
  $manifests[$c.id] = $c.manifest
  foreach ($al in @(if ($c.manifest.PSObject.Properties['aliases']) { $c.manifest.aliases })) { $manifests[[string]$al] = $c.manifest }
}
# States of the manager's projects: running / total long-running services. One-time setup jobs that completed (e.g.
# Rocket.Chat's MongoDB initialization) are not counted as stopped containers.
$states = @{}
$ids = @((Invoke-Docker ps -a -q --filter 'label=com.docker.compose.project').Output | Where-Object { "$_" -match '^[0-9a-f]{12,64}$' })
$facts = @()
if ($ids.Count) { $r = Invoke-Docker inspect $ids; if ($r.ExitCode -eq 0) { $facts = @(foreach ($x in ((@($r.Output) -join "`n") | ConvertFrom-Json)) { ConvertFrom-ContainerInspect $x }) } }
foreach ($a in $apps) {
  $cs = @($facts | Where-Object { $_.project -eq $a.project })
  if (-not $cs.Count) { continue }
  $lc = Get-DeploymentLifecycle -Containers $cs -Manifest $manifests[[string]$a.appId]
  $states[[string]$a.project] = @{ running = $lc.counts.running; total = $lc.counts.longRunning }
}

# The instance's Traefik container: the one of this stack's Compose project running the traefik service.
$traefik = @(docker ps --filter "label=com.docker.compose.project=$($s.StackName)" --filter 'label=com.docker.compose.service=traefik' --format '{{.Names}}' | Where-Object { $_ })
$infra = @{ managerUrl = $ManagerUrl; tunnelName = "$($s.StackName) tunnel"; dashboardUrl = "http://127.0.0.1:$($s.DashboardPort)/dashboard/" }
if ($traefik.Count) { $infra.traefikContainer = $traefik[0] }

# Published hostnames, verified at the Cloudflare edge (an answer or the Access login) and at the origin (Traefik on
# 127.0.0.1 routes the hostname to a backend that answers below 400, or asks for a login).
function Test-Public([string]$Name, [string]$Path = '/', [hashtable]$Headers = @{}) {
  if ($SkipPublicCheck) { return $false }
  $edge = (& curl.exe -s -o NUL -m 15 -w '%{http_code} %{redirect_url}' "https://$Name/") -join ''
  $edge = $edge -replace '\?.*$', ''
  $edgeOk = $edge -match '^(2\d\d|30[1278]) ' -and ($edge -notmatch '^3' -or $edge -match "cloudflareaccess\.com|https://$([regex]::Escape($Name))")
  $hArgs = @('-H', "Host: $Name"); foreach ($k in $Headers.Keys) { $hArgs += @('-H', "${k}: $($Headers[$k])") }
  $origin = (& curl.exe -s -o NUL -m 15 -w '%{http_code}' @hArgs "http://127.0.0.1:$($s.HttpPort)$Path") -join ''
  $originOk = $origin -match '^(2\d\d|3\d\d|401)$'
  Write-Verbose "public $Name edge=$edge origin=$origin"
  return [pscustomobject]@{ ok = ($edgeOk -and $originOk); edge = $edge; origin = $origin }
}
$published = @()
$publicByName = @{}
$checks = @()
$svcFile = Join-Path $ProjectPath 'config\services.json'
if (Test-Path -LiteralPath $svcFile) {
  foreach ($p in @(([IO.File]::ReadAllText($svcFile) | ConvertFrom-Json).services)) {
    $v = @{}
    foreach ($h in @($p.hostnames)) {
      $r = Test-Public $h
      $v[$h] = [bool]($r -and $r.ok)
      $checks += "$h edge=$(if ($r) { $r.edge } else { 'skipped' }) origin=$(if ($r) { $r.origin } else { 'skipped' }) -> $(if ($v[$h]) { 'verified' } else { 'not listed' })"
    }
    $p | Add-Member -NotePropertyName verified -NotePropertyValue $v -Force
    $published += $p
    $label = [string]$(if ($p.PSObject.Properties['displayName'] -and $p.displayName) { $p.displayName } else { $p.name })
    if ($label -cmatch '^[a-z]') { $label = $label.Substring(0, 1).ToUpper() + $label.Substring(1) }
    $ok = @($v.Keys | Where-Object { $v[$_] })
    if ($ok.Count) { $publicByName[$label] = $ok }
  }
}
# The public Traefik dashboard (only routed with the Cloudflare Access token header, which the local check imitates).
$dashCfg = Join-Path $ProjectPath 'config\dashboard.json'
if (Test-Path -LiteralPath $dashCfg) {
  $d = [IO.File]::ReadAllText($dashCfg) | ConvertFrom-Json
  $dh = [string]$(if ($d.PSObject.Properties['hostname']) { $d.hostname } else { '' })
  if ($dh -and (-not $d.PSObject.Properties['enabled'] -or $d.enabled)) {
    $r = Test-Public $dh '/dashboard/' @{ 'Cf-Access-Jwt-Assertion' = 'local-check' }
    $checks += "$dh edge=$(if ($r) { $r.edge } else { 'skipped' }) origin=$(if ($r) { $r.origin } else { 'skipped' }) -> $(if ($r -and $r.ok) { 'verified' } else { 'not listed' })"
    if ($r -and $r.ok) { $publicByName['Traefik Dashboard'] = @($dh) }
  }
}

$cards = New-HomepageCards -Apps $apps -States $states -Manifests $manifests -Published $published -Infra $infra -NotInstalled $NotInstalled
$read = { param($n) $f = Join-Path $cfg $n; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { '' } }
$svc = Merge-HomepageServices (& $read 'services.yaml') $cards
$new = [ordered]@{
  'services.yaml'  = $svc.text
  'bookmarks.yaml' = (Merge-HomepageBookmarks (& $read 'bookmarks.yaml') $cards $publicByName).text
  'widgets.yaml'   = (Merge-HomepageWidgets (& $read 'widgets.yaml')).text
  'settings.yaml'  = (Merge-HomepageSettings (& $read 'settings.yaml') $cards).text
}

"Homepage configuration: $cfg"
'Public hostnames:'; $checks | ForEach-Object { "  $_" }
'Cards:'; $cards | ForEach-Object { '  {0,-15} {1,-22} {2}{3}' -f $_.group, $_.name, $(if ($_.Contains('siteMonitor')) { 'monitored ' } else { 'no status ' }), $_.description }
if ($svc.skipped.Count) { "Already in your own configuration (not added again): $($svc.skipped -join ', ')" }
if ($svc.adopted) { 'The services.yaml generated at installation is replaced by the generated block (a copy is kept).' }
$changed = @()
foreach ($n in $new.Keys) {
  $old = (& $read $n) -replace "`r`n", "`n"
  if ($old -eq $new[$n]) { continue }
  $changed += $n
  "--- $n"
  $diff = Compare-Object @($old -split "`n") @($new[$n] -split "`n")
  $diff | ForEach-Object { "  $(if ($_.SideIndicator -eq '=>') { '+' } else { '-' }) $($_.InputObject)" }
}
if (-not $changed.Count) { 'No changes.'; return }
if (-not $Apply) { "Preview only. Run again with -Apply to write $($changed -join ', ')."; return }
$backup = Join-Path $HomepageFolder ("backups\homepage-config-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($n in $changed) {
  $f = Join-Path $cfg $n
  if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $backup $n) }
  [IO.File]::WriteAllText($f, $new[$n], $utf8)
}
"Written: $($changed -join ', '). Previous files: $backup"
