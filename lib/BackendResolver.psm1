Set-StrictMode -Version 2.0

# Backend address selection: from where an application runs (a Docker container, this computer, another device) and
# what the user typed (127.0.0.1:4119, this PC's LAN address, a container name, a published Windows port), the address
# Traefik must use from INSIDE its container, with the reasons. Resolve-BackendAddress is pure (no Docker, no network)
# and unit-tested; Get-BackendEnvironment reads the engine (read-only) and verifies the host gateway from Traefik's own
# network namespace. Nothing here changes a container, a network or a file.
#
# Rules, in order:
#   - A container on a network Traefik is attached to: its Docker DNS name and the port it listens on inside.
#   - An app on this computer: the host gateway (host.docker.internal on Docker Desktop), never 127.0.0.1 (inside
#     Traefik that is Traefik) and not this PC's LAN address (a Docker network on the same subnet captures it).
#   - Another device: its own address, kept as typed; a Docker subnet that captures it is reported.
#   - A Windows port that a container publishes: that container, by name and internal port.
#   - A container on no shared network: its published port through the host gateway, or a persistent Compose network
#     attachment. Databases, caches and proxy infrastructure are never offered for attachment.
#   - Ambiguous cases return the options instead of one silent choice; a validated user override is kept.
#
# A recommendation never replaces what the user typed: the typed address is always returned as its own candidate
# (role 'entered', or 'custom' for an override) next to the recommendation, and stays selectable unless it cannot work
# at all (a loopback address is Traefik itself) or is not allowed (a base path). Guidance carries a category:
#   recommendation  informational, never blocks         connectivity  may not connect (Docker routing, a captured subnet)
#   restriction     cannot or must not be used          help          explains how Traefik reaches the app

# Host adapters: how containers reach the computer running the engine. Docker Desktop provides host.docker.internal;
# native Linux engines (Debian, Unraid, ...) and Podman need a host-gateway mapping on the Traefik container, so the
# gateway is only recommended after Get-BackendEnvironment has verified that it resolves inside Traefik.
function Get-HostAdapter([string]$Product = '', [string]$OperatingSystem = '') {
  if ($Product -match 'Docker Desktop' -or $OperatingSystem -match 'Docker Desktop') {
    return [ordered]@{ id = 'docker-desktop'; name = 'Docker Desktop'; hostGateway = 'host.docker.internal'; builtIn = $true; hint = '' }
  }
  $mapping = "Add  extra_hosts: ['host.docker.internal:host-gateway']  to the Traefik service in compose.yaml, then recreate Traefik."
  if ($Product -match 'Podman' -or $OperatingSystem -match 'Podman') {
    return [ordered]@{ id = 'podman'; name = 'Podman'; hostGateway = 'host.docker.internal'; builtIn = $false; hint = "Podman names the host host.containers.internal; this tool uses host.docker.internal. $mapping" }
  }
  if ($OperatingSystem -match 'Unraid') { return [ordered]@{ id = 'unraid'; name = 'Unraid'; hostGateway = 'host.docker.internal'; builtIn = $false; hint = $mapping } }
  $name = $(if ($OperatingSystem) { $OperatingSystem } else { 'Linux' })
  return [ordered]@{ id = 'linux'; name = $name; hostGateway = 'host.docker.internal'; builtIn = $false; hint = $mapping }
}

# Pure: "http://127.0.0.1:4119/x", "127.0.0.1:4119", "uptime-kuma" -> { scheme; host; port }.
function Split-BackendAddress([string]$Text) {
  $v = ([string]$Text).Trim()
  $scheme = ''
  if ($v -match '^(?i)(https?|h2c)://') { $scheme = $Matches[1].ToLowerInvariant(); $v = $v.Substring($Matches[0].Length) }
  $path = ''
  $i = $v.IndexOfAny([char[]]'/?#')
  if ($i -ge 0) { $path = $v.Substring($i); $v = $v.Substring(0, $i) }
  if ($path -in @('/', '')) { $path = '' }
  $port = 0; $hostPart = $v
  if ($v -match '^\[(.+)\](?::(\d{1,5}))?$') { $hostPart = $Matches[1]; if ($Matches[2]) { $port = [int]$Matches[2] } }
  elseif ($v -match '^([^:]+):(\d{1,5})$') { $hostPart = $Matches[1]; $port = [int]$Matches[2] }
  return [ordered]@{ scheme = $scheme; host = $hostPart.ToLowerInvariant(); port = $port; path = $path }
}

function Test-LoopbackHost([string]$Value) { return ($Value -match '^(127\.\d+\.\d+\.\d+|localhost|::1|0\.0\.0\.0)$') }

function Test-AddressInSubnet([string]$Address, [string]$Subnet) {
  if (-not (Test-IPv4Address $Address) -or $Subnet -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { return $false }
  return [bool](Test-CidrOverlap "$Address/32" $Subnet)
}

function Get-ResolverProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# Pure: the container a name or address refers to (by name, network alias or container IP), or $null.
function Find-BackendContainer($Containers, [string]$Value) {
  foreach ($c in @($Containers)) {
    if ($c.name -eq $Value) { return [ordered]@{ container = $c; by = 'name' } }
  }
  foreach ($c in @($Containers)) {
    foreach ($n in @($c.networks)) {
      if (@(Get-ResolverProp $n 'aliases' @()) -contains $Value) { return [ordered]@{ container = $c; by = 'alias'; network = $n.name } }
      if ($n.ipv4 -and $n.ipv4 -eq $Value) { return [ordered]@{ container = $c; by = 'ip'; network = $n.name } }
    }
  }
  return $null
}

# Pure: containers publishing $Port on this computer. $ViaAddress: the address the user typed (a loopback address,
# this PC's LAN address); a port published on 127.0.0.1 only answers on loopback.
function Find-PublishedPortOwner($Containers, [int]$Port, [string]$ViaAddress = '') {
  $found = @()
  foreach ($c in @($Containers)) {
    foreach ($p in @($c.published)) {
      if ([int]$p.hostPort -ne $Port -or $p.proto -ne 'tcp') { continue }
      $ip = [string]$p.hostIp
      $matchesAddress = (-not $ViaAddress) -or $ip -in @('', '0.0.0.0', '::') -or $ip -eq $ViaAddress -or ((Test-LoopbackHost $ViaAddress) -and $ip -match '^127\.')
      if ($matchesAddress) { $found += [ordered]@{ container = $c; internalPort = [int]$p.port; hostIp = $ip; hostPort = [int]$p.hostPort } }
    }
  }
  return @($found)
}

# role: entered (what the user typed), recommended, alternative, custom (an override). rejectedReason: why a rejected
# candidate cannot be selected; warning: why a selectable one may not connect.
function New-BackendCandidate([string]$Type, [string]$TargetHost, [int]$Port, [string]$Protocol, [string]$Reason, [string]$Via = '', [string]$Action = '', [string]$Role = 'alternative') {
  $url = "${Protocol}://${TargetHost}:$Port"
  return [ordered]@{ type = $Type; host = $TargetHost; port = $Port; protocol = $Protocol; url = $url; reason = $Reason; via = $Via; action = $Action; role = $Role; rejected = $false; rejectedReason = ''; warning = '' }
}

$script:GuidanceCategory = @{ error = 'restriction'; warn = 'connectivity'; info = 'help' }
# $About: the candidate URL the notice is about (the UI hides a connectivity notice once that question is settled).
function New-BackendGuidance([string]$Id, [string]$Severity, [string]$Title, [string]$Text, [string]$Action = '', [string]$Condition = '', [string]$Category = '', [string]$About = '') {
  return [ordered]@{ id = $Id; severity = $Severity; category = $(if ($Category) { $Category } else { $script:GuidanceCategory[$Severity] }); title = $Title; text = $Text; action = $Action
    condition = $(if ($Condition) { "$Id|$Condition" } else { $Id }); about = $About }
}

# Pure: the protocol a container port most likely speaks (from the discovery port hints).
function Get-PortProtocol($Container, [int]$Port) {
  $p = @(@(Get-ResolverProp $Container 'ports' @()) | Where-Object { [int]$_.port -eq $Port } | Select-Object -First 1)
  if ($p.Count -and $p[0].guess -eq 'https') { return 'https' }
  return 'http'
}

# Pure: how Traefik reaches one container: shared network (by DNS name), else its published port through the host
# gateway, else a persistent network attachment (not for databases, caches or proxy infrastructure).
function Get-ContainerRoute($Container, [int]$Port, $Environment, [string]$Protocol = '') {
  $c = $Container
  $out = [ordered]@{ candidates = @(); guidance = @(); evidence = @(); port = $Port; ambiguous = $false; portChoices = @() }
  $proxyNet = [string](Get-ResolverProp $Environment 'proxyNetwork' '')
  $traefikNets = @(Get-ResolverProp $Environment 'traefikNetworks' @())
  $exposed = @(@($c.exposed) | Where-Object { $_.proto -eq 'tcp' } | ForEach-Object { [int]$_.port })
  # The port inside the container: as typed when the container declares it; a published Windows port maps to its
  # internal port; none typed: the best HTTP candidate, or the choices when several are equally likely.
  $internal = $Port
  if ($Port -gt 0 -and $exposed -notcontains $Port) {
    $pub = @(@($c.published) | Where-Object { [int]$_.hostPort -eq $Port -and $_.proto -eq 'tcp' } | Select-Object -First 1)
    if ($pub.Count) {
      $internal = [int]$pub[0].port
      $out.guidance += New-BackendGuidance 'published-port' 'info' "Use the container's internal port" "$Port is the port $($c.name) publishes on this computer. Inside Docker the app listens on $internal, and Traefik connects to that port directly." 'use-recommended' "$($c.name):$Port"
      $out.evidence += "Port $Port is published by $($c.name) from its internal port $internal."
    } elseif ($exposed.Count) {
      $out.evidence += "$($c.name) declares port(s) $($exposed -join ', '); $Port is not among them (kept as typed: some images do not declare their ports)."
    }
  }
  if ($internal -le 0) {
    $cands = @(@(Get-ResolverProp $c 'ports' @()) | Where-Object { $_.proto -eq 'tcp' -and $_.guess -in @('http', 'https', 'unknown') })
    $web = @($cands | Where-Object { $_.guess -in @('http', 'https') })
    $top = @(); if ($web.Count) { $top = @($web | Where-Object { $_.score -eq $web[0].score }) }
    if ($web.Count) { $internal = [int]$web[0].port } elseif ($cands.Count) { $internal = [int]$cands[0].port }
    $out.portChoices = @($cands | ForEach-Object { [ordered]@{ port = [int]$_.port; guess = $_.guess; reason = $_.reason } })
    if ($top.Count -gt 1) { $out.ambiguous = $true; $out.evidence += "Several ports look like web ports ($(@($top | ForEach-Object { $_.port }) -join ', ')); choose one." }
    elseif ($internal -gt 0) { $out.evidence += "Port $internal chosen: $(@($cands | Where-Object { [int]$_.port -eq $internal })[0].reason)" }
    else { $out.ambiguous = $true; $out.evidence += "$($c.name) declares no TCP port: enter the port the app listens on." }
  }
  $out.port = $internal
  $proto = $(if ($Protocol) { $Protocol } else { Get-PortProtocol $c $internal })
  if ($c.state -ne 'running') { $out.guidance += New-BackendGuidance 'stopped' 'warn' "$($c.name) is not running" "$($c.name) is $($c.state). Start it before testing the connection." '' $c.state }
  $nets = @(@($c.networks) | Where-Object { $_.name -notin @('host', 'none') })
  $shared = @($nets | Where-Object { $traefikNets -contains $_.name } | Sort-Object @{ Expression = { $_.name -ne $proxyNet } })
  if (@($c.networks | Where-Object { $_.name -eq 'host' }).Count) {
    $out.candidates += New-BackendCandidate 'host' (Get-ResolverProp $Environment 'hostGateway' 'host.docker.internal') $internal $proto "$($c.name) uses the host's network: it is reached like an app on this computer." 'host-network'
    $out.evidence += "$($c.name) runs with network_mode: host."
    return $out
  }
  if ($shared.Count) {
    $n = $shared[0]
    if ($n.name -eq 'bridge') {
      $out.candidates += New-BackendCandidate 'lan' $n.ipv4 $internal $proto "Docker's default bridge has no name resolution, so only its IP works (it changes when the container is recreated). Attach it to '$proxyNet' instead." 'bridge-ip'
    } else {
      $out.candidates += New-BackendCandidate 'docker' $c.name $internal $proto "$($c.name) and Traefik share the network '$($n.name)': Traefik reaches it by its Docker DNS name on the port it listens on inside the container." $n.name
    }
    $out.evidence += "Shared networks with Traefik: $(@($shared | ForEach-Object { $_.name }) -join ', ')$(if ($shared.Count -gt 1) { " ('$($shared[0].name)' preferred)" })."
    if (@($nets).Count -gt 1) { $out.evidence += "$($c.name) is on $(@($nets).Count) networks: $(@($nets | ForEach-Object { $_.name }) -join ', ')." }
    return $out
  }
  # Not on a network Traefik is on.
  $out.evidence += "$($c.name) shares no network with Traefik (its networks: $(if ($nets.Count) { @($nets | ForEach-Object { $_.name }) -join ', ' } else { 'none' }); Traefik's: $($traefikNets -join ', '))."
  $gw = [string](Get-ResolverProp $Environment 'hostGateway' '')
  $pubAll = @(@($c.published) | Where-Object { [int]$_.port -eq $internal -and $_.proto -eq 'tcp' -and [int]$_.hostPort -gt 0 } | Select-Object -First 1)
  if ($pubAll.Count -and $gw -and $pubAll[0].hostIp -notmatch '^127\.') {
    $out.candidates += New-BackendCandidate 'host' $gw ([int]$pubAll[0].hostPort) $proto "Through the port $($c.name) already publishes on this computer ($($pubAll[0].hostPort)). No Docker change." 'published-port'
  } elseif ($pubAll.Count) {
    $out.evidence += "Its port $internal is published on $($pubAll[0].hostIp):$($pubAll[0].hostPort) only, which containers cannot reach."
  }
  if ($c.privateService -or $c.infrastructure) {
    $out.guidance += New-BackendGuidance 'private' 'error' "$($c.name) stays private" "$($c.name) is $(if ($c.privateService) { 'a database, cache, message broker or directory server' } else { 'proxy or tunnel infrastructure' }): it is not attached to '$proxyNet' or published." '' $c.name
    return $out
  }
  $att = New-BackendCandidate 'docker' $c.name $internal $proto "Attach $($c.name) to '$proxyNet' in its compose file (networks: [$proxyNet], external: true), then recreate it. Persistent, unlike docker network connect, which is lost when the container is recreated." $proxyNet 'attach'
  $out.candidates += $att
  if ($out.candidates.Count -gt 1) { $out.ambiguous = $true }
  $out.guidance += New-BackendGuidance 'not-shared' 'warn' "Traefik cannot reach $($c.name) by name yet" "$($c.name) is not on a network Traefik is attached to. $(if ($out.candidates.Count -gt 1) { 'Use the port it publishes on this computer, or attach it to the shared network in its compose file.' } else { "Attach it to '$proxyNet' in its compose file." })" '' $c.name
  return $out
}

# Pure. $Location: docker | this-computer | lan | auto. $Address: what the user typed (may carry a port or a scheme).
# $Environment: Get-BackendEnvironment's result. $Containers: Get-DockerContainerInventory's result.
function Resolve-BackendAddress {
  param([string]$Location = 'auto', [string]$Address = '', [int]$Port = 0, [string]$Protocol = '', [string]$Container = '', [switch]$Override,
    $Environment = @{}, $Containers = @())
  $a = Split-BackendAddress $Address
  if ($Container -and -not $a.host) { $a.host = $Container.ToLowerInvariant() }
  if ($a.port -le 0) { $a.port = $Port }
  if ($a.scheme -and -not $Protocol) { $Protocol = $a.scheme }
  $loc = $(if ($Location -in @('docker', 'this-computer', 'lan')) { $Location } else { 'auto' })
  $gw = [string](Get-ResolverProp $Environment 'hostGateway' '')
  $gwVerified = Get-ResolverProp $Environment 'hostGatewayVerified' $null
  $adapter = Get-ResolverProp $Environment 'adapter' $null
  $local = @(Get-ResolverProp $Environment 'localAddresses' @())
  $subnets = @(Get-ResolverProp $Environment 'dockerSubnets' @())
  $res = [ordered]@{ location = $loc; detectedLocation = ''; input = [ordered]@{ address = $Address; host = $a.host; port = $a.port; protocol = $Protocol; path = $a.path }
    kind = ''; recommended = $null; suggested = $null; entered = $null; custom = $null; candidates = @(); guidance = @(); evidence = @(); ambiguous = $false; override = $false; container = ''; portChoices = @() }
  $h = $a.host
  $proto = $(if ($Protocol) { $Protocol } else { 'http' })
  $typedUrl = "${proto}://${h}:$($a.port)"
  # A Docker network whose subnet contains the destination: containers deliver that traffic into the network.
  $overlap = {
    param($Cap, [string]$Destination)
    $res.guidance += New-BackendGuidance 'subnet-overlap' 'warn' 'Docker network overlaps the destination subnet' ("Your Docker network overlaps the destination subnet. Traffic to $Destination may be routed into Docker instead of reaching $(if ($res.kind -eq 'this-pc-ip') { 'your Windows computer' } else { 'that device' })." +
      " Docker network '$($Cap[0].name)' ($($Cap[0].subnet)) contains $Destination, so containers send this traffic into that network. To use $Destination, move that Docker network to another subnet in its compose file, or remove it once nothing uses it$(if ($res.kind -eq 'this-pc-ip') { '; host.docker.internal avoids the conflict without any change' })." +
      ' Nothing is changed automatically.') '' "$Destination|$($Cap[0].name)" 'connectivity' $typedUrl
  }
  $useGateway = {
    param([int]$P, [string]$Why)
    if (-not $gw -or $gwVerified -eq $false) {
      $res.guidance += New-BackendGuidance 'no-host-gateway' 'warn' 'No verified host address inside Docker' "Containers on this Docker host ($(if ($adapter) { $adapter.name } else { 'this engine' })) cannot reach this computer as host.docker.internal yet. $(if ($adapter -and $adapter.hint) { $adapter.hint })" '' "$gwVerified"
      foreach ($ip in $local) {
        if (@($subnets | Where-Object { Test-AddressInSubnet $ip $_.subnet }).Count) { continue }
        $res.candidates += New-BackendCandidate 'lan' $ip $P $(if ($Protocol) { $Protocol } else { 'http' }) "This computer's address ${ip}: on a native Linux engine containers route to it directly. Test before using it." 'host-ip'
      }
      $res.ambiguous = $true
      return
    }
    $res.candidates += New-BackendCandidate 'host' $gw $P $(if ($Protocol) { $Protocol } else { 'http' }) $Why 'host-gateway'
  }

  # 1. What the typed host is.
  $hit = $null
  if (-not $h) { $res.kind = 'empty' }
  elseif (Test-LoopbackHost $h) { $res.kind = 'loopback' }
  elseif ($h -eq 'host.docker.internal' -or ($gw -and $h -eq $gw)) { $res.kind = 'host-gateway' }
  elseif ($local -contains $h) { $res.kind = 'this-pc-ip' }
  else {
    $hit = Find-BackendContainer $Containers $h
    if ($hit -and $hit.by -eq 'ip') { $res.kind = 'container-ip' }
    elseif ($hit) { $res.kind = 'container' }
    elseif (Test-IPv4Address $h) { $res.kind = $(if (@($subnets | Where-Object { Test-AddressInSubnet $h $_.subnet }).Count) { 'docker-subnet' } else { 'lan-ip' }) }
    elseif ($h -match '\.') { $res.kind = 'lan-name' }
    else { $res.kind = 'unknown-name' }
  }
  $res.evidence += "Typed: '$(if ($Address) { $Address } else { $h })' -> $($res.kind)$(if ($a.port) { ", port $($a.port)" })."

  # 2. A port on this computer that a container publishes is that container.
  $owner = @()
  if ($res.kind -in @('loopback', 'host-gateway', 'this-pc-ip') -and $a.port -gt 0) {
    $owner = @(Find-PublishedPortOwner $Containers $a.port $(if ($res.kind -eq 'host-gateway') { '' } else { $h }))
    if ($owner.Count) { $res.evidence += "Port $($a.port) on this computer is published by container $($owner[0].container.name) (internal port $($owner[0].internalPort))." }
  }

  # 3. Candidates by kind.
  switch ($res.kind) {
    'empty' {
      if ($loc -eq 'this-computer' -and $a.port -gt 0) { & $useGateway $a.port 'An app on this computer is reached from inside Docker through the host gateway.' }
      elseif ($loc -eq 'this-computer') { $res.evidence += 'Enter the port the app listens on.' }
    }
    { $_ -in @('loopback', 'this-pc-ip', 'host-gateway') } {
      if ($owner.Count) {
        $c = $owner[0].container
        $res.container = $c.name
        $route = Get-ContainerRoute $c $owner[0].internalPort $Environment $Protocol
        $res.candidates += $route.candidates; $res.guidance += $route.guidance; $res.evidence += $route.evidence
        $res.guidance += New-BackendGuidance 'published-by-container' 'info' 'This port belongs to a Docker container' "Port $($a.port) on this computer is published by the container $($c.name). Traefik reaches it directly as $($c.name):$($owner[0].internalPort) on the shared Docker network, not through Windows." 'use-recommended' "$($c.name):$($a.port)"
        if ($route.ambiguous) { $res.ambiguous = $true }
      } else {
        & $useGateway $a.port 'An app on this computer is reached from inside Docker through the host gateway.'
      }
      if ($res.kind -eq 'loopback') {
        $rec = $(if ($res.candidates.Count) { $res.candidates[0].url } else { '' })
        $res.guidance += New-BackendGuidance 'loopback' 'warn' 'Use the Docker host address instead' "Traefik runs inside Docker. Inside Traefik, $h refers to its own container, not the Windows computer.$(if ($rec) { " Recommended backend: $rec" })" 'use-recommended' "$h|$($a.port)" 'restriction' $typedUrl
      } elseif ($res.kind -eq 'this-pc-ip') {
        $cap = @($subnets | Where-Object { Test-AddressInSubnet $h $_.subnet })
        $gwc = @($res.candidates | Where-Object { $_.via -eq 'host-gateway' })
        if ($gwc.Count) {
          $res.guidance += New-BackendGuidance 'own-lan-ip' 'info' "$($gwc[0].host) is recommended" ("$h is this computer's own address. Traefik runs inside Docker. Docker Desktop provides $($gwc[0].host) as a way to reach applications running directly on Windows." +
            " Your LAN IP is also configurable, but Docker network routing may affect connectivity. Recommended alternative: $($gwc[0].url)") 'use-recommended' "$h|$($a.port)" 'recommendation' $typedUrl
        }
        if ($cap.Count) { & $overlap $cap $h }
      }
    }
    { $_ -in @('container', 'container-ip') } {
      $c = $hit.container
      $res.container = $c.name
      $route = Get-ContainerRoute $c $a.port $Environment $Protocol
      $res.candidates += $route.candidates; $res.guidance += $route.guidance; $res.evidence += $route.evidence; $res.portChoices = $route.portChoices
      if ($route.ambiguous) { $res.ambiguous = $true }
      if ($res.kind -eq 'container-ip') {
        $res.guidance += New-BackendGuidance 'container-ip' 'info' 'Use the container name' "$h is the internal address of container $($c.name) on '$($hit.network)'. It changes when the container is recreated; its name does not." 'use-recommended' $h
      } else {
        $res.guidance += New-BackendGuidance 'container-explain' 'info' 'How Traefik reaches containers' "Traefik reaches a container by its Docker network name and the port the app listens on inside the container ($($c.name):$($route.port)), not by a Windows localhost address." '' $c.name
      }
    }
    'docker-subnet' {
      $cap = @($subnets | Where-Object { Test-AddressInSubnet $h $_.subnet })
      & $overlap $cap $h
      if ($loc -eq 'this-computer') { & $useGateway $a.port 'An app on this computer is reached from inside Docker through the host gateway.' }
    }
    'unknown-name' {
      $res.guidance += New-BackendGuidance 'no-container' 'warn' "No container named $h" "No container or network alias named $h exists on this Docker engine. Check the name (docker ps), or start the container first." '' $h
      $res.candidates += New-BackendCandidate 'docker' $h $a.port $proto 'As typed; no such container right now.' 'docker' '' 'entered'
    }
  }

  # 4. The address as typed: always its own candidate, merged with an identical discovered one. It is rejected only
  #    when it cannot work at all (loopback is Traefik itself) or carries a base path; a captured subnet is a warning.
  $role = $(if ($Override) { 'custom' } else { 'entered' })
  if ($h -and $a.port -gt 0) {
    $etype = $(switch ($res.kind) { 'host-gateway' { 'host' } { $_ -in @('container', 'unknown-name') } { 'docker' } default { 'lan' } })
    $same = @($res.candidates | Where-Object { $_.type -eq $etype -and $_.host -eq $h -and [int]$_.port -eq $a.port })
    if ($same.Count) { $e = $same[0] }
    elseif ($res.kind -eq 'container' -and -not $Override) { $e = $null }
    else {
      $why = $(switch ($res.kind) { 'this-pc-ip' { "This computer's LAN address, exactly as you entered it." } 'container-ip' { "The container's current internal address, as you entered it." } { $_ -in @('lan-ip', 'lan-name', 'docker-subnet') } { 'Another device on your network: its own address, as you entered it.' } default { 'The address you entered, kept exactly as typed.' } })
      $e = New-BackendCandidate $etype $h $a.port $proto $why 'as-entered' '' $role
      $res.candidates = @($e) + @($res.candidates)
    }
    if ($e) {
      $e.role = $role
      if (Test-LoopbackHost $h) { $e.rejected = $true; $e.rejectedReason = "Inside Traefik's container, $h is Traefik itself, not this computer: it cannot reach the app." }
      elseif ($a.path) {
        $e.rejected = $true; $e.rejectedReason = "A base path ($($a.path)) in the backend address is not supported: Traefik forwards the request path unchanged. Use Path prefix under Advanced routing instead."
        $res.guidance += New-BackendGuidance 'backend-path' 'error' 'Remove the path from the backend address' $e.rejectedReason '' $a.path
      }
      $cap = @($subnets | Where-Object { Test-AddressInSubnet $h $_.subnet })
      if ($cap.Count -and $res.kind -ne 'container-ip') { $e.warning = "Docker network '$($cap[0].name)' ($($cap[0].subnet)) contains ${h}: traffic from Traefik may never reach it." }
      if ($Override) { $res.custom = $e } else { $res.entered = $e }
    }
  }

  # 5. Location: what the address says, and a mismatch with what the user chose. The user's choice is never changed.
  $res.detectedLocation = $(switch ($res.kind) { { $_ -in @('loopback', 'this-pc-ip', 'host-gateway') } { if ($owner.Count) { 'docker' } else { 'this-computer' } } { $_ -in @('container', 'container-ip', 'unknown-name') } { 'docker' } { $_ -in @('lan-ip', 'lan-name', 'docker-subnet') } { 'lan' } default { $loc } })
  if ($loc -eq 'lan' -and $res.kind -in @('loopback', 'this-pc-ip', 'host-gateway')) { $res.evidence += "$h is this computer, although 'another computer or device' is chosen: the address is kept as you entered it, and the Docker host address is offered as an alternative." }
  if ($loc -eq 'this-computer' -and $res.kind -in @('lan-ip', 'lan-name')) {
    $res.guidance += New-BackendGuidance 'not-this-pc' 'info' 'This address is another device' "$h is not one of this computer's addresses ($($local -join ', ')). It is kept as another device on your network." '' $h
  }

  # 6. The recommendation: the best discovered path, else the typed address. It never replaces the typed address;
  #    the UI shows both. A validated override is returned as 'custom'.
  $usable = @($res.candidates | Where-Object { -not $_.rejected })
  $found = @($usable | Where-Object { $_.role -notin @('entered', 'custom') })
  if ($found.Count) { $res.recommended = $found[0] } elseif ($usable.Count) { $res.recommended = $usable[0] }
  if ($res.recommended -and $res.recommended.role -eq 'alternative') { $res.recommended.role = 'recommended' }
  if ($res.ambiguous -and $usable.Count -gt 1) { $res.evidence += 'Several paths are possible: the first is suggested; the others are listed.' }
  $res.suggested = $res.recommended
  if ($Override -and $h) {
    if (Test-LoopbackHost $h) {
      $res.guidance += New-BackendGuidance 'override-loopback' 'error' 'This address cannot work from Traefik' "$h inside Traefik's container is Traefik itself, so it cannot be kept as an override." '' $h
    } elseif ($res.custom -and -not $res.custom.rejected) {
      $res.custom.reason = 'Your custom address, kept exactly as typed.'; $res.custom.via = 'override'
      $res.override = $true
    }
  }
  return $res
}

# Live (read-only): the engine, Traefik's networks, every Docker subnet, this computer's IPv4 addresses and whether the
# host gateway resolves inside Traefik's network namespace (one short probe, cached for five minutes). The whole result
# is reused for 30 seconds, so a wizard asking on every address change stays fast; -Fresh reads everything again.
$script:GatewayCache = @{}
$script:EnvironmentCache = @{}
function Get-BackendEnvironment {
  param([Parameter(Mandatory = $true)]$Settings, [switch]$NoGatewayCheck, [switch]$Fresh)
  $ck = "$($Settings.TraefikContainer)|$([bool]$NoGatewayCheck)"
  $hit = $script:EnvironmentCache[$ck]
  if (-not $Fresh -and $hit -and ((Get-Date) - $hit.at).TotalSeconds -lt 30) { return $hit.value }
  if ($Fresh) { $script:GatewayCache.Clear() }
  $product = ((Invoke-Docker version --format '{{.Server.Platform.Name}}').Output -join '').Trim()
  $os = ((Invoke-Docker info --format '{{.OperatingSystem}}').Output -join '').Trim()
  $adapter = Get-HostAdapter $product $os
  $tn = Invoke-Docker inspect $Settings.TraefikContainer --format '{{json .NetworkSettings.Networks}}'
  $traefikNets = @(); $netIds = [ordered]@{}
  if ($tn.ExitCode -eq 0) {
    $o = (@($tn.Output) -join '') | ConvertFrom-Json
    if ($o) { foreach ($p in $o.PSObject.Properties) { $traefikNets += $p.Name; $netIds[$p.Name] = ([string]$p.Value.NetworkID).Substring(0, [Math]::Min(12, ([string]$p.Value.NetworkID).Length)) } }
  }
  $verified = $null; $detail = 'Not checked.'
  if (-not $NoGatewayCheck -and $tn.ExitCode -eq 0) {
    $key = "$($Settings.TraefikContainer)|$($adapter.hostGateway)"
    $cached = $script:GatewayCache[$key]
    if ($cached -and ((Get-Date) - $cached.at).TotalMinutes -lt 5) { $verified = $cached.ok; $detail = $cached.detail }
    else {
      # Port 9 (discard) is almost never open: "refused" or a timeout both prove the name resolves; only "bad address" fails.
      $r = Invoke-Docker run --rm --pull never --network "container:$($Settings.TraefikContainer)" --read-only --cap-drop ALL --security-opt no-new-privileges --memory 32m --label org.traefik-proxy.probe=1 --entrypoint wget $Settings.TraefikImage -q -T 2 -O /dev/null "http://$($adapter.hostGateway):9/"
      $text = (@($r.Output) -join ' ')
      if ($text -match 'Unable to find image|No such image') { $verified = $null; $detail = "Not checked: the probe image $($Settings.TraefikImage) is not present." }
      elseif ($text -match 'bad address|Name does not resolve|unknown host') { $verified = $false; $detail = "$($adapter.hostGateway) does not resolve inside $($Settings.TraefikContainer)." }
      else { $verified = $true; $detail = "$($adapter.hostGateway) resolves inside $($Settings.TraefikContainer)." }
      if ($null -ne $verified) { $script:GatewayCache[$key] = @{ at = (Get-Date); ok = $verified; detail = $detail } }
    }
  }
  $value = [ordered]@{
    adapter = $adapter; hostGateway = $adapter.hostGateway; hostGatewayVerified = $verified; hostGatewayDetail = $detail
    localAddresses = @(Get-LocalIPv4Addresses); dockerSubnets = @(Get-DockerSubnets); proxyNetwork = $Settings.ProxyNetwork
    traefikContainer = $Settings.TraefikContainer; traefikNetworks = $traefikNets; traefikNetworkIds = $netIds; checkedAt = (Get-Date -Format 's')
  }
  $script:EnvironmentCache[$ck] = @{ at = (Get-Date); value = $value }
  return $value
}

Export-ModuleMember -Function Get-HostAdapter, Split-BackendAddress, Test-LoopbackHost, Find-BackendContainer, Find-PublishedPortOwner, Get-ContainerRoute,
  Resolve-BackendAddress, Get-BackendEnvironment, New-BackendCandidate
