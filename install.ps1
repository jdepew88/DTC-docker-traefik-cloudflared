#requires -version 5.1
<#
.SYNOPSIS
  Installs / updates the generic Traefik v3.7.15 + Cloudflare Tunnel reverse proxy on Docker Desktop (Windows).

.DESCRIPTION
  Safe to re-run. Never deletes containers, volumes or networks and never overwrites a file you edited:
  - New files are copied.
  - Files you have not modified since the last install are updated (old copy kept in backups\<timestamp>\).
  - Files you modified are left alone; the packaged version is written next to them as <file>.dist.
  The shared proxy network is created if missing and reused (never recreated) if it already exists.
  Secrets are prompted for (-SetTunnelToken) and stored in secrets\cloudflare_tunnel_token, never in .env.

  Instance settings (stack/container names, loopback ports, proxy network, tunnel subnet) live in .env in the
  install folder. Several instances can coexist if each has its own -InstallPath and .env values.

  Proxied applications are managed with services.ps1 (or the wizard below); see README.

.EXAMPLE
  .\install.ps1 -Wizard                      # guided setup: new Cloudflare tunnel + first app, with tests
  .\install.ps1 -AddApp                      # guided: publish another app on the existing tunnel
  .\install.ps1 -DryRun                      # show what would happen, change nothing
  .\install.ps1 -Start                       # install + start Traefik and the socket proxy
  .\install.ps1 -SetTunnelToken -Start -EnableTunnel   # rotate/replace the token without the wizard
  .\install.ps1 -Rollback                    # restore installer-managed files from the most recent backup
  .\install.ps1 -Stop                        # stop this stack only (no -v, keeps the proxy network)
  .\install.ps1 -Reload                      # apply hand edits in traefik\dynamic\ without a restart
  .\install.ps1 -InstallPath D:\proxy-test -EnvFile .\test.env -Start   # a second, independent instance
#>
[CmdletBinding()]
param(
  [string]$InstallPath = (Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy'),
  # .env to use when the install folder has none yet (default: the packaged .env.example).
  [string]$EnvFile,
  [switch]$DryRun,
  [switch]$Start,
  [switch]$EnableTunnel,
  [switch]$SetTunnelToken,
  [switch]$Rollback,
  [switch]$Stop,
  # Make Traefik re-read traefik\dynamic\ after you edited files there on Windows.
  [switch]$Reload,
  # Tunnel wizard. Answers not given as parameters are asked interactively.
  [switch]$Wizard,
  [switch]$AddApp,
  [string]$Domain,
  [string]$TunnelName,
  [string]$AppHostname,
  # container:<name>:<port> | windows:<port> | lan:<host>:<port> | existing
  [string]$AppTarget,
  [ValidateSet('http', 'https', 'h2c')][string]$AppProtocol = 'http',
  # Route the app in Traefik only; skip the Cloudflare Access / published route steps and the public test.
  [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $Source 'lib\TraefikProxy.psm1') -Force
if (($Wizard -or $AddApp) -and $DryRun) { throw '-Wizard / -AddApp are interactive and cannot be combined with -DryRun.' }
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$ManifestName = '.install-manifest.json'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Files managed by the installer (relative to the package root).
$ManagedFiles = @(
  'compose.yaml',
  'traefik\dynamic\security.yml',
  'traefik\dynamic\dashboard.yml',
  'config\services.example.json',
  'examples\compose-labels.example.yaml',
  'examples\manual-route.yml.example',
  'lib\TraefikProxy.psm1',
  'lib\CloudflareApi.psm1',
  'lib\Dashboard.psm1',
  'lib\ConfigBackup.psm1',
  'lib\LocalHttp.psm1',
  'services.ps1',
  'webui.ps1',
  'webui\index.html',
  'webui\app.js',
  'webui\ui.js',
  'webui\logic.js',
  'webui\setup.js',
  'webui\pages.js',
  'webui\projects.js',
  'webui\backend.js',
  'webui\brands.js',
  'webui\explorer.js',
  'lib\Infrastructure.psm1',
  'lib\DockerDiscovery.psm1',
  'lib\ServiceHealth.psm1',
  'lib\BackendResolver.psm1',
  'lib\AppCatalog.psm1',
  'lib\HomepageConfig.psm1',
  'webui\catalog.js',
  'catalog\apps\echo.json',
  'catalog\apps\uptime-kuma.json',
  'catalog\apps\jellyfin.json',
  'catalog\apps\portainer.json',
  'catalog\apps\arcane.json',
  'catalog\apps\authelia.json',
  'catalog\apps\authentik.json',
  'catalog\apps\channels-dvr.json',
  'catalog\apps\dispatcharr-modular.json',
  'catalog\apps\dispatcharr.json',
  'catalog\apps\diun.json',
  'catalog\apps\homepage.json',
  'catalog\apps\immich.json',
  'catalog\apps\lldap.json',
  'catalog\apps\openldap.json',
  'catalog\apps\postgresql.json',
  'catalog\apps\redis.json',
  'catalog\apps\rocket-chat.json',
  'catalog\apps\traefik-manager.json',
  'catalog\apps\watchtower.json',
  'catalog\apps\whats-up-docker.json',
  'tests\Test-Catalog.ps1',
  'webui\discover.js',
  'tests\Test-Discovery.ps1',
  'tests\Test-Routing.ps1', 'tests\Test-BackendResolver.ps1', 'tests\Test-WizardBrowser.ps1',
  'lib\ProjectDiscovery.psm1',
  'Start-DeploymentManager.ps1',
  'START-HERE.cmd',
  'STOP-MANAGER.cmd',
  'webui\learn.json',
  'webui\app.css',
  'webui\icon.svg',
  'tests\Test-Stack.ps1',
  'tests\Test-ServiceConfig.ps1',
  'tests\Test-WebUi.ps1',
  'tests\Test-FirstRun.ps1',
  'tests\Test-Onboarding.ps1',
  'tests\Test-Backup.ps1',
  'tests\Test-Dashboard.ps1',
  'tests\Test-UiBrowser.ps1',
  'tests\Test-Projects.ps1',
  'tests\Test-Explorer.ps1',
  'tests\EdgeCdp.psm1',
  'tests\WebUiTestHelpers.psm1',
  'tests\CloudflareMock.ps1',
  'scripts\Get-Diagnostics.ps1',
  'scripts\TunnelWizard.ps1',
  'scripts\Update-HomepageConfig.ps1',
  'scripts\Get-NetworkAudit.ps1',
  'install.ps1',
  '.env.example',
  '.gitignore',
  'README.md',
  'SECURITY.md'
)

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" }
function Write-Warn([string]$Message) { Write-Host "    WARNING: $Message" -ForegroundColor Yellow }

# Performs an action unless -DryRun was given.
function Invoke-Change([string]$Description, [scriptblock]$Action) {
  if ($DryRun) {
    Write-Note "[dry-run] $Description"
  } else {
    Write-Note $Description
    & $Action
  }
}

function Get-FullPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

# Compose label lookup. Uses {{json}} because Windows PowerShell 5.1 strips embedded double quotes
# from native-command arguments, which breaks templates like {{index .Labels "x"}}.
function Get-Label($LabelsJson, [string]$Name) {
  if (-not $LabelsJson -or $LabelsJson -eq 'null') { return '' }
  $obj = $LabelsJson | ConvertFrom-Json
  if ($obj.PSObject.Properties[$Name]) { return [string]$obj.$Name }
  return ''
}

function Read-Manifest([string]$Path) {
  $table = @{}
  if (Test-Path -LiteralPath $Path) {
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($property in $json.PSObject.Properties) { $table[$property.Name] = $property.Value }
  }
  return $table
}

# --- Settings -----------------------------------------------------------------------------------
$envPath = Join-Path $InstallPath '.env'
$settingsSource = $envPath
if (-not (Test-Path -LiteralPath $envPath)) {
  if ($EnvFile) { $settingsSource = (Resolve-Path -LiteralPath $EnvFile).Path } else { $settingsSource = Join-Path $Source '.env.example' }
}
$Settings = Get-StackSettings -InstallPath $InstallPath -EnvPath $settingsSource
$settingErrors = @(Test-StackSettings $Settings)
if ($settingErrors.Count -gt 0) { throw ("Invalid settings in ${settingsSource}:`n  " + ($settingErrors -join "`n  ")) }
$ProjectName = $Settings.StackName
$ProxyNetwork = $Settings.ProxyNetwork
$TunnelSubnet = $Settings.TunnelSubnet
$ports = @{ TRAEFIK_HTTP_PORT = $Settings.HttpPort; TRAEFIK_DASHBOARD_PORT = $Settings.DashboardPort }

# Wizard functions (Read-TunnelToken, Save-TunnelToken, Invoke-TunnelWizard, ...) use the helpers above.
. (Join-Path $Source 'scripts\TunnelWizard.ps1')

# ---------------------------------------------------------------------------------------------
Write-Step 'Checking Docker Desktop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker CLI not found. Install/start Docker Desktop and retry.' }
$info = Invoke-Docker info --format '{{.OSType}}|{{.ServerVersion}}|{{.DockerRootDir}}|{{.Name}}'
if ($info.ExitCode -ne 0) { throw ('Docker engine is not reachable: ' + ($info.Output -join ' ')) }
$infoParts = $info.Output[-1].Split('|')
if ($infoParts[0] -ne 'linux') { throw 'Docker Desktop must be running Linux containers (Switch to Linux containers).' }
Write-Note ("Engine {0} on {1}, root dir {2}" -f $infoParts[1], $infoParts[3], $infoParts[2])
$composeVersion = Invoke-Docker compose version --short
if ($composeVersion.ExitCode -ne 0) { throw 'Docker Compose v2 plugin is unavailable.' }
Write-Note ('Docker Compose ' + $composeVersion.Output[-1])
Write-Note ('Install path: ' + $InstallPath)
Write-Note ("Instance '{0}': ports 127.0.0.1:{1}/{2}, network '{3}', tunnel subnet {4} (settings: {5})" -f `
    $ProjectName, $Settings.HttpPort, $Settings.DashboardPort, $ProxyNetwork, $TunnelSubnet, $settingsSource)

$composeFile = Join-Path $InstallPath 'compose.yaml'

# --- Stop -------------------------------------------------------------------------------------
if ($Stop) {
  Write-Step "Stopping project '$ProjectName' (containers only; files, volumes and the '$ProxyNetwork' network are kept)"
  if (-not (Test-Path -LiteralPath $composeFile)) { throw "No compose.yaml at $InstallPath" }
  $downArgs = (Get-ComposeArgs -Settings $Settings -Profiles @('tunnel', 'test')) + @('down', '--remove-orphans')
  Invoke-Change 'docker compose --profile tunnel --profile test down --remove-orphans' {
    $r = Invoke-Docker @downArgs
    $r.Output | ForEach-Object { Write-Note $_ }
    if ($r.ExitCode -ne 0) { throw 'docker compose down failed.' }
  }
  return
}

# --- Reload -------------------------------------------------------------------------------------
if ($Reload) {
  Write-Step 'Reloading traefik\dynamic\ (no restart)'
  if (-not $DryRun) { $warning = Sync-TraefikDynamic $Settings; if ($warning) { Write-Warn $warning } }
  return
}

# --- Rollback ---------------------------------------------------------------------------------
if ($Rollback) {
  $backupRoot = Join-Path $InstallPath 'backups'
  $latest = $null
  if (Test-Path -LiteralPath $backupRoot) {
    # Installer backups only (yyyyMMdd-HHmmss). Service snapshots live in backups\services (services.ps1 rollback).
    $latest = Get-ChildItem -LiteralPath $backupRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
      Sort-Object Name -Descending | Select-Object -First 1
  }
  if ($null -eq $latest) { throw "No installer backups found in $backupRoot. Nothing to roll back. (Service changes: .\services.ps1 rollback)" }
  Write-Step ('Restoring files from ' + $latest.FullName)
  $safety = Join-Path $backupRoot ($Timestamp + '-pre-rollback')
  $manifestPath = Join-Path $InstallPath $ManifestName
  $manifest = Read-Manifest $manifestPath
  foreach ($file in Get-ChildItem -LiteralPath $latest.FullName -Recurse -File) {
    $relative = $file.FullName.Substring($latest.FullName.Length + 1)
    $target = Join-Path $InstallPath $relative
    Invoke-Change "restore $relative (current copy saved to $safety)" {
      if (Test-Path -LiteralPath $target) {
        $saveTo = Join-Path $safety $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saveTo) | Out-Null
        Copy-Item -LiteralPath $target -Destination $saveTo
      }
      Copy-Item -LiteralPath $file.FullName -Destination $target -Force
      # Record the restored version so a later install treats it as unmodified and can update it.
      if ($manifest.ContainsKey($relative)) { $manifest[$relative] = Get-FileSha256 $target }
    }
  }
  if (-not $DryRun) { $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding ASCII }
  Invoke-Change ("rename {0} -> {0}-restored so the next rollback goes one step further back" -f $latest.Name) {
    Rename-Item -LiteralPath $latest.FullName -NewName ($latest.Name + '-restored')
  }
  Write-Note "Apply with: docker compose --project-directory `"$InstallPath`" up -d"
  return
}

# --- Pre-flight checks --------------------------------------------------------------------------
Write-Step 'Inspecting existing containers'
$ps = Invoke-Docker ps --format '{{.Names}}  {{.Ports}}'
$ps.Output | ForEach-Object { Write-Note $_ }

$ownTraefikRunning = $false
foreach ($containerName in @($Settings.TraefikContainer, $Settings.SocketProxyContainer, $Settings.CloudflaredContainer)) {
  $existing = Invoke-Docker inspect $containerName --format '{{json .Config.Labels}}'
  if ($existing.ExitCode -ne 0) { continue }
  $owner = Get-Label $existing.Output[-1] 'com.docker.compose.project'
  $workingDir = Get-Label $existing.Output[-1] 'com.docker.compose.project.working_dir'
  if ($owner -ne $ProjectName) {
    throw "A container named '$containerName' already exists and belongs to project '$owner'. Choose another STACK_NAME in .env."
  }
  if ($workingDir -and ((Get-FullPath $workingDir) -ne (Get-FullPath $InstallPath))) {
    Write-Warn "Project '$ProjectName' is currently running from $workingDir. Stop it there before starting it from $InstallPath."
    if ($Start) { throw 'Refusing to start the same Compose project from two directories.' }
  }
  if ($containerName -eq $Settings.TraefikContainer) { $ownTraefikRunning = $true }
}

Write-Step 'Checking loopback ports'
foreach ($key in $ports.Keys) {
  $port = $ports[$key]
  $user = Get-PortUser $port
  if ($user) {
    $ours = $false
    if ($ownTraefikRunning) {
      $published = Invoke-Docker port $Settings.TraefikContainer
      $ours = [bool]($published.Output | Where-Object { $_ -match (":$port" + '$') })
    }
    if ($ours) { Write-Note "$key $port is published by this stack's traefik container (ok)" }
    else { throw "$key $port is already in use on this PC (by $user). Set $key to a free port in $InstallPath\.env and re-run." }
  } else {
    Write-Note "$key $port is free"
  }
}

Write-Step "Checking shared '$ProxyNetwork' network"
$net = Invoke-Docker network inspect $ProxyNetwork --format '{{.Driver}}|{{.Scope}}|{{len .Containers}}|{{json .Labels}}'
if ($net.ExitCode -eq 0) {
  $netParts = $net.Output[-1].Split('|', 4)
  $netOwner = Get-Label $netParts[3] 'com.docker.compose.project'
  if ($netParts[0] -ne 'bridge' -or $netParts[1] -ne 'local') { throw "Existing '$ProxyNetwork' network is $($netParts[0])/$($netParts[1]); a local bridge network is required. Not modifying it." }
  if ($netOwner) { Write-Warn "'$ProxyNetwork' is owned by Compose project '$netOwner'. It is used here as an external network; do not 'down' that project while apps depend on it." }
  Write-Note ("Reusing existing '{0}' network ({1} attached containers)" -f $ProxyNetwork, $netParts[2])
} else {
  Invoke-Change "docker network create $ProxyNetwork" {
    $r = Invoke-Docker network create --driver bridge --label com.traefik-proxy.purpose=shared-proxy $ProxyNetwork
    if ($r.ExitCode -ne 0) { throw ('network create failed: ' + ($r.Output -join ' ')) }
  }
}

Write-Step "Checking tunnel subnet $TunnelSubnet for conflicts"
$netIds = (Invoke-Docker network ls -q).Output
foreach ($id in $netIds) {
  $n = Invoke-Docker network inspect $id --format '{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}'
  $nParts = $n.Output[-1].Split('|')
  if ($nParts[0] -eq $Settings.TunnelNetwork) { continue }
  foreach ($subnet in ($nParts[1].Trim() -split '\s+')) {
    if ($subnet -match '^\d+\.\d+\.\d+\.\d+/\d+$' -and (Test-CidrOverlap $subnet $TunnelSubnet)) {
      throw "Network '$($nParts[0])' ($subnet) overlaps $TunnelSubnet. Set TUNNEL_SUBNET, TUNNEL_IP_RANGE and CLOUDFLARED_IP in .env to a free range."
    }
  }
}
Write-Note 'No overlap'

# --- Files --------------------------------------------------------------------------------------
Write-Step 'Staging files'
$manifestPath = Join-Path $InstallPath $ManifestName
$manifest = Read-Manifest $manifestPath
$backupDir = Join-Path (Join-Path $InstallPath 'backups') $Timestamp
$sameDir = (Get-FullPath $Source) -eq (Get-FullPath $InstallPath)
if ($sameDir) { Write-Note 'Running from the install directory: files are already in place.' }
foreach ($relative in $ManagedFiles) {
  if ($sameDir) { break }
  $from = Join-Path $Source $relative
  $to = Join-Path $InstallPath $relative
  if (-not (Test-Path -LiteralPath $from)) { Write-Warn "package file missing: $relative"; continue }
  $newHash = Get-FileSha256 $from
  if (-not (Test-Path -LiteralPath $to)) {
    Invoke-Change "add     $relative" {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
      Copy-Item -LiteralPath $from -Destination $to
    }
  } else {
    $currentHash = Get-FileSha256 $to
    if ($currentHash -eq $newHash) {
      Write-Note "same    $relative"
    } elseif ($manifest.ContainsKey($relative) -and $manifest[$relative] -eq $currentHash) {
      Invoke-Change "update  $relative (previous copy -> backups\$Timestamp)" {
        $saveTo = Join-Path $backupDir $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saveTo) | Out-Null
        Copy-Item -LiteralPath $to -Destination $saveTo
        Copy-Item -LiteralPath $from -Destination $to -Force
      }
    } else {
      Invoke-Change "keep    $relative (locally modified; packaged version written to $relative.dist)" {
        Copy-Item -LiteralPath $from -Destination ($to + '.dist') -Force
      }
      continue
    }
  }
  $manifest[$relative] = $newHash
}
if (-not $DryRun -and -not $sameDir) {
  $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding ASCII
}

if (-not (Test-Path -LiteralPath $envPath)) {
  Invoke-Change "create  .env from $(Split-Path -Leaf $settingsSource)" { Copy-Item -LiteralPath $settingsSource -Destination $envPath }
}
foreach ($dir in @('secrets', 'config')) {
  $full = Join-Path $InstallPath $dir
  if (-not (Test-Path -LiteralPath $full)) { Invoke-Change "create  $dir\" { New-Item -ItemType Directory -Path $full | Out-Null } }
}

# --- Tunnel token -------------------------------------------------------------------------------
$tokenPath = Join-Path $InstallPath 'secrets\cloudflare_tunnel_token'
if ($SetTunnelToken) {
  Write-Step 'Cloudflare tunnel token'
  Write-Note 'Cloudflare Zero Trust > Networks > Tunnels > (tunnel) > Configure, Docker tab: copy the command.'
  Write-Note 'Pasting the whole "docker run ... --token <token>" command is fine; only the token is kept.'
  if ($DryRun) {
    Write-Note '[dry-run] would prompt for the token and write secrets\cloudflare_tunnel_token'
  } else {
    $entered = Read-TunnelToken
    $other = Find-ConnectorForTunnel -Settings $Settings -TunnelId $entered.TunnelId
    if ($other) { throw "Container '$other' already runs a connector for tunnel $($entered.TunnelId). Use a token for a separate tunnel." }
    Save-TunnelToken $entered.Token
    $state = Get-WizardState
    $state.tunnelId = $entered.TunnelId
    $state.configuredAt = (Get-Date -Format 's')
    Save-WizardState $state
    $entered = $null
    if (Test-ContainerRunning $Settings.CloudflaredContainer) {
      Write-Note 'cloudflared is running; recreating it with the new token.'
      Start-TunnelStack -Recreate
    }
  }
}

# --- Wizard -------------------------------------------------------------------------------------
if ($Wizard -or $AddApp) {
  Write-Step 'Starting Traefik and the socket proxy'
  $up = Invoke-Docker @((Get-ComposeArgs -Settings $Settings) + @('up', '-d', '--wait', '--wait-timeout', '120'))
  if ($up.ExitCode -ne 0) { $up.Output | ForEach-Object { Write-Note $_ }; throw 'docker compose up failed.' }
  $ok = Invoke-TunnelWizard -AddAppOnly:$AddApp -Domain $Domain -TunnelName $TunnelName -AppHostname $AppHostname -AppTarget $AppTarget -AppProtocol $AppProtocol -LocalOnly:$LocalOnly
  if (-not $ok) { exit 1 }
  return
}

# --- Validate & start ---------------------------------------------------------------------------
if ($DryRun) {
  Write-Step 'Dry run complete; nothing was changed.'
  return
}

Write-Step 'Validating Compose configuration'
$profiles = @()
if ($EnableTunnel) {
  if (-not (Test-Path -LiteralPath $tokenPath)) { throw 'secrets\cloudflare_tunnel_token is missing. Re-run with -SetTunnelToken.' }
  $profiles = @('tunnel')
}
$baseArgs = Get-ComposeArgs -Settings $Settings -Profiles $profiles
$cfg = Invoke-Docker @($baseArgs + @('config', '--quiet'))
if ($cfg.ExitCode -ne 0) { throw ('Compose validation failed: ' + ($cfg.Output -join ' ')) }
Write-Note 'docker compose config: ok (syntax only; run tests\Test-Stack.ps1 for live checks)'

Write-Step 'Validating proxied services (config\services.json)'
$registry = Read-ServiceRegistry -Settings $Settings
$plan = Get-ServicePlan -Settings $Settings -Services $registry.services
foreach ($issue in @($plan.Issues | Where-Object { $_.Level -eq 'Error' })) { Write-Warn "$($issue.Service): $($issue.Message)" }
if ($plan.FileChanges -gt 0) { Write-Warn "$($plan.FileChanges) route file(s) differ from config\services.json. Review with: .\services.ps1 preview" }
Write-Note ('{0} service(s) defined, {1} enabled.' -f @($registry.services).Count, @($registry.services | Where-Object { $_.enabled }).Count)

if ($Start) {
  Write-Step 'Starting stack'
  $up = Invoke-Docker @($baseArgs + @('up', '-d', '--wait', '--wait-timeout', '120'))
  $up.Output | ForEach-Object { Write-Note $_ }
  if ($up.ExitCode -ne 0) { throw 'docker compose up failed. See: docker compose logs --tail=100' }
}

if (Test-ContainerRunning $Settings.TraefikContainer) {
  # Picks up traefik\dynamic\ changes made above (Windows file edits do not trigger Traefik's watcher).
  $warning = Sync-TraefikDynamic $Settings
  if ($warning) { Write-Warn $warning }
}

Write-Step 'Done'
Write-Note "Project:     $InstallPath"
Write-Note "Add an app:  .\services.ps1 add -Name <name> -Hostname <host> -TargetType docker|host|lan -TargetHost <host> -Port <port>"
Write-Note "Local test:  curl.exe -i -H `"Host: <hostname>`" http://127.0.0.1:$($Settings.HttpPort)/"
Write-Note "Dashboard:   http://127.0.0.1:$($Settings.DashboardPort)/dashboard/"
Write-Note "Tests:       powershell -ExecutionPolicy Bypass -File `"$InstallPath\tests\Test-Stack.ps1`""
