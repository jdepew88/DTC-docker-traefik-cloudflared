#requires -version 5.1
<#
.SYNOPSIS
  Installs / updates the Traefik v3.7.15 + Cloudflare Tunnel Compose project on Docker Desktop (Windows).

.DESCRIPTION
  Safe to re-run. Never deletes containers, volumes or networks and never overwrites a file you edited:
  - New files are copied.
  - Files you have not modified since the last install are updated (old copy kept in backups\<timestamp>\).
  - Files you modified are left alone; the packaged version is written next to them as <file>.dist.
  The shared `proxy` network is created if missing and reused (never recreated) if it already exists.
  Secrets are prompted for (-SetTunnelToken) and stored in secrets\cloudflare_tunnel_token, never in .env.

.EXAMPLE
  .\install.ps1 -Wizard                      # guided setup: new Cloudflare tunnel + first app, with tests
  .\install.ps1 -AddApp                      # guided: publish another app on the existing tunnel
  .\install.ps1 -DryRun                      # show what would happen, change nothing
  .\install.ps1 -Start                       # install + start Traefik and the socket proxy
  .\install.ps1 -SetTunnelToken -Start -EnableTunnel   # rotate/replace the token without the wizard
  .\install.ps1 -OmniVoiceHost voice.example.com -AttachOmniVoice
  .\install.ps1 -Rollback                    # restore files from the most recent backup
  .\install.ps1 -Stop                        # stop this stack only (no -v, keeps the proxy network)
  .\install.ps1 -Reload                      # apply hand edits in traefik\dynamic\ without a restart
#>
[CmdletBinding()]
param(
  [string]$InstallPath = (Join-Path $env:USERPROFILE '.docker\projects\traefik-cloudflared-windows'),
  [switch]$DryRun,
  [switch]$Start,
  [switch]$EnableTunnel,
  [switch]$SetTunnelToken,
  [string]$OmniVoiceHost,
  [switch]$AttachOmniVoice,
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
  # container:<name>:<port> | windows:<port> | preset:omnivoice | existing
  [string]$AppTarget,
  # Route the app in Traefik only; skip the Cloudflare Access / published route steps and the public test.
  [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
if (($Wizard -or $AddApp) -and $DryRun) { throw '-Wizard / -AddApp are interactive and cannot be combined with -DryRun.' }
$ProjectName = 'traefik-cloudflared'
$TraefikImage = 'traefik:v3.7.15'   # keep in sync with compose.yaml; used for the reload helper container
$ProxyNetwork = 'proxy'
$TunnelSubnet = '172.31.250.0/28'
$ManifestName = '.install-manifest.json'
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Files managed by the installer (relative to the package root).
$ManagedFiles = @(
  'compose.yaml',
  'traefik\traefik.yml',
  'traefik\dynamic\security.yml',
  'traefik\dynamic\dashboard.yml',
  'traefik\dynamic\host-app.yml.example',
  'examples\omnivoice.dynamic.yml.example',
  'examples\omnivoice.compose.example.yaml',
  'tests\Test-Stack.ps1',
  'scripts\Get-Diagnostics.ps1',
  'scripts\TunnelWizard.ps1',
  'install.ps1',
  '.env.example',
  '.gitignore',
  'README.md',
  'SECURITY.md'
)

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" }
function Write-Warn([string]$Message) { Write-Host "    WARNING: $Message" -ForegroundColor Yellow }

# Runs docker without letting PowerShell 5.1 turn native stderr output into terminating errors.
# Plain function (no param block) so docker flags such as -q / -f are not parsed as PowerShell parameters.
function Invoke-Docker {
  $DockerArgs = @($args | ForEach-Object { $_ })
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & docker @DockerArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  return [pscustomobject]@{ ExitCode = $code; Output = @($output) }
}

# Performs an action unless -DryRun was given.
function Invoke-Change([string]$Description, [scriptblock]$Action) {
  if ($DryRun) {
    Write-Note "[dry-run] $Description"
  } else {
    Write-Note $Description
    & $Action
  }
}

# Full path without requiring it to exist (Resolve-Path fails on missing paths under StrictMode).
function Get-FullPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd('')
}

# Compose label lookup. Uses {{json}} because Windows PowerShell 5.1 strips embedded double quotes
# from native-command arguments, which breaks templates like {{index .Labels "x"}}.
function Get-Label($LabelsJson, [string]$Name) {
  if (-not $LabelsJson -or $LabelsJson -eq 'null') { return '' }
  $obj = $LabelsJson | ConvertFrom-Json
  if ($obj.PSObject.Properties[$Name]) { return [string]$obj.$Name }
  return ''
}

function Get-FileSha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Read-Manifest([string]$Path) {
  $table = @{}
  if (Test-Path -LiteralPath $Path) {
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($property in $json.PSObject.Properties) { $table[$property.Name] = $property.Value }
  }
  return $table
}

function Read-DotEnv([string]$Path) {
  $values = @{}
  if (Test-Path -LiteralPath $Path) {
    foreach ($line in Get-Content -LiteralPath $Path) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
  }
  return $values
}

function ConvertTo-IPv4Range([string]$Cidr) {
  $parts = $Cidr.Split('/')
  $bytes = ([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
  [Array]::Reverse($bytes)
  $address = [BitConverter]::ToUInt32($bytes, 0)
  $size = [Math]::Pow(2, 32 - [int]$parts[1])
  $first = [Math]::Floor($address / $size) * $size
  return @($first, ($first + $size - 1))
}

function Test-CidrOverlap([string]$A, [string]$B) {
  $ra = ConvertTo-IPv4Range $A
  $rb = ConvertTo-IPv4Range $B
  return ($ra[0] -le $rb[1]) -and ($rb[0] -le $ra[1])
}

function Get-ComposeArgs([switch]$AllProfiles) {
  $composeArgs = @('compose', '--project-directory', $InstallPath, '-f', (Join-Path $InstallPath 'compose.yaml'))
  if ($AllProfiles) { $composeArgs += @('--profile', 'tunnel', '--profile', 'test') }
  return $composeArgs
}

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

$composeFile = Join-Path $InstallPath 'compose.yaml'

# --- Stop -------------------------------------------------------------------------------------
if ($Stop) {
  Write-Step "Stopping project '$ProjectName' (containers only; files, volumes and the '$ProxyNetwork' network are kept)"
  if (-not (Test-Path -LiteralPath $composeFile)) { throw "No compose.yaml at $InstallPath" }
  $downArgs = (Get-ComposeArgs -AllProfiles) + @('down', '--remove-orphans')
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
  if (-not $DryRun) { Sync-TraefikDynamic }
  return
}

# --- Rollback ---------------------------------------------------------------------------------
if ($Rollback) {
  $backupRoot = Join-Path $InstallPath 'backups'
  $latest = $null
  if (Test-Path -LiteralPath $backupRoot) {
    $latest = Get-ChildItem -LiteralPath $backupRoot -Directory | Where-Object { $_.Name -notlike '*-pre-rollback' -and $_.Name -notlike '*-restored' } |
      Sort-Object Name -Descending | Select-Object -First 1
  }
  if ($null -eq $latest) { throw "No backups found in $backupRoot. Nothing to roll back." }
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

$existingTraefik = Invoke-Docker inspect traefik --format '{{json .Config.Labels}}'
$ownTraefikRunning = $false
if ($existingTraefik.ExitCode -eq 0) {
  $owner = Get-Label $existingTraefik.Output[-1] 'com.docker.compose.project'
  $workingDir = Get-Label $existingTraefik.Output[-1] 'com.docker.compose.project.working_dir'
  if ($owner -ne $ProjectName) {
    throw "A container named 'traefik' already exists and belongs to project '$owner'. Resolve that before installing."
  }
  if ($workingDir -and ((Get-FullPath $workingDir) -ne (Get-FullPath $InstallPath))) {
    Write-Warn "Project '$ProjectName' is currently running from $workingDir. Stop it there before starting it from $InstallPath."
    if ($Start) { throw 'Refusing to start the same Compose project from two directories.' }
  }
  $ownTraefikRunning = $true
}

Write-Step 'Checking loopback ports'
$envValues = Read-DotEnv (Join-Path $InstallPath '.env')
$ports = @{ TRAEFIK_HTTP_PORT = 8180; TRAEFIK_DASHBOARD_PORT = 8181 }
foreach ($key in @($ports.Keys)) { if ($envValues.ContainsKey($key) -and $envValues[$key]) { $ports[$key] = [int]$envValues[$key] } }
foreach ($key in $ports.Keys) {
  $port = $ports[$key]
  $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
  if ($listeners.Count -gt 0) {
    $ours = $false
    if ($ownTraefikRunning) {
      $published = Invoke-Docker port traefik
      $ours = [bool]($published.Output | Where-Object { $_ -match (":$port" + '$') })
    }
    if ($ours) { Write-Note "$key $port is published by this stack's traefik container (ok)" }
    else { throw "$key $port is already in use on this PC. Set $key to a free port in $InstallPath\.env and re-run." }
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
    $r = Invoke-Docker network create --driver bridge --label com.jdepew88.purpose=shared-traefik-proxy $ProxyNetwork
    if ($r.ExitCode -ne 0) { throw ('network create failed: ' + ($r.Output -join ' ')) }
  }
}

Write-Step "Checking tunnel subnet $TunnelSubnet for conflicts"
$netIds = (Invoke-Docker network ls -q).Output
foreach ($id in $netIds) {
  $n = Invoke-Docker network inspect $id --format '{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}'
  $nParts = $n.Output[-1].Split('|')
  if ($nParts[0] -eq ($ProjectName + '_tunnel')) { continue }
  foreach ($subnet in ($nParts[1].Trim() -split '\s+')) {
    if ($subnet -match '^\d+\.\d+\.\d+\.\d+/\d+$' -and (Test-CidrOverlap $subnet $TunnelSubnet)) {
      throw "Network '$($nParts[0])' ($subnet) overlaps $TunnelSubnet. Change the tunnel subnet, cloudflared ipv4_address and traefik.yml trustedIPs together."
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

$envPath = Join-Path $InstallPath '.env'
if (-not (Test-Path -LiteralPath $envPath)) {
  Invoke-Change 'create  .env from .env.example' { Copy-Item -LiteralPath (Join-Path $InstallPath '.env.example') -Destination $envPath }
}
$secretsDir = Join-Path $InstallPath 'secrets'
if (-not (Test-Path -LiteralPath $secretsDir)) {
  Invoke-Change 'create  secrets\' { New-Item -ItemType Directory -Path $secretsDir | Out-Null }
}

# --- OmniVoice ----------------------------------------------------------------------------------
if ($OmniVoiceHost) {
  if ($OmniVoiceHost -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') { throw "Invalid hostname: $OmniVoiceHost" }
  $omniTarget = Join-Path $InstallPath 'traefik\dynamic\omnivoice.yml'
  if (Test-Path -LiteralPath $omniTarget) {
    Write-Note 'traefik\dynamic\omnivoice.yml already exists; not overwriting.'
  } else {
    Invoke-Change "create  traefik\dynamic\omnivoice.yml for $OmniVoiceHost" {
      $template = Get-Content -LiteralPath (Join-Path $InstallPath 'examples\omnivoice.dynamic.yml.example') -Raw
      [IO.File]::WriteAllText($omniTarget, $template.Replace('voice.example.com', $OmniVoiceHost))
    }
  }
}
if ($AttachOmniVoice) {
  Write-Step "Attaching OmniVoice containers to '$ProxyNetwork' (live, no restart)"
  foreach ($name in @('omnivoice-triton-api', 'omnivoice-perform-api')) {
    $c = Invoke-Docker inspect $name --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
    if ($c.ExitCode -ne 0) { Write-Warn "container $name not found; skipped"; continue }
    if (($c.Output[-1] -split '\s+') -contains $ProxyNetwork) { Write-Note "$name already attached"; continue }
    Invoke-Change "docker network connect $ProxyNetwork $name" {
      $r = Invoke-Docker network connect $ProxyNetwork $name
      if ($r.ExitCode -ne 0) { throw ('network connect failed: ' + ($r.Output -join ' ')) }
    }
  }
}

# --- Tunnel token -------------------------------------------------------------------------------
$tokenPath = Join-Path $secretsDir 'cloudflare_tunnel_token'
if ($SetTunnelToken) {
  Write-Step 'Cloudflare tunnel token'
  Write-Note 'Cloudflare Zero Trust > Networks > Tunnels > (tunnel) > Configure, Docker tab: copy the command.'
  Write-Note 'Pasting the whole "docker run ... --token <token>" command is fine; only the token is kept.'
  if ($DryRun) {
    Write-Note '[dry-run] would prompt for the token and write secrets\cloudflare_tunnel_token'
  } else {
    $entered = Read-TunnelToken
    $other = Find-ConnectorForTunnel $entered.TunnelId
    if ($other) { throw "Container '$other' already runs a connector for tunnel $($entered.TunnelId). Use a token for a separate tunnel." }
    Save-TunnelToken $entered.Token
    $state = Get-WizardState
    $state.tunnelId = $entered.TunnelId
    $state.configuredAt = (Get-Date -Format 's')
    Save-WizardState $state
    $entered = $null
    if (((Invoke-Docker inspect cloudflared --format '{{.State.Running}}').Output -join '').Trim() -eq 'true') {
      Write-Note 'cloudflared is running; recreating it with the new token.'
      Start-TunnelStack -Recreate
    }
  }
}

# --- Wizard -------------------------------------------------------------------------------------
if ($Wizard -or $AddApp) {
  Write-Step 'Starting Traefik and the socket proxy'
  $up = Invoke-Docker @((Get-ComposeArgs) + @('up', '-d', '--wait', '--wait-timeout', '120'))
  if ($up.ExitCode -ne 0) { $up.Output | ForEach-Object { Write-Note $_ }; throw 'docker compose up failed.' }
  $ok = Invoke-TunnelWizard -AddAppOnly:$AddApp -Domain $Domain -TunnelName $TunnelName -AppHostname $AppHostname -AppTarget $AppTarget -LocalOnly:$LocalOnly
  if (-not $ok) { exit 1 }
  return
}

# --- Validate & start ---------------------------------------------------------------------------
if ($DryRun) {
  Write-Step 'Dry run complete; nothing was changed.'
  return
}

Write-Step 'Validating Compose configuration'
$profileArgs = @()
if ($EnableTunnel) {
  if (-not (Test-Path -LiteralPath $tokenPath)) { throw 'secrets\cloudflare_tunnel_token is missing. Re-run with -SetTunnelToken.' }
  $profileArgs = @('--profile', 'tunnel')
}
$baseArgs = (Get-ComposeArgs) + $profileArgs
$cfg = Invoke-Docker @($baseArgs + @('config', '--quiet'))
if ($cfg.ExitCode -ne 0) { throw ('Compose validation failed: ' + ($cfg.Output -join ' ')) }
Write-Note 'docker compose config: ok (syntax only; run tests\Test-Stack.ps1 for live checks)'

if ($Start) {
  Write-Step 'Starting stack'
  $up = Invoke-Docker @($baseArgs + @('up', '-d', '--wait', '--wait-timeout', '120'))
  $up.Output | ForEach-Object { Write-Note $_ }
  if ($up.ExitCode -ne 0) { throw 'docker compose up failed. See: docker compose logs --tail=100' }
}

if (-not $DryRun -and ((Invoke-Docker inspect traefik --format '{{.State.Running}}').Output -join '').Trim() -eq 'true') {
  # Picks up traefik\dynamic\ changes made above (Windows file edits do not trigger Traefik's watcher).
  Sync-TraefikDynamic
}

Write-Step 'Done'
Write-Note "Project: $InstallPath"
Write-Note "Local test:  curl.exe -i -H `"Host: <hostname>`" http://127.0.0.1:$($ports['TRAEFIK_HTTP_PORT'])/"
Write-Note "Dashboard:   http://127.0.0.1:$($ports['TRAEFIK_DASHBOARD_PORT'])/dashboard/"
Write-Note "Tests:       powershell -ExecutionPolicy Bypass -File `"$InstallPath\tests\Test-Stack.ps1`""
