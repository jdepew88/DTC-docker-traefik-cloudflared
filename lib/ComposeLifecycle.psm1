Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AppCatalog.psm1')

# Lifecycle of the services of a Docker Compose application. A Compose app may run long-running services (the app, its
# database, cache or message bus) next to one-time jobs (permissions, database initialization, migrations) that are
# meant to finish and exit. A job that completed successfully is not a stopped container, and a running container is not
# proof that the application is ready. Pure functions: the caller collects `docker inspect` output (and the manifest,
# when the app came from the catalog); nothing here talks to Docker.
#
# The role of a service is taken, in this order, from: the manifest (declared role / lifecycle); another service waiting
# for it with depends_on: service_completed_successfully; a restart policy that keeps it running (always,
# unless-stopped); a health check; another service waiting for it to be started or healthy; the restart policy
# on-failure (Docker restarts it only when it fails, so exit code 0 is its normal end). Otherwise the role is unknown
# and the status is reported neutrally: an exit code 0 alone never makes a service a "completed job".

$script:RoleNames = @{ app = 'Application'; database = 'Database'; cache = 'Cache'; messaging = 'Messaging'; worker = 'Background worker'; support = 'Supporting service'
  proxy = 'Proxy'; init = 'Setup job'; migration = 'Migration job'; maintenance = 'Maintenance job' }
# Status key -> tone (ok, neutral, info, warn, err) and label. Tones drive the counts: err = failure, warn = attention.
$script:Statuses = [ordered]@{
  'healthy'              = @('ok', 'Running, healthy')
  'running-unverified'   = @('neutral', 'Running; no health check (readiness not verified)')
  'running'              = @('neutral', 'Running')
  'starting'             = @('warn', 'Running; health check not passed yet')
  'unhealthy'            = @('err', 'Running, unhealthy')
  'restarting'           = @('err', 'Restarting')
  'paused'               = @('warn', 'Paused')
  'completed'            = @('ok', 'Completed successfully')
  'job-running'          = @('info', 'Running (one-time job in progress)')
  'job-failed'           = @('err', 'Failed')
  'job-not-run'          = @('neutral', 'No container')
  'stopped'              = @('neutral', 'Stopped')
  'stopped-unexpectedly' = @('err', 'Stopped unexpectedly')
  'not-started'          = @('neutral', 'Not started')
  'missing'              = @('warn', 'No container')
  'optional-inactive'    = @('neutral', 'Optional, not enabled')
  'exited-unknown'       = @('neutral', 'Exited (code 0); role unknown')
  'exited-error'         = @('err', 'Exited with an error')
}

function Get-LcProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# Pure: the facts of one container from `docker inspect` (parsed JSON). Environment, command line and other values that
# may hold secrets are not copied.
function ConvertFrom-ContainerInspect($Inspect) {
  $cfg = Get-LcProp $Inspect 'Config' $null; $st = Get-LcProp $Inspect 'State' $null; $hc = Get-LcProp $Inspect 'HostConfig' $null
  $labels = Get-LcProp $cfg 'Labels' $null
  $label = { param($n) [string](Get-LcProp $labels $n '') }
  $deps = @(foreach ($d in ((& $label 'com.docker.compose.depends_on') -split ',')) {
      $p = $d.Split(':'); if ($p[0]) { [ordered]@{ service = $p[0]; condition = $(if ($p.Count -gt 1 -and $p[1]) { $p[1] } else { 'service_started' }) } }
    })
  $test = @(Get-LcProp (Get-LcProp $cfg 'Healthcheck' $null) 'Test' @())
  $health = Get-LcProp $st 'Health' $null
  $nets = Get-LcProp (Get-LcProp $Inspect 'NetworkSettings' $null) 'Networks' $null
  $networks = @(if ($nets) { foreach ($n in $nets.PSObject.Properties) {
        $names = @(@(Get-LcProp $n.Value 'Aliases' @()) + @(Get-LcProp $n.Value 'DNSNames' @()) | Where-Object { $_ -and $_ -notmatch '^[0-9a-f]{12,64}$' } | Select-Object -Unique)
        [ordered]@{ name = $n.Name; ip = [string](Get-LcProp $n.Value 'IPAddress' ''); dnsNames = $names }
      } })
  $portMap = Get-LcProp (Get-LcProp $Inspect 'NetworkSettings' $null) 'Ports' $null
  $ports = @(if ($portMap) { foreach ($p in $portMap.PSObject.Properties) {
        $bind = @(Get-LcProp $p 'Value' @() | Where-Object { $_ })
        if ($bind.Count) { foreach ($b in $bind) { [ordered]@{ container = $p.Name; hostIp = [string](Get-LcProp $b 'HostIp' ''); hostPort = [string](Get-LcProp $b 'HostPort' '') } } }
        else { [ordered]@{ container = $p.Name; hostIp = ''; hostPort = '' } }
      } })
  $mounts = @(foreach ($m in @(Get-LcProp $Inspect 'Mounts' @())) { [ordered]@{ type = [string](Get-LcProp $m 'Type' ''); name = [string](Get-LcProp $m 'Name' ''); source = $(if ((Get-LcProp $m 'Type' '') -eq 'bind') { [string](Get-LcProp $m 'Source' '') } else { '' }); target = [string](Get-LcProp $m 'Destination' ''); readOnly = -not [bool](Get-LcProp $m 'RW' $true) } })
  $policy = [string](Get-LcProp (Get-LcProp $hc 'RestartPolicy' $null) 'Name' '')
  return [ordered]@{
    id = ([string](Get-LcProp $Inspect 'Id' '')).Substring(0, [Math]::Min(12, ([string](Get-LcProp $Inspect 'Id' '')).Length))
    name = ([string](Get-LcProp $Inspect 'Name' '')).TrimStart('/'); project = (& $label 'com.docker.compose.project'); service = (& $label 'com.docker.compose.service')
    workingDir = (& $label 'com.docker.compose.project.working_dir'); oneoff = ((& $label 'com.docker.compose.oneoff') -eq 'True')
    app = (& $label 'org.traefik-proxy.app'); managedProject = (& $label 'org.traefik-proxy.project')
    image = [string](Get-LcProp $cfg 'Image' ''); imageId = [string](Get-LcProp $Inspect 'Image' '')
    state = [string](Get-LcProp $st 'Status' ''); exitCode = [int](Get-LcProp $st 'ExitCode' 0); health = [string](Get-LcProp $health 'Status' '')
    hasHealthcheck = [bool]($test.Count -and $test[0] -ne 'NONE'); restartPolicy = $(if ($policy) { $policy } else { 'no' }); restartCount = [int](Get-LcProp $Inspect 'RestartCount' 0)
    startedAt = [string](Get-LcProp $st 'StartedAt' ''); finishedAt = [string](Get-LcProp $st 'FinishedAt' '')
    dependsOn = $deps; networks = $networks; ports = $ports; mounts = $mounts
  }
}

# Pure: who waits for a service, from the depends_on of the others (service -> list of {service, condition}).
function Get-ServiceDependents($Services) {
  $map = @{}
  foreach ($s in @($Services)) {
    foreach ($d in @(Get-LcProp $s 'dependsOn' @())) {
      $t = [string](Get-LcProp $d 'service' ''); if (-not $t) { continue }
      if (-not $map.ContainsKey($t)) { $map[$t] = @() }
      $map[$t] += , ([ordered]@{ service = [string](Get-LcProp $s 'service' ''); condition = [string](Get-LcProp $d 'condition' 'service_started') })
    }
  }
  return $map
}

# Pure: the role and lifecycle of one service, with where that knowledge comes from. $Declared from
# Get-ServiceDeclaredLifecycle (manifest), $Dependents from Get-ServiceDependents.
function Get-ServiceRole($Service, $Declared = $null, [object[]]$Dependents = @()) {
  $out = [ordered]@{ role = ''; roleName = ''; lifecycle = 'unknown'; source = 'none'; reason = '' }
  $named = { param($r) if ($script:RoleNames.ContainsKey($r)) { $script:RoleNames[$r] } else { '' } }
  if ($Declared -and (Get-LcProp $Declared 'declared' $false)) {
    $out.role = [string](Get-LcProp $Declared 'role' ''); $out.lifecycle = [string](Get-LcProp $Declared 'lifecycle' 'unknown'); $out.source = 'manifest'
    $out.roleName = $(if ($out.role) { & $named $out.role } elseif ($out.lifecycle -eq 'run-once') { 'One-time job' } else { 'Service' })
    $out.reason = $(if ($out.lifecycle -eq 'run-once') { 'The app''s manifest declares it a one-time job that exits when its work is done.' } else { 'The app''s manifest declares it a long-running service.' })
    return $out
  }
  $byCompletion = @($Dependents | Where-Object { $_.condition -eq 'service_completed_successfully' })
  $policy = [string](Get-LcProp $Service 'restartPolicy' 'no')
  $waits = @($Dependents | Where-Object { $_.condition -in 'service_started', 'service_healthy' })
  if ($byCompletion.Count) {
    $out.lifecycle = 'run-once'; $out.source = 'compose'; $out.roleName = 'One-time job'
    $out.reason = "Compose: $(@($byCompletion | ForEach-Object { $_.service }) -join ', ') waits for it to complete successfully (depends_on: service_completed_successfully)."
  } elseif ($policy -in 'always', 'unless-stopped') {
    $out.lifecycle = 'long-running'; $out.source = 'compose'; $out.roleName = 'Service'
    $out.reason = "Restart policy '$policy': Docker keeps it running."
  } elseif ([bool](Get-LcProp $Service 'hasHealthcheck' $false)) {
    $out.lifecycle = 'long-running'; $out.source = 'compose'; $out.roleName = 'Service'; $out.reason = 'It has a health check, so it is meant to keep running.'
  } elseif ($waits.Count) {
    $out.lifecycle = 'long-running'; $out.source = 'compose'; $out.roleName = 'Service'
    $out.reason = "$(@($waits | ForEach-Object { $_.service }) -join ', ') waits for it to be started or healthy."
  } elseif ($policy -eq 'on-failure') {
    $out.lifecycle = 'run-once'; $out.source = 'inferred'; $out.roleName = 'One-time job (inferred)'
    $out.reason = "Restart policy 'on-failure': Docker restarts it only when it fails, so exit code 0 is its normal end. Not declared anywhere: inferred."
  } else {
    $out.reason = "Nothing declares whether it should keep running (restart policy '$policy', no health check, nothing waits for it)."
  }
  return $out
}

function New-LcStatus([string]$Key, [string]$Detail = '') {
  $s = $script:Statuses[$Key]
  return [ordered]@{ key = $Key; tone = $s[0]; label = $s[1]; detail = $Detail }
}

# Pure: the status of one service. $Service may have no container (state ''), e.g. a prepared app. $AllStopped: no
# long-running service of the deployment runs (the whole app was stopped, rather than one part failing).
function Get-ServiceStatus($Service, $Role, [switch]$AllStopped, [switch]$Optional, [switch]$Prepared) {
  $state = [string](Get-LcProp $Service 'state' ''); $code = [int](Get-LcProp $Service 'exitCode' 0); $health = [string](Get-LcProp $Service 'health' '')
  $restarts = [int](Get-LcProp $Service 'restartCount' 0)
  $life = [string]$Role.lifecycle
  if (-not $state) {
    if ($Optional) { return New-LcStatus 'optional-inactive' 'Turned off when the app was installed.' }
    if ($Prepared) { return New-LcStatus 'not-started' 'No container yet: Compose creates it when the app starts.' }
    if ($life -eq 'run-once') { return New-LcStatus 'job-not-run' 'Its container does not exist: not run yet, or removed after it completed. Compose creates it again the next time the app starts.' }
    return New-LcStatus 'missing' 'Defined in compose.yaml, but no container exists. Start the app again to create it.'
  }
  if ($state -eq 'created') { return New-LcStatus 'not-started' 'Created, never started.' }
  if ($state -eq 'paused') { return New-LcStatus 'paused' }
  if ($state -eq 'restarting') { return New-LcStatus 'restarting' "Docker is restarting it after a failure (exit code $code, $restarts restart(s))." }
  if ($life -eq 'run-once') {
    if ($state -eq 'running') { return New-LcStatus 'job-running' }
    if ($code -eq 0) { return New-LcStatus 'completed' 'Exited with code 0 after doing its work.' }
    return New-LcStatus 'job-failed' "Exited with code $code. The services that depend on it may not have started; see its logs."
  }
  if ($state -eq 'running') {
    if ($health -eq 'healthy') { return New-LcStatus 'healthy' 'Its health check passes.' }
    if ($health -eq 'unhealthy') { return New-LcStatus 'unhealthy' 'Its health check fails.' }
    if ($health -eq 'starting') { return New-LcStatus 'starting' 'Started; its health check has not passed yet.' }
    if ($life -eq 'long-running') { return New-LcStatus 'running-unverified' 'The container runs, but it has no health check: whether the service inside is ready is not verified.' }
    return New-LcStatus 'running' 'Its role is unknown; it runs.'
  }
  # exited / dead
  if ($life -eq 'long-running') {
    # A whole app that was stopped is "Stopped"; a crash (exit code other than 0, 137 or 143) is reported either way.
    if ($AllStopped -and $code -in 0, 137, 143) { return New-LcStatus 'stopped' "Exited with code $code." }
    return New-LcStatus 'stopped-unexpectedly' "Exited with code $code while it should keep running. See its logs."
  }
  if ($code -eq 0) { return New-LcStatus 'exited-unknown' 'Exited with code 0. Nothing says whether it is a one-time job or a service that stopped; check its purpose before relying on it.' }
  return New-LcStatus 'exited-error' "Exited with code $code."
}

# Pure: the lifecycle of a whole Compose application.
#   $Containers  facts from ConvertFrom-ContainerInspect (this project's containers; one-off `run` containers are ignored)
#   $Manifest    the catalog manifest when the app came from the catalog (declared roles, optional services), else $null
#   $Defined     service names defined in compose.yaml without a container yet (prepared apps, removed containers)
#   $Inactive    services the manifest has but this installation turned off (optional services)
# Returns services (each with role, status, dependencies), counts, state, headline and health.
function Get-DeploymentLifecycle {
  param([object[]]$Containers = @(), $Manifest = $null, [string[]]$Defined = @(), [string[]]$Inactive = @(), [switch]$Prepared)
  $cs = @($Containers | Where-Object { $_ -and -not (Get-LcProp $_ 'oneoff' $false) })
  $names = @(@($cs | ForEach-Object { [string]$_.service }) + @($Defined) + @($Inactive) | Where-Object { $_ } | Select-Object -Unique)
  $mServices = Get-LcProp $Manifest 'services' $null
  $byName = @{}
  foreach ($n in $names) {
    $c = @($cs | Where-Object { $_.service -eq $n })
    $byName[$n] = $(if ($c.Count) { $c[0] } else { [ordered]@{ name = ''; service = $n; state = ''; exitCode = 0; health = ''; hasHealthcheck = $false; restartPolicy = 'no'; restartCount = 0; dependsOn = @(); networks = @(); ports = @(); mounts = @(); image = ''; imageId = '' } })
  }
  # Dependencies of services without a container come from the manifest.
  if ($mServices) {
    foreach ($n in $names) {
      $ms = Get-LcProp $mServices $n $null
      if ($ms -and -not (Get-LcProp $byName[$n] 'state' '')) {
        $byName[$n].dependsOn = @(foreach ($d in @(Get-LcProp $ms 'dependsOn' @())) { [ordered]@{ service = [string]$d.service; condition = [string](Get-LcProp $d 'condition' 'service_started') } })
        $byName[$n].image = [string](Get-LcProp $ms 'image' '')
        $byName[$n].hasHealthcheck = [bool](Get-LcProp $ms 'healthcheck' $null)
        $byName[$n].restartPolicy = [string](Get-LcProp $ms 'restart' 'unless-stopped')
      }
    }
  }
  $dependents = Get-ServiceDependents @($byName.Values)
  $roles = @{}
  foreach ($n in $names) {
    $decl = $null
    if ($mServices -and (Get-LcProp $mServices $n $null)) { $decl = Get-ServiceDeclaredLifecycle (Get-LcProp $mServices $n $null) }
    $roles[$n] = Get-ServiceRole $byName[$n] $decl @($(if ($dependents.ContainsKey($n)) { $dependents[$n] }))
  }
  $lrUp = @($names | Where-Object { $roles[$_].lifecycle -eq 'long-running' -and (Get-LcProp $byName[$_] 'state' '') -eq 'running' }).Count
  $lrAll = @($names | Where-Object { $roles[$_].lifecycle -eq 'long-running' -and $Inactive -notcontains $_ }).Count
  $allStopped = ($cs.Count -gt 0 -and $lrAll -gt 0 -and $lrUp -eq 0)
  # No container at all: a prepared app (never started) or one whose containers were removed outside the manager.
  $isPrepared = (-not $cs.Count)
  $webService = [string](Get-LcProp (Get-LcProp $Manifest 'web' $null) 'service' '')
  $order = @{ 'long-running' = 0; 'run-once' = 1; 'unknown' = 2 }
  $services = @(foreach ($n in ($names | Sort-Object @{ e = { $order[$roles[$_].lifecycle] } }, @{ e = { if ($_ -eq $webService) { 0 } else { 1 } } }, @{ e = { $_ } })) {
      $f = $byName[$n]; $r = $roles[$n]
      $decl = $(if ($mServices -and (Get-LcProp $mServices $n $null)) { Get-ServiceDeclaredLifecycle (Get-LcProp $mServices $n $null) } else { $null })
      $status = Get-ServiceStatus $f $r -AllStopped:$allStopped -Optional:($Inactive -contains $n) -Prepared:$isPrepared
      $expected = $(if ($r.lifecycle -eq 'run-once') { $true } elseif ($r.lifecycle -eq 'long-running') { $false } else { $null })
      [ordered]@{ service = $n; label = $(if ($decl -and $decl.label) { $decl.label } else { $n }); purpose = $(if ($decl) { $decl.purpose } else { '' }); web = ($n -eq $webService)
        container = [string](Get-LcProp $f 'name' ''); image = [string](Get-LcProp $f 'image' ''); imageId = [string](Get-LcProp $f 'imageId' '')
        role = $r.role; roleName = $r.roleName; lifecycle = $r.lifecycle; roleSource = $r.source; roleReason = $r.reason
        state = [string](Get-LcProp $f 'state' ''); exitCode = $(if ((Get-LcProp $f 'state' '') -in 'exited', 'dead') { [int](Get-LcProp $f 'exitCode' 0) } else { $null })
        health = $(if ((Get-LcProp $f 'hasHealthcheck' $false)) { $(if ((Get-LcProp $f 'health' '')) { [string]$f.health } else { 'not run yet' }) } else { 'none' })
        restartPolicy = [string](Get-LcProp $f 'restartPolicy' 'no'); restartCount = [int](Get-LcProp $f 'restartCount' 0)
        expectedToExit = $expected; startedAt = [string](Get-LcProp $f 'startedAt' ''); finishedAt = [string](Get-LcProp $f 'finishedAt' '')
        dependsOn = @(Get-LcProp $f 'dependsOn' @()); dependents = @($(if ($dependents.ContainsKey($n)) { $dependents[$n] }))
        networks = @(Get-LcProp $f 'networks' @()); ports = @(Get-LcProp $f 'ports' @()); mounts = @(Get-LcProp $f 'mounts' @())
        status = $status }
    })
  $lr = @($services | Where-Object { $_.lifecycle -eq 'long-running' -and $_.status.key -ne 'optional-inactive' })
  $jobs = @($services | Where-Object { $_.lifecycle -eq 'run-once' -and $_.status.key -ne 'optional-inactive' })
  $unknown = @($services | Where-Object { $_.lifecycle -eq 'unknown' -and $_.status.key -ne 'optional-inactive' })
  $counts = [ordered]@{
    longRunning = $lr.Count; running = @($lr | Where-Object { $_.state -eq 'running' }).Count
    healthy = @($lr | Where-Object { $_.status.key -eq 'healthy' }).Count; withoutHealthcheck = @($lr | Where-Object { $_.health -eq 'none' }).Count
    jobs = $jobs.Count; jobsCompleted = @($jobs | Where-Object { $_.status.key -eq 'completed' }).Count; jobsFailed = @($jobs | Where-Object { $_.status.key -eq 'job-failed' }).Count
    jobsRunning = @($jobs | Where-Object { $_.status.key -eq 'job-running' }).Count
    unknown = $unknown.Count; unknownRunning = @($unknown | Where-Object { $_.state -eq 'running' }).Count
    optional = @($services | Where-Object { $_.status.key -eq 'optional-inactive' }).Count
  }
  $problems = @($services | Where-Object { $_.status.tone -eq 'err' } | ForEach-Object { "$($_.label): $($_.status.label)$(if ($_.status.detail) { " - $($_.status.detail)" })" })
  $attention = @($services | Where-Object { $_.status.tone -eq 'warn' } | ForEach-Object { "$($_.label): $($_.status.label)" })
  $state = $(if ($isPrepared) { $(if ($Prepared) { 'prepared' } else { 'absent' }) } elseif ($problems.Count) { 'failed' } elseif ($allStopped) { 'stopped' } elseif ($attention.Count) { 'warning' } else { 'running' })
  $parts = @()
  if ($isPrepared) { $parts += $(if ($Prepared) { 'Prepared, not started' } else { 'No containers' }) }
  elseif ($allStopped -and -not $problems.Count) { $parts += "Stopped (0/$($counts.longRunning) running)" }
  else {
    if ($counts.longRunning) { $parts += "$($counts.running)/$($counts.longRunning) running" }
    if ($counts.jobsCompleted) { $parts += "$($counts.jobsCompleted) setup job$(if ($counts.jobsCompleted -ne 1) { 's' }) completed" }
    if ($counts.jobsRunning) { $parts += "$($counts.jobsRunning) setup job$(if ($counts.jobsRunning -ne 1) { 's' }) running" }
    if ($counts.jobsFailed) { $parts += "$($counts.jobsFailed) setup job$(if ($counts.jobsFailed -ne 1) { 's' }) failed" }
    if ($counts.unknown) { $parts += "$($counts.unknown) with unknown role" }
  }
  $healthText = $(if ($isPrepared) { $(if ($Prepared) { 'Not started yet.' } else { 'No container exists for this app (removed, or never started). Start it to create them.' }) }
    elseif ($problems.Count) { "$($problems.Count) problem$(if ($problems.Count -ne 1) { 's' }): $($problems[0])" }
    elseif ($allStopped) { 'The app is stopped.' }
    elseif ($counts.longRunning -and $counts.healthy -eq $counts.longRunning) { 'All long-running services pass their health checks.' }
    elseif ($attention.Count) { $attention[0] }
    else { "No failures detected. $($counts.withoutHealthcheck) of $($counts.longRunning) running service$(if ($counts.longRunning -ne 1) { 's' }) $(if ($counts.withoutHealthcheck -eq 1) { 'has' } else { 'have' }) no health check, so readiness is not verified for $(if ($counts.withoutHealthcheck -eq 1) { 'it' } else { 'them' })." })
  return [ordered]@{ services = $services; counts = $counts; state = $state; headline = ($parts -join " $([char]0x00B7) "); parts = $parts
    health = [ordered]@{ verified = [bool](-not $isPrepared -and -not $problems.Count -and $counts.longRunning -and $counts.healthy -eq $counts.longRunning); text = $healthText; problems = $problems; attention = $attention } }
}

# Pure: completed one-time job containers that may be removed to tidy up, with the reason each one qualifies. Only
# services whose run-once role is declared by the manifest or by Compose (not inferred) and that exited with code 0;
# never a running container. The Compose definitions, volumes and data are not touched by removing them.
function Get-JobCleanupCandidates($Lifecycle) {
  return @(@($Lifecycle.services) | Where-Object {
      $_.lifecycle -eq 'run-once' -and $_.roleSource -in 'manifest', 'compose' -and $_.status.key -eq 'completed' -and $_.container -and $_.state -eq 'exited' -and $_.exitCode -eq 0
    } | ForEach-Object { [ordered]@{ service = $_.service; label = $_.label; container = $_.container; finishedAt = $_.finishedAt; reason = $_.roleReason } })
}

Export-ModuleMember -Function ConvertFrom-ContainerInspect, Get-ServiceDependents, Get-ServiceRole, Get-ServiceStatus, Get-DeploymentLifecycle, Get-JobCleanupCandidates
