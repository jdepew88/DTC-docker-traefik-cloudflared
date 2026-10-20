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
  [string]$StopFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $here 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $here 'lib\LocalHttp.psm1') -Force
Set-CloudflareApiBase $CloudflareApiBase

if (-not $InstallPath) {
  if ((Test-Path -LiteralPath (Join-Path $here '.env')) -or (Test-Path -LiteralPath (Join-Path $here '.install-manifest.json'))) { $InstallPath = $here }
  else { $InstallPath = Join-Path $env:USERPROFILE '.docker\projects\traefik-proxy' }
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

function Get-Settings { return Get-StackSettings -InstallPath $InstallPath }

function Test-Installed { return (Test-Path -LiteralPath (Join-Path $InstallPath 'compose.yaml')) }

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
  if (-not (Test-Installed)) { Stop-Request 409 "No installation at $InstallPath yet. Finish the Traefik step on the Setup page first." }
  $settings = Get-Settings
  $registry = Read-ServiceRegistry -Settings $settings
  $routers = Get-TraefikApi $settings '/api/http/routers'
  $plan = Get-ServicePlan -Settings $settings -Services $registry.services
  $cf = Read-CloudflareConfig -Settings $settings
  return [ordered]@{
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
  if (-not (Test-Installed)) { Stop-Request 409 'Install the stack first (Setup page).' }
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
    config    = [ordered]@{ accountId = $config.accountId; accountName = $config.accountName; tunnelId = $config.tunnelId; tunnelName = $config.tunnelName }
    managed   = $managed
    connector = [ordered]@{ tokenFile = (Test-TunnelTokenFile $settings); container = $settings.CloudflaredContainer; running = $(if (Test-Installed) { Test-ContainerRunning $settings.CloudflaredContainer } else { $false }) }
    apiBase   = Get-CloudflareApiBase
  }
}

function Save-TokenRequest($Body) {
  $settings = Get-Settings
  if (-not (Test-Path -LiteralPath $InstallPath)) { Stop-Request 409 'Install the stack first; the token is stored in its secrets folder.' }
  $token = ([string](Get-Field $Body 'token' '')).Trim()
  if (-not (Test-CloudflareApiToken $token)) { Stop-Request 400 'That does not look like a Cloudflare API token (it should be a long string of letters, digits, - and _).' }
  $info = Get-CloudflareApiTokenInfo -Settings $settings
  if ($info.Stored -and -not [bool](Get-Field $Body 'confirmReplace' $false)) { Stop-Request 409 'A token is already stored. Confirm that you want to replace it.' @{ needsConfirm = 'replace' } }
  $check = Test-CloudflareToken -Settings $settings -Token $token
  if (-not $check.Valid) { Stop-Request 400 ('Cloudflare did not accept this token; it was not saved. ' + $check.Message) }
  Save-CloudflareApiToken -Settings $settings -Token $token
  $token = $null
  $config = Read-CloudflareConfig -Settings $settings
  if (-not $config.accountId -and @($check.Accounts).Count -eq 1) {
    $config.accountId = $check.Accounts[0].id; $config.accountName = $check.Accounts[0].name
    Save-CloudflareConfig -Settings $settings -Config $config
  }
  Write-Audit 'cloudflare-token-saved' "accounts=$(@($check.Accounts).Count) zones=$(@($check.Zones).Count)"
  return [ordered]@{ saved = $true; accounts = @($check.Accounts); zones = @($check.Zones); message = $check.Message }
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
  if (-not (Test-Installed)) { Stop-Request 409 'Install the stack first.' }
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
      $registry = Read-ServiceRegistry -Settings $settings
      $plan = Get-ServicePlan -Settings $settings -Services $registry.services
      $out = [ordered]@{ ok = -not $plan.HasErrors; issues = @($plan.Issues); drift = $plan.FileChanges; deep = $null }
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
      $config = Assert-CloudflareReady
      return [ordered]@{ zones = @(Get-CloudflareZones -Settings $settings -AccountId $config.accountId) }
    }
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
