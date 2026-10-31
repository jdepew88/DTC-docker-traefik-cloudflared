# JSON API of the Adopt page, dot-sourced by webui.ps1 (it uses that script's Stop-Request, Get-Field, Get-Settings, Assert-Installed,
# Assert-Confirmed and Write-Audit). The decisions live in lib\AppAdoption.psm1; this file only keeps the order of the steps:
# a step that changes something requires the step before it, its own confirmation, and the state it was previewed against.

$script:AdoptionHostPattern = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

function Get-AdoptionSpecFromSource($Source, $Facts) {
  $specId = [string](Get-Field $Source 'specId' '')
  if ($specId) {
    $spec = @(Get-AdoptionSpecs $CatalogDir | Where-Object { $_.id -eq $specId })
    if ($spec.Count) { return $spec[0] }
    $existing = $(try { Read-AdoptionState (Get-Settings) $specId } catch { $null })
    if ($existing) { return $existing.spec }
    Stop-Request 404 "No routing specification '$specId'."
  }
  $name = [string](Get-Field $Source 'container' '')
  $c = @(@($Facts.containers) | Where-Object { $_.name -eq $name })
  if (-not $c.Count) { Stop-Request 404 "No container '$name' on this Docker engine." }
  $port = 0
  if (-not [int]::TryParse([string](Get-Field $Source 'port' ''), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { Stop-Request 400 'A port from 1 to 65535 is required.' }
  try { return (New-SingleServiceSpec $c[0] $port) } catch { Stop-Request 400 $_.Exception.Message }
}

# Everything a step needs, read fresh: a step never acts on what the page last saw.
function Get-AdoptionContext($Body) {
  $settings = Get-Settings
  $facts = Get-AdoptionFacts $settings
  $spec = Get-AdoptionSpecFromSource $Body $facts
  $request = ConvertTo-AdoptionRequest (Get-Field $Body 'request' $null)
  $state = Read-AdoptionState $settings $spec.id
  $existing = Get-ExistingAdoptionFiles $spec.id $facts.targets
  $plan = Get-AdoptionPlan -Spec $spec -Request $request -Facts $facts -ExistingFiles $existing
  return [pscustomobject]@{ Settings = $settings; Facts = $facts; Spec = $spec; Request = $request; State = $state; Plan = $plan }
}

function Assert-AdoptionPlanOk($Ctx) { if (-not $Ctx.Plan.ok) { Stop-Request 409 "The preview has blocking problems: $(@($Ctx.Plan.blockers) -join ' ')" } }

function Assert-AdoptionPhase($Ctx, [string[]]$Allowed, [string]$Message) {
  $phase = $(if ($Ctx.State) { [string]$Ctx.State.phase } else { 'new' })
  if ($Allowed -notcontains $phase) { Stop-Request 409 "$Message (current phase: $phase)" }
}

# What is activated must be what was prepared: hostnames or backends changing afterwards need a new preparation.
function Assert-AdoptionSameRequest($Ctx) {
  if ($Ctx.State -and $Ctx.State.PSObject.Properties['fingerprint'] -and [string]$Ctx.State.fingerprint -and $Ctx.State.fingerprint -ne $Ctx.Plan.fingerprint) {
    Stop-Request 409 'The configuration changed since it was prepared. Prepare it again.'
  }
}

function Set-AdoptionField($State, [string]$Name, $Value) { $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }

function Get-AdoptionTargetsView($Targets) {
  $view = @{}
  foreach ($r in 'external', 'internal') { $t = $Targets[$r]; $view[$r] = [ordered]@{ role = $r; mode = $t.mode; name = $t.name; running = [bool]$t.running; entryPoint = $t.entryPoint; network = $t.network; detail = $t.detail } }
  return $view
}

function Invoke-AdoptionApi($Request, $Body, [string]$Key) {
  Assert-Installed
  switch -Exact ($Key) {
    # --- Read-only --------------------------------------------------------------------------------------------------------
    'GET /api/adoption/discover' {
      $settings = Get-Settings
      $facts = Get-AdoptionFacts $settings
      $own = @($settings.StackName); if ($facts.targets.internal.mode -eq 'stack') { $own += $facts.targets.internal.name }
      $inv = ConvertTo-AdoptionInventory -Containers $facts.containers -Routers $facts.routers.external -Specs @(Get-AdoptionSpecs $CatalogDir) -Networks $facts.networks -ProxyNetwork $settings.ProxyNetwork -OwnStacks $own
      return [ordered]@{ inventory = $inv; targets = (Get-AdoptionTargetsView $facts.targets) }
    }
    'GET /api/adoption/status' {
      $settings = Get-Settings
      $facts = Get-AdoptionFacts $settings
      $source = [pscustomobject]@{ specId = [string]$Request.Query['specId']; container = [string]$Request.Query['container']; port = [string]$Request.Query['port'] }
      $spec = Get-AdoptionSpecFromSource $source $facts
      $state = Read-AdoptionState $settings $spec.id
      # Suggestions only: the address of the authentik this deployment already uses, when it uses one.
      $authUser = @(@($facts.services) | Where-Object { $_.PSObject.Properties['auth'] -and $_.auth.endpoint } | Select-Object -First 1)
      $drift = @(); if ($state) { $drift = @(Get-AdoptionDrift $state $facts.containers) }
      return [ordered]@{ id = $spec.id; displayName = $spec.displayName; state = $state; drift = $drift
        suggested = [ordered]@{ authEndpoint = $(if ($authUser.Count) { [string]$authUser[0].auth.endpoint } else { '' }) }; targets = (Get-AdoptionTargetsView $facts.targets) }
    }
    'POST /api/adoption/preview' { return (Get-AdoptionContext $Body).Plan }
    'POST /api/adoption/validate' {
      $ctx = Get-AdoptionContext $Body
      return [ordered]@{ checks = @(Invoke-AdoptionReachability -Settings $ctx.Settings -Plan $ctx.Plan -Facts $ctx.Facts) }
    }
    'POST /api/adoption/cutover-plan' {
      $ctx = Get-AdoptionContext $Body
      return (ConvertTo-CloudflarePlanView (Get-AdoptionCloudflarePlan -Settings $ctx.Settings -Spec $ctx.Spec -Request $ctx.Request -Services $ctx.Facts.services))
    }
    'POST /api/adoption/retire-plan' {
      $ctx = Get-AdoptionContext $Body
      return (Get-AdoptionRetirePlan -Spec $ctx.Spec -Facts $ctx.Facts -OwnStacks @($ctx.Settings.StackName, [string]$ctx.Facts.targets.internal.name) -OwnNetworks @($ctx.Settings.ProxyNetwork, $ctx.Settings.TunnelNetwork))
    }

    # --- Steps ------------------------------------------------------------------------------------------------------------
    'POST /api/adoption/prepare' {
      $ctx = Get-AdoptionContext $Body
      Assert-AdoptionPlanOk $ctx
      if ($ctx.Request.mode -eq 'none') { Stop-Request 409 'This routing has no routes to prepare.' }
      $state = $(if ($ctx.State) { $ctx.State } else { New-AdoptionState $ctx.Spec.id $ctx.Spec $ctx.Request })
      $checks = @(Invoke-AdoptionPrepare -Settings $ctx.Settings -Plan $ctx.Plan -Facts $ctx.Facts)
      $state.spec = $ctx.Spec; $state.request = $ctx.Request; $state.checks = $checks
      $failed = @($checks | Where-Object { $_.state -eq 'failed' }).Count -gt 0
      if ($state.phase -notin 'activated', 'tested', 'cutover', 'verified') { $state.phase = $(if ($failed) { 'previewed' } else { 'prepared' }) }
      Set-AdoptionField $state 'fingerprint' $ctx.Plan.fingerprint
      Add-AdoptionHistory $state 'prepared' "$($checks.Count) file(s) checked"
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
      Write-Audit 'adoption-prepare' "$($ctx.Spec.id) mode=$($ctx.Request.mode)"
      return [ordered]@{ phase = $state.phase; checks = $checks }
    }
    'POST /api/adoption/activate' {
      Assert-Confirmed $Body
      $ctx = Get-AdoptionContext $Body
      Assert-AdoptionPlanOk $ctx
      Assert-AdoptionPhase $ctx @('prepared', 'activated', 'tested') 'Prepare and validate first.'
      Assert-AdoptionSameRequest $ctx
      if (@($ctx.State.checks | Where-Object { $_.kind -eq 'config' -and $_.state -eq 'failed' }).Count) { Stop-Request 409 'Traefik rejected the prepared configuration.' }
      foreach ($t in @($ctx.Plan.targets)) { if ($t.proxyMode -eq 'absent') { Stop-Request 409 'There is no internal proxy to activate on.' } }
      $state = $ctx.State
      try { $steps = @(Invoke-AdoptionActivate -Settings $ctx.Settings -Plan $ctx.Plan -Facts $ctx.Facts -State $state) }
      catch {
        # Half-applied network changes and files are in the state, so that a rollback can undo them.
        Add-AdoptionHistory $state 'activate-failed' $_.Exception.Message
        Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
        Stop-Request 500 $_.Exception.Message
      }
      $state.phase = 'activated'
      Add-AdoptionHistory $state 'activated' ''
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
      Write-Audit 'adoption-activate' "$($ctx.Spec.id) mode=$($ctx.Request.mode) networks=$(@($ctx.Plan.networkChanges | ForEach-Object { $_.command }) -join '; ')"
      # The attachments changed: read the facts again before testing.
      $after = Get-AdoptionContext $Body
      $checks = @(Invoke-AdoptionTests -Settings $after.Settings -Plan $after.Plan -Facts $after.Facts)
      $state.checks = $checks
      if (Test-ChecksPassed $checks) { $state.phase = 'tested' }
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
      return [ordered]@{ phase = $state.phase; steps = $steps; checks = $checks }
    }
    'POST /api/adoption/test' {
      $ctx = Get-AdoptionContext $Body
      Assert-AdoptionPhase $ctx @('activated', 'tested', 'cutover', 'verified', 'cutover-failed') 'Activate first.'
      $checks = @(Invoke-AdoptionTests -Settings $ctx.Settings -Plan $ctx.Plan -Facts $ctx.Facts)
      $state = $ctx.State
      $state.checks = $checks
      $passed = Test-ChecksPassed $checks
      if ($state.phase -in 'activated', 'tested') { $state.phase = $(if ($passed) { 'tested' } else { 'activated' }) }
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
      return [ordered]@{ phase = $state.phase; checks = $checks }
    }
    'POST /api/adoption/cutover' {
      Assert-Confirmed $Body
      if (-not [bool](Get-Field $Body 'approveCloudflare' $false)) { Stop-Request 400 'Cutover needs an explicit approval of its Cloudflare changes.' }
      $ctx = Get-AdoptionContext $Body
      Assert-AdoptionPlanOk $ctx
      Assert-AdoptionPhase $ctx @('tested', 'cutover-failed') 'Every local test must pass before the cutover.'
      $state = $ctx.State
      $steps = New-Object System.Collections.ArrayList
      $manual = @()
      $cfPlan = Get-AdoptionCloudflarePlan -Settings $ctx.Settings -Spec $ctx.Spec -Request $ctx.Request -Services $ctx.Facts.services
      $failed = $false
      if ($cfPlan -and $cfPlan.Connected) {
        if (@($cfPlan.Errors).Count) { Stop-Request 409 "Cloudflare blocks this: $(@($cfPlan.Errors) -join ' ')" }
        if ([string](Get-Field $Body 'fingerprint' '') -ne [string]$cfPlan.Fingerprint) { Stop-Request 409 'Cloudflare changed since you reviewed it. Review the cutover again.' }
        $results = @(Invoke-CloudflareServicePlan -Settings $ctx.Settings -Plan $cfPlan -ServiceName "adopt-$($ctx.Spec.id)" -ConfirmedOverwrites @(Get-Field $Body 'confirmOverwrites' @() | ForEach-Object { [string]$_ }))
        foreach ($r in $results) { if ($r.Status -ne 'Unchanged') { $null = $steps.Add([ordered]@{ name = $r.Summary; status = $r.Status; message = $r.Message }) } }
        $rev = Get-CloudflareReversal $cfPlan $results
        $failed = @($results | Where-Object { $_.Status -in 'Failed', 'Skipped' }).Count -gt 0
        $manual = @($rev.manual)
        if ($failed) {
          # A half-done cutover is worse than none: what it created goes away, what it replaced is listed.
          foreach ($r in @(Invoke-CloudflareReversal -Settings $ctx.Settings -Spec $ctx.Spec -Request $ctx.Request -Created $rev.created -Services $ctx.Facts.services)) { $null = $steps.Add([ordered]@{ name = "Undo: $($r.Summary)"; status = $r.Status; message = $r.Message }) }
          $state.cloudflare = [pscustomobject]@{ created = @(); manualReversal = $manual; fingerprint = '' }
        } else {
          $state.cloudflare = [pscustomobject]@{ created = @($rev.created); manualReversal = $manual; fingerprint = [string]$cfPlan.Fingerprint }
        }
      } elseif ($cfPlan) {
        $null = $steps.Add([ordered]@{ name = 'Cloudflare is not connected'; status = 'Skipped'; message = 'Make the DNS and tunnel changes by hand; Verify then checks them.' })
        $manual = @($cfPlan.ManualSteps | ForEach-Object { [string]$_ })
      }
      $state.phase = $(if ($failed) { 'cutover-failed' } else { 'cutover' })
      Add-AdoptionHistory $state $state.phase ''
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
      Write-Audit 'adoption-cutover' "$($ctx.Spec.id) result=$($state.phase)"
      return [ordered]@{ phase = $state.phase; steps = @($steps.ToArray()); manual = $manual }
    }
    'POST /api/adoption/verify' {
      $ctx = Get-AdoptionContext $Body
      Assert-AdoptionPhase $ctx @('cutover', 'verified') 'Cut over first.'
      $checks = @(Invoke-AdoptionTests -Settings $ctx.Settings -Plan $ctx.Plan -Facts $ctx.Facts)
      $ext = @($ctx.Plan.targets | Where-Object { $_.role -eq 'external' })
      if ($ext.Count) { $checks += @(Invoke-AdoptionPublicChecks $ext[0].hostname ($ext[0].signIn -eq 'authentik')) }
      $int = @($ctx.Plan.targets | Where-Object { $_.role -eq 'internal' })
      if ($int.Count) { $checks += [ordered]@{ kind = 'dns'; role = 'internal'; subject = $int[0].hostname; state = 'unverified'; detail = 'LAN DNS must answer on LAN clients: check it from one.' } }
      $state = $ctx.State
      $state.checks = $checks
      $state.phase = $(if (Test-ChecksPassed $checks) { 'verified' } else { 'cutover' })
      Add-AdoptionHistory $state 'verify' $state.phase
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
      return [ordered]@{ phase = $state.phase; checks = $checks }
    }
    'POST /api/adoption/repair' {
      Assert-Confirmed $Body
      $ctx = Get-AdoptionContext $Body
      if (-not $ctx.State) { Stop-Request 409 'Nothing was adopted.' }
      $steps = @(foreach ($d in @(Get-AdoptionDrift $ctx.State $ctx.Facts.containers | Where-Object { $_.kind -eq 'network-lost' })) {
          $r = Invoke-Docker network connect $d.network $d.container
          [ordered]@{ name = "Attach $($d.container) to $($d.network)"; status = $(if ($r.ExitCode -eq 0) { 'Done' } else { 'Failed' }); message = (@($r.Output) -join ' ').Trim() }
        })
      Write-Audit 'adoption-repair' "$($ctx.Spec.id): $(@($steps).Count) network(s)"
      return [ordered]@{ steps = $steps }
    }
    'POST /api/adoption/rollback' {
      Assert-Confirmed $Body
      $ctx = Get-AdoptionContext $Body
      if (-not $ctx.State) { Stop-Request 409 'Nothing to roll back.' }
      $state = $ctx.State
      $steps = New-Object System.Collections.ArrayList
      $manual = @($state.cloudflare.manualReversal)
      if (@($state.cloudflare.created).Count) {
        try { foreach ($r in @(Invoke-CloudflareReversal -Settings $ctx.Settings -Spec $ctx.Spec -Request $state.request -Created $state.cloudflare.created -Services $ctx.Facts.services)) { $null = $steps.Add([ordered]@{ name = "Undo: $($r.Summary)"; status = $r.Status; message = $r.Message }); if ($r.Status -eq 'Failed') { $manual += "Cloudflare: remove by hand: $($r.Summary)" } } }
        catch { $manual += "Cloudflare could not be changed ($($_.Exception.Message)). Remove by hand: $(@($state.cloudflare.created | ForEach-Object { "$($_.step) $($_.hostname)" }) -join ', ')." }
      }
      foreach ($s in @(Invoke-AdoptionLocalRollback -Settings $ctx.Settings -State $state -Targets $ctx.Facts.targets)) { $null = $steps.Add($s) }
      $state.cloudflare = [pscustomobject]@{ created = @(); manualReversal = @(); fingerprint = '' }
      $state.phase = 'rolled-back'; $state.checks = @()
      Add-AdoptionHistory $state 'rolled-back' ''
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $state
      Write-Audit 'adoption-rollback' $ctx.Spec.id
      return [ordered]@{ phase = 'rolled-back'; steps = @($steps.ToArray()); manual = $manual }
    }
    'POST /api/adoption/retire' {
      Assert-Confirmed $Body
      $ctx = Get-AdoptionContext $Body
      Assert-AdoptionPhase $ctx @('verified') 'Old proxy resources can be retired only after a successful verification.'
      $action = [string](Get-Field $Body 'action' '')
      if ($action -notin 'stop', 'delete') { Stop-Request 400 'The action must be stop or delete.' }
      $names = @(Get-Field $Body 'names' @() | ForEach-Object { [string]$_ })
      if (-not $names.Count) { Stop-Request 400 'Name what to retire.' }
      if ($action -eq 'delete' -and [string](Get-Field $Body 'confirmText' '') -ne $names[0]) { Stop-Request 400 "Deleting needs its name typed: $($names[0])." }
      $plan = Get-AdoptionRetirePlan -Spec $ctx.Spec -Facts $ctx.Facts -OwnStacks @($ctx.Settings.StackName, [string]$ctx.Facts.targets.internal.name) -OwnNetworks @($ctx.Settings.ProxyNetwork, $ctx.Settings.TunnelNetwork)
      $results = @(Invoke-AdoptionRetire -RetirePlan $plan -Action $action -Names $names)
      Add-AdoptionHistory $ctx.State "retire-$action" ($names -join ', ')
      Save-AdoptionState $ctx.Settings $ctx.Spec.id $ctx.State
      Write-Audit "adoption-retire-$action" ($names -join ', ')
      return [ordered]@{ results = $results }
    }
  }
  Stop-Request 404 'Unknown adoption request.'
}
