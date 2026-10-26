#requires -version 5.1
<#
.SYNOPSIS
  Manage the applications proxied by Traefik: add, edit, enable/disable, remove, preview, validate, roll back.

.DESCRIPTION
  Services are stored in config\services.json and rendered to traefik\dynamic\svc-<name>.yml.
  Every command that changes something only shows a PREVIEW (diff + validation) unless -Apply is given.
  With -Apply the planned configuration is first loaded into a throwaway Traefik container (no network) to
  prove it is valid, then the current state is backed up (backups\services\) and the files are written.
  Traefik picks up the change without a restart. No stack container is started, stopped or recreated.

  Target types:
    docker  a container on the shared proxy network, by container name      -> http://<container>:<port>
    host    an app running directly on this Windows PC                        -> http://host.docker.internal:<port>
    lan     another device on your network (IP address or DNS name)          -> http://10.10.0.11:32800

.EXAMPLE
  .\services.ps1 list
  .\services.ps1 add -Name plex -Hostname plex.example.com -TargetType lan -TargetHost 10.10.0.11 -Port 32800
  .\services.ps1 add -Name plex -Hostname plex.example.com -TargetType lan -TargetHost 10.10.0.11 -Port 32800 -Apply
  .\services.ps1 add -Name wiki -Hostname wiki.example.com -TargetType docker -TargetHost wikijs -Port 3000 -Apply
  .\services.ps1 add -Name grafana -Hostname grafana.example.com -TargetType host -Port 3000 -Apply
  .\services.ps1 set -Name plex -Port 32400 -Apply
  .\services.ps1 disable -Name plex -Apply
  .\services.ps1 remove -Name plex -Apply
  .\services.ps1 preview                 # registry vs. generated files
  .\services.ps1 apply                   # (re)generate every route from config\services.json
  .\services.ps1 validate -Deep          # rules + a throwaway Traefik container
  .\services.ps1 backups
  .\services.ps1 rollback -Apply         # restore the state before the last apply
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('list', 'show', 'add', 'set', 'enable', 'disable', 'remove', 'preview', 'apply', 'validate', 'backups', 'rollback')]
  [string]$Command = 'list',
  [string]$Name,
  [string[]]$Hostname,
  [ValidateSet('docker', 'host', 'lan')][string]$TargetType,
  [string]$TargetHost,
  [int]$Port,
  [ValidateSet('http', 'https', 'h2c')][string]$Protocol,
  [switch]$TlsSkipVerify,
  [string]$PathPrefix,
  [switch]$StripPrefix,
  [string[]]$Middleware,
  [string]$Description,
  [switch]$Disabled,
  # Cloudflare intent (used for warnings, the wizard and the web UI): -NoAccess = no Cloudflare Access login,
  # -LocalOnly = not published through the tunnel at all.
  [switch]$NoAccess,
  [switch]$LocalOnly,
  [string]$BackupId,
  [switch]$Apply,
  [switch]$Deep,
  [switch]$SkipDeepValidation,
  [switch]$Json,
  [string]$InstallPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'lib\TraefikProxy.psm1') -Force

# Run from the deployed folder by default; from a source checkout, target the default install folder.
if (-not $InstallPath) {
  if ((Test-Path -LiteralPath (Join-Path $here '.env')) -or (Test-Path -LiteralPath (Join-Path $here '.install-manifest.json'))) { $InstallPath = $here }
  else { $InstallPath = Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy' }
}
if (-not (Test-Path -LiteralPath (Join-Path $InstallPath 'compose.yaml'))) { throw "No installation at $InstallPath. Run install.ps1 first or pass -InstallPath." }
$settings = Get-StackSettings -InstallPath $InstallPath

function Write-Plan($Plan) {
  foreach ($line in (Format-ServicePlan $Plan)) {
    $color = 'Gray'
    if ($line -match '^\[ERROR\]') { $color = 'Red' } elseif ($line -match '^\[WARNING\]') { $color = 'Yellow' }
    elseif ($line -match '^    \+ ') { $color = 'Green' } elseif ($line -match '^    - ') { $color = 'Red' }
    elseif ($line -match '^(ADD|UPDATE|REMOVE)') { $color = 'Cyan' }
    Write-Host $line -ForegroundColor $color
  }
}

function Find-ProxyService([object[]]$Services, [string]$ServiceName) {
  $found = @($Services | Where-Object { $_.name -eq $ServiceName.ToLowerInvariant() })
  if ($found.Count -eq 0) { throw "No service named '$ServiceName'. See: .\services.ps1 list" }
  return $found[0]
}

# Shows the plan and, with -Apply, validates it in Traefik and writes it.
function Complete-Change($Services, [string]$Summary) {
  $plan = Get-ServicePlan -Settings $settings -Services $Services
  if ($Json) { $plan | Select-Object HasErrors, FileChanges, RegistryChanged, Issues, Changes | ConvertTo-Json -Depth 6; if (-not $Apply) { return } }
  else { Write-Host "Preview: $Summary" -ForegroundColor Cyan; Write-Plan $plan; Write-Host '' }
  if ($plan.HasErrors) { Write-Host 'Fix the errors above; nothing was changed.' -ForegroundColor Red; exit 1 }
  if (-not $Apply) {
    if ($plan.FileChanges -gt 0 -or $plan.RegistryChanged) { Write-Host 'Nothing was changed. Re-run with -Apply to write these changes.' -ForegroundColor Yellow }
    return
  }
  if ($plan.FileChanges -eq 0 -and -not $plan.RegistryChanged) { Write-Host 'Already up to date.' -ForegroundColor Green; return }
  if ($plan.FileChanges -gt 0 -and -not $SkipDeepValidation) {
    Write-Host 'Validating the planned configuration in a throwaway Traefik container...' -ForegroundColor Cyan
    $deep = Test-TraefikDynamicConfig -Settings $settings -Plan $plan
    foreach ($w in $deep.Warnings) { Write-Host "  [WARNING] $w" -ForegroundColor Yellow }
    if (-not $deep.Ok) {
      foreach ($e in $deep.Errors) { Write-Host "  [ERROR] $e" -ForegroundColor Red }
      Write-Host 'Traefik rejected the configuration; nothing was changed.' -ForegroundColor Red
      exit 1
    }
    Write-Host "  Traefik accepted $(@($deep.Routers).Count) generated router(s)." -ForegroundColor Green
  }
  $result = Invoke-ServicePlan -Settings $settings -Plan $plan
  Write-Host "Applied. Previous state saved to $($result.Backup) (undo: .\services.ps1 rollback -Apply)" -ForegroundColor Green
  if ($result.ReloadWarning) { Write-Host "  [WARNING] $($result.ReloadWarning)" -ForegroundColor Yellow }
  if ($result.Reloaded) {
    $wait = Wait-ServiceRouters -Settings $settings -Services $plan.Services
    if ($wait.Ok) { Write-Host '  Traefik loaded every enabled service route.' -ForegroundColor Green }
    else { Write-Host ("  [WARNING] Traefik has not loaded: " + ($wait.Missing -join ', ')) -ForegroundColor Yellow }
  } elseif (-not (Test-ContainerRunning $settings.TraefikContainer)) {
    Write-Host "  Traefik ($($settings.TraefikContainer)) is not running; routes load when it starts." -ForegroundColor Yellow
  }
}

$registry = Read-ServiceRegistry -Settings $settings
$services = @($registry.services)

switch ($Command) {
  'list' {
    if ($Json) { ConvertTo-RegistryJson $services; break }
    if ($services.Count -eq 0) { Write-Host 'No services yet. Add one with: .\services.ps1 add -Name <name> -Hostname <host> -TargetType docker|host|lan -TargetHost <host> -Port <port>'; break }
    $services | ForEach-Object {
      [pscustomobject]@{
        Name = $_.name
        Enabled = $_.enabled
        Hostnames = ($_.hostnames -join ', ') + $_.pathPrefix
        Target = "$($_.target.type): $(Get-ServiceUrl $_)"
        Access = if (-not $_.cloudflare.publish) { 'local only' } elseif ($_.cloudflare.access) { 'Cloudflare Access' } else { 'PUBLIC' }
      }
    } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  }
  'show' {
    $s = Find-ProxyService $services $Name
    Write-Host (ConvertTo-RegistryJson @($s))
    Write-Host '--- traefik\dynamic\' (Get-ServiceFileName $s.name) -ForegroundColor Cyan
    Write-Host (ConvertTo-TraefikRouteYaml $s)
  }
  'add' {
    foreach ($required in @('Name', 'Hostname', 'TargetType', 'Port')) {
      if (-not $PSBoundParameters.ContainsKey($required)) { throw "add needs -$required." }
    }
    $p = @{ Name = $Name; Hostname = $Hostname; TargetType = $TargetType; TargetHost = $TargetHost; Port = $Port
      TlsSkipVerify = $TlsSkipVerify; PathPrefix = $PathPrefix; StripPrefix = $StripPrefix; Description = $Description
      Disabled = $Disabled; Publish = (-not $LocalOnly); Access = (-not $NoAccess -and -not $LocalOnly) }
    if ($Protocol) { $p.Protocol = $Protocol }
    if ($PSBoundParameters.ContainsKey('Middleware')) { $p.Middleware = $Middleware }
    $new = New-ServiceDefinition @p
    Complete-Change (@($services) + $new) "add service '$($new.name)'"
  }
  'set' {
    $s = Find-ProxyService $services $Name
    if ($PSBoundParameters.ContainsKey('Hostname')) { $s.hostnames = @($Hostname | ForEach-Object { $_.ToLowerInvariant() }) }
    if ($PSBoundParameters.ContainsKey('TargetType')) {
      $s.target.type = $TargetType
      if ($TargetType -eq 'host' -and -not $PSBoundParameters.ContainsKey('TargetHost')) { $s.target.host = 'host.docker.internal' }
    }
    if ($PSBoundParameters.ContainsKey('TargetHost')) { $s.target.host = $TargetHost }
    if ($PSBoundParameters.ContainsKey('Port')) { $s.target.port = $Port }
    if ($PSBoundParameters.ContainsKey('Protocol')) { $s.target.protocol = $Protocol }
    if ($PSBoundParameters.ContainsKey('TlsSkipVerify')) { $s.target.tlsSkipVerify = [bool]$TlsSkipVerify }
    if ($PSBoundParameters.ContainsKey('PathPrefix')) { $s.pathPrefix = $PathPrefix }
    if ($PSBoundParameters.ContainsKey('StripPrefix')) { $s.stripPrefix = [bool]$StripPrefix }
    if ($PSBoundParameters.ContainsKey('Middleware')) { $s.middlewares = @($Middleware) }
    if ($PSBoundParameters.ContainsKey('Description')) { $s.description = $Description }
    if ($PSBoundParameters.ContainsKey('Disabled')) { $s.enabled = -not $Disabled }
    if ($PSBoundParameters.ContainsKey('LocalOnly')) { $s.cloudflare.publish = -not $LocalOnly }
    if ($PSBoundParameters.ContainsKey('NoAccess')) { $s.cloudflare.access = -not $NoAccess }
    Complete-Change $services "update service '$($s.name)'"
  }
  'enable' { (Find-ProxyService $services $Name).enabled = $true; Complete-Change $services "enable '$Name'" }
  'disable' { (Find-ProxyService $services $Name).enabled = $false; Complete-Change $services "disable '$Name' (definition kept, route removed)" }
  'remove' {
    $null = Find-ProxyService $services $Name
    Complete-Change @($services | Where-Object { $_.name -ne $Name.ToLowerInvariant() }) "remove '$Name'"
  }
  'preview' {
    $Apply = $false
    Complete-Change $services 'config\services.json vs. traefik\dynamic\svc-*.yml'
  }
  'apply' { $Apply = $true; Complete-Change $services 'regenerate all routes from config\services.json' }
  'validate' {
    $plan = Get-ServicePlan -Settings $settings -Services $services
    Write-Plan $plan
    $ok = -not $plan.HasErrors
    if ($Deep) {
      Write-Host 'Loading the configuration into a throwaway Traefik container...' -ForegroundColor Cyan
      $deepResult = Test-TraefikDynamicConfig -Settings $settings -Plan $plan
      foreach ($w in $deepResult.Warnings) { Write-Host "  [WARNING] $w" -ForegroundColor Yellow }
      foreach ($e in $deepResult.Errors) { Write-Host "  [ERROR] $e" -ForegroundColor Red }
      foreach ($r in $deepResult.Routers) { Write-Host ("  {0,-30} {1,-9} {2}" -f $r.Name, $r.Status, $r.Rule) }
      $ok = $ok -and $deepResult.Ok
    }
    if ($ok) { Write-Host 'Configuration is valid.' -ForegroundColor Green } else { Write-Host 'Configuration has errors.' -ForegroundColor Red; exit 1 }
  }
  'backups' {
    $list = @(Get-ServiceBackups $settings)
    if ($list.Count -eq 0) { Write-Host 'No service backups yet.'; break }
    $list | Select-Object Id, CreatedAt, @{ n = 'RouteFiles'; e = { $_.Files.Count } } | Format-Table -AutoSize | Out-String | Write-Host
  }
  'rollback' {
    $list = @(Get-ServiceBackups $settings | Where-Object { -not $_.Restored -and -not $_.PreRollback })
    if ($BackupId) { $list = @(Get-ServiceBackups $settings | Where-Object { $_.Id -eq $BackupId }) }
    if ($list.Count -eq 0) { throw 'No service backup to restore.' }
    $snap = $list[0]
    Write-Host "Would restore service state from $($snap.Id) ($($snap.CreatedAt)): $($snap.Files.Count) route file(s) + config\services.json." -ForegroundColor Cyan
    if (-not $Apply) { Write-Host 'Nothing was changed. Re-run with -Apply to restore it.' -ForegroundColor Yellow; break }
    $r = Restore-ServiceBackup -Settings $settings -Id $snap.Id
    Write-Host "Restored $($r.Restored). The state before the rollback was saved as $($r.SavedCurrentAs)." -ForegroundColor Green
    if ($r.ReloadWarning) { Write-Host "  [WARNING] $($r.ReloadWarning)" -ForegroundColor Yellow }
  }
}
