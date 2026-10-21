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
  # Where the last used install folder is remembered (default: %LOCALAPPDATA%\TraefikProxy\webui.json).
  [string]$StateFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $here 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $here 'lib\LocalHttp.psm1') -Force
Set-CloudflareApiBase $CloudflareApiBase

if (-not $StateFile) { $StateFile = Join-Path $env:LOCALAPPDATA 'TraefikProxy\webui.json' }
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

function Get-SettingsSource {
  if (Test-Path -LiteralPath (Join-Path $InstallPath '.env')) { return 'env' }
  if ((Read-SetupDraft).settings) { return 'draft' }
  return 'defaults'
}

# Setup wizard choices that are not secret and not yet installed: config\setup.json in the install folder.
function Read-SetupDraft {
  $draft = [pscustomobject][ordered]@{ version = 1; settings = $null; deployment = [pscustomobject][ordered]@{ mode = ''; tunnelChoice = ''; tunnelId = ''; tunnelName = ''; newTunnelName = '' }; installedAt = '' }
  $path = Join-Path $InstallPath 'config\setup.json'
  if (-not (Test-Path -LiteralPath $path)) { return $draft }
  try {
    $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($json.PSObject.Properties['settings'] -and $json.settings) { $draft.settings = $json.settings }
    if ($json.PSObject.Properties['deployment'] -and $json.deployment) {
      foreach ($p in $draft.deployment.PSObject.Properties.Name) { if ($json.deployment.PSObject.Properties[$p]) { $draft.deployment.$p = [string]$json.deployment.$p } }
    }
    if ($json.PSObject.Properties['installedAt']) { $draft.installedAt = [string]$json.installedAt }
  } catch { }
  return $draft
}

function Save-SetupDraft($Draft) {
  Write-TextFileAtomic (Join-Path $InstallPath 'config\setup.json') ((ConvertTo-Json -InputObject $Draft -Depth 5) + "`n")
  Save-RememberedPath
}

# Remembers the install folder for the next start of webui.ps1 (only the path; nothing secret).
function Save-RememberedPath {
  try { Write-TextFileAtomic $StateFile ((ConvertTo-Json -InputObject ([ordered]@{ installPath = $InstallPath }) -Compress) + "`n") } catch { }
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
  $definition = ConvertTo-ServiceDefinition @{
    name = Get-Field $svc 'name' ''; description = ([string](Get-Field $svc 'description' '')).Substring(0, [Math]::Min(200, ([string](Get-Field $svc 'description' '')).Length))
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

  $traefik = Get-ServicePlan -Settings $settings -Services $list
  $others = @($list | Where-Object { $null -eq $new -or $_.name -ne $new.name })
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
  $result = [ordered]@{ ok = $true; steps = $null; backup = ''; warnings = @() }
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
  $draft.settings = [pscustomobject](ConvertTo-InstanceValues $settings)
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
  if (-not $NoDryRun -and (Test-Path -LiteralPath (Join-Path $here 'install.ps1')) -and $docker.EngineRunning) {
    $installArgs = @('-InstallPath', $InstallPath, '-DryRun')
    $tmp = $null
    if (-not (Test-Path -LiteralPath $envPath)) {
      $tmp = Join-Path ([IO.Path]::GetTempPath()) ("tpx-draft-{0}.env" -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
      [IO.File]::WriteAllText($tmp, (New-DotEnvContent ([IO.File]::ReadAllText((Join-Path $here '.env.example'))) (ConvertTo-InstanceValues $settings)))
      $installArgs += @('-EnvFile', $tmp)
    }
    try { $r = Invoke-PowerShellFile (Join-Path $here 'install.ps1') $installArgs; $lines = $r.Lines }
    finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
  }
  $keyText = (ConvertTo-Json -Compress -Depth 5 -InputObject @((ConvertTo-InstanceValues $settings), $draft.deployment, $InstallPath, @($config.domains | ForEach-Object { $_.id }), $config.accountId))
  $sha = [Security.Cryptography.SHA256]::Create()
  $planKey = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyText))).Replace('-', '').Substring(0, 32)
  return [ordered]@{
    installed = $installed; mode = $mode; steps = $steps; blockers = $blockers; warnings = $warnings
    conflicts = $conflicts; dryRun = $lines; canInstall = ($blockers.Count -eq 0); planKey = $planKey
  }
}

# Runs the previewed installation. The only place where the setup wizard changes Docker or Cloudflare.
function Invoke-InstallRequest($Body) {
  Assert-Confirmed $Body
  $plan = Get-InstallPlan -NoDryRun
  if (-not $plan.canInstall) { Stop-Request 409 ('Installation is blocked: ' + ($plan.blockers -join ' ')) }
  if ([string](Get-Field $Body 'planKey' '') -ne $plan.planKey) { Stop-Request 409 'The settings changed since the preview. Preview the installation again.' }
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
      Write-TextFileAtomic $envPath (New-DotEnvContent ([IO.File]::ReadAllText((Join-Path $here '.env.example'))) (ConvertTo-InstanceValues $settings))
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
  return [ordered]@{ ok = $ok; steps = $results.ToArray(); lines = $lines }
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

# --- Router ----------------------------------------------------------------------------------------------------

function Invoke-ApiRoute($Request, $Body) {
  $m = $Request.Method
  $p = $Request.Path
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
    'GET /api/backups' { return [ordered]@{ backups = @(Get-BackupData) } }
    'POST /api/backups/preview' { return Get-BackupPreview $Body }
    'POST /api/backups/restore' {
      Assert-Installed
      Assert-Confirmed $Body
      $id = [string](Get-Field $Body 'id' '')
      if (@(Get-ServiceBackups $settings | Where-Object { $_.Id -eq $id }).Count -eq 0) { Stop-Request 404 "No backup '$id'." }
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
    if ($Request.Path -eq '/api/session') { $data = [ordered]@{ ok = $true; csrf = $session.Csrf; installPath = $InstallPath } }
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

try { $listener = New-LoopbackListener $Port }
catch { throw "Cannot listen on 127.0.0.1:$Port ($($_.Exception.Message)). Is the web UI already running? Use -Port to pick another port." }
$launchUrl = "http://127.0.0.1:$Port/?k=$($State.LaunchKey)"
Write-Host "Traefik proxy web UI for $InstallPath" -ForegroundColor Cyan
Write-Host "Listening on http://127.0.0.1:$Port/ (this PC only). Press Ctrl+C to stop."
if ($LaunchUrlFile) {
  [IO.File]::WriteAllText($LaunchUrlFile, $launchUrl)
} else {
  Write-Host ''
  Write-Host 'Open this link (it signs this browser in; do not share it):' -ForegroundColor Yellow
  Write-Host "  $launchUrl"
  if (-not $NoBrowser) { Start-Process $launchUrl }
}
try {
  Start-HttpLoop -Listener $listener -StopFile $StopFile -Handler { param($r) Invoke-Request $r }
} finally {
  $listener.Stop()
  Write-Host 'Web UI stopped.'
}
