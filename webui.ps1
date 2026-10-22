#requires -version 5.1
<#
.SYNOPSIS
  Local web interface for the Traefik + Cloudflare Tunnel proxy: guided setup, service management, Cloudflare
  DNS / Tunnel / Access automation, backups, logs and diagnostics.

.DESCRIPTION
  Listens on 127.0.0.1 only (a loopback socket, unreachable from the LAN). Access needs the one-time link printed
  at startup, which sets a session cookie; every API call is also checked for the Host header (DNS-rebinding
  protection), and every change for the Origin header and a per-session CSRF token. Nothing is changed without a
  preview and an explicit confirmation in the browser, and overwriting existing Cloudflare resources needs a
  separate confirmation per resource.

  The server is a thin layer over lib\TraefikProxy.psm1 (the same code services.ps1 and install.ps1 use) and
  lib\CloudflareApi.psm1. The Cloudflare API token is stored with Windows DPAPI (current user) in
  secrets\cloudflare_api.dpapi and is never sent back to the browser.

  Stop the server with Ctrl+C.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\webui.ps1
  powershell -ExecutionPolicy Bypass -File .\webui.ps1 -Port 8190 -InstallPath D:\proxy -NoBrowser
#>
[CmdletBinding()]
param(
  [ValidateRange(1024, 65535)][int]$Port = 8190,
  [string]$InstallPath,
  [switch]$NoBrowser,
  # Tests only: a loopback Cloudflare API mock (http://127.0.0.1:<port>). Real use always talks to api.cloudflare.com.
  [string]$CloudflareApiBase,
  # Tests only: write the launch link here instead of printing/opening it, and stop when StopFile appears.
  [string]$LaunchUrlFile,
  [string]$StopFile,
  # Where the last used install folder and the recent projects are remembered (default: %LOCALAPPDATA%\TraefikProxy\webui.json).
  [string]$StateFile,
  # Folder whose subfolders are offered as existing deployments (default: %USERPROFILE%\.docker\projects).
  [string]$ProjectsRoot,
  # Launcher mode (Start-DeploymentManager.ps1): the sign-in link is written to -LaunchUrlFile only (never printed),
  # works once and is replaced by a new one after use; -OpenBrowser opens it.
  [switch]$SingleUseLaunch,
  [switch]$OpenBrowser,
  # App Catalog manifests (default: catalog\ next to this script; tests use a fixture folder).
  [string]$CatalogDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $here 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $here 'lib\Dashboard.psm1') -Force
Import-Module (Join-Path $here 'lib\ConfigBackup.psm1') -Force
Import-Module (Join-Path $here 'lib\ProjectDiscovery.psm1') -Force
Import-Module (Join-Path $here 'lib\Infrastructure.psm1') -Force
Import-Module (Join-Path $here 'lib\DockerDiscovery.psm1') -Force
Import-Module (Join-Path $here 'lib\ServiceHealth.psm1') -Force
Import-Module (Join-Path $here 'lib\AppCatalog.psm1') -Force
if (-not $CatalogDir) { $CatalogDir = Join-Path $here 'catalog' }
Import-Module (Join-Path $here 'lib\LocalHttp.psm1') -Force
Set-CloudflareApiBase $CloudflareApiBase

if (-not $StateFile) { $StateFile = Join-Path $env:LOCALAPPDATA 'TraefikProxy\webui.json' }
if (-not $ProjectsRoot) { $ProjectsRoot = Join-Path $env:USERPROFILE '.docker\projects' }
# With an explicit -InstallPath the deployment is chosen; otherwise the website starts on the project chooser.
$ProjectChosen = $PSBoundParameters.ContainsKey('InstallPath')
# Install folder: -InstallPath, else this folder when it is an installation, else the folder chosen last time in the
# setup wizard, else the default.
if (-not $InstallPath) {
  if ((Test-Path -LiteralPath (Join-Path $here '.env')) -or (Test-Path -LiteralPath (Join-Path $here '.install-manifest.json'))) { $InstallPath = $here }
  else {
    $InstallPath = Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy'
    try {
      if (Test-Path -LiteralPath $StateFile) {
        $remembered = [string](([IO.File]::ReadAllText($StateFile) | ConvertFrom-Json).installPath)
        if ($remembered -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $remembered)) { $InstallPath = $remembered }
      }
    } catch { }
  }
}
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
$StaticRoot = Join-Path $here 'webui'

function New-RandomKey([int]$Bytes = 32) {
  $b = New-Object byte[] $Bytes
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($b)
  return ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$State = @{
  LaunchKey = New-RandomKey
  Sessions  = @{}
  Plans     = @{}
  Imports   = @{}
  Chosen    = $ProjectChosen
  Upgrades  = @{}
  AppPlans  = @{}
  Cookie    = "tpx_session_$Port"
  Origins   = @("http://127.0.0.1:$Port", "http://localhost:$Port")
  Hosts     = @("127.0.0.1:$Port", "localhost:$Port")
}

$SecurityHeaders = @{
  'Content-Security-Policy'      = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
  'X-Content-Type-Options'       = 'nosniff'
  'X-Frame-Options'              = 'DENY'
  'Referrer-Policy'              = 'no-referrer'
  'Cache-Control'                = 'no-store'
  'Cross-Origin-Opener-Policy'   = 'same-origin'
  'Cross-Origin-Resource-Policy' = 'same-origin'
  'Permissions-Policy'           = 'camera=(), microphone=(), geolocation=(), payment=(), usb=()'
}
$StaticFiles = @{
  '/'           = @('index.html', 'text/html; charset=utf-8')
  '/index.html' = @('index.html', 'text/html; charset=utf-8')
  '/app.js'     = @('app.js', 'text/javascript; charset=utf-8')
  '/ui.js'      = @('ui.js', 'text/javascript; charset=utf-8')
  '/logic.js'   = @('logic.js', 'text/javascript; charset=utf-8')
  '/setup.js'   = @('setup.js', 'text/javascript; charset=utf-8')
  '/pages.js'   = @('pages.js', 'text/javascript; charset=utf-8')
  '/projects.js' = @('projects.js', 'text/javascript; charset=utf-8')
  '/brands.js' = @('brands.js', 'text/javascript; charset=utf-8')
  '/explorer.js' = @('explorer.js', 'text/javascript; charset=utf-8')
  '/discover.js' = @('discover.js', 'text/javascript; charset=utf-8')
  '/catalog.js' = @('catalog.js', 'text/javascript; charset=utf-8')
  '/learn.json' = @('learn.json', 'application/json; charset=utf-8')
  '/app.css'    = @('app.css', 'text/css; charset=utf-8')
  '/icon.svg'   = @('icon.svg', 'image/svg+xml')
}
$EmailPattern = '^[A-Za-z0-9._%+''-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,63}$'

# --- Helpers -------------------------------------------------------------------------------------------------

function Stop-Request([int]$Status, [string]$Message, $Extra) {
  $ex = New-Object System.Exception $Message
  $ex.Data['status'] = $Status
  if ($Extra) { $ex.Data['extra'] = $Extra }
  throw $ex
}

function Get-Field($Object, [string]$Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
  return $Default
}

function New-JsonResponse($Data, [int]$Status = 200, [hashtable]$Headers = @{}) {
  $h = @{} + $SecurityHeaders
  foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  return @{ Status = $Status; ContentType = 'application/json; charset=utf-8'; Body = (ConvertTo-Json -InputObject $Data -Depth 14 -Compress); Headers = $h }
}

# Instance settings: the installed .env, else the setup wizard's draft, else the packaged defaults.
function Get-Settings {
  if (Test-Path -LiteralPath (Join-Path $InstallPath '.env')) { return Get-StackSettings -InstallPath $InstallPath }
  $draft = Read-SetupDraft
  $values = Read-DotEnv (Join-Path $here '.env.example')
  if ($draft.settings) { foreach ($p in $draft.settings.PSObject.Properties) { $values[$p.Name] = [string]$p.Value } }
  return ConvertTo-StackSettings -InstallPath $InstallPath -Values $values
}

# The .env values the installer writes: the instance keys plus TRAEFIK_LOG_LEVEL / TRAEFIK_READ_TIMEOUT when the setup
# draft has them (a restored backup).
function Get-EnvValues($Settings) {
  $values = ConvertTo-InstanceValues $Settings
  $draft = Read-SetupDraft
  foreach ($k in @('TRAEFIK_LOG_LEVEL', 'TRAEFIK_READ_TIMEOUT')) {
    if ($draft.settings -and $draft.settings.PSObject.Properties[$k] -and [string]$draft.settings.$k -match '^[A-Za-z0-9_.:-]{1,32}$') { $values[$k] = [string]$draft.settings.$k }
  }
  return $values
}

function Get-SettingsSource {
  if (Test-Path -LiteralPath (Join-Path $InstallPath '.env')) { return 'env' }
  if ((Read-SetupDraft).settings) { return 'draft' }
  return 'defaults'
}

# Setup wizard choices that are not secret and not yet installed: config\setup.json in the install folder.
function Read-SetupDraft { return Read-SetupDraftFile $InstallPath }

function Save-SetupDraft($Draft) {
  Write-TextFileAtomic (Join-Path $InstallPath 'config\setup.json') (ConvertTo-SetupDraftJson $Draft)
  Save-RememberedPath
}

# A protected recovery point (backups\recovery\) before a configuration change. A change is refused when the
# recovery point cannot be written.
function New-ChangeRecoveryPoint([string]$Reason) {
  try { return New-RecoveryPoint -Settings (Get-Settings) -Reason $Reason -SourceRoot $here }
  catch { Stop-Request 500 "No change was made: the recovery point could not be written ($($_.Exception.Message))." }
}

# A file download (not JSON). Invoke-Request sends it as-is with Content-Disposition: attachment.
function New-Download([string]$FileName, [string]$ContentType, $Body) {
  return [pscustomobject]@{ IsDownload = $true; FileName = $FileName; ContentType = $ContentType; Body = $Body }
}

# Manager state outside every deployment: the last used folder and the recent projects (paths and names only).
function Read-ManagerState {
  $st = [ordered]@{ installPath = ''; recent = @() }
  try {
    if (Test-Path -LiteralPath $StateFile) {
      $j = [IO.File]::ReadAllText($StateFile) | ConvertFrom-Json
      if ($j.PSObject.Properties['installPath']) { $st.installPath = [string]$j.installPath }
      if ($j.PSObject.Properties['recent'] -and $j.recent) {
        $st.recent = @($j.recent | Where-Object { $_ -and $_.PSObject.Properties['path'] -and [string]$_.path -match '^[A-Za-z]:\\' } | ForEach-Object {
            [ordered]@{ path = [string]$_.path; stackName = [string](Get-Field $_ 'stackName' ''); lastOpened = [string](Get-Field $_ 'lastOpened' '') } })
      }
    }
  } catch { }
  if ($st.installPath -and @($st.recent | Where-Object { Test-SamePath $_.path $st.installPath }).Count -eq 0) { $st.recent = @([ordered]@{ path = $st.installPath; stackName = ''; lastOpened = '' }) + @($st.recent) }
  return $st
}

function Save-ManagerState($St) {
  try { Write-TextFileAtomic $StateFile ((ConvertTo-Json -InputObject $St -Depth 4) + "`n") } catch { }
}

# Remembers the install folder for the next start and puts it on top of the recent projects (nothing secret).
function Save-RememberedPath {
  $st = Read-ManagerState
  $name = ''
  try { $name = (Get-Settings).StackName } catch { }
  $st.installPath = $InstallPath
  $st.recent = @(@([ordered]@{ path = $InstallPath; stackName = $name; lastOpened = (Get-Date -Format 's') }) + @($st.recent | Where-Object { -not (Test-SamePath $_.path $InstallPath) }) | Select-Object -First 20)
  Save-ManagerState $st
}

function Test-Installed { return (Test-Path -LiteralPath (Join-Path $InstallPath 'compose.yaml')) }

# Code (modules, scripts, static files) always comes from $here, the folder webui.ps1 runs from; $InstallPath
# holds only the instance's configuration and runtime files and may not exist before the first install.
function Get-NotInstalledMessage { return "Not installed: no Traefik installation at $InstallPath yet. Finish the Traefik step on the Setup page first." }
function Assert-Installed { if (-not (Test-Installed)) { Stop-Request 409 (Get-NotInstalledMessage) } }

function Write-Audit([string]$Action, [string]$Detail) {
  if (-not (Test-Path -LiteralPath $InstallPath)) { return }
  $dir = Join-Path $InstallPath 'logs'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $line = '{0} {1} {2}' -f (Get-Date -Format 's'), $Action, ((ConvertTo-RedactedText @($Detail)) -join ' ')
  [IO.File]::AppendAllText((Join-Path $dir 'webui-audit.log'), $line + "`r`n")
}

function Get-Cookie($Request, [string]$Name) {
  if (-not $Request.Headers.ContainsKey('cookie')) { return $null }
  foreach ($part in $Request.Headers['cookie'].Split(';')) {
    $kv = $part.Trim().Split('=', 2)
    if ($kv.Count -eq 2 -and $kv[0] -eq $Name) { return $kv[1] }
  }
  return $null
}

function Test-ConstantTimeEqual([string]$A, [string]$B) {
  if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
  return $diff -eq 0
}

function Invoke-PowerShellFile([string]$File, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $File @Arguments 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Lines = @(ConvertTo-RedactedText @($out)) }
}

function Assert-Confirmed($Body) {
  if (-not [bool](Get-Field $Body 'confirm' $false)) { Stop-Request 400 'This action needs explicit confirmation.' }
}

# --- Status ----------------------------------------------------------------------------------------------------

function Get-StatusData {
  $settings = Get-Settings
  $docker = Get-DockerStatus
  $stack = Get-StackStatus -Settings $settings -SkipDocker:(-not $docker.EngineRunning)
  $services = @()
  $drift = 0
  if (Test-Installed) {
    try {
      $registry = Read-ServiceRegistry -Settings $settings
      $services = @($registry.services)
      $drift = (Get-ServicePlan -Settings $settings -Services $services).FileChanges
    } catch { }
  }
  $cfConfig = Read-CloudflareConfig -Settings $settings
  $token = Get-CloudflareApiTokenInfo -Settings $settings
  return [ordered]@{
    instance   = [ordered]@{ installPath = $InstallPath; installed = (Test-Installed); stackName = $settings.StackName; httpPort = $settings.HttpPort; dashboardPort = $settings.DashboardPort; proxyNetwork = $settings.ProxyNetwork; tunnelSubnet = $settings.TunnelSubnet; sourcePath = $here; canInstall = (Test-Path -LiteralPath (Join-Path $here 'install.ps1')) }
    docker     = $docker
    stack      = $stack
    services   = [ordered]@{ total = $services.Count; enabled = @($services | Where-Object { $_.enabled }).Count; drift = $drift }
    cloudflare = [ordered]@{ tokenStored = $token.Stored; tokenReadable = $token.Readable; tokenSavedAt = $token.SavedAt; accountId = $cfConfig.accountId; accountName = $cfConfig.accountName; tunnelId = $cfConfig.tunnelId; tunnelName = $cfConfig.tunnelName; apiBase = (Get-CloudflareApiBase) }
  }
}

# --- Services --------------------------------------------------------------------------------------------------

function ConvertTo-ServiceView($Service, $Routers, $Managed) {
  $router = @($Routers | Where-Object { $null -ne $_ -and $_.name -eq "svc-$($Service.name)@file" })
  $cf = @()
  foreach ($h in $Service.hostnames) {
    if ($Managed -and $Managed.PSObject.Properties[$h]) { $cf += [ordered]@{ hostname = $h; dns = [bool]$Managed.$h.dnsRecordId; access = [bool]$Managed.$h.accessAppId } }
  }
  return [ordered]@{
    service   = $Service
    url       = Get-ServiceUrl $Service
    rule      = Get-ServiceRule $Service
    router    = $(if ($router.Count -gt 0) { [string]$router[0].status } elseif ($null -eq $Routers) { 'unknown' } else { 'not loaded' })
    exposure  = $(if (-not $Service.cloudflare.publish) { 'local' } elseif ($Service.cloudflare.access) { 'access' } else { 'public' })
    cloudflareManaged = $cf
  }
}

function Get-ServicesData {
  if (-not (Test-Installed)) {
    return [ordered]@{ installed = $false; message = (Get-NotInstalledMessage); services = @(); middlewares = @(); drift = @(); issues = @(); traefikUp = $false }
  }
  $settings = Get-Settings
  $registry = Read-ServiceRegistry -Settings $settings
  $routers = Get-TraefikApi $settings '/api/http/routers'
  $plan = Get-ServicePlan -Settings $settings -Services $registry.services
  $cf = Read-CloudflareConfig -Settings $settings
  return [ordered]@{
    installed   = $true
    services    = @($registry.services | ForEach-Object { ConvertTo-ServiceView $_ $routers $cf.managed })
    middlewares = @(Get-AvailableMiddlewares $settings | ForEach-Object { "$_@file" })
    drift       = @($plan.Changes | Where-Object { $_.Action -ne 'unchanged' } | ForEach-Object { [ordered]@{ file = $_.File; action = $_.Action } })
    issues      = @($plan.Issues)
    traefikUp   = ($null -ne $routers)
  }
}

# Suggests docker / host / lan from what the user typed as backend host.
function Resolve-Target($Target) {
  $hostValue = ([string](Get-Field $Target 'host' '')).Trim()
  $type = ([string](Get-Field $Target 'type' 'auto')).Trim().ToLowerInvariant()
  $note = ''
  if ($type -eq 'auto' -or -not $type) {
    if ($hostValue -match '^(localhost|127\.\d+\.\d+\.\d+|host\.docker\.internal|::1)$') {
      $type = 'host'
      if ($hostValue -ne 'host.docker.internal') { $note = "'$hostValue' inside a container means the container itself; this PC is reached as host.docker.internal." }
      $hostValue = 'host.docker.internal'
    } elseif ((Test-IPv4Address $hostValue) -or $hostValue.Contains('.')) { $type = 'lan' }
    else { $type = 'docker' }
  }
  return [pscustomobject]@{ Type = $type; Host = $hostValue; Note = $note }
}

function Get-ServiceFromBody($Body) {
  $svc = Get-Field $Body 'service' $null
  if ($null -eq $svc) { Stop-Request 400 'Missing service definition.' }
  $target = Get-Field $svc 'target' $null
  $resolved = Resolve-Target $target
  $hostnames = @(Get-Field $svc 'hostnames' @())
  if ($hostnames.Count -gt 20) { Stop-Request 400 'At most 20 hostnames per service.' }
  $displayName = ([string](Get-Field $svc 'displayName' '')).Trim()
  $definition = ConvertTo-ServiceDefinition @{
    name = Get-Field $svc 'name' ''; displayName = $displayName.Substring(0, [Math]::Min(80, $displayName.Length)); description = ([string](Get-Field $svc 'description' '')).Substring(0, [Math]::Min(200, ([string](Get-Field $svc 'description' '')).Length))
    enabled = [bool](Get-Field $svc 'enabled' $true); hostnames = $hostnames; pathPrefix = Get-Field $svc 'pathPrefix' ''
    stripPrefix = [bool](Get-Field $svc 'stripPrefix' $false); middlewares = @(Get-Field $svc 'middlewares' @('default-headers@file'))
    target = @{ type = $resolved.Type; host = $resolved.Host; port = (Get-Field $target 'port' 0); protocol = (Get-Field $target 'protocol' 'http'); tlsSkipVerify = [bool](Get-Field $target 'tlsSkipVerify' $false) }
    cloudflare = @{ publish = [bool](Get-Field (Get-Field $svc 'cloudflare' $null) 'publish' $true); access = [bool](Get-Field (Get-Field $svc 'cloudflare' $null) 'access' $true) }
  }
  return [pscustomobject]@{ Service = $definition; Note = $resolved.Note }
}

function Find-RegistryService($Services, [string]$Name) {
  $found = @($Services | Where-Object { $_.name -eq ([string]$Name).ToLowerInvariant() })
  if ($found.Count -eq 0) { Stop-Request 404 "No service named '$Name'." }
  return $found[0]
}

# Extra live checks for docker targets (read-only).
function Get-TargetWarnings($Settings, $Service) {
  $warnings = @()
  if ($null -eq $Service -or $Service.target.type -ne 'docker' -or $Service.target.host -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { return $warnings }
  $r = Invoke-Docker inspect $Service.target.host --format '{{json .NetworkSettings.Networks}}'
  if ($r.ExitCode -ne 0) {
    $warnings += "No container named '$($Service.target.host)' exists right now. The route will answer 502 until it does."
  } else {
    $nets = ((@($r.Output) -join '') | ConvertFrom-Json)
    if (-not $nets.PSObject.Properties[$Settings.ProxyNetwork]) {
      $warnings += "Container '$($Service.target.host)' is not attached to the '$($Settings.ProxyNetwork)' network, so Traefik cannot reach it. Add it in its compose file (networks: [$($Settings.ProxyNetwork)], external) or run: docker network connect $($Settings.ProxyNetwork) $($Service.target.host)"
    }
  }
  return $warnings
}

# Builds the Traefik + Cloudflare plan for a change request. Pure read: nothing is written.
function Build-ChangePlan($Body) {
  Assert-Installed
  $settings = Get-Settings
  $registry = Read-ServiceRegistry -Settings $settings
  $services = @($registry.services)
  $op = [string](Get-Field $Body 'op' '')
  $name = [string](Get-Field $Body 'name' '')
  $notes = @()
  $previous = $null; $new = $null
  switch ($op) {
    'add' {
      $parsed = Get-ServiceFromBody $Body
      $new = $parsed.Service
      if ($parsed.Note) { $notes += $parsed.Note }
      $list = @($services) + $new
      $summary = "Add service '$($new.name)'"
    }
    'update' {
      $previous = Find-RegistryService $services $name
      $parsed = Get-ServiceFromBody $Body
      $new = $parsed.Service
      if ($parsed.Note) { $notes += $parsed.Note }
      if ($new.name -ne $previous.name) { Stop-Request 400 'A service cannot be renamed; remove it and add it again.' }
      $list = @($services | ForEach-Object { if ($_.name -eq $previous.name) { $new } else { $_ } })
      $summary = "Update service '$($new.name)'"
    }
    { $_ -in @('enable', 'disable') } {
      $previous = Find-RegistryService $services $name
      $new = ConvertTo-ServiceDefinition ($previous | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
      $new.enabled = ($op -eq 'enable')
      $list = @($services | ForEach-Object { if ($_.name -eq $previous.name) { $new } else { $_ } })
      $summary = "$((Get-Culture).TextInfo.ToTitleCase($op)) service '$($new.name)'"
      if ($op -eq 'disable') { $notes += 'Disabling removes the Traefik route but keeps the definition and the Cloudflare records (the hostname answers 404 until you enable it again).' }
    }
    'remove' {
      $previous = Find-RegistryService $services $name
      $list = @($services | Where-Object { $_.name -ne $previous.name })
      $summary = "Remove service '$($previous.name)'"
    }
    default { Stop-Request 400 "Unknown operation '$op'." }
  }
  $cfOptions = Get-Field $Body 'cloudflare' $null
  $automate = [bool](Get-Field $cfOptions 'automate' $true)
  $cleanup = [bool](Get-Field $cfOptions 'cleanup' $true)
  $emails = @(@(Get-Field $cfOptions 'accessEmails' @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
  if ($emails.Count -gt 50) { Stop-Request 400 'At most 50 Access emails.' }
  foreach ($e in $emails) { if ($e -notmatch $EmailPattern) { Stop-Request 400 "'$e' is not a valid email address." } }

  # The public dashboard's hostname belongs to the dashboard: no service may route it, and its Cloudflare records are
  # never cleaned up by a service change.
  $dash = Read-DashboardConfig -Settings $settings
  if ($dash.hostname -and $new -and @($new.hostnames) -contains $dash.hostname) { Stop-Request 400 "$($dash.hostname) is the public Traefik dashboard's hostname. Choose another hostname." }
  $traefik = Get-ServicePlan -Settings $settings -Services $list
  $others = @($list | Where-Object { $null -eq $new -or $_.name -ne $new.name })
  if ($dash.hostname) { $others += Get-DashboardPseudoService $settings $dash.hostname }
  $cf = $null
  if ($automate) {
    try { $cf = Get-CloudflareServicePlan -Settings $settings -Service $new -PreviousService $previous -OtherServices $others -AccessEmails $emails -Cleanup:$cleanup }
    catch { $cf = [pscustomobject]@{ Connected = $true; Actions = @(); Notes = @(); Errors = @($_.Exception.Message); ManualSteps = @(); Fingerprint = 'error' } }
  } else {
    $cfg = Read-CloudflareConfig -Settings $settings
    $cf = [pscustomobject]@{ Connected = $false; Actions = @(); Notes = @('Cloudflare automation is off for this change; only Traefik is changed.'); Errors = @(); ManualSteps = @(Get-CloudflareManualSteps $new $cfg.tunnelId); Fingerprint = '' }
  }
  # One owner per hostname: a hostname another router in this Traefik (hand-written file, Docker labels) or a
  # container's labels already claim blocks the change; the user resolves the other definition first.
  if ($new -and $new.enabled) {
    $claimRouters = Get-TraefikApi $settings '/api/http/routers'
    $labelled = @(); try { $labelled = @(Get-DockerContainerInventory -ProxyNetwork $settings.ProxyNetwork | Where-Object { @($_.traefik.routers).Count }) } catch { }
    foreach ($hn in @($new.hostnames)) {
      foreach ($c in @(Find-HostnameClaims -Hostname $hn -Routers $claimRouters -Containers $labelled -OwnService $new.name)) {
        if ($c.level -eq 'error') { $traefik.Issues = @($traefik.Issues) + (New-Issue 'Error' $new.name 'hostnames' "$hn is already routed elsewhere: $($c.detail) Remove or change that definition first, so one configuration owns the hostname.") }
        else { $notes += "$hn`: $($c.detail) Make sure only one Traefik publishes it." }
      }
    }
  }
  $traefikKey = $traefik.RegistryJson + '|' + ((@($traefik.Changes | ForEach-Object { "$($_.File):$($_.Action):$($_.OldContent)" })) -join '|')
  return [pscustomobject]@{
    Op = $op; Summary = $summary; Settings = $settings; Traefik = $traefik; Cloudflare = $cf; New = $new; Previous = $previous
    Notes = @($notes + @(Get-TargetWarnings $settings $new)); TraefikKey = $traefikKey
  }
}

function ConvertTo-PlanView($Plan, [string]$PlanId) {
  $t = $Plan.Traefik
  $cf = $Plan.Cloudflare
  $errors = @($t.Issues | Where-Object { $_.Level -eq 'Error' }).Count + @($cf.Errors).Count
  $changes = @($t.Changes | Where-Object { $_.Action -ne 'unchanged' } | ForEach-Object { [ordered]@{ file = "traefik\dynamic\$($_.File)"; action = $_.Action; diff = @(Get-LineDiff $_.OldContent $_.NewContent) } })
  $cfActions = @($cf.Actions | ForEach-Object { [ordered]@{ id = $_.Id; step = $_.Step; kind = $_.Kind; hostname = $_.Hostname; summary = $_.Summary; detail = $_.Detail; overwrite = $_.Overwrite } })
  $hasWork = ($t.FileChanges -gt 0) -or $t.RegistryChanged -or (@($cfActions | Where-Object { $_.kind -ne 'none' }).Count -gt 0)
  return [ordered]@{
    planId     = $PlanId
    summary    = $Plan.Summary
    notes      = @($Plan.Notes)
    traefik    = [ordered]@{ changes = $changes; issues = @($t.Issues); registryChanged = $t.RegistryChanged; fileChanges = $t.FileChanges }
    cloudflare = [ordered]@{ connected = $cf.Connected; actions = $cfActions; notes = @($cf.Notes); errors = @($cf.Errors); manualSteps = @($cf.ManualSteps) }
    canApply   = ($errors -eq 0 -and $hasWork)
    hasWork    = $hasWork
  }
}

function Invoke-PlanRequest($Body) {
  $plan = Build-ChangePlan $Body
  # Expired plans are dropped; a plan is valid for 15 minutes and can be applied once.
  foreach ($k in @($State.Plans.Keys)) { if (((Get-Date) - $State.Plans[$k].Created).TotalMinutes -gt 15) { $State.Plans.Remove($k) } }
  $id = New-RandomKey 12
  $State.Plans[$id] = [pscustomobject]@{ Created = (Get-Date); Body = ($Body | ConvertTo-Json -Depth 10 -Compress); TraefikKey = $plan.TraefikKey; CfFingerprint = $plan.Cloudflare.Fingerprint }
  return ConvertTo-PlanView $plan $id
}

function Invoke-ApplyRequest($Body) {
  Assert-Confirmed $Body
  $id = [string](Get-Field $Body 'planId' '')
  if (-not $id -or -not $State.Plans.ContainsKey($id)) { Stop-Request 409 'This preview has expired or was already applied. Preview the change again.' }
  $stored = $State.Plans[$id]
  $State.Plans.Remove($id)
  if (((Get-Date) - $stored.Created).TotalMinutes -gt 15) { Stop-Request 409 'This preview has expired. Preview the change again.' }
  # Recompute against the current state and refuse if anything changed since the preview.
  $plan = Build-ChangePlan ($stored.Body | ConvertFrom-Json)
  if ($plan.TraefikKey -ne $stored.TraefikKey -or $plan.Cloudflare.Fingerprint -ne $stored.CfFingerprint) {
    Stop-Request 409 'The configuration or Cloudflare changed since the preview. Preview the change again.'
  }
  $view = ConvertTo-PlanView $plan $id
  if (-not $view.canApply) { Stop-Request 400 'This plan has errors or nothing to change.' }
  $confirmed = @(@(Get-Field $Body 'confirmOverwrites' @()) | ForEach-Object { [string]$_ })
  $needed = @($plan.Cloudflare.Actions | Where-Object { $_.Overwrite } | ForEach-Object { $_.Id })
  $missing = @($needed | Where-Object { $confirmed -notcontains $_ })
  if ($missing.Count -gt 0) { Stop-Request 400 ('Confirm each overwrite of an existing Cloudflare resource: ' + ($missing -join ', ')) }

  $settings = $plan.Settings
  $steps = New-Object System.Collections.ArrayList
  $result = [ordered]@{ ok = $true; steps = $null; backup = ''; recoveryPoint = ''; warnings = @() }
  $result.recoveryPoint = New-ChangeRecoveryPoint $plan.Summary
  $t = $plan.Traefik
  if ($t.FileChanges -gt 0 -or $t.RegistryChanged) {
    if ($t.FileChanges -gt 0) {
      $deep = Test-TraefikDynamicConfig -Settings $settings -Plan $t
      $result.warnings += @($deep.Warnings)
      if (-not $deep.Ok) {
        $null = $steps.Add([ordered]@{ name = 'Validate in a throwaway Traefik container'; status = 'Failed'; message = (@($deep.Errors) -join ' | ') })
        $result.ok = $false; $result.steps = $steps.ToArray()
        Write-Audit 'apply-rejected' "$($plan.Summary): Traefik validation failed"
        return $result
      }
      $null = $steps.Add([ordered]@{ name = 'Validate in a throwaway Traefik container'; status = 'Done'; message = "$(@($deep.Routers).Count) generated router(s) accepted" })
    }
    $applied = Invoke-ServicePlan -Settings $settings -Plan $t
    $result.backup = [string](Split-Path -Leaf ([string]$applied.Backup))
    $null = $steps.Add([ordered]@{ name = 'Write Traefik configuration'; status = 'Done'; message = "Backup $($result.backup)" })
    if ($applied.ReloadWarning) { $result.warnings += $applied.ReloadWarning }
    if ($applied.Reloaded) {
      $wait = Wait-ServiceRouters -Settings $settings -Services $t.Services
      if ($wait.Ok) { $null = $steps.Add([ordered]@{ name = 'Traefik reload'; status = 'Done'; message = 'Every enabled service route is loaded.' }) }
      else { $null = $steps.Add([ordered]@{ name = 'Traefik reload'; status = 'Warning'; message = 'Not loaded yet: ' + ($wait.Missing -join ', ') }) }
    } elseif (-not (Test-ContainerRunning $settings.TraefikContainer)) {
      $null = $steps.Add([ordered]@{ name = 'Traefik reload'; status = 'Warning'; message = 'Traefik is not running; routes load when it starts.' })
    }
  }
  $serviceName = if ($plan.New) { $plan.New.name } else { $plan.Previous.name }
  foreach ($r in @(Invoke-CloudflareServicePlan -Settings $settings -Plan $plan.Cloudflare -ServiceName $serviceName -ConfirmedOverwrites $confirmed)) {
    if ($r.Status -eq 'Unchanged') { continue }
    $null = $steps.Add([ordered]@{ name = $r.Summary; status = $r.Status; message = $r.Message })
    if ($r.Status -eq 'Failed') { $result.ok = $false }
  }
  $result.steps = $steps.ToArray()
  Write-Audit 'apply' ("$($plan.Summary): " + ((@($result.steps | ForEach-Object { "$($_.name)=$($_.status)" })) -join '; '))
  return $result
}

# --- Backups ---------------------------------------------------------------------------------------------------

function Get-BackupData {
  $settings = Get-Settings
  return @(Get-ServiceBackups $settings | Select-Object -First 50 | ForEach-Object {
      [ordered]@{ id = $_.Id; createdAt = $_.CreatedAt; files = @($_.Files); restored = $_.Restored; preRollback = $_.PreRollback }
    })
}

function Get-BackupPreview($Body) {
  $settings = Get-Settings
  $id = [string](Get-Field $Body 'id' '')
  $snap = @(Get-ServiceBackups $settings | Where-Object { $_.Id -eq $id })
  if ($snap.Count -eq 0) { Stop-Request 404 "No backup '$id'." }
  $dir = $snap[0].Path
  $changes = @()
  $current = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $settings.DynamicDir -File -Filter 'svc-*.yml' -ErrorAction SilentlyContinue)) { $current[$f.Name] = [IO.File]::ReadAllText($f.FullName) }
  $saved = @{}
  foreach ($n in $snap[0].Files) { $saved[$n] = [IO.File]::ReadAllText((Join-Path (Join-Path $dir 'dynamic') $n)) }
  foreach ($n in @(@($current.Keys) + @($saved.Keys) | Select-Object -Unique | Sort-Object)) {
    $old = if ($current.ContainsKey($n)) { $current[$n] } else { $null }
    $new = if ($saved.ContainsKey($n)) { $saved[$n] } else { $null }
    if ($old -eq $new) { continue }
    $action = if ($null -eq $old) { 'add' } elseif ($null -eq $new) { 'remove' } else { 'update' }
    $changes += [ordered]@{ file = "traefik\dynamic\$n"; action = $action; diff = @(Get-LineDiff $old $new) }
  }
  $regOld = if (Test-Path -LiteralPath $settings.RegistryPath) { [IO.File]::ReadAllText($settings.RegistryPath) } else { $null }
  $regNew = if (Test-Path -LiteralPath (Join-Path $dir 'services.json')) { [IO.File]::ReadAllText((Join-Path $dir 'services.json')) } else { $null }
  if ($regOld -ne $regNew) { $changes += [ordered]@{ file = 'config\services.json'; action = $(if ($null -eq $regNew) { 'remove' } else { 'update' }); diff = @(Get-LineDiff $regOld $regNew) } }
  return [ordered]@{ id = $id; changes = $changes; note = 'Rollback restores Traefik routes and the service registry only. Cloudflare DNS, tunnel routes and Access apps are not rolled back.' }
}

# --- Portable backups and restore ---------------------------------------------------------------------------------

function Get-AccessEmailsFromBody($Body) {
  $emails = @(@(Get-Field $Body 'accessEmails' @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
  if ($emails.Count -gt 50) { Stop-Request 400 'At most 50 Access emails.' }
  foreach ($e in $emails) { if ($e -notmatch $EmailPattern) { Stop-Request 400 "'$e' is not a valid email address." } }
  return $emails
}

function ConvertTo-CheckReview($Check) {
  $items = @()
  if (-not $Check) { return $items }
  if (-not $Check.Connected) { return @(New-ReviewItem 'validated' 'pending' 'Cloudflare resources not verified' $Check.Message) }
  $map = @{ verified = 'ok'; none = 'info'; missing = 'warning'; mismatch = 'warning'; unknown = 'warning' }
  foreach ($x in @($Check.Account, $Check.Tunnel)) { if ($x) { $items += New-ReviewItem 'validated' $map[$x.state] $(if ($x -eq $Check.Account) { 'Cloudflare account' } else { 'Cloudflare tunnel' }) $x.message } }
  foreach ($d in $Check.Domains) { $items += New-ReviewItem 'validated' $map[$d.state] "Allowed domain $($d.name)" $d.message }
  foreach ($h in $Check.Hostnames) {
    foreach ($x in @($h.dns, $h.access)) { if ($x.state -ne 'none') { $items += New-ReviewItem 'validated' $map[$x.state] "$(if ($x -eq $h.dns) { 'DNS record' } else { 'Access application' }) of $($h.hostname)" $x.message } }
  }
  return $items
}

# What the browser sees of a restore plan.
function ConvertTo-RestoreView($Backup, $Plan, [string]$ImportId) {
  $m = $Backup.Manifest
  $review = New-Object System.Collections.ArrayList
  $add = { param($Stage, $State, $Label, $Message) $null = $review.Add((New-ReviewItem $Stage $State $Label $Message)) }
  $kindText = @{ zip = 'Full backup (.zip)'; json = 'Configuration export (.json)'; 'legacy-services' = 'Service registry from an earlier version' }[$Backup.Kind]
  & $add 'prepared' 'ok' 'Backup read' "$kindText of instance '$($m.sourceStackName)', created $($m.createdAt)$(if ($m.managerVersion) { " by manager $($m.managerVersion)" }); $(@($m.services).Count) service(s)."
  $localCount = @($Plan.Local.Items | Where-Object { $_.action -in @('create', 'update', 'delete') }).Count
  & $add 'prepared' $(if ($localCount) { 'ok' } else { 'info' }) 'Local configuration' $(if ($localCount) { "$localCount change(s) prepared." } else { 'Already matches the backup.' })
  & $add 'validated' 'ok' 'Format and version' "Schema $($m.schemaVersion); this manager ($(Get-ManagerVersion)) reads schema 1 and earlier service registries."
  & $add 'validated' 'ok' 'No credentials in the backup' 'The file was scanned for tokens, keys and secrets.'
  foreach ($w in $Backup.Warnings) { & $add 'validated' 'warning' 'Backup contents' $w }
  $svcErrors = @($Plan.Local.Errors)
  & $add 'validated' $(if ($svcErrors.Count) { 'failed' } else { 'ok' }) 'Configuration checks' $(if ($svcErrors.Count) { $svcErrors -join ' ' } else { 'Instance settings and service definitions are valid.' })
  foreach ($i in @(ConvertTo-CheckReview $Plan.Cloudflare.Check)) { $null = $review.Add($i) }
  & $add 'applied' 'pending' 'Local configuration' $(if ($Plan.Local.CanApply) { 'Waiting for your approval.' } else { 'Nothing to apply.' })
  & $add 'applied' 'pending' 'Cloudflare' $(if ($Plan.Cloudflare.CanApply) { 'Waiting for your separate approval.' } elseif ($Plan.Cloudflare.Message) { $Plan.Cloudflare.Message } else { 'Nothing to change in Cloudflare.' })
  foreach ($a in $Plan.ActionsNeeded) { & $add 'action' 'warning' 'Requires your action' $a }
  foreach ($e in @($Plan.Cloudflare.Errors)) { & $add 'action' 'failed' 'Cloudflare' $e }
  foreach ($c in $Plan.Credentials) { & $add 'action' $(if ($c.present) { 'info' } else { 'warning' }) "$($c.label) ($(if ($c.present) { 'present on this PC' } else { 'missing on this PC' }))" $c.recover }
  $cf = $Plan.Cloudflare
  return [ordered]@{
    importId    = $ImportId
    source      = [ordered]@{ fileName = $Backup.FileName; kind = $Backup.Kind; schemaVersion = $m.schemaVersion; managerVersion = $m.managerVersion; createdAt = $m.createdAt; stackName = $m.sourceStackName; services = @($m.services).Count; sha256 = $Backup.Sha256; installPath = $InstallPath }
    warnings    = @($Backup.Warnings)
    local       = [ordered]@{ items = @($Plan.Local.Items); errors = @($Plan.Local.Errors); canApply = $Plan.Local.CanApply; hasWork = $Plan.Local.HasWork }
    cloudflare  = [ordered]@{
      connected = $cf.Connected; message = $cf.Message; needsLocal = $cf.NeedsLocal; canApply = $cf.CanApply; hasWork = $cf.HasWork
      actions = @($cf.Actions); errors = @($cf.Errors); notes = @($cf.Notes | Select-Object -Unique)
    }
    credentials = @($Plan.Credentials)
    actions     = @($Plan.ActionsNeeded)
    review      = $review.ToArray()
  }
}

function Get-ImportBackup($Body) {
  $recoveryId = [string](Get-Field $Body 'recoveryId' '')
  if ($recoveryId) {
    try { $bytes = Get-RecoveryPointBytes -Settings (Get-Settings) -Id $recoveryId } catch { Stop-Request 404 $_.Exception.Message }
    return [pscustomobject]@{ Bytes = $bytes; FileName = $recoveryId }
  }
  $b64 = [string](Get-Field $Body 'contentBase64' '')
  if (-not $b64) { Stop-Request 400 'Choose a backup file.' }
  try { $bytes = [Convert]::FromBase64String($b64) } catch { Stop-Request 400 'The file could not be read.' }
  $name = ([string](Get-Field $Body 'fileName' 'backup')) -replace '[^A-Za-z0-9._ -]', ''
  return [pscustomobject]@{ Bytes = $bytes; FileName = $name.Substring(0, [Math]::Min(100, $name.Length)) }
}

function Get-RestoreState([string]$ImportId, $Emails) {
  foreach ($k in @($State.Imports.Keys)) { if (((Get-Date) - $State.Imports[$k].Created).TotalMinutes -gt 30) { $State.Imports.Remove($k) } }
  if (-not $ImportId -or -not $State.Imports.ContainsKey($ImportId)) { Stop-Request 409 'This restore preview has expired. Choose the backup file again.' }
  $entry = $State.Imports[$ImportId]
  $backup = Read-ConfigBackup -Bytes $entry.Bytes -FileName $entry.FileName
  $plan = Get-RestorePlan -Settings (Get-Settings) -Backup $backup -SourceRoot $here -AccessEmails $Emails
  return [pscustomobject]@{ Entry = $entry; Backup = $backup; Plan = $plan }
}

# Reads and validates an uploaded backup (or a recovery point) and returns the restore preview. Writes nothing.
function Invoke-ImportPreview($Body) {
  $file = Get-ImportBackup $Body
  $emails = Get-AccessEmailsFromBody $Body
  $backup = Read-ConfigBackup -Bytes $file.Bytes -FileName $file.FileName
  if (@($backup.Errors).Count -gt 0) { Stop-Request 400 (@($backup.Errors) -join ' ') }
  while ($State.Imports.Count -ge 5) { $oldest = @($State.Imports.Keys | Sort-Object { $State.Imports[$_].Created })[0]; $State.Imports.Remove($oldest) }
  $id = New-RandomKey 12
  $State.Imports[$id] = [pscustomobject]@{ Created = (Get-Date); Bytes = $file.Bytes; FileName = $file.FileName; Emails = $emails }
  $plan = Get-RestorePlan -Settings (Get-Settings) -Backup $backup -SourceRoot $here -AccessEmails $emails
  $State.Imports[$id] | Add-Member -NotePropertyName LocalKey -NotePropertyValue $plan.Local.Key
  $State.Imports[$id] | Add-Member -NotePropertyName CfFingerprint -NotePropertyValue $plan.Cloudflare.Fingerprint
  return ConvertTo-RestoreView $backup $plan $id
}

# Applies one part of a previewed restore: 'local' (configuration files, Traefik reload) or 'cloudflare'.
# Each part needs its own confirmation and is refused if the state changed since the preview.
function Invoke-ImportApply($Body) {
  Assert-Confirmed $Body
  $part = [string](Get-Field $Body 'part' '')
  if ($part -notin @('local', 'cloudflare')) { Stop-Request 400 "Unknown restore part '$part'." }
  $importId = [string](Get-Field $Body 'importId' '')
  $emails = Get-AccessEmailsFromBody $Body
  $r = Get-RestoreState $importId $emails
  $entry = $r.Entry
  $settings = Get-Settings
  $steps = @()
  $ok = $true
  if ($part -eq 'local') {
    if ($r.Plan.Local.Key -ne $entry.LocalKey) { Stop-Request 409 'The configuration changed since the preview. Preview the restore again.' }
    if (-not $r.Plan.Local.CanApply) { Stop-Request 400 'The local part has errors or nothing to change.' }
    $recovery = New-ChangeRecoveryPoint "before restore of $($entry.FileName)"
    $res = Invoke-RestoreLocal -Settings $settings -Plan $r.Plan
    $steps = @($res.Steps); $ok = $res.Ok
    Save-RememberedPath
    Write-Audit 'restore-local' "file=$($entry.FileName) ok=$ok recovery=$recovery"
  } else {
    if ($r.Plan.Cloudflare.Fingerprint -ne $entry.CfFingerprint) {
      Stop-Request 409 'Cloudflare changed since the preview. Preview the restore again.'
    }
    if (-not $r.Plan.Cloudflare.CanApply) { Stop-Request 400 $(if ($r.Plan.Cloudflare.NeedsLocal) { 'Apply the local configuration first.' } elseif ($r.Plan.Cloudflare.Message) { $r.Plan.Cloudflare.Message } else { 'The Cloudflare part has errors or nothing to change.' }) }
    $confirmed = @(@(Get-Field $Body 'confirmOverwrites' @()) | ForEach-Object { [string]$_ })
    $missing = @($r.Plan.Cloudflare.Actions | Where-Object { $_.overwrite -and $confirmed -notcontains $_.id } | ForEach-Object { $_.id })
    if ($missing.Count -gt 0) { Stop-Request 400 ('Confirm each overwrite of an existing Cloudflare resource: ' + ($missing -join ', ')) }
    $recovery = New-ChangeRecoveryPoint "before cloudflare restore of $($entry.FileName)"
    $res = Invoke-RestoreCloudflare -Settings $settings -Plan $r.Plan -ConfirmedOverwrites $confirmed
    $steps = @($res.Steps); $ok = $res.Ok
    Write-Audit 'restore-cloudflare' ("file=$($entry.FileName) ok=$ok recovery=$recovery " + ((@($steps | ForEach-Object { "$($_.name)=$($_.status)" })) -join '; '))
  }
  # The next part is previewed against the new state.
  $after = Get-RestoreState $importId $emails
  $entry.LocalKey = $after.Plan.Local.Key
  $entry.CfFingerprint = $after.Plan.Cloudflare.Fingerprint
  $view = ConvertTo-RestoreView $after.Backup $after.Plan $importId
  $view['result'] = [ordered]@{ part = $part; ok = $ok; steps = $steps; recoveryPoint = $recovery }
  return $view
}

function Get-BackupsData {
  $settings = Get-Settings
  return [ordered]@{
    installed      = (Test-Installed)
    backups        = @(Get-BackupData)
    recoveryPoints = @(Get-RecoveryPoints -Settings $settings)
    credentials    = @(Get-CredentialInventory $settings)
  }
}

# --- Public Traefik dashboard ---------------------------------------------------------------------------------------

function Get-DashboardData {
  $settings = Get-Settings
  $dash = Read-DashboardConfig -Settings $settings
  $cf = Read-CloudflareConfig -Settings $settings
  $token = Get-CloudflareApiTokenInfo -Settings $settings
  $suggestZone = if ($dash.zoneId) { $dash.zoneId } elseif (@($cf.domains).Count -gt 0) { @($cf.domains)[0].id } else { '' }
  return [ordered]@{
    installed    = (Test-Installed)
    localUrl     = "http://127.0.0.1:$($settings.DashboardPort)/dashboard/"
    enabled      = $dash.enabled
    hostname     = $dash.hostname
    publicUrl    = $(if ($dash.enabled -and $dash.hostname) { "https://$($dash.hostname)/dashboard/" } else { '' })
    # Follows the instance name until the user edits it (or it was published / restored with another name).
    subdomain    = $(if ($dash.enabled -and $dash.subdomain) { $dash.subdomain } elseif ($dash.subdomainCustom -and $dash.subdomain) { $dash.subdomain } else { Get-DashboardDefaultSubdomain $settings })
    subdomainCustom = [bool]($dash.subdomainCustom -and $dash.subdomain)
    defaultSubdomain = Get-DashboardDefaultSubdomain $settings
    publish      = [bool]$dash.publish
    configured   = (Test-Path -LiteralPath (Join-Path $InstallPath 'config\dashboard.json'))
    zoneId       = $suggestZone
    accessEmails = @($dash.accessEmails)
    contactEmail = (Read-SetupDraft).contactEmail
    domains      = @($cf.domains)
    cloudflareReady = [bool]($token.Stored -and $token.Readable -and $cf.accountId -and $cf.tunnelId)
    tunnelName   = $cf.tunnelName
  }
}

function ConvertTo-DashboardPlanView($Plan, [string]$PlanId) {
  $cf = $Plan.Cloudflare
  $changes = @()
  if ($Plan.FileAction -ne 'unchanged') { $changes += [ordered]@{ file = "traefik\dynamic\$(Get-DashboardRouteFile)"; action = $Plan.FileAction; diff = @(Get-LineDiff $Plan.OldContent $Plan.NewContent) } }
  $cfActions = @(); if ($cf) { $cfActions = @($cf.Actions | ForEach-Object { [ordered]@{ id = $_.Id; step = $_.Step; kind = $_.Kind; hostname = $_.Hostname; summary = $_.Summary; detail = $_.Detail; overwrite = $_.Overwrite } }) }
  $hasWork = $changes.Count -gt 0 -or @($cfActions | Where-Object { $_.kind -ne 'none' }).Count -gt 0
  $errors = @($Plan.Errors)
  $review = @(
    New-ReviewItem 'prepared' 'ok' $(if ($Plan.Disable) { 'Remove the public dashboard' } else { 'Public dashboard' }) $(if ($Plan.Hostname) { "https://$($Plan.Hostname)/dashboard/ (and /api), through tunnel '$((Read-CloudflareConfig -Settings (Get-Settings)).tunnelName)'." } else { '' })
    New-ReviewItem 'validated' $(if ($errors.Count) { 'failed' } else { 'ok' }) 'Checks' $(if ($errors.Count) { $errors -join ' ' } else { 'Hostname, allowed domain and Cloudflare state checked.' })
  )
  if (-not $Plan.Disable) {
    $access = @($cfActions | Where-Object { $_.step -eq 'access' })
    $review += New-ReviewItem 'validated' $(if ($access.Count -and -not $errors.Count) { 'ok' } else { 'failed' }) 'Cloudflare Access (required)' $(if ($access.Count) { $access[0].summary } else { 'Access cannot be ensured, so nothing will be published (fail closed).' })
  }
  $review += New-ReviewItem 'applied' 'pending' 'Changes' $(if ($hasWork -and -not $errors.Count) { 'Waiting for your confirmation.' } elseif (-not $hasWork) { 'Nothing to change.' } else { 'Blocked.' })
  return [ordered]@{
    planId = $PlanId; summary = $(if ($Plan.Disable) { "Remove the public dashboard $($Plan.Hostname)" } else { "Publish the Traefik dashboard as $($Plan.Hostname)" })
    hostname = $Plan.Hostname; url = $(if ($Plan.Hostname) { "https://$($Plan.Hostname)/dashboard/" } else { '' })
    notes = @($(if (-not $Plan.Disable) { 'Order: Cloudflare Access first; the Traefik route, tunnel route and DNS record are only created once Access protects the hostname.' }))
    traefik = [ordered]@{ changes = $changes; issues = @(); registryChanged = $false; fileChanges = $changes.Count }
    cloudflare = [ordered]@{ connected = [bool]($cf -and $cf.Connected); actions = $cfActions; notes = @($(if ($cf) { $cf.Notes })); errors = $errors; manualSteps = @() }
    canApply = ($errors.Count -eq 0 -and $hasWork); hasWork = $hasWork; review = $review
  }
}

# Dashboard choices made during setup (before or after installation). Nothing in Traefik or Cloudflare changes.
function Save-DashboardSettingsRequest($Body) {
  $settings = Get-Settings
  $cfg = Read-DashboardConfig -Settings $settings
  $cf = Read-CloudflareConfig -Settings $settings
  $custom = [bool](Get-Field $Body 'subdomainCustom' $false)
  $sub = ([string](Get-Field $Body 'subdomain' '')).Trim().ToLowerInvariant().TrimEnd('.')
  if ($custom -and -not (Test-DashboardSubdomain $sub)) { Stop-Request 400 "'$sub' is not a valid subdomain (letters, digits and dashes)." }
  $zoneId = [string](Get-Field $Body 'zoneId' '')
  $zone = @($cf.domains | Where-Object { $_.id -eq $zoneId })
  if ($zoneId -and $zone.Count -eq 0) { Stop-Request 400 'Choose one of the allowed Cloudflare domains.' }
  $emails = Get-AccessEmailsFromBody $Body
  if ($cfg.enabled -and (($custom -and $sub -ne $cfg.subdomain) -or ($zoneId -and $zoneId -ne $cfg.zoneId))) { Stop-Request 409 "The dashboard is published as $($cfg.hostname). Remove it first to change its name." }
  if (-not $cfg.enabled) {
    $cfg.subdomainCustom = $custom
    $cfg.subdomain = $(if ($custom) { $sub } else { '' })
    if ($zone.Count -gt 0) { $cfg.zoneId = $zone[0].id; $cfg.zoneName = $zone[0].name }
  }
  $cfg.accessEmails = @($emails)
  $cfg.publish = [bool](Get-Field $Body 'publish' $cfg.publish)
  Save-DashboardConfig -Settings $settings -Config $cfg
  Save-RememberedPath
  Write-Audit 'dashboard-settings' "publish=$($cfg.publish) custom=$custom"
  return Get-DashboardData
}

function Get-DashboardPlanFromBody($Body) {
  $settings = Get-Settings
  $registry = Read-ServiceRegistry -Settings $settings
  $disable = [bool](Get-Field $Body 'disable' $false)
  $emails = Get-AccessEmailsFromBody $Body
  # Before installation the chosen existing tunnel is only in the setup draft; plan against it (read-only).
  $cfConfig = Read-CloudflareConfig -Settings $settings
  $draft = Read-SetupDraft
  if (-not (Test-Installed) -and -not $cfConfig.tunnelId -and $draft.deployment.mode -eq 'tunnel' -and $draft.deployment.tunnelChoice -eq 'existing' -and $draft.deployment.tunnelId) {
    $cfConfig.tunnelId = $draft.deployment.tunnelId; $cfConfig.tunnelName = $draft.deployment.tunnelName
  }
  return Get-DashboardPlan -Settings $settings -Subdomain ([string](Get-Field $Body 'subdomain' '')) -ZoneId ([string](Get-Field $Body 'zoneId' '')) -AccessEmails $emails -Disable:$disable -Services @($registry.services) -CloudflareConfig $cfConfig
}

function Invoke-DashboardPlanRequest($Body) {
  $plan = Get-DashboardPlanFromBody $Body
  foreach ($k in @($State.Plans.Keys)) { if (((Get-Date) - $State.Plans[$k].Created).TotalMinutes -gt 15) { $State.Plans.Remove($k) } }
  $id = New-RandomKey 12
  $State.Plans[$id] = [pscustomobject]@{ Created = (Get-Date); Kind = 'dashboard'; Body = ($Body | ConvertTo-Json -Depth 6 -Compress); Key = $plan.Key }
  return ConvertTo-DashboardPlanView $plan $id
}

function Invoke-DashboardApplyRequest($Body) {
  Assert-Confirmed $Body
  Assert-Installed
  $id = [string](Get-Field $Body 'planId' '')
  if (-not $id -or -not $State.Plans.ContainsKey($id) -or -not $State.Plans[$id].PSObject.Properties['Kind']) { Stop-Request 409 'This preview has expired or was already applied. Preview again.' }
  $stored = $State.Plans[$id]
  $State.Plans.Remove($id)
  if (((Get-Date) - $stored.Created).TotalMinutes -gt 15) { Stop-Request 409 'This preview has expired. Preview again.' }
  $plan = Get-DashboardPlanFromBody ($stored.Body | ConvertFrom-Json)
  if ($plan.Key -ne $stored.Key) { Stop-Request 409 'Traefik or Cloudflare changed since the preview. Preview again.' }
  $view = ConvertTo-DashboardPlanView $plan $id
  if (-not $view.canApply) { Stop-Request 400 'This plan has errors or nothing to change.' }
  $confirmed = @(@(Get-Field $Body 'confirmOverwrites' @()) | ForEach-Object { [string]$_ })
  $missing = @($plan.Cloudflare.Actions | Where-Object { $_.Overwrite -and $confirmed -notcontains $_.Id } | ForEach-Object { $_.Id })
  if ($missing.Count -gt 0) { Stop-Request 400 ('Confirm each overwrite of an existing Cloudflare resource: ' + ($missing -join ', ')) }
  $recovery = New-ChangeRecoveryPoint $(if ($plan.Disable) { 'before removing the public dashboard' } else { 'before publishing the dashboard' })
  $settings = Get-Settings
  $r = Invoke-DashboardPlan -Settings $settings -Plan $plan -ConfirmedOverwrites $confirmed
  Write-Audit 'dashboard' ("$($view.summary): ok=$($r.Ok) failClosed=$($r.FailClosed) " + ((@($r.Steps | ForEach-Object { "$($_.name)=$($_.status)" })) -join '; '))
  $review = @($r.Steps | ForEach-Object { New-ReviewItem 'applied' $(@{ Done = 'ok'; Unchanged = 'info'; Warning = 'warning'; Skipped = 'warning'; 'Not run' = 'info'; Failed = 'failed' }[$_.status]) $_.name $_.message })
  if ($r.FailClosed) { $review += New-ReviewItem 'action' 'failed' 'Nothing was published (fail closed)' 'Fix the Cloudflare Access problem above, then preview again. The local dashboard keeps working.' }
  return [ordered]@{
    ok = $r.Ok; failClosed = $r.FailClosed; steps = @($r.Steps); recoveryPoint = $recovery; warnings = @()
    url = $(if (-not $plan.Disable -and $r.Ok) { "https://$($plan.Hostname)/dashboard/" } else { '' }); review = $review
  }
}

function Invoke-DashboardVerifyRequest($Body) {
  Assert-Installed
  $v = Get-DashboardVerification -Settings (Get-Settings) -Public:([bool](Get-Field $Body 'public' $false))
  $map = @{ ok = 'ok'; failed = 'failed'; warning = 'warning'; skipped = 'info' }
  return [ordered]@{
    hostname = $v.Hostname; localUrl = $v.LocalUrl; publicUrl = $v.PublicUrl; checks = @($v.Checks)
    review = @($v.Checks | ForEach-Object { New-ReviewItem $(if ($_.state -eq 'failed') { 'action' } else { 'verified' }) $map[$_.state] $_.label $_.message })
  }
}

# --- Cloudflare ------------------------------------------------------------------------------------------------

function Assert-CloudflareReady([switch]$NeedTunnel) {
  $settings = Get-Settings
  if (-not (Get-CloudflareApiTokenInfo -Settings $settings).Stored) { Stop-Request 409 'Save a Cloudflare API token first.' }
  $config = Read-CloudflareConfig -Settings $settings
  if (-not $config.accountId) { Stop-Request 409 'Select a Cloudflare account first.' }
  if ($NeedTunnel -and -not $config.tunnelId) { Stop-Request 409 'Select or create a tunnel first.' }
  return $config
}

function Get-CloudflareData {
  $settings = Get-Settings
  $config = Read-CloudflareConfig -Settings $settings
  $managed = @()
  foreach ($p in $config.managed.PSObject.Properties) { $managed += [ordered]@{ hostname = $p.Name; service = $p.Value.service; dns = [bool]$p.Value.dnsRecordId; access = [bool]$p.Value.accessAppId } }
  return [ordered]@{
    token     = Get-CloudflareApiTokenInfo -Settings $settings
    config    = [ordered]@{ accountId = $config.accountId; accountName = $config.accountName; tunnelId = $config.tunnelId; tunnelName = $config.tunnelName; domains = @($config.domains) }
    managed   = $managed
    connector = [ordered]@{ tokenFile = (Test-TunnelTokenFile $settings); container = $settings.CloudflaredContainer; running = $(if (Test-Installed) { Test-ContainerRunning $settings.CloudflaredContainer } else { $false }) }
    apiBase   = Get-CloudflareApiBase
  }
}

# What the browser sees of a discovery run (never the token).
function ConvertTo-DiscoveryView($Discovery, $Config) {
  $allowed = @($Config.domains | ForEach-Object { $_.id })
  return [ordered]@{
    valid       = [bool]$Discovery.Valid
    status      = $Discovery.Status
    message     = $Discovery.Message
    accounts    = @($Discovery.Accounts)
    accountId   = $Discovery.AccountId
    accountName = $Discovery.AccountName
    zones       = @($Discovery.Zones | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; status = $_.status; accountId = $_.accountId; dns = $_.dns; allowed = ($allowed -contains $_.id) } })
    tunnels     = @($Discovery.Tunnels)
    permissions = @($Discovery.Permissions)
    domains     = @($Config.domains)
    profileEmail = $(if ($Discovery.PSObject.Properties['ProfileEmail']) { $Discovery.ProfileEmail } else { '' })
  }
}

# Verifies a pasted token, then stores it (DPAPI) and records what it can reach. Allowed before installation: the
# token goes to secrets\ in the install folder, which is created if needed. Nothing in Cloudflare is changed.
function Save-TokenRequest($Body) {
  $settings = Get-Settings
  $token = ([string](Get-Field $Body 'token' '')).Trim()
  if (-not (Test-CloudflareApiToken $token)) { Stop-Request 400 'That does not look like a Cloudflare API token (it should be a long string of letters, digits, - and _).' }
  $info = Get-CloudflareApiTokenInfo -Settings $settings
  if ($info.Stored -and -not [bool](Get-Field $Body 'confirmReplace' $false)) { Stop-Request 409 'A token is already stored. Confirm that you want to replace it.' @{ needsConfirm = 'replace' } }
  $config = Read-CloudflareConfig -Settings $settings
  $discovery = Get-CloudflareDiscovery -Settings $settings -Token $token -AccountId $config.accountId
  if (-not $discovery.Valid) { $token = $null; Stop-Request 400 ('The token was not saved. ' + $discovery.Message) }
  Save-CloudflareApiToken -Settings $settings -Token $token
  $token = $null
  Save-RememberedPath
  if ($discovery.AccountId) { $config.accountId = $discovery.AccountId; $config.accountName = $discovery.AccountName }
  # Keep allowed domains the new token can still see; with exactly one visible domain, allow it automatically.
  $visible = @($discovery.Zones | ForEach-Object { $_.id })
  $config.domains = @($config.domains | Where-Object { $visible -contains $_.id })
  if (@($config.domains).Count -eq 0 -and @($discovery.Zones).Count -eq 1) {
    $z = $discovery.Zones[0]
    $config.domains = @([pscustomobject][ordered]@{ id = $z.id; name = $z.name; accountId = $z.accountId })
  }
  Save-CloudflareConfig -Settings $settings -Config $config
  Write-Audit 'cloudflare-token-saved' "accounts=$(@($discovery.Accounts).Count) zones=$(@($discovery.Zones).Count) allowed=$(@($config.domains).Count)"
  $view = ConvertTo-DiscoveryView $discovery $config
  $view['saved'] = $true
  return $view
}

function Get-DiscoveryRequest {
  $settings = Get-Settings
  if (-not (Get-CloudflareApiTokenInfo -Settings $settings).Stored) { Stop-Request 409 'Save a Cloudflare API token first.' }
  $config = Read-CloudflareConfig -Settings $settings
  $discovery = Get-CloudflareDiscovery -Settings $settings -AccountId $config.accountId -ZoneIds @($config.domains | ForEach-Object { $_.id })
  return ConvertTo-DiscoveryView $discovery $config
}

# The application-level allowlist: services can only be published under these domains.
function Set-DomainsRequest($Body) {
  $settings = Get-Settings
  if (-not (Get-CloudflareApiTokenInfo -Settings $settings).Stored) { Stop-Request 409 'Save a Cloudflare API token first.' }
  $ids = @(@(Get-Field $Body 'zoneIds' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
  foreach ($id in $ids) { if (-not (Test-CloudflareId $id)) { Stop-Request 400 "Invalid zone id '$id'." } }
  $zones = @(Invoke-CloudflareApi -Settings $settings -Path '/zones' -All)
  $selected = @()
  foreach ($id in $ids) {
    $z = @($zones | Where-Object { $_.id -eq $id })
    if ($z.Count -eq 0) { Stop-Request 400 "The API token cannot see zone '$id'." }
    $acct = ''; if ($z[0].PSObject.Properties['account'] -and $z[0].account) { $acct = [string]$z[0].account.id }
    $selected += [pscustomobject][ordered]@{ id = [string]$z[0].id; name = [string]$z[0].name; accountId = $acct }
  }
  $config = Read-CloudflareConfig -Settings $settings
  $config.domains = $selected
  Save-CloudflareConfig -Settings $settings -Config $config
  Write-Audit 'cloudflare-domains' (($selected | ForEach-Object { $_.name }) -join ',')
  return [ordered]@{ domains = @($selected) }
}

# --- Setup wizard ----------------------------------------------------------------------------------------------

$DeploymentModes = @(
  [ordered]@{ id = 'tunnel'; supported = $true; title = 'Cloudflare Tunnel'; detail = 'Publishes apps through an outbound tunnel from this PC. No router ports, no public IP needed. Cloudflare provides HTTPS.' }
  [ordered]@{ id = 'local'; supported = $true; title = 'Local only'; detail = 'Traefik on this PC only (127.0.0.1). Nothing is published and Cloudflare is not needed. You can add a tunnel later.' }
  [ordered]@{ id = 'public-ip'; supported = $false; title = 'Public IP with port forwarding'; detail = 'Not supported by this version: Traefik only listens on 127.0.0.1 and has no HTTPS entry point or certificate resolver. Use Cloudflare Tunnel instead.' }
)
$TlsInfo = [ordered]@{
  letsEncryptSupported = $false
  detail = "Let's Encrypt is not available in this version and no ACME email is needed. With Cloudflare Tunnel, Cloudflare issues and renews the HTTPS certificates for your hostnames at its edge; the tunnel itself is encrypted. In local-only mode Traefik serves plain HTTP on 127.0.0.1."
}

function Get-SetupData {
  $settings = Get-Settings
  $draft = Read-SetupDraft
  $token = Get-CloudflareApiTokenInfo -Settings $settings
  $cfConfig = Read-CloudflareConfig -Settings $settings
  $installed = Test-Installed
  $mode = $draft.deployment.mode
  if ($installed -and -not $mode) { $mode = $(if (Test-TunnelTokenFile $settings) { 'tunnel' } else { 'local' }) }
  return [ordered]@{
    installPath    = $InstallPath
    installed      = $installed
    sourcePath     = $here
    canInstall     = (Test-Path -LiteralPath (Join-Path $here 'install.ps1'))
    canChangePath  = -not $installed
    settingsSource = Get-SettingsSource
    settings       = ConvertTo-InstanceValues $settings
    deployment     = [ordered]@{ mode = $mode; tunnelChoice = $draft.deployment.tunnelChoice; tunnelId = $draft.deployment.tunnelId; tunnelName = $draft.deployment.tunnelName; newTunnelName = $draft.deployment.newTunnelName }
    installedAt    = $draft.installedAt
    contactEmail   = $draft.contactEmail
    defaultInstallPath = (Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy')
    modes          = $DeploymentModes
    tls            = $TlsInfo
    cloudflare     = [ordered]@{
      tokenStored = $token.Stored; tokenReadable = $token.Readable; tokenSavedAt = $token.SavedAt
      accountId = $cfConfig.accountId; accountName = $cfConfig.accountName; tunnelId = $cfConfig.tunnelId; tunnelName = $cfConfig.tunnelName
      domains = @($cfConfig.domains)
      tokenLink = Get-CloudflareTokenTemplateUrl; tokenLinkWithAccess = Get-CloudflareTokenTemplateUrl -IncludeAccess
      permissions = @(Get-CloudflareTokenPermissions | ForEach-Object { [ordered]@{ id = $_.Id; label = $_.Label; optional = $_.Optional; purpose = $_.Purpose } })
    }
  }
}

function Assert-NotInstalled([string]$What) {
  if (Test-Installed) { Stop-Request 409 "$What cannot be changed here after installation. Edit $InstallPath\.env by hand (and re-run the installer), or install a second instance into another folder." }
}

# Settings from a request body: only the instance keys, as plain strings.
function Get-SettingsFromBody($Body) {
  $raw = Get-Field $Body 'settings' $null
  if ($null -eq $raw) { Stop-Request 400 'Missing settings.' }
  $values = Read-DotEnv (Join-Path $here '.env.example')
  foreach ($k in @('STACK_NAME', 'TRAEFIK_HTTP_PORT', 'TRAEFIK_DASHBOARD_PORT', 'PROXY_NETWORK', 'TUNNEL_SUBNET', 'TUNNEL_IP_RANGE', 'CLOUDFLARED_IP')) {
    $v = ([string](Get-Field $raw $k '')).Trim()
    if (-not $v) { Stop-Request 400 "$k is required." }
    if ($v.Length -gt 64 -or $v -notmatch '^[A-Za-z0-9_./-]+$') { Stop-Request 400 "$k contains characters that are not allowed." }
    $values[$k] = $v
  }
  foreach ($k in @('TRAEFIK_HTTP_PORT', 'TRAEFIK_DASHBOARD_PORT')) { if ($values[$k] -notmatch '^\d{2,5}$') { Stop-Request 400 "$k must be a number." } }
  try { $settings = ConvertTo-StackSettings -InstallPath $InstallPath -Values $values } catch { Stop-Request 400 $_.Exception.Message }
  $errors = @(Test-StackSettings $settings)
  if ($errors.Count -gt 0) { Stop-Request 400 ($errors -join ' ') }
  return $settings
}

function Save-SettingsRequest($Body) {
  Assert-NotInstalled 'The instance settings'
  $settings = Get-SettingsFromBody $Body
  $draft = Read-SetupDraft
  $keep = Get-EnvValues $settings
  $draft.settings = [pscustomobject]$keep
  Save-SetupDraft $draft
  Write-Audit 'setup-settings' (($draft.settings.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ')
  return [ordered]@{ settings = ConvertTo-InstanceValues $settings; conflicts = @(Get-StackConflicts -Settings $settings) }
}

# Moves the install folder before anything is installed. Files the wizard already wrote (API token, Cloudflare
# selections, setup draft) move along; an existing installation at the new path is managed as it is.
function Set-InstallPathRequest($Body) {
  Assert-NotInstalled 'The install folder'
  $path = ([string](Get-Field $Body 'path' '')).Trim()
  if ($path -notmatch '^[A-Za-z]:\\[^<>:"|?*]+$') { Stop-Request 400 'Enter a full local path such as C:\Users\you\traefik-proxy or D:\proxy.' }
  try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { Stop-Request 400 'That is not a valid folder path.' }
  if ($full -match '^[A-Za-z]:$') { Stop-Request 400 'Choose a folder, not the root of a drive.' }
  if ($env:windir -and $full.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase)) { Stop-Request 400 'Choose a folder outside the Windows directory.' }
  if ($full -eq $InstallPath) { return Get-SetupData }
  $moves = @('secrets\cloudflare_api.dpapi', 'config\cloudflare.json', 'config\setup.json') | Where-Object { Test-Path -LiteralPath (Join-Path $InstallPath $_) }
  $targetInstalled = Test-Path -LiteralPath (Join-Path $full 'compose.yaml')
  if (-not $targetInstalled) {
    foreach ($rel in $moves) { if (Test-Path -LiteralPath (Join-Path $full $rel)) { Stop-Request 409 "$full already contains $rel. Choose another folder." } }
  }
  if (-not $targetInstalled) {
    foreach ($rel in $moves) {
      $to = Join-Path $full $rel
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
      Move-Item -LiteralPath (Join-Path $InstallPath $rel) -Destination $to
      if ($rel -like 'secrets\*') { Set-SecretFileAcl $to }
    }
    foreach ($dir in @('secrets', 'config', 'logs', '')) {
      $d = Join-Path $InstallPath $dir
      if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) { Remove-Item -LiteralPath $d -Force }
    }
  }
  $old = $InstallPath
  $script:InstallPath = $full
  Save-RememberedPath
  Write-Audit 'setup-path' "from=$old to=$full moved=$(@($moves).Count) existingInstallation=$targetInstalled"
  return Get-SetupData
}

function Set-DeploymentRequest($Body) {
  Assert-NotInstalled 'The deployment method'
  $mode = [string](Get-Field $Body 'mode' '')
  $def = @($DeploymentModes | Where-Object { $_.id -eq $mode })
  if ($def.Count -eq 0) { Stop-Request 400 "Unknown deployment method '$mode'." }
  if (-not $def[0].supported) { Stop-Request 400 $def[0].detail }
  $draft = Read-SetupDraft
  $d = $draft.deployment
  $d.mode = $mode
  $d.tunnelChoice = ''; $d.tunnelId = ''; $d.tunnelName = ''; $d.newTunnelName = ''
  if ($mode -eq 'tunnel') {
    $config = Assert-CloudflareReady
    $settings = Get-Settings
    $choice = [string](Get-Field $Body 'tunnelChoice' '')
    if ($choice -eq 'existing') {
      $id = [string](Get-Field $Body 'tunnelId' '')
      if (-not (Test-CloudflareId $id)) { Stop-Request 400 'Choose a tunnel.' }
      $t = @(Get-CloudflareTunnels -Settings $settings -AccountId $config.accountId | Where-Object { $_.id -eq $id })
      if ($t.Count -eq 0) { Stop-Request 400 'That tunnel does not exist in the selected account.' }
      if (-not $t[0].remotelyManaged) { Stop-Request 400 "Tunnel '$($t[0].name)' is locally managed (config file). Only dashboard/API-managed tunnels can be automated; create a new tunnel instead." }
      $d.tunnelChoice = 'existing'; $d.tunnelId = $id; $d.tunnelName = [string]$t[0].name
    } elseif ($choice -eq 'new') {
      $name = ([string](Get-Field $Body 'newTunnelName' '')).Trim()
      if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { Stop-Request 400 'Tunnel name: use letters, digits, dot, dash or underscore (max 63).' }
      if (@(Get-CloudflareTunnels -Settings $settings -AccountId $config.accountId | Where-Object { $_.name -eq $name }).Count -gt 0) { Stop-Request 400 "A tunnel named '$name' already exists; choose it as an existing tunnel instead." }
      $d.tunnelChoice = 'new'; $d.newTunnelName = $name
    } else { Stop-Request 400 'Choose an existing tunnel or name a new one.' }
  }
  Save-SetupDraft $draft
  Write-Audit 'setup-deployment' "mode=$mode tunnel=$($d.tunnelChoice) $($d.tunnelName)$($d.newTunnelName)"
  return Get-SetupData
}

# Everything the installation would do, and what blocks it. Read-only (the installer runs with -DryRun).
function Get-InstallPlan([switch]$NoDryRun) {
  $settings = Get-Settings
  $draft = Read-SetupDraft
  $mode = $draft.deployment.mode
  $installed = Test-Installed
  $blockers = @(); $warnings = @(); $steps = @()
  $docker = Get-DockerStatus
  if (-not ($docker.CliFound -and $docker.EngineRunning -and $docker.OsType -eq 'linux' -and $docker.ComposeOk)) { $blockers += 'Docker Desktop is not ready (see the Docker Desktop step).' }
  if (-not (Test-Path -LiteralPath (Join-Path $here 'install.ps1'))) { $blockers += 'install.ps1 is missing next to webui.ps1.' }
  if (-not $mode) { $blockers += 'Choose a deployment method.' }
  $conflicts = @()
  if (-not $installed) {
    $conflicts = @(Get-StackConflicts -Settings $settings)
    foreach ($c in $conflicts) { if ($c.Level -eq 'error') { $blockers += $c.Message } elseif ($c.Level -eq 'warning') { $warnings += $c.Message } }
  }
  $config = Read-CloudflareConfig -Settings $settings
  $tunnelLabel = ''
  if ($mode -eq 'tunnel') {
    $token = Get-CloudflareApiTokenInfo -Settings $settings
    if (-not ($token.Stored -and $token.Readable)) { $blockers += 'Tunnel mode needs the Cloudflare API token (Connect Cloudflare).' }
    if (-not $config.accountId) { $blockers += 'Choose the Cloudflare account.' }
    if (@($config.domains).Count -eq 0) { $warnings += 'No allowed domain is selected yet; services cannot be published until you choose one.' }
    $choice = $draft.deployment.tunnelChoice
    if ($choice -eq 'existing') {
      $tunnelLabel = $draft.deployment.tunnelName
      $other = Find-ConnectorForTunnel -Settings $settings -TunnelId $draft.deployment.tunnelId
      if ($other) { $blockers += "Container '$other' already runs a connector for tunnel '$tunnelLabel'. Use a separate tunnel for this instance." }
    } elseif ($choice -eq 'new') { $tunnelLabel = $draft.deployment.newTunnelName }
    else { $blockers += 'Choose the tunnel (existing or new).' }
  }

  $envPath = Join-Path $InstallPath '.env'
  if (Test-Path -LiteralPath $envPath) { $steps += [ordered]@{ kind = 'local'; text = "Keep the existing $envPath." } }
  else {
    $v = ConvertTo-InstanceValues $settings
    $steps += [ordered]@{ kind = 'local'; text = "Write $envPath (instance '$($v.STACK_NAME)', ports 127.0.0.1:$($v.TRAEFIK_HTTP_PORT)/$($v.TRAEFIK_DASHBOARD_PORT), network '$($v.PROXY_NETWORK)', tunnel subnet $($v.TUNNEL_SUBNET))." }
  }
  if ($mode -eq 'tunnel' -and $draft.deployment.tunnelChoice -eq 'new') {
    $steps += [ordered]@{ kind = 'cloudflare'; text = "Create the Cloudflare tunnel '$tunnelLabel' in account '$($config.accountName)' (remotely managed). No DNS record or route is created yet." }
  }
  if ($mode -eq 'tunnel') {
    $steps += [ordered]@{ kind = 'local'; text = "Download the connector token of tunnel '$tunnelLabel' into secrets\cloudflare_tunnel_token (read-only API call)." }
  }
  $containers = "$($settings.TraefikContainer), $($settings.SocketProxyContainer)"
  if ($mode -eq 'tunnel') { $containers += ", $($settings.CloudflaredContainer)" }
  $steps += [ordered]@{ kind = 'docker'; text = "Run install.ps1 -Start$(if ($mode -eq 'tunnel') { ' -EnableTunnel' }): copy the stack files, create the Docker network '$($settings.ProxyNetwork)' if it does not exist, and start this instance's containers only ($containers)." }

  $lines = @()
  $dryExit = $null
  $composeOk = $null
  $composeLines = @()
  if (-not $NoDryRun -and (Test-Path -LiteralPath (Join-Path $here 'install.ps1')) -and $docker.EngineRunning) {
    $installArgs = @('-InstallPath', $InstallPath, '-DryRun')
    $tmp = $null
    $envFile = $envPath
    if (-not (Test-Path -LiteralPath $envPath)) {
      $tmp = Join-Path ([IO.Path]::GetTempPath()) ("tpx-draft-{0}.env" -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
      [IO.File]::WriteAllText($tmp, (New-DotEnvContent ([IO.File]::ReadAllText((Join-Path $here '.env.example'))) (Get-EnvValues $settings)))
      $installArgs += @('-EnvFile', $tmp)
      $envFile = $tmp
    }
    try {
      $r = Invoke-PowerShellFile (Join-Path $here 'install.ps1') $installArgs
      $lines = $r.Lines; $dryExit = $r.ExitCode
      # Compose syntax and variable check of the file that will be installed (offline: docker compose config).
      $composeFile = if ($installed) { Join-Path $InstallPath 'compose.yaml' } else { Join-Path $here 'compose.yaml' }
      $projectDir = if (Test-Path -LiteralPath $InstallPath) { $InstallPath } else { $here }
      $ccArgs = @('compose', '-f', $composeFile, '--project-directory', $projectDir, '--env-file', $envFile)
      if ($mode -eq 'tunnel') { $ccArgs += @('--profile', 'tunnel') }
      $cc = Invoke-Docker @($ccArgs + @('config', '--quiet'))
      $composeOk = ($cc.ExitCode -eq 0)
      $composeLines = @(ConvertTo-RedactedText @($cc.Output))
    } finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
  }
  $keyText = (ConvertTo-Json -Compress -Depth 5 -InputObject @((ConvertTo-InstanceValues $settings), $draft.deployment, $InstallPath, @($config.domains | ForEach-Object { $_.id }), $config.accountId))
  $sha = [Security.Cryptography.SHA256]::Create()
  $planKey = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyText))).Replace('-', '').Substring(0, 32)

  # Readable review: what is prepared, what was validated, and what still needs the user.
  $review = New-Object System.Collections.ArrayList
  $add = { param($Stage, $State, $Label, $Message) $null = $review.Add((New-ReviewItem $Stage $State $Label $Message)) }
  $v = ConvertTo-InstanceValues $settings
  & $add 'prepared' $(if ((Get-SettingsSource) -eq 'defaults') { 'info' } else { 'ok' }) 'Instance settings' "'$($v.STACK_NAME)', ports 127.0.0.1:$($v.TRAEFIK_HTTP_PORT)/$($v.TRAEFIK_DASHBOARD_PORT), network '$($v.PROXY_NETWORK)', tunnel subnet $($v.TUNNEL_SUBNET)$(if ((Get-SettingsSource) -eq 'defaults') { ' (defaults: not saved yet)' })."
  & $add 'prepared' $(if ($mode) { 'ok' } else { 'failed' }) 'Deployment method' $(if ($mode -eq 'tunnel') { "Cloudflare Tunnel$(if ($tunnelLabel) { ": $(if ($draft.deployment.tunnelChoice -eq 'new') { "new tunnel '$tunnelLabel', created when you confirm" } else { "existing tunnel '$tunnelLabel'" })" })" } elseif ($mode) { 'Local only (nothing is published).' } else { 'Not chosen yet (step 4).' })
  & $add 'validated' $(if ($docker.CliFound -and $docker.EngineRunning -and $docker.OsType -eq 'linux' -and $docker.ComposeOk) { 'ok' } else { 'failed' }) 'Docker Desktop' $(if ($docker.EngineRunning) { "Engine $($docker.ServerVersion), Compose $($docker.ComposeVersion)." } else { 'Not running.' })
  if (-not $installed) {
    $errs = @($conflicts | Where-Object { $_.Level -eq 'error' })
    & $add 'validated' $(if ($errs.Count) { 'failed' } else { 'ok' }) 'Names, ports and networks' $(if ($errs.Count) { "$($errs.Count) conflict(s) with what already runs on this PC." } else { 'No conflict with existing containers, ports or networks.' })
  }
  if ($mode -eq 'tunnel') {
    $token = Get-CloudflareApiTokenInfo -Settings $settings
    & $add 'validated' $(if ($token.Stored -and $token.Readable) { 'ok' } else { 'failed' }) 'Cloudflare API token' $(if ($token.Stored -and $token.Readable) { "Stored (encrypted) for account '$($config.accountName)'." } else { 'Not connected (step 1).' })
  }
  if ($null -eq $composeOk) { & $add 'validated' 'pending' 'Compose configuration' $(if ($NoDryRun) { '' } else { 'Not checked: Docker is not running.' }) }
  else { & $add 'validated' $(if ($composeOk) { 'ok' } else { 'failed' }) 'Compose configuration' $(if ($composeOk) { 'docker compose config accepts the configuration.' } else { 'docker compose config reported errors (see technical output).' }) }
  if ($null -eq $dryExit) { & $add 'validated' 'pending' 'Installer dry run' $(if ($NoDryRun) { '' } else { 'Not run: Docker is not running.' }) }
  else { & $add 'validated' $(if ($dryExit -eq 0) { 'ok' } else { 'failed' }) 'Installer dry run' $(if ($dryExit -eq 0) { 'install.ps1 -DryRun finished without errors; nothing was changed.' } else { "install.ps1 -DryRun stopped with exit code $dryExit (see technical output)." }) }
  & $add 'applied' $(if ($installed) { 'ok' } else { 'pending' }) 'Installation' $(if ($installed) { 'Already installed.' } else { 'Nothing has been changed yet. Docker and Cloudflare change only after you confirm.' })
  & $add 'verified' 'pending' 'Runtime checks' 'Containers, Traefik API and the tunnel connector are checked after the installation.'
  foreach ($b in $blockers) { & $add 'action' 'failed' 'Blocking' $b }
  foreach ($w in $warnings) { & $add 'action' 'warning' 'Note' $w }
  $diagnostics = @()
  if ($lines.Count) { $diagnostics += @('== install.ps1 -DryRun ==') + @($lines) }
  if ($null -ne $composeOk) { $diagnostics += @('', "== docker compose config --quiet (exit $(if ($composeOk) { 0 } else { 'non-zero' })) ==") + @($(if ($composeLines.Count) { $composeLines } else { '(no output)' })) }
  return [ordered]@{
    installed = $installed; mode = $mode; steps = $steps; blockers = $blockers; warnings = $warnings
    conflicts = $conflicts; dryRun = $lines; canInstall = ($blockers.Count -eq 0 -and ($null -eq $dryExit -or $dryExit -eq 0) -and $composeOk -ne $false); planKey = $planKey
    review = $review.ToArray(); diagnostics = $diagnostics
  }
}

# Runtime review after an installation (read-only).
function Get-RuntimeReview($Settings, [string]$Mode) {
  $items = @()
  $st = Get-StackStatus -Settings $Settings
  foreach ($c in @($st.Containers | Where-Object { $_.Role -ne 'cloudflared' -or $Mode -eq 'tunnel' })) {
    $healthy = $c.State -eq 'running' -and ($c.Health -in @('', 'healthy'))
    $items += New-ReviewItem $(if ($healthy) { 'verified' } else { 'action' }) $(if ($healthy) { 'ok' } elseif ($c.State -eq 'running') { 'warning' } else { 'failed' }) "Container $($c.Name)" "$($c.State)$(if ($c.Health) { " ($($c.Health))" })"
  }
  $items += New-ReviewItem $(if ($st.TraefikApi) { 'verified' } else { 'action' }) $(if ($st.TraefikApi) { 'ok' } else { 'failed' }) 'Traefik API (local dashboard)' $(if ($st.TraefikApi) { "Traefik $($st.TraefikVersion) answers on http://127.0.0.1:$($Settings.DashboardPort)/dashboard/" } else { 'Not answering.' })
  return $items
}

# Runs the previewed installation. The only place where the setup wizard changes Docker or Cloudflare.
function Invoke-InstallRequest($Body) {
  Assert-Confirmed $Body
  $plan = Get-InstallPlan -NoDryRun
  if (-not $plan.canInstall) { Stop-Request 409 ('Installation is blocked: ' + ($plan.blockers -join ' ')) }
  if ([string](Get-Field $Body 'planKey' '') -ne $plan.planKey) { Stop-Request 409 'The settings changed since the preview. Preview the installation again.' }
  # Local and Cloudflare changes are approved separately (setup steps 5 and 6).
  if (@($plan.steps | Where-Object { $_.kind -eq 'cloudflare' }).Count -gt 0 -and -not [bool](Get-Field $Body 'confirmCloudflare' $false)) {
    Stop-Request 400 'This installation creates a resource in your Cloudflare account. Approve the Cloudflare changes separately.' @{ needsConfirm = 'cloudflare' }
  }
  $settings = Get-Settings
  $draft = Read-SetupDraft
  $mode = $draft.deployment.mode
  $results = New-Object System.Collections.ArrayList
  $step = { param($Name, $Status, $Message) $null = $results.Add([ordered]@{ name = $Name; status = $Status; message = $Message }) }
  $lines = @()
  $ok = $true
  try {
    $envPath = Join-Path $InstallPath '.env'
    if (-not (Test-Path -LiteralPath $envPath)) {
      Write-TextFileAtomic $envPath (New-DotEnvContent ([IO.File]::ReadAllText((Join-Path $here '.env.example'))) (Get-EnvValues $settings))
      & $step 'Write .env' 'Done' $envPath
    }
    Save-RememberedPath
    if ($mode -eq 'tunnel') {
      $config = Read-CloudflareConfig -Settings $settings
      if ($draft.deployment.tunnelChoice -eq 'new') {
        $t = New-CloudflareTunnel -Settings $settings -AccountId $config.accountId -Name $draft.deployment.newTunnelName
        $config.tunnelId = $t.id; $config.tunnelName = $t.name
        $draft.deployment.tunnelChoice = 'existing'; $draft.deployment.tunnelId = $t.id; $draft.deployment.tunnelName = $t.name; $draft.deployment.newTunnelName = ''
        Save-SetupDraft $draft
        Write-Audit 'cloudflare-tunnel-created' "name=$($t.name) id=$($t.id)"
        & $step 'Create Cloudflare tunnel' 'Done' "$($t.name) ($($t.id))"
      } else {
        $config.tunnelId = $draft.deployment.tunnelId; $config.tunnelName = $draft.deployment.tunnelName
      }
      Save-CloudflareConfig -Settings $settings -Config $config
      $null = Install-CloudflareTunnelToken -Settings $settings -AccountId $config.accountId -TunnelId $config.tunnelId
      Write-Audit 'tunnel-token-installed' "tunnel=$($config.tunnelId)"
      & $step 'Install connector token' 'Done' 'secrets\cloudflare_tunnel_token'
    }
    $installArgs = @('-InstallPath', $InstallPath, '-Start')
    if ($mode -eq 'tunnel') { $installArgs += '-EnableTunnel' }
    $r = Invoke-PowerShellFile (Join-Path $here 'install.ps1') $installArgs
    $lines = $r.Lines
    if ($r.ExitCode -ne 0) { $ok = $false; & $step 'Run the installer' 'Failed' 'See the installer output.' }
    else { & $step 'Run the installer' 'Done' "install.ps1 $($installArgs -join ' ')" }
  } catch {
    $ok = $false
    & $step 'Installation' 'Failed' $_.Exception.Message
  }
  if ($ok) { $draft = Read-SetupDraft; $draft.installedAt = (Get-Date -Format 's'); Save-SetupDraft $draft }
  Write-Audit 'setup-install' "ok=$ok mode=$mode"
  $review = @($results | ForEach-Object { New-ReviewItem 'applied' $(if ($_.status -eq 'Done') { 'ok' } else { 'failed' }) $_.name $_.message })
  if ($ok) {
    $review += @(Get-RuntimeReview $settings $mode)
    $review += New-ReviewItem 'action' 'info' 'Next' 'Check Traefik itself on the Traefik dashboard step before you publish applications.'
  } else { $review += New-ReviewItem 'action' 'failed' 'Installation failed' 'See the technical output, fix the cause and preview again.' }
  return [ordered]@{ ok = $ok; steps = $results.ToArray(); lines = $lines; review = $review }
}

function Select-CloudflareRequest($Body) {
  $settings = Get-Settings
  $config = Read-CloudflareConfig -Settings $settings
  $accountId = [string](Get-Field $Body 'accountId' $config.accountId)
  $tunnelId = [string](Get-Field $Body 'tunnelId' '')
  if (-not (Test-CloudflareId $accountId)) { Stop-Request 400 'Invalid account id.' }
  $accounts = @(Invoke-CloudflareApi -Settings $settings -Path '/accounts' -All)
  $acct = @($accounts | Where-Object { $_.id -eq $accountId })
  if ($acct.Count -eq 0) { Stop-Request 400 'The API token cannot see that account.' }
  if ($accountId -ne $config.accountId) { $config.tunnelId = ''; $config.tunnelName = '' }
  $config.accountId = $accountId; $config.accountName = [string]$acct[0].name
  if ($tunnelId) {
    if (-not (Test-CloudflareId $tunnelId)) { Stop-Request 400 'Invalid tunnel id.' }
    $tunnel = @(Get-CloudflareTunnels -Settings $settings -AccountId $accountId | Where-Object { $_.id -eq $tunnelId })
    if ($tunnel.Count -eq 0) { Stop-Request 400 'That tunnel does not exist in the selected account.' }
    if (-not $tunnel[0].remotelyManaged) { Stop-Request 400 "Tunnel '$($tunnel[0].name)' is locally managed (config file). Only dashboard/API-managed tunnels can be automated; create a new tunnel instead." }
    $config.tunnelId = $tunnelId; $config.tunnelName = $tunnel[0].name
  }
  Save-CloudflareConfig -Settings $settings -Config $config
  Write-Audit 'cloudflare-select' "account=$($config.accountName) tunnel=$($config.tunnelName)"
  return Get-CloudflareData
}

function New-TunnelRequest($Body) {
  Assert-Confirmed $Body
  $config = Assert-CloudflareReady
  $settings = Get-Settings
  $name = ([string](Get-Field $Body 'name' '')).Trim()
  $t = New-CloudflareTunnel -Settings $settings -AccountId $config.accountId -Name $name
  $config.tunnelId = $t.id; $config.tunnelName = $t.name
  Save-CloudflareConfig -Settings $settings -Config $config
  Write-Audit 'cloudflare-tunnel-created' "name=$($t.name) id=$($t.id)"
  return Get-CloudflareData
}

function Install-ConnectorRequest($Body) {
  Assert-Confirmed $Body
  $config = Assert-CloudflareReady -NeedTunnel
  $settings = Get-Settings
  Assert-Installed
  if ((Test-TunnelTokenFile $settings) -and -not [bool](Get-Field $Body 'confirmReplace' $false)) {
    Stop-Request 409 'secrets\cloudflare_tunnel_token already exists. Confirm that it should be replaced with the token of the selected tunnel.' @{ needsConfirm = 'replace' }
  }
  $wasRunning = Test-ContainerRunning $settings.CloudflaredContainer
  $installed = Install-CloudflareTunnelToken -Settings $settings -AccountId $config.accountId -TunnelId $config.tunnelId
  Write-Audit 'tunnel-token-installed' "tunnel=$($config.tunnelId)"
  $start = Start-TunnelConnector -Settings $settings -Recreate:$wasRunning
  Write-Audit 'cloudflared-start' "ok=$($start.Ok) $($start.Message)"
  return [ordered]@{ ok = $start.Ok; message = $start.Message; output = @($start.Output | Select-Object -Last 20); previousTokenBackedUp = [bool]$installed.PreviousTokenBackup }
}

# --- Environment, overview, expert view -------------------------------------------------------------------------

# Whether the install folder can be created/written: the nearest existing folder on the path gets a temporary file
# that is deleted when closed.
function Test-InstallPathAccess([string]$Path) {
  $probe = $Path
  while ($probe -and -not (Test-Path -LiteralPath $probe)) { $probe = Split-Path -Parent $probe }
  if (-not $probe) { return [ordered]@{ ok = $false; exists = $false; message = 'No part of this path exists (is the drive present?).' } }
  $exists = Test-Path -LiteralPath $Path
  try {
    $f = [IO.File]::Create((Join-Path $probe ('.tpx-write-check-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))), 1, [IO.FileOptions]::DeleteOnClose)
    $f.Dispose()
    return [ordered]@{ ok = $true; exists = $exists; message = $(if ($exists) { "$Path exists and is writable." } else { "$Path will be created inside $probe (writable)." }) }
  } catch { return [ordered]@{ ok = $false; exists = $exists; message = "Windows refused to write in $probe. Choose a folder in your user profile." } }
}

# Everything setup step 2 checks, read-only (apart from the deleted write probe).
function Get-EnvironmentData {
  $settings = Get-Settings
  $docker = Get-DockerStatus
  $installed = Test-Installed
  # Before the user saved any settings, check (and offer) values that collide with nothing on this PC rather than
  # the packaged defaults, which often clash with an existing stack.
  $suggested = $false
  if (-not $installed -and (Get-SettingsSource) -eq 'defaults' -and $docker.EngineRunning) { $settings = Get-SuggestedStackSettings -InstallPath $InstallPath; $suggested = $true }
  $conflicts = @()
  if (-not $installed) { $conflicts = @(Get-StackConflicts -Settings $settings) }
  $others = 0
  if ($docker.EngineRunning) { $others = @((Invoke-Docker ps -a --format '{{.Names}}').Output | Where-Object { $_ -and -not $_.StartsWith("$($settings.StackName)-") }).Count }
  return [ordered]@{
    docker = $docker; installed = $installed; path = (Test-InstallPathAccess $InstallPath); conflicts = $conflicts
    otherContainers = $others; settings = ConvertTo-InstanceValues $settings; suggested = $suggested
  }
}

function Set-ContactEmailRequest($Body) {
  $email = ([string](Get-Field $Body 'email' '')).Trim()
  if ($email -and $email -notmatch $EmailPattern) { Stop-Request 400 "'$email' is not a valid email address." }
  $draft = Read-SetupDraft
  $draft.contactEmail = $email
  Save-SetupDraft $draft
  return [ordered]@{ contactEmail = $email }
}

# --- App Catalog and installed apps ---------------------------------------------------------------------------

function Get-CatalogView($M) {
  $services = @(foreach ($sp in @($(if ($M.PSObject.Properties['services'] -and $M.services) { $M.services.PSObject.Properties } else { @() }))) {
      [ordered]@{ name = $sp.Name; image = [string]$sp.Value.image
        ports = @(@(if ($sp.Value.PSObject.Properties['ports']) { $sp.Value.ports }) | ForEach-Object { [ordered]@{ container = [int]$_.container; protocol = [string]$_.protocol; primary = [bool]($_.PSObject.Properties['primary'] -and $_.primary) } })
        volumes = @(@(if ($sp.Value.PSObject.Properties['volumes']) { $sp.Value.volumes }) | ForEach-Object { [ordered]@{ name = [string]$_.name; target = [string]$_.target; kind = $(if ($_.PSObject.Properties['kind']) { [string]$_.kind } else { 'volume' }); readOnly = [bool]($_.PSObject.Properties['readOnly'] -and $_.readOnly); description = $(if ($_.PSObject.Properties['description']) { [string]$_.description } else { '' }); input = $(if ($_.PSObject.Properties['input']) { [string]$_.input } else { '' }) } })
        dockerSocket = [bool]($sp.Value.PSObject.Properties['dockerSocket'] -and $sp.Value.dockerSocket); stateful = [bool](Get-Prop2 $sp.Value 'stateful' $false); when = [string](Get-Prop2 $sp.Value 'when' ''); networkMode = [string](Get-Prop2 $sp.Value 'networkMode' '')
        environment = @(if ($sp.Value.PSObject.Properties['environment'] -and $sp.Value.environment) { $sp.Value.environment.PSObject.Properties | ForEach-Object { $_.Name } }) }
    })
  $field = { param($n, $d) if ($M.PSObject.Properties[$n] -and $null -ne $M.$n) { $M.$n } else { $d } }
  return [ordered]@{
    id = [string]$M.id; name = [string]$M.name; description = [string]$M.description; category = [string]$M.category; license = [string]$M.license; maintainer = [string]$M.maintainer
    source = (& $field 'source' $null); docs = @(& $field 'docs' @()); installable = [bool](& $field 'installable' $false); installNote = [string](& $field 'installNote' '')
    platform = (Get-PlatformSupport $M); privileges = @(& $field 'privileges' @()); security = @(& $field 'security' @()); dependencies = @(& $field 'dependencies' @())
    exposure = (& $field 'exposure' $null); web = (& $field 'web' $null); update = (& $field 'update' $null); imageReference = [string](& $field 'imageReference' '')
    inputs = @(@(& $field 'inputs' @()) | ForEach-Object { [ordered]@{ id = [string]$_.id; type = [string]$_.type; label = [string]$_.label; required = [bool]($_.PSObject.Properties['required'] -and $_.required); help = $(if ($_.PSObject.Properties['help']) { [string]$_.help } else { '' }); default = $(if ($_.PSObject.Properties['default']) { [string]$_.default } else { '' }) } })
    services = $services; group = [string](& $field 'group' ''); deprecated = [bool](& $field 'deprecated' $false); deprecationNote = [string](& $field 'deprecationNote' '')
    resources = $(if ($M.PSObject.Properties['services'] -and $M.services) { $bv = @{}; foreach ($i in @(& $field 'inputs' @())) { if ($i.type -eq 'boolean') { $bv["input:$($i.id)"] = $(if ([string](Get-Prop2 $i 'default' 'false') -eq 'true') { 'true' } else { 'false' }) } }; Get-AppResourceEstimate $M $bv } else { & $field 'resources' $null })
    files = @(@(& $field 'files' @()) | ForEach-Object { [string]$_.path }); alternatives = @(& $field 'alternatives' @()); requirements = @(& $field 'requirements' @())
  }
}

function Get-CatalogData {
  $apps = @(Get-CatalogApps -CatalogDir $CatalogDir)
  $installed = @()
  if (Test-Installed) { $installed = @(Read-AppsRegistry (Get-Settings)) }
  return [ordered]@{
    apps = @($apps | Where-Object { -not @($_.errors).Count } | ForEach-Object { $v = Get-CatalogView $_.manifest; $v.installedAs = @($installed | Where-Object { $_.appId -eq $v.id } | ForEach-Object { $_.project }); $v })
    invalid = @($apps | Where-Object { @($_.errors).Count } | ForEach-Object { [ordered]@{ file = $_.file; errors = @($_.errors) } })
    sources = @([ordered]@{ type = 'curated'; name = 'Curated catalog (this manager)'; enabled = $true },
      [ordered]@{ type = 'github-compose'; name = 'GitHub Compose repositories'; enabled = $false }, [ordered]@{ type = 'docker-hub'; name = 'Docker Hub (image discovery only)'; enabled = $false },
      [ordered]@{ type = 'ghcr'; name = 'GitHub Container Registry (image discovery only)'; enabled = $false }, [ordered]@{ type = 'unraid-xml'; name = 'Unraid templates (import)'; enabled = $false },
      [ordered]@{ type = 'user-compose'; name = 'Your own Compose file'; enabled = $false })
  }
}

function Get-ComposeProjectContainers([string]$Project) {
  $r = Invoke-Docker ps -a --filter "label=com.docker.compose.project=$Project" --format '{{.Names}}|{{.State}}|{{.Status}}|{{.Image}}'
  return @(@($r.Output) | Where-Object { $_ -match '\|' } | ForEach-Object { $p = ([string]$_).Split('|'); [ordered]@{ name = $p[0]; state = $p[1]; status = $p[2]; image = $p[3]; health = $(if ($p[2] -match '\((healthy|unhealthy|health: starting)\)') { $Matches[1] } else { '' }) } })
}

function Get-AppDefaults($Manifest, $Settings) {
  $base = [string]$Manifest.id
  $root = Split-Path -Parent $InstallPath
  $existing = @(Read-AppsRegistry $Settings | ForEach-Object { $_.project })
  $n = 1; $project = $base
  while ($existing -contains $project -or (Test-Path -LiteralPath (Join-Path $root $project)) -or @(Get-ComposeProjectContainers $project).Count -or $project -eq $Settings.StackName) { $n++; $project = "$base-$n" }
  # Admin interfaces open on 127.0.0.1 by default: the manifest's port, or the next free one.
  $lp = 0
  if ($Manifest.PSObject.Properties['web'] -and $Manifest.web.PSObject.Properties['localPort'] -and [int]$Manifest.web.localPort) {
    $lp = [int]$Manifest.web.localPort
    $usedByApps = @(Read-AppsRegistry $Settings | ForEach-Object { if ($_.PSObject.Properties['localPort']) { [int]$_.localPort } })
    while ((Get-PortUser $lp) -or $usedByApps -contains $lp) { $lp++ }
  }
  return [ordered]@{ project = $project; folder = (Join-Path $root $project); timezone = (Get-IanaTimeZone); localPort = $lp }
}

function Get-IanaTimeZone {
  try { $id = [TimeZoneInfo]::Local.Id; $map = @{ 'W. Europe Standard Time' = 'Europe/Berlin'; 'GMT Standard Time' = 'Europe/London'; 'Pacific Standard Time' = 'America/Los_Angeles'; 'Mountain Standard Time' = 'America/Denver'; 'Central Standard Time' = 'America/Chicago'; 'Eastern Standard Time' = 'America/New_York'; 'Romance Standard Time' = 'Europe/Paris'; 'Central European Standard Time' = 'Europe/Warsaw'; 'AUS Eastern Standard Time' = 'Australia/Sydney'; 'Tokyo Standard Time' = 'Asia/Tokyo'; 'UTC' = 'UTC' }; if ($map.ContainsKey($id)) { return $map[$id] } } catch { }
  return 'UTC'
}

function Get-AppSecretKeys($Manifest) {
  $secretInputs = @(@(if ($Manifest.PSObject.Properties['inputs']) { $Manifest.inputs }) | Where-Object { $_.type -in 'generated', 'secret' } | ForEach-Object { [string]$_.id })
  $keys = @()
  foreach ($sp in $Manifest.services.PSObject.Properties) {
    if (-not ($sp.Value.PSObject.Properties['environment'] -and $sp.Value.environment)) { continue }
    foreach ($ev in $sp.Value.environment.PSObject.Properties) { foreach ($sid in $secretInputs) { if ([string]$ev.Value -match "\{\{\s*input:$sid\s*\}\}") { $keys += $ev.Name } } }
  }
  return @($keys | Select-Object -Unique)
}

# Validated preview of an installation: compose.yaml, configuration files and the .env with secrets masked, plus
# every check (names, folder, volumes, port, network, memory, disk, docker compose config). Writes nothing except a
# temporary copy for `docker compose config` (removed again).
function Invoke-AppPlan($Body) {
  Assert-Installed
  $settings = Get-Settings
  $appId = [string](Get-Field $Body 'appId' '')
  try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $appId } catch { Stop-Request 404 $_.Exception.Message }
  $platform = Get-PlatformSupport $m
  if (-not $platform.installable) { Stop-Request 409 "$($m.name) cannot be installed here: $(if ($m.PSObject.Properties['installNote']) { $m.installNote } else { $platform.support })" }
  $defaults = Get-AppDefaults $m $settings
  $project = ([string](Get-Field $Body 'project' $defaults.project)).Trim().ToLowerInvariant()
  $checks = New-Object System.Collections.ArrayList
  $check = { param($label, $ok, $message, $state = $null) $null = $checks.Add([ordered]@{ label = $label; state = $(if ($state) { $state } elseif ($ok) { 'ok' } else { 'failed' }); message = $message }) }
  if ($project -notmatch '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$') { Stop-Request 400 'The project name may use lowercase letters, digits and dashes (at most 32 characters).' }
  $folderRaw = [string](Get-Field $Body 'folder' $defaults.folder)
  try { $folder = ConvertTo-ProjectPath $folderRaw } catch { Stop-Request 400 "Installation folder: $($_.Exception.Message)" }
  $taken = @(Get-ComposeProjectContainers $project).Count -gt 0 -or $project -eq $settings.StackName -or @(Read-AppsRegistry $settings | Where-Object { $_.project -eq $project }).Count
  & $check 'Project name is free' (-not $taken) $(if ($taken) { "A Compose project or app named '$project' already exists." } else { "Compose project '$project'." })
  # A folder holding only the backups of an earlier installation counts as empty: the backups are kept.
  $folderOk = -not (Test-Path -LiteralPath $folder) -or -not @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'backups' }).Count
  & $check 'Installation folder is new or empty' $folderOk $(if ($folderOk) { $folder } else { "$folder already contains files; choose another folder." })
  $insideDeployment = $folder.StartsWith($InstallPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $folder -ieq $InstallPath
  if ($insideDeployment) { & $check 'Installation folder is outside the proxy deployment' $false 'Apps get their own folder, not one inside the proxy deployment.' }
  $hostNet = @($m.services.PSObject.Properties | Where-Object { [string](Get-Prop2 $_.Value 'networkMode' '') -eq 'host' }).Count -gt 0
  $localPort = 0
  if (-not $hostNet -and [int]::TryParse([string](Get-Field $Body 'localPort' $defaults.localPort), [ref]$localPort) -and $localPort -ne 0) {
    if ($localPort -lt 1024 -or $localPort -gt 65535) { Stop-Request 400 'The local port must be between 1024 and 65535.' }
    $user = Get-PortUser $localPort
    & $check "Local port 127.0.0.1:$localPort is free" (-not $user) $(if ($user) { "In use by $user. Choose another local port." } else { 'Only this PC can open it.' })
  }
  $tz = ([string](Get-Field $Body 'timezone' $defaults.timezone)).Trim()
  $appUrl = ([string](Get-Field $Body 'appUrl' '')).Trim()
  if ($appUrl -and $appUrl -notmatch '^https?://[A-Za-z0-9.-]+(:\d+)?/?$') { Stop-Request 400 'The app address must look like https://app.example.com.' }
  if (-not $appUrl) { $appUrl = $(if ($localPort) { "http://127.0.0.1:$localPort" } else { "http://$project" }) }
  $inputs = @{}
  $bodyInputs = Get-Field $Body 'inputs' $null
  if ($bodyInputs) { foreach ($p in $bodyInputs.PSObject.Properties) { $inputs[$p.Name] = [string]$p.Value } }
  $cfDomains = @((Read-CloudflareConfig -Settings $settings).domains | ForEach-Object { $_.name })
  $context = @{ traefikContainer = $settings.TraefikContainer; proxyNetwork = $settings.ProxyNetwork; domains = $(if ($cfDomains.Count) { $cfDomains -join ',' } else { 'localhost' }) }
  $resolved = Resolve-AppValues -Manifest $m -Inputs $inputs -Project $project -AppUrl $appUrl -TimeZone $tz -LocalPort $localPort -Context $context
  foreach ($err in $resolved.Errors) { & $check 'Settings' $false $err }
  $active = @(Get-ActiveServices $m $resolved.Values)
  $net = Get-DockerNetworkFacts $settings.ProxyNetwork
  & $check "Shared network '$($settings.ProxyNetwork)' exists" $net.exists $(if ($net.exists) { 'The web service joins it so Traefik can reach it by name; nothing is published yet.' } else { 'Start the proxy deployment first.' })
  $volumes = @()
  foreach ($sp in $active) { foreach ($v in @(Get-Prop2 $sp.Value 'volumes' @())) { if ((Get-Prop2 $v 'kind' 'volume') -eq 'volume' -and -not ((Get-Prop2 $v 'input' '') -and [string]$resolved.Values["input:$($v.input)"])) { $volumes += "${project}_$($v.name)" } } }
  $volumes = @($volumes | Select-Object -Unique)
  $reuse = [bool](Get-Field $Body 'reuseData' $false)
  foreach ($vn in $volumes) {
    $exists = (Invoke-Docker volume inspect $vn).ExitCode -eq 0
    if ($exists -and $reuse) { & $check "Data volume $vn" $true 'Exists already: the app will use the data in it (as you chose).' 'warning' }
    else { & $check "Data volume $vn" (-not $exists) $(if ($exists) { 'A volume with this name already exists (kept from an earlier installation?). Choose another project name, or choose to reuse its data.' } else { 'Will be created; it survives updates, restarts and removal unless you delete it explicitly.' }) }
  }
  # Resources: the app's estimate against what Docker and Windows have free right now. When the project is only
  # prepared (not started), a shortfall is a warning: nothing runs until Start, which checks again.
  $startNow = [bool](Get-Field $Body 'startNow' $true)
  $res = Get-HostResources
  $need = Get-AppResourceEstimate $m $resolved.Values
  if ($need.memoryMB -gt 0) {
    $free = [Math]::Min($res.dockerFreeMB, $res.windowsFreeMB)
    $memState = $(if ($need.memoryMB -gt $free) { $(if ($startNow) { 'failed' } else { 'warning' }) } elseif ($need.memoryMB * 1.5 -gt $free) { 'warning' } else { 'ok' })
    & $check 'Memory' ($memState -ne 'failed') "Needs about $($need.memoryMB) MB; free now: $($res.dockerFreeMB) MB for Docker (of $($res.dockerTotalMB) MB), $($res.windowsFreeMB) MB in Windows.$(if ($memState -eq 'failed') { ' Stop other apps or give Docker Desktop more memory first.' })" $memState
  }
  if ($need.diskMB -gt 0) {
    $freeDisk = [Math]::Min($res.projectsDiskFreeMB, $res.dockerDiskFreeMB)
    & $check 'Disk space' ($need.diskMB -lt $freeDisk) "Needs about $($need.diskMB) MB (images and first data); free: $freeDisk MB." $(if ($need.diskMB -ge $freeDisk) { $(if ($startNow) { 'failed' } else { 'warning' }) } elseif ($need.diskMB * 3 -gt $freeDisk) { 'warning' } else { 'ok' })
  }
  $compose = $null; $envText = $null; $envAll = [ordered]@{}
  if (-not @($resolved.Errors).Count) {
    try {
      $compose = ConvertTo-AppCompose -Manifest $m -Project $project -Resolved $resolved -ProxyNetwork $settings.ProxyNetwork -LocalPort $localPort
      foreach ($svc in $resolved.Env.Keys) { foreach ($k in $resolved.Env[$svc].Keys) { $envAll[$k] = $resolved.Env[$svc][$k] } }
      $envText = ConvertTo-EnvFileText $envAll
    } catch { & $check 'Compose file' $false $_.Exception.Message }
  }
  $filesPreview = @()
  if ($compose) {
    $extra = $resolved.Values.Clone(); $extra['installedApps'] = (Get-InstalledAppsYaml $settings)
    try { $filesPreview = @(Get-AppFiles $m $extra | ForEach-Object { [ordered]@{ path = $_.path; content = $(if ($_.secret) { '(contains secrets: written to the project folder, readable by your account only)' } else { $_.content -replace '__derived:[A-Za-z0-9]+', '<computed during installation>' }) } }) } catch { & $check 'Configuration files' $false $_.Exception.Message }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("tpm-app-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
      [IO.File]::WriteAllText((Join-Path $tmp 'compose.yaml'), $compose); [IO.File]::WriteAllText((Join-Path $tmp '.env'), $envText)
      Set-SecretFileAcl (Join-Path $tmp '.env')
      $v = Invoke-Docker compose --project-directory $tmp -f (Join-Path $tmp 'compose.yaml') config -q
      & $check 'docker compose config' ($v.ExitCode -eq 0) $(if ($v.ExitCode -eq 0) { 'The Compose file is valid.' } else { (Hide-SecretValues @($v.Output) @($envAll.Values)) -join ' ' })
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  $images = @(foreach ($sp in $active) { $present = (Invoke-Docker image inspect $sp.Value.image).ExitCode -eq 0; [ordered]@{ service = $sp.Name; image = [string]$sp.Value.image; present = $present } })
  foreach ($i in $images) { & $check "Image $($i.image -replace '@sha256:.*', '')" $true $(if ($i.present) { 'Already on this PC.' } else { 'Will be downloaded during the installation (pinned by digest).' }) 'info' }
  $privileged = @($m.privileges).Count -gt 0
  $secretKeys = @($resolved.Secrets)
  $preview = $(if ($envText) { (($envText -split "`n") | ForEach-Object { if ($_ -match '^([A-Z][A-Z0-9_]*)=' -and $secretKeys -contains $Matches[1]) { "$($Matches[1])=<secret, stored only in .env>" } else { $_ } }) -join "`n" } else { '' })
  $canApply = $compose -and -not @($checks | Where-Object { $_.state -eq 'failed' }).Count
  foreach ($k in @($State.AppPlans.Keys)) { if (((Get-Date) - $State.AppPlans[$k].Created).TotalMinutes -gt 15) { $State.AppPlans.Remove($k) } }
  $planId = New-RandomKey 12
  if ($canApply) { $State.AppPlans[$planId] = [pscustomobject]@{ Created = (Get-Date); AppId = $m.id; Project = $project; Folder = $folder; Compose = $compose; EnvAll = $envAll; Values = $resolved.Values; Derived = @($resolved.Derived); Privileged = $privileged; Images = $images; LocalPort = $localPort; StartNow = $startNow } }
  return [ordered]@{
    planId = $(if ($canApply) { $planId } else { '' }); canApply = [bool]$canApply; appId = $m.id; name = $m.name; project = $project; folder = $folder
    container = (Get-AppContainerName $m $project $m.web.service)
    services = @($active | ForEach-Object { [ordered]@{ name = $_.Name; container = (Get-AppContainerName $m $project $_.Name); image = [string]$_.Value.image; stateful = [bool](Get-Prop2 $_.Value 'stateful' $false) } })
    compose = $compose; envPreview = $preview; files = $filesPreview; checks = $checks.ToArray(); existingVolumes = @($volumes | Where-Object { (Invoke-Docker volume inspect $_).ExitCode -eq 0 })
    privileges = @($m.privileges); security = @($m.security); volumes = $volumes; images = $images; resources = [ordered]@{ need = $need; host = $res }
    localUrl = $(if ($localPort) { "http://127.0.0.1:$localPort/" } else { '' }); startNow = $startNow
  }
}

function Get-Prop2($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# Memory and disk an installation needs: per-service estimates of the services it runs, else the app's estimate.
function Get-AppResourceEstimate($Manifest, [hashtable]$Values) {
  $mem = 0; $disk = 0; $per = $false
  foreach ($sp in (Get-ActiveServices $Manifest $Values)) {
    $r = Get-Prop2 $sp.Value 'resources' $null
    if ($r) { $per = $true; $mem += [int](Get-Prop2 $r 'memoryMB' 0); $disk += [int](Get-Prop2 $r 'diskMB' 0) }
  }
  $app = Get-Prop2 $Manifest 'resources' $null
  if (-not $per -and $app) { $mem = [int](Get-Prop2 $app 'memoryMB' 0); $disk = [int](Get-Prop2 $app 'diskMB' 0) }
  return [ordered]@{ memoryMB = $mem; diskMB = $disk }
}

# What this PC and Docker Desktop have free right now (read-only).
function Get-HostResources {
  $out = [ordered]@{ dockerTotalMB = 0; dockerUsedMB = 0; dockerFreeMB = 0; cpus = 0; windowsTotalMB = 0; windowsFreeMB = 0; projectsDiskFreeMB = 0; dockerDiskFreeMB = 0; running = 0; containers = @() }
  try { $os = Get-CimInstance Win32_OperatingSystem; $out.windowsTotalMB = [int]($os.TotalVisibleMemorySize / 1024); $out.windowsFreeMB = [int]($os.FreePhysicalMemory / 1024) } catch { }
  $i = Invoke-Docker info --format '{{.MemTotal}}|{{.NCPU}}'
  $line = @($i.Output | Where-Object { $_ -match '^\d+\|\d+$' })[0]
  if ($line) { $p = $line.Split('|'); $out.dockerTotalMB = [int]([int64]$p[0] / 1MB); $out.cpus = [int]$p[1] }
  $st = Invoke-Docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}'
  $used = 0.0
  $list = @(foreach ($l in @($st.Output)) {
      if ($l -notmatch '^([^|]+)\|([\d.]+)\s*([KMG]i?B)') { continue }
      $mb = [double]$Matches[2] * @{ KiB = 1 / 1024; KB = 1 / 1024; MiB = 1; MB = 1; GiB = 1024; GB = 1024 }[$Matches[3]]
      $used += $mb
      [ordered]@{ name = $Matches[1]; memoryMB = [int]$mb }
    })
  $out.containers = @($list | Sort-Object { $_.memoryMB } -Descending)
  $out.running = $list.Count
  $out.dockerUsedMB = [int]$used
  $out.dockerFreeMB = [Math]::Max(0, $out.dockerTotalMB - $out.dockerUsedMB)
  try { $out.projectsDiskFreeMB = [int]((Get-PSDrive ((Split-Path -Qualifier $InstallPath).TrimEnd(':'))).Free / 1MB) } catch { }
  try { $out.dockerDiskFreeMB = [int]((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free / 1MB) } catch { }
  return $out
}

# A YAML list of the installed apps for Homepage's services.yaml: links to their local addresses and an internal status
# check over the shared network. No widgets, API keys or Docker access.
function Get-InstalledAppsYaml($Settings) {
  $apps = @(Read-AppsRegistry $Settings)
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $lines = @('- Apps:')
  $n = 0
  foreach ($a in $apps) {
    $m = @($catalog | Where-Object { $_.id -eq $a.appId } | ForEach-Object { $_.manifest })
    if (-not $m.Count -or $a.appId -eq 'homepage') { continue }
    $web = $m[0].web.service
    $port = [int](@(@($m[0].services.$web.ports) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary })[0].container)
    $scheme = $(if (@(@($m[0].services.$web.ports) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary -and $_.protocol -eq 'https' }).Count) { 'https' } else { 'http' })
    $href = $(if ($a.PSObject.Properties['localUrl'] -and $a.localUrl) { [string]$a.localUrl } elseif ($a.PSObject.Properties['localPort'] -and [int]$a.localPort) { "http://127.0.0.1:$($a.localPort)/" } else { '' })
    $name = ([string]$a.name).Replace('"', "'")
    $lines += "    - ""$name"":"
    # A prepared app has no container yet: no link and no status check, so it is never shown as up.
    if ($a.PSObject.Properties['prepared'] -and $a.prepared) { $lines += '        description: "prepared, not started"'; $n++; continue }
    if ($href) { $lines += "        href: $href" }
    $lines += "        description: ""$(([string]$m[0].category))"""
    if ($m[0].web.PSObject.Properties['status']) { $port = [int]$m[0].web.status.port; $scheme = [string]$m[0].web.status.scheme }
    # Apps kept off the shared network (web.proxy false) cannot be checked from Homepage.
    if (-not ($m[0].web.PSObject.Properties['proxy'] -and -not $m[0].web.proxy)) { $lines += "        siteMonitor: ${scheme}://$(Get-AppContainerName $m[0] $a.project $web):$port" }
    $n++
  }
  if (-not $n) { return "- Apps: []`n" }
  return ($lines -join "`n") + "`n"
}

# Post-install steps with their templates resolved (values include generated passwords): kept in memory, or for a
# prepared app in a restricted .post-install.json until its first start.
function Get-ResolvedPostInstall($Manifest, [hashtable]$Values) {
  return @(foreach ($h in @(if ($Manifest.PSObject.Properties['postInstall']) { $Manifest.postInstall })) {
      $o = [ordered]@{ service = [string]$h.service; label = [string]$h.label }
      if ($h.PSObject.Properties['http']) {
        $o.http = [ordered]@{ path = [string]$h.http.path; body = (Resolve-TemplateValue ([string]$h.http.body) $Values) }
        if ($h.http.PSObject.Properties['tokenFromLog']) { $o.http.tokenFromLog = [ordered]@{ pattern = [string]$h.http.tokenFromLog.pattern; header = [string]$h.http.tokenFromLog.header } }
      } else { $o.command = @($h.command | ForEach-Object { Resolve-TemplateValue ([string]$_) $Values }) }
      [pscustomobject]$o
    })
}

function Invoke-AppPostInstall($Manifest, [string]$Project, [int]$LocalPort, $Hooks, $Health, [string[]]$Secrets) {
  $out = New-Object System.Collections.ArrayList
  $scheme = $(if (@(@($Manifest.services.($Manifest.web.service).ports) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary -and $_.protocol -eq 'https' }).Count) { 'https' } else { 'http' })
  foreach ($hook in @($Hooks)) {
    if (-not $hook) { continue }
    $name = "Post-install: $($hook.label)"
    if (-not ($Health -and $Health.running)) { $null = $out.Add([ordered]@{ name = $name; status = 'Skipped'; message = 'The app is not running.' }); continue }
    $container = Get-AppContainerName $Manifest $Project $hook.service
    if ($hook.PSObject.Properties['http'] -and $hook.http) {
      if (-not $LocalPort) { $null = $out.Add([ordered]@{ name = $name; status = 'Skipped'; message = 'The app has no local port.' }); continue }
      $code = 0; $msg = ''; $headers = @{}
      for ($try = 0; $try -lt 6; $try++) {
        # Some apps print a one-time setup token in their log that must accompany the first call (Portainer 2.45+).
        if ($hook.http.PSObject.Properties['tokenFromLog'] -and $hook.http.tokenFromLog) {
          $log = ((Invoke-Docker logs $container).Output | Out-String)
          $tm = [regex]::Matches($log, [string]$hook.http.tokenFromLog.pattern)
          if ($tm.Count) { $headers[[string]$hook.http.tokenFromLog.header] = $tm[$tm.Count - 1].Groups[1].Value } else { Start-Sleep -Seconds 5; continue }
        }
        $hr = Invoke-LoopbackPost "${scheme}://127.0.0.1:$LocalPort$($hook.http.path)" ([string]$hook.http.body) $headers; $code = $hr.Status; $msg = $hr.Error
        if ($code -ge 200 -and $code -lt 300) { break }; Start-Sleep -Seconds 5
      }
      $null = $out.Add([ordered]@{ name = $name; status = $(if ($code -ge 200 -and $code -lt 300) { 'Done' } else { 'Failed' }); message = "HTTP $code $msg" })
      continue
    }
    $hr = $null
    for ($try = 0; $try -lt 5; $try++) { $hr = Invoke-Docker @(@('exec', $container) + @($hook.command)); if ($hr.ExitCode -eq 0) { break }; Start-Sleep -Seconds 4 }
    $null = $out.Add([ordered]@{ name = $name; status = $(if ($hr.ExitCode -eq 0) { 'Done' } else { 'Failed' }); message = ((Hide-SecretValues @(ConvertTo-RedactedText @($hr.Output | Select-Object -Last 3)) $Secrets) -join ' ') })
  }
  return $out.ToArray()
}

# POST JSON to an app on 127.0.0.1 only. A self-signed certificate is accepted for loopback addresses only.
function Invoke-LoopbackPost([string]$Url, [string]$Json, [hashtable]$Headers = @{}) {
  $res = [pscustomobject]@{ Status = 0; Error = '' }
  if (([Uri]$Url).Host -ne '127.0.0.1') { $res.Error = 'not a loopback address'; return $res }
  $prev = [Net.ServicePointManager]::ServerCertificateValidationCallback
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { param($s, $c, $ch, $e) ([Net.HttpWebRequest]$s).Address.IsLoopback }
    $req = [Net.HttpWebRequest]::Create($Url); $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 15000; $req.Proxy = $null
    foreach ($k in $Headers.Keys) { $req.Headers.Add($k, [string]$Headers[$k]) }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json); $req.ContentLength = $bytes.Length
    $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    try { $r = $req.GetResponse() } catch [Net.WebException] { if ($_.Exception.Response) { $r = $_.Exception.Response } else { throw } }
    $res.Status = [int]$r.StatusCode; $r.Close()
  } catch { $res.Error = $_.Exception.Message } finally { [Net.ServicePointManager]::ServerCertificateValidationCallback = $prev }
  return $res
}

# Values computed at installation time (never in the plan): e.g. an Authelia argon2 password hash, computed with the
# app's own image so the hash format is exactly what that version expects.
function Resolve-DerivedValue($Manifest, [string]$Id, [hashtable]$Values) {
  $i = @($Manifest.inputs | Where-Object { $_.id -eq $Id })[0]
  switch ([string]$i.method) {
    'authelia-argon2' {
      $image = [string]@($Manifest.services.PSObject.Properties | Where-Object { $_.Value.image -match '^authelia/authelia' })[0].Value.image
      $r = Invoke-Docker run --rm --pull missing --network none $image authelia crypto hash generate argon2 --password ([string]$Values["input:$($i.from)"])
      $hash = @($r.Output | ForEach-Object { if ([string]$_ -match '(\$argon2id\$\S+)') { $Matches[1] } })[0]
      if ($r.ExitCode -ne 0 -or -not $hash) { throw 'Could not compute the Authelia password hash.' }
      return $hash
    }
  }
  throw "Unknown derived method '$($i.method)'."
}

function Invoke-AppApply($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $planId = [string](Get-Field $Body 'planId' '')
  if (-not $State.AppPlans.ContainsKey($planId)) { Stop-Request 409 'This preview has expired or was already used. Preview again.' }
  $plan = $State.AppPlans[$planId]; $State.AppPlans.Remove($planId)
  if ($plan.Privileged -and -not [bool](Get-Field $Body 'confirmPrivileges' $false)) { Stop-Request 400 'This app needs elevated privileges: confirm them explicitly.' }
  if ((Test-Path -LiteralPath $plan.Folder) -and @(Get-ChildItem -LiteralPath $plan.Folder -Force | Where-Object { $_.Name -ne 'backups' }).Count) { Stop-Request 409 "$($plan.Folder) is no longer empty. Preview again." }
  $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $plan.AppId
  $steps = New-Object System.Collections.ArrayList
  $step = { param($name, $status, $message) $null = $steps.Add([ordered]@{ name = $name; status = $status; message = $message }) }
  $values = $plan.Values.Clone()
  foreach ($d in $plan.Derived) {
    try { $values["input:$d"] = Resolve-DerivedValue $m $d $values; & $step "Compute $d" 'Done' 'Computed on this PC.' }
    catch { & $step "Compute $d" 'Failed' $_.Exception.Message; return [ordered]@{ ok = $false; steps = $steps.ToArray(); project = $plan.Project; folder = $plan.Folder; health = $null; container = '' } }
  }
  New-Item -ItemType Directory -Force -Path $plan.Folder | Out-Null
  [IO.File]::WriteAllText((Join-Path $plan.Folder 'compose.yaml'), $plan.Compose)
  $envPath = Join-Path $plan.Folder '.env'
  [IO.File]::WriteAllText($envPath, '')
  Set-SecretFileAcl $envPath
  [IO.File]::WriteAllText($envPath, (ConvertTo-EnvFileText $plan.EnvAll))
  [IO.File]::WriteAllText((Join-Path $plan.Folder 'README.md'), (New-AppReadme $m $plan.Project $plan.Folder))
  foreach ($sp in (Get-ActiveServices $m $values)) {
    foreach ($v in @(Get-Prop2 $sp.Value 'volumes' @())) { if ((Get-Prop2 $v 'kind' 'volume') -eq 'project') { New-Item -ItemType Directory -Force -Path (Join-Path $plan.Folder ($v.source -replace '/', '\')) | Out-Null } }
  }
  $values['installedApps'] = Get-InstalledAppsYaml $settings
  foreach ($f in (Get-AppFiles $m $values)) {
    $target = Join-Path $plan.Folder ($f.path -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    if ($f.secret) { [IO.File]::WriteAllText($target, ''); Set-SecretFileAcl $target }
    [IO.File]::WriteAllText($target, $f.content)
  }
  # Sign-in passwords a person needs (generated or typed) go to credentials.txt, readable by this account only.
  $creds = @(@($m.inputs) | Where-Object { $_ -and $_.type -eq 'password' } | ForEach-Object { "$($_.label): $($values["input:$($_.id)"])" })
  if ($creds.Count) {
    $cp = Join-Path $plan.Folder 'credentials.txt'; [IO.File]::WriteAllText($cp, ''); Set-SecretFileAcl $cp
    [IO.File]::WriteAllText($cp, ((@("Sign-in details for $($m.name) ($($plan.Project)). Keep this file private; change the passwords after the first sign-in if you like.", '') + $creds) -join "`r`n") + "`r`n")
  }
  & $step 'Write the Compose project' 'Done' $(if ($creds.Count) { "$($plan.Folder) (sign-in details: credentials.txt)" } else { $plan.Folder })
  $webScheme = $(if (@(@($m.services.($m.web.service).ports) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary -and $_.protocol -eq 'https' }).Count) { 'https' } else { 'http' })
  $localUrl = $(if ($plan.LocalPort) { "${webScheme}://127.0.0.1:$($plan.LocalPort)/" } else { '' })
  $record = [ordered]@{ project = $plan.Project; appId = $plan.AppId; name = [string]$m.name; folder = $plan.Folder; installedAt = (Get-Date -Format 's'); images = @($plan.Images | ForEach-Object { $_.image }); localPort = $plan.LocalPort; localUrl = $localUrl; prepared = (-not $plan.StartNow) }
  Save-AppsRegistry $settings (@(Read-AppsRegistry $settings | Where-Object { $_.project -ne $plan.Project }) + [pscustomobject]$record)
  $hooks = @(Get-ResolvedPostInstall $m $values)
  if (-not $plan.StartNow) {
    if ($hooks.Count) { $hp = Join-Path $plan.Folder '.post-install.json'; [IO.File]::WriteAllText($hp, ''); Set-SecretFileAcl $hp; [IO.File]::WriteAllText($hp, (ConvertTo-Json -InputObject @($hooks) -Depth 6)) }
    Write-Audit 'app-prepare' "$($plan.AppId) project=$($plan.Project) folder=$($plan.Folder)"
    & $step 'Prepared, not started' 'Done' 'No app container was created or started. Use Start on the Installed apps page when resources allow: it checks memory again and downloads the pinned images.'
    return [ordered]@{ ok = $true; prepared = $true; steps = $steps.ToArray(); project = $plan.Project; folder = $plan.Folder; health = $null; container = (Get-AppContainerName $m $plan.Project $m.web.service); output = ''; localUrl = $localUrl; credentialsFile = $(if ($creds.Count) { Join-Path $plan.Folder 'credentials.txt' } else { '' }) }
  }
  $up = Invoke-Docker compose --project-directory $plan.Folder -f (Join-Path $plan.Folder 'compose.yaml') up -d
  $secrets = @(@((Read-AppEnv $envPath).Values) + @($values.Keys | Where-Object { $_ -like 'input:*' } | ForEach-Object { [string]$values[$_] }) | Where-Object { $_ -and $_.Length -ge 8 -and $_ -notmatch '^(true|false)$' -and $_ -notmatch '^[A-Za-z]:\\' })
  $upText = (Hide-SecretValues @(ConvertTo-RedactedText @($up.Output)) $secrets) -join "`n"
  & $step 'Download images and start (docker compose up -d)' $(if ($up.ExitCode -eq 0) { 'Done' } else { 'Failed' }) ($upText -split "`n" | Select-Object -Last 6 | Out-String).Trim()
  Write-Audit 'app-install' "$($plan.AppId) project=$($plan.Project) folder=$($plan.Folder) exit=$($up.ExitCode)"
  $health = $null
  if ($up.ExitCode -eq 0) { $health = Get-AppHealth $plan.Project $m $settings 90 }
  # Commands the app's own tools run once it is up (e.g. setting the first administrator password).
  foreach ($x in (Invoke-AppPostInstall $m $plan.Project $plan.LocalPort $hooks $health $secrets)) { $null = $steps.Add($x) }
  return [ordered]@{ ok = ($up.ExitCode -eq 0); steps = $steps.ToArray(); project = $plan.Project; folder = $plan.Folder; health = $health
    container = (Get-AppContainerName $m $plan.Project $m.web.service); output = $upText; localUrl = $localUrl; credentialsFile = $(if ($creds.Count) { Join-Path $plan.Folder 'credentials.txt' } else { '' }) }
}

# Running state of every container and a real HTTP request to the web interface (probe container on the shared network).
function Get-AppHealth([string]$Project, $Manifest, $Settings, [int]$WaitSeconds = 0) {
  $web = Get-AppContainerName $Manifest $Project $Manifest.web.service
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  do {
    $cs = @(Get-ComposeProjectContainers $Project)
    $w = @($cs | Where-Object { $_.name -eq $web })
    $starting = @($cs | Where-Object { $_.health -eq 'health: starting' -or $_.state -in 'created', 'restarting' }).Count
    $ready = $w.Count -and $w[0].state -eq 'running' -and -not $starting
    if ($ready -or (Get-Date) -ge $deadline) { break }
    Start-Sleep -Seconds 3
  } while ($true)
  $out = [ordered]@{ containers = $cs; web = $web; running = [bool]($w.Count -and $w[0].state -eq 'running'); allRunning = (-not @($cs | Where-Object { $_.state -ne 'running' -and $_.status -notmatch 'Exited \(0\)' }).Count); http = $null }
  if ($out.running) {
    $primary = @(@($Manifest.services.($Manifest.web.service).ports) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary })[0]
    $c = @(Get-DockerContainerInventory -ProxyNetwork $Settings.ProxyNetwork | Where-Object { $_.name -eq $web })
    if ($c.Count) {
      $probe = $null
      for ($i = 0; $i -lt 10; $i++) { $probe = Test-ContainerPort -Container $c[0] -Port ([int]$primary.container) -ProxyNetwork $Settings.ProxyNetwork -Image $Settings.TraefikImage -NamePrefix $Settings.StackName -Schemes $(if ($primary.protocol -eq 'https') { @('https') } else { @('http', 'https') }); if ($probe.result -in 'http', 'https') { break }; Start-Sleep -Seconds 4 }
      $out.http = $probe
    }
  }
  return $out
}

function Find-InstalledApp([string]$Project) {
  $settings = Get-Settings
  $a = @(Read-AppsRegistry $settings | Where-Object { $_.project -eq $Project })
  if (-not $a.Count) { Stop-Request 404 "No app '$Project' was installed by this manager." }
  $compose = Join-Path $a[0].folder 'compose.yaml'
  # Only projects this manager generated are managed: an edited or foreign compose file is left alone.
  if (-not (Test-Path -LiteralPath $compose) -or ([IO.File]::ReadAllText($compose) -notmatch "org\.traefik-proxy\.project: $([regex]::Escape($Project))")) { Stop-Request 409 "$($a[0].folder) no longer holds the Compose project this manager created; manage it with docker compose directly." }
  return $a[0]
}

function Get-AppsData {
  Assert-Installed
  $settings = Get-Settings
  $registry = @((Read-ServiceRegistry -Settings $settings).services)
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  return [ordered]@{ apps = @(Read-AppsRegistry $settings | ForEach-Object {
        $a = $_
        $cs = @(Get-ComposeProjectContainers $a.project)
        $m = @($catalog | Where-Object { $_.id -eq $a.appId } | ForEach-Object { $_.manifest })
        $composePath = Join-Path $a.folder 'compose.yaml'
        $diff = @(); if ($m.Count -and (Test-Path -LiteralPath $composePath)) { $diff = @(Get-AppUpdateDiff $m[0] ([IO.File]::ReadAllText($composePath))) }
        [ordered]@{ project = $a.project; appId = $a.appId; name = $a.name; folder = $a.folder; installedAt = $a.installedAt; folderExists = (Test-Path -LiteralPath $composePath)
          containers = $cs; running = @($cs | Where-Object { $_.state -eq 'running' }).Count; total = $cs.Count
          localUrl = $(if ($a.PSObject.Properties['localUrl'] -and $a.localUrl) { [string]$a.localUrl } elseif ($a.PSObject.Properties['localPort'] -and [int]$a.localPort) { "http://127.0.0.1:$($a.localPort)/" } else { '' })
          routes = @($registry | Where-Object { $_.target.type -eq 'docker' -and @($cs | ForEach-Object { $_.name }) -contains $_.target.host } | ForEach-Object { [ordered]@{ name = $_.name; hostnames = @($_.hostnames); publish = [bool]$_.cloudflare.publish } })
          prepared = [bool]($a.PSObject.Properties['prepared'] -and $a.prepared -and $cs.Count -eq 0)
          updateAvailable = ($diff.Count -gt 0); updates = $diff; catalog = $(if ($m.Count) { [ordered]@{ web = $m[0].web; exposure = $m[0].exposure } } else { $null }) }
      }) }
}

function Invoke-AppAction($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  $action = [string](Get-Field $Body 'action' '')
  if ($action -notin 'start', 'stop', 'restart') { Stop-Request 400 "Unknown action '$action'." }
  if ($action -eq 'start' -and -not @(Get-ComposeProjectContainers $a.project).Count) {
    # First start of a prepared project: check memory again, then create the containers (downloads the pinned images).
    try { $mm = Get-CatalogApp -CatalogDir $CatalogDir -Id $a.appId; $need = Get-AppResourceEstimate $mm @{}; $res = Get-HostResources; $free = [Math]::Min($res.dockerFreeMB, $res.windowsFreeMB)
      if ($need.memoryMB -gt $free -and -not [bool](Get-Field $Body 'force' $false)) { Stop-Request 409 "$($a.name) needs about $($need.memoryMB) MB but only $free MB is free. Stop other apps first." } } catch [System.Management.Automation.RuntimeException] { if ($_.Exception.Message -match 'needs about') { throw } }
    $r = Invoke-Docker compose --project-directory $a.folder -f (Join-Path $a.folder 'compose.yaml') up -d
    $hp = Join-Path $a.folder '.post-install.json'
    if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $hp)) {
      $mm = Get-CatalogApp -CatalogDir $CatalogDir -Id $a.appId
      $stored = @([IO.File]::ReadAllText($hp) | ConvertFrom-Json)
      $health = Get-AppHealth $a.project $mm (Get-Settings) 90
      $lp = $(if ($a.PSObject.Properties['localPort']) { [int]$a.localPort } else { 0 })
      $hookSteps = @(Invoke-AppPostInstall $mm $a.project $lp $stored $health @((Read-AppEnv (Join-Path $a.folder '.env')).Values))
      if (-not @($hookSteps | Where-Object { $_.status -ne 'Done' }).Count) { Remove-Item -LiteralPath $hp -Force }
      $r.Output = @($r.Output) + @($hookSteps | ForEach-Object { "$($_.status): $($_.name) $($_.message)" })
    }
  } else { $r = Invoke-Docker compose --project-directory $a.folder -f (Join-Path $a.folder 'compose.yaml') $action }
  Write-Audit "app-$action" "$($a.project) exit=$($r.ExitCode)"
  return [ordered]@{ ok = ($r.ExitCode -eq 0); project = $a.project; action = $action; output = ((ConvertTo-RedactedText @($r.Output)) -join "`n"); containers = @(Get-ComposeProjectContainers $a.project) }
}

function Get-AppLogsData([string]$Project, [int]$Tail) {
  Assert-Installed
  $a = Find-InstalledApp $Project
  if ($Tail -lt 1 -or $Tail -gt 2000) { $Tail = 200 }
  $r = Invoke-Docker compose --project-directory $a.folder -f (Join-Path $a.folder 'compose.yaml') logs --no-color --tail $Tail
  $secrets = @((Read-AppEnv (Join-Path $a.folder '.env')).Values)
  return [ordered]@{ project = $a.project; lines = @(Hide-SecretValues @(ConvertTo-RedactedText @($r.Output)) $secrets) }
}

function Invoke-AppHealthRequest($Body) {
  Assert-Installed
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $a.appId } catch { Stop-Request 409 $_.Exception.Message }
  return Get-AppHealth $a.project $m (Get-Settings) 0
}

function Get-ImageMajor([string]$Image) {
  if ($Image -match ':([^@]+)@') { $t = $Matches[1] } elseif ($Image -match ':([^:/@]+)$') { $t = $Matches[1] } else { return '' }
  if ($t -match '(\d+)') { return $Matches[1] }
  return $t
}

# Backs up an app's configuration: compose.yaml, .env, its configuration folders and its named volumes (as .tar.gz),
# into <app folder>\backups\<time>\ (readable by the current user, SYSTEM and Administrators only). Apps with a database
# are stopped for the copy and started again, so the database files are consistent. Media and other volumes marked
# backup:false (caches, libraries, recordings) are skipped: they are the user's data, not configuration.
function Invoke-AppBackupCore($App, $Manifest, $Settings) {
  $dir = Join-Path $App.folder ("backups\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $copyFile = { param($from, $name) if (Test-Path -LiteralPath $from) { $to = Join-Path $dir $name; [IO.File]::WriteAllText($to, ''); Set-SecretFileAcl $to; [IO.File]::WriteAllBytes($to, [IO.File]::ReadAllBytes($from)) } }
  & $copyFile (Join-Path $App.folder 'compose.yaml') 'compose.yaml'
  & $copyFile (Join-Path $App.folder '.env') '.env'
  $values = @{}; foreach ($i in @(Get-Prop2 $Manifest 'inputs' @())) { if ($i.type -eq 'boolean') { $values["input:$($i.id)"] = 'true' } }
  $active = @(Get-ActiveServices $Manifest $values)
  $compose = [IO.File]::ReadAllText((Join-Path $App.folder 'compose.yaml'))
  $volumes = @(); $skipped = @(); $folders = @()
  foreach ($sp in $active) {
    if ($compose -notmatch "(?m)^  $([regex]::Escape($sp.Name)):\s*$") { continue }
    foreach ($v in @(Get-Prop2 $sp.Value 'volumes' @())) {
      $kind = Get-Prop2 $v 'kind' 'volume'
      if ($kind -eq 'project' -and (Get-Prop2 $v 'backup' $true)) { $folders += [string]$v.source }
      elseif ($kind -eq 'volume') { if (Get-Prop2 $v 'backup' $true) { $volumes += "$($App.project)_$($v.name)" } else { $skipped += "$($App.project)_$($v.name)" } }
    }
  }
  foreach ($f in ($folders | Select-Object -Unique)) {
    $src = Join-Path $App.folder ($f -replace '/', '\')
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $dir ($f -replace '/', '_')) -Recurse }
  }
  $stateful = @($active | Where-Object { Get-Prop2 $_.Value 'stateful' $false }).Count -gt 0
  $stopped = $false
  if ($stateful -and $volumes.Count) {
    $null = Invoke-Docker compose --project-directory $App.folder -f (Join-Path $App.folder 'compose.yaml') stop
    $stopped = $true
  }
  $results = @()
  try {
    foreach ($vn in ($volumes | Select-Object -Unique)) {
      if ((Invoke-Docker volume inspect $vn).ExitCode -ne 0) { continue }
      $r = Invoke-Docker run --rm --pull never --network none -v "${vn}:/v:ro" -v "${dir}:/b" --entrypoint tar $Settings.TraefikImage czf "/b/$vn.tar.gz" -C /v .
      $file = Join-Path $dir "$vn.tar.gz"
      if (Test-Path -LiteralPath $file) { Set-SecretFileAcl $file }
      $results += [ordered]@{ volume = $vn; ok = ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $file)); sizeMB = $(if (Test-Path -LiteralPath $file) { [Math]::Round((Get-Item -LiteralPath $file).Length / 1MB, 1) } else { 0 }) }
    }
  } finally {
    if ($stopped) { $null = Invoke-Docker compose --project-directory $App.folder -f (Join-Path $App.folder 'compose.yaml') start }
  }
  $info = [ordered]@{ app = $App.appId; project = $App.project; createdAt = (Get-Date -Format 's'); volumes = $results; skipped = $skipped; folders = @($folders | Select-Object -Unique); stoppedForBackup = $stopped }
  [IO.File]::WriteAllText((Join-Path $dir 'backup.json'), ($info | ConvertTo-Json -Depth 5))
  Write-Audit 'app-backup' "$($App.project) $dir volumes=$(@($results).Count)"
  return [ordered]@{ ok = -not @($results | Where-Object { -not $_.ok }).Count; folder = $dir; volumes = $results; skipped = $skipped; folders = $info.folders; stopped = $stopped }
}

function Invoke-AppBackup($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $a.appId } catch { Stop-Request 409 $_.Exception.Message }
  return Invoke-AppBackupCore $a $m (Get-Settings)
}

# Update preview: what the catalog would change, plus a notification when the registry now has a newer build under the
# same tag. Nothing is pulled. Database (stateful) services never change their major version through this path.
function Get-AppUpdateItems($App, $Manifest, [switch]$Registry) {
  $text = [IO.File]::ReadAllText((Join-Path $App.folder 'compose.yaml'))
  $installed = Get-ComposeServiceImages $text
  $items = @()
  foreach ($sp in $Manifest.services.PSObject.Properties) {
    if (-not $installed.Contains($sp.Name)) { continue }
    $from = [string]$installed[$sp.Name]; $to = [string]$sp.Value.image
    $stateful = [bool](Get-Prop2 $sp.Value 'stateful' $false)
    if ($from -ne $to) {
      $major = (Get-ImageMajor $from) -ne (Get-ImageMajor $to)
      $items += [ordered]@{ service = $sp.Name; kind = 'catalog'; from = $from; to = $to; stateful = $stateful; majorChange = $major; blocked = ($stateful -and $major)
        note = $(if ($stateful -and $major) { 'Database major-version upgrades need the application''s own migration procedure; not applied here.' } else { '' }) }
    }
    if ($Registry -and $from -match '^(.+:[^@]+)@(sha256:[0-9a-f]{64})$') {
      $tagRef = $Matches[1]; $pinned = $Matches[2]
      $r = Invoke-Docker buildx imagetools inspect $tagRef --format '{{json .Manifest.Digest}}'
      $now = ((@($r.Output) -join '') -replace '"', '').Trim()
      if ($r.ExitCode -eq 0 -and $now -match '^sha256:[0-9a-f]{64}$' -and $now -ne $pinned) {
        $items += [ordered]@{ service = $sp.Name; kind = 'registry'; from = $from; to = "$tagRef@$now"; stateful = $stateful; majorChange = $false; blocked = $stateful
          note = $(if ($stateful) { 'A newer build of the same tag exists. Database images are only changed together with a catalog update.' } else { 'A newer build of the same tag exists (security fixes are usually published this way).' }) }
      }
    }
  }
  return $items
}

function Invoke-AppUpdatePreview($Body) {
  Assert-Installed
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $a.appId } catch { Stop-Request 409 $_.Exception.Message }
  $items = @(Get-AppUpdateItems $a $m -Registry:([bool](Get-Field $Body 'registry' $true)))
  $applicable = @($items | Where-Object { -not $_.blocked })
  $key = Get-TextSha256 (($applicable | ForEach-Object { "$($_.service)|$($_.from)|$($_.to)" }) -join "`n")
  $notes = $(if ($m.PSObject.Properties['update'] -and $m.update.PSObject.Properties['notes']) { [string]$m.update.notes } else { '' })
  return [ordered]@{ project = $a.project; changes = $applicable; blocked = @($items | Where-Object { $_.blocked }); previewKey = $(if ($applicable.Count) { $key } else { '' }); notes = $notes
    releaseNotes = @(@(if ($m.PSObject.Properties['docs']) { $m.docs }) | Select-Object -First 1)
    keeps = @('A backup of the configuration and data volumes is made first (apps with a database are stopped for it).', 'compose.yaml is saved as compose.yaml.bak-<time>; only image lines change; your other edits stay.', 'Data volumes, media and library folders are never deleted by an update.') }
}

function Invoke-AppUpdateApply($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $a.appId
  $items = @(Get-AppUpdateItems $a $m -Registry:([bool](Get-Field $Body 'registry' $true)) | Where-Object { -not $_.blocked })
  $key = Get-TextSha256 (($items | ForEach-Object { "$($_.service)|$($_.from)|$($_.to)" }) -join "`n")
  if (-not $items.Count -or $key -ne [string](Get-Field $Body 'previewKey' '')) { Stop-Request 409 'The installed project, the catalog or the registry changed since the preview. Preview again.' }
  $settings = Get-Settings
  $backup = Invoke-AppBackupCore $a $m $settings
  if (-not $backup.ok) { Stop-Request 500 "The backup before the update failed ($($backup.folder)); nothing was updated." }
  $path = Join-Path $a.folder 'compose.yaml'
  $text = [IO.File]::ReadAllText($path)
  $bak = "$path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item -LiteralPath $path -Destination $bak
  foreach ($c in $items) { $text = $text.Replace("    image: $($c.from)", "    image: $($c.to)") }
  Write-TextFileAtomic $path $text
  $up = Invoke-Docker compose --project-directory $a.folder -f $path up -d
  Write-Audit 'app-update' "$($a.project) $(($items | ForEach-Object { $_.to }) -join ',') exit=$($up.ExitCode)"
  return [ordered]@{ ok = ($up.ExitCode -eq 0); project = $a.project; backup = (Split-Path -Leaf $bak); dataBackup = $backup.folder; changes = $items
    output = ((Hide-SecretValues @(ConvertTo-RedactedText @($up.Output)) @((Read-AppEnv (Join-Path $a.folder '.env')).Values)) -join "`n")
    health = $(if ($up.ExitCode -eq 0) { Get-AppHealth $a.project $m $settings 60 } else { $null }) }
}

# Removes an app's containers. Data volumes and the project folder are kept unless explicitly chosen (with the project
# name typed as confirmation); folders you chose for bind mounts are never touched.
function Invoke-AppRemove($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  $deleteVolumes = [bool](Get-Field $Body 'deleteVolumes' $false)
  $deleteFolder = [bool](Get-Field $Body 'deleteFolder' $false)
  if (($deleteVolumes -or $deleteFolder) -and [string](Get-Field $Body 'confirmText' '') -ne $a.project) { Stop-Request 400 "Type the project name ($($a.project)) to delete data." }
  $cs = @(Get-ComposeProjectContainers $a.project | ForEach-Object { $_.name })
  $routes = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.target.type -eq 'docker' -and $cs -contains $_.target.host } | ForEach-Object { $_.name })
  if ($routes.Count) { Stop-Request 409 "Remove the service route(s) $($routes -join ', ') on the Services page first, so the hostname does not answer 502." }
  $args2 = @('compose', '--project-directory', $a.folder, '-f', (Join-Path $a.folder 'compose.yaml'), 'down')
  if ($deleteVolumes) { $args2 += '-v' }
  $r = Invoke-Docker @args2
  if ($r.ExitCode -ne 0) { Stop-Request 500 "docker compose down failed: $((ConvertTo-RedactedText @($r.Output)) -join ' ')" }
  $folderRemoved = $false
  if ($deleteFolder) {
    foreach ($f in @(Get-ChildItem -LiteralPath $a.folder -Force -File)) { if ($f.Name -in 'compose.yaml', '.env', 'README.md', 'credentials.txt', '.post-install.json' -or $f.Name -like 'compose.yaml.bak-*') { $f.IsReadOnly = $false; Remove-Item -LiteralPath $f.FullName -Force } }
    if (-not @(Get-ChildItem -LiteralPath $a.folder -Force).Count) { Remove-Item -LiteralPath $a.folder -Force; $folderRemoved = $true }
  }
  Save-AppsRegistry $settings @(Read-AppsRegistry $settings | Where-Object { $_.project -ne $a.project })
  Write-Audit 'app-remove' "$($a.project) volumes=$deleteVolumes folder=$deleteFolder"
  $kept = @((Invoke-Docker volume ls -q --filter "name=$($a.project)_").Output | Where-Object { $_ })
  return [ordered]@{ removed = $true; project = $a.project; volumesDeleted = $deleteVolumes; keptVolumes = @($kept); folderRemoved = $folderRemoved; folder = $a.folder }
}

# --- Docker discovery and publishing ----------------------------------------------------------------------

function Get-DockerContainersData {
  Assert-Installed
  $settings = Get-Settings
  if (-not (Get-DockerStatus).EngineRunning) { Stop-Request 503 'The Docker engine is not reachable. Start Docker Desktop.' }
  $registry = @((Read-ServiceRegistry -Settings $settings).services)
  $own = @((Get-StackContainerNames $settings).Values) + @($settings.WhoamiContainer)
  $list = @(Get-DockerContainerInventory -ProxyNetwork $settings.ProxyNetwork | ForEach-Object {
      $name = $_.name
      $_.ownInstance = $own -contains $name
      $_.services = @($registry | Where-Object { $_.target.type -eq 'docker' -and $_.target.host -eq $name } | ForEach-Object { [ordered]@{ name = $_.name; hostnames = @($_.hostnames); port = $_.target.port } })
      $_
    })
  return [ordered]@{ proxyNetwork = $settings.ProxyNetwork; containers = $list; checkedAt = (Get-Date -Format 's') }
}

function Find-InventoryContainer([string]$Name) {
  if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { Stop-Request 400 'Invalid container name.' }
  $settings = Get-Settings
  $c = @(Get-DockerContainerInventory -ProxyNetwork $settings.ProxyNetwork | Where-Object { $_.name -eq $Name })
  if (-not $c.Count) { Stop-Request 404 "No container named '$Name'." }
  return $c[0]
}

function Get-HostnameClaimsData([string]$Hostname, [string]$ServiceName) {
  Assert-Installed
  $h = $Hostname.Trim().ToLowerInvariant()
  if ($h -notmatch '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { Stop-Request 400 'Enter a valid hostname.' }
  $settings = Get-Settings
  $containers = @(); try { $containers = @(Get-DockerContainerInventory -ProxyNetwork $settings.ProxyNetwork) } catch { }
  $dash = Read-DashboardConfig -Settings $settings
  $claims = Find-HostnameClaims -Hostname $h -Services @((Read-ServiceRegistry -Settings $settings).services) -Routers (Get-TraefikApi $settings '/api/http/routers') -Containers $containers -OwnService $ServiceName -DashboardHostname $(if ($dash.enabled) { $dash.hostname } else { '' })
  return [ordered]@{ hostname = $h; claims = @($claims); free = -not @($claims | Where-Object { $_.level -eq 'error' }).Count }
}

# Probes one container port with a short-lived probe container (see Test-ContainerPort). Changes nothing.
function Invoke-PortProbe($Body) {
  Assert-Installed
  $settings = Get-Settings
  $c = Find-InventoryContainer ([string](Get-Field $Body 'container' ''))
  $port = 0
  if (-not [int]::TryParse([string](Get-Field $Body 'port' ''), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { Stop-Request 400 'Enter a port from 1 to 65535.' }
  if ($port -in 2375, 2376) { Stop-Request 400 'The Docker Engine API port is never probed or published.' }
  $r = Test-ContainerPort -Container $c -Port $port -ProxyNetwork $settings.ProxyNetwork -Image $settings.TraefikImage -NamePrefix $settings.StackName
  Write-Audit 'port-probe' "$($c.name):$port $($r.method) $($r.result)"
  return $r
}

# Attaches a container to the shared network (docker network connect): a Docker change, so it needs confirm. The
# attachment lasts until the container is recreated; the response carries the Compose lines that make it permanent.
function Invoke-NetworkConnect($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $c = Find-InventoryContainer ([string](Get-Field $Body 'container' ''))
  $own = @((Get-StackContainerNames $settings).Values)
  if ($own -contains $c.name) { Stop-Request 400 'The containers of this deployment are managed by its compose.yaml.' }
  if ($c.infrastructure) { Stop-Request 400 "$($c.name) looks like proxy or tunnel infrastructure; it is not attached automatically." }
  if ($c.Contains('privateService') -and $c.privateService) { Stop-Request 400 "$($c.name) is a database, cache, message broker or directory server: it stays on its private network and is not attached to '$($settings.ProxyNetwork)'." }
  $snippet = @("services:", "  $(if ($c.compose.service) { $c.compose.service } else { $c.name }):", '    networks:', "      - $($settings.ProxyNetwork)", 'networks:', "  $($settings.ProxyNetwork):", '    external: true')
  if ($c.onProxyNetwork) { return [ordered]@{ connected = $true; changed = $false; message = "$($c.name) is already attached to '$($settings.ProxyNetwork)'."; composeSnippet = $snippet } }
  $r = Invoke-Docker network connect $settings.ProxyNetwork $c.name
  Write-Audit 'network-connect' "$($c.name) -> $($settings.ProxyNetwork) exit=$($r.ExitCode)"
  if ($r.ExitCode -ne 0) { Stop-Request 500 "docker network connect failed: $((@($r.Output) -join ' ').Trim())" }
  return [ordered]@{ connected = $true; changed = $true; message = "$($c.name) is now attached to '$($settings.ProxyNetwork)'. It stays attached until the container is recreated; add the lines below to its compose file to keep it."; composeSnippet = $snippet; workingDir = $c.compose.workingDir }
}

function Invoke-ServiceHealth($Body) {
  Assert-Installed
  $settings = Get-Settings
  $svc = Find-RegistryService @((Read-ServiceRegistry -Settings $settings).services) ([string](Get-Field $Body 'name' ''))
  return Get-ServiceHealth -Settings $settings -Service $svc -Public:([bool](Get-Field $Body 'public' $false))
}

# The recorded tunnel as Cloudflare reports it (one read-only GET), or $null without a readable token.
function Get-TunnelInfo($Settings, $Status, $Cf) {
  if (-not ($Status.cloudflare.tokenStored -and $Status.cloudflare.tokenReadable -and $Cf.accountId -and $Cf.tunnelId)) { return $null }
  try {
    $t = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($Cf.accountId)/cfd_tunnel/$($Cf.tunnelId)"
    return [ordered]@{ name = [string]$t.name; status = [string]$t.status; connections = @($(if ($t.PSObject.Properties['connections']) { $t.connections } else { @() })).Count; error = '' }
  } catch { return [ordered]@{ name = $Cf.tunnelName; status = 'unknown'; connections = 0; error = $_.Exception.Message } }
}

# Infrastructure Explorer: every component of the request path with what has actually been established about it.
# Read-only (Docker inspect, Traefik's local API, one Cloudflare GET for the tunnel).
function Get-InfrastructureData {
  $status = Get-StatusData
  $settings = Get-Settings
  $installed = Test-Installed
  $cf = Read-CloudflareConfig -Settings $settings
  $mode = (Read-SetupDraft).deployment.mode
  if (-not $mode -and $installed) { $mode = $(if (Test-TunnelTokenFile $settings) { 'tunnel' } else { 'local' }) }
  $services = @()
  if ($installed) { try { $services = @((Read-ServiceRegistry -Settings $settings).services) } catch { } }
  $dash = Read-DashboardConfig -Settings $settings
  $base = [ordered]@{
    mode = $mode; installed = $installed; stackName = $settings.StackName; httpPort = $settings.HttpPort; dashboardPort = $settings.DashboardPort
    proxyNetwork = $settings.ProxyNetwork; cloudflaredIp = $settings.CloudflaredIp; docker = $status.docker; stack = $status.stack
    services = $services; cloudflare = $cf; token = (Get-CloudflareApiTokenInfo -Settings $settings); tunnel = (Get-TunnelInfo $settings $status $cf)
    tunnelTokenPresent = [bool]$status.stack.TunnelTokenPresent; dashboard = [ordered]@{ enabled = [bool]$dash.enabled; hostname = [string]$dash.hostname; router = (Get-DashboardRouterName) }
  }
  $facts = Get-InfrastructureFacts -Settings $settings -Base $base
  $model = ConvertTo-InfrastructureModel -Facts $facts
  $model.instance = [ordered]@{ stackName = $settings.StackName; installPath = $InstallPath; httpPort = $settings.HttpPort; dashboardPort = $settings.DashboardPort; proxyNetwork = $settings.ProxyNetwork; tunnelNetwork = $settings.TunnelNetwork }
  $model.dashboard = [ordered]@{ localUrl = "http://127.0.0.1:$($settings.DashboardPort)/dashboard/"; publicUrl = $(if ($dash.enabled -and $dash.hostname) { "https://$($dash.hostname)/dashboard/" } else { '' }) }
  $model.checkedAt = (Get-Date -Format 's')
  return $model
}

function Get-OverviewData {
  $status = Get-StatusData
  $settings = Get-Settings
  $installed = Test-Installed
  $dash = Get-DashboardData
  $services = @(); $issues = @()
  if ($installed) { try { $reg = Read-ServiceRegistry -Settings $settings; $services = @($reg.services); $issues = @((Get-ServicePlan -Settings $settings -Services $services).Issues | Where-Object { $_.Level -eq 'Error' }) } catch { } }
  $cf = Read-CloudflareConfig -Settings $settings
  $mode = (Read-SetupDraft).deployment.mode
  if (-not $mode -and $installed) { $mode = $(if (Test-TunnelTokenFile $settings) { 'tunnel' } else { 'local' }) }
  $tunnel = Get-TunnelInfo $settings $status $cf
  $warnings = @()
  $c = @{}; foreach ($x in @($status.stack.Containers)) { $c[$x.Role] = $x }
  if ($installed) {
    foreach ($role in @('traefik', 'socket-proxy')) { if ($c[$role].State -ne 'running') { $warnings += "Container $($c[$role].Name) is $($c[$role].State)." } }
    if ($mode -eq 'tunnel' -and $c['cloudflared'].State -ne 'running') { $warnings += "The tunnel connector ($($c['cloudflared'].Name)) is $($c['cloudflared'].State)." }
    if ($c['traefik'].State -eq 'running' -and -not $status.stack.TraefikApi) { $warnings += 'Traefik is running but its API does not answer.' }
    if ($status.services.drift -gt 0) { $warnings += "$($status.services.drift) route file(s) differ from the service registry." }
    if (@($issues).Count -gt 0) { $warnings += "$(@($issues).Count) service definition error(s)." }
  }
  if ($status.cloudflare.tokenStored -and -not $status.cloudflare.tokenReadable) { $warnings += 'The stored Cloudflare API token cannot be decrypted by this Windows account.' }
  if ($tunnel -and $tunnel.status -ne 'healthy' -and $mode -eq 'tunnel') { $warnings += "Cloudflare reports the tunnel as '$($tunnel.status)'." }
  $recent = @()
  $file = Join-Path $InstallPath 'logs\webui-audit.log'
  if (Test-Path -LiteralPath $file) {
    $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
    try { $null = $fs.Seek([Math]::Max(0, $fs.Length - 32768), 'Begin'); $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
    $recent = @($text -split "`r?`n" | Where-Object { $_ -match '^\d{4}-' } | Select-Object -Last 8)
    [array]::Reverse($recent)
  }
  $upgrade = $null
  if ($installed) { try { $upgrade = Get-UpgradeStatus -Path $InstallPath -SourceRoot $here } catch { } }
  return [ordered]@{
    installed = $installed; mode = $mode; status = $status; dashboard = $dash; tunnel = $tunnel; upgrade = $upgrade; path = $InstallPath
    domains = @($cf.domains); services = [ordered]@{ total = $services.Count; enabled = @($services | Where-Object { $_.enabled }).Count; published = @($services | Where-Object { $_.enabled -and $_.cloudflare.publish }).Count }
    warnings = $warnings; recent = $recent
  }
}

# Expert view: the generated configuration of this instance and the commands the tool runs. Non-secret files only;
# anything credential-like is withheld.
function Get-ExpertConfigData {
  $settings = Get-Settings
  $files = New-Object System.Collections.ArrayList
  $envPath = Join-Path $InstallPath '.env'
  if (Test-Path -LiteralPath $envPath) { $null = $files.Add([ordered]@{ path = '.env (known keys)'; content = (Get-FilteredEnv $envPath) }) }
  else { $null = $files.Add([ordered]@{ path = '.env (would be written)'; content = (New-DotEnvContent ([IO.File]::ReadAllText((Join-Path $here '.env.example'))) (Get-EnvValues $settings)) }) }
  $rels = @('config\setup.json', 'config\cloudflare.json', 'config\dashboard.json', 'config\services.json')
  if (Test-Path -LiteralPath $settings.DynamicDir) { $rels += @(Get-ChildItem -LiteralPath $settings.DynamicDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' } | ForEach-Object { "traefik\dynamic\$($_.Name)" }) }
  foreach ($rel in $rels) {
    $p = Join-Path $InstallPath $rel
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $text = ([IO.File]::ReadAllText($p)).Replace("`r`n", "`n")
    $hit = Find-CredentialPattern $text
    if (-not $hit -and (Test-TextContainsApiToken -Settings $settings -Text $text)) { $hit = 'the API token' }
    $null = $files.Add([ordered]@{ path = $rel; content = $(if ($hit) { "(withheld: contains what looks like $hit)" } else { $text }) })
  }
  $mode = (Read-SetupDraft).deployment.mode
  $compose = (@('docker') + @(Get-ComposeArgs -Settings $settings -Profiles @($(if ($mode -eq 'tunnel') { 'tunnel' }) | Where-Object { $_ })) + @('up', '-d', '--wait')) | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } }
  return [ordered]@{
    installPath = $InstallPath; sourcePath = $here; managerVersion = Get-ManagerVersion
    commands = @(
      [ordered]@{ purpose = 'Preview the installation (changes nothing)'; command = "powershell -ExecutionPolicy Bypass -File `"$here\install.ps1`" -InstallPath `"$InstallPath`" -DryRun" }
      [ordered]@{ purpose = 'Install and start'; command = "powershell -ExecutionPolicy Bypass -File `"$here\install.ps1`" -InstallPath `"$InstallPath`" -Start$(if ($mode -eq 'tunnel') { ' -EnableTunnel' })" }
      [ordered]@{ purpose = 'What the installer runs to start this instance'; command = ($compose -join ' ') }
      [ordered]@{ purpose = 'Re-read traefik\dynamic without a restart'; command = "powershell -ExecutionPolicy Bypass -File `"$InstallPath\install.ps1`" -InstallPath `"$InstallPath`" -Reload" }
      [ordered]@{ purpose = 'Stop this instance only'; command = "powershell -ExecutionPolicy Bypass -File `"$InstallPath\install.ps1`" -InstallPath `"$InstallPath`" -Stop" }
    )
    images = Get-ComposeImages $(if (Test-Installed) { Join-Path $InstallPath 'compose.yaml' } else { Join-Path $here 'compose.yaml' })
    containers = Get-StackContainerNames $settings
    networks = [ordered]@{ proxy = $settings.ProxyNetwork; tunnel = $settings.TunnelNetwork; tunnelSubnet = $settings.TunnelSubnet; tunnelIpRange = $settings.TunnelIpRange; cloudflaredIp = $settings.CloudflaredIp }
    files = $files.ToArray()
  }
}

# --- Projects: discover, attach, start new, upgrade --------------------------------------------------------------
# Attach opens an existing deployment as it is: nothing in its folder, in Docker or in Cloudflare changes. Upgrade
# updates its application files (a separate, confirmed step). Restore (Backups page) recovers configuration from a file.

function Get-ProjectPathFromBody($Body) {
  try { return ConvertTo-ProjectPath ([string](Get-Field $Body 'path' '')) } catch { Stop-Request 400 $_.Exception.Message }
}

function Get-ProjectsData {
  $st = Read-ManagerState
  $remembered = @($st.recent | ForEach-Object { $_.path })
  $candidates = @(Find-ProjectCandidates -Remembered $remembered -SourceRoot $here -ProjectsRoot $ProjectsRoot)
  $list = @(foreach ($c in $candidates) {
      $sum = Get-ProjectSummary -Path $c.path -SourceRoot $here
      if ($sum.kind -in @('other', 'package') -and @($c.sources) -notcontains 'recent') { continue }
      $rec = @($st.recent | Where-Object { Test-SamePath $_.path $c.path })
      [ordered]@{ summary = $sum; sources = @($c.sources); recent = ($rec.Count -gt 0); lastOpened = $(if ($rec.Count) { $rec[0].lastOpened } else { '' }); active = ((Test-SamePath $c.path $InstallPath) -and $State.Chosen) }
    })
  $list = @($list | Sort-Object @{ e = { -not $_.active } }, @{ e = { -not $_.recent } }, @{ e = { $_.lastOpened }; Descending = $true })
  return [ordered]@{
    chosen = [bool]$State.Chosen; activePath = $InstallPath; activeInstalled = (Test-Installed)
    projects = $list; projectsRoot = $ProjectsRoot; sourcePath = $here
    suggestedNewPath = (Get-NewProjectSuggestion)
  }
}

# A free folder name under the Docker projects folder for a new deployment.
function Get-NewProjectSuggestion {
  $base = Join-Path $ProjectsRoot 'traefik-proxy'
  if (-not (Test-Path -LiteralPath $base)) { return $base }
  for ($i = 2; $i -le 50; $i++) { $p = "$base-$i"; if (-not (Test-Path -LiteralPath $p)) { return $p } }
  return "$base-new"
}

function Invoke-ProjectInspect($Body) {
  $path = Get-ProjectPathFromBody $Body
  $r = Get-ProjectInspection -Path $path -SourceRoot $here -Cloudflare:([bool](Get-Field $Body 'cloudflare' $true))
  return $r
}

# Makes the folder the active project. Reads only; resets previews that belonged to the previous project.
function Set-ActiveProject([string]$Path) {
  $script:InstallPath = $Path
  $State.Chosen = $true
  $State.Plans.Clear(); $State.Imports.Clear(); $State.Upgrades.Clear(); $State.AppPlans.Clear()
  Save-RememberedPath
}

function Invoke-ProjectAttach($Body) {
  $path = Get-ProjectPathFromBody $Body
  $kind = Get-ProjectKind $path
  if ($kind -eq 'missing') { Stop-Request 404 "The folder $path does not exist (moved or deleted). Remove it from the list or choose its new location." }
  if ($kind -eq 'legacy') { Stop-Request 409 'This folder uses the earlier single-app layout, which this manager does not manage. It was left unchanged. See "Migrating from the earlier single-app layout" in the README.' }
  if ($kind -in @('other', 'package')) { Stop-Request 409 "$path is not a deployment of this tool. Choose the folder that contains its .env and compose.yaml, or start a new deployment." }
  $i = Get-ProjectInspection -Path $path -SourceRoot $here -NoDocker
  if (-not $i.usable) { Stop-Request 409 ('This deployment cannot be opened: ' + (@($i.blockers) -join ' ')) }
  Set-ActiveProject $path
  return [ordered]@{ attached = $true; path = $path; installed = (Test-Installed); stackName = (Get-Settings).StackName }
}

# A new deployment in a folder without one. Nothing is written until the setup journey saves its first choice.
function Invoke-ProjectNew($Body) {
  $path = Get-ProjectPathFromBody $Body
  $kind = Get-ProjectKind $path
  if ($kind -in @('manager', 'legacy')) { Stop-Request 409 "$path already contains a deployment. Open it instead (Continue where you left off); starting a new deployment there is refused." @{ needsAttach = $true } }
  if ($kind -eq 'package') { Stop-Request 409 'That is a copy of the manager itself. Choose an empty folder for the new deployment.' }
  if ($kind -eq 'other' -and @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count -gt 0) { Stop-Request 409 "$path is not empty. Choose an empty or new folder for the deployment." }
  Set-ActiveProject $path
  return [ordered]@{ path = $path; draft = ($kind -eq 'draft') }
}

function Invoke-ProjectForget($Body) {
  $path = Get-ProjectPathFromBody $Body
  $st = Read-ManagerState
  $st.recent = @($st.recent | Where-Object { -not (Test-SamePath $_.path $path) })
  if (Test-SamePath $st.installPath $path) { $st.installPath = '' }
  Save-ManagerState $st
  return [ordered]@{ removed = $path }
}

function Get-FolderBrowseData([string]$Path) {
  $roots = @(Get-FolderRoots)
  if (-not $Path) { $Path = $(if (Test-Path -LiteralPath $ProjectsRoot) { $ProjectsRoot } else { $env:USERPROFILE }) }
  try { $l = Get-FolderListing -Path $Path } catch { Stop-Request 400 $_.Exception.Message }
  return [ordered]@{ path = $l.path; parent = $l.parent; kind = $l.kind; entries = @($l.entries); roots = $roots }
}

# install.ps1 -DryRun for a deployment folder: which application files an upgrade would update (changes nothing).
function Invoke-UpgradePreview($Body) {
  $path = Get-ProjectPathFromBody $Body
  if ((Get-ProjectKind $path) -ne 'manager') { Stop-Request 409 'Only an installed deployment of this tool can be upgraded.' }
  $u = Get-UpgradeStatus -Path $path -SourceRoot $here
  $r = Invoke-PowerShellFile (Join-Path $here 'install.ps1') @('-InstallPath', $path, '-DryRun')
  $files = @($r.Lines | ForEach-Object {
      if ($_ -match '^\s+\[dry-run\] (update|add)\s+(\S+)') { [ordered]@{ action = $Matches[1]; file = $Matches[2] } }
      elseif ($_ -match '^\s+\[dry-run\] keep\s+(\S+)') { [ordered]@{ action = 'keep'; file = $Matches[1] } } })
  $key = Get-TextSha256 ((ConvertTo-Json -Compress -Depth 4 -InputObject @($path, $u.changed, $u.added, $u.modified)))
  $State.Upgrades[$key] = [pscustomobject]@{ Path = $path; Created = (Get-Date) }
  return [ordered]@{
    path = $path; upgrade = $u; ok = ($r.ExitCode -eq 0); files = $files; lines = $r.Lines; previewKey = $key
    notes = @(
      'Only application files (scripts, web pages, packaged Traefik files) are updated. .env, config\, secrets\, generated routes, backups and logs are kept.'
      'Files you edited by hand are kept; the new version is written next to them as <file>.dist.'
      $(if ($u.composeChanged) { 'compose.yaml changes: the running containers keep their current settings until you restart the instance (install.ps1 -Start). Nothing is restarted by the upgrade.' } else { 'compose.yaml is unchanged: no container needs a restart.' })
      'The previous copies are saved in backups\<time>\ and can be restored with install.ps1 -Rollback.'
    )
  }
}

function Invoke-UpgradeApply($Body) {
  Assert-Confirmed $Body
  $path = Get-ProjectPathFromBody $Body
  $key = [string](Get-Field $Body 'previewKey' '')
  if (-not $key -or -not $State.Upgrades.ContainsKey($key) -or -not (Test-SamePath $State.Upgrades[$key].Path $path)) { Stop-Request 409 'Preview the upgrade first.' }
  $u = Get-UpgradeStatus -Path $path -SourceRoot $here
  $now = Get-TextSha256 ((ConvertTo-Json -Compress -Depth 4 -InputObject @($path, $u.changed, $u.added, $u.modified)))
  if ($now -ne $key) { Stop-Request 409 'The files changed since the preview. Preview the upgrade again.' }
  $State.Upgrades.Remove($key)
  $recovery = $null
  try { $recovery = New-RecoveryPoint -Settings (Get-ProjectSettings $path) -Reason 'before upgrade' -SourceRoot $here } catch { Stop-Request 500 "No change was made: the recovery point could not be written ($($_.Exception.Message))." }
  $r = Invoke-PowerShellFile (Join-Path $here 'install.ps1') @('-InstallPath', $path)
  if (Test-SamePath $path $InstallPath) { Write-Audit 'upgrade' "exit=$($r.ExitCode) recovery=$recovery" }
  return [ordered]@{ ok = ($r.ExitCode -eq 0); lines = $r.Lines; recoveryPoint = $recovery; upgrade = (Get-UpgradeStatus -Path $path -SourceRoot $here) }
}

function Invoke-ManagerStop($Body) {
  Assert-Confirmed $Body
  if (-not $StopFile) { Stop-Request 409 'This manager was started without a stop file. Close its PowerShell window (or press Ctrl+C there) to stop it.' }
  [IO.File]::WriteAllText($StopFile, 'stop')
  return [ordered]@{ stopping = $true }
}

# --- Router ----------------------------------------------------------------------------------------------------

function Invoke-ApiRoute($Request, $Body) {
  $m = $Request.Method
  $p = $Request.Path
  # Until a deployment is chosen, nothing may change any folder: only the project and manager actions are allowed.
  if (-not $State.Chosen -and $m -ne 'GET' -and -not ($p.StartsWith('/api/projects/') -or $p -eq '/api/manager/stop')) {
    Stop-Request 409 'Choose a deployment first (open an existing one or start a new one).'
  }
  $settings = Get-Settings
  switch -Exact ("$m $p") {
    'GET /api/session' { return [ordered]@{ ok = $true } }
    'GET /api/status' { return Get-StatusData }
    'GET /api/services' { return Get-ServicesData }
    'POST /api/services/plan' { return Invoke-PlanRequest $Body }
    'POST /api/services/apply' { return Invoke-ApplyRequest $Body }
    'POST /api/validate' {
      if (-not (Test-Installed)) { return [ordered]@{ ok = $false; installed = $false; message = (Get-NotInstalledMessage); issues = @(); drift = 0; deep = $null } }
      $registry = Read-ServiceRegistry -Settings $settings
      $plan = Get-ServicePlan -Settings $settings -Services $registry.services
      $out = [ordered]@{ ok = -not $plan.HasErrors; installed = $true; message = ''; issues = @($plan.Issues); drift = $plan.FileChanges; deep = $null }
      if ([bool](Get-Field $Body 'deep' $false)) {
        $deep = Test-TraefikDynamicConfig -Settings $settings -Plan $plan
        $out.deep = $deep
        $out.ok = $out.ok -and $deep.Ok
      }
      return $out
    }
    'GET /api/backups' { return Get-BackupsData }
    'GET /api/backups/export' {
      $format = [string]$Request.Query['format']
      if ($format -eq 'zip') {
        $a = New-ConfigBackupArchive -Settings $settings -SourceRoot $here
        Write-Audit 'backup-export' "zip files=$(@($a.Manifest.archive.files).Count) excluded=$(@($a.Excluded).Count)"
        return New-Download $a.FileName 'application/zip' $a.Bytes
      }
      if ($format -ne 'json') { Stop-Request 400 "Unknown export format '$format'." }
      $e = Export-ConfigManifest -Settings $settings -SourceRoot $here
      Write-Audit 'backup-export' 'json'
      return New-Download $e.FileName 'application/json; charset=utf-8' $e.Text
    }
    'GET /api/backups/recovery/download' {
      $id = [string]$Request.Query['id']
      try { [byte[]]$bytes = Get-RecoveryPointBytes -Settings $settings -Id $id } catch { Stop-Request 404 $_.Exception.Message }
      return New-Download $id 'application/zip' $bytes
    }
    'POST /api/backups/import/preview' { return Invoke-ImportPreview $Body }
    'POST /api/backups/import/apply' { return Invoke-ImportApply $Body }
    'GET /api/projects' { return Get-ProjectsData }
    'POST /api/projects/inspect' { return Invoke-ProjectInspect $Body }
    'POST /api/projects/attach' { return Invoke-ProjectAttach $Body }
    'POST /api/projects/new' { return Invoke-ProjectNew $Body }
    'POST /api/projects/forget' { return Invoke-ProjectForget $Body }
    'GET /api/projects/browse' { return Get-FolderBrowseData ([string]$Request.Query['path']) }
    'POST /api/projects/upgrade/preview' { return Invoke-UpgradePreview $Body }
    'POST /api/projects/upgrade/apply' { return Invoke-UpgradeApply $Body }
    'POST /api/manager/stop' { return Invoke-ManagerStop $Body }
    'GET /api/dashboard' { return Get-DashboardData }
    'POST /api/dashboard/settings' { return Save-DashboardSettingsRequest $Body }
    'GET /api/overview' { return Get-OverviewData }
    'GET /api/infrastructure' { return Get-InfrastructureData }
    'GET /api/docker/containers' { return Get-DockerContainersData }
    'GET /api/docker/claims' { return Get-HostnameClaimsData ([string]$Request.Query['hostname']) ([string]$Request.Query['service']) }
    'POST /api/docker/probe' { return Invoke-PortProbe $Body }
    'POST /api/docker/connect' { return Invoke-NetworkConnect $Body }
    'POST /api/services/health' { return Invoke-ServiceHealth $Body }
    'GET /api/catalog' { return Get-CatalogData }
    'GET /api/catalog/defaults' { try { $cm = Get-CatalogApp -CatalogDir $CatalogDir -Id ([string]$Request.Query['id']) } catch { Stop-Request 404 $_.Exception.Message }; Assert-Installed; return Get-AppDefaults $cm (Get-Settings) }
    'POST /api/catalog/plan' { return Invoke-AppPlan $Body }
    'POST /api/catalog/apply' { return Invoke-AppApply $Body }
    'GET /api/apps' { return Get-AppsData }
    'POST /api/apps/action' { return Invoke-AppAction $Body }
    'GET /api/apps/logs' { $tl = 200; [int]::TryParse([string]$Request.Query['tail'], [ref]$tl) | Out-Null; return Get-AppLogsData ([string]$Request.Query['project']) $tl }
    'POST /api/apps/health' { return Invoke-AppHealthRequest $Body }
    'POST /api/apps/update/preview' { return Invoke-AppUpdatePreview $Body }
    'POST /api/apps/update/apply' { return Invoke-AppUpdateApply $Body }
    'POST /api/apps/remove' { return Invoke-AppRemove $Body }
    'POST /api/apps/backup' { return Invoke-AppBackup $Body }
    'GET /api/system/resources' { return Get-HostResources }
    'GET /api/environment' { return Get-EnvironmentData }
    'GET /api/expert/config' { return Get-ExpertConfigData }
    'POST /api/setup/contact' { return Set-ContactEmailRequest $Body }
    'POST /api/dashboard/plan' { return Invoke-DashboardPlanRequest $Body }
    'POST /api/dashboard/apply' { return Invoke-DashboardApplyRequest $Body }
    'POST /api/dashboard/verify' { return Invoke-DashboardVerifyRequest $Body }
    'POST /api/backups/preview' { return Get-BackupPreview $Body }
    'POST /api/backups/restore' {
      Assert-Installed
      Assert-Confirmed $Body
      $id = [string](Get-Field $Body 'id' '')
      if (@(Get-ServiceBackups $settings | Where-Object { $_.Id -eq $id }).Count -eq 0) { Stop-Request 404 "No backup '$id'." }
      $null = New-ChangeRecoveryPoint "before rollback to $id"
      $r = Restore-ServiceBackup -Settings $settings -Id $id
      Write-Audit 'rollback' "restored=$($r.Restored) saved=$($r.SavedCurrentAs)"
      return [ordered]@{ restored = $r.Restored; savedCurrentAs = $r.SavedCurrentAs; warning = $r.ReloadWarning }
    }
    'GET /api/logs' {
      $role = [string]$Request.Query['role']
      if (@((Get-StackContainerNames $settings).Keys) -notcontains $role) { Stop-Request 400 "Unknown container '$role'." }
      $tail = 200
      if ($Request.Query.ContainsKey('tail')) { [int]::TryParse($Request.Query['tail'], [ref]$tail) | Out-Null }
      if (-not (Test-Installed)) { return [ordered]@{ Container = (Get-StackContainerNames $settings)[$role]; Ok = $false; Lines = @(Get-NotInstalledMessage) } }
      return Get-StackLogs -Settings $settings -Role $role -Tail $tail
    }
    'GET /api/audit' {
      $file = Join-Path $InstallPath 'logs\webui-audit.log'
      $lines = @()
      if (Test-Path -LiteralPath $file) {
        # Last 256 KB only; Get-Content -Tail can spin forever on Windows PowerShell 5.1.
        $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        try {
          $start = [Math]::Max(0, $fs.Length - 262144)
          $null = $fs.Seek($start, 'Begin')
          $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd()
        } finally { $fs.Dispose() }
        $lines = @($text -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 200)
      }
      return [ordered]@{ lines = $lines }
    }
    'POST /api/diagnostics' {
      $script = Join-Path $here 'scripts\Get-Diagnostics.ps1'
      $r = Invoke-PowerShellFile $script @('-ProjectPath', $InstallPath)
      return [ordered]@{ ok = ($r.ExitCode -eq 0); lines = $r.Lines }
    }
    'POST /api/install/preview' {
      $r = Invoke-PowerShellFile (Join-Path $here 'install.ps1') @('-InstallPath', $InstallPath, '-DryRun')
      return [ordered]@{ ok = ($r.ExitCode -eq 0); lines = $r.Lines }
    }
    'POST /api/install/run' {
      Assert-Confirmed $Body
      $args2 = @('-InstallPath', $InstallPath, '-Start')
      if ([bool](Get-Field $Body 'enableTunnel' $false)) { $args2 += '-EnableTunnel' }
      $r = Invoke-PowerShellFile (Join-Path $here 'install.ps1') $args2
      Write-Audit 'install' "exit=$($r.ExitCode)"
      return [ordered]@{ ok = ($r.ExitCode -eq 0); lines = $r.Lines }
    }
    'GET /api/cloudflare' { return Get-CloudflareData }
    'POST /api/cloudflare/token' { return Save-TokenRequest $Body }
    'POST /api/cloudflare/token/delete' {
      Assert-Confirmed $Body
      $removed = Remove-CloudflareApiToken -Settings $settings
      Write-Audit 'cloudflare-token-removed' ''
      return [ordered]@{ removed = $removed }
    }
    'GET /api/cloudflare/accounts' {
      if (-not (Get-CloudflareApiTokenInfo -Settings $settings).Stored) { Stop-Request 409 'Save a Cloudflare API token first.' }
      return [ordered]@{ accounts = @(Invoke-CloudflareApi -Settings $settings -Path '/accounts' -All | ForEach-Object { [ordered]@{ id = [string]$_.id; name = [string]$_.name } }) }
    }
    'GET /api/cloudflare/zones' {
      # Only the allowed domains: services can be published under these and nothing else.
      $config = Assert-CloudflareReady
      return [ordered]@{ zones = @(Select-AllowedZones $config (Get-CloudflareZones -Settings $settings -AccountId $config.accountId)) }
    }
    'GET /api/cloudflare/discovery' { return Get-DiscoveryRequest }
    'POST /api/cloudflare/domains' { return Set-DomainsRequest $Body }
    'GET /api/setup' { return Get-SetupData }
    'POST /api/setup/path' { return Set-InstallPathRequest $Body }
    'POST /api/setup/settings' { return Save-SettingsRequest $Body }
    'POST /api/setup/suggest' {
      Assert-NotInstalled 'The instance settings'
      $s = Get-SuggestedStackSettings -InstallPath $InstallPath
      return [ordered]@{ settings = ConvertTo-InstanceValues $s; conflicts = @(Get-StackConflicts -Settings $s) }
    }
    'POST /api/setup/check' { return [ordered]@{ settings = ConvertTo-InstanceValues $settings; conflicts = @(Get-StackConflicts -Settings $settings) } }
    'POST /api/setup/deployment' { return Set-DeploymentRequest $Body }
    'POST /api/setup/preview' { return Get-InstallPlan }
    'POST /api/setup/install' { return Invoke-InstallRequest $Body }
    'GET /api/cloudflare/tunnels' {
      $config = Assert-CloudflareReady
      return [ordered]@{ tunnels = @(Get-CloudflareTunnels -Settings $settings -AccountId $config.accountId) }
    }
    'POST /api/cloudflare/select' { return Select-CloudflareRequest $Body }
    'POST /api/cloudflare/tunnel' { return New-TunnelRequest $Body }
    'POST /api/cloudflare/connector' { return Install-ConnectorRequest $Body }
  }
  Stop-Request 404 "No such endpoint: $m $p"
}

function Invoke-Request($Request) {
  # DNS-rebinding protection: only our own loopback origin may talk to us.
  $hostHeader = if ($Request.Headers.ContainsKey('host')) { $Request.Headers['host'].ToLowerInvariant() } else { '' }
  if ($State.Hosts -notcontains $hostHeader) {
    return @{ Status = 421; Body = "Unexpected Host header.`n"; Headers = $SecurityHeaders }
  }
  $path = $Request.Path

  if (-not $path.StartsWith('/api/')) {
    if ($Request.Method -ne 'GET') { return @{ Status = 405; Body = "Method not allowed.`n"; Headers = $SecurityHeaders } }
    if ($path -eq '/' -and $Request.Query.ContainsKey('k')) {
      if (-not (Test-ConstantTimeEqual ([string]$Request.Query['k']) $State.LaunchKey)) { return @{ Status = 403; Body = "Invalid or expired link. Use the link printed by webui.ps1.`n"; Headers = $SecurityHeaders } }
      $sid = New-RandomKey
      $State.Sessions[$sid] = [pscustomobject]@{ Csrf = (New-RandomKey); Created = (Get-Date) }
      # Launcher mode: a link works once (it may linger in browser history or a process listing); the next one is
      # written to the user-only link file for "open again".
      if ($SingleUseLaunch) { $State.LaunchKey = New-RandomKey; Write-LaunchUrlFile }
      $h = @{} + $SecurityHeaders
      $h['Set-Cookie'] = "$($State.Cookie)=$sid; Path=/; HttpOnly; SameSite=Strict"
      $h['Location'] = '/'
      return @{ Status = 303; Body = ''; Headers = $h }
    }
    if (-not $StaticFiles.ContainsKey($path)) { return @{ Status = 404; Body = "Not found.`n"; Headers = $SecurityHeaders } }
    $file = $StaticFiles[$path]
    return @{ Status = 200; ContentType = $file[1]; Body = [IO.File]::ReadAllBytes((Join-Path $StaticRoot $file[0])); Headers = $SecurityHeaders }
  }

  $sid = Get-Cookie $Request $State.Cookie
  if (-not $sid -or -not $State.Sessions.ContainsKey($sid)) {
    return New-JsonResponse @{ error = 'Not signed in. Open the link printed by webui.ps1 in this browser.'; signedOut = $true } 401
  }
  $session = $State.Sessions[$sid]
  $body = $null
  if ($Request.Method -ne 'GET') {
    $origin = if ($Request.Headers.ContainsKey('origin')) { $Request.Headers['origin'] } else { '' }
    if ($State.Origins -notcontains $origin) { return New-JsonResponse @{ error = 'Cross-origin request refused.' } 403 }
    $csrf = if ($Request.Headers.ContainsKey('x-csrf-token')) { $Request.Headers['x-csrf-token'] } else { '' }
    if (-not (Test-ConstantTimeEqual $csrf $session.Csrf)) { return New-JsonResponse @{ error = 'Missing or invalid CSRF token. Reload the page.' } 403 }
    $ct = if ($Request.Headers.ContainsKey('content-type')) { $Request.Headers['content-type'] } else { '' }
    if ($ct -notmatch '^application/json\b') { return New-JsonResponse @{ error = 'Content-Type must be application/json.' } 415 }
    try { $body = if ($Request.Body) { $Request.Body | ConvertFrom-Json } else { [pscustomobject]@{} } }
    catch { return New-JsonResponse @{ error = 'Request body is not valid JSON.' } 400 }
  }
  try {
    $data = Invoke-ApiRoute $Request $body
    if ($Request.Path -eq '/api/session') { $data = [ordered]@{ ok = $true; csrf = $session.Csrf; installPath = $InstallPath; chosen = [bool]$State.Chosen; canStop = [bool]$StopFile } }
    if ($data -is [pscustomobject] -and $data.PSObject.Properties['IsDownload']) {
      $h = @{} + $SecurityHeaders
      $h['Content-Disposition'] = "attachment; filename=`"$($data.FileName -replace '[^A-Za-z0-9._-]', '_')`""
      return @{ Status = 200; ContentType = $data.ContentType; Body = $data.Body; Headers = $h }
    }
    return New-JsonResponse $data
  } catch {
    $status = 500
    if ($_.Exception.Data.Contains('status')) { $status = [int]$_.Exception.Data['status'] }
    $payload = [ordered]@{ error = ((ConvertTo-RedactedText @($_.Exception.Message)) -join ' ') }
    if ($_.Exception.Data.Contains('extra')) { foreach ($k in $_.Exception.Data['extra'].Keys) { $payload[$k] = $_.Exception.Data['extra'][$k] } }
    if ($status -eq 500) { Write-Audit 'error' "$($Request.Method) $($Request.Path): $($payload.error)" }
    return New-JsonResponse $payload $status
  }
}

# --- Start -------------------------------------------------------------------------------------------------------

# The current sign-in link, readable by this Windows user only (the launcher reads it to open the browser again).
function Write-LaunchUrlFile {
  if (-not $LaunchUrlFile) { return }
  $dir = Split-Path -Parent $LaunchUrlFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # Written to a temporary file that is restricted first, then moved into place: the link file never exists with
  # default permissions, not even for a moment.
  $tmp = "$LaunchUrlFile.tmp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  [IO.File]::WriteAllText($tmp, "http://127.0.0.1:$Port/?k=$($State.LaunchKey)")
  if ($SingleUseLaunch) { Set-SecretFileAcl $tmp }
  Move-Item -LiteralPath $tmp -Destination $LaunchUrlFile -Force
}

try { $listener = New-LoopbackListener $Port }
catch { throw "Cannot listen on 127.0.0.1:$Port ($($_.Exception.Message)). Is the web UI already running? Use -Port to pick another port." }
$launchUrl = "http://127.0.0.1:$Port/?k=$($State.LaunchKey)"
Write-Host "Deployment Manager (Traefik + Cloudflare) for $(if ($ProjectChosen) { $InstallPath } else { 'your deployments' })" -ForegroundColor Cyan
Write-Host "Listening on http://127.0.0.1:$Port/ (this PC only). Press Ctrl+C to stop."
if ($LaunchUrlFile) {
  Write-LaunchUrlFile
  if ($OpenBrowser -and -not $NoBrowser) { Start-Process "http://127.0.0.1:$Port/?k=$($State.LaunchKey)" }
} else {
  Write-Host ''
  Write-Host 'Open this link (it signs this browser in; do not share it):' -ForegroundColor Yellow
  Write-Host "  $launchUrl"
  if (-not $NoBrowser) { Start-Process $launchUrl }
}
try {
  # 3 MB: a backup upload (at most 2 MB) arrives base64-encoded in a JSON body.
  Start-HttpLoop -Listener $listener -StopFile $StopFile -MaxBodyBytes 3145728 -Handler { param($r) Invoke-Request $r }
} finally {
  $listener.Stop()
  Write-Host 'Web UI stopped.'
}
