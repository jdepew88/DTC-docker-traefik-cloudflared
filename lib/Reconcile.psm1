Set-StrictMode -Version 2.0

# Reconciliation: compares what DTC intends for an application (its instance record, observed baseline and the routes
# it owns) with what Docker and Traefik report now, explains each difference and proposes a repair. Pure: callers
# gather the observations (DockerDiscovery inventory, Traefik routers, backend probes) and apply approved repairs
# through the existing change pipeline. Nothing here changes anything.
#
# Repairs are scoped by ownership: a DTC-owned route may be corrected automatically after a preview; anything owned
# by the application's management tool (Arcane, Portainer, Compose files, the container itself) is only explained,
# with the lines to change there.

function Get-RcnProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function New-DriftFinding([string]$Id, [string]$Severity, [string]$Title, [string]$Explanation, [string]$Evidence, $Repair = $null) {
  return [ordered]@{ id = $Id; severity = $Severity; title = $Title; explanation = $Explanation; evidence = $Evidence; repair = $Repair }
}

# A repair: kind (route-update, route-recreate, route-disable, route-resync, network-connect, protection-reapply,
# advice), who owns the change ('dtc' = DTC may apply it after a preview, 'external' = the application's owner must make
# it), the exact change for DTC-owned repairs, and the advice text.
function New-Repair([string]$Kind, [string]$Owner, [string]$Description, $Change = $null, [string[]]$Snippet = @()) {
  return [ordered]@{ kind = $Kind; owner = $Owner; automatic = ($Owner -eq 'dtc'); description = $Description; change = $Change; snippet = @($Snippet) }
}

# Pure: drift of one integrated (or managed) instance. Parameters:
#   -Instance        contract instance (mode, target, baseline, authority, integrations) or a managed app adapted to it
#   -Container       the container that plays the instance's part now (Find-InstanceContainer), $null when missing
#   -Authority       its management authority now (Get-ManagementAuthority)
#   -Routes          routes owned by or pointing at the instance (service definitions)
#   -LoadedRouters   names of routers Traefik reports (svc-<name> style keys), $null when Traefik was not asked
#   -RouteFiles      route names whose YAML file exists, $null when not checked
#   -Probes          { "<host>:<port>" = { result: http|closed|...; status } } backend probes from Traefik's network
#   -Middlewares     middleware names available in this Traefik
#   -Claims          { "<hostname>" = [claims from other owners] }
#   -ProxyNetwork    the shared network name
#   -Volumes         names of volumes that exist (managed instances), $null when not checked
#   -ExpectedVolumes volumes the stack declares (managed instances)
#   -Protection      { "<route>" = { provider; verified } } recorded protection state per route
#   -PortProbes      { "<port>" = { result } } probes of the container's exposed ports from Traefik's network; when given,
#                    a changed port is repaired only to the one port that really answers HTTP
function Get-DriftFindings {
  param($Instance, $Container, $Authority = $null, [object[]]$Routes = @(), [string[]]$LoadedRouters = $null, [string[]]$RouteFiles = $null, $Probes = @{},
    [string[]]$Middlewares = @(), $Claims = @{}, [string]$ProxyNetwork = '', [string[]]$Volumes = $null, [string[]]$ExpectedVolumes = @(), $Protection = @{}, $PortProbes = @{})
  $f = New-Object System.Collections.ArrayList
  $mode = [string](Get-RcnProp $Instance 'mode' 'integrated')
  $base = Get-RcnProp $Instance 'baseline' $null
  $target = Get-RcnProp $Instance 'target' $null
  $owner = $(if ($Authority) { [string]$Authority.label } else { [string](Get-RcnProp (Get-RcnProp $Instance 'authority' $null) 'label' 'its management tool') })
  $external = $mode -ne 'managed'
  $routeOwned = { param($r) $o = Get-RcnProp $r 'owner' $null; ($mode -eq 'managed') -or ($o -and [string](Get-RcnProp $o 'instanceId' '') -eq [string]$Instance.instanceId) }
  $netSnippet = { param([string]$svc) @('services:', "  $(if ($svc) { $svc } else { '<service>' }):", '    networks:', "      - $ProxyNetwork", 'networks:', "  $($ProxyNetwork):", '    external: true') }

  # 1. The container itself.
  if (-not $Container) {
    $null = $f.Add((New-DriftFinding 'container-missing' 'error' 'The application''s container is missing' `
        "No container of $(if ([string](Get-RcnProp $target 'project' '')) { "Compose project '$($target.project)' service '$($target.service)'" } else { "name '$($target.container)'" }) exists. Its routes answer 502 until it is back." `
        "expected: $([string](Get-RcnProp $base 'containerName' (Get-RcnProp $target 'container' '')))" `
        $(if ($external) { New-Repair 'advice' 'external' "Start or redeploy it with $owner. DTC does not recreate containers it does not own." } else { New-Repair 'advice' 'dtc' 'Start the app on the Installed apps page (Start), or restore it from a backup.' })))
    return $f.ToArray()
  }
  $cname = [string](Get-RcnProp $Container 'name' '')
  $state = [string](Get-RcnProp $Container 'state' '')
  if ($state -and $state -ne 'running') {
    $null = $f.Add((New-DriftFinding 'container-stopped' 'error' "The container is $state" "$cname is not running, so Traefik cannot reach it." "state: $state" `
        $(if ($external) { New-Repair 'advice' 'external' "Start it with $owner." } else { New-Repair 'advice' 'dtc' 'Start the app on the Installed apps page.' })))
  }
  if ([string](Get-RcnProp $Container 'health' '') -eq 'unhealthy') {
    $null = $f.Add((New-DriftFinding 'unhealthy' 'warning' 'The container reports unhealthy' "Docker's health check for $cname fails; the application may answer with errors." 'health: unhealthy' (New-Repair 'advice' $(if ($external) { 'external' } else { 'dtc' }) 'Check its logs; the health check is part of the application, not of DTC.')))
  }
  if ($base) {
    $bid = [string](Get-RcnProp $base 'containerId' '')
    $bname = [string](Get-RcnProp $base 'containerName' '')
    if ($bid -and [string](Get-RcnProp $Container 'id' '') -and $bid -ne [string]$Container.id) {
      $null = $f.Add((New-DriftFinding 'container-replaced' 'info' 'The container was recreated' "$owner replaced the container ($bid -> $($Container.id)). Routes use its DNS name, so this alone breaks nothing; the checks below show whether anything else changed." "id: $bid -> $($Container.id)" $null))
    }
    $bp = [string](Get-RcnProp $base 'project' ''); $bs = [string](Get-RcnProp $base 'service' '')
    $cp = [string](Get-RcnProp (Get-RcnProp $Container 'compose' $null) 'project' ''); $cs = [string](Get-RcnProp (Get-RcnProp $Container 'compose' $null) 'service' '')
    if (($bp -or $bs) -and ($bp -ne $cp -or $bs -ne $cs)) {
      $null = $f.Add((New-DriftFinding 'identity-changed' 'warning' 'The container belongs to another Compose service now' "It was recorded as '$bp/$bs' and now reports '$cp/$cs'. Check that this is still the same application." "compose: $bp/$bs -> $cp/$cs" (New-Repair 'advice' 'external' 'If it is the same application, integrate it again to record the new identity; otherwise remove the integration.')))
    }
    $bimg = [string](Get-RcnProp $base 'image' '')
    if ($bimg -and $bimg -ne [string](Get-RcnProp $Container 'image' '')) {
      $null = $f.Add((New-DriftFinding 'image-changed' 'info' 'The image changed' "$owner now runs $([string]$Container.image) (was $bimg). Updates are the owner's decision; DTC only notes it." "image: $bimg -> $([string]$Container.image)" $null))
    }
    $ba = [string](Get-RcnProp $base 'authority' '')
    if ($Authority -and $ba -and $ba -ne [string]$Authority.id) {
      $null = $f.Add((New-DriftFinding 'ownership-changed' 'warning' 'Another tool manages it now' "It was managed by '$ba' and now by '$($Authority.id)' ($((@($Authority.evidence)) -join '; ')). DTC keeps managing only its own integrations." "authority: $ba -> $($Authority.id)" (New-Repair 'advice' 'external' 'Review the integration; switch it to Observed if the new owner should handle routing.')))
    }
  }
  # 2. Networking: Traefik reaches the backend over the shared network by DNS name.
  $nets = @(@(Get-RcnProp $Container 'networks' @()) | ForEach-Object { [string]$_.name })
  $onProxy = $ProxyNetwork -and $nets -contains $ProxyNetwork
  $routed = @($Routes | Where-Object { [bool](Get-RcnProp $_ 'enabled' $true) })
  if ($ProxyNetwork -and -not $onProxy -and $routed.Count) {
    $why = $(if ($base -and @(Get-RcnProp $base 'networks' @()) -contains $ProxyNetwork) { "It was on '$ProxyNetwork' when DTC recorded it; its network membership changed$(if ($base -and [string](Get-RcnProp $base 'containerId' '') -ne [string]$Container.id) { " after $owner recreated the container" })." } else { "It is not on '$ProxyNetwork'." })
    $null = $f.Add((New-DriftFinding 'off-proxy-network' 'error' 'Traefik cannot reach the application' "The application is $(if ($state -eq 'running') { 'running' } else { $state }), but Traefik cannot reach its configured backend. $why" "networks: $($nets -join ', ')" `
        $(if ($external) { New-Repair 'network-connect' 'external' "Add the shared network to the service in $owner's Compose file (lines below) and redeploy it there. A one-off 'docker network connect' also works but is lost when the container is recreated." $null (& $netSnippet ([string](Get-RcnProp (Get-RcnProp $Container 'compose' $null) 'service' ''))) } else { New-Repair 'advice' 'dtc' 'Restart the app from the Installed apps page: its generated Compose file attaches the shared network.' })))
  }
  # 3. Each route.
  $exposed = @(@(Get-RcnProp $Container 'exposed' @()) | ForEach-Object { [int]$_.port })
  $httpPorts = @(@(Get-RcnProp $Container 'ports' @()) | Where-Object { [string]$_.guess -in 'http', 'https' } | ForEach-Object { [int]$_.port })
  $aliases = @(@(@(Get-RcnProp $Container 'networks' @()) | Where-Object { [string]$_.name -eq $ProxyNetwork }) | ForEach-Object { @(Get-RcnProp $_ 'aliases' @()) } | ForEach-Object { [string]$_ })
  foreach ($r in $Routes) {
    $rn = [string]$r.name
    $mine = & $routeOwned $r
    $tgt = Get-RcnProp $r 'target' $null
    $th = [string](Get-RcnProp $tgt 'host' ''); $tp = [int](Get-RcnProp $tgt 'port' 0)
    $enabled = [bool](Get-RcnProp $r 'enabled' $true)
    $repairOwner = $(if ($mine) { 'dtc' } else { 'external' })
    if ($null -ne $RouteFiles -and $enabled -and $RouteFiles -notcontains $rn) {
      $null = $f.Add((New-DriftFinding 'route-file-missing' 'error' "The route file of '$rn' is missing" "traefik\dynamic\svc-$rn.yml is not on disk, so Traefik does not route $(@($r.hostnames) -join ', ')." "file: svc-$rn.yml" (New-Repair 'route-resync' $repairOwner 'Write the route file again from the service registry (validated in a throwaway Traefik first).' ([ordered]@{ route = $rn }))))
    } elseif ($null -ne $LoadedRouters -and $enabled -and -not @($LoadedRouters | Where-Object { $_ -match "^$([regex]::Escape($rn))(-|@|$)" }).Count) {
      $null = $f.Add((New-DriftFinding 'router-not-loaded' 'error' "Traefik has not loaded the route '$rn'" 'The file exists but Traefik reports no such router (rejected or not reloaded).' "router: $rn" (New-Repair 'route-resync' $repairOwner 'Validate and rewrite the route; Traefik reloads it.' ([ordered]@{ route = $rn }))))
    }
    if (-not $enabled) { continue }
    if ($th -and $th -ne $cname -and $aliases -notcontains $th) {
      $null = $f.Add((New-DriftFinding 'route-target-stale' 'error' "The route '$rn' points at a name the container no longer answers to" "It sends requests to '$th', but the application's container is '$cname'$(if ($aliases.Count) { " (aliases on $($ProxyNetwork): $($aliases -join ', '))" })." "target: ${th}:$tp" `
          (New-Repair 'route-update' $repairOwner "Point the route at '$cname' (its container name, resolvable on the shared network)." ([ordered]@{ route = $rn; host = $cname; port = $tp }))))
    }
    if ($tp -and $exposed.Count -and $exposed -notcontains $tp) {
      $answering = @($exposed | Where-Object { $PortProbes -is [System.Collections.IDictionary] -and $PortProbes.Contains([string]$_) -and [string](Get-RcnProp $PortProbes[[string]$_] 'result' '') -in 'http', 'https' })
      $probed = $PortProbes -is [System.Collections.IDictionary] -and $PortProbes.Count -gt 0
      $candidate = $(if ($probed) { if ($answering.Count -eq 1) { [int]$answering[0] } else { 0 } } elseif ($httpPorts.Count -eq 1) { $httpPorts[0] } elseif ($base -and [int](Get-RcnProp $base 'port' 0) -and $exposed -contains [int]$base.port) { [int]$base.port } else { 0 })
      $null = $f.Add((New-DriftFinding 'port-changed' 'error' "The application no longer listens on port $tp" "The route '$rn' uses port $tp, but the container now exposes $($exposed -join ', ')." "ports: $($exposed -join ', ')" `
          $(if ($candidate) { New-Repair 'route-update' $repairOwner "Use port $candidate in the route ($(if ($probed) { 'the only exposed port that answers HTTP from Traefik''s network' } else { 'the container''s web port' }))." ([ordered]@{ route = $rn; port = $candidate }) } else { New-Repair 'advice' $repairOwner 'Choose the web port in the route editor: the container exposes several or none that look like HTTP.' })))
    }
    $pk = "${th}:$tp"
    $probe = $(if ($Probes -is [System.Collections.IDictionary] -and $Probes.Contains($pk)) { $Probes[$pk] } else { $null })
    if ($probe -and [string](Get-RcnProp $probe 'result' '') -notin 'http', 'https', 'tls' -and -not @($f | Where-Object { $_.id -in 'off-proxy-network', 'container-stopped', 'port-changed' }).Count) {
      $null = $f.Add((New-DriftFinding 'backend-unreachable' 'error' "Traefik's network cannot reach $pk" "A request from the shared network to $pk failed ($([string](Get-RcnProp $probe 'result' '')))." "probe: $([string](Get-RcnProp $probe 'result' '')) $([string](Get-RcnProp $probe 'message' ''))" (New-Repair 'advice' $(if ($external) { 'external' } else { 'dtc' }) 'Check that the application listens on that port on all interfaces (not only 127.0.0.1 inside the container).')))
    }
    # Same rule as Test-ServiceDefinition: file-provider references by name (without @file); other providers are not checked.
    $bad = @(@(Get-RcnProp $r 'middlewares' @()) | Where-Object { $m = [string]$_; $prov = $(if ($m.Contains('@')) { ($m -split '@')[1] } else { 'file' }); $Middlewares.Count -and $prov -eq 'file' -and $Middlewares -notcontains ($m -split '@')[0] })
    if ($bad.Count) {
      $null = $f.Add((New-DriftFinding 'middleware-missing' 'error' "The route '$rn' references middleware that does not exist" "$($bad -join ', ') is not defined in this Traefik, so the route is rejected." "middlewares: $($bad -join ', ')" `
          (New-Repair 'route-update' $repairOwner "Remove $($bad -join ', ') from the route (shared middleware is never deleted or rewritten)." ([ordered]@{ route = $rn; middlewares = @(@(Get-RcnProp $r 'middlewares' @()) | Where-Object { $bad -notcontains [string]$_ }) }))))
    }
    $prot = $(if ($Protection -is [System.Collections.IDictionary] -and $Protection.Contains($rn)) { $Protection[$rn] } else { $null })
    $want = [string](Get-RcnProp $prot 'provider' '')
    $have = [string](Get-RcnProp (Get-RcnProp $r 'auth' $null) 'provider' '')
    if ($want -and $want -ne $have) {
      $null = $f.Add((New-DriftFinding 'protection-missing' 'error' "The route '$rn' is no longer protected by $want" "DTC protected it with $want, but the route has $(if ($have) { $have } else { 'no sign-in' }) now. Visitors reach the application without signing in first." "auth: $want -> $(if ($have) { $have } else { 'none' })" `
          (New-Repair 'protection-reapply' $repairOwner "Protect the route with $want again through Identity & Access (preview first)." ([ordered]@{ route = $rn; provider = $want }))))
    }
    foreach ($h in @($r.hostnames)) {
      $cl = @(if ($Claims -is [System.Collections.IDictionary] -and $Claims.Contains([string]$h)) { @($Claims[[string]$h]) | Where-Object { [string](Get-RcnProp $_ 'level' '') -eq 'error' } })
      if ($cl.Count) { $null = $f.Add((New-DriftFinding 'hostname-conflict' 'error' "$h is claimed by another configuration" "$((@($cl | ForEach-Object { [string](Get-RcnProp $_ 'detail' '') })) -join ' ') One configuration must own a hostname." "hostname: $h" (New-Repair 'advice' 'external' 'Remove the other definition (Docker labels or a hand-written file) or choose another hostname.'))) }
    }
  }
  # 4. Integrations whose route disappeared from the registry (removed by hand or by an older backup restore).
  foreach ($g in @(Get-RcnProp $Instance 'integrations' @())) {
    $rn = [string](Get-RcnProp $g 'route' '')
    if ($rn -and -not @($Routes | Where-Object { [string]$_.name -eq $rn }).Count) {
      $spec = Get-RcnProp $g 'spec' $null
      $null = $f.Add((New-DriftFinding 'route-missing' 'error' "The route '$rn' DTC created is gone" "The integration recorded route '$rn', but the service registry no longer has it." "route: $rn" `
          $(if ($spec) { New-Repair 'route-recreate' 'dtc' "Create '$rn' again from the integration record (preview first)." ([ordered]@{ route = $rn }) } else { New-Repair 'advice' 'dtc' 'Remove the integration and integrate the application again.' })))
    }
  }
  # 5. Volumes (managed stacks only: external tools own their volumes).
  if (-not $external -and $null -ne $Volumes) {
    foreach ($v in $ExpectedVolumes) { if ($Volumes -notcontains $v) { $null = $f.Add((New-DriftFinding 'volume-missing' 'error' "Volume $v is missing" "The stack declares $v, but Docker has no such volume: the application starts with empty data." "volume: $v" (New-Repair 'advice' 'dtc' 'Restore the app''s data from a backup (Installed apps > Backups) before using it.'))) } }
  }
  return $f.ToArray()
}

# Pure: the repair plan for a set of findings: route changes DTC may make (merged per route, applied through the
# change pipeline with validation, backup and rollback) and everything else as instructions for the owner.
# $Routes: the current service definitions. Returns { routeChanges[] (route, before, after); resync[]; recreate[];
# protection[]; external[] (advice with snippets); canApply }.
function Get-RepairPlan([object[]]$Findings, [object[]]$Routes = @()) {
  $Findings = @($Findings | Where-Object { $null -ne $_ }); $Routes = @($Routes | Where-Object { $null -ne $_ })
  $changes = [ordered]@{}; $resync = @(); $recreate = @(); $prot = @(); $external = @()
  foreach ($x in $Findings) {
    $r = Get-RcnProp $x 'repair' $null
    if (-not $r) { continue }
    if ([string]$r.owner -ne 'dtc' -or [string]$r.kind -eq 'advice') { $external += [ordered]@{ finding = [string]$x.id; title = [string]$x.title; description = [string]$r.description; snippet = @($r.snippet); owner = [string]$r.owner }; continue }
    $c = Get-RcnProp $r 'change' $null
    $rn = [string](Get-RcnProp $c 'route' '')
    switch ([string]$r.kind) {
      'route-update' {
        $cur = @($Routes | Where-Object { [string]$_.name -eq $rn })[0]
        if (-not $cur) { continue }
        if (-not $changes.Contains($rn)) { $changes[$rn] = [ordered]@{ route = $rn; findings = @(); before = [ordered]@{ host = [string]$cur.target.host; port = [int]$cur.target.port; middlewares = @($cur.middlewares) }; after = [ordered]@{ host = [string]$cur.target.host; port = [int]$cur.target.port; middlewares = @($cur.middlewares) } } }
        $changes[$rn].findings += [string]$x.id
        if (Get-RcnProp $c 'host' '') { $changes[$rn].after.host = [string]$c.host }
        if ([int](Get-RcnProp $c 'port' 0)) { $changes[$rn].after.port = [int]$c.port }
        if ($c -is [System.Collections.IDictionary] -and $c.Contains('middlewares')) { $changes[$rn].after.middlewares = @($c.middlewares) }
      }
      'route-resync' { if ($resync -notcontains $rn) { $resync += $rn } }
      'route-recreate' { if ($recreate -notcontains $rn) { $recreate += $rn } }
      'protection-reapply' { $prot += [ordered]@{ route = $rn; provider = [string](Get-RcnProp $c 'provider' '') } }
    }
  }
  $list = @($changes.Values)
  return [ordered]@{ routeChanges = $list; resync = $resync; recreate = $recreate; protection = $prot; external = $external
    canApply = [bool]($list.Count -or $resync.Count -or $recreate.Count)
    notes = @('Only routes DTC owns are changed; each change is validated in a throwaway Traefik, backed up and rolled back if Traefik rejects it.', 'Containers, Compose files and settings of the application''s owner are never changed by a repair.') }
}

# Pure: a one-line summary of findings for lists.
function Get-DriftSummary([object[]]$Findings) {
  $Findings = @($Findings | Where-Object { $null -ne $_ })
  $err = @($Findings | Where-Object { $_.severity -eq 'error' }).Count
  $warn = @($Findings | Where-Object { $_.severity -eq 'warning' }).Count
  return [ordered]@{ state = $(if ($err) { 'drifted' } elseif ($warn) { 'attention' } else { 'in-sync' }); errors = $err; warnings = $warn; total = @($Findings).Count }
}

Export-ModuleMember -Function Get-DriftFindings, Get-RepairPlan, Get-DriftSummary, New-DriftFinding, New-Repair
