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
  [switch]$OpenBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $here 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $here 'lib\Dashboard.psm1') -Force
Import-Module (Join-Path $here 'lib\ConfigBackup.psm1') -Force
Import-Module (Join-Path $here 'lib\ProjectDiscovery.psm1') -Force
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
  $tunnel = $null
  if ($status.cloudflare.tokenStored -and $status.cloudflare.tokenReadable -and $cf.accountId -and $cf.tunnelId) {
    try {
      $t = Invoke-CloudflareApi -Settings $settings -Path "/accounts/$($cf.accountId)/cfd_tunnel/$($cf.tunnelId)"
      $tunnel = [ordered]@{ name = [string]$t.name; status = [string]$t.status; connections = @($(if ($t.PSObject.Properties['connections']) { $t.connections } else { @() })).Count; error = '' }
    } catch { $tunnel = [ordered]@{ name = $cf.tunnelName; status = 'unknown'; connections = 0; error = $_.Exception.Message } }
  }
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
  $State.Plans.Clear(); $State.Imports.Clear(); $State.Upgrades.Clear()
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
