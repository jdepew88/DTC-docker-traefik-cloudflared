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
  [string]$CatalogDir,
  # Launcher (Start-DeploymentManager.ps1): its state folder (launcher.json: default deployment, startup preferences), how
  # this start was requested (default / choose / recovery) and a notice for the chooser (e.g. "default deployment missing").
  [string]$LauncherStateDir,
  [ValidateSet('', 'default', 'choose', 'recovery')][string]$StartMode = '',
  [string]$StartNotice,
  # Remembered browsers: sign-ins from the launch link set a cookie that lasts -RememberDays and survives restarts, so a
  # bookmarked http://127.0.0.1:<port>/ keeps working. Only SHA-256 hashes of the cookies are stored, with a user-only ACL.
  [string]$SessionFile,
  [ValidateRange(1, 365)][int]$RememberDays = 30,
  # Tests only: the Startup folder for "Start with Windows" (default: this user's Startup folder).
  [string]$StartupDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $here 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $here 'lib\AccessDiagnostics.psm1') -Force
Import-Module (Join-Path $here 'lib\Dashboard.psm1') -Force
Import-Module (Join-Path $here 'lib\ConfigBackup.psm1') -Force
Import-Module (Join-Path $here 'lib\ProjectDiscovery.psm1') -Force
Import-Module (Join-Path $here 'lib\Infrastructure.psm1') -Force
Import-Module (Join-Path $here 'lib\DockerDiscovery.psm1') -Force
Import-Module (Join-Path $here 'lib\ServiceHealth.psm1') -Force
Import-Module (Join-Path $here 'lib\BackendResolver.psm1') -Force
Import-Module (Join-Path $here 'lib\AppCatalog.psm1') -Force
Import-Module (Join-Path $here 'lib\ComposeLifecycle.psm1') -Force
Import-Module (Join-Path $here 'lib\AppInstances.psm1') -Force
Import-Module (Join-Path $here 'lib\SecretStore.psm1') -Force
Import-Module (Join-Path $here 'lib\CredentialManager.psm1') -Force
Import-Module (Join-Path $here 'lib\RoutingModel.psm1') -Force
Import-Module (Join-Path $here 'lib\Authentik.psm1') -Force
Import-Module (Join-Path $here 'lib\IdentityProvider.psm1') -Force
Import-Module (Join-Path $here 'lib\SafeFetch.psm1') -Force
Import-Module (Join-Path $here 'lib\AppSources.psm1') -Force
Import-Module (Join-Path $here 'lib\HostPlatform.psm1') -Force
Import-Module (Join-Path $here 'lib\ProvisionPolicy.psm1') -Force
Import-Module (Join-Path $here 'lib\IdentityContract.psm1') -Force
Import-Module (Join-Path $here 'lib\AiAssist.psm1') -Force
Import-Module (Join-Path $here 'lib\Recipes.psm1') -Force
Import-Module (Join-Path $here 'lib\AppContract.psm1') -Force
Import-Module (Join-Path $here 'lib\Reconcile.psm1') -Force
Import-Module (Join-Path $here 'lib\ExternalManagers.psm1') -Force
Import-Module (Join-Path $here 'lib\Launcher.psm1') -Force
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
  IdpPlans  = @{}
  IdpChecks = @{}
  AccessApps = $null
  ProvisionPlans = @{}
  IntegrationPlans = @{}
  ManagerSnapshots = @{}
  AiEstimates = @{}
  Remembered = @{}
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
  '/backend.js' = @('backend.js', 'text/javascript; charset=utf-8')
  '/projects.js' = @('projects.js', 'text/javascript; charset=utf-8')
  '/brands.js' = @('brands.js', 'text/javascript; charset=utf-8')
  '/explorer.js' = @('explorer.js', 'text/javascript; charset=utf-8')
  '/discover.js' = @('discover.js', 'text/javascript; charset=utf-8')
  '/catalog.js' = @('catalog.js', 'text/javascript; charset=utf-8')
  '/provision.js' = @('provision.js', 'text/javascript; charset=utf-8')
  '/applications.js' = @('applications.js', 'text/javascript; charset=utf-8')
  '/credentials.js' = @('credentials.js', 'text/javascript; charset=utf-8')
  '/identity.js' = @('identity.js', 'text/javascript; charset=utf-8')
  '/routing.js' = @('routing.js', 'text/javascript; charset=utf-8')
  '/deployments.js' = @('deployments.js', 'text/javascript; charset=utf-8')
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
  # Cloudflare Access defaults to on for a published service without another sign-in. When the request names authentik,
  # Access stays off unless it is asked for explicitly (with layered authentication): never two logins by default.
  $namesAuthentik = [bool]($svc.PSObject.Properties['auth'] -and $null -ne $svc.auth -and [string](Get-Field $svc.auth 'provider' '') -eq 'authentik')
  $def = @{
    name = Get-Field $svc 'name' ''; displayName = $displayName.Substring(0, [Math]::Min(80, $displayName.Length)); description = ([string](Get-Field $svc 'description' '')).Substring(0, [Math]::Min(200, ([string](Get-Field $svc 'description' '')).Length))
    enabled = [bool](Get-Field $svc 'enabled' $true); hostnames = $hostnames; pathPrefix = Get-Field $svc 'pathPrefix' ''
    stripPrefix = [bool](Get-Field $svc 'stripPrefix' $false); middlewares = @(Get-Field $svc 'middlewares' @('default-headers@file'))
    target = @{ type = $resolved.Type; host = $resolved.Host; port = (Get-Field $target 'port' 0); protocol = (Get-Field $target 'protocol' 'http'); tlsSkipVerify = [bool](Get-Field $target 'tlsSkipVerify' $false) }
    cloudflare = @{ publish = [bool](Get-Field (Get-Field $svc 'cloudflare' $null) 'publish' $true); access = [bool](Get-Field (Get-Field $svc 'cloudflare' $null) 'access' (-not $namesAuthentik)) }
  }
  # Sign-in (ForwardAuth): only when the request names it. A form that does not send 'auth' keeps whatever the
  # service had (Build-ChangePlan), so editing a protected service never silently removes its protection.
  $hasAuth = [bool]($svc.PSObject.Properties['auth'])
  if ($hasAuth -and $null -ne $svc.auth) { $def.auth = @{ provider = [string](Get-Field $svc.auth 'provider' ''); endpoint = [string](Get-Field $svc.auth 'endpoint' ''); layered = [bool](Get-Field $svc.auth 'layered' $false) } }
  $definition = ConvertTo-ServiceDefinition $def
  return [pscustomobject]@{ Service = $definition; Note = $resolved.Note; HasAuth = $hasAuth }
}

function Find-RegistryService($Services, [string]$Name) {
  $found = @($Services | Where-Object { $_.name -eq ([string]$Name).ToLowerInvariant() })
  if ($found.Count -eq 0) { Stop-Request 404 "No service named '$Name'." }
  return $found[0]
}

# Extra live checks of the target (read-only): container membership of the shared network, what a LAN address means
# inside Docker, then one real request from Traefik's network namespace with the public Host header. Returns the notes
# for the preview and the verification verdict, which is the readiness check: an apply re-runs it right before writing.
function Get-TargetCheck($Settings, $Service) {
  $warnings = @()
  $verdict = $null
  if ($null -eq $Service -or $Service.target.host -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { return [pscustomobject]@{ Warnings = $warnings; Verdict = $verdict } }
  $probe = $Service.enabled
  $knownPorts = @()
  if ($Service.target.type -eq 'docker') {
    $r = Invoke-Docker inspect $Service.target.host --format '{{json .Config.ExposedPorts}}|{{json .NetworkSettings.Networks}}'
    if ($r.ExitCode -ne 0) {
      $warnings += "No container named '$($Service.target.host)' exists right now. The route will answer 502 until it does."; $probe = $false
      $verdict = [ordered]@{ result = 'dns'; state = 'failed'; label = 'DNS resolution failure'; message = "No container named '$($Service.target.host)' exists on this Docker engine."; url = ''; evidence = @() }
    } else {
      $parts = (@($r.Output) -join '').Trim().Split([char[]]'|', 2)
      $ep = $parts[0] | ConvertFrom-Json
      if ($ep) { $knownPorts = @($ep.PSObject.Properties | Where-Object { $_.Name -match '^\d+/tcp$' } | ForEach-Object { [int]$_.Name.Split('/')[0] }) }
      $nets = $parts[1] | ConvertFrom-Json
      if (-not $nets.PSObject.Properties[$Settings.ProxyNetwork]) {
        $warnings += "Container '$($Service.target.host)' is not attached to the '$($Settings.ProxyNetwork)' network, so Traefik cannot reach it. Add it in its compose file (networks: [$($Settings.ProxyNetwork)], external) or run: docker network connect $($Settings.ProxyNetwork) $($Service.target.host)"; $probe = $false
        $verdict = [ordered]@{ result = 'dns'; state = 'failed'; label = 'DNS resolution failure'; message = "Container '$($Service.target.host)' is not attached to '$($Settings.ProxyNetwork)', so its name does not resolve from Traefik's network."; url = ''; evidence = @() }
      }
    }
  } elseif ($Service.target.type -eq 'lan') {
    $warnings += @(Get-LanTargetIssues $Service.target.host (Get-LocalIPv4Addresses) (Get-DockerSubnets) | ForEach-Object { $_.message })
  }
  if ($probe) {
    $verdict = Add-BackendVerdictCause (Get-BackendVerdict (Test-BackendFromTraefik -Settings $Settings -Service $Service -CompareHostHeader) $Service $Settings.ProxyNetwork $knownPorts) $Service.target
    if ($verdict.state -in 'failed', 'warning') { $warnings += "Backend test from Traefik's network: $($verdict.message)" }
  }
  return [pscustomobject]@{ Warnings = $warnings; Verdict = $verdict }
}

# A timeout to an address inside a Docker network's subnet has a known cause: say so instead of guessing.
function Add-BackendVerdictCause($Verdict, $Target) {
  if ($Verdict -and $Verdict.result -in @('timeout', 'error') -and $Target.type -eq 'lan' -and (Test-IPv4Address ([string]$Target.host))) {
    $cap = @(Get-LanTargetIssues ([string]$Target.host) (Get-LocalIPv4Addresses) (Get-DockerSubnets) | Where-Object { $_.Contains('cause') -and $_['cause'] -eq 'subnet-overlap' })
    if ($cap.Count) { $Verdict.cause = 'subnet-overlap'; $Verdict.message = "Traefik could not connect to $($Target.host):$($Target.port). $($cap[0].message)" }
  }
  return $Verdict
}

# Where an application runs and what the user typed -> the backend address Traefik should use, with the reasons, the
# containers to choose from and, on request, one verification of a target from Traefik's network. Read-only.
function Invoke-BackendResolve($Body) {
  Assert-Installed
  $settings = Get-Settings
  $envr = Get-BackendEnvironment -Settings $settings -Fresh:([bool](Get-Field $Body 'fresh' $false))
  $inv = @(); try { $inv = @(Get-DockerContainerInventory -ProxyNetwork $settings.ProxyNetwork) } catch { }
  $own = @((Get-StackContainerNames $settings).Values) + @($settings.WhoamiContainer)
  $port = 0; $null = [int]::TryParse([string](Get-Field $Body 'port' ''), [ref]$port)
  $address = ([string](Get-Field $Body 'address' '')).Trim()
  if ($address.Length -gt 300) { Stop-Request 400 'The address is too long.' }
  $res = Resolve-BackendAddress -Location ([string](Get-Field $Body 'location' 'auto')) -Address $address -Port $port -Protocol ([string](Get-Field $Body 'protocol' '')) `
    -Container ([string](Get-Field $Body 'container' '')) -Override:([bool](Get-Field $Body 'override' $false)) -Environment $envr -Containers @($inv | Where-Object { $own -notcontains $_.name })
  $containers = @($inv | Where-Object { $_.state -eq 'running' -and -not $_.infrastructure -and $own -notcontains $_.name } | ForEach-Object {
      [ordered]@{ name = $_.name; image = ($_.image -replace '@sha256:[0-9a-f]+', ''); project = $_.compose.project; private = [bool]$_.privateService
        networks = @($_.networks | ForEach-Object { [ordered]@{ name = $_.name; ipv4 = $_.ipv4; aliases = @($_.aliases) } }); sharesTraefikNetwork = [bool](@($_.networks | Where-Object { @($envr.traefikNetworks) -contains $_.name }).Count)
        ports = @($_.ports | ForEach-Object { [ordered]@{ port = $_.port; proto = $_.proto; guess = $_.guess; reason = $_.reason; hostPort = $_.hostPort; hostIp = $_.hostIp } }) } })
  $hostname = ([string](Get-Field $Body 'hostname' '')).Trim().ToLowerInvariant()
  if ($hostname -notmatch '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { $hostname = '' }
  $verification = $null; $yaml = ''; $verifications = @()
  $toTarget = { param($t) if ($null -eq $t) { return $null } [ordered]@{ type = [string](Get-Field $t 'type' ''); host = [string](Get-Field $t 'host' ''); port = [int](Get-Field $t 'port' 0); protocol = [string](Get-Field $t 'protocol' 'http'); tlsSkipVerify = [bool](Get-Field $t 'tlsSkipVerify' $false) } }
  $valid = { param($x) [bool]($x -and $x.host -match '^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$' -and $x.port -ge 1 -and $x.port -le 65535 -and $x.protocol -in @('http', 'https', 'h2c') -and $x.type -in @('docker', 'host', 'lan') -and -not (Test-LoopbackHost $x.host)) }
  # One verification of exactly this target from Traefik's network: never a substitute address.
  $verify = {
    param($x)
    $svc = [pscustomobject]@{ name = 'backend-test'; enabled = $true; hostnames = @($(if ($hostname) { $hostname } else { $x.host })); pathPrefix = ''; stripPrefix = $false; target = [pscustomobject]$x }
    $known = @(); $tc = @($inv | Where-Object { $_.name -eq $x.host }); if ($tc.Count) { $known = @($tc[0].exposed | Where-Object { $_.proto -eq 'tcp' } | ForEach-Object { [int]$_.port }) }
    $vr = Add-BackendVerdictCause (Get-BackendVerdict (Test-BackendFromTraefik -Settings $settings -Service $svc -CompareHostHeader:([bool]$hostname)) $svc $settings.ProxyNetwork $known) $x
    $vr.target = $x; $vr.targetUrl = "$($x.protocol)://$($x.host):$($x.port)"; $vr.testedAt = (Get-Date -Format 's')
    Write-Audit 'backend-test' "$($vr.targetUrl) $($vr.result)"
    return $vr
  }
  $target = & $toTarget (Get-Field $Body 'target' $null)
  $pick = $(if ($res.custom -and $res.override) { $res.custom } else { $res.recommended })
  if (-not $target -and $pick) { $target = [ordered]@{ type = $pick.type; host = $pick.host; port = $pick.port; protocol = $pick.protocol; tlsSkipVerify = $false } }
  if (& $valid $target) {
    try { $yaml = ConvertTo-TraefikRouteYaml (ConvertTo-ServiceDefinition @{ name = 'preview'; hostnames = @($(if ($hostname) { $hostname } else { 'app.example.com' })); middlewares = @('default-headers@file'); target = @{ type = $target.type; host = $target.host; port = $target.port; protocol = $target.protocol; tlsSkipVerify = $target.tlsSkipVerify } }) } catch { $yaml = '' }
    if ([bool](Get-Field $Body 'test' $false)) { $verification = & $verify $target }
  }
  # "Test every address": each candidate on its own, one after another (at most four).
  $many = @(Get-Field $Body 'targets' @())
  if ($many.Count -gt 4) { Stop-Request 400 'At most four addresses are tested at once.' }
  foreach ($m in $many) { $x = & $toTarget $m; if (& $valid $x) { $verifications += & $verify $x } }
  return [ordered]@{ resolution = $res; environment = $envr; containers = $containers; verification = $verification; verifications = @($verifications); traefikYaml = $yaml }
}

# Builds the Traefik + Cloudflare plan for a change request. Pure read: nothing is written.
# $Owner (internal callers only, never from the browser): the integration that owns a new route.
function Build-ChangePlan($Body, $Owner = $null) {
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
      if ($Owner) { $new | Add-Member -NotePropertyName owner -NotePropertyValue ([pscustomobject]$Owner) -Force; $new = ConvertTo-ServiceDefinition $new }
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
      if (-not $parsed.HasAuth -and $previous.PSObject.Properties['auth']) { $new | Add-Member -NotePropertyName auth -NotePropertyValue $previous.auth -Force }
      # The owner of a route is kept on every edit (the browser cannot set or change it).
      if ($previous.PSObject.Properties['owner']) { $new | Add-Member -NotePropertyName owner -NotePropertyValue $previous.owner -Force }
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
  $check = Get-TargetCheck $settings $new
  # Generic "make sure it is reachable" reminders are dropped once a real request from Traefik's network succeeded.
  if ($check.Verdict -and $check.Verdict.state -in 'ok', 'auth') {
    $traefik.Issues = @($traefik.Issues | Where-Object { -not ($_.Level -eq 'Warning' -and $_.Field -eq 'target.host' -and $_.Message -match '^(The container .+ must be attached|The Windows app must listen)') })
  }
  return [pscustomobject]@{
    Op = $op; Summary = $summary; Settings = $settings; Traefik = $traefik; Cloudflare = $cf; New = $new; Previous = $previous
    Notes = @($notes + @($check.Warnings)); Backend = $check.Verdict; TraefikKey = $traefikKey
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
    # The connection test from Traefik's network; when it failed, applying needs an explicit acknowledgment.
    backend    = $Plan.Backend
    # The exact backend URL this plan writes into the Traefik service (the user's choice, never a substitute).
    backendUrl = $(if ($Plan.New) { Get-ServiceUrl $Plan.New } else { '' })
    needsBackendAck = [bool]($Plan.Backend -and $Plan.Backend.state -eq 'failed')
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
  # The backend was verified again just now (Build-ChangePlan). A route to a backend that fails is only saved on request.
  if ($view.needsBackendAck -and -not [bool](Get-Field $Body 'acceptUnverifiedBackend' $false)) {
    $State.Plans[$id] = $stored
    Stop-Request 409 "The backend did not pass the connection test from Traefik's network: $($plan.Backend.message) Fix the backend, or confirm that you want to save the route anyway." @{ needsBackendAck = $true; backend = $plan.Backend }
  }
  return Invoke-ChangePlanSteps $plan $confirmed
}

# Executes a verified change plan: recovery point, Traefik validation in a throwaway container, backup + write + reload,
# backend readiness step, then the approved Cloudflare actions. Shared by service changes and identity protection.
function Invoke-ChangePlanSteps($plan, [string[]]$confirmed) {
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
  # The route is ready only when Traefik's network reaches the backend: the verification made right before writing,
  # reported as its own step (a failed one was saved only because the user confirmed it).
  if ($plan.New -and $plan.New.enabled -and $plan.Backend) {
    $b = $plan.Backend
    $null = $steps.Add([ordered]@{ name = 'Backend reachable from Traefik'; status = $(switch ($b.state) { 'ok' { 'Done' } 'auth' { 'Done' } 'skipped' { 'Skipped' } default { 'Warning' } })
        message = "$($b.label): $($b.message)$(if ($b.state -eq 'failed') { ' Saved anyway, as you confirmed: the route is not ready until the backend answers.' })" })
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
        environment = @(if ($sp.Value.PSObject.Properties['environment'] -and $sp.Value.environment) { $sp.Value.environment.PSObject.Properties | ForEach-Object { $_.Name } })
        declared = (Get-ServiceDeclaredLifecycle $sp.Value) }
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
    aliases = @(& $field 'aliases' @()); manifestVersion = [string](& $field 'manifestVersion' ''); availability = (Get-ManifestAvailability $M)
    variantOf = [string](& $field 'variantOf' ''); variant = (& $field 'variant' $null); choiceGroup = (& $field 'choiceGroup' $null)
    architectures = @(& $field 'architectures' @()); authentication = (& $field 'authentication' $null); limitations = @(& $field 'limitations' @())
    headless = [bool](Get-Prop2 (& $field 'web' $null) 'headless' $false); postInstall = @(@(& $field 'postInstall' @()) | ForEach-Object { [string](Get-Prop2 $_ 'label' '') })
    components = @(if ($M.PSObject.Properties['services'] -and $M.services) { @($M.services.PSObject.Properties | ForEach-Object { Get-ServiceComponent $M $_.Name } | Select-Object -Unique) })
    manualSetup = @(& $field 'manualSetup' @()); verification = (& $field 'testStatus' $null); website = [string](& $field 'website' '')
    optionalPorts = @(if ($M.PSObject.Properties['services'] -and $M.services) { foreach ($sp in $M.services.PSObject.Properties) { foreach ($p in @(Get-Prop2 $sp.Value 'ports' @())) { $pub = Get-Prop2 $p 'publish' $null; if ($pub) {
              [ordered]@{ service = $sp.Name; container = [int]$p.container; protocol = [string]$p.protocol; label = [string](Get-Prop2 $p 'label' ''); hostPort = [int](Get-Prop2 $pub 'hostPort' 0); address = [string](Get-Prop2 $pub 'address' ''); when = [string](Get-Prop2 $pub 'when' '') } } } } })
  }
}

# Compose's standard file names, in the order docker compose itself picks them. Apps installed here use compose.yaml;
# an adopted project keeps whichever of these it has (recorded as composeFile).
$ComposeFileNames = @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml')
function Find-ComposeFileName([string]$Folder) {
  foreach ($n in $ComposeFileNames) { if ($Folder -and (Test-Path -LiteralPath (Join-Path $Folder $n))) { return $n } }
  return ''
}
function Get-AppComposePath($App) {
  $folder = [string]$(if ($App -is [System.Collections.IDictionary]) { $App['folder'] } else { $App.folder })
  $name = [string]$(if ($App -is [System.Collections.IDictionary]) { if ($App.Contains('composeFile')) { $App['composeFile'] } } elseif ($App.PSObject.Properties['composeFile']) { $App.composeFile })
  if (-not $name) { $name = Find-ComposeFileName $folder }
  if (-not $name) { $name = 'compose.yaml' }
  return (Join-Path $folder $name)
}

# Modular stacks: every Compose file of an installed app, in order (compose.yaml first). The record's composeFiles
# (written at installation) lists them; older and adopted installations have their single file. Start, stop, logs,
# update, backup, restore and removal always pass the complete set to docker compose.
function Get-RecordValue($Record, [string]$Name, $Default = $null) {
  if ($Record -is [System.Collections.IDictionary]) { if ($Record.Contains($Name) -and $null -ne $Record[$Name]) { return $Record[$Name] }; return $Default }
  return (Get-Prop2 $Record $Name $Default)
}
function Get-AppComposeFileNames($App) {
  $names = @(@(Get-RecordValue $App 'composeFiles' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^compose(\.[a-z0-9-]+)?\.yaml$' })
  if ($names.Count) { return $names }
  return @(Split-Path -Leaf (Get-AppComposePath $App))
}
function Get-AppComposeFiles($App) {
  $folder = [string](Get-RecordValue $App 'folder' '')
  return @(Get-AppComposeFileNames $App | ForEach-Object { Join-Path $folder $_ })
}
function Get-AppComposeArgs($App) {
  $a = @('compose', '--project-directory', [string](Get-RecordValue $App 'folder' ''))
  foreach ($f in (Get-AppComposeFiles $App)) { $a += @('-f', $f) }
  return , $a
}
# The files as { file; content } (missing files are left out), their joined text and their fingerprint.
function Get-AppComposeSetText($App) {
  return @(foreach ($f in (Get-AppComposeFiles $App)) { if (Test-Path -LiteralPath $f) { [ordered]@{ file = (Split-Path -Leaf $f); content = [IO.File]::ReadAllText($f) } } })
}
function Get-AppComposeText($App) { return ((@(Get-AppComposeSetText $App) | ForEach-Object { $_.content }) -join "`n") }
# Files the manager generates in an app folder (and may delete when asked to remove the app's files).
function Test-GeneratedAppFile([string]$Name) {
  return ($Name -in 'compose.yaml', '.env', 'README.md', 'credentials.txt', '.post-install.json', '.dtc-manifest.json', 'dtc-stack.json' -or $Name -match '^compose(\.[a-z0-9-]+)?\.yaml(\.bak-\d{8}-\d{6})?$')
}
# dtc-stack.json follows image changes made by an update (nothing else in it changes).
function Update-AppStackImages($App) {
  $p = Join-Path ([string](Get-RecordValue $App 'folder' '')) 'dtc-stack.json'
  if (-not (Test-Path -LiteralPath $p)) { return }
  try {
    $st = [IO.File]::ReadAllText($p) | ConvertFrom-Json
    $imgs = Get-ComposeServiceImages (Get-AppComposeText $App)
    foreach ($s in @($st.services)) { if ($imgs.Contains([string]$s.name)) { $s.image = [string]$imgs[[string]$s.name] } }
    $st | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-Date -Format 's') -Force
    [IO.File]::WriteAllText($p, (($st | ConvertTo-Json -Depth 12) + "`n"), (New-Object Text.UTF8Encoding($false)))
  } catch { }
}
function Get-AppComposeFingerprint($App) { $set = @(Get-AppComposeSetText $App); if (-not $set.Count) { return '' }; return (Get-ComposeSetFingerprint $set) }

# --- Deployments: lifecycle, instances, duplicates ----------------------------------------------------------------

# Facts (lib\ComposeLifecycle.psm1) of every Compose container on this PC, from two docker calls. No environment or
# command line is kept.
function Get-ComposeContainerFacts {
  $ids = @((Invoke-Docker ps -a -q --filter 'label=com.docker.compose.project').Output | Where-Object { "$_" -match '^[0-9a-f]{12,64}$' })
  if (-not $ids.Count) { return @() }
  $r = Invoke-Docker inspect $ids
  if ($r.ExitCode -ne 0) { return @() }
  $parsed = (@($r.Output) -join "`n") | ConvertFrom-Json
  return @(foreach ($x in $parsed) { ConvertFrom-ContainerInspect $x })
}

# Lifecycle of one installed instance: its containers, the services its compose.yaml defines and, for catalog apps,
# the roles the manifest declares and the optional services this installation left out.
function Get-InstanceLifecycle($Instance, [object[]]$Facts, $Catalog) {
  $cs = @($Facts | Where-Object { $_.project -eq $Instance.project })
  $m = Get-InstanceManifest $Instance $Catalog
  $defined = @()
  $composePath = Get-AppComposePath $Instance
  if ($Instance.folder -and (Test-Path -LiteralPath $composePath)) { $defined = @((Get-ComposeServiceImages (Get-AppComposeText $Instance)).Keys) }
  $inactive = @(); if ($m -and $defined.Count) { $inactive = @($m.services.PSObject.Properties | Where-Object { $defined -notcontains $_.Name } | ForEach-Object { $_.Name }) }
  return Get-DeploymentLifecycle -Containers $cs -Manifest $m -Defined $defined -Inactive $inactive -Prepared:([bool]$Instance.prepared)
}

# Registry instances with their lifecycle, hostnames and container count (for duplicate detection and the apps page).
function Get-InstalledInstances($Settings, $Catalog, [object[]]$Facts) {
  $registry = @((Read-ServiceRegistry -Settings $Settings).services)
  return @(Read-AppsRegistry $Settings | ForEach-Object {
      $i = ConvertTo-AppInstance $_ $Catalog
      $lc = Get-InstanceLifecycle $i $Facts $Catalog
      $names = @($Facts | Where-Object { $_.project -eq $i.project } | ForEach-Object { $_.name })
      $i.lifecycle = $lc; $i.state = $lc.state; $i.headline = $lc.headline; $i.containerCount = $names.Count
      $i.routes = @($registry | Where-Object { $_.target.type -eq 'docker' -and $names -contains $_.target.host } | ForEach-Object { [ordered]@{ name = $_.name; hostnames = @($_.hostnames); publish = [bool]$_.cloudflare.publish; authProvider = $(if ($_.PSObject.Properties['auth'] -and $_.auth) { [string]$_.auth.provider } else { '' }) } })
      $i.hostnames = @($i.routes | ForEach-Object { $_.hostnames })
      $i
    })
}

# Existing installations of the application a manifest installs (registered, archived and unregistered ones).
function Get-ExistingInstallations($Manifest, $Settings) {
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $facts = @(Get-ComposeContainerFacts)
  $instances = @(Get-InstalledInstances $Settings $catalog $facts)
  $un = @(Get-DetectedInstallations $catalog (@($instances | ForEach-Object { $_.project }) + $Settings.StackName))
  $found = @(Find-AppInstallations (Get-ApplicationId $Manifest) $instances @($un | Where-Object { $_.project }))
  # Containers started without Compose count as existing installations too (they cannot be adopted, only inspected).
  $found += @($un | Where-Object { -not $_.project -and $_.applicationId -eq (Get-ApplicationId $Manifest) } | ForEach-Object {
      [ordered]@{ source = 'container'; project = $_.container; instanceId = ''; label = ''; folder = ''; archived = $false; origin = 'discovered'; state = [string]$_.containers[0].state; headline = ''
        containers = 1; hostnames = @(); reason = $_.reason } })
  return $found
}

# Installations of catalog applications on this PC that the manager does not manage: unregistered Compose projects
# (adoptable) and containers started without Compose (inspect and route only). Read-only: two docker calls.
function Get-DetectedInstallations($Valid, [string[]]$Exclude) {
  $ids = @((Invoke-Docker ps -a -q).Output | Where-Object { "$_" -match '^[0-9a-f]{12,64}$' })
  if (-not $ids.Count) { return @() }
  $r = Invoke-Docker inspect $ids
  if ($r.ExitCode -ne 0) { return @() }
  $facts = @(foreach ($x in ((@($r.Output) -join "`n") | ConvertFrom-Json)) { ConvertFrom-ContainerInspect $x })
  # Disposable test deployments (tests\TestResources.psm1 prefixes) are never shown as installations, unless this manager
  # itself runs a disposable test deployment (then its fixtures are what it should see).
  $self = $(if (Test-Installed) { [string](Get-Settings).StackName } else { '' })
  if ($self -notmatch '^tp[xm]-[a-z]+-[0-9a-f]{6,8}') { $facts = @($facts | Where-Object { $_.name -notmatch '^tp[xm]-[a-z]+-[0-9a-f]{6,8}' -and [string]$_.project -notmatch '^tp[xm]-[a-z]+-[0-9a-f]{6,8}' }) }
  return @(@(Get-UnregisteredInstallations @($facts | Where-Object { $_.project }) $Valid $Exclude) + @(Get-StandaloneInstallations @($facts | Where-Object { -not $_.project }) $Valid))
}

# The catalog as the browser sees it: one entry per application (variants listed under it), each with the instances
# installed on this PC. Reference entries (building blocks) are listed apart; retired entries are not offered at all
# and only named so the page can explain where they went.
function Get-CatalogData {
  $apps = @(Get-CatalogApps -CatalogDir $CatalogDir)
  $valid = @($apps | Where-Object { -not @($_.errors).Count })
  $instances = @()
  if (Test-Installed) { $instances = @(Read-AppsRegistry (Get-Settings) | ForEach-Object { ConvertTo-AppInstance $_ $valid }) }
  $offered = @($valid | Where-Object { (Get-ManifestAvailability $_.manifest) -eq 'offered' })
  # Where each installation is reachable: its local address and the service routes that point at its web container.
  $routesReg = @(); if (Test-Installed) { $routesReg = @((Read-ServiceRegistry -Settings (Get-Settings)).services) }
  $reach = { param($inst)
    $mm = @($valid | Where-Object { $_.id -eq $inst.appId } | ForEach-Object { $_.manifest })[0]
    $webC = $(if ($mm -and -not (Get-Prop2 $mm.web 'headless' $false)) { Get-AppContainerName $mm $inst.project $mm.web.service } else { '' })
    $rs = @($routesReg | Where-Object { $webC -and $_.target.type -eq 'docker' -and $_.target.host -eq $webC })
    [ordered]@{ localUrl = [string](Get-RecordValue $inst 'localUrl' ''); hostnames = @($rs | ForEach-Object { @($_.hostnames) }); public = [bool](@($rs | Where-Object { $_.cloudflare -and $_.cloudflare.publish }).Count)
      protected = [bool](@($rs | Where-Object { $_.PSObject.Properties['auth'] -and $_.auth }).Count) } }
  $instanceList = { param($appId) @($instances | Where-Object { $_.applicationId -eq $appId -and -not $_.archived } | ForEach-Object { [ordered]@{ project = $_.project; instanceId = $_.instanceId; label = $_.label; manifestId = $_.appId; prepared = $_.prepared; origin = $_.origin; access = (& $reach $_) } }) }
  $exclude = @(@($instances | ForEach-Object { $_.project }) + $(if (Test-Installed) { (Get-Settings).StackName } else { @() }))
  $detected = @(); try { $detected = @(Get-DetectedInstallations $valid $exclude) } catch { }
  $detectedList = { param($appId) @($detected | Where-Object { $_.applicationId -eq $appId } | ForEach-Object { [ordered]@{ project = $_.project; container = [string](Get-Prop2 $_ 'container' ''); standalone = [bool](Get-Prop2 $_ 'standalone' $false)
          folder = $_.folder; reason = $_.reason; containers = @($_.containers | ForEach-Object { [ordered]@{ name = $_.name; state = $_.state; image = $_.image } }) } }) }
  # Host facts for compatibility (architecture Docker runs, NVIDIA driver present).
  $hostInfo = [ordered]@{ architecture = ''; nvidiaGpu = [bool](Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue) }
  $ai = Invoke-Docker info --format '{{.Architecture}}'; if ($ai.ExitCode -eq 0) { $hostInfo.architecture = ConvertTo-ImageArchitecture ((@($ai.Output) -join '').Trim()) }
  return [ordered]@{
    apps = @(foreach ($e in @($offered | Where-Object { -not (Get-Prop2 $_.manifest 'variantOf' '') })) {
        $v = Get-CatalogView $e.manifest
        $v.applicationId = $e.id
        $v.variants = @($offered | Where-Object { [string](Get-Prop2 $_.manifest 'variantOf' '') -eq $e.id } | ForEach-Object { $vv = Get-CatalogView $_.manifest; $vv.applicationId = $e.id; $vv })
        $v.instances = @(& $instanceList $e.id)
        $v.archivedInstances = @($instances | Where-Object { $_.applicationId -eq $e.id -and $_.archived }).Count
        $v.installedAs = @($v.instances | ForEach-Object { $_.project })
        $v.detected = @(& $detectedList $e.id)
        $v.compatibility = @(Get-AppHostCompatibility $e.manifest $hostInfo)
        $v
      })
    reference = @($valid | Where-Object { (Get-ManifestAvailability $_.manifest) -eq 'reference' } | ForEach-Object { [ordered]@{ id = $_.id; name = [string]$_.manifest.name; description = [string]$_.manifest.description; note = [string](Get-Prop2 $_.manifest 'installNote' '') } })
    retired = @($valid | Where-Object { (Get-ManifestAvailability $_.manifest) -eq 'retired' } | ForEach-Object { [ordered]@{ id = $_.id; name = [string]$_.manifest.name; date = [string](Get-Prop2 $_.manifest.retired 'date' ''); note = [string]$_.manifest.retired.note; replacement = @(Get-Prop2 $_.manifest.retired 'replacement' @()); installed = @(& $instanceList $_.id).Count } })
    invalid = @($apps | Where-Object { @($_.errors).Count } | ForEach-Object { [ordered]@{ file = $_.file; errors = @($_.errors) } })
    host = $hostInfo
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
  # Existing installations of the same application (any variant, alias or project name) and of the other members of
  # its choice group (e.g. Portainer when installing Arcane), so the page offers them before a second installation.
  $existing = @(Get-ExistingInstallations $Manifest $Settings)
  $alternatives = @()
  $cg = [string](Get-Prop2 (Get-Prop2 $Manifest 'choiceGroup' $null) 'id' '')
  if ($cg) {
    $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
    $others = @($catalog | Where-Object { $_.id -ne $Manifest.id -and [string](Get-Prop2 (Get-Prop2 $_.manifest 'choiceGroup' $null) 'id' '') -eq $cg } | ForEach-Object { $_.id })
    $alternatives = @(Read-AppsRegistry $Settings | ForEach-Object { ConvertTo-AppInstance $_ $catalog } | Where-Object { $others -contains $_.applicationId -and -not $_.archived } | ForEach-Object { [ordered]@{ project = $_.project; name = $_.name } })
  }
  return [ordered]@{ project = $project; folder = (Join-Path $root $project); timezone = (Get-IanaTimeZone); localPort = $lp; existing = $existing; alternativesInstalled = $alternatives }
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
# $Manifest: an imported application (provisioning engine), validated with the same rules as catalog manifests.
function Invoke-AppPlan($Body, $Manifest = $null) {
  Assert-Installed
  $settings = Get-Settings
  $appId = [string](Get-Field $Body 'appId' '')
  if ($Manifest) { $m = $Manifest; $merr = @(Test-AppManifest $m -AllowImported); if ($merr.Count) { Stop-Request 400 ('The application manifest is not valid: ' + ($merr -join '; ')) } }
  else { try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $appId } catch { Stop-Request 404 $_.Exception.Message } }
  if ((Get-ManifestAvailability $m) -eq 'retired') { Stop-Request 410 "$($m.name) is no longer offered for new installations: $($m.retired.note)" }
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
  # Never a silent second installation: an existing one (registered, archived or found running) must be managed,
  # adopted or archived instead, unless the user asks for another, separate instance.
  $another = [bool](Get-Field $Body 'anotherInstance' $false)
  $instanceLabel = ([string](Get-Field $Body 'instanceLabel' '')).Trim()
  if ($instanceLabel.Length -gt 40 -or $instanceLabel -match '[\r\n<>"]') { Stop-Request 400 'The instance label may have at most 40 characters, without quotes or angle brackets.' }
  $existing = @($defaults.existing)
  $current = @($existing | Where-Object { -not $_.archived })
  if ($current.Count) {
    $list = ($current | ForEach-Object { "$($_.project)$(if ($_.source -eq 'docker') { ' (not registered)' })" }) -join ', '
    if ($another) { & $check 'Another instance' $true "$($m.name) is already installed ($list). This creates a second, separate instance$(if ($instanceLabel) { " labelled '$instanceLabel'" }) with its own project, folder, volumes and port; nothing is shared or merged." 'warning' }
    else { & $check 'Not already installed' $false "$($m.name) is already installed: $list. Manage, adopt or archive the existing installation, or choose to install another, separate instance." }
  } elseif (@($existing | Where-Object { $_.archived }).Count) { & $check 'Not already installed' $true "An archived record of $($m.name) exists ($(@($existing | Where-Object { $_.archived } | ForEach-Object { $_.project }) -join ', ')); this is a new installation." 'warning' }
  if (@($defaults.alternativesInstalled).Count) { & $check 'Choice of tools' $true "$(@($defaults.alternativesInstalled | ForEach-Object { $_.name }) -join ', ') is already installed for the same purpose; you rarely need both." 'warning' }
  # A folder holding only the backups of an earlier installation counts as empty: the backups are kept.
  $folderOk = -not (Test-Path -LiteralPath $folder) -or -not @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'backups' }).Count
  & $check 'Installation folder is new or empty' $folderOk $(if ($folderOk) { $folder } else { "$folder already contains files; choose another folder." })
  $insideDeployment = $folder.StartsWith($InstallPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $folder -ieq $InstallPath
  if ($insideDeployment) { & $check 'Installation folder is outside the proxy deployment' $false 'Apps get their own folder, not one inside the proxy deployment.' }
  $hostNet = @($m.services.PSObject.Properties | Where-Object { [string](Get-Prop2 $_.Value 'networkMode' '') -eq 'host' }).Count -gt 0
  $headless = [bool](Get-Prop2 $m.web 'headless' $false)
  $localPort = 0
  if ($headless) { & $check 'No web interface' $true "$($m.name) is headless: no port is published and there is nothing to route or publish." 'info' }
  if (-not $hostNet -and -not $headless -and [int]::TryParse([string](Get-Field $Body 'localPort' $defaults.localPort), [ref]$localPort) -and $localPort -ne 0) {
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
  # Extra ports the user opted into (e.g. Git over SSH, DNS, direct media-server access): free on this PC, and a clear
  # note when they open to the local network.
  foreach ($pp in @(Get-AppPublishedPorts $m $resolved.Values)) {
    $what = "$(if ($pp.label) { $pp.label } else { "Port $($pp.container)" }) ($($pp.protocol.ToUpperInvariant()) $($pp.hostIp):$($pp.hostPort))"
    $busy = $(if ($pp.protocol -eq 'udp') { $(if (@(Get-NetUDPEndpoint -LocalPort $pp.hostPort -ErrorAction SilentlyContinue).Count) { 'a process on this PC' } else { $null }) } else { Get-PortUser $pp.hostPort })
    if ($pp.hostPort -eq $localPort -and $pp.protocol -eq 'tcp' -and -not ($pp.primary -and $pp.address -eq 'lan')) { $busy = 'the local web port chosen above' }
    if ($busy) { & $check $what $false "Port $($pp.hostPort) is in use by $busy. Choose another port or leave this option off." }
    elseif ($pp.address -eq 'lan') { & $check $what $true "Opens on every network interface of this PC: other devices on your network can connect (Windows may ask to allow it through the firewall). Nothing is published to the Internet." 'warning' }
    else { & $check $what $true 'Opened on this PC only (127.0.0.1).' }
  }
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
  foreach ($hc in (Get-AppHostCompatibility $m $res $resolved.Values)) { & $check $hc.label ($hc.state -ne 'failed') $hc.message $hc.state }
  $cvOk = $res.composeVersion -match '^(\d+)\.(\d+)' -and [int]$Matches[1] -ge 2
  & $check 'Docker Engine and Compose' $cvOk $(if ($cvOk) { "Docker $($res.dockerVersion), Compose $($res.composeVersion)." } else { "Docker Compose v2 is required (found '$($res.composeVersion)')." }) $(if ($cvOk) { 'ok' } else { 'failed' })
  $compose = $null; $composeSet = @(); $envText = $null; $envAll = [ordered]@{}
  if (-not @($resolved.Errors).Count) {
    try {
      # One Compose project, split into small files by component for multi-service apps (modular stack).
      $composeSet = @(ConvertTo-AppComposeSet -Manifest $m -Project $project -Resolved $resolved -ProxyNetwork $settings.ProxyNetwork -LocalPort $localPort)
      $compose = [string]$composeSet[0].content
      $fileEnv = Get-ComposeFileEnv @($composeSet | ForEach-Object { $_.file })
      foreach ($k in $fileEnv.Keys) { $envAll[$k] = $fileEnv[$k] }
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
      foreach ($cf in $composeSet) { [IO.File]::WriteAllText((Join-Path $tmp $cf.file), $cf.content) }
      [IO.File]::WriteAllText((Join-Path $tmp '.env'), $envText)
      Set-SecretFileAcl (Join-Path $tmp '.env')
      $cfgArgs = @('compose', '--project-directory', $tmp); foreach ($cf in $composeSet) { $cfgArgs += @('-f', (Join-Path $tmp $cf.file)) }
      $v = Invoke-Docker @($cfgArgs + @('config', '-q'))
      & $check 'docker compose config' ($v.ExitCode -eq 0) $(if ($v.ExitCode -ne 0) { (Hide-SecretValues @($v.Output) @($envAll.Values)) -join ' ' } elseif ($composeSet.Count -gt 1) { "The project is valid as one Compose project made of $($composeSet.Count) files: $(@($composeSet | ForEach-Object { $_.file }) -join ', ')." } else { 'The Compose file is valid.' })
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
  $stack = $null
  if ($composeSet.Count) { try { $stack = New-AppStackManifest -Manifest $m -Project $project -ComposeSet $composeSet -Resolved $resolved -ProxyNetwork $settings.ProxyNetwork -LocalPort $localPort -LocalUrl $(if ($localPort) { "http://127.0.0.1:$localPort/" } else { '' }) } catch { & $check 'Stack manifest' $false $_.Exception.Message } }
  $canApply = $compose -and $stack -and -not @($checks | Where-Object { $_.state -eq 'failed' }).Count
  if ($canApply) { $State.AppPlans[$planId] = [pscustomobject]@{ Created = (Get-Date); AppId = $m.id; Project = $project; Folder = $folder; Compose = $compose; ComposeSet = $composeSet; Stack = $stack; EnvAll = $envAll; Values = $resolved.Values; Derived = @($resolved.Derived); Privileged = $privileged; Images = $images; LocalPort = $localPort; StartNow = $startNow; Label = $instanceLabel; Manifest = $Manifest } }
  return [ordered]@{
    planId = $(if ($canApply) { $planId } else { '' }); canApply = [bool]$canApply; appId = $m.id; name = $m.name; project = $project; folder = $folder
    container = (Get-AppContainerName $m $project $m.web.service)
    services = @($active | ForEach-Object { [ordered]@{ name = $_.Name; container = (Get-AppContainerName $m $project $_.Name); image = [string]$_.Value.image; stateful = [bool](Get-Prop2 $_.Value 'stateful' $false) } })
    compose = $compose; composeFiles = @($composeSet | ForEach-Object { [ordered]@{ file = $_.file; component = $_.component; services = @($_.services); content = $_.content } }); stack = $stack
    envPreview = $preview; files = $filesPreview; checks = $checks.ToArray(); existingVolumes = @($volumes | Where-Object { (Invoke-Docker volume inspect $_).ExitCode -eq 0 })
    privileges = @(Get-Prop2 $m 'privileges' @()); security = @(Get-Prop2 $m 'security' @()); volumes = $volumes; images = $images; resources = [ordered]@{ need = $need; host = $res }
    localUrl = $(if ($localPort) { "http://127.0.0.1:$localPort/" } else { '' }); startNow = $startNow; existing = $existing; anotherInstance = $another; instanceLabel = $instanceLabel
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

# Pure: Docker's architecture name (x86_64, aarch64) as image platforms name it (amd64, arm64).
function ConvertTo-ImageArchitecture([string]$Name) {
  switch -regex ($Name.Trim()) { '^(x86_64|amd64)$' { return 'amd64' } '^(aarch64|arm64)$' { return 'arm64' } '^armv7' { return 'arm/v7' } default { return $Name.Trim() } }
}

# Pure: host compatibility of a manifest with what Docker reports: CPU architecture (every image of the stack must be
# published for it), hardware (GPU, devices) and the platform note. Each check: label, state, message.
function Get-AppHostCompatibility($Manifest, $HostInfo, [hashtable]$Values = @{}) {
  $checks = @()
  $archs = @(@(Get-Prop2 $Manifest 'architectures' @()) | ForEach-Object { ([string]$_) -replace '^linux/', '' })
  if ($HostInfo.architecture) {
    if (-not $archs.Count) { $checks += [ordered]@{ label = 'CPU architecture'; state = 'info'; message = "Not declared by the manifest; Docker runs $($HostInfo.architecture)." } }
    elseif ($archs -contains $HostInfo.architecture) { $checks += [ordered]@{ label = 'CPU architecture'; state = 'ok'; message = "Every image is published for $($HostInfo.architecture) (this PC)." } }
    else { $checks += [ordered]@{ label = 'CPU architecture'; state = 'failed'; message = "The images are published for $($archs -join ', ') only; Docker on this PC runs $($HostInfo.architecture)." } }
  }
  $gpu = $false; $devices = @()
  foreach ($sp in @(if (Get-Prop2 $Manifest 'services' $null) { Get-ActiveServices $Manifest $Values })) {
    $g = Get-Prop2 $sp.Value 'gpus' $false
    if (($g -is [bool] -and $g) -or ($g -is [string] -and [string]$Values["input:$g"] -eq 'true')) { $gpu = $true }
    $devices += @(Get-Prop2 $sp.Value 'devices' @())
  }
  if ($gpu) { $checks += [ordered]@{ label = 'GPU'; state = $(if ($HostInfo.nvidiaGpu) { 'warning' } else { 'failed' }); message = $(if ($HostInfo.nvidiaGpu) { 'An NVIDIA driver is installed; GPU access from Docker Desktop (WSL2) is experimental.' } else { 'GPU access was requested but no NVIDIA driver was found on this PC: the container would not start. Turn the GPU option off.' }) } }
  if ($devices.Count) { $checks += [ordered]@{ label = 'Host devices'; state = 'warning'; message = "Requests $($devices -join ', '): host devices are not available inside Docker Desktop containers." } }
  return $checks
}

# What this PC and Docker Desktop have free right now (read-only).
function Get-HostResources {
  $out = [ordered]@{ dockerTotalMB = 0; dockerUsedMB = 0; dockerFreeMB = 0; cpus = 0; windowsTotalMB = 0; windowsFreeMB = 0; projectsDiskFreeMB = 0; dockerDiskFreeMB = 0; running = 0; containers = @()
    architecture = ''; dockerVersion = ''; composeVersion = ''; nvidiaGpu = $false }
  try { $os = Get-CimInstance Win32_OperatingSystem; $out.windowsTotalMB = [int]($os.TotalVisibleMemorySize / 1024); $out.windowsFreeMB = [int]($os.FreePhysicalMemory / 1024) } catch { }
  $i = Invoke-Docker info --format '{{.MemTotal}}|{{.NCPU}}|{{.Architecture}}|{{.ServerVersion}}'
  $line = @($i.Output | Where-Object { $_ -match '^\d+\|\d+\|' })[0]
  if ($line) { $p = $line.Split('|'); $out.dockerTotalMB = [int]([int64]$p[0] / 1MB); $out.cpus = [int]$p[1]; $out.architecture = (ConvertTo-ImageArchitecture $p[2]); $out.dockerVersion = [string]$p[3] }
  $cv = Invoke-Docker compose version --short; $out.composeVersion = ((@($cv.Output) -join '').Trim() -replace '^v', '')
  # An NVIDIA GPU usable from Docker Desktop (WSL2) needs the Windows driver, which installs nvidia-smi.
  $out.nvidiaGpu = [bool](Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue)
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
  foreach ($a in @($apps | Where-Object { -not ($_.PSObject.Properties['archived'] -and $_.archived) })) {
    $m = @(@(Resolve-CatalogEntry $catalog ([string]$a.appId)) | Where-Object { $_ } | ForEach-Object { $_.manifest })
    if (-not $m.Count -or $a.appId -eq 'homepage') { continue }
    $web = $m[0].web.service
    # Headless apps (no web interface, e.g. Diun) get no card.
    if ([bool](Get-Prop2 $m[0].web 'headless' $false)) { continue }
    $port = [int](@(@(Get-Prop2 $m[0].services.$web 'ports' @()) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary } | ForEach-Object { $_.container }) + 0)[0]
    $scheme = $(if (@(@(Get-Prop2 $m[0].services.$web 'ports' @()) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary -and $_.protocol -eq 'https' }).Count) { 'https' } else { 'http' })
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
  $scheme = $(if (@(@(Get-Prop2 $Manifest.services.($Manifest.web.service) 'ports' @()) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary -and $_.protocol -eq 'https' }).Count) { 'https' } else { 'http' })
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
  $m = $(if ($plan.PSObject.Properties['Manifest'] -and $plan.Manifest) { $plan.Manifest } else { Get-CatalogApp -CatalogDir $CatalogDir -Id $plan.AppId })
  $steps = New-Object System.Collections.ArrayList
  $step = { param($name, $status, $message) $null = $steps.Add([ordered]@{ name = $name; status = $status; message = $message }) }
  $values = $plan.Values.Clone()
  foreach ($d in $plan.Derived) {
    try { $values["input:$d"] = Resolve-DerivedValue $m $d $values; & $step "Compute $d" 'Done' 'Computed on this PC.' }
    catch { & $step "Compute $d" 'Failed' $_.Exception.Message; return [ordered]@{ ok = $false; steps = $steps.ToArray(); project = $plan.Project; folder = $plan.Folder; health = $null; container = '' } }
  }
  $set = @($(if ($plan.PSObject.Properties['ComposeSet'] -and @($plan.ComposeSet).Count) { $plan.ComposeSet } else { , ([ordered]@{ file = 'compose.yaml'; component = 'app'; services = @(); content = $plan.Compose }) }))
  $fileNames = @($set | ForEach-Object { [string]$_.file })
  $webScheme = $(if (@(@(Get-Prop2 $m.services.($m.web.service) 'ports' @()) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary -and $_.protocol -eq 'https' }).Count) { 'https' } else { 'http' })
  $localUrl = $(if ($plan.LocalPort) { "${webScheme}://127.0.0.1:$($plan.LocalPort)/" } else { '' })
  # The instance: its own id, the manifest it came from, who created its resources (origin 'installed': the manager
  # created the folder, containers, named volumes and private network), its Compose files and a fingerprint of them,
  # so later edits made with other tools (Arcane, Portainer, an editor) are noticed before the manager changes it.
  # It is registered before any file is written (installState 'writing'): if the manager stops half-way, the
  # Installed apps page shows an interrupted installation that can be discarded instead of an orphaned folder.
  $record = [ordered]@{ instanceId = ('i-' + (New-SecretValue 6)); project = $plan.Project; appId = $plan.AppId; name = [string]$m.name; label = [string]$plan.Label; origin = 'installed'
    folder = $plan.Folder; installedAt = (Get-Date -Format 's'); images = @($plan.Images | ForEach-Object { $_.image }); localPort = $plan.LocalPort; localUrl = $localUrl; prepared = (-not $plan.StartNow)
    composeFiles = $fileNames; stackFile = 'dtc-stack.json'; composeSha256 = (Get-ComposeSetFingerprint $set); installState = 'writing' }
  Save-AppsRegistry $settings (@(Read-AppsRegistry $settings | Where-Object { $_.project -ne $plan.Project }) + [pscustomobject]$record)
  New-Item -ItemType Directory -Force -Path $plan.Folder | Out-Null
  foreach ($cf in $set) { [IO.File]::WriteAllText((Join-Path $plan.Folder $cf.file), [string]$cf.content) }
  $envPath = Join-Path $plan.Folder '.env'
  [IO.File]::WriteAllText($envPath, '')
  Set-SecretFileAcl $envPath
  [IO.File]::WriteAllText($envPath, (ConvertTo-EnvFileText $plan.EnvAll))
  [IO.File]::WriteAllText((Join-Path $plan.Folder 'README.md'), (New-AppReadme $m $plan.Project $plan.Folder $fileNames))
  if ($plan.PSObject.Properties['Stack'] -and $plan.Stack) { [IO.File]::WriteAllText((Join-Path $plan.Folder 'dtc-stack.json'), (($plan.Stack | ConvertTo-Json -Depth 12) + "`n"), (New-Object Text.UTF8Encoding($false))) }
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
  & $step 'Write the Compose project' 'Done' $(if ($set.Count -gt 1) { "$($plan.Folder): $($fileNames -join ', ') (one Compose project), .env, dtc-stack.json$(if ($creds.Count) { ', credentials.txt' })" } elseif ($creds.Count) { "$($plan.Folder) (sign-in details: credentials.txt)" } else { $plan.Folder })
  # Every file is written: the installation is no longer interrupted.
  $record.Remove('installState')
  Save-AppsRegistry $settings (@(Read-AppsRegistry $settings | Where-Object { $_.project -ne $plan.Project }) + [pscustomobject]$record)
  $hooks = @(Get-ResolvedPostInstall $m $values)
  if (-not $plan.StartNow) {
    if ($hooks.Count) { $hp = Join-Path $plan.Folder '.post-install.json'; [IO.File]::WriteAllText($hp, ''); Set-SecretFileAcl $hp; [IO.File]::WriteAllText($hp, (ConvertTo-Json -InputObject @($hooks) -Depth 6)) }
    Write-Audit 'app-prepare' "$($plan.AppId) project=$($plan.Project) folder=$($plan.Folder)"
    & $step 'Prepared, not started' 'Done' 'No app container was created or started. Use Start on the Installed apps page when resources allow: it checks memory again and downloads the pinned images.'
    return [ordered]@{ ok = $true; prepared = $true; steps = $steps.ToArray(); project = $plan.Project; folder = $plan.Folder; health = $null; container = (Get-AppContainerName $m $plan.Project $m.web.service); output = ''; localUrl = $localUrl; credentialsFile = $(if ($creds.Count) { Join-Path $plan.Folder 'credentials.txt' } else { '' }) }
  }
  $up = Invoke-Docker @((Get-AppComposeArgs $record) + @('up', '-d'))
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
  # A headless app has no web interface to probe: running (and healthy, when it has a health check) is all there is.
  if ($out.running -and [bool](Get-Prop2 $Manifest.web 'headless' $false)) { $out.http = [ordered]@{ result = 'not-applicable'; detail = 'Headless app: no web interface. Its state and health check are shown above.' }; $out.headless = $true; return $out }
  if ($out.running) {
    $primary = @(@(Get-Prop2 $Manifest.services.($Manifest.web.service) 'ports' @()) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary })[0]
    $c = @(Get-DockerContainerInventory -ProxyNetwork $Settings.ProxyNetwork | Where-Object { $_.name -eq $web })
    if ($c.Count) {
      $probe = $null
      # Retries only while an install or update waits for the app to come up; a page view probes once.
      $tries = $(if ($WaitSeconds -gt 0) { 10 } else { 1 })
      for ($i = 0; $i -lt $tries; $i++) { $probe = Test-ContainerPort -Container $c[0] -Port ([int]$primary.container) -ProxyNetwork $Settings.ProxyNetwork -Image $Settings.TraefikImage -NamePrefix $Settings.StackName -Schemes $(if ($primary.protocol -eq 'https') { @('https') } else { @('http', 'https') }); if ($probe.result -in 'http', 'https') { break }; if ($i -lt $tries - 1) { Start-Sleep -Seconds 4 } }
      $out.http = $probe
    }
  }
  return $out
}

# The manifest of an installed instance: the catalog's, or for an application imported by the provisioning engine the
# copy saved next to its compose.yaml (manifestFile in config\apps.json).
function Get-InstanceManifest($Record, $Catalog = $null) {
  $file = [string]$(if ($Record -is [System.Collections.IDictionary]) { $Record['manifestFile'] } else { Get-Prop2 $Record 'manifestFile' '' })
  $folder = [string]$(if ($Record -is [System.Collections.IDictionary]) { $Record['folder'] } else { Get-Prop2 $Record 'folder' '' })
  if ($file -and $folder -and $file -notmatch '[\\/]') { $p = Join-Path $folder $file; if (Test-Path -LiteralPath $p) { try { return ([IO.File]::ReadAllText($p) | ConvertFrom-Json) } catch { } } }
  if ($null -ne $Catalog) { $e = Resolve-CatalogEntry $Catalog ([string]$Record.appId); if ($e) { return $e.manifest }; return $null }
  return (Get-CatalogApp -CatalogDir $CatalogDir -Id ([string]$Record.appId))
}

function Find-InstalledApp([string]$Project) {
  $settings = Get-Settings
  $a = @(Read-AppsRegistry $settings | Where-Object { $_.project -eq $Project })
  if (-not $a.Count) { Stop-Request 404 "No app '$Project' was installed by this manager." }
  $compose = Get-AppComposePath $a[0]
  if ([string](Get-Prop2 $a[0] 'installState' '') -eq 'writing') { Stop-Request 409 "The installation of '$Project' was interrupted before all files were written. Discard it on the Installed apps page and install again." }
  if ([bool](Get-Prop2 $a[0] 'archived' $false)) { Stop-Request 409 "The record of '$Project' is archived. Restore it on the Installed apps page to manage it here." }
  if ([string](Get-Prop2 $a[0] 'origin' '') -eq 'adopted') {
    # Adopted projects were not generated here: their compose.yaml is the user's own. The folder must still be the
    # one Docker reports for the project's containers.
    if (-not (Test-Path -LiteralPath $compose)) { Stop-Request 409 "$($a[0].folder) no longer holds its Compose file; manage the project with docker compose directly." }
    return $a[0]
  }
  # Only projects this manager generated are managed: an edited or foreign compose file is left alone.
  if (-not (Test-Path -LiteralPath $compose) -or ([IO.File]::ReadAllText($compose) -notmatch "org\.traefik-proxy\.project: $([regex]::Escape($Project))")) { Stop-Request 409 "$($a[0].folder) no longer holds the Compose project this manager created; manage it with docker compose directly." }
  return $a[0]
}

# Installed apps: every registered instance with the lifecycle of its services (long-running services, completed or
# failed one-time jobs), its routes, and whether its compose.yaml changed outside the manager. Archived records are
# listed apart; Compose projects that look like catalog apps but are not registered are listed as discovered.
# running / total are raw container counts (kept for scripts); the page uses lifecycle.
function Get-AppsData {
  Assert-Installed
  $settings = Get-Settings
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $facts = @(Get-ComposeContainerFacts)
  $instances = @(Get-InstalledInstances $settings $catalog $facts)
  $views = @(foreach ($i in $instances) {
      $m = Get-InstanceManifest $i $catalog
      $composePath = Get-AppComposePath $i
      $composeText = $(if ($i.folder -and (Test-Path -LiteralPath $composePath)) { Get-AppComposeText $i } else { '' })
      $diff = @(); if ($m -and $composeText) { $diff = @(Get-AppUpdateDiff $m $composeText) }
      $cs = @($facts | Where-Object { $_.project -eq $i.project })
      $siblings = @($instances | Where-Object { $_.applicationId -eq $i.applicationId -and $_.project -ne $i.project -and -not $_.archived } | ForEach-Object { $_.project })
      [ordered]@{ project = $i.project; instanceId = $i.instanceId; appId = $i.appId; recordedAppId = $i.recordedAppId; applicationId = $i.applicationId; availability = $i.availability
        name = $i.name; label = $i.label; origin = $i.origin; archived = $i.archived; archivedAt = $i.archivedAt; folder = $i.folder; installedAt = $i.installedAt; folderExists = [bool]$composeText
        containers = @($cs | ForEach-Object { [ordered]@{ name = $_.name; state = $_.state; status = "$($_.state)$(if ($_.state -ne 'running') { " (exit $($_.exitCode))" })$(if ($_.health) { " ($($_.health))" })"; image = $_.image; health = $_.health } })
        running = @($cs | Where-Object { $_.state -eq 'running' }).Count; total = $cs.Count
        lifecycle = $i.lifecycle; siblings = $siblings
        localUrl = $(if ($i.localUrl) { $i.localUrl } elseif ($i.localPort) { "http://127.0.0.1:$($i.localPort)/" } else { '' })
        routes = $i.routes; prepared = [bool]($i.prepared -and $cs.Count -eq 0)
        composeChanged = $(if (-not $composeText -or -not $i.composeSha256) { $null } else { (Get-AppComposeFingerprint $i) -ne $i.composeSha256 })
        composeFiles = @(Get-AppComposeFileNames $i); installState = [string](Get-RecordValue $i 'installState' ''); hasStack = [bool]($i.folder -and (Test-Path -LiteralPath (Join-Path $i.folder 'dtc-stack.json')))
        updateAvailable = ($diff.Count -gt 0); updates = $diff; catalog = $(if ($m) { [ordered]@{ web = $m.web; exposure = $m.exposure } } else { $null }) }
    })
  $discovered = @(Get-UnregisteredInstallations $facts $catalog (@($instances | ForEach-Object { $_.project }) + $settings.StackName))
  return [ordered]@{ apps = @($views | Where-Object { -not $_.archived }); archived = @($views | Where-Object { $_.archived }); discovered = $discovered; checkedAt = (Get-Date -Format 's') }
}

# Details of one instance for inspection: services with roles and lifecycle, images, dependencies, health, exit codes,
# networks (with the other containers on them and their DNS names), published ports, volumes, hostnames, and the
# Cloudflare and authentik references. Read-only; no environment values, commands or secrets.
function Get-AppDetailData([string]$Project) {
  Assert-Installed
  $settings = Get-Settings
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $facts = @(Get-ComposeContainerFacts)
  $i = @(Get-InstalledInstances $settings $catalog $facts | Where-Object { $_.project -eq $Project })
  if (-not $i.Count) { Stop-Request 404 "No app '$Project' is registered in this manager." }
  $i = $i[0]
  $cs = @($facts | Where-Object { $_.project -eq $Project })
  # Every container on this PC (also outside Compose) for the network membership.
  $all = @($facts)
  $known = @($facts | ForEach-Object { $_.id })
  $loose = @((Invoke-Docker ps -a -q).Output | Where-Object { "$_" -match '^[0-9a-f]{12,64}$' -and $known -notcontains "$_".Substring(0, 12) })
  if ($loose.Count) { $r = Invoke-Docker inspect $loose; if ($r.ExitCode -eq 0) { $all += @(foreach ($x in ((@($r.Output) -join "`n") | ConvertFrom-Json)) { ConvertFrom-ContainerInspect $x }) } }
  $netNames = @($cs | ForEach-Object { @($_.networks) | ForEach-Object { $_.name } } | Select-Object -Unique)
  $networks = @(foreach ($n in $netNames) {
      $members = @($all | Where-Object { @($_.networks | Where-Object { $_.name -eq $n }).Count } | ForEach-Object { $c = $_; $e = @($c.networks | Where-Object { $_.name -eq $n })[0]
          [ordered]@{ container = $c.name; project = $c.project; service = $c.service; inThisApp = ($c.project -eq $Project); ip = $e.ip; dnsNames = @($e.dnsNames) } })
      [ordered]@{ name = $n; shared = ($n -eq $settings.ProxyNetwork); private = ($n -like "$Project`_*"); members = $members }
    })
  $cf = Read-CloudflareConfig -Settings $settings
  $cfHosts = @(); if ($cf.PSObject.Properties['managed'] -and $cf.managed) { $cfHosts = @($cf.managed.PSObject.Properties | Where-Object { @($i.hostnames) -contains $_.Name } | ForEach-Object { [ordered]@{ hostname = $_.Name; dnsRecord = [bool](Get-Prop2 $_.Value 'dnsRecordId' ''); accessApp = [bool](Get-Prop2 $_.Value 'accessAppId' '') } }) }
  $idApps = @()
  try { $id = Read-IdentityConfig -Settings $settings; $ap = Get-Prop2 (Get-Prop2 $id 'authentik' $null) 'apps' $null; if ($ap) { $idApps = @($ap.PSObject.Properties | Where-Object { @($i.routes | ForEach-Object { $_.name }) -contains $_.Name } | ForEach-Object { [ordered]@{ service = $_.Name; slug = [string](Get-Prop2 $_.Value 'slug' '') } }) } } catch { }
  $composePath = Get-AppComposePath $i
  $composeText = $(if ($i.folder -and (Test-Path -LiteralPath $composePath)) { Get-AppComposeText $i } else { '' })
  return [ordered]@{
    project = $i.project; instanceId = $i.instanceId; name = $i.name; label = $i.label; appId = $i.appId; applicationId = $i.applicationId; origin = $i.origin; folder = $i.folder; archived = $i.archived
    lifecycle = $i.lifecycle; cleanup = @(Get-JobCleanupCandidates $i.lifecycle); routes = $i.routes; networks = $networks
    published = @($cs | ForEach-Object { $c = $_; @($c.ports | Where-Object { $_.hostPort }) | ForEach-Object { [ordered]@{ container = $c.name; port = $_.container; hostIp = $_.hostIp; hostPort = $_.hostPort; localOnly = ($_.hostIp -in '127.0.0.1', '::1') } } })
    volumes = @($cs | ForEach-Object { $c = $_; @($c.mounts | Where-Object { $_.type -eq 'volume' }) | ForEach-Object { [ordered]@{ container = $c.name; name = $_.name; target = $_.target; readOnly = $_.readOnly; anonymous = [bool]($_.name -match '^[0-9a-f]{64}$') } } })
    cloudflare = $cfHosts; authentik = $idApps
    composeChanged = $(if (-not $composeText -or -not $i.composeSha256) { $null } else { (Get-AppComposeFingerprint $i) -ne $i.composeSha256 })
    composeFiles = @(Get-AppComposeFileNames $i)
    checkedAt = (Get-Date -Format 's')
  }
}

function Invoke-AppAction($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  $action = [string](Get-Field $Body 'action' '')
  if ($action -notin 'start', 'stop', 'restart') { Stop-Request 400 "Unknown action '$action'." }
  if ($action -eq 'start' -and -not @(Get-ComposeProjectContainers $a.project).Count) {
    # First start of a prepared project: check memory again, then create the containers (downloads the pinned images).
    try { $mm = Get-InstanceManifest $a; $need = Get-AppResourceEstimate $mm @{}; $res = Get-HostResources; $free = [Math]::Min($res.dockerFreeMB, $res.windowsFreeMB)
      if ($need.memoryMB -gt $free -and -not [bool](Get-Field $Body 'force' $false)) { Stop-Request 409 "$($a.name) needs about $($need.memoryMB) MB but only $free MB is free. Stop other apps first." } } catch [System.Management.Automation.RuntimeException] { if ($_.Exception.Message -match 'needs about') { throw } }
    $r = Invoke-Docker @((Get-AppComposeArgs $a) + @('up', '-d'))
    $hp = Join-Path $a.folder '.post-install.json'
    if ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $hp)) {
      $mm = Get-InstanceManifest $a
      $stored = @([IO.File]::ReadAllText($hp) | ConvertFrom-Json)
      $health = Get-AppHealth $a.project $mm (Get-Settings) 90
      $lp = $(if ($a.PSObject.Properties['localPort']) { [int]$a.localPort } else { 0 })
      $hookSteps = @(Invoke-AppPostInstall $mm $a.project $lp $stored $health @((Read-AppEnv (Join-Path $a.folder '.env')).Values))
      if (-not @($hookSteps | Where-Object { $_.status -ne 'Done' }).Count) { Remove-Item -LiteralPath $hp -Force }
      $r.Output = @($r.Output) + @($hookSteps | ForEach-Object { "$($_.status): $($_.name) $($_.message)" })
    }
  } else { $r = Invoke-Docker @((Get-AppComposeArgs $a) + @($action)) }
  Write-Audit "app-$action" "$($a.project) exit=$($r.ExitCode)"
  return [ordered]@{ ok = ($r.ExitCode -eq 0); project = $a.project; action = $action; output = ((ConvertTo-RedactedText @($r.Output)) -join "`n"); containers = @(Get-ComposeProjectContainers $a.project) }
}

function Get-AppLogsData([string]$Project, [int]$Tail, [string]$Service = '') {
  Assert-Installed
  $a = Find-InstalledApp $Project
  if ($Tail -lt 1 -or $Tail -gt 2000) { $Tail = 200 }
  $logArgs = @((Get-AppComposeArgs $a) + @('logs', '--no-color', '--tail', $Tail))
  # One service's logs (also of a one-time job that exited): the service must belong to this project.
  if ($Service) {
    $known = @(@(Get-ComposeContainerFacts | Where-Object { $_.project -eq $a.project } | ForEach-Object { $_.service }) + @((Get-ComposeServiceImages (Get-AppComposeText $a)).Keys))
    if ($Service -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$' -or $known -notcontains $Service) { Stop-Request 404 "No service '$Service' in $($a.project)." }
    $logArgs += $Service
  }
  $r = Invoke-Docker @logArgs
  $secrets = @((Read-AppEnv (Join-Path $a.folder '.env')).Values)
  return [ordered]@{ project = $a.project; service = $Service; lines = @(Hide-SecretValues @(ConvertTo-RedactedText @($r.Output)) $secrets) }
}

function Invoke-AppHealthRequest($Body) {
  Assert-Installed
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  try { $m = Get-InstanceManifest $a } catch { Stop-Request 409 $_.Exception.Message }
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
function Invoke-AppBackupCore($App, $Manifest, $Settings, [string]$Reason = 'manual') {
  $dir = Join-Path $App.folder ("backups\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $copyFile = { param($from, $name) if (Test-Path -LiteralPath $from) { $to = Join-Path $dir $name; [IO.File]::WriteAllText($to, ''); Set-SecretFileAcl $to; [IO.File]::WriteAllBytes($to, [IO.File]::ReadAllBytes($from)) } }
  $fileNames = @(Get-AppComposeFileNames $App)
  foreach ($fn in $fileNames) { & $copyFile (Join-Path $App.folder $fn) $fn }
  & $copyFile (Join-Path $App.folder '.env') '.env'
  & $copyFile (Join-Path $App.folder 'dtc-stack.json') 'dtc-stack.json'
  $values = @{}; foreach ($i in @(Get-Prop2 $Manifest 'inputs' @())) { if ($i.type -eq 'boolean') { $values["input:$($i.id)"] = 'true' } }
  $active = @(Get-ActiveServices $Manifest $values)
  $compose = Get-AppComposeText $App
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
  # Logical dumps of PostgreSQL databases with the database's own pg_dump (custom format), taken while it runs (a
  # consistent snapshot) and checked with pg_restore --list. The volume copy below restores into the same PostgreSQL
  # major version; the dump also restores into a newer one (docs/authentik-recovery.md). Values never leave the container.
  $dumps = @()
  foreach ($sp in $active) {
    if ([string](Get-Prop2 $sp.Value 'role' '') -ne 'database' -or [string](Get-Prop2 $sp.Value 'image' '') -notmatch '(^|/)postgres(ql)?:') { continue }
    $cn = Get-AppContainerName $Manifest $App.project $sp.Name
    if (-not (Test-ContainerRunning $cn)) { $dumps += [ordered]@{ service = $sp.Name; file = ''; ok = $false; message = 'not running: no dump (the volume copy still holds the data)' }; continue }
    $fname = "$($App.project)_$($sp.Name).pgdump"
    $d1 = Invoke-Docker exec $cn sh -c 'pg_dump -U "$POSTGRES_USER" -d "${POSTGRES_DB:-$POSTGRES_USER}" -Fc -f /tmp/dtc-backup.pgdump && pg_restore --list /tmp/dtc-backup.pgdump > /dev/null'
    $d2 = $(if ($d1.ExitCode -eq 0) { Invoke-Docker cp "${cn}:/tmp/dtc-backup.pgdump" (Join-Path $dir $fname) } else { $d1 })
    $null = Invoke-Docker exec $cn rm -f /tmp/dtc-backup.pgdump
    $dfile = Join-Path $dir $fname
    if (Test-Path -LiteralPath $dfile) { Set-SecretFileAcl $dfile }
    $dumps += [ordered]@{ service = $sp.Name; file = $fname; ok = ($d1.ExitCode -eq 0 -and $d2.ExitCode -eq 0 -and (Test-Path -LiteralPath $dfile)); format = 'pg_dump custom (-Fc)'
      sizeMB = $(if (Test-Path -LiteralPath $dfile) { [Math]::Round((Get-Item -LiteralPath $dfile).Length / 1MB, 2) } else { 0 }); message = $(if ($d1.ExitCode -ne 0) { ((ConvertTo-RedactedText @($d1.Output | Select-Object -Last 2)) -join ' ') } else { '' }) }
  }
  $stateful = @($active | Where-Object { Get-Prop2 $_.Value 'stateful' $false }).Count -gt 0
  $stopped = $false
  if ($stateful -and $volumes.Count) {
    $null = Invoke-Docker @((Get-AppComposeArgs $App) + @('stop'))
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
    if ($stopped) { $null = Invoke-Docker @((Get-AppComposeArgs $App) + @('start')) }
  }
  $info = [ordered]@{ app = $App.appId; project = $App.project; createdAt = (Get-Date -Format 's'); reason = $Reason; composeFiles = $fileNames; composeSha256 = (Get-AppComposeFingerprint $App)
    volumes = $results; skipped = $skipped; folders = @($folders | Select-Object -Unique); stoppedForBackup = $stopped; databases = @($dumps) }
  [IO.File]::WriteAllText((Join-Path $dir 'backup.json'), ($info | ConvertTo-Json -Depth 5))
  Write-Audit 'app-backup' "$($App.project) $dir volumes=$(@($results).Count) dumps=$(@($dumps | Where-Object { $_.ok }).Count)/$(@($dumps).Count)"
  return [ordered]@{ ok = -not @($results | Where-Object { -not $_.ok }).Count; folder = $dir; volumes = $results; skipped = $skipped; folders = $info.folders; stopped = $stopped; databases = @($dumps) }
}

function Invoke-AppBackup($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  try { $m = Get-InstanceManifest $a } catch { Stop-Request 409 $_.Exception.Message }
  return Invoke-AppBackupCore $a $m (Get-Settings)
}

# Update preview: what the catalog would change, plus a notification when the registry now has a newer build under the
# same tag. Nothing is pulled. Database (stateful) services never change their major version through this path.
function Get-AppUpdateItems($App, $Manifest, [switch]$Registry) {
  $text = Get-AppComposeText $App
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
  try { $m = Get-InstanceManifest $a } catch { Stop-Request 409 $_.Exception.Message }
  $items = @(Get-AppUpdateItems $a $m -Registry:([bool](Get-Field $Body 'registry' $true)))
  $applicable = @($items | Where-Object { -not $_.blocked })
  $key = Get-TextSha256 (($applicable | ForEach-Object { "$($_.service)|$($_.from)|$($_.to)" }) -join "`n")
  $notes = $(if ($m.PSObject.Properties['update'] -and $m.update.PSObject.Properties['notes']) { [string]$m.update.notes } else { '' })
  # compose.yaml edited outside the manager (Arcane, Portainer, an editor) since it was generated or last updated here.
  $baseline = [string](Get-Prop2 $a 'composeSha256' '')
  $external = $(if ($baseline) { (Get-AppComposeFingerprint $a) -ne $baseline } else { $null })
  return [ordered]@{ project = $a.project; changes = $applicable; blocked = @($items | Where-Object { $_.blocked }); previewKey = $(if ($applicable.Count) { $key } else { '' }); notes = $notes
    externalChanges = $external; externalNote = $(if ($external) { 'compose.yaml was changed outside the manager since it was written here. The update changes only the image lines and keeps those edits; review them before continuing.' } elseif ($null -eq $external) { 'No fingerprint of compose.yaml was recorded (installed by an earlier version), so changes made with other tools cannot be detected.' } else { '' })
    releaseNotes = @(@(if ($m.PSObject.Properties['docs']) { $m.docs }) | Select-Object -First 1)
    keeps = @('A backup of the configuration and data volumes is made first (apps with a database are stopped for it).', 'compose.yaml is saved as compose.yaml.bak-<time>; only image lines change; your other edits stay.', 'Data volumes, media and library folders are never deleted by an update.') }
}

function Invoke-AppUpdateApply($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  $m = Get-InstanceManifest $a
  $items = @(Get-AppUpdateItems $a $m -Registry:([bool](Get-Field $Body 'registry' $true)) | Where-Object { -not $_.blocked })
  $key = Get-TextSha256 (($items | ForEach-Object { "$($_.service)|$($_.from)|$($_.to)" }) -join "`n")
  if (-not $items.Count -or $key -ne [string](Get-Field $Body 'previewKey' '')) { Stop-Request 409 'The installed project, the catalog or the registry changed since the preview. Preview again.' }
  $settings = Get-Settings
  $baseline = [string](Get-Prop2 $a 'composeSha256' '')
  if ($baseline -and (Get-AppComposeFingerprint $a) -ne $baseline -and -not [bool](Get-Field $Body 'acknowledgeExternalChanges' $false)) { Stop-Request 409 'compose.yaml was changed outside the manager. Review the changes and confirm that the update may proceed (only image lines change; your edits are kept).' }
  $backup = Invoke-AppBackupCore $a $m $settings 'before-update'
  if (-not $backup.ok) { Stop-Request 500 "The backup before the update failed ($($backup.folder)); nothing was updated." }
  # Only image lines change, in whichever file of the stack defines the service; every file is saved first.
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bak = ''
  foreach ($path in (Get-AppComposeFiles $a)) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = [IO.File]::ReadAllText($path)
    $new = $text; foreach ($c in $items) { $new = $new.Replace("    image: $($c.from)", "    image: $($c.to)") }
    if ($new -ne $text) { Copy-Item -LiteralPath $path -Destination "$path.bak-$stamp"; if (-not $bak) { $bak = "$path.bak-$stamp" }; Write-TextFileAtomic $path $new }
  }
  # The updated files are the new baseline for detecting edits made with other tools.
  $records = @(Read-AppsRegistry $settings)
  foreach ($rec in @($records | Where-Object { $_.project -eq $a.project })) { $rec | Add-Member -NotePropertyName composeSha256 -NotePropertyValue (Get-AppComposeFingerprint $a) -Force }
  Save-AppsRegistry $settings $records
  Update-AppStackImages $a
  $up = Invoke-Docker @((Get-AppComposeArgs $a) + @('up', '-d'))
  Write-Audit 'app-update' "$($a.project) $(($items | ForEach-Object { $_.to }) -join ',') exit=$($up.ExitCode)"
  return [ordered]@{ ok = ($up.ExitCode -eq 0); project = $a.project; backup = $(if ($bak) { Split-Path -Leaf $bak } else { '' }); dataBackup = $backup.folder; backupId = (Split-Path -Leaf $backup.folder); changes = $items
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
  if (($deleteVolumes -or $deleteFolder) -and [string](Get-Prop2 $a 'origin' '') -eq 'adopted') { Stop-Request 400 'This project was adopted: the manager did not create its data or files and never deletes them. Only its containers can be removed here.' }
  if ($deleteVolumes) {
    $inv = Get-AppRemovalInventory $a $settings
    $shared = @($inv.volumes | Where-Object { @($_.sharedWith).Count })
    if ($shared.Count) { Stop-Request 409 "Data volumes $(@($shared | ForEach-Object { $_.name }) -join ', ') are also used by other containers; they are never deleted with this app. Remove without deleting data." }
  }
  $cs = @(Get-ComposeProjectContainers $a.project | ForEach-Object { $_.name })
  $routes = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.target.type -eq 'docker' -and $cs -contains $_.target.host } | ForEach-Object { $_.name })
  if ($routes.Count) { Stop-Request 409 "Remove the service route(s) $($routes -join ', ') on the Services page first, so the hostname does not answer 502." }
  $args2 = @((Get-AppComposeArgs $a) + @('down'))
  if ($deleteVolumes) { $args2 += '-v' }
  $r = Invoke-Docker @args2
  if ($r.ExitCode -ne 0) { Stop-Request 500 "docker compose down failed: $((ConvertTo-RedactedText @($r.Output)) -join ' ')" }
  $folderRemoved = $false
  if ($deleteFolder) {
    foreach ($f in @(Get-ChildItem -LiteralPath $a.folder -Force -File)) { if (Test-GeneratedAppFile $f.Name) { $f.IsReadOnly = $false; Remove-Item -LiteralPath $f.FullName -Force } }
    if (-not @(Get-ChildItem -LiteralPath $a.folder -Force).Count) { Remove-Item -LiteralPath $a.folder -Force; $folderRemoved = $true }
  }
  Save-AppsRegistry $settings @(Read-AppsRegistry $settings | Where-Object { $_.project -ne $a.project })
  Write-Audit 'app-remove' "$($a.project) volumes=$deleteVolumes folder=$deleteFolder"
  $kept = @((Invoke-Docker volume ls -q --filter "name=$($a.project)_").Output | Where-Object { $_ })
  return [ordered]@{ removed = $true; project = $a.project; volumesDeleted = $deleteVolumes; keptVolumes = @($kept); folderRemoved = $folderRemoved; folder = $a.folder }
}

# Every container on this PC as facts (Compose and others), for shared volume and network checks.
function Get-AllContainerFacts {
  $facts = @(Get-ComposeContainerFacts)
  $known = @($facts | ForEach-Object { $_.id })
  $loose = @((Invoke-Docker ps -a -q).Output | Where-Object { "$_" -match '^[0-9a-f]{12,64}$' -and $known -notcontains "$_".Substring(0, 12) })
  if ($loose.Count) { $r = Invoke-Docker inspect $loose; if ($r.ExitCode -eq 0) { $facts += @(foreach ($x in ((@($r.Output) -join "`n") | ConvertFrom-Json)) { ConvertFrom-ContainerInspect $x }) } }
  return $facts
}

# What removing a registered app would touch and what it leaves alone (lib\AppInstances.psm1 Get-RemovalInventory).
function Get-AppRemovalInventory($Record, $Settings) {
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $inst = ConvertTo-AppInstance $Record $catalog
  $all = @(Get-AllContainerFacts)
  $cs = @($all | Where-Object { $_.project -eq $inst.project })
  $names = @($cs | ForEach-Object { $_.name })
  $routes = @((Read-ServiceRegistry -Settings $Settings).services | Where-Object { $_.target.type -eq 'docker' -and $names -contains $_.target.host })
  $hosts = @($routes | ForEach-Object { @($_.hostnames) })
  $cf = Read-CloudflareConfig -Settings $Settings
  $cfHosts = @(); if ($cf.PSObject.Properties['managed'] -and $cf.managed) { $cfHosts = @($cf.managed.PSObject.Properties | Where-Object { $hosts -contains $_.Name } | ForEach-Object { $_.Name }) }
  $idApps = @(); try { $ap = Get-Prop2 (Get-Prop2 (Read-IdentityConfig -Settings $Settings) 'authentik' $null) 'apps' $null; if ($ap) { $idApps = @($ap.PSObject.Properties | Where-Object { @($routes | ForEach-Object { $_.name }) -contains $_.Name } | ForEach-Object { [string](Get-Prop2 $_.Value 'slug' $_.Name) }) } } catch { }
  $files = @(); if ($inst.folder -and (Test-Path -LiteralPath $inst.folder)) { $files = @(Get-ChildItem -LiteralPath $inst.folder -Force -File | Where-Object { Test-GeneratedAppFile $_.Name } | ForEach-Object { $_.Name }) }
  return Get-RemovalInventory -Instance $inst -Containers $cs -All $all -Routes $routes -CloudflareHosts $cfHosts -IdentityApps $idApps -ProxyNetwork $Settings.ProxyNetwork -FolderFiles $files
}

function Get-AppRemovePlan($Body) {
  Assert-Installed
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  return Get-AppRemovalInventory $a (Get-Settings)
}

# Archives the record of an obsolete installation: the manager hides it, and nothing on the PC changes (containers,
# volumes, folder, routes, Cloudflare and authentik stay as they are). Refused while one of its containers runs.
function Invoke-AppArchive($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $project = [string](Get-Field $Body 'project' '')
  $records = @(Read-AppsRegistry $settings)
  $r = @($records | Where-Object { $_.project -eq $project })
  if (-not $r.Count) { Stop-Request 404 "No app '$project' is registered in this manager." }
  if ([bool](Get-Prop2 $r[0] 'archived' $false)) { Stop-Request 409 "The record of '$project' is already archived." }
  $running = @(Get-ComposeProjectContainers $project | Where-Object { $_.state -in 'running', 'restarting', 'paused' })
  if ($running.Count) { Stop-Request 409 "$project still runs ($(@($running | ForEach-Object { $_.name }) -join ', ')). Archive only records of installations that are not in use; stop it first if it is obsolete." }
  $r[0] | Add-Member -NotePropertyName archived -NotePropertyValue $true -Force
  $r[0] | Add-Member -NotePropertyName archivedAt -NotePropertyValue (Get-Date -Format 's') -Force
  Save-AppsRegistry $settings $records
  Write-Audit 'app-archive' "$project (record only; nothing else changed)"
  return [ordered]@{ ok = $true; project = $project; archived = $true; unchanged = @('containers', 'volumes', 'folder', 'routes', 'Cloudflare', 'authentik') }
}

function Invoke-AppRestoreRecord($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $project = [string](Get-Field $Body 'project' '')
  $records = @(Read-AppsRegistry $settings)
  $r = @($records | Where-Object { $_.project -eq $project -and [bool](Get-Prop2 $_ 'archived' $false) })
  if (-not $r.Count) { Stop-Request 404 "No archived record '$project'." }
  $r[0].PSObject.Properties.Remove('archived'); $r[0].PSObject.Properties.Remove('archivedAt')
  Save-AppsRegistry $settings $records
  Write-Audit 'app-restore-record' $project
  return [ordered]@{ ok = $true; project = $project; archived = $false }
}

# Review of a Compose project found on this PC that looks like a catalog app but is not registered. Adopting it only
# registers it (origin 'adopted'); nothing in the project changes, and the manager never deletes its data or files.
function Get-AppAdoptPlan($Body) {
  Assert-Installed
  $settings = Get-Settings
  $project = [string](Get-Field $Body 'project' '')
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $facts = @(Get-ComposeContainerFacts)
  $registered = @(Read-AppsRegistry $settings | ForEach-Object { $_.project })
  if ($registered -contains $project) { Stop-Request 409 "'$project' is already registered." }
  $u = @(Get-UnregisteredInstallations $facts $catalog (@($registered) + $settings.StackName) | Where-Object { $_.project -eq $project })
  if (-not $u.Count) { Stop-Request 404 "No unregistered Compose project '$project' that matches a catalog app was found." }
  $u = $u[0]
  $cs = @($facts | Where-Object { $_.project -eq $project })
  $folders = @($cs | ForEach-Object { $_.workingDir } | Where-Object { $_ } | Select-Object -Unique)
  $folder = $(if ($folders.Count -eq 1) { [string]$folders[0] } else { '' })
  $checks = New-Object System.Collections.ArrayList
  $check = { param($label, $state, $message) $null = $checks.Add([ordered]@{ label = $label; state = $state; message = $message }) }
  & $check 'Recognized application' 'ok' "$($u.name): $($u.reason)"
  if ($u.availability -eq 'retired') { & $check 'Catalog status' 'warning' "$($u.name) is no longer offered for new installations; adopting it only lets you manage this existing one." }
  & $check 'Project folder' $(if ($folder -and (Test-Path -LiteralPath $folder)) { 'ok' } else { 'failed' }) $(if ($folder) { $folder } else { "Docker reports $($folders.Count) folders for this project's containers." })
  $composeName = Find-ComposeFileName $folder
  $hasCompose = [bool]$composeName
  & $check 'Compose file' $(if ($hasCompose) { 'ok' } else { 'failed' }) $(if ($hasCompose) { "$composeName found; it stays exactly as it is." } else { "No $($ComposeFileNames -join ', ') in the folder; keep managing it with docker compose or your tool." })
  $entry = Resolve-CatalogEntry $catalog $u.appId
  $lc = Get-DeploymentLifecycle -Containers $cs -Manifest $entry.manifest
  $key = Get-TextSha256 ("$project|$folder|" + (@($cs | ForEach-Object { "$($_.id):$($_.image)" } | Sort-Object) -join ','))
  return [ordered]@{ project = $project; appId = $u.appId; name = $u.name; folder = $folder; composeFile = $composeName; lifecycle = $lc; checks = $checks.ToArray(); canAdopt = -not @($checks | Where-Object { $_.state -eq 'failed' }).Count; reviewKey = $key
    keeps = @('Nothing in the project changes: compose.yaml, .env, containers, volumes and networks stay as they are.', 'The manager never deletes data or files of an adopted project; removing it here removes its containers only.', 'Changes made later with Arcane, Portainer or an editor are noticed before the manager changes anything.') }
}

function Invoke-AppAdopt($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $plan = Get-AppAdoptPlan $Body
  if (-not $plan.canAdopt) { Stop-Request 409 'This project cannot be adopted; see the review.' }
  if ($plan.reviewKey -ne [string](Get-Field $Body 'reviewKey' '')) { Stop-Request 409 'The project changed since the review. Review it again.' }
  $label = ([string](Get-Field $Body 'label' '')).Trim(); if ($label.Length -gt 40 -or $label -match '[\r\n<>"]') { Stop-Request 400 'The instance label may have at most 40 characters, without quotes or angle brackets.' }
  $compose = [IO.File]::ReadAllText((Get-AppComposePath $plan))
  $record = [ordered]@{ instanceId = ('i-' + (New-SecretValue 6)); project = $plan.project; appId = $plan.appId; name = $plan.name; label = $label; origin = 'adopted'; folder = $plan.folder; composeFile = $plan.composeFile
    installedAt = (Get-Date -Format 's'); images = @($plan.lifecycle.services | ForEach-Object { $_.image } | Where-Object { $_ }); localPort = 0; localUrl = ''; prepared = $false; composeSha256 = (Get-TextSha256 $compose) }
  Save-AppsRegistry $settings (@(Read-AppsRegistry $settings) + [pscustomobject]$record)
  Write-Audit 'app-adopt' "$($plan.appId) project=$($plan.project) folder=$($plan.folder)"
  return [ordered]@{ ok = $true; project = $plan.project; instanceId = $record.instanceId }
}

# Completed one-time job containers (e.g. Rocket.Chat's MongoDB permission and replica-set setup) that may be removed
# to tidy up. Their Compose definitions, volumes and data stay; Compose creates them again (and they exit again) the
# next time the app is started or recreated. Nothing runs automatically.
function Get-AppCleanupPlan($Body) {
  Assert-Installed
  $settings = Get-Settings
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $inst = ConvertTo-AppInstance $a $catalog
  $lc = Get-InstanceLifecycle $inst @(Get-ComposeContainerFacts) $catalog
  $c = @(Get-JobCleanupCandidates $lc)
  return [ordered]@{ project = $a.project; candidates = $c; key = (Get-TextSha256 ((@($c | ForEach-Object { "$($_.container)|$($_.finishedAt)" }) -join ','))); lifecycle = $lc.headline
    notes = @('Only containers of one-time jobs that completed successfully (exit code 0) and whose role is declared by the app or by Compose.', 'compose.yaml, the job definitions, volumes and data are not changed: the jobs run again the next time the app is started or recreated.', 'No other container is stopped, restarted or recreated.') }
}

function Invoke-AppCleanup($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $plan = Get-AppCleanupPlan $Body
  if (-not @($plan.candidates).Count) { Stop-Request 409 'There is nothing to tidy up.' }
  if ($plan.key -ne [string](Get-Field $Body 'key' '')) { Stop-Request 409 'The containers changed since the preview. Preview again.' }
  $results = @(foreach ($c in $plan.candidates) {
      $now = @(Get-ComposeContainerFacts | Where-Object { $_.name -eq $c.container })
      if (-not $now.Count -or $now[0].state -ne 'exited' -or $now[0].exitCode -ne 0) { [ordered]@{ container = $c.container; ok = $false; message = 'Its state changed; left alone.' }; continue }
      $r = Invoke-Docker rm $c.container
      [ordered]@{ container = $c.container; ok = ($r.ExitCode -eq 0); message = $(if ($r.ExitCode -eq 0) { 'Removed (definition and data kept).' } else { (@($r.Output) -join ' ') }) }
    })
  Write-Audit 'app-cleanup' "$($plan.project) $(@($results | Where-Object { $_.ok } | ForEach-Object { $_.container }) -join ',')"
  return [ordered]@{ ok = -not @($results | Where-Object { -not $_.ok }).Count; project = $plan.project; results = $results }
}

# --- Installed apps: restore and roll back, interrupted installations, stack and routing diagnostics -----------------

# Backups of one app (<app folder>\backups\<yyyyMMdd-HHmmss>\backup.json), newest first.
function Get-AppBackupList($App) {
  $root = Join-Path ([string]$App.folder) 'backups'
  if (-not (Test-Path -LiteralPath $root)) { return @() }
  return @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'backup.json')) } | Sort-Object Name -Descending | ForEach-Object {
      $info = $null; try { $info = [IO.File]::ReadAllText((Join-Path $_.FullName 'backup.json')) | ConvertFrom-Json } catch { }
      $files = @(Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { Test-GeneratedAppFile $_.Name } | ForEach-Object { $_.Name })
      [ordered]@{ id = $_.Name; createdAt = [string](Get-Prop2 $info 'createdAt' ''); reason = [string](Get-Prop2 $info 'reason' 'manual')
        volumes = @(@(Get-Prop2 $info 'volumes' @()) | ForEach-Object { [ordered]@{ volume = [string]$_.volume; ok = [bool]$_.ok; sizeMB = $_.sizeMB } })
        files = $files; composeFiles = @(Get-Prop2 $info 'composeFiles' @()); folders = @(Get-Prop2 $info 'folders' @()); valid = [bool]$info }
    })
}

function Get-AppBackupsData([string]$Project) {
  Assert-Installed
  $a = Find-InstalledApp $Project
  return [ordered]@{ project = $a.project; folder = (Join-Path $a.folder 'backups'); backups = @(Get-AppBackupList $a) }
}

# What restoring a backup would do. Only volumes of this project ("<project>_...") and files the manager generates are
# ever restored; a safety backup of the current state is made first, so a restore can itself be undone.
function Get-AppRestorePlan($Body) {
  Assert-Installed
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  if ([string](Get-Prop2 $a 'origin' '') -eq 'adopted') { Stop-Request 409 'This project was adopted: the manager did not create its data and does not restore it. Use your own backup tools.' }
  $id = [string](Get-Field $Body 'backup' '')
  if ($id -notmatch '^\d{8}-\d{6}$') { Stop-Request 400 'Choose a backup.' }
  $b = @(Get-AppBackupList $a | Where-Object { $_.id -eq $id })
  if (-not $b.Count -or -not $b[0].valid) { Stop-Request 404 "No backup '$id' of $($a.project)." }
  $b = $b[0]
  $dir = Join-Path $a.folder "backups\$id"
  $restoreFiles = [bool](Get-Field $Body 'restoreFiles' $true)
  $vols = @(foreach ($v in $b.volumes) {
      $file = Join-Path $dir "$($v.volume).tar.gz"
      $own = $v.volume.StartsWith("$($a.project)_")
      [ordered]@{ volume = $v.volume; sizeMB = $v.sizeMB; available = ($v.ok -and (Test-Path -LiteralPath $file)); ownVolume = $own; exists = ((Invoke-Docker volume inspect $v.volume).ExitCode -eq 0) }
    })
  $bad = @($vols | Where-Object { -not $_.ownVolume })
  if ($bad.Count) { Stop-Request 409 "The backup names volumes that do not belong to $($a.project) ($(@($bad | ForEach-Object { $_.volume }) -join ', ')); it is not restored." }
  $files = @(if ($restoreFiles) { @($b.files | Where-Object { $_ -ne 'credentials.txt' }) })
  $folders = @($b.folders | Where-Object { [string]$_ -match '^[A-Za-z0-9][A-Za-z0-9_./-]*$' -and [string]$_ -notmatch '\.\.' -and (Test-Path -LiteralPath (Join-Path $dir (([string]$_) -replace '/', '_'))) })
  $key = Get-TextSha256 ("$($a.project)|$id|$restoreFiles|" + ((@($vols | ForEach-Object { "$($_.volume):$($_.sizeMB)" }) + $files + $folders) -join ','))
  return [ordered]@{ project = $a.project; backup = $id; createdAt = $b.createdAt; reason = $b.reason; restoreFiles = $restoreFiles; volumes = $vols; files = $files; folders = $folders; key = $key
    steps = @('Back up the current state first (safety backup, so this restore can be undone).', "Stop the app's containers.", 'Replace the contents of each data volume with the backup.',
      $(if ($files.Count) { "Put back $($files -join ', ') from the backup (the Compose files as they were then)." } else { 'Keep the current Compose files and .env.' }),
      $(if ($folders.Count) { "Copy back the configuration folders: $($folders -join ', ')." } else { $null }), 'Start the app again (docker compose up -d) and check its health.') | Where-Object { $_ }
    keeps = @('Folders you chose (media, photos, recordings) are never touched.', 'Routes, Cloudflare and authentik settings are not changed.', 'Other apps and their volumes are not touched.') }
}

function Invoke-AppRestore($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $plan = Get-AppRestorePlan $Body
  if ($plan.key -ne [string](Get-Field $Body 'key' '')) { Stop-Request 409 'The backup or the app changed since the preview. Preview again.' }
  $a = Find-InstalledApp $plan.project
  $m = Get-InstanceManifest $a
  $steps = New-Object System.Collections.ArrayList
  $step = { param($name, $status, $message) $null = $steps.Add([ordered]@{ name = $name; status = $status; message = $message }) }
  $safety = Invoke-AppBackupCore $a $m $settings 'before-restore'
  if (-not $safety.ok) { Stop-Request 500 "The safety backup failed ($($safety.folder)); nothing was restored." }
  & $step 'Safety backup of the current state' 'Done' (Split-Path -Leaf $safety.folder)
  $stop = Invoke-Docker @((Get-AppComposeArgs $a) + @('stop'))
  & $step 'Stop the app' $(if ($stop.ExitCode -eq 0) { 'Done' } else { 'Failed' }) ((ConvertTo-RedactedText @($stop.Output | Select-Object -Last 2)) -join ' ')
  $dir = Join-Path $a.folder "backups\$($plan.backup)"
  $ok = $true
  foreach ($v in @($plan.volumes | Where-Object { $_.available })) {
    $r = Invoke-Docker run --rm --pull never --network none -v "$($v.volume):/v" -v "${dir}:/b:ro" --entrypoint sh $settings.TraefikImage -c "cd /v && rm -rf ./* ./.[!.]* ./..?* && tar xzf '/b/$($v.volume).tar.gz' -C /v"
    if ($r.ExitCode -ne 0) { $ok = $false }
    & $step "Restore volume $($v.volume)" $(if ($r.ExitCode -eq 0) { 'Done' } else { 'Failed' }) "$($v.sizeMB) MB"
    if (-not $ok) { break }
  }
  if (-not $ok) {
    # Roll back: every volume of the safety backup is put back, files and folders are left as they were, then the app
    # starts in its state from before this restore.
    $sdir = [string]$safety.folder
    foreach ($sv in @($safety.volumes | Where-Object { $_.ok })) {
      $rr = Invoke-Docker run --rm --pull never --network none -v "$($sv.volume):/v" -v "${sdir}:/b:ro" --entrypoint sh $settings.TraefikImage -c "cd /v && rm -rf ./* ./.[!.]* ./..?* && tar xzf '/b/$($sv.volume).tar.gz' -C /v"
      & $step "Roll back volume $($sv.volume) from the safety backup" $(if ($rr.ExitCode -eq 0) { 'Done' } else { 'Failed' }) ''
    }
    $up0 = Invoke-Docker @((Get-AppComposeArgs $a) + @('up', '-d'))
    & $step 'Start the app in its previous state' $(if ($up0.ExitCode -eq 0) { 'Done' } else { 'Failed' }) ''
    Write-Audit 'app-restore-failed' "$($a.project) backup=$($plan.backup) rolled back from $(Split-Path -Leaf $sdir)"
    return [ordered]@{ ok = $false; rolledBack = $true; project = $a.project; backup = $plan.backup; safetyBackup = (Split-Path -Leaf $sdir); steps = $steps.ToArray(); health = $null }
  }
  if ($plan.files.Count) {
    foreach ($f in $plan.files) {
      $target = Join-Path $a.folder $f
      $bytes = [IO.File]::ReadAllBytes((Join-Path $dir $f))
      if ($f -eq '.env' -or -not (Test-Path -LiteralPath $target)) { [IO.File]::WriteAllText($target, ''); if ($f -eq '.env') { Set-SecretFileAcl $target } }
      [IO.File]::WriteAllBytes($target, $bytes)
    }
    # The Compose file set of the backup becomes the app's set again; files only the current set had are kept on disk
    # but no longer used (they stay visible in the folder).
    $names = @($plan.files | Where-Object { $_ -match '^compose(\.[a-z0-9-]+)?\.yaml$' })
    $records = @(Read-AppsRegistry $settings)
    foreach ($rec in @($records | Where-Object { $_.project -eq $a.project })) {
      if ($names.Count) { $rec | Add-Member -NotePropertyName composeFiles -NotePropertyValue @($names | Sort-Object { if ($_ -eq 'compose.yaml') { 0 } else { 1 } }, { $_ }) -Force }
      $rec | Add-Member -NotePropertyName composeSha256 -NotePropertyValue (Get-AppComposeFingerprint $rec) -Force
    }
    Save-AppsRegistry $settings $records
    $a = Find-InstalledApp $plan.project
    & $step 'Restore the Compose files and .env' 'Done' ($plan.files -join ', ')
  }
  foreach ($f in $plan.folders) {
    $src = Join-Path $dir (([string]$f) -replace '/', '_')
    $dst = Join-Path $a.folder (([string]$f) -replace '/', '\')
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    & $step "Restore folder $f" 'Done' ''
  }
  $up = Invoke-Docker @((Get-AppComposeArgs $a) + @('up', '-d'))
  & $step 'Start the app (docker compose up -d)' $(if ($up.ExitCode -eq 0) { 'Done' } else { 'Failed' }) ((Hide-SecretValues @(ConvertTo-RedactedText @($up.Output | Select-Object -Last 4)) @((Read-AppEnv (Join-Path $a.folder '.env')).Values)) -join ' ')
  $health = $null; if ($up.ExitCode -eq 0) { $health = Get-AppHealth $a.project $m $settings 60 }
  Write-Audit 'app-restore' "$($a.project) backup=$($plan.backup) files=$($plan.files.Count) volumes=$(@($plan.volumes).Count) safety=$(Split-Path -Leaf $safety.folder)"
  return [ordered]@{ ok = ($ok -and $up.ExitCode -eq 0); project = $a.project; backup = $plan.backup; safetyBackup = (Split-Path -Leaf $safety.folder); steps = $steps.ToArray(); health = $health }
}

# An installation interrupted before all its files were written (installState 'writing'): what is there, and
# discarding it (its containers if any, the files the manager generates, the folder when empty, and the record).
# Data volumes are kept unless the project name is typed; folders you chose are never touched.
function Invoke-AppDiscardInterrupted($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $project = [string](Get-Field $Body 'project' '')
  $rec = @(Read-AppsRegistry $settings | Where-Object { $_.project -eq $project })
  if (-not $rec.Count) { Stop-Request 404 "No app '$project' is registered in this manager." }
  $rec = $rec[0]
  if ([string](Get-Prop2 $rec 'installState' '') -ne 'writing') { Stop-Request 409 "'$project' is not an interrupted installation." }
  $removed = @()
  if (@(Get-ComposeProjectContainers $project).Count -and @(Get-AppComposeFiles $rec | Where-Object { Test-Path -LiteralPath $_ }).Count) {
    $null = Invoke-Docker @((Get-AppComposeArgs $rec) + @('down'))
    $removed += 'containers'
  }
  if ($rec.folder -and (Test-Path -LiteralPath $rec.folder)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $rec.folder -Force -File)) { if (Test-GeneratedAppFile $f.Name) { $f.IsReadOnly = $false; Remove-Item -LiteralPath $f.FullName -Force; $removed += $f.Name } }
    if (-not @(Get-ChildItem -LiteralPath $rec.folder -Recurse -Force -File).Count) { Remove-Item -LiteralPath $rec.folder -Recurse -Force; $removed += 'folder' }
  }
  Save-AppsRegistry $settings @(Read-AppsRegistry $settings | Where-Object { $_.project -ne $project })
  Write-Audit 'app-discard-interrupted' "$project removed=$($removed -join ',')"
  return [ordered]@{ ok = $true; project = $project; removed = $removed; folderKept = [bool]($rec.folder -and (Test-Path -LiteralPath $rec.folder)) }
}

# Pure: the blocks of a generated Traefik file, split into routers, services and middlewares (each with its YAML), so
# one app's routing can be inspected piece by piece.
function Split-TraefikRouteYaml([string]$Text) {
  $out = [ordered]@{ routers = @(); services = @(); middlewares = @() }
  $section = ''; $cur = $null; $items = @{ routers = New-Object System.Collections.ArrayList; services = New-Object System.Collections.ArrayList; middlewares = New-Object System.Collections.ArrayList }
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^  (routers|services|middlewares):\s*$') { $section = $Matches[1]; $cur = $null; continue }
    if ($line -match '^\S') { $section = ''; $cur = $null; continue }
    if (-not $section) { continue }
    if ($line -match '^    ([A-Za-z0-9@_.-]+):\s*$') { $cur = [ordered]@{ name = $Matches[1]; lines = New-Object System.Collections.ArrayList }; $null = $items[$section].Add($cur); $null = $cur.lines.Add($line.Substring(4)); continue }
    if ($cur -and $line -match '^      ') { $null = $cur.lines.Add($line.Substring(4)) }
  }
  foreach ($k in @('routers', 'services', 'middlewares')) {
    $out[$k] = @(foreach ($it in $items[$k]) {
        $o = [ordered]@{ name = $it.name; yaml = (@($it.lines) -join "`n") }
        $rule = @($it.lines | Where-Object { $_ -match '^\s+rule:\s*' } | ForEach-Object { ($_ -replace '^\s+rule:\s*', '').Trim("'") })[0]
        if ($rule) { $o.rule = $rule }
        $url = @($it.lines | Where-Object { $_ -match '^\s+- url:\s*' } | ForEach-Object { ($_ -replace '^\s+- url:\s*', '').Trim("'") })
        if ($url.Count) { $o.urls = $url }
        $o
      })
  }
  return $out
}

# Stack description of an installation without dtc-stack.json (installed by an earlier version, or adopted): read from
# its own Compose files with `docker compose config --no-interpolate` (no .env values are read or returned).
function Get-DerivedAppStack($App, $Manifest, $Settings) {
  $r = Invoke-Docker @((Get-AppComposeArgs $App) + @('config', '--format', 'json', '--no-interpolate'))
  if ($r.ExitCode -ne 0) { return $null }
  try { $cfg = (@($r.Output) -join "`n") | ConvertFrom-Json } catch { return $null }
  $svcs = @(foreach ($sp in @($cfg.services.PSObject.Properties)) {
      $s = $sp.Value
      $decl = $(if ($Manifest -and $Manifest.services.PSObject.Properties[$sp.Name]) { Get-ServiceDeclaredLifecycle $Manifest.services.PSObject.Properties[$sp.Name].Value } else { [ordered]@{ role = ''; lifecycle = '' } })
      $nets = @(); $n = Get-Prop2 $s 'networks' $null; if ($n) { $nets = @($n.PSObject.Properties | ForEach-Object { $k = $_.Name; $def = Get-Prop2 $cfg.networks $k $null; $nm = [string](Get-Prop2 $def 'name' ''); if ($nm) { $nm } else { "$($App.project)_$k" } }) }
      [ordered]@{ name = $sp.Name; container = [string](Get-Prop2 $s 'container_name' "$($App.project)-$($sp.Name)-1"); role = $decl.role; lifecycle = $decl.lifecycle; image = [string](Get-Prop2 $s 'image' '')
        networks = $nets; volumes = @(@(Get-Prop2 $s 'volumes' @()) | ForEach-Object { [ordered]@{ type = [string]$_.type; name = $(if ($_.type -eq 'volume') { $vd = Get-Prop2 $cfg.volumes ([string]$_.source) $null; $vn = [string](Get-Prop2 $vd 'name' ''); if ($vn) { $vn } else { "$($App.project)_$($_.source)" } } else { '' }); source = $(if ($_.type -eq 'bind') { [string]$_.source } else { '' }); target = [string]$_.target } })
        ports = @(@(Get-Prop2 $s 'ports' @()) | ForEach-Object { [ordered]@{ container = [int]$_.target; published = $(if ($_.PSObject.Properties['published'] -and $_.published) { "$(Get-Prop2 $_ 'host_ip' '0.0.0.0'):$($_.published)" } else { '' }) } })
        dependsOn = @($(if ($s.PSObject.Properties['depends_on'] -and $s.depends_on) { $s.depends_on.PSObject.Properties | ForEach-Object { [ordered]@{ service = $_.Name; condition = [string](Get-Prop2 $_.Value 'condition' 'service_started') } } }))
        healthcheck = [bool]($s.PSObject.Properties['healthcheck'] -and $s.healthcheck); environment = @($(if ($s.PSObject.Properties['environment'] -and $s.environment) { $s.environment.PSObject.Properties | ForEach-Object { $_.Name } })) }
    })
  return [ordered]@{ schema = 1; kind = 'dtc-stack'; derived = $true; project = $App.project; origin = [string](Get-Prop2 $App 'origin' 'installed')
    application = [ordered]@{ id = [string]$App.appId; name = [string]$App.name; publisher = [string](Get-Prop2 $Manifest 'maintainer' ''); source = [string](Get-Prop2 (Get-Prop2 $Manifest 'source' $null) 'url' '') }
    composeFiles = @(Get-AppComposeFileNames $App | ForEach-Object { [ordered]@{ file = $_; component = $(if ($_ -eq 'compose.yaml') { 'app' } else { ($_ -replace '^compose\.|\.yaml$', '') }); services = @() } })
    services = $svcs; startOrder = @(Get-StackStartOrder $svcs)
    dependencies = @($svcs | Where-Object { $_.role -in 'database', 'cache', 'messaging', 'support' } | ForEach-Object { [ordered]@{ service = $_.name; role = $_.role; image = $_.image } })
    networks = [ordered]@{ shared = @(@($svcs | ForEach-Object { $_.networks }) | Where-Object { $_ -eq $Settings.ProxyNetwork } | Select-Object -Unique); private = @(@($svcs | ForEach-Object { $_.networks }) | Where-Object { $_ -ne $Settings.ProxyNetwork } | Select-Object -Unique) }
    routing = [ordered]@{ owner = 'deployment-manager'; provider = 'traefik-file'; dockerLabels = $false }
    authentication = $(if ($Manifest) { Get-Prop2 $Manifest 'authentication' $null } else { $null }) }
}

# One app's stack, routing and diagnostics: its Compose files (no .env values), the stack description, every route
# that points at it split into routers / services / middlewares, whether the file provider actually loads those files
# and Traefik serves them, its health, and findings with what to do about them. Read-only.
function Get-AppStackData([string]$Project) {
  Assert-Installed
  $settings = Get-Settings
  $a = Find-InstalledApp $Project
  $m = $null; try { $m = Get-InstanceManifest $a } catch { }
  $findings = New-Object System.Collections.ArrayList
  $find = { param($level, $message, $fix) $null = $findings.Add([ordered]@{ level = $level; message = $message; fix = $fix }) }
  $files = @(foreach ($f in (Get-AppComposeFiles $a)) {
      $exists = Test-Path -LiteralPath $f
      if (-not $exists) { & $find 'error' "$(Split-Path -Leaf $f) is missing from $($a.folder)." 'Restore it from a backup (Back up / Restore), or remove and reinstall the app.' }
      [ordered]@{ file = (Split-Path -Leaf $f); exists = $exists; content = $(if ($exists) { [IO.File]::ReadAllText($f) } else { '' }) }
    })
  $stackPath = Join-Path $a.folder 'dtc-stack.json'
  $stack = $null; $source = 'none'
  if (Test-Path -LiteralPath $stackPath) { try { $stack = [IO.File]::ReadAllText($stackPath) | ConvertFrom-Json; $source = 'file' } catch { & $find 'warning' 'dtc-stack.json is not valid JSON.' 'Write it again with "Describe this stack".' } }
  if (-not $stack) { $stack = Get-DerivedAppStack $a $m $settings; if ($stack) { $source = 'derived' } }
  $fp = Get-AppComposeFingerprint $a
  $changed = $(if ($a.PSObject.Properties['composeSha256'] -and $a.composeSha256 -and $fp) { $fp -ne $a.composeSha256 } else { $null })
  if ($changed) { & $find 'warning' 'The Compose files were changed outside the manager since they were written here.' 'Review the change; updates keep it but change image lines only.' }
  # Routes: explicit file-provider definitions in traefik\dynamic (the directory Traefik loads; it does not look into
  # sub-folders), and whether Traefik serves their routers.
  $dynDir = Join-Path $settings.InstallPath 'traefik\dynamic'
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $inst = @(Get-InstalledInstances $settings $catalog @(Get-ComposeContainerFacts) | Where-Object { $_.project -eq $a.project })[0]
  $routers = $null; try { $routers = Get-TraefikApi $settings '/api/http/routers' } catch { }
  $routes = @(foreach ($rt in @($inst.routes)) {
      $fileName = Get-ServiceFileName $rt.name
      $path = Join-Path $dynDir $fileName
      $exists = Test-Path -LiteralPath $path
      $parts = $(if ($exists) { Split-TraefikRouteYaml ([IO.File]::ReadAllText($path)) } else { [ordered]@{ routers = @(); services = @(); middlewares = @() } })
      $served = @(foreach ($r in $parts.routers) { $live = $(if ($null -ne $routers) { @($routers | Where-Object { $_.name -eq "$($r.name)@file" })[0] } else { $null }); [ordered]@{ router = $r.name; served = [bool]$live; status = $(if ($live) { [string](Get-Prop2 $live 'status' '') } elseif ($null -eq $routers) { 'unknown' } else { 'missing' }) } })
      if (-not $exists) { & $find 'error' "Route '$($rt.name)': $fileName is missing from traefik\dynamic." 'Apply the service plan again on the Services page (it regenerates the file).' }
      elseif ($null -ne $routers -and @($served | Where-Object { -not $_.served }).Count) { & $find 'error' "Route '$($rt.name)': Traefik does not serve $(@($served | Where-Object { -not $_.served } | ForEach-Object { $_.router }) -join ', ')." 'Open the Traefik dashboard for configuration errors; the Services page validates and re-applies the route.' }
      [ordered]@{ name = $rt.name; hostnames = @($rt.hostnames); publish = $rt.publish; authProvider = $rt.authProvider; file = "traefik\dynamic\$fileName"; exists = $exists
        loadedByFileProvider = [bool]($exists -and $fileName -match '\.ya?ml$'); routers = $parts.routers; services = $parts.services; middlewares = $parts.middlewares; traefik = $served }
    })
  $health = $null
  if ($m) { try { $health = Get-AppHealth $a.project $m $settings 0 } catch { } }
  $lc = $inst.lifecycle
  if ($a.PSObject.Properties['prepared'] -and $a.prepared -and -not @(Get-ComposeProjectContainers $a.project).Count) { & $find 'info' 'Prepared, not started: nothing has been downloaded or started yet.' 'Press Start when there is enough memory; it checks again first.' }
  elseif ($health -and -not $health.running) { & $find 'error' "The web service $($health.web) is not running." 'Start or restart the app; read its logs (Logs) for the reason.' }
  elseif ($health -and $health.http -and $health.http.result -notin 'http', 'https', 'not-applicable') { & $find 'warning' "The web interface did not answer on the shared network: $($health.http.detail)" 'Wait for the first start to finish (some apps migrate their database first), then check the logs.' }
  foreach ($s in @(Get-Prop2 $lc 'services' @())) {
    $st = [string](Get-Prop2 (Get-Prop2 $s 'status' $null) 'key' '')
    if ($st -in 'job-failed', 'stopped-unexpectedly', 'unhealthy', 'restarting') { & $find 'error' "$($s.name): $([string](Get-Prop2 $s.status 'label' $st))." "Read the logs of $($s.name) (Logs, choose the service)." }
  }
  # A database, cache or broker attached to the shared proxy network is reachable by every other app on it.
  $facts = @(Get-ComposeContainerFacts | Where-Object { $_.project -eq $a.project })
  foreach ($c in $facts) {
    $role = $(if ($m -and $m.services.PSObject.Properties[[string]$c.service]) { [string](Get-Prop2 $m.services.PSObject.Properties[[string]$c.service].Value 'role' '') } else { '' })
    if ($role -in 'database', 'cache', 'messaging' -and @($c.networks | Where-Object { $_.name -eq $settings.ProxyNetwork }).Count) { & $find 'warning' "$($c.name) ($role) is on the shared proxy network '$($settings.ProxyNetwork)'." 'Only web front ends belong there; recreate the app with its generated Compose files.' }
  }
  if (-not $findings.Count) { & $find 'ok' 'No problems found.' '' }
  return [ordered]@{ project = $a.project; name = $a.name; folder = $a.folder; composeFiles = $files; stack = $stack; stackSource = $source; composeChanged = $changed
    env = [ordered]@{ file = '.env'; variables = @((Read-AppEnv (Join-Path $a.folder '.env')).Keys); note = 'Names only; values are never shown here.' }
    routing = [ordered]@{ directory = 'traefik\dynamic'; recursive = $false; dockerProvider = 'not used for apps (no traefik.* labels are generated)'; routes = $routes; traefikReachable = ($null -ne $routers) }
    health = $health; lifecycle = $lc; findings = $findings.ToArray(); backups = @(Get-AppBackupList $a | Select-Object -First 10); checkedAt = (Get-Date -Format 's') }
}

# Writes dtc-stack.json for an installation that has none (installed by an earlier version, or adopted), derived from
# its own Compose files. Nothing else in the folder changes: existing installations are described, never moved.
function Invoke-AppStackDescribe($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $a = Find-InstalledApp ([string](Get-Field $Body 'project' ''))
  $p = Join-Path $a.folder 'dtc-stack.json'
  if (Test-Path -LiteralPath $p) { Stop-Request 409 "$($a.project) already has dtc-stack.json." }
  $m = $null; try { $m = Get-InstanceManifest $a } catch { }
  $stack = Get-DerivedAppStack $a $m $settings
  if (-not $stack) { Stop-Request 409 'docker compose could not read the project; nothing was written.' }
  $stack.generatedAt = (Get-Date -Format 's')
  [IO.File]::WriteAllText($p, (($stack | ConvertTo-Json -Depth 12) + "`n"), (New-Object Text.UTF8Encoding($false)))
  $records = @(Read-AppsRegistry $settings)
  foreach ($rec in @($records | Where-Object { $_.project -eq $a.project })) { $rec | Add-Member -NotePropertyName stackFile -NotePropertyValue 'dtc-stack.json' -Force }
  Save-AppsRegistry $settings $records
  Write-Audit 'app-stack-describe' "$($a.project) (dtc-stack.json written; nothing else changed)"
  return [ordered]@{ ok = $true; project = $a.project; file = $p; unchanged = @('Compose files', '.env', 'containers', 'volumes', 'networks', 'routes') }
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

# --- Authentication & Routing (read-only) -------------------------------------------------------------------------------
# Facts about one service for lib\RoutingModel.psm1. Without -Probe only configuration is read: route files, Docker,
# Traefik's API and GET requests to the authentik and Cloudflare APIs. -Probe adds real requests: one anonymous GET
# through Traefik (no cookies, never follows a sign-in), the backend from Traefik's container, and GETs to the public
# addresses through Cloudflare. Nothing is changed and no credential is sent to an application.
function Get-RouteFileFacts([string]$Path, [string]$Name) {
  $f = [ordered]@{ fileExists = $false; rule = ''; entryPoints = @(); middlewares = @(); forwardAuthAddress = ''; outpostRouter = $false; backendUrl = '' }
  if (-not (Test-Path -LiteralPath $Path)) { return $f }
  $f.fileExists = $true
  $lines = [IO.File]::ReadAllLines($Path)
  $section = ''; $block = ''
  foreach ($l in $lines) {
    if ($l -match '^  (routers|middlewares|services):\s*$') { $section = $Matches[1]; $block = ''; continue }
    if ($l -match '^    ([A-Za-z0-9@._-]+):\s*$') { $block = $Matches[1]; continue }
    if ($section -eq 'routers' -and $block -eq "svc-$Name") {
      if ($l -match "^\s+rule:\s*'(.*)'\s*$") { $f.rule = $Matches[1].Replace("''", "'") }
      elseif ($l -match '^\s+entryPoints:\s*\[(.*)\]') { $f.entryPoints = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
      elseif ($l -match '^\s+middlewares:\s*\[(.*)\]') { $f.middlewares = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    }
    if ($section -eq 'routers' -and $block -eq "svc-$Name-outpost") { $f.outpostRouter = $true }
    if ($section -eq 'middlewares' -and $block -eq "svc-$Name-authentik" -and $l -match '^\s+address:\s*(\S+)') { $f.forwardAuthAddress = $Matches[1] }
    if ($section -eq 'services' -and $block -eq "svc-$Name" -and $l -match '^\s+-\s*url:\s*(\S+)' -and -not $f.backendUrl) { $f.backendUrl = $Matches[1] }
  }
  return $f
}

function Get-ContainerNetworkNames([string]$Container) {
  if (-not $Container) { return @() }
  $r = Invoke-Docker inspect $Container --format '{{json .NetworkSettings.Networks}}'
  if ($r.ExitCode -ne 0) { return @() }
  try { return @(((@($r.Output) -join '') | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $_.Name }) } catch { return @() }
}

function Get-RoutingFacts($Settings, $Svc, [switch]$Probe) {
  $cfg = Read-IdentityConfig -Settings $Settings
  $h = [string]@($Svc.hostnames)[0]
  $authP = $(if ($Svc.PSObject.Properties['auth'] -and $Svc.auth -and $Svc.auth.PSObject.Properties['provider']) { [string]$Svc.auth.provider } else { '' })
  $route = Get-RouteFileFacts (Join-Path $InstallPath "traefik\dynamic\svc-$($Svc.name).yml") $Svc.name
  $routers = $null
  $tr = Get-TraefikApi $Settings '/api/http/routers'
  if ($null -ne $tr) { $routers = @{}; foreach ($r in $tr) { if ($r -and $r.name -like "svc-$($Svc.name)*") { $routers[[string]$r.name] = [string]$r.status } } }
  $server = [string]$cfg.authentik.serverContainer
  $akNets = @(Get-ContainerNetworkNames $server)
  $identity = [ordered]@{ publicUrl = [string]$cfg.authentik.publicUrl; authHostname = [string]$cfg.authentik.hostname; serverContainer = $(if ($server) { $server } else { 'authentik-server' })
    onProxyNetwork = $(if ($server) { $akNets -contains $Settings.ProxyNetwork } else { $true }); googleConfigured = [bool]$cfg.authentik.google.clientId
    appVerifiedAt = [string](Get-IdProp2 (Get-IdentityApp $cfg $Svc.name) 'verifiedAt' '') }

  # authentik objects (GET only), when the manager is connected.
  $ak = $null
  if ($authP -eq 'authentik') {
    $ak = [ordered]@{ connected = $false; error = '' }
    $base = [string]$cfg.authentik.localUrl
    if ($base) {
      try {
        $credArgs = Get-IdentityCredentialArgs $Settings $base
        $cred = Test-StoredCredential @credArgs -IfOlderThanMinutes 2
        if ($cred.ok) {
          $conn = New-AuthentikConnection -BaseUrl $base -Token (Read-ProtectedSecret -Settings $Settings -Name (Get-IdentityTokenSecretName))
          $slug = "dm-$($Svc.name)"
          $out = @(Get-AuthentikList $conn '/outposts/instances/' | Where-Object { [string](Get-IdProp2 $_ 'managed' '') -eq 'goauthentik.io/outposts/embedded' })[0]
          $prov = @(Get-AuthentikList $conn "/providers/proxy/?name=$([Uri]::EscapeDataString($slug))" | Where-Object { [string]$_.name -eq $slug })[0]
          $app = $null; try { $app = Invoke-AuthentikApi $conn GET "/core/applications/$slug/" } catch { }
          $rules = $null; if ($app) { try { $rules = @(Get-AuthentikList $conn "/policies/bindings/?target=$([string](Get-IdProp2 $app 'pbm_uuid' $app.pk))").Count } catch { } }
          $ak = [ordered]@{ connected = $true; error = ''; outpostName = [string](Get-IdProp2 $out 'name' '')
            outpostHost = [string](Get-IdProp2 (Get-IdProp2 $out 'config' $null) 'authentik_host' ''); outpostBrowserHost = [string](Get-IdProp2 (Get-IdProp2 $out 'config' $null) 'authentik_host_browser' '')
            providerFound = [bool]$prov; providerExternalHost = [string](Get-IdProp2 $prov 'external_host' ''); providerMode = [string](Get-IdProp2 $prov 'mode' '')
            providerAssigned = [bool]($prov -and $out -and @($out.providers | ForEach-Object { [int]$_ }) -contains [int]$prov.pk); applicationFound = [bool]$app; rules = $rules }
        } else { $ak.error = [string]$cred.message }
      } catch { $ak.error = $_.Exception.Message }
    } else { $ak.error = 'authentik is not set up in the manager.' }
  }

  # Cloudflare (configuration only here; the health checks below read the API).
  $cf = Read-CloudflareConfig -Settings $Settings
  $accId = [string](Get-ManagedResource $cf $h 'accessAppId')
  $accName = ''
  if ($accId -and -not $Svc.cloudflare.access) {
    try { $a = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($cf.accountId)/access/apps/$accId"; $accName = [string]$a.name } catch { if ((Get-CfErrorStatus $_) -ne 404) { $accName = "(id $accId)" } }
  }
  $backendNets = $null
  if ($Svc.target.type -eq 'docker') { $backendNets = @(Get-ContainerNetworkNames $Svc.target.host) }

  $facts = [ordered]@{
    service = [ordered]@{ name = $Svc.name; displayName = $(if ($Svc.PSObject.Properties['displayName'] -and $Svc.displayName) { $Svc.displayName } else { $Svc.name }); hostname = $h; enabled = [bool]$Svc.enabled
      publish = [bool]$Svc.cloudflare.publish; access = [bool]$Svc.cloudflare.access; authProvider = $authP; targetUrl = (Get-ServiceUrl $Svc); targetType = [string]$Svc.target.type; targetHost = [string]$Svc.target.host }
    route = $route; traefik = [ordered]@{ apiOk = ($null -ne $routers); routers = $routers }; identity = $identity; authentik = $ak
    cloudflare = [ordered]@{ connected = [bool]$cf.tunnelId; tunnelName = [string]$cf.tunnelName; accessAppName = $accName; accessAppByDtc = [bool]$accName }
    networks = [ordered]@{ proxy = $Settings.ProxyNetwork; traefik = @(Get-ContainerNetworkNames "$($Settings.StackName)-traefik"); authentik = $akNets; backend = $backendNets }
    health = $null; challenge = $null; publicAuth = $null; checkedAt = (Get-Date -Format 's')
  }
  if ($Probe) {
    $facts.health = Get-ServiceHealth -Settings $Settings -Service $Svc -Public:([bool]$Svc.cloudflare.publish)
    if ($authP -eq 'authentik' -and $Svc.enabled) { $facts.challenge = Test-ForwardAuthChallenge -TraefikPort $Settings.HttpPort -Hostname $h -HostPort (Get-IdentityAppAddress ([string]$cfg.authentik.publicUrl) $h).HostPort -AuthHostname ([string]$cfg.authentik.hostname) }
    if ($authP -eq 'authentik' -and $cfg.authentik.publicUrl) {
      $pr = Invoke-ProbeRequest "$(([string]$cfg.authentik.publicUrl).TrimEnd('/'))/-/health/live/"
      $facts.publicAuth = [ordered]@{ status = $pr.Status; location = (Get-RedactedUrl $pr.Location); error = $pr.Error }
    }
  }
  return $facts
}

# GET /api/routing[?service=<name>][&probe=1]: the applications that can be shown and the request path of one of them.
function Get-RoutingView($Query) {
  Assert-Installed
  $settings = Get-Settings
  $all = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_ -and @($_.hostnames).Count })
  $list = @($all | ForEach-Object { [ordered]@{ name = $_.name; displayName = $(if ($_.PSObject.Properties['displayName'] -and $_.displayName) { $_.displayName } else { $_.name }); hostname = [string]@($_.hostnames)[0]
        protected = [bool]($_.PSObject.Properties['auth'] -and $_.auth -and [string]$_.auth.provider -eq 'authentik'); publish = [bool]$_.cloudflare.publish; enabled = [bool]$_.enabled } })
  $want = [string]$Query['service']
  $svc = $(if ($want) { @($all | Where-Object { $_.name -eq $want.ToLowerInvariant() })[0] } else { $null })
  if ($want -and -not $svc) { Stop-Request 404 "No service named '$want'." }
  if (-not $svc) { $svc = @($all | Where-Object { $_.PSObject.Properties['auth'] -and $_.auth -and [string]$_.auth.provider -eq 'authentik' })[0] }
  if (-not $svc) { $svc = @($all)[0] }
  $model = $null
  if ($svc) { $model = Get-RoutingModel -Facts (Get-RoutingFacts $settings $svc -Probe:([string]$Query['probe'] -eq '1')) }
  return [ordered]@{ mode = 'guided'; services = $list; selected = $(if ($svc) { $svc.name } else { '' }); model = $model }
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
    identity = (Get-IdentityExplorerFacts $settings)
  }
  $facts = Get-InfrastructureFacts -Settings $settings -Base $base
  $model = ConvertTo-InfrastructureModel -Facts $facts
  $model.instance = [ordered]@{ stackName = $settings.StackName; installPath = $InstallPath; httpPort = $settings.HttpPort; dashboardPort = $settings.DashboardPort; proxyNetwork = $settings.ProxyNetwork; tunnelNetwork = $settings.TunnelNetwork }
  $model.dashboard = [ordered]@{ localUrl = "http://127.0.0.1:$($settings.DashboardPort)/dashboard/"; publicUrl = $(if ($dash.enabled -and $dash.hostname) { "https://$($dash.hostname)/dashboard/" } else { '' }) }
  $model.checkedAt = (Get-Date -Format 's')
  return $model
}

# Identity facts for the Explorer: local only (identity.json and one docker inspect), no authentik API call.
function Get-IdentityExplorerFacts($Settings) {
  if (-not (Test-Installed)) { return $null }
  try { $cfg = Read-IdentityConfig -Settings $Settings } catch { return $null }
  $srv = $null
  if ($cfg.authentik.serverContainer) {
    $r = Invoke-Docker inspect $cfg.authentik.serverContainer --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{json .NetworkSettings.Networks}}'
    if ($r.ExitCode -eq 0) {
      $parts = (@($r.Output) -join '').Split([char[]]'|', 3)
      $nets = $parts[2] | ConvertFrom-Json
      $srv = [ordered]@{ name = $cfg.authentik.serverContainer; state = $parts[0]; health = $parts[1]; onProxyNetwork = [bool]$nets.PSObject.Properties[$Settings.ProxyNetwork] }
    }
  }
  $verified = @($cfg.authentik.apps.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties['verifiedAt'] -and $_.Value.verifiedAt } | ForEach-Object { $_.Name })
  return [ordered]@{ provider = $cfg.provider; hostname = $cfg.authentik.hostname; server = $srv; verified = $verified; googleVerified = [bool]$cfg.authentik.google.verifiedAt }
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

# --- Launcher: remembered browsers, start mode, default deployment, Start with Windows -------------------------------------
# Remembered browsers (-SessionFile): only SHA-256 hashes of session cookies and their expiry are stored, in a file readable
# by this Windows user only, so a copy of the file signs nobody in. Launcher settings (lib\Launcher.psm1) hold no secret.
# Changing the default deployment only records a folder: nothing in Docker, in the deployment or in Cloudflare changes.

function Read-RememberedSessions {
  $State.Remembered.Clear()
  if (-not $SessionFile -or -not (Test-Path -LiteralPath $SessionFile)) { return }
  try {
    $j = [IO.File]::ReadAllText($SessionFile) | ConvertFrom-Json
    $now = Get-Date
    foreach ($e in @(Get-Field $j 'sessions' @())) {
      if (-not $e -or -not $e.PSObject.Properties['hash'] -or -not $e.PSObject.Properties['expires']) { continue }
      $exp = [datetime]::MinValue
      $ok = [datetime]::TryParseExact([string]$e.expires, 's', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$exp)
      if ($ok -and [string]$e.hash -match '^[0-9A-F]{64}$' -and $exp -gt $now) { $State.Remembered[([string]$e.hash).ToUpperInvariant()] = $exp }
    }
  } catch { }
}

function Save-RememberedSessions {
  if (-not $SessionFile) { return }
  $now = Get-Date
  $list = @($State.Remembered.Keys | Where-Object { $State.Remembered[$_] -gt $now } | Sort-Object | ForEach-Object { [ordered]@{ hash = $_; expires = $State.Remembered[$_].ToString('s', [Globalization.CultureInfo]::InvariantCulture) } })
  $dir = Split-Path -Parent $SessionFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = "$SessionFile.tmp-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  [IO.File]::WriteAllText($tmp, (ConvertTo-Json -Depth 3 -InputObject ([ordered]@{ schema = 1; sessions = $list })) + "`n")
  Set-SecretFileAcl $tmp
  Move-Item -LiteralPath $tmp -Destination $SessionFile -Force
}

# The session for a cookie: an in-memory one, else a remembered browser (gets a new CSRF token after a restart).
function Get-RequestSession([string]$Sid) {
  if (-not $Sid) { return $null }
  if ($State.Sessions.ContainsKey($Sid)) { return $State.Sessions[$Sid] }
  if (-not $SessionFile -or $Sid -notmatch '^[A-Za-z0-9_-]{20,64}$') { return $null }
  $hash = Get-TextSha256 $Sid
  if ($State.Remembered.ContainsKey($hash) -and $State.Remembered[$hash] -gt (Get-Date)) {
    $State.Sessions[$Sid] = [pscustomobject]@{ Csrf = (New-RandomKey); Created = (Get-Date) }
    return $State.Sessions[$Sid]
  }
  return $null
}

function Assert-Launcher {
  if (-not $LauncherStateDir) { Stop-Request 409 'Startup settings need the launcher: start the manager with the DTC shortcut, Start-DeploymentManager.ps1 or START-HERE.cmd (not webui.ps1 directly).' }
}

function Get-LauncherData {
  if (-not $LauncherStateDir) { return [ordered]@{ available = $false; startMode = $StartMode } }
  $s = Read-LauncherSettings -StateDir $LauncherStateDir -ProgramPath $here
  $d = Get-LauncherDeployment ([string]$s.defaultDeployment)
  return [ordered]@{
    available = $true; startMode = $StartMode; notice = [string]$StartNotice; edition = $s.edition; programPath = $here; problem = $s.problem
    defaultDeployment = [ordered]@{ path = $s.defaultDeployment; stackName = $(if ($d.stackName) { $d.stackName } else { $s.defaultStackName }); kind = $d.kind; usable = $d.usable }
    openBrowserOnManualLaunch = $s.openBrowserOnManualLaunch; dockerWaitSeconds = $s.dockerWaitSeconds
    preferredPort = $s.port; port = $Port; bookmarkUrl = "http://127.0.0.1:$Port/"; rememberBrowser = [bool]$SessionFile; rememberDays = $RememberDays
    autostart = (Get-LauncherAutostart -ProgramPath $here -StartupDir $StartupDir); launcherBuilt = (Test-Path -LiteralPath (Get-LauncherExePath $here))
    appName = (Get-LauncherAppName $s.edition); logDir = (Get-LauncherFiles $LauncherStateDir).LogDir
  }
}

function Set-LauncherSettingsRequest($Body) {
  Assert-Launcher
  $s = Read-LauncherSettings -StateDir $LauncherStateDir -ProgramPath $here
  $changes = New-Object System.Collections.ArrayList
  $flag = {
    param($Name)
    $v = $Body.$Name
    if ($v -isnot [bool]) { Stop-Request 400 "$Name must be true or false." }
    return $v
  }
  if ($Body.PSObject.Properties['defaultDeployment']) {
    $path = [string]$Body.defaultDeployment
    if ($path) {
      try { $path = ConvertTo-ProjectPath $path } catch { Stop-Request 400 $_.Exception.Message }
      $d = Get-LauncherDeployment $path
      if (-not $d.usable) { Stop-Request 409 "$path is not an installed deployment of this tool, so it cannot be the default. Finish its setup first, or choose another folder." }
      $s.defaultDeployment = $path; $s.defaultStackName = $d.stackName
      $null = $changes.Add("default deployment $path ($($d.stackName))")
    } else { $s.defaultDeployment = ''; $s.defaultStackName = ''; $null = $changes.Add('default deployment cleared') }
  }
  if ($Body.PSObject.Properties['openBrowserOnManualLaunch']) { $s.openBrowserOnManualLaunch = & $flag 'openBrowserOnManualLaunch'; $null = $changes.Add("open browser on manual launch: $($s.openBrowserOnManualLaunch)") }
  if ($Body.PSObject.Properties['dockerWaitSeconds']) {
    $w = [string]$Body.dockerWaitSeconds
    if ($w -notmatch '^\d{1,4}$' -or [int]$w -gt 1800) { Stop-Request 400 'dockerWaitSeconds must be between 0 and 1800.' }
    $s.dockerWaitSeconds = [int]$w; $null = $changes.Add("wait for Docker Desktop: $w s")
  }
  if ($Body.PSObject.Properties['autostart']) {
    $want = & $flag 'autostart'
    if ($want -and -not (Test-Path -LiteralPath (Get-LauncherExePath $here))) {
      try { $null = New-LauncherExe -ProgramPath $here } catch { Write-LauncherLog -StateDir $LauncherStateDir -Source 'website' -Level 'WARN' -Message "The windowless launcher could not be built; autostart uses powershell.exe hidden instead. $($_.Exception.Message)" }
    }
    try { $null = Set-LauncherAutostart -ProgramPath $here -Enabled $want -StartupDir $StartupDir } catch { Stop-Request 500 "Start with Windows could not be changed: $($_.Exception.Message)" }
    $s.autostart = $want; $null = $changes.Add("start with Windows: $want")
  }
  Save-LauncherSettings $LauncherStateDir $s
  Write-LauncherLog -StateDir $LauncherStateDir -Source 'website' -Message ('Settings changed: ' + (@($changes) -join '; '))
  return Get-LauncherData
}

function Invoke-ManagerStop($Body) {
  Assert-Confirmed $Body
  if (-not $StopFile) { Stop-Request 409 'This manager was started without a stop file. Close its PowerShell window (or press Ctrl+C there) to stop it.' }
  [IO.File]::WriteAllText($StopFile, 'stop')
  return [ordered]@{ stopping = $true }
}

# --- Identity & Access (authentik) ---------------------------------------------------------------------------------
# Thin request handlers over lib\IdentityProvider.psm1 (state, model) and lib\Authentik.psm1 (API, sync). Every change
# in authentik is previewed first (the sync functions' dry run), applied once after confirmation, and recomputed right
# before applying; the Traefik side goes through the same plan/validate/backup/apply path as every service change.

# --- Application launcher, authentication diagnostics and redundant Cloudflare Access cleanup ------------------------
# Read-only facts for every application on the Identity & Access page (lib\AccessDiagnostics.psm1 turns them into one
# diagnosis each). Cloudflare Access applications are listed at most every two minutes (immediately on "Run checks").

function Get-IdentityAccessApps($Settings, $Cloudflare, [switch]$Refresh) {
  $c = $State.AccessApps
  if (-not $Refresh -and $c -and ((Get-Date) - $c.At).TotalSeconds -lt 120) { return $c }
  $r = [pscustomobject]@{ At = (Get-Date); Ok = $false; Apps = @(); Error = '' }
  if (-not $Cloudflare.accountId -or -not (Get-CloudflareApiTokenInfo -Settings $Settings).Stored) { $r.Error = 'Cloudflare automation is not connected, so Cloudflare Access was not checked.' }
  else {
    try { $r.Apps = @(Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($Cloudflare.accountId)/access/apps" -All); $r.Ok = $true }
    catch { $r.Error = $(if ($_.Exception.Data['cfStatus'] -in 401, 403) { 'The Cloudflare API token cannot read Access applications, so a Cloudflare login in front of an application cannot be detected.' } else { $_.Exception.Message }) }
  }
  $State.AccessApps = $r
  return $r
}

function Get-IdentityLauncher {
  param($Settings, $Config, $Services, $Inventory, $Routers, $AppFacts, $Cloudflare, $Install, [switch]$Refresh)
  $acc = Get-IdentityAccessApps $Settings $Cloudflare -Refresh:$Refresh
  $bb = Get-AuthentikBrowserBase ([string]$Config.authentik.publicUrl) ([string]$Config.authentik.localUrl)
  $out = @()
  foreach ($s in @($Services)) {
    if ($Install -and $s.target.type -eq 'docker' -and $s.target.host -eq $Install.serverContainer) { continue }
    if ($Config.authentik.service -and $s.name -eq $Config.authentik.service) { continue }
    $h = [string]@($s.hostnames)[0]
    $fact = @($AppFacts | Where-Object { $_.service -eq $s.name })[0]
    $mode = Get-ServiceAuthMode $s
    $ctr = [ordered]@{ name = ''; state = 'host' }
    if ($s.target.type -eq 'docker') {
      $c = @($Inventory | Where-Object { $_.name -eq $s.target.host })[0]
      $ctr.name = [string]$s.target.host
      $ctr.state = $(if ($c) { [string]$c.state } elseif (@($Inventory).Count) { 'missing' } else { 'unknown' })
    }
    $rt = $(if ($null -eq $Routers) { $null } else { @($Routers | Where-Object { $null -ne $_ -and $_.name -eq "svc-$($s.name)@file" })[0] })
    $router = $(if ($null -eq $Routers) { 'unknown' } elseif (-not $s.enabled) { 'off' } elseif ($rt) { [string]$rt.status } else { 'missing' })
    $managedId = $(if ($h) { Get-ManagedResource $Cloudflare $h 'accessAppId' } else { '' })
    $coverage = $null
    if ($acc.Ok -and $h) { $coverage = @(Get-AccessCoverage -Apps $acc.Apps -Hostname $h -ManagedAppId $managedId) }
    $facts = @{ hostname = $h; enabled = [bool]$s.enabled; publish = [bool]$s.cloudflare.publish; authMode = $mode; container = $ctr.state; router = $router }
    if ($null -ne $coverage) { $facts.accessCoverage = $coverage }
    if ($fact) {
      $facts.forwardAuthConfigured = [bool]$fact.forwardAuth.configured
      if ($null -ne $fact.forwardAuth.loaded) { $facts.forwardAuthLoaded = [bool]$fact.forwardAuth.loaded }
      if ($fact.authentikChecked) { $facts.authentikApp = [bool]$fact.authentik }
      $ext = [string]$fact.provider.externalHost
      if ($ext) {
        $u = $null
        $facts.providerExternalHost = $ext; $facts.providerMode = [string]$fact.provider.mode
        $facts.expectedExternalHost = $(if ([Uri]::TryCreate($ext, [UriKind]::Absolute, [ref]$u) -and $u.Host -eq $h) { $ext } else { "https://$h" })
      }
      if ($null -ne $fact.provider.onOutpost) { $facts.outpostAssigned = [bool]$fact.provider.onOutpost }
      if ($fact.challenge) { $facts.challenge = [string]$fact.challenge.State }
    }
    # Windows-host targets: when nothing on this PC listens on the target port, Traefik's connection is refused for
    # certain, so the row says so instead of "Healthy" (LAN targets are not probed here; Run checks does that).
    if ($s.target.type -eq 'host' -and [string]$s.target.host -in @('host.docker.internal', 'gateway.docker.internal', 'localhost', '127.0.0.1') -and [int]$s.target.port -gt 0) {
      $listening = $null
      try { $listening = @(Get-NetTCPConnection -LocalPort ([int]$s.target.port) -State Listen -ErrorAction Stop).Count -gt 0 } catch { if ([string]$_.CategoryInfo.Category -eq 'ObjectNotFound') { $listening = $false } }
      if ($null -ne $listening) { $ctr.listening = $listening; if (-not $listening) { $facts.backend = 'unreachable' } }
    }
    $diag = Get-AppAccessDiagnosis $facts
    $slug = $(if ($fact) { [string]$fact.slug } else { "dm-$($s.name)" })
    $protected = ($mode -in @('authentik', 'layered', 'layered-unconfirmed'))
    $out += [ordered]@{
      service = $s.name; displayName = $(if ($s.PSObject.Properties['displayName'] -and $s.displayName) { $s.displayName } else { $s.name }); hostname = $h
      openUrl = (Get-ServiceOpenUrl $s ([int]$Settings.HttpPort)); publish = [bool]$s.cloudflare.publish; enabled = [bool]$s.enabled
      authentikUrl = $(if ($protected -and $bb.Base) { "$($bb.Base)/if/admin/#/core/applications/$slug" } else { '' }); authentikUrlPublic = [bool]$bb.Public
      container = $ctr; router = $router; target = (Get-ServiceUrl $s); authMode = $mode; authModeLabel = (Get-AuthModeLabel $mode)
      access = [ordered]@{ checked = [bool]$acc.Ok; error = $(if ($acc.Ok) { '' } else { [string]$acc.Error }); managedAppId = $managedId
        apps = @(@($coverage) | Where-Object { $_ } | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; pattern = $_.Pattern; wildcard = $_.Wildcard; pathOnly = $_.PathOnly; createdByTool = $_.CreatedByTool } }) }
      diagnosis = $diag
    }
  }
  return $out
}

# One request without following redirects, cookies or credentials; only status, Location and a few response headers.
function Invoke-TraceHop([string]$Url, [string]$HostHeader = '') {
  $r = [ordered]@{ status = 0; location = ''; headers = @{}; error = '' }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'; $req.AllowAutoRedirect = $false; $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
    $req.UserAgent = 'DTC-identity-trace/1 (read-only)'
    if (([Uri]$Url).IsLoopback) { $req.Proxy = $null }
    if ($HostHeader) { $req.Host = $HostHeader }
    $resp = $null
    try { $resp = $req.GetResponse() } catch [System.Net.WebException] { if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw } }
    $r.status = [int]$resp.StatusCode; $r.location = [string]$resp.Headers['Location']
    foreach ($k in 'cf-mitigated', 'server') { $v = $resp.Headers[$k]; if ($v) { $r.headers[$k] = [string]$v } }
    $resp.Close()
  } catch { $r.error = ($_.Exception.Message -replace '[?#]\S*', '') }
  return $r
}

# Follows plain redirects (http -> https, trailing slashes) and stops at the first component that asks for
# authentication or answers. Recorded URLs carry no query string (no codes, states or tokens).
function Get-RedirectTrace([string]$Url, [string]$HostHeader = '', [string]$AuthHostname = '', [string]$Mode = '', [int]$MaxHops = 5) {
  $hops = @(); $cur = $Url
  for ($i = 0; $i -lt $MaxHops; $i++) {
    $x = Invoke-TraceHop $cur $HostHeader
    $kind = Get-RedirectHopKind -Status $x.status -Location $x.location -AuthHostname $AuthHostname -Headers $x.headers
    $shown = $(if ($HostHeader) { $u = [Uri]$cur; "$($u.Scheme)://$HostHeader$($u.AbsolutePath) (via this PC's Traefik)" } else { ConvertTo-SafeUrl $cur })
    $hops += [ordered]@{ url = $shown; status = $x.status; kind = $kind; next = (ConvertTo-SafeUrl $x.location); error = $x.error }
    if ($kind -ne 'redirect' -or -not $x.location -or $HostHeader) { break }
    $cur = (New-Object Uri ([Uri]$cur), $x.location).AbsoluteUri
  }
  $v = Get-RedirectVerdict $hops $Mode
  return [ordered]@{ hops = $hops; component = $v.component; message = $v.message }
}

# POST /api/identity/trace { service }: which component answers first and who asks for authentication, through the
# public address (Cloudflare) and through this PC's Traefik. Read-only, anonymous, no cookies.
function Invoke-IdentityTrace($Body) {
  Assert-Installed
  $name = [string](Get-Field $Body 'service' '')
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  $svc = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.name -eq $name })[0]
  if (-not $svc) { Stop-Request 404 "No service named '$name'." }
  $h = [string]@($svc.hostnames)[0]
  if (-not $h) { Stop-Request 400 "'$name' has no hostname." }
  $mode = Get-ServiceAuthMode $svc
  $authHost = [string]$cfg.authentik.hostname
  $result = [ordered]@{ service = $svc.name; hostname = $h; mode = $mode; modeLabel = (Get-AuthModeLabel $mode); public = $null; local = $null; checkedAt = (Get-Date -Format 's') }
  if ($svc.cloudflare.publish) { $result.public = Get-RedirectTrace -Url "https://$h/" -AuthHostname $authHost -Mode $mode }
  if ($svc.enabled) { $result.local = Get-RedirectTrace -Url "http://127.0.0.1:$($settings.HttpPort)/" -HostHeader $h -AuthHostname $authHost -Mode $mode -MaxHops 1 }
  Write-Audit 'identity-trace' "$($svc.name) public=$(if ($result.public) { $result.public.component } else { '-' }) local=$(if ($result.local) { $result.local.component } else { '-' })"
  return $result
}

# Removes the Cloudflare Access application DTC created in front of an authentik-protected application (the second,
# redundant login). Preconditions, checked at preview and again at apply: the service uses authentik (not layered),
# its route asks authentik, an anonymous request is sent to sign in right now (ForwardAuth enforced, fails closed),
# and the Access application is the one DTC recorded when it created it. Access applications DTC did not create are
# never touched. Nothing else changes: no Traefik file, DNS record or tunnel route.
function Invoke-IdentityAccessCleanup($Body, [switch]$Apply) {
  Assert-Installed
  if ($Apply) { $p = Use-IdpPlan $Body 'access-cleanup'; $name = $p.Service } else { $name = [string](Get-Field $Body 'service' '') }
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  $svc = @($ctx.Services | Where-Object { $_.name -eq $name })[0]
  if (-not $svc) { Stop-Request 404 "No service named '$name'." }
  $h = [string]@($svc.hostnames)[0]
  $mode = Get-ServiceAuthMode $svc
  if ($mode -ne 'authentik') { Stop-Request 409 $(if ($mode -eq 'layered') { "'$name' uses layered authentication on purpose; change that on the Services page first." } else { "'$name' is not protected by authentik, so its Cloudflare login is not redundant." }) }
  $fact = @($ctx.Facts.apps | Where-Object { $_.service -eq $name })[0]
  if (-not $fact -or -not $fact.forwardAuth.configured -or $fact.forwardAuth.loaded -eq $false) { Stop-Request 409 "The route of '$name' does not ask authentik (ForwardAuth not configured or not loaded). The Cloudflare login is kept." }
  $challenge = Test-ForwardAuthChallenge -TraefikPort $ctx.Settings.HttpPort -Hostname $h -HostPort (Get-IdentityAppAddress ([string]$ctx.Config.authentik.publicUrl) $h).HostPort -AuthHostname $ctx.Config.authentik.hostname
  $State.IdpChecks[$name] = $challenge
  if ($challenge.State -ne 'auth') { Stop-Request 409 "authentik protection of $h is not verified right now ($($challenge.Message)). The Cloudflare login is kept." }
  if (-not (Get-ManagedResource $ctx.Cloudflare $h 'accessAppId')) { Stop-Request 409 "DTC did not create a Cloudflare Access application for $h. Access applications created elsewhere are not changed here: narrow or remove them in Cloudflare Zero Trust." }
  # authentik must also decide WHO may sign in: its application for this service exists and has at least one access rule.
  if (-not $fact.authentik -or -not ($fact.rules -ge 1)) { Stop-Request 409 "authentik has no application with an access rule for '$name' (dm-$name), or it could not be checked, so who may sign in is not verified. The Cloudflare login is kept." }
  # The application DTC recorded must still exist and cover exactly this hostname (never a wildcard, path or multi-domain one).
  $acct = [string]$ctx.Cloudflare.accountId
  $appId = [string](Get-ManagedResource $ctx.Cloudflare $h 'accessAppId')
  $live = $null
  try { $live = Invoke-CloudflareApi -Settings $ctx.Settings -Path "/accounts/$acct/access/apps/$appId" } catch { Stop-Request 409 "The Cloudflare Access application of $h could not be read ($($_.Exception.Message)). Nothing was changed." }
  $shd = @(); if ($live.PSObject.Properties['self_hosted_domains']) { $shd = @($live.self_hosted_domains) }
  $domains = @(@($live.domain) + $shd | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant().TrimEnd('/') } | Select-Object -Unique)
  if ([string]$live.type -ne 'self_hosted' -or $domains.Count -ne 1 -or $domains[0] -ne $h.ToLowerInvariant()) { Stop-Request 409 "The Cloudflare Access application recorded for $h now covers '$($domains -join ', ')' (type $($live.type)), not exactly $h. It is not changed here: review it in Cloudflare Zero Trust." }
  $policies = $null
  try { $policies = @(Invoke-CloudflareApi -Settings $ctx.Settings -Path "/accounts/$acct/access/apps/$appId/policies" -All) } catch { if ($live.PSObject.Properties['policies']) { $policies = @($live.policies) } }
  if ($null -eq $policies) { Stop-Request 409 "The policies of the Cloudflare Access application of $h could not be read, so no restorable copy can be saved. Nothing was changed." }
  $copy =$svc | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $copy.cloudflare.access = $false
  $changeBody = [pscustomobject]@{ op = 'update'; name = $svc.name; service = $copy; cloudflare = [pscustomobject]@{ automate = $true; accessEmails = @(); cleanup = $true } }
  $plan = Build-ChangePlan $changeBody
  $other = @($plan.Cloudflare.Actions | Where-Object { $_.Kind -ne 'none' -and -not ($_.Step -eq 'access' -and $_.Kind -eq 'delete') })
  if ($other.Count -or $plan.Traefik.FileChanges -gt 0) { Stop-Request 409 "Removing the Cloudflare login of $h would also change other things ($((@($other | ForEach-Object { $_.Summary }) + $(if ($plan.Traefik.FileChanges) { 'Traefik route' })) -join '; ')). Use the Services page for that change." }
  $deletes = @($plan.Cloudflare.Actions | Where-Object { $_.Step -eq 'access' -and $_.Kind -eq 'delete' })
  if (-not $deletes.Count) { Stop-Request 409 "There is no Cloudflare Access application created by DTC in front of $h any more. $(@($plan.Cloudflare.Errors) -join ' ')" }
  if (-not $Apply) {
    $id = New-IdpPlanId ([pscustomobject]@{ Kind = 'access-cleanup'; Service = $svc.name; TraefikKey = $plan.TraefikKey; CfFingerprint = $plan.Cloudflare.Fingerprint })
    return [ordered]@{ planId = $id; service = $svc.name; hostname = $h; canApply = $true; challenge = [ordered]@{ state = $challenge.State; message = $challenge.Message }
      actions = @($deletes | ForEach-Object { [ordered]@{ id = $_.Id; summary = $_.Summary; detail = $_.Detail } })
      notes = @(@($plan.Cloudflare.Notes) | Where-Object { $_ -notmatch 'still asks visitors' })
      keeps = @("authentik ForwardAuth in front of $h (verified just now: anonymous visitors are sent to sign in)", "authentik application dm-$name with $($fact.rules) access rule(s)$(if ($fact.ownerOnly) { ' (DTC owners only)' })", 'The Traefik route, DNS record and tunnel route', 'Access applications DTC did not create', 'A copy of the Access application and its policies is saved in backups\cloudflare-access before it is removed')
      rollback = "To put the Cloudflare login back, edit '$($svc.name)' on the Services page, turn on ""Require Cloudflare Access"" and choose layered authentication." }
  }
  if ($plan.TraefikKey -ne $p.TraefikKey -or $plan.Cloudflare.Fingerprint -ne $p.CfFingerprint) { Stop-Request 409 'The configuration or Cloudflare changed since the preview. Preview again.' }
  # Restorable copy first; without it nothing is deleted.
  $snap = Join-Path (Join-Path $ctx.Settings.BackupRoot 'cloudflare-access') ('{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $h)
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path $snap) | Out-Null
    $json = [ordered]@{ savedAt = (Get-Date).ToString('o'); service = $svc.name; hostname = $h; accountId = $acct; app = $live; policies = $policies } | ConvertTo-Json -Depth 15
    [IO.File]::WriteAllText($snap, $json)
    $back = Get-Content -LiteralPath $snap -Raw | ConvertFrom-Json
    if ([string]$back.app.id -ne $appId) { throw 'read-back mismatch' }
  } catch { Stop-Request 500 "A copy of the Access application of $h could not be saved ($($_.Exception.Message)). Nothing was changed." }
  $res = Invoke-ChangePlanSteps $plan @()
  $State.AccessApps = $null
  $after = $null
  if ($res.ok -and $svc.cloudflare.publish) { Start-Sleep -Seconds 2; $after = Get-RedirectTrace -Url "https://$h/" -AuthHostname $ctx.Config.authentik.hostname -Mode 'authentik' }
  Write-Audit 'identity-access-cleanup' "$($svc.name) app=$appId ok=$($res.ok) after=$(if ($after) { $after.component } else { '-' }) snapshot=$snap"
  return [ordered]@{ ok = [bool]$res.ok; service = $svc.name; hostname = $h; steps = @($res.steps); after = $after; snapshot = $snap
    message = $(if (-not $res.ok) { 'Cloudflare did not accept the change; the Access application is unchanged.' } elseif ($after -and $after.component -eq 'authentik') { "Done: $h now goes straight to authentik." } elseif ($after) { "Removed. The public address still answers through $($after.component); Cloudflare can take a minute to apply the change." } else { 'Removed.' }) }
}

function Get-IdentityContext([switch]$Deep, [switch]$ProbeApps) {
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  $inv = @(); try { $inv = @(Get-DockerContainerInventory -ProxyNetwork $settings.ProxyNetwork) } catch { }
  $apps = @(); if (Test-Installed) { $apps = @(Read-AppsRegistry $settings) }
  $installs = @(Find-AuthentikInstallations -Containers $inv -Apps $apps -ProxyNetwork $settings.ProxyNetwork)
  $install = $null
  if ($cfg.authentik.project) { $install = @($installs | Where-Object { $_.project -eq $cfg.authentik.project })[0] }
  elseif ($cfg.authentik.serverContainer) { $install = @($installs | Where-Object { $_.serverContainer -eq $cfg.authentik.serverContainer })[0] }
  $baseUrl = $(if ($install -and $install.localUrl) { $install.localUrl } else { $cfg.authentik.localUrl })
  $running = [bool]($install -and $install.server -and $install.server.state -eq 'running')
  $health = $null; if ($running -and $baseUrl) { $health = Get-AuthentikHealth -BaseUrl $baseUrl }
  # The API token is a managed credential (lib\CredentialManager.psm1): validated at most every two minutes on page
  # loads, immediately on -Deep ("Run checks"), and again whenever authentik refuses it.
  $credential = $null
  $conn = $null; $overview = $null; $overviewError = ''
  $credArgs = Get-IdentityCredentialArgs $settings $baseUrl
  if ($health -and $health.Live) {
    $credential = Test-StoredCredential @credArgs -IfOlderThanMinutes $(if ($Deep) { 0 } else { 2 })
    if ($credential.ok) {
      $plain = Read-ProtectedSecret -Settings $settings -Name (Get-IdentityTokenSecretName)
      $conn = New-AuthentikConnection -BaseUrl $baseUrl -Token $plain
      $plain = $null
      try { $overview = Get-AuthentikOverview $conn }
      catch {
        $overviewError = $_.Exception.Message
        if ($_.Exception.Data['Status'] -in 401, 403) { $credential = Test-StoredCredential @credArgs; $conn = $null; $overviewError = '' }
      }
    }
  } else {
    $credential = Get-CredentialView -Settings $settings -Id 'authentik-api' -SecretName (Get-IdentityTokenSecretName) -Label 'authentik API token'
    if ($credential.stored -and $credential.readable) { $credential.status = 'unreachable'; $credential.ok = $false; $credential.message = 'authentik is not reachable, so the token was not checked. It is kept as it is.' }
  }
  $token = [ordered]@{ stored = $credential.stored; readable = $credential.readable; savedAt = $credential.savedAt; user = $credential.savedBy; ok = [bool]$credential.ok; username = $credential.account
    superuser = [bool]$credential.ok; message = $credential.message; status = $credential.status }
  $services = @(); if (Test-Installed) { try { $services = @((Read-ServiceRegistry -Settings $settings).services) } catch { } }
  $routers = $null; if (Test-Installed) { $routers = Get-TraefikApi $settings '/api/http/routers' }
  $route = $null
  $svc = $(if ($cfg.authentik.service) { @($services | Where-Object { $_.name -eq $cfg.authentik.service })[0] } else { $null })
  if ($svc) {
    $rt = @($routers | Where-Object { $null -ne $_ -and $_.name -eq "svc-$($svc.name)@file" })
    $route = [ordered]@{ exists = $true; enabled = [bool]$svc.enabled; service = $svc.name; publish = [bool]$svc.cloudflare.publish; access = [bool]$svc.cloudflare.access
      router = $(if ($rt.Count) { [string]$rt[0].status } elseif ($null -eq $routers) { 'unknown' } else { 'not loaded' }); target = (Get-ServiceUrl $svc) }
  }
  $cf = Read-CloudflareConfig -Settings $settings
  $cfFacts = $null
  if ($cfg.authentik.hostname) { $dnsId = Get-ManagedResource $cf $cfg.authentik.hostname 'dnsRecordId'; $cfFacts = [ordered]@{ connected = [bool]$cf.tunnelId; dns = [bool]$dnsId; tunnel = [bool]($dnsId -and $cf.tunnelId); access = [bool](Get-ManagedResource $cf $cfg.authentik.hostname 'accessAppId') } }
  $google = [ordered]@{ clientId = $cfg.authentik.google.clientId; source = $null; redirect = $null; logins = @(); verifiedAt = $cfg.authentik.google.verifiedAt; verifiedBy = $cfg.authentik.google.verifiedBy }
  $changed = $false
  if ($overview) {
    $google.source = @($overview.OAuthSources | Where-Object { $_.Slug -eq $cfg.authentik.google.slug })[0]
    if ($google.source -and $cfg.authentik.hostname) { $google.redirect = Test-AuthentikGoogleRedirect -BaseUrl $baseUrl -PublicHost $cfg.authentik.hostname -Slug $cfg.authentik.google.slug -ExpectClientId $google.source.ConsumerKey }
    if ($google.source -and -not $cfg.authentik.google.verifiedAt) {
      $since = $(if ($cfg.authentik.google.configuredAt) { [datetime]$cfg.authentik.google.configuredAt } else { [datetime]::MinValue })
      try { $google.logins = @(Get-AuthentikSourceLogins -Conn $conn -Slug $cfg.authentik.google.slug -Since $since) } catch { }
      if ($google.logins.Count) {
        # Evidence of a real Google sign-in: a user connected to the Google source signed in after it was configured.
        $cfg.authentik.google.verifiedAt = $google.logins[0].LastLogin; $cfg.authentik.google.verifiedBy = $google.logins[0].Username
        $google.verifiedAt = $cfg.authentik.google.verifiedAt; $google.verifiedBy = $cfg.authentik.google.verifiedBy; $changed = $true
      }
    }
  }
  $appFacts = @()
  foreach ($s in @($services | Where-Object { $_.PSObject.Properties['auth'] -and $_.auth.provider -eq 'authentik' })) {
    $known = Get-IdentityApp $cfg $s.name
    $exists = $false; $appPk = ''
    $rules = $null; $ownerOnly = $false
    $prov = [ordered]@{ pk = ''; externalHost = ''; mode = ''; onOutpost = $null }
    if ($conn) {
      try {
        $a = Invoke-AuthentikApi $conn GET "/core/applications/dm-$($s.name)/"; $exists = [bool]$a.provider; $appPk = [string]$a.pk
        # Read only: the provider's external address and mode, and whether the embedded outpost serves it.
        if ($a.provider) {
          $prov.pk = [string]$a.provider
          try { $pp = Invoke-AuthentikApi $conn GET "/providers/proxy/$($a.provider)/"; $prov.externalHost = [string]$pp.external_host; $prov.mode = [string]$pp.mode } catch { }
          if ($overview -and $overview.Outpost) { $prov.onOutpost = [bool](@($overview.Outpost.Providers) -contains [int]$a.provider) }
        }
        # Read only: who may open it is authentik's business; the manager only shows how many rules there are.
        $b = @(Get-AuthentikList $conn "/policies/bindings/?target=$([string]$a.pbm_uuid)"); $rules = $b.Count
        $og = Get-AuthentikGroup $conn (Get-AuthentikOwnersGroupName); $ownerOnly = [bool]($og -and $b.Count -eq 1 -and [string]$b[0].group -eq [string]$og.pk)
      } catch { }
    }
    $verifiedAt = [string](Get-IdProp2 $known 'verifiedAt' '')
    if ($conn -and $appPk -and -not $verifiedAt) {
      $since = $(if ($known -and (Get-IdProp2 $known 'protectedAt' '')) { [datetime](Get-IdProp2 $known 'protectedAt' '') } else { [datetime]::MinValue })
      try { $ev = Get-AuthentikAppAccessEvidence -Conn $conn -ApplicationPk $appPk -Since $since; if ($ev) { $verifiedAt = $ev.At; Set-IdentityApp $cfg $s.name (Merge-IdentityApp $known @{ verifiedAt = $ev.At; verifiedBy = $ev.Username }); $changed = $true } } catch { }
    }
    $check = $(if ($State.IdpChecks.ContainsKey($s.name)) { $State.IdpChecks[$s.name] } else { $null })
    # -ProbeApps (the wizard's protection step and summary): one anonymous request through Traefik per application, so
    # completion is shown from what Traefik and authentik do now, not from stored flags. Read-only.
    if (($Deep -or $ProbeApps) -and $s.enabled) { $check = Test-ForwardAuthChallenge -TraefikPort $settings.HttpPort -Hostname @($s.hostnames)[0] -HostPort (Get-IdentityAppAddress ([string]$cfg.authentik.publicUrl) @($s.hostnames)[0]).HostPort -AuthHostname $cfg.authentik.hostname; $State.IdpChecks[$s.name] = $check }
    # ForwardAuth in the configuration: the route file attaches the authentik middleware, and Traefik has loaded it.
    $rf = Get-RouteFileFacts (Join-Path $InstallPath "traefik\dynamic\svc-$($s.name).yml") $s.name
    $rt = @($routers | Where-Object { $null -ne $_ -and $_.name -eq "svc-$($s.name)@file" })
    $fa = [ordered]@{ configured = [bool](@($rf.middlewares) -contains "svc-$($s.name)-authentik" -and $rf.forwardAuthAddress)
      loaded = $(if ($null -eq $routers) { $null } else { [bool]($rt.Count -and [string]$rt[0].status -eq 'enabled' -and @(if ($rt[0].PSObject.Properties['middlewares']) { $rt[0].middlewares }) -contains "svc-$($s.name)-authentik@file") }) }
    $appFacts += [ordered]@{ service = $s.name; displayName = $(if ($s.PSObject.Properties['displayName']) { $s.displayName } else { $s.name }); hostname = @($s.hostnames)[0]; protected = $true; authentik = $exists; challenge = $check; verifiedAt = $verifiedAt
      verifiedBy = [string](Get-IdProp2 (Get-IdentityApp $cfg $s.name) 'verifiedBy' ''); forwardAuth = $fa; enabled = [bool]$s.enabled; rules = $rules; ownerOnly = $ownerOnly; cloudflareAccess = [bool]$s.cloudflare.access; publish = [bool]$s.cloudflare.publish; slug = "dm-$($s.name)"
      provider = $prov; authentikChecked = [bool]$conn }
  }
  $launcher = @(Get-IdentityLauncher -Settings $settings -Config $cfg -Services $services -Inventory $inv -Routers $routers -AppFacts $appFacts -Cloudflare (Read-CloudflareConfig -Settings $settings) -Install $install -Refresh:$Deep)
  if ($changed) { Save-IdentityConfig -Settings $settings -Config $cfg }
  $pub = $(if ($State.IdpChecks.ContainsKey('__public')) { $State.IdpChecks['__public'] } else { $null })
  if ($Deep -and $cfg.authentik.hostname -and $route -and $route.publish) {
    $r = Invoke-ProbeRequest "https://$($cfg.authentik.hostname)/-/health/live/"
    $pub = [ordered]@{ state = $(if ($r.Status -eq 200) { 'ok' } else { 'failed' }); message = $(if ($r.Status -eq 200) { "https://$($cfg.authentik.hostname) answers through Cloudflare (authentik is live)." } elseif ($r.Status -in 301, 302 -and $r.Location -match 'cloudflareaccess\.com') { 'Cloudflare Access asks for a login before the sign-in page: visitors would log in twice.' } elseif ($r.Status) { "https://$($cfg.authentik.hostname) answered HTTP $($r.Status) (DNS may still be propagating)." } else { "Not reachable yet: $($r.Error) (DNS may still be propagating)." }); checkedAt = (Get-Date -Format 's') }
    if ($r.Status -in 301, 302) { $pub.state = 'failed' }
    $State.IdpChecks['__public'] = $pub
  }
  $facts = [ordered]@{ provider = $cfg.provider; install = $install; health = $health; token = $token; overview = $overview; hostname = $cfg.authentik.hostname; publicUrl = $cfg.authentik.publicUrl; owner = $cfg.authentik.owner; authMode = $cfg.authMode
    route = $route; cloudflare = $cfFacts; publicCheck = $pub; google = $google; apps = $appFacts; launcher = $launcher }
  return [pscustomobject]@{ Settings = $settings; Config = $cfg; Installs = $installs; Install = $install; BaseUrl = $baseUrl; Conn = $conn; Overview = $overview; OverviewError = $overviewError; Credential = $credential
    Facts = $facts; Services = $services; Cloudflare = $cf }
}

# Arguments for the reusable credential functions: the authentik API token, validated against this installation.
function Get-IdentityCredentialArgs($Settings, [string]$BaseUrl) {
  $u = $BaseUrl
  return @{ Settings = $Settings; Id = 'authentik-api'; SecretName = (Get-IdentityTokenSecretName); Label = 'authentik API token'; Validator = { param($t) Test-AuthentikCredential -BaseUrl $u -Token $t }.GetNewClosure() }
}

function Get-IdProp2($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Merge-IdentityApp($Known, [hashtable]$Values) {
  $o = [ordered]@{}
  if ($Known) { foreach ($p in $Known.PSObject.Properties) { $o[$p.Name] = $p.Value } }
  foreach ($k in $Values.Keys) { $o[$k] = $Values[$k] }
  return [pscustomobject]$o
}

function Assert-IdentityConnection($Ctx) {
  if ($Ctx.Config.provider -ne 'authentik') { Stop-Request 409 'Choose authentik as the identity provider first.' }
  if (-not $Ctx.Install) { Stop-Request 409 'No authentik installation is recorded. Install or adopt one first.' }
  if (-not $Ctx.Conn) { Stop-Request 409 $(if ($Ctx.Facts.token.message) { $Ctx.Facts.token.message } else { 'Connect the manager to authentik first (API token).' }) }
  if (-not $Ctx.Facts.token.superuser) { Stop-Request 409 "The saved token belongs to '$($Ctx.Facts.token.username)', who is not an authentik administrator." }
}

function ConvertTo-AkActionView($Actions) {
  return @(@($Actions) | ForEach-Object { [ordered]@{ kind = $_.Kind; object = $_.Object; name = $_.Name; summary = $_.Summary; detail = $_.Detail; status = $_.Status; message = $_.Message } })
}

function Get-AkFingerprint($Actions) { return (Get-TextSha256 ((@(@($Actions) | ForEach-Object { "$($_.Kind)|$($_.Object)|$($_.Name)|$($_.Detail)" })) -join "`n")) }

function New-IdpPlanId($Data) {
  foreach ($k in @($State.IdpPlans.Keys)) { if (((Get-Date) - $State.IdpPlans[$k].Created).TotalMinutes -gt 15) { $State.IdpPlans.Remove($k) } }
  $id = New-RandomKey 12
  $Data | Add-Member -NotePropertyName Created -NotePropertyValue (Get-Date) -Force
  $State.IdpPlans[$id] = $Data
  return $id
}

function Use-IdpPlan($Body, [string]$Kind) {
  Assert-Confirmed $Body
  $id = [string](Get-Field $Body 'planId' '')
  if (-not $id -or -not $State.IdpPlans.ContainsKey($id) -or $State.IdpPlans[$id].Kind -ne $Kind) { Stop-Request 409 'This preview has expired or was already applied. Preview again.' }
  $p = $State.IdpPlans[$id]; $State.IdpPlans.Remove($id)
  if (((Get-Date) - $p.Created).TotalMinutes -gt 15) { Stop-Request 409 'This preview has expired. Preview again.' }
  return $p
}

# Everything the Identity & Access page shows. Secrets never appear: the token only as metadata, the Google client
# secret not at all.
function Get-IdentityData([switch]$Deep, [switch]$ProbeApps) {
  $ctx = Get-IdentityContext -Deep:$Deep -ProbeApps:$ProbeApps
  $cfg = $ctx.Config; $settings = $ctx.Settings
  $model = Get-IdentityModel -Facts $ctx.Facts
  $domains = @($ctx.Cloudflare.domains | ForEach-Object { [string]$_.name })
  $suggested = $(if ($cfg.authentik.hostname) { $cfg.authentik.hostname } else { Get-SuggestedAuthHostname @($domains)[0] })
  $googleValues = $null
  if ($cfg.authentik.publicUrl) { $googleValues = Get-GoogleOAuthSettings -PublicUrl $cfg.authentik.publicUrl -Slug $cfg.authentik.google.slug -Domain $(if ($cfg.authentik.hostname -match '^[^.]+\.(.+)$') { $Matches[1] } else { '' }) }
  $catalogDefaults = $null
  try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id 'authentik'; if (Test-Installed) { $catalogDefaults = Get-AppDefaults $m $settings } } catch { }
  $routeBody = $null
  if ($ctx.Install -and $ctx.Install.serverContainer -and $suggested) {
    $existing = $(if ($cfg.authentik.service) { @($ctx.Services | Where-Object { $_.name -eq $cfg.authentik.service })[0] } else { $null })
    $name = $(if ($existing) { $existing.name } else { $n = 'authentik'; $i = 1; while (@($ctx.Services | Where-Object { $_.name -eq $n }).Count) { $i++; $n = "authentik-$i" }; $n })
    $routeBody = [ordered]@{ op = $(if ($existing) { 'update' } else { 'add' }); name = $name
      service = [ordered]@{ name = $name; displayName = 'authentik (sign-in)'; description = 'authentik sign-in page (Identity & Access)'; enabled = $true; hostnames = @($suggested); pathPrefix = ''; stripPrefix = $false; middlewares = @('default-headers@file')
        target = [ordered]@{ type = 'docker'; host = $ctx.Install.serverContainer; port = 9000; protocol = 'http'; tlsSkipVerify = $false }
        cloudflare = [ordered]@{ publish = [bool]$ctx.Cloudflare.tunnelId; access = $false } } }
  }
  return [ordered]@{
    provider = $cfg.provider; providers = @(Get-IdentityProviders); config = $cfg; progress = $cfg.progress
    installs = @($ctx.Installs); install = $ctx.Install; health = $ctx.Facts.health; token = $ctx.Facts.token; credential = $ctx.Credential; overviewError = $ctx.OverviewError
    overview = $(if ($ctx.Overview) { [ordered]@{ version = $ctx.Overview.Version; user = $ctx.Overview.User; missingFlows = @($ctx.Overview.MissingFlows); outpost = $(if ($ctx.Overview.Outpost) { [ordered]@{ name = $ctx.Overview.Outpost.Name; authentikHost = $ctx.Overview.Outpost.AuthentikHost; providers = @($ctx.Overview.Outpost.Providers) } } else { $null })
        settings = $ctx.Overview.Settings; sources = @($ctx.Overview.OAuthSources); loginStage = $ctx.Overview.LoginStage } } else { $null })
    route = $ctx.Facts.route; cloudflare = $ctx.Facts.cloudflare; publicCheck = $ctx.Facts.publicCheck; google = $ctx.Facts.google; googleValues = $googleValues; apps = @($ctx.Facts.apps)
    launcher = @($ctx.Facts.launcher)
    # Links a browser opens: the public authentik address (where the owner's session and Google sign-in work). The
    # local API address is only for the manager itself; Google rejects sign-in there (redirect_uri_mismatch).
    adminLinks = $(if ($ctx.BaseUrl -or $cfg.authentik.publicUrl) { $bb = Get-AuthentikBrowserBase ([string]$cfg.authentik.publicUrl) ([string]$ctx.BaseUrl); $b = $bb.Base; [ordered]@{ base = $b; public = $bb.Public; local = [string]$ctx.BaseUrl; users = "$b/if/admin/#/identity/users"; groups = "$b/if/admin/#/identity/groups"; invitations = "$b/if/admin/#/core/invitations"; applications = "$b/if/admin/#/core/applications"; flows = "$b/if/admin/#/flow/flows"; sources = "$b/if/admin/#/core/sources"; policies = "$b/if/admin/#/policy/policies" } } else { $null })
    model = $model; domains = $domains; suggestedHostname = $suggested; routeBody = $routeBody; catalogDefaults = $catalogDefaults; contactEmail = [string](Read-SetupDraft).contactEmail
    cloudflareReady = [bool]($ctx.Cloudflare.tunnelId -and (Get-CloudflareApiTokenInfo -Settings $settings).Stored)
    services = @($ctx.Services | ForEach-Object { [ordered]@{ name = $_.name; displayName = $(if ($_.PSObject.Properties['displayName']) { $_.displayName } else { '' }); hostnames = @($_.hostnames); enabled = [bool]$_.enabled
          target = (Get-ServiceUrl $_); publish = [bool]$_.cloudflare.publish; access = [bool]$_.cloudflare.access; auth = $(if ($_.PSObject.Properties['auth']) { $_.auth.provider } else { '' })
          isIdentity = [bool]($ctx.Install -and $_.target.type -eq 'docker' -and $_.target.host -eq $ctx.Install.serverContainer) } })
    checkedAt = (Get-Date -Format 's')
  }
}

function Set-IdentityProviderRequest($Body) {
  Assert-Installed
  $p = [string](Get-Field $Body 'provider' '')
  if ($p -eq 'authelia') { Stop-Request 409 'Authelia can be installed from the App Catalog, but its sign-in integration (Google, protected applications) is not implemented in this version. Choose authentik or Configure later.' }
  if ($p -notin 'authentik', 'none') { Stop-Request 400 "Unknown identity provider '$p'." }
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  $protected = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.PSObject.Properties['auth'] })
  if ($p -eq 'none' -and $protected.Count) { Stop-Request 409 "Remove authentik protection from $(@($protected | ForEach-Object { $_.name }) -join ', ') first." }
  $cfg.provider = $p
  Set-IdentityProgress $cfg 'provider' 'done' $p
  Save-IdentityConfig -Settings $settings -Config $cfg
  Write-Audit 'identity-provider' $p
  return [ordered]@{ ok = $true; provider = $p }
}

# Records an authentik installation found on this PC (installed by the catalog or by hand). Nothing in authentik, its
# containers, volumes or credentials is changed.
function Invoke-IdentityAdopt($Body) {
  Assert-Installed
  $ctx = Get-IdentityContext
  if ($ctx.Config.provider -ne 'authentik') { Stop-Request 409 'Choose authentik as the identity provider first.' }
  $project = [string](Get-Field $Body 'project' '')
  $container = [string](Get-Field $Body 'container' '')
  $inst = @($ctx.Installs | Where-Object { ($project -and $_.project -eq $project) -or ($container -and $_.serverContainer -eq $container) })[0]
  if (-not $inst) { Stop-Request 404 'That authentik installation was not found on this Docker engine.' }
  $notes = @()
  if (-not $inst.localUrl) { $notes += 'Its web port 9000 is not published on 127.0.0.1, so the manager cannot reach its API from this PC. Publish it as 127.0.0.1:<port>:9000 in its compose file.' }
  if ($inst.serverContainer -and -not $inst.onProxyNetwork) { $notes += "$($inst.serverContainer) is not on the shared network '$($ctx.Settings.ProxyNetwork)'; Traefik needs that to reach it. Add the network to its compose file (the manager does not edit projects it did not create)." }
  $cfg = $ctx.Config
  $cfg.authentik.project = $inst.project; $cfg.authentik.folder = $inst.folder; $cfg.authentik.managed = [bool]$inst.managed
  $cfg.authentik.serverContainer = $inst.serverContainer; $cfg.authentik.localUrl = $inst.localUrl
  Set-IdentityProgress $cfg 'install' 'done' "adopted $($inst.project)"
  Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
  Write-Audit 'identity-adopt' "project=$($inst.project) container=$($inst.serverContainer) managed=$($inst.managed)"
  return [ordered]@{ ok = $true; install = $inst; notes = $notes }
}

# Replaces (or sets) the authentik API token. The candidate is validated against this authentik first: it must work,
# belong to an administrator and reach every API area the manager uses. Only then does it replace the stored token;
# a failed candidate leaves the stored token exactly as it was, so another attempt is always possible. For
# installations made by the manager the token can be taken from the project's .env (AUTHENTIK_BOOTSTRAP_TOKEN).
# Nothing in authentik changes: no container, account, outpost token or configuration is touched.
function Save-IdentityTokenRequest($Body) {
  Assert-Installed
  $ctx = Get-IdentityContext
  if (-not $ctx.Install) { Stop-Request 409 'Install or adopt authentik first.' }
  if (-not $ctx.BaseUrl) { Stop-Request 409 'authentik has no local address (port 9000 on 127.0.0.1) the manager can reach.' }
  $token = ''
  if ([bool](Get-Field $Body 'fromBootstrap' $false)) {
    if (-not ($ctx.Install.managed -and $ctx.Install.folder)) { Stop-Request 409 'Only installations made by this manager have a bootstrap token; paste a token instead.' }
    $envFile = Read-AppEnv (Join-Path $ctx.Install.folder '.env')
    if (-not $envFile.Contains('AUTHENTIK_BOOTSTRAP_TOKEN') -or -not $envFile['AUTHENTIK_BOOTSTRAP_TOKEN']) { Stop-Request 409 'This installation was made without a bootstrap token (an older catalog version). Create an API token in authentik and paste it.' }
    $token = [string]$envFile['AUTHENTIK_BOOTSTRAP_TOKEN']
  } else { $token = ([string](Get-Field $Body 'token' '')).Trim() }
  if (-not $token) { Stop-Request 400 'Paste the new API token.' }
  $credArgs = Get-IdentityCredentialArgs $ctx.Settings $ctx.BaseUrl
  $r = Set-CredentialFromCandidate @credArgs -Candidate $token
  $token = $null
  if (-not $r.Ok) {
    Write-Audit 'identity-token-rejected' "status=$($r.Result.Status) account=$($r.Result.Account)"
    $msg = $(if ($r.Result.Status -eq 'unreachable') { "$($r.Result.Message) Nothing was changed." } else { "$($r.Result.Message) The token you entered was not saved; $(if ($r.View.stored) { 'the previously saved token is unchanged.' } else { 'nothing is saved yet.' })" })
    Stop-Request 400 $msg @{ credential = $r.View; candidate = [ordered]@{ status = $r.Result.Status; account = $r.Result.Account; message = $r.Result.Message }; preserved = [bool]$r.View.stored }
  }
  Set-IdentityProgress $ctx.Config 'api' 'done' $r.Result.Account
  Save-IdentityConfig -Settings $ctx.Settings -Config $ctx.Config
  Write-Audit 'identity-token' "$(if ($r.Replaced) { 'replaced' } else { 'saved' }) account=$($r.Result.Account) expires=$($r.View.expiresAt)"
  $model = Get-IdentityModel -Facts (Get-IdentityContext).Facts
  return [ordered]@{ ok = $true; replaced = $r.Replaced; credential = $r.View; username = $r.Result.Account; superuser = $true; version = $r.Result.Version; next = @($model.next)[0]; warning = $r.View.expiryWarning }
}

# "Test connection": validates the stored token again without asking for it.
function Test-IdentityTokenRequest {
  Assert-Installed
  $ctx = Get-IdentityContext
  if (-not $ctx.BaseUrl) { Stop-Request 409 'No authentik installation with a local address is recorded.' }
  $credArgs = Get-IdentityCredentialArgs $ctx.Settings $ctx.BaseUrl
  $view = Test-StoredCredential @credArgs
  Write-Audit 'identity-token-test' "status=$($view.status) account=$($view.account)"
  return [ordered]@{ ok = [bool]$view.ok; credential = $view; next = @((Get-IdentityModel -Facts (Get-IdentityContext).Facts).next)[0] }
}

# Records the public sign-in hostname (the route itself is created through the normal service preview).
function Set-IdentityHostnameRequest($Body) {
  Assert-Installed
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  $h = ([string](Get-Field $Body 'hostname' '')).Trim().ToLowerInvariant()
  if ($h -notmatch '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { Stop-Request 400 'Enter a hostname such as auth.example.com.' }
  $svcName = ([string](Get-Field $Body 'service' '')).Trim().ToLowerInvariant()
  if ($svcName -notmatch '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$') { Stop-Request 400 'Invalid service name.' }
  $services = @((Read-ServiceRegistry -Settings $settings).services)
  $other = @($services | Where-Object { $_.name -ne $svcName -and @($_.hostnames) -contains $h })
  if ($other.Count) { Stop-Request 409 "$h is already used by service '$($other[0].name)'." }
  $cfg.authentik.hostname = $h; $cfg.authentik.service = $svcName; $cfg.authentik.publicUrl = "https://$h"
  Set-IdentityProgress $cfg 'hostname' 'saved' $h
  Save-IdentityConfig -Settings $settings -Config $cfg
  Write-Audit 'identity-hostname' $h
  return [ordered]@{ ok = $true; hostname = $h; publicUrl = "https://$h"; redirectUri = "https://$h/source/oauth/callback/$($cfg.authentik.google.slug)/" }
}

function Invoke-IdentityOutpost($Body, [switch]$Apply) {
  Assert-Installed
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  if (-not $ctx.Config.authentik.publicUrl) { Stop-Request 409 'Choose the public sign-in address first.' }
  if (-not $Apply) {
    $actions = Sync-AuthentikOutpost -Conn $ctx.Conn -PublicUrl $ctx.Config.authentik.publicUrl -WhatIf
    $id = New-IdpPlanId ([pscustomobject]@{ Kind = 'outpost'; Fingerprint = (Get-AkFingerprint $actions) })
    return [ordered]@{ planId = $id; actions = @(ConvertTo-AkActionView $actions); canApply = [bool]@($actions | Where-Object { $_.Kind -ne 'none' }).Count }
  }
  $p = Use-IdpPlan $Body 'outpost'
  if ((Get-AkFingerprint (Sync-AuthentikOutpost -Conn $ctx.Conn -PublicUrl $ctx.Config.authentik.publicUrl -WhatIf)) -ne $p.Fingerprint) { Stop-Request 409 'authentik changed since the preview. Preview again.' }
  $actions = Sync-AuthentikOutpost -Conn $ctx.Conn -PublicUrl $ctx.Config.authentik.publicUrl
  Set-IdentityProgress $ctx.Config 'outpost' 'done' $ctx.Config.authentik.publicUrl
  Save-IdentityConfig -Settings $ctx.Settings -Config $ctx.Config
  Write-Audit 'identity-outpost' $ctx.Config.authentik.publicUrl
  return [ordered]@{ ok = $true; actions = @(ConvertTo-AkActionView $actions) }
}

# The initial owner's Google address: asked once. It can be changed until the owner has signed in with Google; after
# that, people are managed in authentik.
function Set-IdentityOwnerRequest($Body) {
  Assert-Installed
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  if ($cfg.authentik.owner.subject) { Stop-Request 409 "The initial owner ($($cfg.authentik.owner.email)) is already set up with Google. Add more people, or change who owns what, in authentik." }
  try { $email = ConvertTo-OwnerEmail ([string](Get-Field $Body 'email' '')) } catch { Stop-Request 400 $_.Exception.Message }
  $cfg.authentik.owner.email = $email
  $cfg.authentik.owner.makeAdmin = [bool](Get-Field $Body 'makeAdmin' $true)
  Set-IdentityProgress $cfg 'owner' 'saved' ''
  Save-IdentityConfig -Settings $settings -Config $cfg
  Write-Audit 'identity-owner' 'initial owner address saved'
  return [ordered]@{ ok = $true; owner = $cfg.authentik.owner }
}

function Get-GoogleDesired($Body, $Cfg) {
  $id = ([string](Get-Field $Body 'clientId' $Cfg.authentik.google.clientId)).Trim(); $secret = ([string](Get-Field $Body 'clientSecret' '')).Trim()
  $json = [string](Get-Field $Body 'clientJson' '')
  if ($json) {
    # Google's downloaded client file (preferred): validated here; the secret is used once and never stored.
    $redir = "$($Cfg.authentik.publicUrl)/source/oauth/callback/$($Cfg.authentik.google.slug)/"
    $g = ConvertFrom-GoogleClientJson -Json $json -ExpectedRedirectUri $redir
    $json = $null
    if (-not $g.Ok) { Stop-Request 400 ($g.Errors -join ' ') @{ jsonErrors = @($g.Errors) } }
    $id = $g.ClientId; $secret = $g.ClientSecret
  }
  return [pscustomobject]@{ Slug = $Cfg.authentik.google.slug; ClientId = $id; ClientSecret = $secret
    OwnerEmail = $Cfg.authentik.owner.email; OwnerVerified = [bool]$Cfg.authentik.owner.subject; Replace = [bool](Get-Field $Body 'replace' $false); Repair = [bool](Get-Field $Body 'repair' $false) }
}

# Checks a downloaded Google client file without using it: client type, ID, secret present, redirect URI, endpoints.
function Invoke-IdentityGoogleInspect($Body) {
  Assert-Installed
  $cfg = Read-IdentityConfig -Settings (Get-Settings)
  if (-not $cfg.authentik.publicUrl) { Stop-Request 409 'Set up the public sign-in address first: the file must contain its redirect URI.' }
  $redir = "$($cfg.authentik.publicUrl)/source/oauth/callback/$($cfg.authentik.google.slug)/"
  $g = ConvertFrom-GoogleClientJson -Json ([string](Get-Field $Body 'clientJson' '')) -ExpectedRedirectUri $redir
  return [ordered]@{ ok = $g.Ok; clientId = $g.ClientId; projectId = $g.ProjectId; secretPresent = [bool]$g.ClientSecret; redirectUris = @($g.RedirectUris); expectedRedirectUri = $redir; errors = @($g.Errors); warnings = @($g.Warnings) }
}

# Saves the client ID (never the secret), so the wizard survives a refresh or a trip to Google Cloud.
function Save-IdentityGoogleRequest($Body) {
  Assert-Installed
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  $id = ([string](Get-Field $Body 'clientId' '')).Trim()
  if ($id -and -not (Test-GoogleClientId $id)) { Stop-Request 400 'The client ID does not look like a Google OAuth client ID (it ends in .apps.googleusercontent.com).' }
  $cfg.authentik.google.clientId = $id
  Set-IdentityProgress $cfg 'google' 'draft' 'client ID saved'
  Save-IdentityConfig -Settings $settings -Config $cfg
  return [ordered]@{ ok = $true; google = $cfg.authentik.google }
}

function Invoke-IdentityGooglePlan($Body) {
  Assert-Installed
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  if (-not $ctx.Config.authentik.publicUrl) { Stop-Request 409 'Set up the public sign-in address first: Google needs the https redirect URI.' }
  if (-not $ctx.Config.authentik.owner.email) { Stop-Request 409 'Enter the initial owner''s Google account first.' }
  $d = Get-GoogleDesired $Body $ctx.Config
  try { $r = Sync-AuthentikGoogleSource -Conn $ctx.Conn -Desired $d -WhatIf }
  catch { if ($_.Exception.Data['NeedsReplace']) { Stop-Request 409 $_.Exception.Message @{ needsReplace = $true } } else { Stop-Request 400 $_.Exception.Message } }
  $id = New-IdpPlanId ([pscustomobject]@{ Kind = 'google'; Desired = $d; Fingerprint = (Get-AkFingerprint $r.Actions) })
  return [ordered]@{ planId = $id; actions = @(ConvertTo-AkActionView $r.Actions); canApply = $true; secretProvided = [bool]$d.ClientSecret; redirectUri = "$($ctx.Config.authentik.publicUrl)/source/oauth/callback/$($d.Slug)/"
    notes = @("Only $($d.OwnerEmail) can create an account with Google at first. Everyone else is added later in authentik (invitations, or by editing the enrollment policy there).",
      'Google accounts are never linked to existing authentik accounts by email.',
      'akadmin keeps signing in with its password: Google is an additional sign-in method, never the only way in.') }
}

function Invoke-IdentityGoogleApply($Body) {
  Assert-Installed
  $p = Use-IdpPlan $Body 'google'
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  $now = $null; try { $now = Sync-AuthentikGoogleSource -Conn $ctx.Conn -Desired $p.Desired -WhatIf } catch { Stop-Request 409 $_.Exception.Message }
  if ((Get-AkFingerprint $now.Actions) -ne $p.Fingerprint) { Stop-Request 409 'authentik changed since the preview. Preview again.' }
  $null = New-ChangeRecoveryPoint 'before Google sign-in configuration'
  $result = $null; $err = ''
  try { $result = Sync-AuthentikGoogleSource -Conn $ctx.Conn -Desired $p.Desired } catch { $err = $_.Exception.Message }
  $p.Desired.ClientSecret = $null
  $cfg = $ctx.Config; $g = $cfg.authentik.google
  if ($err) {
    Set-IdentityProgress $cfg 'google' 'failed' $err
    Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
    Write-Audit 'identity-google' "failed: $err"
    return [ordered]@{ ok = $false; message = "$err Nothing after the failed step was changed; preview again to continue where it stopped."; actions = @() }
  }
  $g.clientId = $p.Desired.ClientId
  if (@($result.Actions | Where-Object { $_.Kind -ne 'none' -and $_.Object -eq 'Google source' }).Count) { $g.configuredAt = (Get-Date -Format 's') }
  Set-IdentityProgress $cfg 'google' 'configured' ''
  Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
  Write-Audit 'identity-google' ("applied: " + ((@($result.Actions | Where-Object { $_.Kind -ne 'none' } | ForEach-Object { "$($_.Kind) $($_.Object) $($_.Name)" })) -join '; '))
  $redir = $null; if ($cfg.authentik.hostname) { $redir = Test-AuthentikGoogleRedirect -BaseUrl $ctx.BaseUrl -PublicHost $cfg.authentik.hostname -Slug $g.slug -ExpectClientId $g.clientId }
  return [ordered]@{ ok = $true; actions = @(ConvertTo-AkActionView $result.Actions); redirect = $redir }
}

# Owner verification (explicit setup action). Google path: the account connected to the Google source with the owner's
# address (authentik's enrollment policy only let Google-verified addresses through); the Google subject seen first is
# pinned. Local path: the administrator whose token the manager uses, signed in after the check was started. Both: the
# account must be Internal, joins "DTC owners" (and the administrators if chosen). An External account is only changed
# to Internal when the request says repair = true.
function Invoke-IdentityOwnerVerify($Body) {
  Assert-Installed
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  $cfg = $ctx.Config; $o = $cfg.authentik.owner
  $local = $cfg.authMode -eq 'local'
  $repair = [bool](Get-Field $Body 'repair' $false)
  $since = [datetime]::MinValue
  if ($local) {
    if (-not $o.localSince) { Stop-Request 409 'Start the local sign-in check first.' }
    $since = [datetime]$o.localSince
    $me = (Invoke-AuthentikApi $ctx.Conn GET '/core/users/me/').user
    $owner = [pscustomobject]@{ Pk = [int]$me.pk; Username = [string]$me.username; Subject = '' }
    $null = Sync-AuthentikOwnersGroup -Conn $ctx.Conn
  } else {
    if (-not $o.email) { Stop-Request 409 'Enter the initial owner''s Google account first.' }
    $found = @(Find-AuthentikOwner -Conn $ctx.Conn -OwnerEmail $o.email -Slug $cfg.authentik.google.slug | Where-Object { $_.IsActive })
    if (-not $found.Count) { return [ordered]@{ ok = $false; verified = $false; items = @(); message = "Nobody has signed in with Google as $($o.email) yet. Press ""Continue with Google"", choose that account, then ""I've signed in - check again""." } }
    if ($found.Count -gt 1) { Stop-Request 409 "Several authentik accounts signed in with Google as $($o.email): $(@($found | ForEach-Object { $_.Username }) -join ', '). Resolve this in authentik first." }
    $owner = $found[0]
    if ($o.subject -and $owner.Subject -ne $o.subject) { Stop-Request 409 'A different Google identity signed in with the owner''s address than the one verified first. Nothing was changed; check the account in authentik.' }
  }
  $repaired = @()
  $u = Invoke-AuthentikApi $ctx.Conn GET "/core/users/$($owner.Pk)/"
  if ([string]$u.type -ne 'internal') {
    if (-not $repair) {
      $chk = Get-AuthentikOwnerCheck -Conn $ctx.Conn -Owner $owner -MakeAdmin:([bool]$o.makeAdmin -and -not $local) -ExpectSubject $o.subject -Since $since -Local:$local
      return [ordered]@{ ok = $false; verified = $false; needsRepair = $true; items = @($chk.Items); username = $owner.Username; message = "'$($owner.Username)' is an External authentik account, so authentik's dashboard refuses it (""Interface can only be accessed by internal users""). Repair makes it Internal; nothing else changes." }
    }
    if (Set-AuthentikUserInternal -Conn $ctx.Conn -UserPk $owner.Pk) { $repaired += "made '$($owner.Username)' Internal" }
  }
  $null = Complete-AuthentikOwner -Conn $ctx.Conn -UserPk $owner.Pk -MakeAdmin:([bool]$o.makeAdmin -and -not $local)
  $chk = Get-AuthentikOwnerCheck -Conn $ctx.Conn -Owner $owner -MakeAdmin:([bool]$o.makeAdmin -and -not $local) -ExpectSubject $o.subject -Since $since -Local:$local
  if ($chk.Ok) {
    if (-not $o.verifiedAt -or (-not $local -and -not $o.subject)) { $o.verifiedAt = $(if ($chk.LastLogin) { $chk.LastLogin } else { Get-Date -Format 's' }) }
    $o.username = $owner.Username
    if (-not $local) { $o.subject = $owner.Subject; if (-not $cfg.authentik.google.verifiedAt) { $cfg.authentik.google.verifiedAt = $o.verifiedAt; $cfg.authentik.google.verifiedBy = $owner.Username } }
    Set-IdentityProgress $cfg 'owner' 'verified' $owner.Username
    Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
  }
  Write-Audit 'identity-owner-verify' "user=$($owner.Username) ok=$($chk.Ok) local=$local repaired=$($repaired -join ',')"
  return [ordered]@{ ok = $chk.Ok; verified = $chk.Ok; items = @($chk.Items); username = $owner.Username; repaired = $repaired
    message = $(if ($chk.Ok) { "Verified: $($owner.Username) is the owner." } else { 'Not verified yet: ' + ((@($chk.Items | Where-Object { -not $_.ok } | ForEach-Object { "$($_.label): $($_.message)" })) -join ' ') })
    next = $(if ($chk.Ok) { @((Get-IdentityModel -Facts (Get-IdentityContext).Facts).next)[0] } else { '' }) }
}

# Local path: remember when the check started, so only a sign-in after it counts.
function Start-IdentityLocalOwnerCheck {
  Assert-Installed
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  if ($cfg.authentik.owner.verifiedAt -and $cfg.authMode -eq 'local') { Stop-Request 409 'The owner is already verified.' }
  $cfg.authentik.owner.localSince = (Get-Date).AddSeconds(-5).ToString('s')
  Save-IdentityConfig -Settings $settings -Config $cfg
  return [ordered]@{ ok = $true; since = $cfg.authentik.owner.localSince }
}

function Set-IdentityModeRequest($Body) {
  Assert-Installed
  $m = [string](Get-Field $Body 'mode' '')
  if ($m -notin 'local', 'google') { Stop-Request 400 'mode must be local or google.' }
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  if ($cfg.provider -ne 'authentik') { $cfg.provider = 'authentik' }
  # Only the guided path changes: switching never touches authentik accounts, policies or application access.
  $cfg.authMode = $m
  Set-IdentityProgress $cfg 'mode' 'done' $m
  Save-IdentityConfig -Settings $settings -Config $cfg
  Write-Audit 'identity-mode' $m
  return [ordered]@{ ok = $true; mode = $m }
}

function Set-IdentityWizardStepRequest($Body) {
  Assert-Installed
  $step = [string](Get-Field $Body 'step' '')
  if ($step -notmatch '^[a-z-]{1,30}$') { Stop-Request 400 'Invalid step.' }
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  $cfg.wizardStep = $step
  $skip = [string](Get-Field $Body 'skip' '')
  if ($skip -eq 'apps') { $cfg.protectSkippedAt = (Get-Date -Format 's') } elseif ($skip -eq 'clear-apps') { $cfg.protectSkippedAt = '' }
  Save-IdentityConfig -Settings $settings -Config $cfg
  return [ordered]@{ ok = $true }
}

# Google-first sign-in page: preview, apply (records the previous brand values), restore.
function Invoke-IdentityLoginPage($Body, [string]$Action) {
  Assert-Installed
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  $cfg = $ctx.Config; $lp = $cfg.authentik.loginPage
  $domain = $(if ($cfg.authentik.hostname -match '^[^.]+\.(.+)$') { $Matches[1] } else { $cfg.authentik.hostname })
  $title = "Sign in to $domain"
  switch ($Action) {
    'plan' {
      try { $r = Sync-AuthentikLoginPage -Conn $ctx.Conn -Title $title -Slug $cfg.authentik.google.slug -WhatIf } catch { Stop-Request 400 $_.Exception.Message }
      $id = New-IdpPlanId ([pscustomobject]@{ Kind = 'loginpage'; Fingerprint = (Get-AkFingerprint $r.Actions) })
      return [ordered]@{ planId = $id; actions = @(ConvertTo-AkActionView $r.Actions); title = $title; canApply = [bool]@($r.Actions | Where-Object { $_.Kind -ne 'none' }).Count
        recoveryUrl = "$($ctx.BaseUrl)/if/flow/default-authentication-flow/" }
    }
    'apply' {
      $p = Use-IdpPlan $Body 'loginpage'
      if ((Get-AkFingerprint (Sync-AuthentikLoginPage -Conn $ctx.Conn -Title $title -Slug $cfg.authentik.google.slug -WhatIf).Actions) -ne $p.Fingerprint) { Stop-Request 409 'authentik changed since the preview. Preview again.' }
      $r = Sync-AuthentikLoginPage -Conn $ctx.Conn -Title $title -Slug $cfg.authentik.google.slug
      if (-not $lp.appliedAt) { $lp.brand = $r.Previous.brand; $lp.previousFlow = $r.Previous.flow; $lp.previousTitle = $r.Previous.title }
      $lp.appliedAt = (Get-Date -Format 's')
      Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
      Write-Audit 'identity-loginpage' 'applied'
      return [ordered]@{ ok = $true; actions = @(ConvertTo-AkActionView $r.Actions) }
    }
    'restore' {
      Assert-Confirmed $Body
      if (-not $lp.appliedAt) { Stop-Request 409 'The Google-first sign-in page was not applied by the manager.' }
      Restore-AuthentikLoginPage -Conn $ctx.Conn -Previous ([pscustomobject]@{ brand = $lp.brand; flow = $lp.previousFlow; title = $lp.previousTitle })
      $lp.appliedAt = ''
      Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
      Write-Audit 'identity-loginpage' 'restored'
      return [ordered]@{ ok = $true }
    }
  }
}

# Protecting applications: one service at a time is turned into a change body for the normal Traefik/Cloudflare
# pipeline. Cloudflare Access stays as it is unless 'remove' is chosen explicitly.
function Get-ProtectRequest([string]$Name, $Ctx, [string]$AccessChoice = 'keep', [switch]$Remove) {
  $svc = @($Ctx.Services | Where-Object { $_.name -eq $Name.ToLowerInvariant() })[0]
  if (-not $svc) { Stop-Request 404 "No service named '$Name'." }
  if ($Ctx.Install -and $svc.target.type -eq 'docker' -and $svc.target.host -eq $Ctx.Install.serverContainer) { Stop-Request 400 "'$($svc.name)' is the authentik sign-in page itself; it cannot be protected by authentik (endless redirect loop)." }
  if ($Ctx.Config.authentik.service -and $svc.name -eq $Ctx.Config.authentik.service) { Stop-Request 400 "'$($svc.name)' is the authentik sign-in page itself; it cannot be protected by authentik." }
  if (-not $Remove) {
    if (-not $svc.enabled) { Stop-Request 400 "'$($svc.name)' is disabled." }
    if (@($svc.hostnames).Count -ne 1) { Stop-Request 400 "'$($svc.name)' has several hostnames; authentik identifies an application by one address." }
    if (-not $Ctx.Install.onProxyNetwork) { Stop-Request 409 "authentik ($($Ctx.Install.serverContainer)) is not on the shared network, so Traefik cannot ask it whether a visitor may pass." }
  }
  # remove (default when protecting): authentik becomes the only interactive sign-in; a Cloudflare Access application
  # this tool created is deleted. layered: Cloudflare Access stays in front on purpose (two sign-ins). keep: the
  # previous name of layered; when removing protection it keeps Cloudflare Access as the remaining gate.
  if ($AccessChoice -notin 'keep', 'remove', 'layered') { Stop-Request 400 'cloudflareAccess must be remove, layered or keep.' }
  $copy = $svc | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ($AccessChoice -eq 'remove') { $copy.cloudflare.access = $false }
  if ($Remove) { $copy.PSObject.Properties.Remove('auth') | Out-Null; $copy | Add-Member -NotePropertyName auth -NotePropertyValue ([pscustomobject]@{ provider = 'none' }) -Force }
  else {
    $auth = [pscustomobject][ordered]@{ provider = 'authentik'; endpoint = "http://$($Ctx.Install.serverContainer):9000" }
    if ($copy.cloudflare.access) { $auth | Add-Member -NotePropertyName layered -NotePropertyValue $true }
    $copy | Add-Member -NotePropertyName auth -NotePropertyValue $auth -Force
  }
  $cfReady = [bool]($Ctx.Cloudflare.tunnelId -and (Get-CloudflareApiTokenInfo -Settings $Ctx.Settings).Stored)
  return [pscustomobject]@{ Service = $svc; ChangeBody = [pscustomobject]@{ op = 'update'; name = $svc.name; service = $copy; cloudflare = [pscustomobject]@{ automate = [bool]($cfReady -and $copy.cloudflare.publish); accessEmails = @(Get-ManagedAccessEmails $Ctx.Cloudflare @($svc.hostnames)[0]); cleanup = ($AccessChoice -eq 'remove') } } }
}

# PublicUrl: the sign-in address browsers are sent to; protection points the embedded outpost at it (or refuses when
# none is set and the outpost would send browsers to an address that only works on this PC).
function Get-ProtectDesired($Svc) {
  $pub = ''; try { $pub = [string](Read-IdentityConfig -Settings (Get-Settings)).authentik.publicUrl } catch { }
  $h = @($Svc.hostnames)[0]
  return [pscustomobject]@{ Service = $Svc.name; DisplayName = $(if ($Svc.PSObject.Properties['displayName']) { $Svc.displayName } else { $Svc.name }); Hostname = $h; PublicUrl = $pub; ExternalUrl = (Get-IdentityAppAddress $pub $h).Url }
}

# Preview for "Protect selected with authentik" (services: [...]) or for removing protection from one (service).
# A sign-in in Traefik protects only requests through Traefik: host ports the backend container publishes reach it
# directly. Returns a note for the protection preview ('' when nothing is published or the container is unknown).
# Nothing is changed: the owner of the Compose file removes the ports.
function Get-SignInBypassNote($Service) {
  if (-not $Service) { return '' }
  if ([string]$Service.target.type -eq 'host') {
    # Traefik reaches it through a port on this computer: that port is open to the network unless bound to loopback.
    $port = [int]$Service.target.port
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.LocalAddress } | Select-Object -Unique)
    $wide = @($listen | Where-Object { $_ -notin '127.0.0.1', '::1' })
    if ($wide.Count) { return "Warning: the application listens on $(@($wide | ForEach-Object { "${_}:$port" }) -join ', '), so other devices on the network can open it directly, WITHOUT signing in, unless Windows Firewall blocks port $port. Block port $port for other devices in Windows Firewall, or make the application listen on 127.0.0.1 only (then check that the route still works: Traefik reaches it as host.docker.internal); the sign-in protects only the address $(@($Service.hostnames)[0])." }
    return ''
  }
  if ([string]$Service.target.type -ne 'docker') { return '' }
  $name = [string]$Service.target.host
  if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { return '' }
  $r = Invoke-Docker inspect --format '{{json .NetworkSettings.Ports}}|{{json .Config.Labels}}' $name
  if ($r.ExitCode -ne 0) { return '' }
  $parts = ([string]($r.Output -join '')) -split '\|', 2
  $ports = $null; $labels = $null
  try { $ports = $parts[0] | ConvertFrom-Json; if ($parts.Count -gt 1) { $labels = $parts[1] | ConvertFrom-Json } } catch { return '' }
  if (-not $ports) { return '' }
  $open = @(); $local = @()
  foreach ($p in $ports.PSObject.Properties) {
    foreach ($b in @($p.Value)) {
      if (-not $b -or -not [string]$b.HostPort) { continue }
      $ip = [string]$b.HostIp
      $d = "$(if ($ip) { $ip } else { '0.0.0.0' }):$($b.HostPort)"
      if ($ip -in '127.0.0.1', '::1') { $local += $d } else { $open += $d }
    }
  }
  $open = @($open | Select-Object -Unique); $local = @($local | Select-Object -Unique)
  if (-not ($open.Count + $local.Count)) { return '' }
  $cf = $(if ($labels -and $labels.PSObject.Properties['com.docker.compose.project.config_files']) { [string]$labels.'com.docker.compose.project.config_files' } else { '' })
  $owner = $(if ($cf) { "its Compose file ($cf)" } else { '' })
  return "Warning: $name also publishes $(@($open + $local) -join ', ') on this computer. $(if ($open.Count) { 'Anyone who can reach this computer on that port opens the application WITHOUT signing in.' } else { 'Programs and users on this PC open it without signing in.' }) Remove the ports: entry from $(if ($owner) { $owner } else { 'its Compose file' }) and redeploy it (Traefik reaches it over the shared network); the sign-in protects only the address $(@($Service.hostnames)[0])."
}

function Invoke-IdentityProtectPlan($Body, [switch]$Remove) {
  Assert-Installed
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  foreach ($k in @('emails', 'domains', 'groups', 'createGroup')) { if ($Body.PSObject.Properties[$k]) { Stop-Request 400 "Who may open an application is managed in authentik, not here ('$k' is not accepted)." } }
  $names = @(@(Get-Field $Body 'services' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
  if (-not $names.Count -and (Get-Field $Body 'service' '')) { $names = @([string](Get-Field $Body 'service' '')) }
  if (-not $names.Count) { Stop-Request 400 'Select at least one application.' }
  if ($Remove -and $names.Count -ne 1) { Stop-Request 400 'Remove protection from one application at a time.' }
  if ($names.Count -gt 20) { Stop-Request 400 'At most 20 applications at once.' }
  # Protecting: authentik becomes the only login unless layered authentication is chosen explicitly. Removing
  # protection: Cloudflare Access (if any) stays as the remaining gate unless asked otherwise.
  $access = [string](Get-Field $Body 'cloudflareAccess' $(if ($Remove) { 'keep' } else { 'remove' }))
  $items = @(); $stored = @()
  foreach ($n in $names) {
    $req = Get-ProtectRequest $n $ctx $access -Remove:$Remove
    $ak = $null
    try { $ak = $(if ($Remove) { Remove-AuthentikAppProtection -Conn $ctx.Conn -Service $req.Service.name -WhatIf } else { (Sync-AuthentikAppProtection -Conn $ctx.Conn -Desired (Get-ProtectDesired $req.Service) -WhatIf).Actions }) } catch { Stop-Request 400 "$($req.Service.name): $($_.Exception.Message)" }
    $plan = Build-ChangePlan $req.ChangeBody
    $view = ConvertTo-PlanView $plan ''
    $svc = $req.Service
    $notes = @()
    if ($Remove) { $notes += $(if ($svc.cloudflare.publish -and -not $req.ChangeBody.service.cloudflare.access) { 'After this, the application is reachable WITHOUT any sign-in by anyone on the Internet (public, no Cloudflare Access). Its own login is the only protection.' } elseif ($svc.cloudflare.publish) { 'After this, Cloudflare Access is the only sign-in in front of the application.' } else { 'After this, the application is reachable from this PC without sign-in.' }); $notes += 'The authentik application and its access rules stay in authentik; protecting it again reuses them.' }
    else {
      if ($svc.cloudflare.publish -and $req.ChangeBody.service.cloudflare.access) { $notes += 'Cloudflare Access stays in front: visitors sign in with Cloudflare first, then with authentik.' }
      if (@($ak | Where-Object { $_.Object -eq 'access' -and $_.Kind -eq 'none' }).Count) { $notes += 'This application already has access rules in authentik; they are kept exactly as they are.' }
      $bypass = Get-SignInBypassNote $svc
      if ($bypass) { $notes += $bypass }
    }
    $errors = @($view.traefik.issues | Where-Object { $_.Level -eq 'Error' }).Count + @($view.cloudflare.errors).Count
    # Removal: what stays exactly as it is, and whether the application ends up open to the Internet without any
    # sign-in (the page then asks for an explicit acknowledgement).
    $keeps = @(); $public = $false
    if ($Remove) {
      $public = [bool]($svc.cloudflare.publish -and -not $req.ChangeBody.service.cloudflare.access)
      $keeps = @("The container and the application itself", "The route: $(@($svc.hostnames)[0]) still goes to $(Get-ServiceUrl $svc)",
        "authentik: the application dm-$($svc.name), its provider, users, groups and access rules (protecting again reuses them)",
        $(if ($svc.cloudflare.access) { 'Cloudflare Access in front of the application' } elseif ($svc.cloudflare.publish) { 'Cloudflare DNS record and tunnel route' } else { 'Local only: nothing is published' }))
    }
    $items += [ordered]@{ service = $svc.name; displayName = (Get-ProtectDesired $svc).DisplayName; hostname = @($svc.hostnames)[0]; authentik = @(ConvertTo-AkActionView $ak); traefik = $view; notes = $notes; errors = $errors; keeps = $keeps; becomesPublic = $public }
    $stored += [pscustomobject]@{ Service = $svc.name; ChangeBody = ($req.ChangeBody | ConvertTo-Json -Depth 10 -Compress); AkFingerprint = (Get-AkFingerprint $ak); TraefikKey = $plan.TraefikKey; CfFingerprint = $plan.Cloudflare.Fingerprint }
  }
  $id = New-IdpPlanId ([pscustomobject]@{ Kind = $(if ($Remove) { 'unprotect' } else { 'protect' }); Items = $stored; Access = $access })
  $total = @($items | ForEach-Object { $_.errors } | Measure-Object -Sum).Sum
  return [ordered]@{ planId = $id; items = $items; cloudflareAccess = $access; canApply = ($total -eq 0)
    service = $(if ($items.Count -eq 1) { $items[0].service } else { '' }); authentik = $(if ($items.Count -eq 1) { $items[0].authentik } else { @() }); traefik = $(if ($items.Count -eq 1) { $items[0].traefik } else { $null }); notes = $(if ($items.Count -eq 1) { $items[0].notes } else { @() }) }
}

# Applies a protect/unprotect preview, one application after the other (each with its own Traefik backup). An
# application counts as protected only after an unauthenticated request was refused or sent to sign in.
function Invoke-IdentityProtectApply($Body, [switch]$Remove) {
  Assert-Installed
  $p = Use-IdpPlan $Body $(if ($Remove) { 'unprotect' } else { 'protect' })
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  $confirmed = @(@(Get-Field $Body 'confirmOverwrites' @()) | ForEach-Object { [string]$_ })
  # Everything is checked against the current state before anything is changed.
  $prepared = @()
  foreach ($it in $p.Items) {
    $plan = Build-ChangePlan ($it.ChangeBody | ConvertFrom-Json)
    $svc = @($ctx.Services | Where-Object { $_.name -eq $it.Service })[0]
    $akNow = $(if ($Remove) { Remove-AuthentikAppProtection -Conn $ctx.Conn -Service $it.Service -WhatIf } else { (Sync-AuthentikAppProtection -Conn $ctx.Conn -Desired (Get-ProtectDesired $svc) -WhatIf).Actions })
    if ($plan.TraefikKey -ne $it.TraefikKey -or $plan.Cloudflare.Fingerprint -ne $it.CfFingerprint -or (Get-AkFingerprint $akNow) -ne $it.AkFingerprint) { Stop-Request 409 "The configuration, Cloudflare or authentik changed since the preview ($($it.Service)). Preview again." }
    $missing = @($plan.Cloudflare.Actions | Where-Object { $_.Overwrite -and $confirmed -notcontains $_.Id } | ForEach-Object { $_.Id })
    if ($missing.Count) { Stop-Request 400 ('Confirm each overwrite of an existing Cloudflare resource: ' + ($missing -join ', ')) }
    $prepared += [pscustomobject]@{ Item = $it; Plan = $plan; Service = $svc }
  }
  $cfg = $ctx.Config
  $results = @()
  foreach ($x in $prepared) {
    $name = $x.Item.Service
    # Planned again now, against the registry as the previous applications left it: a plan built before them would
    # write their old (unprotected) definitions back. Only this service's definition differs from the current state.
    $plan = Build-ChangePlan ($x.Item.ChangeBody | ConvertFrom-Json)
    $out = [ordered]@{ service = $name; ok = $true; authentik = @(); traefik = $null; challenge = $null; message = '' }
    if (-not $Remove) {
      # authentik first: when the route starts asking authentik, the application and provider must already exist.
      try { $r = Sync-AuthentikAppProtection -Conn $ctx.Conn -Desired (Get-ProtectDesired $x.Service); $out.authentik = @(ConvertTo-AkActionView $r.Actions) }
      catch { $out.ok = $false; $out.message = "authentik: $($_.Exception.Message) The Traefik route was not changed."; $results += $out; continue }
      Set-IdentityApp $cfg $name ([pscustomobject][ordered]@{ slug = $r.Slug; providerPk = $r.ProviderPk; applicationPk = $r.ApplicationPk; initialAccess = $r.Access; protectedAt = (Get-Date -Format 's'); verifiedAt = ''; verifiedBy = '' })
      Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
      # The route switches only once the embedded outpost has loaded the provider (otherwise it would answer 404).
      $wait = Wait-AuthentikOutpost -BaseUrl $ctx.BaseUrl -Hostname (Get-IdentityAppAddress ([string]$cfg.authentik.publicUrl) @($plan.New.hostnames)[0]).HostHeader -Seconds 90
      if (-not $wait.Ready) { $out.ok = $false; $out.message = "authentik's embedded outpost has not loaded the application yet (HTTP $($wait.Status)). The Traefik route was not changed; protect it again in a minute (nothing is created twice)."; $results += $out; continue }
      if ($plan.Traefik.FileChanges -gt 0 -or $plan.Traefik.RegistryChanged) { $out.traefik = Invoke-ChangePlanSteps $plan $confirmed } else { $out.traefik = [ordered]@{ ok = $true; steps = @(); warnings = @() } }
      if (-not $out.traefik.ok) { $out.ok = $false; $out.message = 'Traefik did not accept the change; the route is unchanged.' }
      else {
        # Traefik reloads the route and the outpost reloads its sign-in address a few seconds after a change: until then an
        # anonymous request may still pass ('open') or be sent to the previous address ('misrouted'). Anything else, and
        # either state after the deadline, is reported as not verified.
        $deadline = (Get-Date).AddSeconds(60)
        do { $out.challenge = Test-ForwardAuthChallenge -TraefikPort $ctx.Settings.HttpPort -Hostname @($plan.New.hostnames)[0] -HostPort (Get-IdentityAppAddress ([string]$cfg.authentik.publicUrl) @($plan.New.hostnames)[0]).HostPort -AuthHostname $cfg.authentik.hostname; if ($out.challenge.State -notin 'open', 'misrouted') { break }; Start-Sleep -Seconds 2 } while ((Get-Date) -lt $deadline)
        $State.IdpChecks[$name] = $out.challenge
        if ($out.challenge.State -ne 'auth') { $out.ok = $false; $out.message = "ForwardAuth is not verified: $($out.challenge.Message)" }
        else { $out.message = 'Protected: an unauthenticated request is sent to sign in.' }
      }
    } else {
      # Traefik first: the route stops asking authentik before the outpost stops serving the application.
      if ($plan.Traefik.FileChanges -gt 0 -or $plan.Traefik.RegistryChanged) { $out.traefik = Invoke-ChangePlanSteps $plan $confirmed } else { $out.traefik = [ordered]@{ ok = $true; steps = @(); warnings = @() } }
      if (-not $out.traefik.ok) { $out.ok = $false; $out.message = 'Traefik did not accept the change; protection is unchanged.' }
      else {
        try { $out.authentik = @(ConvertTo-AkActionView (Remove-AuthentikAppProtection -Conn $ctx.Conn -Service $name)) } catch { $out.message = "The route no longer uses authentik, but the outpost assignment could not be removed: $($_.Exception.Message)" }
        Set-IdentityApp $cfg $name $null
        $State.IdpChecks.Remove($name)
      }
    }
    $results += $out
  }
  $allOk = -not @($results | Where-Object { -not $_.ok }).Count
  # Protecting an application ends a deliberate skip of the wizard's protection step.
  if (-not $Remove -and @($results | Where-Object { $_.ok }).Count) { $cfg.protectSkippedAt = '' }
  Set-IdentityProgress $cfg 'apps' $(if ($allOk) { $(if ($Remove) { 'unprotected' } else { 'protected' }) } else { 'failed' }) ((@($results | ForEach-Object { $_.service })) -join ', ')
  Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
  Write-Audit $(if ($Remove) { 'identity-unprotect' } else { 'identity-protect' }) ((@($results | ForEach-Object { "$($_.service) ok=$($_.ok)" })) -join '; ')
  $first = $results[0]
  return [ordered]@{ ok = $allOk; results = $results; authentik = $first.authentik; traefik = $first.traefik; challenge = $first.challenge; message = $(if ($results.Count -eq 1) { $first.message } else { "$(@($results | Where-Object { $_.ok }).Count) of $($results.Count) done." }) }
}

# --- Universal provisioning: Container -> Reverse proxy -> Authentication ----------------------------------------
# A pasted link becomes a draft (lib\AppSources.psm1), reviewed for security and host compatibility
# (lib\ProvisionPolicy.psm1, lib\HostPlatform.psm1) and optionally completed by AI (lib\AiAssist.psm1). One approved
# operation then reuses the existing pipelines: the App Catalog installer (an ordinary Compose project), the service
# planner (explicit Traefik file-provider YAML; Cloudflare DNS, tunnel route and Access through the existing tunnel)
# and Identity & Access through the identity contract below. Each operation keeps a journal (config\provision\
# operations) of what it created, reused or modified; rollback undoes only what the operation created or modified.

function Get-ProvisionDir([string]$Sub) { $d = Join-Path $InstallPath "config\provision\$Sub"; New-Item -ItemType Directory -Force -Path $d | Out-Null; return $d }
function Assert-ProvisionId([string]$Value, [string]$What) { if ($Value -notmatch '^[a-f0-9]{8,32}$') { Stop-Request 400 "Invalid $What." }; return $Value }

function Read-ProvisionDraft([string]$Id) {
  $p = Join-Path (Get-ProvisionDir 'drafts') "$(Assert-ProvisionId $Id 'draft id').json"
  if (-not (Test-Path -LiteralPath $p)) { Stop-Request 404 'This draft no longer exists. Import the link again.' }
  return ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
}
function Save-ProvisionDraft($Draft) { Write-TextFileAtomic (Join-Path (Get-ProvisionDir 'drafts') "$($Draft.draftId).json") (($Draft | ConvertTo-Json -Depth 30) + "`n") }
function Read-ProvisionJournal([string]$Id) {
  $p = Join-Path (Get-ProvisionDir 'operations') "$(Assert-ProvisionId $Id 'operation id').json"
  if (-not (Test-Path -LiteralPath $p)) { Stop-Request 404 'No such provisioning operation.' }
  return (ConvertTo-OrderedTree ([IO.File]::ReadAllText($p) | ConvertFrom-Json))
}
function Save-ProvisionJournal($Journal) { Write-TextFileAtomic (Join-Path (Get-ProvisionDir 'operations') "$($Journal.operationId).json") (($Journal | ConvertTo-Json -Depth 20) + "`n") }

# Names that must never leave this PC in an AI request or a shared recipe: this deployment's domains and host names,
# the Windows user and machine names, and the installation folder.
function Get-ProvisionPrivateNames($Settings) {
  $n = @($env:USERNAME, $env:COMPUTERNAME, $env:USERDOMAIN, $InstallPath)
  try { $cf = Read-CloudflareConfig -Settings $Settings; $n += @($cf.domains | ForEach-Object { [string]$_.name }) } catch { }
  try { $n += @((Read-ServiceRegistry -Settings $Settings).services | ForEach-Object { @($_.hostnames) }) } catch { }
  try { $ic = Read-IdentityConfig -Settings $Settings; $n += @($ic.authentik.hostname, $ic.authentik.owner.email) } catch { }
  return @($n | Where-Object { $_ -and ([string]$_).Length -ge 3 } | ForEach-Object { [string]$_ } | Select-Object -Unique)
}

# The draft as the page shows it: structure (never values of secrets), open questions, evidence, the security review,
# host compatibility, ForwardAuth suitability and whether a curated recipe exists for the same application.
function Get-ProvisionDraftView($Draft) {
  $m = $Draft.manifest
  $adapter = Get-CurrentHostAdapter
  $findings = @(Get-ManifestSecurityFindings $m)
  $compat = Get-HostCompatibility $m $adapter
  $errors = @(Test-AppManifest $m -AllowImported)
  $svcs = @($m.services.PSObject.Properties | ForEach-Object {
      $s = $_.Value
      [ordered]@{ name = $_.Name; role = [string](Get-Prop2 $s 'role' ''); image = [string]$s.image
        ports = @(@(Get-Prop2 $s 'ports' @()) | ForEach-Object { [ordered]@{ container = [int]$_.container; protocol = [string]$_.protocol; primary = [bool](Get-Prop2 $_ 'primary' $false) } })
        volumes = @(@(Get-Prop2 $s 'volumes' @()) | ForEach-Object { [ordered]@{ name = [string]$_.name; kind = [string](Get-Prop2 $_ 'kind' 'volume'); target = [string]$_.target } })
        settings = @(if (Get-Prop2 $s 'environment' $null) { $s.environment.PSObject.Properties | ForEach-Object { $_.Name } })
        dependsOn = @(@(Get-Prop2 $s 'dependsOn' @()) | ForEach-Object { "$($_.service) ($($_.condition))" }) }
    })
  $inputs = @(@(Get-Prop2 $m 'inputs' @()) | ForEach-Object { [ordered]@{ id = [string]$_.id; type = [string]$_.type; label = [string](Get-Prop2 $_ 'label' $_.id); required = [bool](Get-Prop2 $_ 'required' $false); default = $(if ([string]$_.type -in 'text', 'timezone', 'boolean') { [string](Get-Prop2 $_ 'default' '') } else { '' }) } })
  $aiRuns = @(@(Get-Prop2 $Draft 'ai' @()))
  # Import notes exist only on imported drafts; a curated catalog manifest has none.
  $importNotes = Get-Prop2 $m 'draft' $null
  $blocked = @($findings | Where-Object { $_.severity -eq 'block' }).Count -or $errors.Count -or $compat.status -eq 'incompatible' -or -not [bool](Get-Prop2 $m 'installable' $false)
  return [ordered]@{ draftId = $Draft.draftId; createdAt = $Draft.createdAt; url = $Draft.url; kind = $Draft.kind; id = [string]$m.id; name = [string]$m.name; description = [string]$m.description
    license = [string]$m.license; maintainer = [string]$m.maintainer; source = $m.source; docs = @($m.docs); architectures = @(Get-Prop2 $m 'architectures' @())
    services = $svcs; web = (Get-Prop2 $m 'web' $null); inputs = $inputs; privileges = @(Get-Prop2 $m 'privileges' @())
    unresolved = @(Get-Prop2 $importNotes 'unresolved' @()); unsupported = @(Get-Prop2 $importNotes 'unsupported' @()); evidence = @(Get-Prop2 $importNotes 'evidence' @()); assumptions = @(Get-Prop2 $importNotes 'assumptions' @())
    knownIssues = @(Get-Prop2 $m 'knownIssues' @()); verification = (Get-Prop2 $m 'verification' $null); findings = $findings; compatibility = $compat; manifestErrors = $errors
    protection = (Get-ProtectionCompatibility $m); catalogMatch = (Get-Prop2 $Draft 'catalogMatch' $null)
    trust = (Get-RecipeTrust $m); authOptions = (Get-AuthenticationOptions -Manifest $m -IdentityReady $(try { [bool](Get-IdentityContractStatus).readiness.ready } catch { $false })); reused = $false
    ai = [ordered]@{ runs = $aiRuns.Count; usd = [Math]::Round((@($aiRuns | ForEach-Object { [double](Get-Prop2 (Get-Prop2 $_ 'usage' $null) 'usd' 0) }) | Measure-Object -Sum).Sum, 5) }
    deployable = (-not $blocked) }
}

function Get-ProvisionData {
  Assert-Installed
  $settings = Get-Settings
  $drafts = @(Get-ChildItem -LiteralPath (Get-ProvisionDir 'drafts') -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 50 | ForEach-Object {
      try { $d = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json; [ordered]@{ draftId = $d.draftId; name = [string]$d.manifest.name; kind = $d.kind; url = $d.url; createdAt = $d.createdAt; unresolved = @(Get-Prop2 (Get-Prop2 $d.manifest 'draft' $null) 'unresolved' @()).Count } } catch { }
    })
  $ops = @(Get-ChildItem -LiteralPath (Get-ProvisionDir 'operations') -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 20 | ForEach-Object {
      try { $j = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json; [ordered]@{ operationId = $j.operationId; summary = $j.summary; state = $j.state; startedAt = $j.startedAt } } catch { }
    })
  $ai = Read-AiConfig $settings
  $key = Get-ProtectedSecretInfo -Settings $settings -Name (Get-AiKeySecretName)
  $domains = @(); try { $domains = @((Read-CloudflareConfig -Settings $settings).domains | ForEach-Object { [string]$_.name }) } catch { }
  return [ordered]@{ drafts = $drafts; operations = $ops; domains = $domains; host = (Get-CurrentHostAdapter); hosts = @(Get-HostAdapters | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; status = $_.status; tested = $_.tested } })
    sources = @('Docker Hub (hub.docker.com links or image names)', 'GitHub repositories and Compose files', 'GitHub Container Registry, Quay and lscr.io image names', 'Unraid template XML (raw links or pasted)', 'Compose files (pasted: a main file and up to 3 overrides)', 'awesome-selfhosted entries')
    ai = [ordered]@{ provider = $ai.provider; model = $ai.model; escalationModel = $ai.escalationModel; allowEscalation = [bool]$ai.allowEscalation; monthlyLimitUsd = $ai.monthlyLimitUsd; perRequestLimitUsd = $ai.perRequestLimitUsd; maxOutputTokens = $ai.maxOutputTokens
      keyStored = [bool]$key.Stored; providers = @(Get-AiProviders); prices = (Get-AiPrices); month = (Get-AiMonthSpend (Read-AiUsage $settings) ([double]$ai.monthlyLimitUsd)) }
    identity = (Get-IdentityContractStatus); recipes = @(Get-LocalRecipes $settings).Count; registry = (Get-RecipeRegistryInfo) }
}

function Invoke-ProvisionImport($Body) {
  Assert-Installed
  $url = ([string](Get-Field $Body 'url' '')).Trim()
  # Pasted text instead of a link: Compose (main file + overrides) or an Unraid template, with an optional project link.
  $texts = @(@(Get-Field $Body 'texts' @()) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
  $one = [string](Get-Field $Body 'text' '')
  if ($one.Trim()) { $texts = @($one) + $texts }
  if (-not $url -and -not $texts.Count) { Stop-Request 400 'Paste a link, an image name, a Compose file or an Unraid template.' }
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  $r = $null
  try {
    if ($texts.Count) { $r = Import-AppSourceText -Format ([string](Get-Field $Body 'format' 'auto')) -Texts $texts -SourceUrl ([string](Get-Field $Body 'sourceUrl' '')) -Name ([string](Get-Field $Body 'name' '')) -CatalogApps $catalog }
    else { $r = Import-AppSource -Text $url -CatalogApps $catalog }
  } catch { Stop-Request 422 $_.Exception.Message }
  # Importing the same link or text again returns the existing draft instead of a duplicate.
  foreach ($f in @(Get-ChildItem -LiteralPath (Get-ProvisionDir 'drafts') -Filter '*.json' -File)) {
    try { $old = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
    if ([string](Get-Prop2 $old 'importKey' '') -eq $r.ImportKey) { $v = Get-ProvisionDraftView $old; $v.reused = $true; return $v }
  }
  $draft = [ordered]@{ version = 1; draftId = (New-SecretValue 8); createdAt = (Get-Date -Format 's'); url = $(if ($texts.Count) { [string](Get-Field $Body 'sourceUrl' '') } else { $url }); kind = $r.Kind; importKey = $r.ImportKey; catalogMatch = $r.CatalogMatch; manifest = $r.Manifest; ai = @() }
  $saved = ($draft | ConvertTo-Json -Depth 30) | ConvertFrom-Json
  Save-ProvisionDraft $saved
  Write-Audit 'provision-import' "$($r.Kind) $($r.Manifest.id) draft=$($draft.draftId)"
  return (Get-ProvisionDraftView $saved)
}

# A curated catalog application as a New app draft: the same review, plan, apply (install -> backend check -> route ->
# authentik -> publish -> verify), journal and rollback as imported applications, with the catalog's own manifest.
function Invoke-ProvisionCatalogDraft($Body) {
  Assert-Installed
  $appId = [string](Get-Field $Body 'appId' '')
  try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $appId } catch { Stop-Request 404 $_.Exception.Message }
  if ((Get-ManifestAvailability $m) -ne 'offered' -or -not [bool](Get-Prop2 $m 'installable' $false)) { Stop-Request 409 "$($m.name) is not offered for installation." }
  if ([bool](Get-Prop2 $m.web 'headless' $false) -or -not [bool](Get-Prop2 $m.web 'proxy' $true)) { Stop-Request 409 "$($m.name) is never routed or published (no web interface on the shared network): install it from the App Catalog." }
  $draft = [ordered]@{ version = 1; draftId = (New-SecretValue 8); createdAt = (Get-Date -Format 's'); url = [string](Get-Prop2 $m.source 'url' ''); kind = 'catalog'; catalogId = [string]$m.id; catalogMatch = $null; manifest = $m; ai = @() }
  $saved = ($draft | ConvertTo-Json -Depth 30) | ConvertFrom-Json
  Save-ProvisionDraft $saved
  Write-Audit 'provision-catalog' "$($m.id) draft=$($draft.draftId)"
  return (Get-ProvisionDraftView $saved)
}

function Invoke-ProvisionDraftEdit($Body) {
  Assert-Installed
  $d = Read-ProvisionDraft ([string](Get-Field $Body 'draftId' ''))
  $tree = ConvertTo-OrderedTree $d.manifest
  try { $tree = Set-DraftWebPort $tree ([string](Get-Field $Body 'webService' '')) ([int](Get-Field $Body 'webPort' 0)) ([string](Get-Field $Body 'protocol' 'http')) } catch { Stop-Request 400 $_.Exception.Message }
  $d.manifest = ($tree | ConvertTo-Json -Depth 30) | ConvertFrom-Json
  Save-ProvisionDraft $d
  return (Get-ProvisionDraftView $d)
}

function Remove-ProvisionDraftRequest($Body) {
  $id = Assert-ProvisionId ([string](Get-Field $Body 'draftId' '')) 'draft id'
  $p = Join-Path (Get-ProvisionDir 'drafts') "$id.json"
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
  return [ordered]@{ removed = $true }
}

# --- AI assistance (optional, approved per request) ---

function Get-ProvisionDocumentation($Manifest) {
  $kind = [string](Get-Prop2 $Manifest.source 'kind' ''); $url = [string](Get-Prop2 $Manifest.source 'url' ''); $up = [string](Get-Prop2 $Manifest.source 'upstream' '')
  $text = ''
  if ($kind -eq 'dockerhub' -and $url -match 'hub\.docker\.com/(?:_/|r/)([^/?#]+)(?:/([^/?#]+))?') {
    $repo = $(if ($Matches[2]) { "$($Matches[1])/$($Matches[2])" } else { "library/$($Matches[1])" })
    try { $text = [string](Invoke-SafeJson -Url "https://hub.docker.com/v2/repositories/$repo/").full_description } catch { }
  }
  $gh = @($url, $up) | Where-Object { $_ -match '^https://github\.com/[^/]+/[^/]+' } | Select-Object -First 1
  if (-not $text -and $gh -and $gh -match '^https://github\.com/([^/]+)/([^/#?]+)') {
    try { $rd = Invoke-SafeJson -Url "https://api.github.com/repos/$($Matches[1])/$($Matches[2] -replace '\.git$', '')/readme"; if ([string]$rd.download_url) { $text = (Invoke-SafeFetch -Url ([string]$rd.download_url) -MaxBytes 512KB).Text } } catch { }
  }
  return $text
}

function Invoke-ProvisionAiEstimate($Body) {
  Assert-Installed
  $settings = Get-Settings
  $cfg = Read-AiConfig $settings
  if ($cfg.provider -eq 'none') { Stop-Request 409 'AI assistance is off. Turn it on with your own API key, or answer the open questions yourself.' }
  $d = Read-ProvisionDraft ([string](Get-Field $Body 'draftId' ''))
  if (-not @(Get-Prop2 (Get-Prop2 $d.manifest 'draft' $null) 'unresolved' @()).Count) { Stop-Request 409 'This draft has no open questions; AI is not needed.' }
  $req = New-AiPlanningRequest -Manifest $d.manifest -Documentation (Get-ProvisionDocumentation $d.manifest) -PrivateNames (Get-ProvisionPrivateNames $settings) -MaxChars $cfg.maxContextChars
  $escalate = [bool](Get-Field $Body 'escalate' $false)
  if ($escalate -and -not $cfg.allowEscalation) { Stop-Request 400 'Escalation to the larger model is not allowed in your AI settings.' }
  $model = $(if ($escalate) { $cfg.escalationModel } else { $cfg.model })
  $est = Get-AiCostEstimate $req $model $cfg.maxOutputTokens
  $spend = Get-AiMonthSpend (Read-AiUsage $settings) ([double]$cfg.monthlyLimitUsd)
  $budget = Test-AiBudget $est $cfg $spend
  foreach ($k in @($State.AiEstimates.Keys)) { if (((Get-Date) - $State.AiEstimates[$k].Created).TotalMinutes -gt 15) { $State.AiEstimates.Remove($k) } }
  $id = New-SecretValue 8
  $State.AiEstimates[$id] = [pscustomobject]@{ Created = (Get-Date); DraftId = $d.draftId; Request = $req; Model = $model; Estimate = $est }
  return [ordered]@{ estimateId = $id; provider = $cfg.provider; model = $model; estimate = $est; budget = $budget; month = $spend; redacted = $req.Removed
    preview = [ordered]@{ system = $req.System; user = $req.User; chars = $req.Chars } }
}

function Invoke-ProvisionAiRun($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $id = [string](Get-Field $Body 'estimateId' '')
  if (-not $State.AiEstimates.ContainsKey($id)) { Stop-Request 409 'This estimate has expired or was used. Estimate again.' }
  $e = $State.AiEstimates[$id]; $State.AiEstimates.Remove($id)
  $cfg = Read-AiConfig $settings
  $budget = Test-AiBudget $e.Estimate $cfg (Get-AiMonthSpend (Read-AiUsage $settings) ([double]$cfg.monthlyLimitUsd))
  if (-not $budget.ok) { Stop-Request 409 $budget.reason }
  $d = Read-ProvisionDraft $e.DraftId
  $key = ''
  if ((Get-ProtectedSecretInfo -Settings $settings -Name (Get-AiKeySecretName)).Stored) { $key = Read-ProtectedSecret -Settings $settings -Name (Get-AiKeySecretName) }
  $res = $null
  try { $res = Invoke-AiPlanning -Settings $settings -Request $e.Request -Model $e.Model -MaxOutputTokens $cfg.maxOutputTokens -ApiKey $key -Provider $cfg.provider } catch { $key = $null; Stop-Request 502 $_.Exception.Message }
  $key = $null
  $merged = Merge-AiProposal (ConvertTo-OrderedTree $d.manifest) $res.Proposal
  $d.manifest = ($merged.Manifest | ConvertTo-Json -Depth 30) | ConvertFrom-Json
  $run = [ordered]@{ at = (Get-Date -Format 's'); model = $res.Model; cached = $res.Cached; usage = $res.Usage; applied = @($merged.Applied); rejected = @($merged.Rejected); summary = [string](Get-Prop2 $res.Proposal 'summary' '') }
  $d.ai = @(@(Get-Prop2 $d 'ai' @()) + [pscustomobject]$run)
  Save-ProvisionDraft $d
  Write-Audit 'provision-ai' "draft=$($d.draftId) model=$($res.Model) cached=$($res.Cached) usd=$($res.Usage.usd)"
  return [ordered]@{ run = $run; draft = (Get-ProvisionDraftView $d) }
}

function Set-ProvisionAiSettingsRequest($Body) {
  Assert-Installed
  $settings = Get-Settings
  $c = Read-AiConfig $settings
  $prov = [string](Get-Field $Body 'provider' $c.provider)
  if ($prov -notin 'none', 'anthropic') { Stop-Request 400 'Provider must be none or anthropic (other providers are not implemented).' }
  $prices = Get-AiPrices
  foreach ($k in @('model', 'escalationModel')) { $v = [string](Get-Field $Body $k $c[$k]); if (-not $prices.Contains($v)) { Stop-Request 400 "Unknown model '$v'." }; $c[$k] = $v }
  $c.provider = $prov
  $c.allowEscalation = [bool](Get-Field $Body 'allowEscalation' $c.allowEscalation)
  foreach ($k in @('monthlyLimitUsd', 'perRequestLimitUsd')) { $v = 0.0; if ([double]::TryParse([string](Get-Field $Body $k $c[$k]), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $c[$k] = $v } else { Stop-Request 400 "$k must be a number." } }
  $mt = 0; if ([int]::TryParse([string](Get-Field $Body 'maxOutputTokens' $c.maxOutputTokens), [ref]$mt)) { $c.maxOutputTokens = $mt }
  Save-AiConfig $settings $c
  Write-Audit 'provision-ai-settings' "provider=$($c.provider) model=$($c.model) monthly=$($c.monthlyLimitUsd)"
  return (Read-AiConfig $settings)
}

function Save-ProvisionAiKeyRequest($Body) {
  Assert-Installed
  $k = ([string](Get-Field $Body 'key' '')).Trim()
  if ($k -notmatch '^sk-ant-[A-Za-z0-9_-]{20,200}$') { Stop-Request 400 'That does not look like an Anthropic API key (sk-ant-...). A Claude subscription is not an API key.' }
  Save-ProtectedSecret -Settings (Get-Settings) -Name (Get-AiKeySecretName) -Value $k -Label 'Anthropic API key (AI assistance)'
  $k = $null
  Write-Audit 'provision-ai-key' 'saved'
  return [ordered]@{ stored = $true }
}

# --- Identity contract (docs/provisioning.md). The provisioner calls only these; they wrap Identity & Access. ---

# 1 + 2. Providers and readiness, from the same context the Identity & Access page uses.
function Get-IdentityContractStatus {
  $ctx = $null
  try { $ctx = Get-IdentityContext } catch { return [ordered]@{ providers = @(Get-ContractProviders @(Get-IdentityProviders) (Get-IdentityReadiness @{ provider = '' })); readiness = (Get-IdentityReadiness @{ provider = '' }) } }
  $ov = $null; if ($ctx.Conn) { try { $ov = Get-AuthentikOverview $ctx.Conn } catch { } }
  $owners = $false; if ($ctx.Conn) { try { $owners = [bool](Get-AuthentikGroup $ctx.Conn (Get-AuthentikOwnersGroupName)) } catch { } }
  $facts = [ordered]@{ provider = [string]$ctx.Config.provider; installFound = [bool]$ctx.Install; running = [bool]($ctx.Install -and $ctx.Install.server -and $ctx.Install.server.state -eq 'running')
    onProxyNetwork = [bool]($ctx.Install -and $ctx.Install.onProxyNetwork); tokenOk = [bool]$ctx.Conn; outpost = [bool]($ov -and $ov.Outpost)
    outpostBrowserHostOk = $false; publicUrl = [string]$ctx.Config.authentik.publicUrl; ownersGroup = $owners }
  $ready = Get-IdentityReadiness $facts
  return [ordered]@{ providers = @(Get-ContractProviders @(Get-IdentityProviders) $ready); readiness = $ready; endpoint = $(if ($ctx.Install) { "http://$($ctx.Install.serverContainer):9000" } else { '' }); publicUrl = [string]$ctx.Config.authentik.publicUrl }
}

# 3 + 4. Whether an application can be protected and what protecting it would change in authentik (read-only).
function Get-IdentityProtectionPreview([string]$ServiceName, [string]$Hostname, [string]$DisplayName) {
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  if ($Hostname -and $ctx.Config.authentik.hostname -and $Hostname -eq $ctx.Config.authentik.hostname) { Stop-Request 400 "$Hostname is authentik's own sign-in address; it cannot be protected by authentik." }
  $desired = [pscustomobject]@{ Service = $ServiceName; DisplayName = $DisplayName; Hostname = $Hostname; PublicUrl = [string]$ctx.Config.authentik.publicUrl; ExternalUrl = (Get-IdentityAppAddress ([string]$ctx.Config.authentik.publicUrl) $Hostname).Url }
  $r = Sync-AuthentikAppProtection -Conn $ctx.Conn -Desired $desired -WhatIf
  return [ordered]@{ actions = @(ConvertTo-AkActionView $r.Actions); reuses = @($r.Actions | Where-Object { $_.Kind -eq 'none' } | ForEach-Object { "$($_.Object) $($_.Name)" }); creates = @($r.Actions | Where-Object { $_.Kind -eq 'create' } | ForEach-Object { "$($_.Object) $($_.Name)" }) }
}

# 5. Protection through the existing protect pipeline (authentik first, wait for the outpost, then the route), so the
# result is exactly what the Identity & Access page would have done. Returns the apply result and what was created.
function Request-IdentityProtection([string]$ServiceName) {
  $plan = Invoke-IdentityProtectPlan ([pscustomobject]@{ services = @($ServiceName); cloudflareAccess = 'keep' })
  if (-not $plan.canApply) { throw "The protection preview has errors: $((@($plan.items | ForEach-Object { @($_.traefik.traefik.issues) | ForEach-Object { $_.Message } })) -join ' ')" }
  $res = Invoke-IdentityProtectApply ([pscustomobject]@{ planId = $plan.planId; confirm = $true; confirmOverwrites = @() })
  $first = @($res.results)[0]
  return [ordered]@{ ok = [bool]$res.ok; message = [string]$res.message; challenge = $first.challenge
    # The action views are ordered dictionaries (ConvertTo-AkActionView): read their keys directly (Get-Prop2 reads
    # object properties only, which left every name blank and recorded created objects as reused, so a rollback kept them).
    created = @(@($first.authentik) | ForEach-Object { $v = $_; $g = { param($k) [string]$(if ($v -is [System.Collections.IDictionary]) { $v[$k] } else { Get-Prop2 $v $k '' }) }; if ((& $g 'kind') -eq 'create') { "$(& $g 'object') $(& $g 'name')" } })
    authentik = @($first.authentik) }
}

# 6. Verification: one anonymous request through Traefik must be sent to sign in.
function Test-IdentityProtection([string]$Hostname) {
  $settings = Get-Settings
  $cfg = Read-IdentityConfig -Settings $settings
  return (Test-ForwardAuthChallenge -TraefikPort $settings.HttpPort -Hostname $Hostname -HostPort (Get-IdentityAppAddress ([string]$cfg.authentik.publicUrl) $Hostname).HostPort -AuthHostname $cfg.authentik.hostname)
}

# 7. Rollback of protection set up by one operation: the route stops asking authentik (Traefik first), then the
# provider is unassigned from the outpost; the authentik application and provider are deleted only when this
# operation created both. The outpost, flows, Google source, owners group and other applications are never touched.
function Undo-IdentityProtection([string]$ServiceName, [bool]$CreatedByOperation) {
  $ctx = Get-IdentityContext
  Assert-IdentityConnection $ctx
  $svc = @($ctx.Services | Where-Object { $_.name -eq $ServiceName })[0]
  $out = @()
  if ($svc -and $svc.PSObject.Properties['auth'] -and $svc.auth.provider -eq 'authentik') {
    $req = Get-ProtectRequest $ServiceName $ctx 'keep' -Remove
    $plan = Build-ChangePlan $req.ChangeBody
    $r = Invoke-ChangePlanSteps $plan @()
    if (-not $r.ok) { throw 'Traefik did not accept removing the ForwardAuth middleware.' }
    $out += 'Route: ForwardAuth middleware removed'
  }
  $acts = @(Remove-AuthentikAppProtection -Conn $ctx.Conn -Service $ServiceName -DeleteObjects:$CreatedByOperation)
  $out += @($acts | Where-Object { $_.Kind -ne 'none' } | ForEach-Object { $_.Summary })
  $cfg = Read-IdentityConfig -Settings $ctx.Settings
  Set-IdentityApp $cfg $ServiceName $null
  Save-IdentityConfig -Settings $ctx.Settings -Config $cfg
  $State.IdpChecks.Remove($ServiceName)
  return $out
}

# --- Plan, apply, verify, roll back ---

# The service route of a provisioned app: an explicit file-provider definition pointing at the web container by its
# Compose service DNS name on the shared network (stable across container recreation).
function New-ProvisionService($AppPlan, $Manifest, [string]$Hostname, [bool]$Publish, [bool]$Access, [string]$AuthEndpoint = '') {
  $web = [string]$Manifest.web.service
  $primary = @(@($Manifest.services.$web.ports) | Where-Object { $_.PSObject.Properties['primary'] -and $_.primary })[0]
  $svc = [pscustomobject][ordered]@{ name = $AppPlan.project; displayName = ([string]$Manifest.name).Substring(0, [Math]::Min(80, ([string]$Manifest.name).Length)); description = "Provisioned from $([string](Get-Prop2 $Manifest.source 'kind' 'catalog'))"
    enabled = $true; hostnames = @($Hostname); middlewares = @('default-headers@file')
    target = [pscustomobject]@{ type = 'docker'; host = $AppPlan.container; port = [int]$primary.container; protocol = [string]$primary.protocol; tlsSkipVerify = ([string]$primary.protocol -eq 'https') }
    cloudflare = [pscustomobject]@{ publish = $Publish; access = $Access } }
  if ($AuthEndpoint) { $svc | Add-Member -NotePropertyName auth -NotePropertyValue ([pscustomobject]@{ provider = 'authentik'; endpoint = $AuthEndpoint }) }
  return $svc
}

function Invoke-ProvisionPlan($Body) {
  Assert-Installed
  $settings = Get-Settings
  $draftId = [string](Get-Field $Body 'draftId' ''); $appId = [string](Get-Field $Body 'appId' '')
  $imported = [bool]$draftId
  $d = $null
  if ($imported) {
    $d = Read-ProvisionDraft $draftId; $m = $d.manifest
    # A catalog draft installs the curated manifest itself (not an imported copy).
    if ([string](Get-Prop2 $d 'catalogId' '')) { $imported = $false; try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id ([string]$d.catalogId) } catch { Stop-Request 404 $_.Exception.Message } }
  }
  elseif ($appId) { try { $m = Get-CatalogApp -CatalogDir $CatalogDir -Id $appId } catch { Stop-Request 404 $_.Exception.Message } }
  else { Stop-Request 400 'Choose an imported draft or a catalog application.' }
  $access = [string](Get-Field $Body 'access' 'local')
  if ($access -notin 'local', 'lan', 'public') { Stop-Request 400 'Access must be local, lan or public (remote-server access is not implemented in this version).' }
  $auth = [string](Get-Field $Body 'auth' $(if ($access -eq 'local') { 'none' } else { 'authentik' }))
  if ($auth -notin 'authentik', 'cloudflare-access', 'native', 'none', 'authelia') { Stop-Request 400 'Unknown authentication choice.' }
  $hostname = ([string](Get-Field $Body 'hostname' '')).Trim().ToLowerInvariant()
  $ack = @(@(Get-Field $Body 'acknowledge' @()) | ForEach-Object { [string]$_ })
  $blockers = New-Object System.Collections.ArrayList; $warnings = New-Object System.Collections.ArrayList
  $cf = Read-CloudflareConfig -Settings $settings
  $cfReady = [bool]($cf.tunnelId -and (Get-CloudflareApiTokenInfo -Settings $settings).Stored)
  if ($access -ne 'local') {
    if ($hostname -notmatch '^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { Stop-Request 400 'Enter a host name such as app.example.com.' }
    if ($access -eq 'public') {
      $zones = @($cf.domains | ForEach-Object { [string]$_.name })
      if (-not @($zones | Where-Object { $hostname -eq $_ -or $hostname.EndsWith(".$_") }).Count) { Stop-Request 400 "$hostname is not in a Cloudflare domain of this deployment ($(if ($zones.Count) { $zones -join ', ' } else { 'none connected' }))." }
      if (-not $cfReady) { $null = $blockers.Add('Cloudflare is not connected (API token and tunnel), so the hostname cannot be published. Connect it on the Cloudflare page, or choose LAN access.') }
    } else { $null = $warnings.Add("Traefik in this deployment listens on 127.0.0.1 only: the route $hostname works on this PC; other devices on your network reach it only after Traefik is configured to listen on the LAN (not changed here).") }
  }
  # 1. Container: security review, host compatibility, then the regular installation preview.
  $findings = @(if ($imported) { Get-ManifestSecurityFindings $m } else { @() })
  $compat = Get-HostCompatibility $m (Get-CurrentHostAdapter)
  if ($compat.status -eq 'incompatible') { foreach ($i in @($compat.items | Where-Object { $_.level -eq 'incompatible' })) { $null = $blockers.Add($i.message) } }
  $acks = Test-FindingsAcknowledged $findings $ack
  foreach ($b in @($findings | Where-Object { $_.severity -eq 'block' })) { $null = $blockers.Add($b.message) }
  # A draft that is not installable (or invalid) stops here: the installation preview needs a complete manifest.
  $early = $false
  if ($imported) { $errs = @(Test-AppManifest $m -AllowImported); foreach ($x in $errs) { $null = $blockers.Add("Manifest: $x"); $early = $true } }
  if ($imported -and -not [bool](Get-Prop2 $m 'installable' $false)) { $null = $blockers.Add("Not installable yet: $(Get-Prop2 $m 'installNote' 'answer the open questions first.')"); $early = $true }
  if ($early) {
    return [ordered]@{ planId = ''; canApply = $false; blockers = @($blockers); warnings = @($warnings); findings = $findings; compatibility = $compat; acknowledgements = $acks }
  }
  $appBody = [pscustomobject]@{ appId = [string]$m.id; startNow = $true; anotherInstance = [bool](Get-Field $Body 'anotherInstance' $false); instanceLabel = [string](Get-Field $Body 'instanceLabel' '') }
  foreach ($k in @('project', 'folder', 'localPort', 'timezone', 'inputs', 'reuseData')) { $v = Get-Field $Body $k $null; if ($null -ne $v) { $appBody | Add-Member -NotePropertyName $k -NotePropertyValue $v } }
  # A sign-in in front of the route is only a protection if nothing else reaches the application: no direct web port
  # on this PC (127.0.0.1:<port> would bypass ForwardAuth or Access). It is opened through its host name only.
  if ($access -ne 'local' -and $auth -in 'authentik', 'cloudflare-access') {
    $appBody | Add-Member -NotePropertyName localPort -NotePropertyValue 0 -Force
    $null = $warnings.Add("No direct web port is published on this PC: it would bypass the $(if ($auth -eq 'authentik') { 'authentik' } else { 'Cloudflare Access' }) sign-in. Open the application through $hostname.")
  }
  $app = Invoke-AppPlan $appBody $(if ($imported) { $m } else { $null })
  foreach ($c in @($app.checks | Where-Object { $_.state -eq 'failed' })) { $null = $blockers.Add("$($c.label): $($c.message)") }
  # Imported images already running elsewhere on this PC (same repository as the web service): never a silent duplicate.
  if ($imported) {
    $repo = ([string]$m.services.($m.web.service).image -replace '@sha256:.*$', '' -replace ':[^:/]+$', '')
    $running = @(Get-ComposeContainerFacts | Where-Object { ([string]$_.image -replace '@sha256:.*$', '' -replace ':[^:/]+$', '') -eq $repo })
    if ($running.Count -and -not $appBody.anotherInstance) { $null = $blockers.Add("$repo already runs on this PC ($(@($running | ForEach-Object { $_.name }) -join ', ')). Manage or adopt it on the Installed apps page, or choose to install another, separate instance.") }
  }
  # 2. Reverse proxy and Cloudflare: the final route as one regular change plan (preview only; nothing is written).
  $identity = Get-IdentityContractStatus
  $protect = Get-ProtectionCompatibility $m
  $options = @(Get-ProvisionAuthOptions $access $identity.readiness $cfReady $protect)
  $opt = @($options | Where-Object { $_.id -eq $auth })[0]
  if (-not $opt -or -not $opt.available) { $null = $blockers.Add("Authentication '$auth' is not available: $(if ($opt) { $opt.reason } else { 'unknown' })") }
  elseif ($opt.requiresAck -and $ack -notcontains "auth:$auth") { $null = $blockers.Add("Acknowledge: $($opt.reason)") }
  $route = $null; $identityPreview = $null
  if ($access -ne 'local') {
    $svcName = $app.project
    if (@((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.name -eq $svcName }).Count) { $null = $blockers.Add("A service route named '$svcName' already exists; choose another project name.") }
    $final = New-ProvisionService $app $m $hostname ($access -eq 'public') ($auth -eq 'cloudflare-access') $(if ($auth -eq 'authentik') { [string]$identity.endpoint } else { '' })
    try {
      $plan = Build-ChangePlan ([pscustomobject]@{ op = 'add'; name = $svcName; service = $final; cloudflare = [pscustomobject]@{ automate = ($access -eq 'public' -and $cfReady); accessEmails = @(); cleanup = $true } })
      $route = ConvertTo-PlanView $plan ''
      foreach ($i in @($route.traefik.issues | Where-Object { $_.Level -eq 'Error' -and $_.Message -notmatch 'No such container|not found|does not exist' })) { $null = $blockers.Add("Traefik: $($i.Message)") }
      foreach ($e in @($route.cloudflare.errors)) { $null = $blockers.Add("Cloudflare: $e") }
      foreach ($a in @($route.cloudflare.actions | Where-Object { $_.Overwrite })) { $null = $warnings.Add("Cloudflare: $($a.Summary) overwrites an existing resource; it needs your explicit confirmation.") }
    } catch { $null = $blockers.Add("Route: $($_.Exception.Message)") }
    if ($auth -eq 'authentik' -and $opt -and $opt.available) {
      try { $identityPreview = Get-IdentityProtectionPreview $svcName $hostname ([string]$m.name) } catch { $null = $blockers.Add("authentik: $($_.Exception.Message)") }
      if ($protect.forwardAuth -eq 'caution') { $null = $warnings.Add("ForwardAuth: $($protect.recommendation)") }
      if ($access -eq 'lan') { $null = $warnings.Add('authentik sends browsers to the public sign-in page and back to this host name: the host name must resolve for the browsers that use it.') }
    }
  }
  if (-not $acks.ok) { foreach ($x in $acks.missing) { $null = $blockers.Add("Review and acknowledge: $(@($findings | Where-Object { $_.id -eq $x })[0].message)") } }
  $aiRuns = @(if ($d) { @(Get-Prop2 $d 'ai' @()) })
  $steps = @('Write the Compose project and start it (images pinned by digest; only the web port on 127.0.0.1)', 'Check that the containers and their dependencies are healthy and the web interface answers')
  if ($access -ne 'local') { $steps += "Add the Traefik route $hostname (explicit file-provider YAML)$(if ($access -eq 'public') { ', not public yet' })" }
  if ($auth -eq 'authentik') { $steps += 'Protect it with authentik (application, provider, owner-only access, outpost), then verify that anonymous visitors are sent to sign in' }
  if ($access -eq 'public') { $steps += "Publish $hostname through the existing Cloudflare Tunnel$(if ($auth -eq 'cloudflare-access') { ' behind Cloudflare Access' })" }
  $steps += 'Verify every stage and record the result'
  $canApply = [bool]($app.canApply -and -not $blockers.Count)
  $planId = ''
  if ($canApply) {
    foreach ($k in @($State.ProvisionPlans.Keys)) { if (((Get-Date) - $State.ProvisionPlans[$k].Created).TotalMinutes -gt 15) { $State.ProvisionPlans.Remove($k) } }
    $planId = New-SecretValue 8
    $State.ProvisionPlans[$planId] = [pscustomobject]@{ Created = (Get-Date); DraftId = $draftId; AppId = $appId; Imported = $imported; AppPlanId = $app.planId; Access = $access; Auth = $auth; Hostname = $hostname
      Project = $app.project; Container = $app.container; Manifest = $m; Endpoint = [string]$identity.endpoint; CfReady = $cfReady; Name = [string]$m.name; Volumes = @($app.volumes); Folder = $app.folder }
  }
  return [ordered]@{ planId = $planId; canApply = $canApply; blockers = @($blockers); warnings = @($warnings); steps = $steps
    container = $app; findings = $findings; acknowledgements = $acks; compatibility = $compat
    routing = $route; authentication = [ordered]@{ choice = $auth; options = $options; protection = $protect; identity = $identityPreview; readiness = $identity.readiness }
    access = [ordered]@{ choice = $access; hostname = $hostname; cloudflareReady = $cfReady }
    ai = [ordered]@{ runs = $aiRuns.Count; usd = [Math]::Round((@($aiRuns | ForEach-Object { [double](Get-Prop2 (Get-Prop2 $_ 'usage' $null) 'usd' 0) }) | Measure-Object -Sum).Sum, 5); note = 'No AI is used during deployment.' } }
}

# Runs an approved plan stage by stage. A stage that fails stops the operation; nothing later runs, and the journal
# says what exists so far. An app chosen for authentik protection is published only after protection is verified.
function Invoke-ProvisionApply($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $planId = [string](Get-Field $Body 'planId' '')
  if (-not $State.ProvisionPlans.ContainsKey($planId)) { Stop-Request 409 'This review has expired or was already used. Review again.' }
  $p = $State.ProvisionPlans[$planId]; $State.ProvisionPlans.Remove($planId)
  $confirmed = @(@(Get-Field $Body 'confirmOverwrites' @()) | ForEach-Object { [string]$_ })
  $j = New-ProvisionJournal (New-SecretValue 8) "$($p.Name) as $($p.Project)$(if ($p.Hostname) { " at $($p.Hostname)" }) ($($p.Access), $($p.Auth))"
  $j.plan = [ordered]@{ draftId = $p.DraftId; appId = $p.AppId; project = $p.Project; access = $p.Access; auth = $p.Auth; hostname = $p.Hostname; container = $p.Container }
  $fail = { param($stage, $msg) Add-JournalStage $j $stage 'failed' $msg; $j.state = 'failed'; Save-ProvisionJournal $j; Write-Audit 'provision-apply' "$($j.operationId) failed at $stage" }
  Save-ProvisionJournal $j
  # Stage 1: the Compose project (the regular App Catalog installer, with the imported manifest).
  $res = $null
  try { $res = Invoke-AppApply ([pscustomobject]@{ planId = $p.AppPlanId; confirm = $true; confirmPrivileges = [bool](Get-Field $Body 'confirmPrivileges' $false) }) }
  catch { & $fail 'install' $_.Exception.Message; return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j } }
  Add-JournalResource $j 'compose-project' $p.Project 'created' $res.folder ([ordered]@{ action = 'app-remove'; project = $p.Project })
  foreach ($v in @($p.Volumes)) { Add-JournalResource $j 'data-volume' $v 'created' '' ([ordered]@{ action = 'volume'; name = $v }) }
  if ($p.Imported) {
    # The imported manifest is kept next to compose.yaml so start, update, backup and removal know the application.
    $mf = Join-Path $res.folder '.dtc-manifest.json'
    [IO.File]::WriteAllText($mf, (($p.Manifest | ConvertTo-Json -Depth 30) + "`n"), (New-Object Text.UTF8Encoding($false)))
    Save-AppsRegistry $settings @(Read-AppsRegistry $settings | ForEach-Object { if ($_.project -eq $p.Project) { $_ | Add-Member -NotePropertyName manifestFile -NotePropertyValue '.dtc-manifest.json' -Force; $_ | Add-Member -NotePropertyName source -NotePropertyValue ([string](Get-Prop2 $p.Manifest.source 'kind' 'imported')) -Force }; $_ })
  }
  if (-not $res.ok) { & $fail 'install' (@($res.steps | Where-Object { $_.status -eq 'Failed' } | ForEach-Object { "$($_.name): $($_.message)" }) -join ' '); return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j; install = $res } }
  Add-JournalStage $j 'install' 'passed' "Project $($p.Project) in $($res.folder)"
  $httpOk = [bool]($res.health -and $res.health.http -and $res.health.http.result -in 'http', 'https')
  if (-not $httpOk) { & $fail 'backend' "The web interface of $($p.Container) did not answer: $(if ($res.health -and $res.health.http) { $res.health.http.detail } else { 'no answer' })"; return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j; install = $res } }
  Add-JournalStage $j 'backend' 'passed' "$($p.Container) answers"
  Save-ProvisionJournal $j
  if ($p.Access -ne 'local') {
    # Stage 2: the route, not public yet (and without authentication: protection is added by Identity & Access).
    $first = New-ProvisionService ([pscustomobject]@{ project = $p.Project; container = $p.Container }) $p.Manifest $p.Hostname $false $false ''
    $rp = Build-ChangePlan ([pscustomobject]@{ op = 'add'; name = $p.Project; service = $first; cloudflare = [pscustomobject]@{ automate = $false } })
    $rr = Invoke-ChangePlanSteps $rp @()
    if (-not $rr.ok) { & $fail 'route' 'Traefik did not accept the route.'; return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j } }
    Add-JournalResource $j 'traefik-route' $p.Project 'created' "svc-$($p.Project).yml" ([ordered]@{ action = 'service-remove'; service = $p.Project })
    Add-JournalStage $j 'route' 'passed' "$($p.Hostname) -> $($p.Container)"
    Save-ProvisionJournal $j
    # Stage 3: authentik protection through the identity contract.
    if ($p.Auth -eq 'authentik') {
      $pr = $null
      try { $pr = Request-IdentityProtection $p.Project } catch { & $fail 'authentication' $_.Exception.Message; return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j } }
      $createdAk = @($pr.created)
      Add-JournalResource $j 'authentik-application' "dm-$($p.Project)" $(if (@($createdAk | Where-Object { $_ -like 'application*' }).Count -and @($createdAk | Where-Object { $_ -like 'proxy provider*' }).Count) { 'created' } else { 'reused' }) (($createdAk) -join ', ') ([ordered]@{ action = 'identity-undo'; service = $p.Project })
      Add-JournalResource $j 'authentik-outpost' 'embedded outpost' 'shared' "provider dm-$($p.Project) assigned"
      if (-not $pr.ok) { & $fail 'authentication' $pr.message; return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j } }
      Add-JournalStage $j 'authentication' 'passed' $pr.message
      Save-ProvisionJournal $j
    }
    # Stage 4: publication through the existing tunnel (only after protection is verified).
    if ($p.Access -eq 'public') {
      $reg = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.name -eq $p.Project })[0]
      $pub = $reg | ConvertTo-Json -Depth 8 | ConvertFrom-Json
      $pub.cloudflare.publish = $true; $pub.cloudflare.access = ($p.Auth -eq 'cloudflare-access')
      $cp = Build-ChangePlan ([pscustomobject]@{ op = 'update'; name = $p.Project; service = $pub; cloudflare = [pscustomobject]@{ automate = $true; accessEmails = @(); cleanup = $false } })
      $missing = @($cp.Cloudflare.Actions | Where-Object { $_.Overwrite -and $confirmed -notcontains $_.Id })
      if ($missing.Count) { & $fail 'publish' "Confirm the overwrite of existing Cloudflare resources first: $(@($missing | ForEach-Object { $_.Summary }) -join '; ')"; return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j } }
      $pr2 = Invoke-ChangePlanSteps $cp $confirmed
      if (-not $pr2.ok) { & $fail 'publish' 'Cloudflare or Traefik did not accept the publication.'; return [ordered]@{ ok = $false; operationId = $j.operationId; journal = $j } }
      foreach ($a in @($cp.Cloudflare.Actions | Where-Object { $_.Kind -ne 'none' })) { Add-JournalResource $j "cloudflare-$([string]$a.Step)" $p.Hostname $(if ($a.Overwrite) { 'modified' } else { 'created' }) ([string]$a.Summary) ([ordered]@{ action = 'service-remove'; service = $p.Project }) }
      Add-JournalStage $j 'publish' 'passed' "https://$($p.Hostname)"
      Save-ProvisionJournal $j
    }
  }
  $j.verification = Get-ProvisionVerification $j
  $j.state = $(if (@($j.verification | Where-Object { $_.status -eq 'failed' }).Count) { 'needs-attention' } else { 'deployed' })
  Save-ProvisionJournal $j
  Write-Audit 'provision-apply' "$($j.operationId) $($j.state) project=$($p.Project) access=$($p.Access) auth=$($p.Auth)"
  return [ordered]@{ ok = $true; operationId = $j.operationId; journal = $j; url = $(if ($p.Access -eq 'public') { "https://$($p.Hostname)/" } elseif ($p.Access -eq 'lan') { "http://$($p.Hostname)/" } else { $res.localUrl }); localUrl = $res.localUrl; credentialsFile = $res.credentialsFile }
}

# Every stage checked on its own; a stage that does not apply says so, and nothing untested is reported as passed.
function Get-ProvisionVerification($Journal) {
  $settings = Get-Settings
  $out = New-Object System.Collections.ArrayList
  $add = { param($stage, $status, $detail) $null = $out.Add([ordered]@{ stage = $stage; status = $status; detail = $detail }) }
  $plan = $Journal.plan
  $rec = @(Read-AppsRegistry $settings | Where-Object { $_.project -eq $plan.project })[0]
  if (-not $rec) { & $add 'containers' 'failed' 'The application is no longer registered.'; return @($out) }
  $cfgCheck = Invoke-Docker @((Get-AppComposeArgs $rec) + @('config', '-q'))
  & $add 'compose' $(if ($cfgCheck.ExitCode -eq 0) { 'passed' } else { 'failed' }) 'docker compose config'
  $imgs = @($rec.images); $missingImg = @($imgs | Where-Object { (Invoke-Docker image inspect $_).ExitCode -ne 0 })
  & $add 'images' $(if ($missingImg.Count) { 'failed' } else { 'passed' }) $(if ($missingImg.Count) { "missing: $($missingImg -join ', ')" } else { "$($imgs.Count) image(s) present, pinned by digest" })
  $cs = @(Get-ComposeProjectContainers $plan.project)
  $notRunning = @($cs | Where-Object { $_.state -ne 'running' -and $_.status -notmatch 'Exited \(0\)' })
  & $add 'containers' $(if ($cs.Count -and -not $notRunning.Count) { 'passed' } else { 'failed' }) "$(@($cs | Where-Object { $_.state -eq 'running' }).Count) running$(if ($notRunning.Count) { "; not running: $(@($notRunning | ForEach-Object { $_.name }) -join ', ')" })"
  $unhealthy = @($cs | Where-Object { [string]$_.health -match 'unhealthy' })
  & $add 'dependencies' $(if ($unhealthy.Count) { 'failed' } elseif (@($cs | Where-Object { [string]$_.health -match 'healthy' }).Count) { 'passed' } else { 'not-tested' }) $(if ($unhealthy.Count) { "unhealthy: $(@($unhealthy | ForEach-Object { $_.name }) -join ', ')" } elseif (@($cs | Where-Object { [string]$_.health -match 'healthy' }).Count) { 'health checks pass' } else { 'no health checks defined' })
  $m = Get-InstanceManifest $rec
  $h = $null; if ($m) { $h = Get-AppHealth $plan.project $m $settings 0 }
  $httpOk = [bool]($h -and $h.http -and $h.http.result -in 'http', 'https')
  & $add 'backend' $(if ($httpOk) { 'passed' } else { 'failed' }) $(if ($h -and $h.http) { "$($h.http.result): $($h.http.detail)" } else { 'no answer' })
  & $add 'docker-dns' $(if ($httpOk) { 'passed' } else { 'not-tested' }) $(if ($httpOk) { "$($plan.container) resolved by name on the shared network" } else { 'needs a reachable backend' })
  $svc = $null
  if ($plan.access -ne 'local') { $svc = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.name -eq $plan.project })[0] }
  if (-not $svc) { foreach ($s in @('router', 'cloudflare', 'public', 'auth-challenge')) { & $add $s 'not-applicable' 'Local access only: no route.' } }
  else {
    $model = $null; try { $model = Get-RoutingModel -Facts (Get-RoutingFacts $settings $svc -Probe) } catch { }
    $stages = @(if ($model) { @($model.stages) })
    # The routing model's states: only 'verified' is a passed check; 'configured' means checked in the configuration only.
    $state = { param([string[]]$ids) $ss = @($stages | Where-Object { $ids -contains [string]$_.id }); if (-not $ss.Count) { 'not-tested' } elseif (@($ss | Where-Object { $_.state -eq 'failed' }).Count) { 'failed' } elseif (-not @($ss | Where-Object { $_.state -ne 'verified' }).Count) { 'passed' } else { 'not-tested' } }
    $summary = { param([string[]]$ids) (@($stages | Where-Object { $ids -contains [string]$_.id } | ForEach-Object { "$($_.title): $($_.summary)" }) -join ' ') }
    & $add 'router' (& $state @('router')) $(if ($model) { & $summary @('router') } else { 'routing model unavailable' })
    if ($plan.access -eq 'public') {
      & $add 'cloudflare' (& $state @('dns', 'tunnel')) (& $summary @('dns', 'tunnel'))
      # One real request from the Internet side: Cloudflare -> tunnel -> Traefik. A sign-in page (authentik or Cloudflare
      # Access) proves that the protection layer answers; the application itself is verified by the backend stage.
      $pr = Invoke-ProbeRequest "https://$($plan.hostname)/"
      $toAuth = [string]$pr.Location -match '(cloudflareaccess\.com|/outpost\.goauthentik\.io/|/application/o/authorize|/if/flow/)'
      & $add 'public' $(if ($pr.Status -ge 200 -and $pr.Status -lt 400) { 'passed' } else { 'failed' }) $(if ($pr.Error) { $pr.Error } elseif ($toAuth) { "HTTP $($pr.Status): the sign-in layer answers (the application behind it is checked by the backend stage)" } else { "HTTP $($pr.Status)" })
    } else { & $add 'cloudflare' 'not-applicable' 'Not published.'; & $add 'public' 'not-applicable' 'Not published.' }
    if ($plan.auth -eq 'authentik') {
      $c = Test-IdentityProtection $plan.hostname
      & $add 'auth-challenge' $(if ($c.State -eq 'auth') { 'passed' } else { 'failed' }) ([string]$c.Message)
      & $add 'unauthorized-rejected' $(if ($c.State -eq 'auth') { 'passed' } else { 'failed' }) 'An anonymous request is sent to sign in instead of reaching the application.'
      & $add 'authorized-access' 'not-tested' 'Needs a real sign-in in your browser; the manager records it once authentik reports a successful sign-in to this application.'
    } else { & $add 'auth-challenge' 'not-applicable' "Authentication: $($plan.auth)" }
  }
  return @($out)
}

function Invoke-ProvisionVerify($Body) {
  Assert-Installed
  $j = Read-ProvisionJournal ([string](Get-Field $Body 'operationId' ''))
  $j.verification = Get-ProvisionVerification $j
  Save-ProvisionJournal $j
  return [ordered]@{ operationId = $j.operationId; verification = $j.verification }
}

function Get-ProvisionRollbackPreview($Body) {
  Assert-Installed
  $j = Read-ProvisionJournal ([string](Get-Field $Body 'operationId' ''))
  return [ordered]@{ operationId = $j.operationId; summary = $j.summary; state = $j.state; plan = (Get-ProvisionRollbackPlan $j -DeleteData:([bool](Get-Field $Body 'deleteData' $false))) }
}

# Undoes one operation: Cloudflare and the route first (the hostname stops answering), then authentik (only what this
# operation created), then the Compose project (data volumes only with deleteData and the project name typed).
function Invoke-ProvisionRollback($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $j = Read-ProvisionJournal ([string](Get-Field $Body 'operationId' ''))
  if ([string]$j.state -eq 'rolled-back') { Stop-Request 409 'This operation was already rolled back.' }
  $deleteData = [bool](Get-Field $Body 'deleteData' $false)
  if ($deleteData -and [string](Get-Field $Body 'confirmText' '') -ne [string]$j.plan.project) { Stop-Request 400 "Type the project name ($($j.plan.project)) to delete its data." }
  $rb = Get-ProvisionRollbackPlan $j -DeleteData:$deleteData
  $done = New-Object System.Collections.ArrayList
  $err = ''
  $did = @{}
  try {
    $akStep = @($rb.steps | Where-Object { $_.kind -eq 'authentik-application' })[0]
    $hasRoute = @($rb.steps | Where-Object { $_.kind -eq 'traefik-route' -or $_.kind -like 'cloudflare-*' }).Count
    if ($akStep) { foreach ($x in (Undo-IdentityProtection ([string]$j.plan.project) $true)) { $null = $done.Add("authentik: $x") } }
    elseif (@($rb.kept | Where-Object { $_.kind -eq 'authentik-application' }).Count -and $hasRoute) { foreach ($x in (Undo-IdentityProtection ([string]$j.plan.project) $false)) { $null = $done.Add("authentik: $x") } }
    if ($hasRoute) {
      $reg = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.name -eq [string]$j.plan.project })
      if ($reg.Count) {
        $plan = Build-ChangePlan ([pscustomobject]@{ op = 'remove'; name = [string]$j.plan.project; cloudflare = [pscustomobject]@{ automate = $true; cleanup = $true } })
        $r = Invoke-ChangePlanSteps $plan @()
        if (-not $r.ok) { throw 'Traefik or Cloudflare did not accept removing the route.' }
        $null = $done.Add("Route $($j.plan.hostname) removed$(if (@($rb.steps | Where-Object { $_.kind -like 'cloudflare-*' }).Count) { ' with the Cloudflare records this operation created' })")
      }
    }
    if (@($rb.steps | Where-Object { $_.kind -eq 'compose-project' }).Count -and @(Read-AppsRegistry $settings | Where-Object { $_.project -eq [string]$j.plan.project }).Count) {
      $rm = Invoke-AppRemove ([pscustomobject]@{ project = [string]$j.plan.project; confirm = $true; deleteVolumes = $deleteData; deleteFolder = $deleteData; confirmText = [string](Get-Field $Body 'confirmText' '') })
      $null = $done.Add("Compose project $($rm.project) removed$(if ($deleteData) { ' with its data' } else { "; data volumes kept: $(@($rm.keptVolumes) -join ', ')" })")
    }
  } catch { $err = $_.Exception.Message }
  $j.state = $(if ($err) { 'rollback-failed' } else { 'rolled-back' })
  Add-JournalStage $j 'rollback' $(if ($err) { 'failed' } else { 'passed' }) $(if ($err) { $err } else { ($done -join '; ') })
  Save-ProvisionJournal $j
  Write-Audit 'provision-rollback' "$($j.operationId) $($j.state)"
  return [ordered]@{ ok = (-not $err); done = @($done); kept = @($rb.kept); error = $err; state = $j.state }
}

# --- Recipes (local; sharing is an explicit, previewed export) ---

function Invoke-ProvisionRecipeSave($Body) {
  Assert-Installed
  $settings = Get-Settings
  $j = Read-ProvisionJournal ([string](Get-Field $Body 'operationId' ''))
  $rec = @(Read-AppsRegistry $settings | Where-Object { $_.project -eq [string]$j.plan.project })[0]
  if (-not $rec) { Stop-Request 409 'The application of this operation is no longer installed.' }
  $m = Get-InstanceManifest $rec
  $r = New-Recipe -Manifest $m -HostFingerprint (Get-HostFingerprint) -Verification @($j.verification) -Origin 'local' -KnownIssues @(Get-Prop2 $m 'knownIssues' @())
  $path = Save-Recipe $settings $r
  return [ordered]@{ saved = $true; id = $r.id; file = (Split-Path -Leaf $path); trust = $r.trust }
}

function Get-ProvisionRecipeShare($Body) {
  Assert-Installed
  $settings = Get-Settings
  $id = [string](Get-Field $Body 'recipeId' '')
  if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,60}$') { Stop-Request 400 'Invalid recipe id.' }
  $r = @(Get-LocalRecipes $settings | Where-Object { [string]$_.id -eq $id })[0]
  if (-not $r) { Stop-Request 404 'No such recipe.' }
  $s = ConvertTo-SanitizedRecipe $r (Get-ProvisionPrivateNames $settings)
  return [ordered]@{ recipe = $s.Recipe; removed = $s.Removed; errors = @(Test-Recipe $s.Recipe); note = 'Nothing is uploaded. This is exactly what an exported file contains.' }
}

function Invoke-ProvisionRecipeImport($Body) {
  Assert-Installed
  try { $path = Import-RecipeText (Get-Settings) ([string](Get-Field $Body 'text' '')) } catch { Stop-Request 400 $_.Exception.Message }
  return [ordered]@{ imported = $true; file = (Split-Path -Leaf $path) }
}

function Get-ProvisionRecipes($Query) {
  Assert-Installed
  $settings = Get-Settings
  $app = [string]$Query['app']
  $list = @(Get-LocalRecipes $settings $app)
  $ranked = @(Get-RecipeRanking $list (Get-HostFingerprint))
  return [ordered]@{ recipes = @($ranked | ForEach-Object { [ordered]@{ id = $_.Recipe.id; application = $_.Recipe.application; host = $_.Recipe.host; trust = $_.Recipe.trust; origin = $_.Recipe.provenance.origin; score = $_.Score; reasons = $_.Reasons; compatible = $_.Compatible } }); registry = (Get-RecipeRegistryInfo) }
}

# --- Applications: one model for managed, integrated and observed applications (docs/universal-apps.md) -------------
# lib\AppContract.psm1 (recipes, instances, integrations, ownership modes) and lib\Reconcile.psm1 (drift and repairs).
# Integrations reuse the service change pipeline (Build-ChangePlan / Invoke-ChangePlanSteps: validation in a throwaway
# Traefik, backups, Cloudflare plans) and the identity contract; they never recreate a container or edit the files of
# the tool that owns it.

function Assert-ContractInstanceId([string]$Value) { if ($Value -notmatch '^(x|i)-[0-9a-f]{6,12}$|^legacy-[a-z0-9][a-z0-9_.-]{0,62}$') { Stop-Request 400 'Invalid application id.' }; return $Value }

function Get-ManagedContractRecords($Settings, $Catalog) {
  return @(Read-AppsRegistry $Settings | Where-Object { -not [bool](Get-Prop2 $_ 'archived' $false) } | ForEach-Object {
      $inst = ConvertTo-AppInstance $_ $Catalog
      $m = $null; try { $m = Get-InstanceManifest $_ $Catalog } catch { }
      $web = ''; if ($m -and (Get-Prop2 $m 'web' $null)) { try { $web = Get-AppContainerName $m $inst.project ([string]$m.web.service) } catch { } }
      $o = [ordered]@{}; foreach ($k in $inst.Keys) { $o[$k] = $inst[$k] }
      $o.manifest = $m; $o.webContainer = $web
      $o
    })
}

function Get-ContractContext {
  Assert-Installed
  $settings = Get-Settings
  if (-not (Get-DockerStatus).EngineRunning) { Stop-Request 503 'The Docker engine is not reachable. Start Docker Desktop.' }
  $catalog = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { -not @($_.errors).Count })
  try { $registry = Read-ContractRegistry $settings } catch { Stop-Request 409 $_.Exception.Message }
  return [pscustomobject]@{ Settings = $settings; Catalog = $catalog; Registry = $registry
    Managed = @(Get-ManagedContractRecords $settings $catalog); Services = @((Read-ServiceRegistry -Settings $settings).services)
    Containers = @(Get-DockerContainerInventory -ProxyNetwork $settings.ProxyNetwork); Own = @(@((Get-StackContainerNames $settings).Values) + @($settings.WhoamiContainer)) }
}

function Get-ApplicationsData {
  $c = Get-ContractContext
  $inv = Get-ApplicationInventory -Managed $c.Managed -Registry $c.Registry -Services $c.Services -Containers $c.Containers -StackName $c.Settings.StackName -OwnContainers $c.Own -ProxyNetwork $c.Settings.ProxyNetwork
  $inv.proxyNetwork = $c.Settings.ProxyNetwork
  # Optional Portainer / Arcane connectors add API evidence to the Docker-based authority (never required).
  $snaps = @(if (@(Read-ManagerConnectors).Count) { Get-ManagerSnapshots })
  if ($snaps.Count) {
    foreach ($a in @(@($inv.applications) + @($inv.unmanaged))) { if ($a -and [string]$a['mode'] -ne 'managed' -and [string]$a['project']) { $a['authority'] = Resolve-ManagerAuthority $a['authority'] ([string]$a['project']) $snaps } }
  }
  $inv.managers = @($snaps | ForEach-Object { [ordered]@{ id = $_.id; kind = $_.kind; ok = [bool]$_.ok; error = [string]$_.error; message = [string]$_.message; stacks = @($_.stacks).Count } })
  $inv.entryPoints = @(
    [ordered]@{ id = 'catalog'; label = 'Browse curated applications'; href = '#catalog' }
    [ordered]@{ id = 'link'; label = 'Paste a Docker Hub or GitHub link'; href = '#provision' }
    [ordered]@{ id = 'compose'; label = 'Import Compose'; href = '#provision?source=compose' }
    [ordered]@{ id = 'unraid'; label = 'Import an Unraid template'; href = '#provision?source=unraid' }
    [ordered]@{ id = 'discover'; label = 'Discover existing Docker applications'; href = '#applications' })
  return $inv
}

# The container a request names, refused when it belongs to this deployment, is proxy/tunnel infrastructure or a
# database-like private service.
function Get-IntegrableContainer($Ctx, [string]$Name) {
  if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { Stop-Request 400 'Invalid container name.' }
  $c = @($Ctx.Containers | Where-Object { $_.name -eq $Name })
  if (-not $c.Count) { Stop-Request 404 "No container named '$Name'." }
  $c = $c[0]
  if ($Ctx.Own -contains $c.name -or ([string]$c.compose.project -and [string]$c.compose.project -eq [string]$Ctx.Settings.StackName)) { Stop-Request 400 "$Name is part of this deployment; it is managed by its compose.yaml." }
  if ($c.infrastructure) { Stop-Request 400 "$Name looks like proxy or tunnel infrastructure; it is not integrated as an application." }
  if ($c.privateService) { Stop-Request 400 "$Name is a database, cache, message broker or directory server: it stays private." }
  if (@($Ctx.Managed | Where-Object { [string]$_.project -and [string]$_.project -eq [string]$c.compose.project }).Count) { Stop-Request 409 "$Name belongs to an application DTC manages; use the Installed apps page." }
  return $c
}

function Find-ContractInstance($Ctx, [string]$InstanceId) {
  $i = @(@($Ctx.Registry.instances) | Where-Object { [string]$_.instanceId -eq $InstanceId })
  if ($i.Count) { return $i[0] }
  return $null
}

# DTC Observed: record a container or project for monitoring only. Nothing is changed.
function Invoke-ApplicationObserve($Body) {
  $ctx = Get-ContractContext
  $c = Get-IntegrableContainer $ctx ([string](Get-Field $Body 'container' ''))
  $dup = @(@($ctx.Registry.instances) | Where-Object { $_.target.container -eq $c.name -or ($c.compose.project -and $_.target.project -eq $c.compose.project -and $_.target.service -eq $c.compose.service) })
  if ($dup.Count) { Stop-Request 409 "$($c.name) is already recorded as $($dup[0].mode)." }
  $auth = Get-ManagementAuthority $c
  $inst = New-ContractInstance 'observed' $c $auth ([string](Get-Field $Body 'name' '')) (New-ObservedBaseline $c 0 '' $ctx.Settings.ProxyNetwork $auth)
  $ctx.Registry.instances = @(@($ctx.Registry.instances) + $inst)
  Save-ContractRegistry $ctx.Settings $ctx.Registry
  Write-Audit 'app-observe' "$($c.name) authority=$($auth.id) id=$($inst.instanceId)"
  return [ordered]@{ ok = $true; instance = $inst }
}

# Forgets an observed instance (only the record; integrated ones must have their integrations removed first).
function Invoke-ApplicationForget($Body) {
  $ctx = Get-ContractContext
  $id = Assert-ContractInstanceId ([string](Get-Field $Body 'instanceId' ''))
  $inst = Find-ContractInstance $ctx $id
  if (-not $inst) { Stop-Request 404 'No such application record.' }
  if (@($inst.integrations).Count) { Stop-Request 409 'Remove its integrations first (routes, sign-in, publication).' }
  $ctx.Registry.instances = @(@($ctx.Registry.instances) | Where-Object { $_.instanceId -ne $id })
  Save-ContractRegistry $ctx.Settings $ctx.Registry
  Write-Audit 'app-forget' $id
  return [ordered]@{ ok = $true }
}

# DTC Integrated: a separately owned route (and optionally Cloudflare publication) for an application another tool
# owns. The plan is the ordinary service change plan with the route's owner recorded.
function Build-IntegrationChange($Body, [string]$InstanceId = '', [string]$IntegrationId = '') {
  $ctx = Get-ContractContext
  $c = Get-IntegrableContainer $ctx ([string](Get-Field $Body 'container' ''))
  $existing = @(@($ctx.Registry.instances) | Where-Object { $_.target.container -eq $c.name -or ($c.compose.project -and $_.target.project -eq $c.compose.project -and $_.target.service -eq $c.compose.service) })
  if ($existing.Count -and [string]$existing[0].mode -eq 'observed' -and -not [bool](Get-Field $Body 'switchToIntegrated' $false)) { Stop-Request 409 "$($c.name) is observed. Confirm switching it to Integrated (DTC then manages only the route it creates)." }
  $port = 0; if (-not [int]::TryParse([string](Get-Field $Body 'port' ''), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { Stop-Request 400 'Choose the web port (1-65535).' }
  if ($port -in 2375, 2376) { Stop-Request 400 'The Docker Engine API port is never routed.' }
  if (-not @($c.exposed | Where-Object { [int]$_.port -eq $port -and $_.proto -eq 'tcp' }).Count) { Stop-Request 400 "$($c.name) does not expose TCP port $port." }
  $protocol = [string](Get-Field $Body 'protocol' 'http'); if ($protocol -notin 'http', 'https') { Stop-Request 400 'Protocol must be http or https.' }
  $hostname = ([string](Get-Field $Body 'hostname' '')).Trim().ToLowerInvariant()
  $routeName = ([string](Get-Field $Body 'name' $(if ($c.compose.project) { $c.compose.project } else { $c.name }))).ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-+', '-'
  $routeName = $routeName.Trim('-'); if ($routeName.Length -gt 40) { $routeName = $routeName.Substring(0, 40).Trim('-') }
  $publish = [bool](Get-Field $Body 'publish' $false)
  $instId = $(if ($existing.Count) { [string]$existing[0].instanceId } elseif ($InstanceId) { $InstanceId } else { New-ContractId 'x' })
  $intId = $(if ($IntegrationId) { $IntegrationId } else { New-ContractId 'int' })
  $owner = [ordered]@{ kind = 'integration'; instanceId = $instId; integrationId = $intId }
  $svc = [pscustomobject]@{ name = $routeName; displayName = ([string](Get-Field $Body 'displayName' '')); description = "Integrated application ($((Get-ManagementAuthority $c).label) owns the containers)"
    enabled = $true; hostnames = @($hostname); middlewares = @('default-headers@file')
    target = [pscustomobject]@{ type = 'docker'; host = $c.name; port = $port; protocol = $protocol }
    cloudflare = [pscustomobject]@{ publish = $publish; access = [bool](Get-Field $Body 'access' $publish) } }
  $changeBody = [pscustomobject]@{ op = 'add'; service = $svc; cloudflare = [pscustomobject]@{ automate = $publish } }
  $plan = Build-ChangePlan $changeBody $owner
  $auth = Get-ManagementAuthority $c
  $view = ConvertTo-PlanView $plan ''
  $warnings = @()
  if (-not $c.onProxyNetwork) {
    $warnings += "$($c.name) is not on '$($ctx.Settings.ProxyNetwork)', so Traefik cannot reach it. Add the network to the service in its owner's Compose file (DTC does not edit it), redeploy it there, then preview again."
    $view.canApply = $false
  }
  $ready = $false; try { $ready = [bool](Get-IdentityContractStatus).readiness.ready } catch { }
  return [pscustomobject]@{ Ctx = $ctx; Container = $c; Authority = $auth; Plan = $plan; View = $view; Owner = $owner; ChangeBody = $changeBody; RouteName = $routeName; Hostname = $hostname; Port = $port; Protocol = $protocol; Publish = $publish
    Warnings = $warnings; AuthOptions = (Get-AuthenticationOptions -Image $c.image -IdentityReady $ready -Public $publish); Existing = $(if ($existing.Count) { $existing[0] } else { $null }) }
}

function Get-IntegrationPlan($Body) {
  $x = Build-IntegrationChange $Body
  foreach ($k in @($State.IntegrationPlans.Keys)) { if (((Get-Date) - $State.IntegrationPlans[$k].Created).TotalMinutes -gt 15) { $State.IntegrationPlans.Remove($k) } }
  $id = New-RandomKey 12
  $State.IntegrationPlans[$id] = [pscustomobject]@{ Created = (Get-Date); Body = ($Body | ConvertTo-Json -Depth 8 -Compress); InstanceId = $x.Owner.instanceId; IntegrationId = $x.Owner.integrationId; TraefikKey = $x.Plan.TraefikKey; CfFingerprint = $x.Plan.Cloudflare.Fingerprint }
  $x.View.planId = $id
  return [ordered]@{ planId = $id; plan = $x.View; container = $x.Container.name; route = $x.RouteName; hostname = $x.Hostname; backendUrl = "$($x.Protocol)://$($x.Container.name):$($x.Port)"
    ownership = [ordered]@{ mode = 'integrated'; authority = $x.Authority; rights = (Get-OwnershipModes).integrated; instanceId = $x.Owner.instanceId
      keeps = @("$($x.Container.name) and its Compose project stay with $($x.Authority.label): DTC does not recreate, restart or edit them.", 'Only the route created here (and sign-in or publication you add to it) belongs to DTC; removing the integration removes only those.') }
    authentication = $x.AuthOptions; warnings = @($x.Warnings); canApply = [bool]$x.View.canApply; needsBackendAck = [bool]$x.View.needsBackendAck }
}

function Invoke-IntegrationApply($Body) {
  Assert-Confirmed $Body
  $id = [string](Get-Field $Body 'planId' '')
  if (-not $id -or -not $State.IntegrationPlans.ContainsKey($id)) { Stop-Request 409 'This preview has expired or was already applied. Preview the integration again.' }
  $stored = $State.IntegrationPlans[$id]; $State.IntegrationPlans.Remove($id)
  $x = Build-IntegrationChange ($stored.Body | ConvertFrom-Json) $stored.InstanceId $stored.IntegrationId
  if ($x.Plan.TraefikKey -ne $stored.TraefikKey -or $x.Plan.Cloudflare.Fingerprint -ne $stored.CfFingerprint) { Stop-Request 409 'The configuration changed since the preview. Preview the integration again.' }
  if (-not $x.View.canApply) { Stop-Request 400 "This integration cannot be applied: $((@($x.Warnings) + @($x.View.traefik.issues | Where-Object { $_.Level -eq 'Error' } | ForEach-Object { $_.Message })) -join ' ')" }
  if ($x.View.needsBackendAck -and -not [bool](Get-Field $Body 'acceptUnverifiedBackend' $false)) { $State.IntegrationPlans[$id] = $stored; Stop-Request 409 "The backend did not pass the connection test from Traefik's network: $($x.Plan.Backend.message)" @{ needsBackendAck = $true } }
  $confirmed = @(@(Get-Field $Body 'confirmOverwrites' @()) | ForEach-Object { [string]$_ })
  $result = Invoke-ChangePlanSteps $x.Plan $confirmed
  if (-not $result.ok -and -not @((Read-ServiceRegistry -Settings $x.Ctx.Settings).services | Where-Object { $_.name -eq $x.RouteName }).Count) { Write-Audit 'integration-failed' "$($x.Container.name) route=$($x.RouteName)"; return [ordered]@{ ok = $false; result = $result } }
  $reg = Read-ContractRegistry $x.Ctx.Settings
  $inst = @(@($reg.instances) | Where-Object { $_.instanceId -eq $x.Owner.instanceId })
  if ($inst.Count) { $inst = $inst[0]; $inst.mode = 'integrated'; $inst.authority = $x.Authority; $inst.baseline = (New-ObservedBaseline $x.Container $x.Port $x.Protocol $x.Ctx.Settings.ProxyNetwork $x.Authority); $inst.updatedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
  else {
    $inst = New-ContractInstance 'integrated' $x.Container $x.Authority ([string](Get-Field ($stored.Body | ConvertFrom-Json) 'displayName' '')) (New-ObservedBaseline $x.Container $x.Port $x.Protocol $x.Ctx.Settings.ProxyNetwork $x.Authority)
    $inst.instanceId = $x.Owner.instanceId
    $reg.instances = @(@($reg.instances) + $inst)
  }
  $spec = ConvertTo-OrderedTree ($x.Plan.New | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
  $inst.integrations = @(@($inst.integrations) + [ordered]@{ integrationId = $x.Owner.integrationId; kind = 'traefik-route'; route = $x.RouteName; spec = $spec; createdAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
      protection = $null; publication = [ordered]@{ hostname = $x.Hostname; cloudflare = $x.Publish } })
  Save-ContractRegistry $x.Ctx.Settings $reg
  Write-Audit 'integration-apply' "$($x.Container.name) route=$($x.RouteName) id=$($x.Owner.instanceId) authority=$($x.Authority.id) ok=$($result.ok)"
  return [ordered]@{ ok = [bool]$result.ok; result = $result; instanceId = $x.Owner.instanceId; integrationId = $x.Owner.integrationId; route = $x.RouteName }
}

function Find-IntegrationRoute($Ctx, $Inst, [string]$Route) {
  $g = @(@($Inst.integrations) | Where-Object { [string]$_.route -eq $Route })
  if (-not $g.Count) { Stop-Request 404 "The route '$Route' does not belong to this integration." }
  $svc = @($Ctx.Services | Where-Object { $_.name -eq $Route -and $_.PSObject.Properties['owner'] -and $_.owner.instanceId -eq $Inst.instanceId })
  if (-not $svc.Count) { Stop-Request 409 "The route '$Route' is no longer owned by this integration (it was removed or changed elsewhere). Check drift first." }
  return [pscustomobject]@{ Integration = $g[0]; Service = $svc[0] }
}

# Sign-in in front of an integrated application, through the identity contract (only routes the integration owns).
function Invoke-IntegrationProtect($Body) {
  Assert-Confirmed $Body
  $ctx = Get-ContractContext
  $inst = Find-ContractInstance $ctx (Assert-ContractInstanceId ([string](Get-Field $Body 'instanceId' '')))
  if (-not $inst -or $inst.mode -ne 'integrated') { Stop-Request 404 'No such integrated application.' }
  $r = Find-IntegrationRoute $ctx $inst ([string](Get-Field $Body 'route' ''))
  $st = Get-IdentityContractStatus
  if (-not $st.readiness.ready) { Stop-Request 409 ('Identity & Access is not ready: ' + ((@($st.readiness.missing) | ForEach-Object { $_.message }) -join ' ')) }
  $res = Request-IdentityProtection $r.Service.name
  $check = $null; try { $check = Test-IdentityProtection (@($r.Service.hostnames)[0]) } catch { }
  $reg = Read-ContractRegistry $ctx.Settings
  $i2 = @(@($reg.instances) | Where-Object { $_.instanceId -eq $inst.instanceId })[0]
  foreach ($g in @($i2.integrations)) { if ($g.route -eq $r.Service.name) { $g.protection = [ordered]@{ provider = 'authentik'; created = @($res.created); verified = [bool]($check -and $check.State -eq 'auth'); checkedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z' } } }
  Save-ContractRegistry $ctx.Settings $reg
  Write-Audit 'integration-protect' "$($inst.instanceId) route=$($r.Service.name) ok=$($res.ok) challenge=$(if ($check) { $check.State })"
  return [ordered]@{ ok = [bool]$res.ok; message = $res.message; challenge = $check }
}

function Get-IntegrationRemovePlan($Body) {
  $ctx = Get-ContractContext
  $inst = Find-ContractInstance $ctx (Assert-ContractInstanceId ([string](Get-Field $Body 'instanceId' '')))
  if (-not $inst -or $inst.mode -ne 'integrated') { Stop-Request 404 'No such integrated application.' }
  $owned = @($ctx.Services | Where-Object { $_.PSObject.Properties['owner'] -and $_.owner.instanceId -eq $inst.instanceId })
  return [ordered]@{ instanceId = $inst.instanceId; name = $inst.name
    removes = @($owned | ForEach-Object { [ordered]@{ route = $_.name; hostnames = @($_.hostnames); protection = $(if ($_.PSObject.Properties['auth']) { $_.auth.provider } else { '' }); cloudflare = [bool]$_.cloudflare.publish } })
    keeps = @("The containers, Compose files, volumes and networks of $($inst.name) ($([string]$inst.authority.label)) are not touched.", 'Shared middleware, the authentik outpost, flows and other applications are not touched.')
    key = (Get-TextSha256 ((@($owned | ForEach-Object { "$($_.name)|$(ConvertTo-RegistryJson @($_))" })) -join ',')) }
}

function Invoke-IntegrationRemove($Body) {
  Assert-Confirmed $Body
  $plan = Get-IntegrationRemovePlan $Body
  if ($plan.key -ne [string](Get-Field $Body 'key' '')) { Stop-Request 409 'The integration changed since the preview. Review it again.' }
  $settings = Get-Settings
  $steps = @()
  $reg = Read-ContractRegistry $settings
  $inst = @(@($reg.instances) | Where-Object { $_.instanceId -eq $plan.instanceId })[0]
  foreach ($r in $plan.removes) {
    $g = @(@($inst.integrations) | Where-Object { $_.route -eq $r.route })
    if ($r.protection -eq 'authentik') {
      $created = [bool]($g.Count -and $g[0].protection -and @($g[0].protection.created).Count)
      try { $steps += @(Undo-IdentityProtection $r.route $created) } catch { $steps += "Sign-in of $($r.route) could not be removed: $($_.Exception.Message)"; return [ordered]@{ ok = $false; steps = $steps } }
    }
    $p = Build-ChangePlan ([pscustomobject]@{ op = 'remove'; name = $r.route; cloudflare = [pscustomobject]@{ automate = [bool]$r.cloudflare; cleanup = $true } })
    $res = Invoke-ChangePlanSteps $p @()
    $steps += "Route $($r.route): $(if ($res.ok) { 'removed' } else { 'not removed' })"
    if (-not $res.ok) { return [ordered]@{ ok = $false; steps = $steps; result = $res } }
  }
  $keep = [bool](Get-Field $Body 'keepObserved' $false)
  if ($keep) { $inst.mode = 'observed'; $inst.integrations = @(); $inst.updatedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
  else { $reg.instances = @(@($reg.instances) | Where-Object { $_.instanceId -ne $plan.instanceId }) }
  Save-ContractRegistry $settings $reg
  Write-Audit 'integration-remove' "$($plan.instanceId) routes=$((@($plan.removes) | ForEach-Object { $_.route }) -join ',') keepObserved=$keep"
  return [ordered]@{ ok = $true; steps = $steps; kept = @($plan.keeps) }
}

# Drift of one application: observations gathered here, decisions in lib\Reconcile.psm1.
function Get-ApplicationDrift($Ctx, [string]$InstanceId) {
  $settings = $Ctx.Settings
  $inst = Find-ContractInstance $Ctx $InstanceId
  $container = $null; $authority = $null; $routes = @(); $expectedVolumes = @(); $volumes = $null
  if ($inst) {
    $container = Find-InstanceContainer $inst $Ctx.Containers
    if ($container) { $authority = Get-ManagementAuthority $container @($Ctx.Managed | ForEach-Object { [string]$_.project }) $settings.StackName }
    $names = @(@($inst.integrations) | ForEach-Object { [string]$_.route })
    $routes = @($Ctx.Services | Where-Object { ($_.PSObject.Properties['owner'] -and $_.owner.instanceId -eq $inst.instanceId) -or $names -contains $_.name -or ($container -and $_.target.type -eq 'docker' -and $_.target.host -eq $container.name) })
  } else {
    $m = @($Ctx.Managed | Where-Object { $_.instanceId -eq $InstanceId })
    if (-not $m.Count) { Stop-Request 404 'No such application.' }
    $m = $m[0]
    $web = [string]$m.webContainer
    $svcName = $(if ($m.manifest -and (Get-Prop2 $m.manifest 'web' $null)) { [string]$m.manifest.web.service } else { '' })
    $inst = [ordered]@{ instanceId = $m.instanceId; mode = 'managed'; name = $m.name; target = [ordered]@{ project = $m.project; service = $svcName; container = $web }; integrations = @(); authority = [ordered]@{ id = 'dtc'; label = 'DTC' } }
    $container = Find-InstanceContainer $inst $Ctx.Containers
    $authority = [ordered]@{ id = 'dtc'; label = 'DTC'; confidence = 'certain'; evidence = @() }
    $hosts = @($Ctx.Containers | Where-Object { $_.compose.project -eq $m.project } | ForEach-Object { $_.name }) + @($web)
    $routes = @($Ctx.Services | Where-Object { $_.target.type -eq 'docker' -and $hosts -contains $_.target.host })
    if ($m.folder -and (Test-Path -LiteralPath (Join-Path $m.folder 'dtc-stack.json'))) {
      try { $stack = [IO.File]::ReadAllText((Join-Path $m.folder 'dtc-stack.json')) | ConvertFrom-Json; $expectedVolumes = @(@($stack.volumes) | Where-Object { $_.type -eq 'volume' } | ForEach-Object { [string]$_.name }) } catch { }
      if ($expectedVolumes.Count) { $volumes = @((Invoke-Docker volume ls -q).Output | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
    }
  }
  $loaded = $null
  try { $rt = Get-TraefikApi $settings '/api/http/routers'; if ($null -ne $rt) { $loaded = @(@($rt) | ForEach-Object { ([string]$_.name) -replace '^svc-', '' }) } } catch { }
  $files = @($routes | Where-Object { Test-Path -LiteralPath (Join-Path $settings.InstallPath "traefik\dynamic\svc-$($_.name).yml") } | ForEach-Object { $_.name })
  $probes = @{}
  if ($container -and $container.state -eq 'running' -and $container.onProxyNetwork) {
    foreach ($r in @($routes | Where-Object { $_.enabled -and $_.target.type -eq 'docker' })) {
      $k = "$($r.target.host):$($r.target.port)"
      if ($probes.ContainsKey($k) -or @($container.exposed | Where-Object { [int]$_.port -eq [int]$r.target.port }).Count -eq 0) { continue }
      try { $pr = Test-ContainerPort -Container $container -Port ([int]$r.target.port) -ProxyNetwork $settings.ProxyNetwork -Image $settings.TraefikImage -NamePrefix $settings.StackName -Schemes @([string]$r.target.protocol); $probes[$k] = @{ result = $pr.result; status = $pr.status; message = $pr.detail } } catch { }
    }
  }
  # A route port the container no longer exposes: probe its exposed ports, so a repair uses a port that answers.
  $portProbes = @{}
  if ($container -and $container.state -eq 'running' -and $container.onProxyNetwork -and @($routes | Where-Object { $rp = [int]$_.target.port; $_.enabled -and -not @($container.exposed | Where-Object { [int]$_.port -eq $rp }).Count }).Count) {
    foreach ($ep in @($container.exposed | Where-Object { $_.proto -eq 'tcp' -and [int]$_.port -notin 2375, 2376 } | Select-Object -First 6)) {
      try { $pr = Test-ContainerPort -Container $container -Port ([int]$ep.port) -ProxyNetwork $settings.ProxyNetwork -Image $settings.TraefikImage -NamePrefix $settings.StackName -Schemes @('http'); $portProbes[[string]$ep.port] = @{ result = $pr.result; status = $pr.status } } catch { }
    }
  }
  $claims = @{}
  $labelled = @($Ctx.Containers | Where-Object { @($_.traefik.routers).Count })
  foreach ($r in $routes) { foreach ($h in @($r.hostnames)) { $claims[[string]$h] = @(Find-HostnameClaims -Hostname $h -Services $Ctx.Services -Routers @() -Containers $labelled -OwnService $r.name) } }
  $protection = @{}
  foreach ($g in @($inst.integrations)) { if ($g.protection -and [string]$g.protection.provider) { $protection[[string]$g.route] = $g.protection } }
  $snaps = @(if (@(Read-ManagerConnectors).Count -and $inst.mode -ne 'managed') { Get-ManagerSnapshots })
  $proj = [string]$(if ($container) { $container.compose.project } else { $inst.target.project })
  if ($snaps.Count -and $authority) { $authority = Resolve-ManagerAuthority $authority $proj $snaps }
  $idEndpoint = ''; if (@($routes | Where-Object { $_.PSObject.Properties['auth'] }).Count) { try { $idEndpoint = [string](Get-IdentityContractStatus).endpoint } catch { } }
  $findings = @(Get-DriftFindings -Instance $inst -Container $container -Authority $authority -Routes $routes -LoadedRouters $loaded -RouteFiles $files -Probes $probes -Middlewares @(Get-AvailableMiddlewares $settings) -Claims $claims -ProxyNetwork $settings.ProxyNetwork -Volumes $volumes -ExpectedVolumes $expectedVolumes -Protection $protection -PortProbes $portProbes -IdentityEndpoint $idEndpoint)
  if ($snaps.Count) { $findings = @($findings) + @(Get-ManagerDriftFindings $proj $authority $snaps $container) }
  return [pscustomobject]@{ Instance = $inst; Container = $container; Routes = $routes; Findings = $findings; Summary = (Get-DriftSummary $findings); Repair = (Get-RepairPlan $findings $routes) }
}

function Invoke-ApplicationDriftRequest($Body) {
  $ctx = Get-ContractContext
  $id = Assert-ContractInstanceId ([string](Get-Field $Body 'instanceId' ''))
  $d = Get-ApplicationDrift $ctx $id
  return [ordered]@{ instanceId = $id; mode = [string]$d.Instance.mode; summary = $d.Summary; findings = @($d.Findings); repair = $d.Repair; checkedAt = (Get-Date -Format 's')
    interruptedRepairs = @(Get-InterruptedRepairs | Where-Object { $_.instanceId -eq $id }) }
}

# The change bodies of a repair: route updates, re-syncs and re-creations of DTC-owned routes only.
function Get-RepairChangeBodies($Ctx, $Drift) {
  $bodies = @()
  foreach ($c in @($Drift.Repair.routeChanges)) {
    $cur = @($Ctx.Services | Where-Object { $_.name -eq $c.route })[0]
    $def = ConvertTo-ServiceDefinition ($cur | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $def.target.host = [string]$c.after.host; $def.target.port = [int]$c.after.port; $def.middlewares = @($c.after.middlewares)
    if ($def.PSObject.Properties['auth'] -and [string]$c.after.authEndpoint) { $def.auth.endpoint = [string]$c.after.authEndpoint }
    $bodies += [pscustomobject]@{ Summary = "Update route '$($c.route)'"; Body = [pscustomobject]@{ op = 'update'; name = $c.route; service = $def; cloudflare = [pscustomobject]@{ automate = $false } }; Owner = $null }
  }
  foreach ($rn in @($Drift.Repair.resync)) {
    if (@($Drift.Repair.routeChanges | Where-Object { $_.route -eq $rn }).Count) { continue }
    $cur = @($Ctx.Services | Where-Object { $_.name -eq $rn })[0]
    if ($cur) { $bodies += [pscustomobject]@{ Summary = "Rewrite route '$rn'"; Body = [pscustomobject]@{ op = 'update'; name = $rn; service = $cur; cloudflare = [pscustomobject]@{ automate = $false } }; Owner = $null } }
  }
  foreach ($rn in @($Drift.Repair.recreate)) {
    $g = @(@($Drift.Instance.integrations) | Where-Object { $_.route -eq $rn -and $_.spec })[0]
    if ($g) {
      $spec = $g.spec | ConvertTo-Json -Depth 8 | ConvertFrom-Json
      $bodies += [pscustomobject]@{ Summary = "Create route '$rn' again"; Body = [pscustomobject]@{ op = 'add'; service = $spec; cloudflare = [pscustomobject]@{ automate = $false } }; Owner = [ordered]@{ kind = 'integration'; instanceId = $Drift.Instance.instanceId; integrationId = [string]$g.integrationId } }
    }
  }
  return $bodies
}

function Get-ApplicationRepairPlan($Body) {
  $ctx = Get-ContractContext
  $id = Assert-ContractInstanceId ([string](Get-Field $Body 'instanceId' ''))
  $d = Get-ApplicationDrift $ctx $id
  $bodies = @(Get-RepairChangeBodies $ctx $d)
  $views = @(foreach ($b in $bodies) { $p = Build-ChangePlan $b.Body $b.Owner; [ordered]@{ summary = $b.Summary; plan = (ConvertTo-PlanView $p ''); key = $p.TraefikKey } })
  $key = Get-TextSha256 ((@($views | ForEach-Object { $_.key })) -join '|')
  return [ordered]@{ instanceId = $id; summary = $d.Summary; findings = @($d.Findings); routeChanges = @($views | ForEach-Object { [ordered]@{ summary = $_.summary; plan = $_.plan } })
    external = @($d.Repair.external); protection = @($d.Repair.protection); notes = @($d.Repair.notes); canApply = [bool]($views.Count -and -not @($views | Where-Object { -not $_.plan.hasWork -or @($_.plan.traefik.issues | Where-Object { $_.Level -eq 'Error' }).Count }).Count); key = $key }
}

function Invoke-ApplicationRepair($Body) {
  Assert-Confirmed $Body
  $plan = Get-ApplicationRepairPlan $Body
  if (-not $plan.canApply) { Stop-Request 409 'There is no repair DTC can apply; see the instructions for the application''s owner.' }
  if ($plan.key -ne [string](Get-Field $Body 'key' '')) { Stop-Request 409 'The application changed since the preview. Review the repair again.' }
  $ctx = Get-ContractContext
  $d = Get-ApplicationDrift $ctx $plan.instanceId
  # Journal: the routes as they were before the repair, so a failed or interrupted repair never leaves routing half
  # updated (Invoke-ApplicationRepairRollback, or automatically below).
  $pre = Split-Path -Leaf (New-ServiceBackup $ctx.Settings -Suffix '-pre-repair')
  $journal = [ordered]@{ repairId = (New-SecretValue 6); instanceId = $plan.instanceId; startedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; preBackup = $pre; state = 'running'; steps = @() }
  Save-RepairJournal $journal
  $results = @()
  foreach ($b in @(Get-RepairChangeBodies $ctx $d)) {
    $p = Build-ChangePlan $b.Body $b.Owner
    $r = Invoke-ChangePlanSteps $p @()
    $results += [ordered]@{ summary = $b.Summary; ok = [bool]$r.ok; steps = @($r.steps) }
    $journal.steps = @($journal.steps) + [ordered]@{ summary = $b.Summary; ok = [bool]$r.ok }
    Save-RepairJournal $journal
    if (-not $r.ok) { break }
  }
  $ok = -not @($results | Where-Object { -not $_.ok }).Count
  if (-not $ok -and @($results).Count -gt 1) {
    $null = Restore-ServiceBackup -Settings $ctx.Settings -Id $pre
    $journal.state = 'rolled-back'; Save-RepairJournal $journal
    Write-Audit 'app-repair-rollback' "$($plan.instanceId) restored $pre"
    return [ordered]@{ ok = $false; rolledBack = $true; results = $results; repairId = $journal.repairId }
  }
  $journal.state = $(if ($ok) { 'done' } else { 'failed' }); Save-RepairJournal $journal
  # A repaired integration records what it now relies on, so the next check compares against the repaired state.
  if ($ok -and $d.Instance.mode -eq 'integrated' -and $d.Container) {
    $reg = Read-ContractRegistry $ctx.Settings
    $i2 = @(@($reg.instances) | Where-Object { $_.instanceId -eq $plan.instanceId })[0]
    $route = @((Read-ServiceRegistry -Settings $ctx.Settings).services | Where-Object { $_.PSObject.Properties['owner'] -and $_.owner.instanceId -eq $plan.instanceId })[0]
    if ($i2 -and $route) {
      $i2.baseline = New-ObservedBaseline $d.Container ([int]$route.target.port) ([string]$route.target.protocol) $ctx.Settings.ProxyNetwork (Get-ManagementAuthority $d.Container)
      foreach ($g in @($i2.integrations)) { if ($g.route -eq $route.name) { $g.spec = ConvertTo-OrderedTree ($route | ConvertTo-Json -Depth 8 | ConvertFrom-Json) } }
      $i2.updatedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
      Save-ContractRegistry $ctx.Settings $reg
    }
  }
  Write-Audit 'app-repair' "$($plan.instanceId) ok=$ok $((@($results | ForEach-Object { "$($_.summary)=$($_.ok)" })) -join '; ')"
  return [ordered]@{ ok = $ok; results = $results; repairId = $journal.repairId }
}

function Save-RepairJournal($Journal) { Write-TextFileAtomic (Join-Path (Get-ProvisionDir 'repairs') "$($Journal.repairId).json") (($Journal | ConvertTo-Json -Depth 6) + "`n") }

# Repairs that never finished (the manager was stopped part-way): listed with the routes as they were before.
function Get-InterruptedRepairs {
  return @(Get-ChildItem -LiteralPath (Get-ProvisionDir 'repairs') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
      try { $j = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json; if ([string]$j.state -eq 'running') { [ordered]@{ repairId = [string]$j.repairId; instanceId = [string]$j.instanceId; startedAt = [string]$j.startedAt; preBackup = [string]$j.preBackup; steps = @($j.steps) } } } catch { }
    })
}

function Invoke-ApplicationRepairRollback($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $id = [string](Get-Field $Body 'repairId' '')
  if ($id -notmatch '^[a-f0-9]{8,32}$') { Stop-Request 400 'Invalid repair id.' }
  $p = Join-Path (Get-ProvisionDir 'repairs') "$id.json"
  if (-not (Test-Path -LiteralPath $p)) { Stop-Request 404 'No such repair.' }
  $j = ConvertTo-OrderedTree ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
  if ([string]$j.state -ne 'running') { Stop-Request 409 "This repair is $($j.state); there is nothing to roll back." }
  $r = Restore-ServiceBackup -Settings (Get-Settings) -Id ([string]$j.preBackup)
  $j.state = 'rolled-back'; Save-RepairJournal $j
  Write-Audit 'app-repair-rollback' "$($j.instanceId) interrupted repair $id restored $($j.preBackup)"
  return [ordered]@{ ok = $true; restored = $r.Restored }
}

# --- External managers: optional read-only Portainer / Arcane connectors (lib\ExternalManagers.psm1) ---------------
# Configured in config\managers.json (no secrets) with the API key as a DPAPI secret. Only GET requests are sent.
# Discovery, integration and drift keep working from Docker alone when a connector is missing or does not answer.

function Get-ManagersPath { return (Join-Path $InstallPath 'config\managers.json') }
function Read-ManagerConnectors {
  $p = Get-ManagersPath
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  try { return @(([IO.File]::ReadAllText($p) | ConvertFrom-Json).connectors) } catch { return @() }
}
function Save-ManagerConnectors($List) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Get-ManagersPath)) | Out-Null
  Write-TextFileAtomic (Get-ManagersPath) ((([ordered]@{ version = 1; connectors = @($List) }) | ConvertTo-Json -Depth 6) + "`n")
}

function ConvertTo-ManagerSnapshotView($Snap) {
  if (-not $Snap) { return $null }
  return [ordered]@{ ok = [bool]$Snap.ok; error = [string]$Snap.error; message = [string]$Snap.message; checkedAt = [string]$Snap.checkedAt
    stacks = @(@($Snap.stacks) | ForEach-Object { [ordered]@{ name = $_.name; stackId = $_.stackId; status = $_.status; environment = $_.environment; containers = @(@($_.containers) | ForEach-Object { $_.name }) } }) }
}

function Get-ManagersData {
  Assert-Installed
  $settings = Get-Settings
  return [ordered]@{ kinds = (Get-ExternalManagerKinds)
    connectors = @(Read-ManagerConnectors | ForEach-Object {
        $info = Get-ProtectedSecretInfo -Settings $settings -Name (Get-ManagerSecretName ([string]$_.id))
        [ordered]@{ id = [string]$_.id; kind = [string]$_.kind; name = [string]$_.name; url = [string]$_.url; tlsSkipVerify = [bool](Get-Prop2 $_ 'tlsSkipVerify' $false); environment = [string](Get-Prop2 $_ 'environment' '')
          keyStored = [bool]$info.Stored; keyReadable = [bool]$info.Readable; keySavedAt = [string]$info.SavedAt
          lastCheck = (ConvertTo-ManagerSnapshotView $(if ($State.ManagerSnapshots.ContainsKey([string]$_.id)) { $State.ManagerSnapshots[[string]$_.id].Snap } else { $null })) }
      }) }
}

function Invoke-ManagerSave($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $settings = Get-Settings
  $kind = [string](Get-Field $Body 'kind' '')
  if (-not (Get-ExternalManagerKinds).Contains($kind)) { Stop-Request 400 'Choose Portainer or Arcane.' }
  $id = ([string](Get-Field $Body 'id' $kind)).ToLowerInvariant()
  if ($id -notmatch '^[a-z][a-z0-9-]{1,30}$') { Stop-Request 400 'The connector id may contain lowercase letters, digits and dashes.' }
  $ep = Test-ManagerConnectorUrl ([string](Get-Field $Body 'url' ''))
  if (-not $ep.Ok) { Stop-Request 400 $ep.Reason }
  $name = ([string](Get-Field $Body 'name' (Get-ExternalManagerKinds)[$kind].label)).Trim(); if ($name.Length -gt 40 -or $name -match '[<>"\r\n]') { Stop-Request 400 'The name may have at most 40 characters, without quotes or angle brackets.' }
  $key = [string](Get-Field $Body 'key' '')
  $list = @(Read-ManagerConnectors | Where-Object { [string]$_.id -ne $id })
  $existingKey = (Get-ProtectedSecretInfo -Settings $settings -Name (Get-ManagerSecretName $id)).Stored
  if (-not $key -and -not $existingKey) { Stop-Request 400 'Paste the API key (it is stored encrypted for this Windows account and never shown again).' }
  if ($key -and ($key.Length -lt 8 -or $key.Length -gt 512 -or $key -match '\s')) { Stop-Request 400 'That does not look like an API key.' }
  if ($key) { Save-ProtectedSecret -Settings $settings -Name (Get-ManagerSecretName $id) -Value $key -Label "$((Get-ExternalManagerKinds)[$kind].label) API key (read-only connector)" }
  $list += [ordered]@{ id = $id; kind = $kind; name = $name; url = $ep.BaseUrl; tlsSkipVerify = [bool](Get-Field $Body 'tlsSkipVerify' $false); environment = [string](Get-Field $Body 'environment' '') }
  Save-ManagerConnectors $list
  $State.ManagerSnapshots.Remove($id)
  Write-Audit 'manager-save' "$id $kind $($ep.BaseUrl) key=$(if ($key) { 'replaced' } else { 'kept' })"
  return [ordered]@{ ok = $true; id = $id; scopeNote = (Get-ExternalManagerKinds)[$kind].scopeNote }
}

function Invoke-ManagerDelete($Body) {
  Assert-Installed
  Assert-Confirmed $Body
  $id = [string](Get-Field $Body 'id' '')
  $list = @(Read-ManagerConnectors)
  if (-not @($list | Where-Object { [string]$_.id -eq $id }).Count) { Stop-Request 404 'No such connector.' }
  Save-ManagerConnectors @($list | Where-Object { [string]$_.id -ne $id })
  $null = Remove-ProtectedSecret -Settings (Get-Settings) -Name (Get-ManagerSecretName $id)
  $State.ManagerSnapshots.Remove($id)
  Write-Audit 'manager-delete' $id
  return [ordered]@{ ok = $true }
}

# Snapshots of every configured connector, cached for 60 s (no background polling).
function Get-ManagerSnapshots([switch]$Fresh) {
  $settings = Get-Settings
  return @(foreach ($c in @(Read-ManagerConnectors)) {
      $id = [string]$c.id
      if (-not $Fresh -and $State.ManagerSnapshots.ContainsKey($id) -and ((Get-Date) - $State.ManagerSnapshots[$id].At).TotalSeconds -lt 60) { $State.ManagerSnapshots[$id].Snap; continue }
      $key = $null; try { $key = Read-ProtectedSecret -Settings $settings -Name (Get-ManagerSecretName $id) } catch { }
      $snap = $(if (-not $key) { [pscustomobject]@{ id = $id; kind = [string]$c.kind; ok = $false; error = 'no-key'; message = 'No API key is stored for this connector.'; checkedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; stacks = @() } }
        else { Get-ManagerSnapshot -Connector $c -Key $key })
      $State.ManagerSnapshots[$id] = [pscustomobject]@{ At = (Get-Date); Snap = $snap }
      $snap
    })
}

function Invoke-ManagerTest($Body) {
  Assert-Installed
  $id = [string](Get-Field $Body 'id' '')
  if (-not @(Read-ManagerConnectors | Where-Object { [string]$_.id -eq $id }).Count) { Stop-Request 404 'No such connector.' }
  $snap = @(Get-ManagerSnapshots -Fresh | Where-Object { $_.id -eq $id })[0]
  Write-Audit 'manager-test' "$id ok=$($snap.ok) error=$($snap.error) stacks=$(@($snap.stacks).Count)"
  return (ConvertTo-ManagerSnapshotView $snap)
}

# --- Router ----------------------------------------------------------------------------------------------------

function Invoke-ApiRoute($Request, $Body) {
  $m = $Request.Method
  $p = $Request.Path
  # Until a deployment is chosen, nothing may change any folder: only the project and manager actions are allowed.
  if (-not $State.Chosen -and $m -ne 'GET' -and -not ($p.StartsWith('/api/projects/') -or $p.StartsWith('/api/launcher/') -or $p -eq '/api/manager/stop')) {
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
    'GET /api/launcher' { return Get-LauncherData }
    'POST /api/launcher/settings' { return Set-LauncherSettingsRequest $Body }
    'GET /api/dashboard' { return Get-DashboardData }
    'POST /api/dashboard/settings' { return Save-DashboardSettingsRequest $Body }
    'GET /api/overview' { return Get-OverviewData }
    'GET /api/infrastructure' { return Get-InfrastructureData }
    'GET /api/docker/containers' { return Get-DockerContainersData }
    'GET /api/docker/claims' { return Get-HostnameClaimsData ([string]$Request.Query['hostname']) ([string]$Request.Query['service']) }
    'POST /api/docker/probe' { return Invoke-PortProbe $Body }
    'POST /api/services/backend' { return Invoke-BackendResolve $Body }
    'POST /api/docker/connect' { return Invoke-NetworkConnect $Body }
    'POST /api/services/health' { return Invoke-ServiceHealth $Body }
    'GET /api/catalog' { return Get-CatalogData }
    'GET /api/catalog/defaults' { try { $cm = Get-CatalogApp -CatalogDir $CatalogDir -Id ([string]$Request.Query['id']) } catch { Stop-Request 404 $_.Exception.Message }; Assert-Installed; return Get-AppDefaults $cm (Get-Settings) }
    'POST /api/catalog/plan' { return Invoke-AppPlan $Body }
    'POST /api/catalog/apply' { return Invoke-AppApply $Body }
    'GET /api/apps' { return Get-AppsData }
    'POST /api/apps/action' { return Invoke-AppAction $Body }
    'GET /api/apps/logs' { $tl = 200; [int]::TryParse([string]$Request.Query['tail'], [ref]$tl) | Out-Null; return Get-AppLogsData ([string]$Request.Query['project']) $tl ([string]$Request.Query['service']) }
    'GET /api/apps/detail' { return Get-AppDetailData ([string]$Request.Query['project']) }
    'POST /api/apps/archive' { return Invoke-AppArchive $Body }
    'POST /api/apps/restore' { return Invoke-AppRestoreRecord $Body }
    'POST /api/apps/adopt/plan' { return Get-AppAdoptPlan $Body }
    'POST /api/apps/adopt' { return Invoke-AppAdopt $Body }
    'POST /api/apps/cleanup/plan' { return Get-AppCleanupPlan $Body }
    'POST /api/apps/cleanup' { return Invoke-AppCleanup $Body }
    'POST /api/apps/remove/plan' { return Get-AppRemovePlan $Body }
    'POST /api/apps/health' { return Invoke-AppHealthRequest $Body }
    'POST /api/apps/update/preview' { return Invoke-AppUpdatePreview $Body }
    'POST /api/apps/update/apply' { return Invoke-AppUpdateApply $Body }
    'POST /api/apps/remove' { return Invoke-AppRemove $Body }
    'POST /api/apps/backup' { return Invoke-AppBackup $Body }
    'GET /api/apps/backups' { return Get-AppBackupsData ([string]$Request.Query['project']) }
    'POST /api/apps/restore-data/plan' { return Get-AppRestorePlan $Body }
    'POST /api/apps/restore-data' { return Invoke-AppRestore $Body }
    'POST /api/apps/discard' { return Invoke-AppDiscardInterrupted $Body }
    'GET /api/apps/stack' { return Get-AppStackData ([string]$Request.Query['project']) }
    'POST /api/apps/stack/describe' { return Invoke-AppStackDescribe $Body }
    'GET /api/system/resources' { return Get-HostResources }
    'GET /api/identity' { Assert-Installed; return Get-IdentityData -Deep:([string]$Request.Query['deep'] -eq '1') -ProbeApps:([string]$Request.Query['probe'] -eq 'apps') }
    'GET /api/routing' { return Get-RoutingView $Request.Query }
    'POST /api/identity/provider' { return Set-IdentityProviderRequest $Body }
    'POST /api/identity/adopt' { return Invoke-IdentityAdopt $Body }
    'POST /api/identity/token' { return Save-IdentityTokenRequest $Body }
    'POST /api/identity/token/test' { return Test-IdentityTokenRequest }
    'POST /api/identity/token/delete' {
      Assert-Installed; Assert-Confirmed $Body
      $removed = Remove-StoredCredential -Settings $settings -Id 'authentik-api' -SecretName (Get-IdentityTokenSecretName)
      Write-Audit 'identity-token-removed' ''
      return [ordered]@{ removed = $removed }
    }
    'POST /api/identity/hostname' { return Set-IdentityHostnameRequest $Body }
    'POST /api/identity/outpost/plan' { return Invoke-IdentityOutpost $Body }
    'POST /api/identity/outpost/apply' { return Invoke-IdentityOutpost $Body -Apply }
    'POST /api/identity/owner' { return Set-IdentityOwnerRequest $Body }
    'POST /api/identity/owner/verify' { return Invoke-IdentityOwnerVerify $Body }
    'POST /api/identity/owner/local-start' { return Start-IdentityLocalOwnerCheck }
    'POST /api/identity/mode' { return Set-IdentityModeRequest $Body }
    'POST /api/identity/wizard' { return Set-IdentityWizardStepRequest $Body }
    'POST /api/identity/google/inspect' { return Invoke-IdentityGoogleInspect $Body }
    'POST /api/identity/loginpage/plan' { return Invoke-IdentityLoginPage $Body 'plan' }
    'POST /api/identity/loginpage/apply' { return Invoke-IdentityLoginPage $Body 'apply' }
    'POST /api/identity/loginpage/restore' { return Invoke-IdentityLoginPage $Body 'restore' }
    'POST /api/identity/google/save' { return Save-IdentityGoogleRequest $Body }
    'POST /api/identity/google/plan' { return Invoke-IdentityGooglePlan $Body }
    'POST /api/identity/google/apply' { return Invoke-IdentityGoogleApply $Body }
    'POST /api/identity/protect/plan' { return Invoke-IdentityProtectPlan $Body }
    'POST /api/identity/protect/apply' { return Invoke-IdentityProtectApply $Body }
    'POST /api/identity/unprotect/plan' { return Invoke-IdentityProtectPlan $Body -Remove }
    'POST /api/identity/unprotect/apply' { return Invoke-IdentityProtectApply $Body -Remove }
    'POST /api/identity/trace' { return Invoke-IdentityTrace $Body }
    'POST /api/identity/access/plan' { return Invoke-IdentityAccessCleanup $Body }
    'POST /api/identity/access/apply' { return Invoke-IdentityAccessCleanup $Body -Apply }
    'GET /api/applications' { return Get-ApplicationsData }
    'GET /api/managers' { return Get-ManagersData }
    'POST /api/managers/save' { return Invoke-ManagerSave $Body }
    'POST /api/managers/test' { return Invoke-ManagerTest $Body }
    'POST /api/managers/delete' { return Invoke-ManagerDelete $Body }
    'POST /api/applications/observe' { return Invoke-ApplicationObserve $Body }
    'POST /api/applications/forget' { return Invoke-ApplicationForget $Body }
    'POST /api/applications/drift' { return Invoke-ApplicationDriftRequest $Body }
    'POST /api/applications/repair/plan' { return Get-ApplicationRepairPlan $Body }
    'POST /api/applications/repair/apply' { return Invoke-ApplicationRepair $Body }
    'GET /api/applications/repairs' { Assert-Installed; return [ordered]@{ interrupted = @(Get-InterruptedRepairs) } }
    'POST /api/applications/repair/rollback' { return Invoke-ApplicationRepairRollback $Body }
    'POST /api/integrations/plan' { return Get-IntegrationPlan $Body }
    'POST /api/integrations/apply' { return Invoke-IntegrationApply $Body }
    'POST /api/integrations/protect' { return Invoke-IntegrationProtect $Body }
    'POST /api/integrations/remove/plan' { return Get-IntegrationRemovePlan $Body }
    'POST /api/integrations/remove' { return Invoke-IntegrationRemove $Body }
    'GET /api/provision' { return Get-ProvisionData }
    'POST /api/provision/import' { return Invoke-ProvisionImport $Body }
    'POST /api/provision/catalog' { return Invoke-ProvisionCatalogDraft $Body }
    'GET /api/provision/draft' { Assert-Installed; return Get-ProvisionDraftView (Read-ProvisionDraft ([string]$Request.Query['id'])) }
    'POST /api/provision/draft/web' { return Invoke-ProvisionDraftEdit $Body }
    'POST /api/provision/draft/delete' { return Remove-ProvisionDraftRequest $Body }
    'POST /api/provision/ai/settings' { return Set-ProvisionAiSettingsRequest $Body }
    'POST /api/provision/ai/key' { return Save-ProvisionAiKeyRequest $Body }
    'POST /api/provision/ai/key/delete' { Assert-Installed; Assert-Confirmed $Body; Remove-ProtectedSecret -Settings (Get-Settings) -Name (Get-AiKeySecretName); Write-Audit 'provision-ai-key' 'deleted'; return [ordered]@{ stored = $false } }
    'POST /api/provision/ai/estimate' { return Invoke-ProvisionAiEstimate $Body }
    'POST /api/provision/ai/run' { return Invoke-ProvisionAiRun $Body }
    'POST /api/provision/plan' { return Invoke-ProvisionPlan $Body }
    'POST /api/provision/apply' { return Invoke-ProvisionApply $Body }
    'POST /api/provision/verify' { return Invoke-ProvisionVerify $Body }
    'POST /api/provision/rollback/plan' { return Get-ProvisionRollbackPreview $Body }
    'POST /api/provision/rollback' { return Invoke-ProvisionRollback $Body }
    'GET /api/provision/recipes' { return Get-ProvisionRecipes $Request.Query }
    'POST /api/provision/recipe/save' { return Invoke-ProvisionRecipeSave $Body }
    'POST /api/provision/recipe/share' { return Get-ProvisionRecipeShare $Body }
    'POST /api/provision/recipe/import' { return Invoke-ProvisionRecipeImport $Body }
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
      $cookie = "$($State.Cookie)=$sid; Path=/; HttpOnly; SameSite=Strict"
      if ($SessionFile) {
        $State.Remembered[(Get-TextSha256 $sid)] = (Get-Date).AddDays($RememberDays)
        try { Save-RememberedSessions } catch { }
        $cookie += "; Max-Age=$($RememberDays * 86400)"
      }
      # Launcher mode: a link works once (it may linger in browser history or a process listing); the next one is
      # written to the user-only link file for "open again".
      if ($SingleUseLaunch) { $State.LaunchKey = New-RandomKey; Write-LaunchUrlFile }
      $h = @{} + $SecurityHeaders
      $h['Set-Cookie'] = $cookie
      # The launcher may ask for a page after sign-in (?to=projects); only plain page names are accepted.
      $to = [string]$Request.Query['to']
      $h['Location'] = $(if ($to -match '^[a-z][a-z-]{0,30}$') { "/#$to" } else { '/' })
      return @{ Status = 303; Body = ''; Headers = $h }
    }
    if (-not $StaticFiles.ContainsKey($path)) { return @{ Status = 404; Body = "Not found.`n"; Headers = $SecurityHeaders } }
    $file = $StaticFiles[$path]
    return @{ Status = 200; ContentType = $file[1]; Body = [IO.File]::ReadAllBytes((Join-Path $StaticRoot $file[0])); Headers = $SecurityHeaders }
  }

  $sid = Get-Cookie $Request $State.Cookie
  $session = Get-RequestSession $sid
  if (-not $session) {
    return New-JsonResponse @{ error = 'Not signed in. Open the manager from the DTC tray icon (Open Dashboard) or with the link printed by webui.ps1.'; signedOut = $true } 401
  }
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
  # Sign out of this browser: forgets the session (and the remembered browser); the next visit needs a new launch link.
  if ($Request.Method -eq 'POST' -and $path -eq '/api/session/signout') {
    $State.Sessions.Remove($sid)
    if ($SessionFile) { $State.Remembered.Remove((Get-TextSha256 $sid)); try { Save-RememberedSessions } catch { } }
    return New-JsonResponse ([ordered]@{ signedOut = $true }) 200 @{ 'Set-Cookie' = "$($State.Cookie)=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" }
  }
  try {
    $data = Invoke-ApiRoute $Request $body
    if ($Request.Path -eq '/api/session') { $data = [ordered]@{ ok = $true; csrf = $session.Csrf; installPath = $InstallPath; chosen = [bool]$State.Chosen; canStop = [bool]$StopFile; startMode = $StartMode; launcher = [bool]$LauncherStateDir; remembered = [bool]$SessionFile } }
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

Read-RememberedSessions
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
