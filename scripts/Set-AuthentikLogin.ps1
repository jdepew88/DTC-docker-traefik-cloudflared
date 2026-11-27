#requires -version 5.1
<#
.SYNOPSIS
  The DTC sign-in experience for authentik: Glassmorphism theme, "Continue as <owner>" Google button and the picture
  shortcut. Shows the state, previews it on http://localhost:9000 only, applies it to the public sign-in page, or
  restores the previous sign-in page from a backup.

.DESCRIPTION
  -Action Status   (default) read-only: what the brands use, whether the template is installed, and a live check of
                   the Google request authentik would send (login_hint, scopes, state, prompt). Nothing is sent to Google.
  -Action Preview  creates or updates the objects (flow dm-login, stage, hint policy, picture) and a SEPARATE brand for
                   http://localhost:9000. The public sign-in page is not changed.
  -Action Apply    the same for the default brand: the public sign-in page (auth.<domain>) uses it.
  -Action Restore  -BackupDir <folder>: puts the brand(s) back as recorded in that backup.

  Every Preview/Apply first writes a backup folder <deployment>\backups\login-experience\<time>-<action>\ with the
  previous brand settings (including its custom CSS) and the exact rollback command (ROLLBACK.md).

  authentik caches its templates: when the template files are new or changed the server container must be restarted
  once (-RestartServer; it takes about a minute, during which sign-ins and protected applications wait).

  Your settings (owner address, button text, picture points, timeout) are in <deployment>\config\login-experience.json,
  created from assets\authentik-login\login-experience.default.json on first use. Run -Action Apply (or Preview)
  again after editing it.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Set-AuthentikLogin.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\Set-AuthentikLogin.ps1 -Action Preview -RestartServer
  powershell -ExecutionPolicy Bypass -File .\scripts\Set-AuthentikLogin.ps1 -Action Apply
  powershell -ExecutionPolicy Bypass -File .\scripts\Set-AuthentikLogin.ps1 -Action Restore -BackupDir <folder>
#>
[CmdletBinding()]
param(
  [ValidateSet('Status', 'Preview', 'Apply', 'Restore')][string]$Action = 'Status',
  [string]$InstallPath,
  [string]$BackupDir,
  [switch]$RestartServer,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $InstallPath) { $InstallPath = $toolRoot }
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
foreach ($m in 'SecretStore', 'IdentityProvider', 'Authentik', 'AuthentikLogin') { Import-Module (Join-Path $toolRoot "lib\$m.psm1") -Force -DisableNameChecking }

$idPath = Join-Path $InstallPath 'config\identity.json'
if (-not (Test-Path -LiteralPath $idPath)) { throw "No Identity & Access settings at $idPath. Pass -InstallPath <deployment folder> (for example C:\Users\<you>\.docker\projects\traefik-proxy)." }
$id = [IO.File]::ReadAllText($idPath) | ConvertFrom-Json
$ak = $id.authentik
if ([string]$id.provider -ne 'authentik' -or -not $ak) { throw 'Identity & Access does not use authentik in this deployment.' }
$base = [string]$ak.localUrl
$publicHost = ([Uri][string]$ak.publicUrl).Host
$owner = [string]$ak.owner.email
$settings = [pscustomobject]@{ InstallPath = $InstallPath }
$token = Read-ProtectedSecret -Settings $settings -Name (Get-IdentityTokenSecretName)
if (-not $token) { throw 'The authentik API token of this deployment is not stored (Identity & Access).' }
$conn = New-AuthentikConnection -BaseUrl $base -Token $token
$token = $null

function Write-Actions($Actions) {
  foreach ($a in $Actions) { Write-Host ("  [{0,-7}] {1,-14} {2}" -f $a.Status, $a.Object, $a.Summary) -ForegroundColor $(if ($a.Status -eq 'OK') { 'DarkGray' } elseif ($a.Status -eq 'Planned') { 'Yellow' } else { 'Green' }) }
}
function Show-Check([string]$HostHeader, [string]$Scheme, [string]$Label) {
  $c = Test-AuthentikLoginHint -BaseUrl $base -HostHeader $HostHeader -Scheme $Scheme
  Write-Host "`n$Label ($Scheme`://$HostHeader/if/flow/dm-login/):"
  Write-Host "  page HTTP $($c.page); DTC script on page: $($c.scriptOnPage); form prefill: '$($c.prefill)'"
  Write-Host "  Google request: HTTP $($c.googleStatus); login_hint=$($c.loginHint); scope=$($c.scopes -join ' '); state present: $($c.state); prompt: $(if ($null -eq $c.prompt) { '(none)' } else { $c.prompt })"
  Write-Host "  redirect_uri=$($c.redirectUri)"
  Write-Host "  $($c.message)" -ForegroundColor $(if ($c.ok) { 'Green' } else { 'Red' })
  return $c
}
function Wait-AuthentikReady([int]$Seconds = 180) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do { $h = Get-AuthentikHealth -BaseUrl $base; if ($h.Live -and $h.Ready) { return $true }; Start-Sleep -Seconds 3 } while ((Get-Date) -lt $deadline)
  return $false
}

$flowSlug = Get-AuthentikLoginFlowSlug
$brands = @(Get-AuthentikList $conn '/core/brands/')
$flowPk = ''; try { $flowPk = [string](Invoke-AuthentikApi $conn GET "/flows/instances/$flowSlug/").pk } catch { }

if ($Action -eq 'Status') {
  Write-Host "Deployment: $InstallPath  authentik: $base (public $publicHost)  owner: $owner"
  foreach ($b in $brands) {
    $uses = $(if ($flowPk -and [string]$b.flow_authentication -eq $flowPk) { "DTC sign-in experience ($flowSlug)" } else { "flow $($b.flow_authentication)" })
    Write-Host ("  brand {0,-22} default={1,-5} css={2,6} chars  {3}" -f $b.domain, $b.default, ([string]$b.branding_custom_css).Length, $uses)
  }
  $tpl = Join-Path ([string]$ak.folder) 'custom-templates\if\flow.html'
  Write-Host "  template override: $(if (Test-Path -LiteralPath $tpl) { $tpl } else { 'not installed' })"
  Write-Host "  your settings: $(Join-Path $InstallPath 'config\login-experience.json')$(if (-not (Test-Path -LiteralPath (Join-Path $InstallPath 'config\login-experience.json'))) { ' (not created yet: defaults apply)' })"
  if ($flowPk) {
    if (@($brands | Where-Object { [string]$_.domain -eq 'localhost:9000' }).Count) { $null = Show-Check 'localhost:9000' 'http' 'Local preview' }
    $null = Show-Check $publicHost 'https' 'Public sign-in page'
  }
  return
}

if ($Action -eq 'Restore') {
  if (-not $BackupDir -or -not (Test-Path -LiteralPath (Join-Path $BackupDir 'previous.json'))) { throw 'Pass -BackupDir <folder> of a backup made by -Action Preview or Apply (it contains previous.json).' }
  $prev = [IO.File]::ReadAllText((Join-Path $BackupDir 'previous.json')) | ConvertFrom-Json
  if ($WhatIf) { Write-Host "Would restore brand $($prev.brand) ($($prev.target)) from $BackupDir"; return }
  Write-Host (Restore-AuthentikLoginExperience -Conn $conn -Previous $prev) -ForegroundColor Green
  return
}

# Preview / Apply
$target = $(if ($Action -eq 'Apply') { 'default' } else { 'preview' })
$cfgFile = $(if ($WhatIf) { Join-Path $InstallPath 'config\login-experience.json' } else { Initialize-AuthentikLoginConfigFile -InstallPath $InstallPath -OwnerEmail $owner })
$cfg = Get-AuthentikLoginConfig -InstallPath $InstallPath -OwnerEmail $owner
$problems = Test-AuthentikLoginConfig $cfg
if ($problems.Count) { throw "Fix $cfgFile first: $($problems -join ' ')" }

# Backup of what is about to change (brands with their CSS, the objects of this feature, the template files).
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bdir = Join-Path $InstallPath "backups\login-experience\$stamp-$($Action.ToLowerInvariant())"
if (-not $WhatIf) {
  New-Item -ItemType Directory -Force -Path $bdir | Out-Null
  $snap = [ordered]@{ takenAt = (Get-Date -Format 's'); authentik = (Invoke-AuthentikApi $conn GET '/admin/version/').version_current; brands = $brands
    flows = @(Get-AuthentikList $conn '/flows/instances/' | Select-Object pk, slug, name, title, designation)
    identificationStages = @(Get-AuthentikList $conn '/stages/identification/' | Select-Object pk, name, sources, show_matched_user, user_fields, password_stage) }
  [IO.File]::WriteAllText((Join-Path $bdir 'snapshot.json'), (ConvertTo-Json -InputObject $snap -Depth 10), (New-Object Text.UTF8Encoding($false)))
  $def = Get-AuthentikDefaultBrand $conn
  [IO.File]::WriteAllText((Join-Path $bdir 'default-brand-custom.css'), [string]$def.branding_custom_css, (New-Object Text.UTF8Encoding($false)))
  $tplRoot = Join-Path ([string]$ak.folder) 'custom-templates'
  foreach ($rel in 'if\flow.html', 'dtc\login-experience.js') { $p = Join-Path $tplRoot $rel; if (Test-Path -LiteralPath $p) { $d = Join-Path $bdir "custom-templates\$rel"; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $d) | Out-Null; Copy-Item -LiteralPath $p -Destination $d } }
  Write-Host "Backup: $bdir"
}

# Template files (inert until a brand opts in).
$tpl = Install-AuthentikLoginTemplates -AuthentikFolder ([string]$ak.folder) -WhatIf:$WhatIf
foreach ($f in $tpl.Files) { Write-Host "  template $($f.Status): $($f.Path)" }
if ($tpl.Changed) {
  if ($RestartServer -and -not $WhatIf) {
    $container = [string]$ak.serverContainer
    Write-Host "authentik caches templates: restarting $container ..." -ForegroundColor Yellow
    & docker restart $container | Out-Null
    if (-not (Wait-AuthentikReady)) { throw "$container did not become ready within 3 minutes. Check 'docker logs $container'." }
    Write-Host "  $container is ready."
  } else { Write-Host "  The template files changed: authentik uses them after a restart of its server container (run again with -RestartServer)." -ForegroundColor Yellow }
}

$r = Sync-AuthentikLoginExperience -Conn $conn -Config $cfg -Target $target -WhatIf:$WhatIf
Write-Actions $r.Actions
if ($WhatIf) { return }
[IO.File]::WriteAllText((Join-Path $bdir 'previous.json'), (ConvertTo-Json -InputObject $r.Previous -Depth 10), (New-Object Text.UTF8Encoding($false)))
$here = $MyInvocation.MyCommand.Path
$rollback = @(
  "# Roll back the DTC sign-in experience ($Action, $stamp)",
  '',
  "Brand: $($r.Previous.target) ($($r.Previous.brand)). Previous custom CSS: default-brand-custom.css (default brand). Full snapshot: snapshot.json.",
  '',
  '```',
  "powershell -ExecutionPolicy Bypass -File `"$here`" -InstallPath `"$InstallPath`" -Action Restore -BackupDir `"$bdir`"",
  '```',
  '',
  'This points the brand back to its previous sign-in flow, CSS, background and attributes (a preview brand is deleted).',
  "The template override in $([string]$ak.folder)\custom-templates is inert without the brand setting; to remove it too, delete",
  'custom-templates\if\flow.html and custom-templates\dtc\ and restart the authentik server container.'
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $bdir 'ROLLBACK.md'), $rollback, (New-Object Text.UTF8Encoding($false)))
Write-Host "Rollback: $(Join-Path $bdir 'ROLLBACK.md')"

$check = $(if ($target -eq 'preview') { Show-Check 'localhost:9000' 'http' 'Local preview' } else { Show-Check $publicHost 'https' 'Public sign-in page' })
if (-not $check.ok) { exit 2 }
