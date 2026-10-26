Set-StrictMode -Version 2.0

# Infrastructure Explorer model: what each component of the request path (and each configuration tool around it)
# is, and what has actually been established about it. Every component carries six separate dimensions - detected,
# configured, running, reachable, authenticated, verified - each $true, $false or $null (not checked / not
# applicable), with the evidence for each value. A file existing only ever sets "configured"; it never makes a
# component "verified". Get-InfrastructureFacts reads (never writes) Docker, Traefik's local API and the stored
# configuration; ConvertTo-InfrastructureModel is pure and is unit-tested with fixture facts.

$script:Dimensions = @('detected', 'configured', 'running', 'reachable', 'authenticated', 'verified')

function New-ComponentRecord([string]$Id, [string]$Kind, [bool]$Optional = $false) {
  $dims = [ordered]@{}
  foreach ($d in $script:Dimensions) { $dims[$d] = $null }
  return [ordered]@{ id = $Id; kind = $Kind; optional = $Optional; applicable = $true; dims = $dims; evidence = (New-Object System.Collections.ArrayList); facts = [ordered]@{} }
}

# Records one observation: the dimension becomes $false if any observation for it is $false.
function Add-Evidence($Component, [string]$Dimension, $Value, [string]$Text) {
  if ($script:Dimensions -notcontains $Dimension) { throw "Unknown dimension '$Dimension'." }
  if ($null -ne $Value) {
    $current = $Component.dims[$Dimension]
    $Component.dims[$Dimension] = $(if ($null -eq $current) { [bool]$Value } else { [bool]$current -and [bool]$Value })
  }
  $null = $Component.evidence.Add([ordered]@{ dim = $Dimension; ok = $(if ($null -eq $Value) { $null } else { [bool]$Value }); text = $Text })
}

function Get-FactValue($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $Default
}

# `docker network inspect` reduced to what the Explorer shows. Read-only.
function Get-DockerNetworkFacts([string]$Name) {
  $out = [ordered]@{ name = $Name; exists = $false; driver = ''; internal = $false; subnets = @(); containers = @() }
  if (-not $Name) { return $out }
  $r = Invoke-Docker network inspect $Name
  if ($r.ExitCode -ne 0) { return $out }
  try { $n = @((@($r.Output) -join "`n") | ConvertFrom-Json)[0] } catch { return $out }
  $out.exists = $true
  $out.driver = [string]$n.Driver
  $out.internal = [bool]$n.Internal
  if ($n.IPAM -and $n.IPAM.Config) { $out.subnets = @($n.IPAM.Config | ForEach-Object { [string]$_.Subnet } | Where-Object { $_ }) }
  if ($n.Containers) { $out.containers = @($n.Containers.PSObject.Properties | ForEach-Object { [ordered]@{ name = [string]$_.Value.Name; ipv4 = ([string]$_.Value.IPv4Address -replace '/\d+$', '') } } | Sort-Object { $_.name }) }
  return $out
}

function Get-RouterView($r) {
  $mw = @(); if ($r.PSObject.Properties['middlewares']) { $mw = @($r.middlewares) }
  $eps = @(); if ($r.PSObject.Properties['entryPoints']) { $eps = @($r.entryPoints) }
  return [ordered]@{ name = [string]$r.name; status = [string]$r.status; rule = [string](Get-FactValue $r 'rule' ''); service = [string](Get-FactValue $r 'service' ''); provider = [string](Get-FactValue $r 'provider' ''); entryPoints = $eps; middlewares = $mw }
}

# Collects the facts of one deployment. $Base: the values the web UI already has (mode, installed, docker status,
# stack status, registry services, Cloudflare config/token info, dashboard config, tunnel info). Adds the Traefik API
# lists and the Docker networks. Never writes and never calls Cloudflare.
function Get-InfrastructureFacts {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Base)
  $facts = [ordered]@{}
  foreach ($k in $Base.Keys) { $facts[$k] = $Base[$k] }
  $facts.traefikApi = [ordered]@{ ok = $false; version = ''; entryPoints = @(); routers = @(); services = @(); middlewares = @() }
  $facts.networks = [ordered]@{}
  $docker = $Base.docker
  if (-not (Get-FactValue $docker 'EngineRunning' $false)) { return $facts }
  $stack = $Base.stack
  if (Get-FactValue $stack 'TraefikApi' $false) {
    $t = $facts.traefikApi
    $t.ok = $true
    $t.version = [string](Get-FactValue $stack 'TraefikVersion' '')
    $eps = Get-TraefikApi $Settings '/api/entrypoints'
    if ($eps) { $t.entryPoints = @($eps | ForEach-Object { [ordered]@{ name = [string]$_.name; address = [string]$_.address } }) }
    $routers = Get-TraefikApi $Settings '/api/http/routers'
    if ($routers) { $t.routers = @($routers | ForEach-Object { Get-RouterView $_ }) }
    $services = Get-TraefikApi $Settings '/api/http/services'
    if ($services) {
      $t.services = @($services | ForEach-Object {
          $servers = @(); $statusMap = @{}
          if ($_.PSObject.Properties['loadBalancer'] -and $_.loadBalancer -and $_.loadBalancer.PSObject.Properties['servers']) { $servers = @($_.loadBalancer.servers | ForEach-Object { [string]$_.url }) }
          if ($_.PSObject.Properties['serverStatus'] -and $_.serverStatus) { foreach ($p in $_.serverStatus.PSObject.Properties) { $statusMap[$p.Name] = [string]$p.Value } }
          [ordered]@{ name = [string]$_.name; status = [string]$_.status; provider = [string](Get-FactValue $_ 'provider' ''); type = [string](Get-FactValue $_ 'type' ''); servers = $servers; serverStatus = $statusMap }
        })
    }
    $mws = Get-TraefikApi $Settings '/api/http/middlewares'
    if ($mws) { $t.middlewares = @($mws | ForEach-Object { [ordered]@{ name = [string]$_.name; status = [string]$_.status; type = [string](Get-FactValue $_ 'type' ''); provider = [string](Get-FactValue $_ 'provider' '') } }) }
  }
  $facts.networks.proxy = Get-DockerNetworkFacts $Settings.ProxyNetwork
  $facts.networks.tunnel = Get-DockerNetworkFacts $Settings.TunnelNetwork
  $facts.networks.socket = Get-DockerNetworkFacts "$($Settings.StackName)_socket-internal"
  # Containers that services point at by name: state only (never their environment or labels).
  $targets = @{}
  foreach ($s in @($Base.services)) { if ($s.target.type -eq 'docker' -and $s.target.host) { $targets[[string]$s.target.host] = $true } }
  $facts.containerManagers = @(Get-ContainerManagers)
  $facts.targets = [ordered]@{}
  foreach ($name in $targets.Keys) {
    $r = Invoke-Docker inspect $name --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Config.Image}}'
    if ($r.ExitCode -eq 0) { $p = ((@($r.Output) -join '').Trim()).Split('|'); $facts.targets[$name] = [ordered]@{ exists = $true; state = $p[0]; health = $p[1]; image = $p[2] } }
    else { $facts.targets[$name] = [ordered]@{ exists = $false; state = 'missing'; health = ''; image = '' } }
  }
  return $facts
}

# Running container managers (Portainer, Arcane, Dockge, Yacht) with a port published on this PC: name and local URL.
function Get-ContainerManagers {
  $r = Invoke-Docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}'
  if ($r.ExitCode -ne 0) { return @() }
  return @(foreach ($line in @($r.Output)) {
      $p = ([string]$line).Split('|')
      if ($p.Count -lt 3 -or $p[1] -notmatch '(^|/)(portainer-ce|portainer-ee|portainer|arcane|dockge|yacht)(:|@|$)') { continue }
      $kind = $Matches[2] -replace '-(ce|ee)$', ''
      $m = [regex]::Matches($p[2], '(?:[\d.]+|\[::\]|::):(\d+)->(\d+)/tcp')
      if ($m.Count -eq 0) { continue }
      $hostPort = [int]$m[0].Groups[1].Value; $inner = [int]$m[0].Groups[2].Value
      $scheme = $(if ($inner -in 443, 9443, 8443) { 'https' } else { 'http' })
      [ordered]@{ name = $p[0]; kind = $kind; image = $p[1]; url = "${scheme}://127.0.0.1:$hostPort/" }
    })
}

function Get-ContainerFact($Facts, [string]$Role) {
  foreach ($c in @(Get-FactValue $Facts.stack 'Containers' @())) { if ((Get-FactValue $c 'Role' '') -eq $Role) { return $c } }
  return $null
}

function Add-ContainerEvidence($Component, $Container, [bool]$Expected = $true) {
  if (-not $Container -or -not (Get-FactValue $Container 'Exists' $false)) {
    Add-Evidence $Component 'detected' $(if ($Expected) { $false } else { $null }) "Container $(Get-FactValue $Container 'Name' '') was not found."
    Add-Evidence $Component 'running' $(if ($Expected) { $false } else { $null }) 'Not running.'
    return
  }
  $name = Get-FactValue $Container 'Name' ''
  Add-Evidence $Component 'detected' $true "Container $name exists ($(Get-FactValue $Container 'Image' ''))."
  $state = Get-FactValue $Container 'State' ''
  $health = Get-FactValue $Container 'Health' ''
  Add-Evidence $Component 'running' ($state -eq 'running') "Docker reports $name as $state$(if ($health) { ", health $health" })."
  if ($health -and $health -ne 'healthy' -and $state -eq 'running') { Add-Evidence $Component 'verified' $false "Its own health check reports $health." }
  $Component.facts.container = $name
  $Component.facts.image = Get-FactValue $Container 'Image' ''
  $Component.facts.startedAt = Get-FactValue $Container 'StartedAt' ''
}

function Get-RouterHosts([string]$Rule) {
  return @([regex]::Matches($Rule, 'Host\(\s*`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
}

# The owner of a router: its name without the provider and without the suffixes this tool and Traefik use for
# variants of one route (public-dashboard / public-dashboard-root, svc-x / svc-x-strip).
function Get-RouterOwner([string]$Name) {
  $n = ($Name -replace '@[^@]+$', '')
  if ($n -match '^(public-dashboard)') { return 'public-dashboard' }
  return ($n -replace '-(root|redirect|strip|secure|insecure|outpost)$', '')
}

# Pure: facts -> components (request path + tools) and one flow per service.
function ConvertTo-InfrastructureModel {
  param([Parameter(Mandatory = $true)]$Facts)
  $mode = [string](Get-FactValue $Facts 'mode' 'local'); if (-not $mode) { $mode = 'local' }
  $tunnelMode = $mode -eq 'tunnel'
  $installed = [bool](Get-FactValue $Facts 'installed' $false)
  $cf = Get-FactValue $Facts 'cloudflare' ([ordered]@{})
  $token = Get-FactValue $Facts 'token' ([ordered]@{})
  $tunnel = Get-FactValue $Facts 'tunnel' $null
  $api = Get-FactValue $Facts 'traefikApi' ([ordered]@{ ok = $false; routers = @(); services = @(); middlewares = @(); entryPoints = @() })
  $nets = Get-FactValue $Facts 'networks' ([ordered]@{})
  $services = @(Get-FactValue $Facts 'services' @())
  $enabled = @($services | Where-Object { $_.enabled })
  $published = @($enabled | Where-Object { $_.cloudflare.publish })
  $dash = Get-FactValue $Facts 'dashboard' ([ordered]@{ enabled = $false; hostname = '' })
  $domains = @(Get-FactValue $cf 'domains' @())
  $tokenOk = [bool](Get-FactValue $token 'Stored' $false) -and [bool](Get-FactValue $token 'Readable' $false)
  $routers = @(Get-FactValue $api 'routers' @())
  $tServices = @(Get-FactValue $api 'services' @())
  $components = New-Object System.Collections.ArrayList
  $addC = { param($c) $null = $components.Add($c); $c }

  $c = & $addC (New-ComponentRecord 'browser' 'client')
  $c.facts.note = 'Any browser; nothing to configure.'

  # Cloudflare part of the path (tunnel mode only).
  $c = & $addC (New-ComponentRecord 'dns' 'hop')
  if (-not $tunnelMode) { $c.applicable = $false }
  else {
    Add-Evidence $c 'configured' ($domains.Count -gt 0) $(if ($domains.Count) { "Allowed domains: $(($domains | ForEach-Object { $_.name }) -join ', ')." } else { 'No allowed domain is saved.' })
    Add-Evidence $c 'verified' $null 'Individual DNS records are checked per service (Check health).'
    $c.facts.domains = @($domains | ForEach-Object { [ordered]@{ name = $_.name; id = $_.id } })
  }
  $c = & $addC (New-ComponentRecord 'edge' 'hop')
  if (-not $tunnelMode) { $c.applicable = $false }
  else {
    Add-Evidence $c 'configured' ($domains.Count -gt 0) $(if ($domains.Count) { 'Cloudflare serves HTTPS for the allowed domains.' } else { 'No domain is set up.' })
    Add-Evidence $c 'authenticated' $(if ([bool](Get-FactValue $token 'Stored' $false)) { $tokenOk } else { $null }) $(if (-not (Get-FactValue $token 'Stored' $false)) { 'No API token is stored (Cloudflare automation is not connected).' } elseif ($tokenOk) { 'The stored API token can be decrypted by this Windows account.' } else { 'The stored API token cannot be decrypted by this Windows account.' })
    $c.facts.accountId = [string](Get-FactValue $cf 'accountId' '')
    $c.facts.accountName = [string](Get-FactValue $cf 'accountName' '')
  }
  $c = & $addC (New-ComponentRecord 'access' 'hop' $true)
  $accessUsers = @($published | Where-Object { $_.cloudflare.access })
  $accessWanted = $accessUsers.Count -gt 0 -or [bool](Get-FactValue $dash 'enabled' $false)
  if (-not $tunnelMode -or -not $accessWanted) {
    $c.applicable = $tunnelMode -and $accessWanted
    Add-Evidence $c 'configured' $null $(if (-not $tunnelMode) { 'Local-only deployment: Cloudflare Access is not used.' } else { 'No published service asks for a Cloudflare Access login.' })
  } else {
    Add-Evidence $c 'configured' $true "$($accessUsers.Count) service(s)$(if (Get-FactValue $dash 'enabled' $false) { ' and the Traefik dashboard' }) are set to require a Cloudflare Access login."
    $managed = Get-FactValue $cf 'managed' $null
    $apps = 0
    if ($managed) { foreach ($p in $managed.PSObject.Properties) { if (Get-FactValue $p.Value 'accessAppId' '') { $apps++ } } }
    Add-Evidence $c 'detected' $(if ($apps -gt 0) { $true } else { $null }) "$apps Access application(s) recorded as created by this tool."
    Add-Evidence $c 'verified' $null 'Whether Access really protects a hostname is checked per service (Check health).'
  }
  $c = & $addC (New-ComponentRecord 'tunnel' 'hop')
  if (-not $tunnelMode) { $c.applicable = $false }
  else {
    $tid = [string](Get-FactValue $cf 'tunnelId' '')
    Add-Evidence $c 'configured' ([bool]$tid) $(if ($tid) { "Tunnel '$(Get-FactValue $cf 'tunnelName' '')' is recorded." } else { 'No tunnel is recorded in config\cloudflare.json.' })
    Add-Evidence $c 'detected' ([bool](Get-FactValue $Facts 'tunnelTokenPresent' $false)) $(if (Get-FactValue $Facts 'tunnelTokenPresent' $false) { 'The connector token file is present (secrets\cloudflare_tunnel_token).' } else { 'The connector token file is missing.' })
    if ($tunnel) {
      $ok = -not (Get-FactValue $tunnel 'error' '')
      Add-Evidence $c 'authenticated' $ok $(if ($ok) { 'Cloudflare answered the read-only tunnel request.' } else { "Cloudflare did not answer: $(Get-FactValue $tunnel 'error' '')" })
      if ($ok) {
        $conns = [int](Get-FactValue $tunnel 'connections' 0)
        $healthy = (Get-FactValue $tunnel 'status' '') -eq 'healthy' -or $conns -gt 0
        Add-Evidence $c 'running' $healthy "Cloudflare reports the tunnel as '$(Get-FactValue $tunnel 'status' '')' with $conns connection(s)."
        Add-Evidence $c 'verified' $healthy $(if ($healthy) { 'Verified with Cloudflare: a connector is connected.' } else { 'Cloudflare sees no connected connector.' })
      }
    } else { Add-Evidence $c 'verified' $null $(if ($tokenOk) { 'The tunnel was not checked with Cloudflare.' } else { 'Not checked: Cloudflare automation is not connected, so the tunnel cannot be asked about.' }) }
    $c.facts.tunnelId = $tid
    $c.facts.tunnelName = [string](Get-FactValue $cf 'tunnelName' '')
  }
  $c = & $addC (New-ComponentRecord 'cloudflared' 'hop')
  if (-not $tunnelMode) { $c.applicable = $false }
  else {
    Add-ContainerEvidence $c (Get-ContainerFact $Facts 'cloudflared') $installed
    if ($tunnel -and -not (Get-FactValue $tunnel 'error' '')) {
      $conns = [int](Get-FactValue $tunnel 'connections' 0)
      Add-Evidence $c 'reachable' ($conns -gt 0) $(if ($conns -gt 0) { "Cloudflare sees $conns connection(s) from a connector." } else { 'Cloudflare sees no connection from cloudflared.' })
      if ($conns -gt 0) { Add-Evidence $c 'verified' $true 'Its outbound connections to Cloudflare are confirmed by Cloudflare.' }
    }
    $tn = Get-FactValue $nets 'tunnel' $null
    if ($tn -and $tn.exists) { $c.facts.network = "$($tn.name) ($((@($tn.subnets)) -join ', '))" }
    $c.facts.cloudflaredIp = [string](Get-FactValue $Facts 'cloudflaredIp' '')
  }

  # Traefik: the container and its entry point, then router -> middleware -> service.
  $c = & $addC (New-ComponentRecord 'traefik' 'hop')
  Add-Evidence $c 'configured' $installed $(if ($installed) { 'compose.yaml and traefik\traefik.yml are installed.' } else { 'Not installed yet.' })
  Add-ContainerEvidence $c (Get-ContainerFact $Facts 'traefik') $installed
  $apiOk = [bool](Get-FactValue $api 'ok' $false)
  if ($installed) { Add-Evidence $c 'reachable' $apiOk $(if ($apiOk) { "Its API answers on 127.0.0.1:$(Get-FactValue $Facts 'dashboardPort' '') (version $(Get-FactValue $api 'version' ''))." } else { 'Its API does not answer.' }) }
  $web = @(@(Get-FactValue $api 'entryPoints' @()) | Where-Object { $_.name -eq 'web' })
  if ($apiOk) { Add-Evidence $c 'verified' ($web.Count -gt 0) $(if ($web.Count) { "Entry point 'web' listens on $($web[0].address) inside the container (published on 127.0.0.1:$(Get-FactValue $Facts 'httpPort' ''))." } else { "Entry point 'web' is missing." }) }
  $c.facts.entryPoints = @(Get-FactValue $api 'entryPoints' @())
  $c.facts.version = [string](Get-FactValue $api 'version' '')

  $c = & $addC (New-ComponentRecord 'router' 'hop')
  $expected = @($enabled | ForEach-Object { "svc-$($_.name)@file" })
  if ((Get-FactValue $dash 'enabled' $false) -and (Get-FactValue $dash 'router' '')) { $expected += [string]$dash.router }
  Add-Evidence $c 'configured' ($expected.Count -gt 0) $(if ($expected.Count) { "$($expected.Count) router(s) generated in traefik\dynamic." } else { 'No service is enabled yet.' })
  if ($apiOk -and $expected.Count) {
    $loaded = @($routers | Where-Object { $expected -contains $_.name })
    $bad = @($loaded | Where-Object { $_.status -ne 'enabled' })
    $missing = @($expected | Where-Object { $n = $_; -not ($routers | Where-Object { $_.name -eq $n }) })
    Add-Evidence $c 'running' ($missing.Count -eq 0) $(if ($missing.Count) { "Not loaded by Traefik: $($missing -join ', ')." } else { "Traefik loaded all $($expected.Count) router(s)." })
    if ($bad.Count) { Add-Evidence $c 'verified' $false "Traefik reports errors for: $(($bad | ForEach-Object { $_.name }) -join ', ')." }
    elseif (-not $missing.Count) { Add-Evidence $c 'verified' $null 'Traefik accepted every routing rule; whether requests arrive is tested per service (Check health).' }
  }
  $owners = @($expected | ForEach-Object { Get-RouterOwner $_ })
  $others = @($routers | Where-Object { $_.provider -ne 'internal' -and $owners -notcontains (Get-RouterOwner $_.name) })
  if ($others.Count) { Add-Evidence $c 'detected' $true "$($others.Count) other router(s) not created by this tool (hand-written files or Docker labels)." }
  $c.facts.routers = $routers

  $c = & $addC (New-ComponentRecord 'middleware' 'hop' $true)
  $wanted = @($enabled | ForEach-Object { @($_.middlewares) } | Where-Object { $_ } | Sort-Object -Unique)
  if (-not $wanted.Count) { $c.applicable = $enabled.Count -gt 0; Add-Evidence $c 'configured' $null 'No middleware is used by the enabled services.' }
  else {
    Add-Evidence $c 'configured' $true "Used: $($wanted -join ', ')."
    if ($apiOk) {
      $mw = @(Get-FactValue $api 'middlewares' @())
      $missing = @($wanted | Where-Object { $n = $_; -not ($mw | Where-Object { $_.name -eq $n -and $_.status -eq 'enabled' }) })
      Add-Evidence $c 'running' ($missing.Count -eq 0) $(if ($missing.Count) { "Not available in Traefik: $($missing -join ', ')." } else { 'Traefik has loaded every middleware the services use.' })
    }
  }
  $c.facts.middlewares = @(Get-FactValue $api 'middlewares' @())

  # Sign-in in front of applications (authentik ForwardAuth): a hop only for services that use it.
  $c = & $addC (New-ComponentRecord 'identity' 'hop' $true)
  $idf = Get-FactValue $Facts 'identity' $null
  $protected = @($enabled | Where-Object { $_.PSObject.Properties['auth'] -and $_.auth.provider -eq 'authentik' })
  if (-not $protected.Count) {
    $c.applicable = $false
    if ($idf -and [string](Get-FactValue $idf 'provider' '')) { Add-Evidence $c 'configured' $null "Identity provider: $(Get-FactValue $idf 'provider' ''); no application uses it yet." }
  } else {
    Add-Evidence $c 'configured' $true "$($protected.Count) application(s) sign in through authentik: $(($protected | ForEach-Object { $_.name }) -join ', ')."
    $srv = Get-FactValue $idf 'server' $null
    if ($srv) {
      Add-Evidence $c 'running' ([string](Get-FactValue $srv 'state' '') -eq 'running' -and [string](Get-FactValue $srv 'health' '') -ne 'unhealthy') "authentik server $(Get-FactValue $srv 'name' ''): $(Get-FactValue $srv 'state' '')$(if (Get-FactValue $srv 'health' '') { " ($(Get-FactValue $srv 'health' ''))" })."
      Add-Evidence $c 'reachable' ([bool](Get-FactValue $srv 'onProxyNetwork' $false)) $(if (Get-FactValue $srv 'onProxyNetwork' $false) { 'On the shared network: Traefik asks it about every request (fails closed if it does not answer).' } else { 'Not on the shared network: Traefik cannot ask it, so protected applications refuse every request.' })
    } else { Add-Evidence $c 'running' $false 'No authentik server container is recorded on Identity & Access.' }
    $verified = @(Get-FactValue $idf 'verified' @())
    Add-Evidence $c 'authenticated' $null 'Sign-in redirects are checked on Identity & Access (Run checks).'
    Add-Evidence $c 'verified' $(if ($verified.Count) { $true } else { $null }) $(if ($verified.Count) { "Real sign-ins recorded by authentik for: $($verified -join ', ')." } else { 'Verified only after a real sign-in (Identity & Access).' })
  }
  $c.facts.protected = @($protected | ForEach-Object { [ordered]@{ name = $_.name; hostnames = @($_.hostnames); endpoint = $_.auth.endpoint } })
  $c.facts.identity = $idf

  $c = & $addC (New-ComponentRecord 'service' 'hop')
  $expectedSvc = @($enabled | ForEach-Object { "svc-$($_.name)@file" })
  Add-Evidence $c 'configured' ($expectedSvc.Count -gt 0) $(if ($expectedSvc.Count) { "$($expectedSvc.Count) backend service definition(s)." } else { 'No service is enabled yet.' })
  if ($apiOk -and $expectedSvc.Count) {
    $loaded = @($tServices | Where-Object { $expectedSvc -contains $_.name })
    Add-Evidence $c 'running' ($loaded.Count -eq $expectedSvc.Count) "Traefik loaded $($loaded.Count) of $($expectedSvc.Count) service(s)."
    $down = @($loaded | Where-Object { @($_.serverStatus.Values) -contains 'DOWN' })
    Add-Evidence $c 'reachable' $(if ($down.Count) { $false } else { $null }) $(if ($down.Count) { "Health checks report DOWN for: $(($down | ForEach-Object { $_.name }) -join ', ')." } else { 'Traefik only knows whether a backend answers when a health check is configured; use Check health to send a real request.' })
  }
  $c.facts.services = $tServices

  $c = & $addC (New-ComponentRecord 'network' 'hop')
  $pn = Get-FactValue $nets 'proxy' $null
  $netName = [string](Get-FactValue $Facts 'proxyNetwork' '')
  Add-Evidence $c 'configured' ([bool]$netName) "PROXY_NETWORK=$netName in .env."
  if ($pn) {
    Add-Evidence $c 'detected' ([bool]$pn.exists) $(if ($pn.exists) { "Docker network '$($pn.name)' exists ($($pn.driver), $(@($pn.subnets) -join ', '))." } else { "Docker network '$($pn.name)' does not exist." })
    if ($pn.exists) {
      $tc = [string](Get-FactValue (Get-ContainerFact $Facts 'traefik') 'Name' '')
      $attached = @($pn.containers | Where-Object { $_.name -eq $tc }).Count -gt 0
      Add-Evidence $c 'reachable' $attached $(if ($attached) { "Traefik ($tc) is attached, with $(@($pn.containers).Count - 1) other container(s)." } else { "Traefik ($tc) is not attached to it." })
    }
    $c.facts.network = $pn
  }

  $c = & $addC (New-ComponentRecord 'app' 'hop')
  $targets = Get-FactValue $Facts 'targets' ([ordered]@{})
  if (-not $enabled.Count) { Add-Evidence $c 'configured' $false 'No application is published yet.' }
  else {
    Add-Evidence $c 'configured' $true "$($enabled.Count) enabled service(s): $(($enabled | ForEach-Object { $_.name }) -join ', ')."
    foreach ($s in $enabled) {
      if ($s.target.type -ne 'docker') { Add-Evidence $c 'detected' $null "$($s.name): $($s.target.host):$($s.target.port) runs outside Docker (checked with Check health)."; continue }
      $t = Get-FactValue $targets ([string]$s.target.host) $null
      if (-not $t) { continue }
      Add-Evidence $c 'detected' ([bool]$t.exists) "$($s.name): container $($s.target.host) $(if ($t.exists) { 'exists' } else { 'was not found' })."
      if ($t.exists) {
        Add-Evidence $c 'running' ($t.state -eq 'running') "$($s.name): $($s.target.host) is $($t.state)$(if ($t.health) { " ($($t.health))" })."
        if ($pn -and $pn.exists) {
          $on = @($pn.containers | Where-Object { $_.name -eq $s.target.host }).Count -gt 0
          Add-Evidence $c 'reachable' $on "$($s.name): $(if ($on) { 'attached to' } else { 'NOT attached to' }) '$($pn.name)'."
        }
      }
    }
    Add-Evidence $c 'verified' $null 'An application is verified only by a real HTTP request (Check health).'
  }

  # Configuration tools and supporting components (not hops of a request).
  $docker = Get-FactValue $Facts 'docker' $null
  $c = & $addC (New-ComponentRecord 'docker' 'tool')
  Add-Evidence $c 'detected' ([bool](Get-FactValue $docker 'CliFound' $false)) $(if (Get-FactValue $docker 'CliFound' $false) { 'The docker command is installed.' } else { 'The docker command was not found.' })
  Add-Evidence $c 'running' ([bool](Get-FactValue $docker 'EngineRunning' $false)) $(if (Get-FactValue $docker 'EngineRunning' $false) { "Docker Engine $(Get-FactValue $docker 'ServerVersion' '') ($(Get-FactValue $docker 'OsType' '') containers) answers." } else { 'The Docker engine is not reachable.' })
  $c.facts.context = [string](Get-FactValue $docker 'Context' '')
  $c.facts.serverVersion = [string](Get-FactValue $docker 'ServerVersion' '')
  $c = & $addC (New-ComponentRecord 'compose' 'tool')
  Add-Evidence $c 'detected' ([bool](Get-FactValue $docker 'ComposeOk' $false)) "Docker Compose $(Get-FactValue $docker 'ComposeVersion' 'not found')."
  Add-Evidence $c 'configured' $installed $(if ($installed) { "Project '$(Get-FactValue $Facts 'stackName' '')' (compose.yaml + .env)." } else { 'No compose.yaml yet.' })
  $c.facts.project = [string](Get-FactValue $Facts 'stackName' '')
  $c = & $addC (New-ComponentRecord 'socket-proxy' 'support')
  Add-ContainerEvidence $c (Get-ContainerFact $Facts 'socket-proxy') $installed
  $sn = Get-FactValue $nets 'socket' $null
  if ($sn -and $sn.exists) { Add-Evidence $c 'verified' ([bool]$sn.internal) $(if ($sn.internal) { "Network '$($sn.name)' is internal: no route outside Docker." } else { "Network '$($sn.name)' is NOT internal." }) }
  $c = & $addC (New-ComponentRecord 'manager' 'tool')
  Add-Evidence $c 'running' $true 'This website (127.0.0.1 only). Stopping it does not affect any request path.'

  # One flow per service: which router, service and backend it uses.
  $flows = @(foreach ($s in $services) {
      $rid = "svc-$($s.name)@file"
      $r = @($routers | Where-Object { $_.name -eq $rid })
      $ts = @($tServices | Where-Object { $_.name -eq $rid })
      [ordered]@{
        name = $s.name; displayName = $(if (Get-FactValue $s 'displayName' '') { $s.displayName } else { $s.name }); enabled = [bool]$s.enabled
        hostnames = @($s.hostnames); pathPrefix = [string](Get-FactValue $s 'pathPrefix' '')
        exposure = $(if (-not $s.cloudflare.publish) { 'local' } elseif ($s.cloudflare.access) { 'access' } else { 'public' })
        target = [ordered]@{ type = $s.target.type; host = $s.target.host; port = $s.target.port; protocol = $s.target.protocol }
        router = $(if ($r.Count) { [ordered]@{ name = $r[0].name; status = $r[0].status; rule = $r[0].rule; middlewares = @($r[0].middlewares) } } else { $null })
        service = $(if ($ts.Count) { [ordered]@{ name = $ts[0].name; status = $ts[0].status; servers = @($ts[0].servers) } } else { $null })
        middlewares = @($s.middlewares)
        auth = $(if ($s.PSObject.Properties['auth']) { [string]$s.auth.provider } else { '' })
      }
    })
  # Hostnames claimed by routers of more than one owner (a service, the dashboard pair, a hand-written file, a
  # container's labels): competing definitions. Several routers of one owner (e.g. path variants) are fine.
  $claims = @{}
  foreach ($r in $routers) {
    $owner = Get-RouterOwner $r.name
    foreach ($h in (Get-RouterHosts $r.rule)) {
      if (-not $claims.ContainsKey($h)) { $claims[$h] = @{} }
      if (-not $claims[$h].ContainsKey($owner)) { $claims[$h][$owner] = New-Object System.Collections.ArrayList }
      $null = $claims[$h][$owner].Add($r.name)
    }
  }
  $conflicts = @(foreach ($h in ($claims.Keys | Sort-Object)) { if ($claims[$h].Count -gt 1) { [ordered]@{ hostname = $h; routers = @($claims[$h].Values | ForEach-Object { $_ }) } } })
  return [ordered]@{ mode = $mode; installed = $installed; components = $components.ToArray(); flows = $flows; conflicts = $conflicts; containerManagers = @(Get-FactValue $Facts 'containerManagers' @()) }
}

Export-ModuleMember -Function New-ComponentRecord, Add-Evidence, Get-DockerNetworkFacts, Get-InfrastructureFacts, ConvertTo-InfrastructureModel, Get-RouterHosts, Get-RouterOwner
