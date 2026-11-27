#requires -version 5.1
<#
.SYNOPSIS
  Homepage configuration tests: cards from installed, prepared, stopped and not-installed apps and from published
  services; merging that keeps the user's text and never duplicates a card; the generated file of the first
  installation taken over; preview vs. -Apply of scripts\Update-HomepageConfig.ps1 on a throwaway folder.

.DESCRIPTION
  Unit tests plus one run of the script against temporary folders. No container is created, started or changed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-HomepageConfig.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\AppCatalog.psm1') -Force
Import-Module (Join-Path $repo 'lib\HomepageConfig.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Find-Card($Cards, [string]$Name) { return @($Cards | Where-Object { $_.name -eq $Name })[0] }

$catalogDir = Join-Path $repo 'catalog'
$manifests = @{}
foreach ($c in @(Get-CatalogApps -CatalogDir $catalogDir | Where-Object { -not @($_.errors).Count })) { $manifests[$c.id] = $c.manifest }

# --- Cards ---------------------------------------------------------------------------------------------------------------
$apps = @(
  [pscustomobject]@{ project = 'traefik-manager'; appId = 'traefik-manager'; name = 'Traefik Manager'; localUrl = 'http://127.0.0.1:5000/' },
  [pscustomobject]@{ project = 'portainer'; appId = 'portainer'; name = 'Portainer CE'; localUrl = 'https://127.0.0.1:9443/' },
  [pscustomobject]@{ project = 'homepage'; appId = 'homepage'; name = 'Homepage'; localUrl = 'http://127.0.0.1:3010/' },
  [pscustomobject]@{ project = 'immich'; appId = 'immich'; name = 'Immich'; localUrl = 'http://127.0.0.1:2283/'; prepared = $true },
  [pscustomobject]@{ project = 'kuma'; appId = 'uptime-kuma'; name = 'Uptime Kuma'; localUrl = 'http://127.0.0.1:3001/' },
  [pscustomobject]@{ project = 'lldap'; appId = 'lldap'; name = 'LLDAP (directory)'; localUrl = 'http://127.0.0.1:17170/' },
  [pscustomobject]@{ project = 'rc'; appId = 'rocket-chat'; name = 'Rocket.Chat'; localUrl = 'http://127.0.0.1:3100/' }
)
$states = @{ 'traefik-manager' = @{ running = 1; total = 1 }; portainer = @{ running = 1; total = 1 }; homepage = @{ running = 1; total = 1 }; kuma = @{ running = 0; total = 1 }
  lldap = @{ running = 1; total = 1 }; rc = @{ running = 3; total = 4 } }
$published = @(
  [pscustomobject]@{ name = 'mediabox'; enabled = $true; hostnames = @('mediabox.example.com'); target = [pscustomobject]@{ type = 'lan'; host = '10.20.30.11'; port = 4119; protocol = 'http' }; verified = @{ 'mediabox.example.com' = $false } },
  [pscustomobject]@{ name = 'homepage'; enabled = $true; hostnames = @('home.example.com'); target = [pscustomobject]@{ type = 'docker'; host = 'homepage'; port = 3000; protocol = 'http' }; verified = @{ 'home.example.com' = $true } }
)
$infra = @{ traefikContainer = 'x-traefik'; dashboardUrl = 'http://127.0.0.1:8181/dashboard/'; managerUrl = 'http://127.0.0.1:8190/'; tunnelName = 'x tunnel' }
$cards = New-HomepageCards -Apps $apps -States $states -Manifests $manifests -Published $published -Infra $infra -NotInstalled @('jellyfin', 'channels-dvr', 'immich')

$tm = Find-Card $cards 'Traefik Manager'; $po = Find-Card $cards 'Portainer CE'; $im = Find-Card $cards 'Immich'; $ku = Find-Card $cards 'Uptime Kuma'
$ld = Find-Card $cards 'LLDAP (directory)'; $rc = Find-Card $cards 'Rocket.Chat'; $jf = Find-Card $cards 'Jellyfin'; $nf = Find-Card $cards 'Mediabox'
Test-Condition 'cards: a running app links to its local URL and is checked on the shared network (declared status port)' ($tm.href -eq 'http://127.0.0.1:5000/' -and $tm.siteMonitor -eq 'http://traefik-manager:5000' -and $po.siteMonitor -eq 'http://portainer:9000' -and $tm.group -eq 'Infrastructure') ($tm | ConvertTo-Json -Compress)
Test-Condition 'cards: a prepared app has no link and no status check (never shown as up)' (-not $im.Contains('href') -and -not $im.Contains('siteMonitor') -and $im.description -match 'Prepared') ($im | ConvertTo-Json -Compress)
Test-Condition 'cards: a stopped app is marked stopped, without link or status check' ($ku.description -eq 'Stopped' -and -not $ku.Contains('siteMonitor') -and -not $ku.Contains('href')) ($ku | ConvertTo-Json -Compress)
Test-Condition 'cards: an app kept off the shared network (LLDAP) gets no status check' (-not $ld.Contains('siteMonitor') -and $ld.description -match 'local only') ($ld | ConvertTo-Json -Compress)
Test-Condition 'cards: a partly running multi-service app says so and checks its web container' ($rc.description -match 'Partly running \(3 of 4\)' -and $rc.siteMonitor -eq 'http://rc-rocketchat:3000') ($rc | ConvertTo-Json -Compress)
Test-Condition 'cards: not-installed apps are listed without link; an installed one is not listed twice; Homepage has no card of its own' (-not $jf.Contains('href') -and $jf.description -match 'Not installed' -and @($cards | Where-Object { $_.name -eq 'Immich' }).Count -eq 1 -and -not (Find-Card $cards 'Homepage') -and -not (Find-Card $cards 'Arcane')) ''
Test-Condition 'cards: Traefik dashboard (status + read-only widget), Deployment Manager and tunnel (no unverifiable status)' ((Find-Card $cards 'Traefik Dashboard').widget.type -eq 'traefik' -and (Find-Card $cards 'Traefik Dashboard').siteMonitor -eq 'http://x-traefik:8080/ping' -and -not (Find-Card $cards 'Cloudflare Tunnel').Contains('siteMonitor') -and -not (Find-Card $cards 'Deployment Manager').Contains('siteMonitor')) ''
Test-Condition 'cards: a published LAN service gets its LAN link and check; a published installed app is not added twice' ($nf.href -eq 'http://10.20.30.11:4119/' -and $nf.siteMonitor -eq 'http://10.20.30.11:4119' -and $nf.group -eq 'Media' -and @($nf.publicHosts).Count -eq 0 -and @($cards | Where-Object { $_.name -eq 'Homepage' }).Count -eq 0) ($nf | ConvertTo-Json -Compress)

# --- Merging -------------------------------------------------------------------------------------------------------------
$legacy = "# Apps installed by the Deployment Manager when Homepage was installed. Edit freely; it is never overwritten.`n# Status checks (siteMonitor) use the shared Docker network; no Docker socket is used.`n- Apps:`n    - `"Traefik Manager`":`n        href: http://127.0.0.1:5000/`n        siteMonitor: http://traefik-manager:5000`n    - `"Portainer CE`":`n        href: https://127.0.0.1:9443/`n"
$m1 = Merge-HomepageServices $legacy $cards
Test-Condition 'merge: the services.yaml of the first installation is taken over (no duplicate cards)' ($m1.adopted -and ([regex]::Matches($m1.text, '"Traefik Manager":')).Count -eq 1 -and $m1.text -notmatch '- Apps:') $m1.text
$m2 = Merge-HomepageServices $m1.text $cards
Test-Condition 'merge: merging again changes nothing' ($m2.text -eq $m1.text) ''
$custom = "# my dashboard`n- Mine:`n    - `"Portainer CE`":`n        href: https://portainer.lan/`n    - `"NAS`":`n        href: http://nas.lan/`n"
$m3 = Merge-HomepageServices $custom $cards
Test-Condition 'merge: the user''s text is kept byte for byte and their card names are not generated again' ($m3.text.StartsWith($custom) -and ([regex]::Matches($m3.text, '"Portainer CE":')).Count -eq 1 -and @($m3.skipped) -contains 'Portainer CE' -and -not $m3.adopted) $m3.text
$edited = $m1.text + "- Later:`n    - `"Printer`":`n        href: http://printer.lan/`n"
$m4 = Merge-HomepageServices $edited $cards
Test-Condition 'merge: text added after the generated block is kept (moved above it); there is still one block' ($m4.text.Contains('"Printer":') -and ([regex]::Matches($m4.text, '# BEGIN Deployment Manager')).Count -eq 1 -and ([regex]::Matches($m4.text, '"Traefik Manager":')).Count -eq 1) $m4.text
$custom2 = "# hand-written, mentions the old header later`n- Apps:`n    - `"Traefik Manager`":`n        href: http://other/`n"
Test-Condition 'merge: a hand-written file is never taken over' (-not (Merge-HomepageServices $custom2 $cards).adopted) ''
Test-Condition 'merge: no secrets, tokens or API keys in the generated text' ($m1.text -notmatch '(?i)(password|token|secret|api[_-]?key|key)\s*:') $m1.text
$bm = Merge-HomepageBookmarks "[]`n" $cards @{ Homepage = @('home.example.com') }
Test-Condition 'bookmarks: only verified public addresses; the default [] is replaced' ($bm.text -match 'https://home\.example\.com/' -and $bm.text -notmatch 'mediabox' -and $bm.text -notmatch '(?m)^\[\]') $bm.text
$wg = Merge-HomepageWidgets "- greeting:`n    text: Home lab`n"
$wg2 = Merge-HomepageWidgets "- resources:`n    cpu: true`n"
Test-Condition 'widgets: a resources widget is added once, and not when the user has one' ($wg.text -match '- resources:' -and $wg.text.StartsWith('- greeting:') -and ([regex]::Matches($wg2.text, '- resources:')).Count -eq 1) "$($wg.text) | $($wg2.text)"
$st = Merge-HomepageSettings "title: Home`nlayout:`n  Mine:`n    style: row`n" $cards
Test-Condition 'settings: the user''s layout wins; compact status dots are added' (([regex]::Matches($st.text, '(?m)^layout:')).Count -eq 1 -and $st.text -match 'statusStyle: dot') $st.text

# --- The script on throwaway folders --------------------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tpm-hp-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
try {
  $inst = New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'inst\config')
  $hpDir = Join-Path $tmp 'hp'; New-Item -ItemType Directory -Force -Path (Join-Path $hpDir 'config') | Out-Null
  $reg = [ordered]@{ version = 1; apps = @([ordered]@{ project = 'tpm-hp-none'; appId = 'homepage'; name = 'Homepage'; folder = $hpDir; localUrl = 'http://127.0.0.1:3010/' },
      [ordered]@{ project = 'tpm-hp-immich'; appId = 'immich'; name = 'Immich'; folder = (Join-Path $tmp 'immich'); localUrl = 'http://127.0.0.1:2283/'; prepared = $true }) }
  [IO.File]::WriteAllText((Join-Path $tmp 'inst\config\apps.json'), ($reg | ConvertTo-Json -Depth 5))
  [IO.File]::WriteAllText((Join-Path $hpDir 'config\services.yaml'), $legacy)
  [IO.File]::WriteAllText((Join-Path $hpDir 'config\bookmarks.yaml'), "[]`n")
  $script = Join-Path $repo 'scripts\Update-HomepageConfig.ps1'
  $run = { param([string[]]$Extra) $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ProjectPath (Join-Path $tmp 'inst') -SkipPublicCheck @Extra 2>&1 | ForEach-Object { "$_" }) -join "`n" } finally { $ErrorActionPreference = $prev } }
  $before = [IO.File]::ReadAllText((Join-Path $hpDir 'config\services.yaml'))
  $pv = & $run @()
  Test-Condition 'script: without -Apply it previews and writes nothing' ($pv -match 'Preview only' -and [IO.File]::ReadAllText((Join-Path $hpDir 'config\services.yaml')) -eq $before -and -not (Test-Path (Join-Path $hpDir 'backups'))) $pv
  $ap = & $run @('-Apply')
  $after = [IO.File]::ReadAllText((Join-Path $hpDir 'config\services.yaml'))
  $bk = @(Get-ChildItem -Path (Join-Path $hpDir 'backups') -Recurse -Filter 'services.yaml' -ErrorAction SilentlyContinue)
  Test-Condition 'script: -Apply writes the merged files and keeps the previous ones in backups' ($ap -match 'Written:' -and $after -match '"Immich":' -and $after -match 'Prepared, not started' -and $bk.Count -eq 1 -and [IO.File]::ReadAllText($bk[0].FullName) -eq $before) $ap
  $again = & $run @('-Apply')
  Test-Condition 'script: a second run finds no changes' ($again -match 'No changes') $again
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
