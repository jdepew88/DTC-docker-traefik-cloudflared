Set-StrictMode -Version 2.0

# Docker container discovery for publishing: what runs on the engine, on which networks and ports, and which hostnames
# it already claims. Reads `docker ps` / `docker inspect` only; a container's environment, mounts and command line are
# never returned (they often hold credentials). Port probes run in a short-lived, read-only, capability-less container
# from the already-pulled Traefik image (never pulled, never privileged) attached to a network the target is on.

# Ports that are almost never HTTP, and ports that usually are (name shown as the reason).
$script:NotHttpPorts = @{ 21 = 'FTP'; 22 = 'SSH'; 25 = 'SMTP'; 53 = 'DNS'; 110 = 'POP3'; 143 = 'IMAP'; 389 = 'LDAP'; 445 = 'SMB'; 587 = 'SMTP'; 636 = 'LDAPS'; 993 = 'IMAPS'; 1433 = 'SQL Server'
  1883 = 'MQTT'; 1900 = 'SSDP'; 3306 = 'MySQL/MariaDB'; 3478 = 'STUN'; 5432 = 'PostgreSQL'; 5672 = 'AMQP'; 6379 = 'Redis'; 7359 = 'Jellyfin discovery'; 8883 = 'MQTT/TLS'
  9042 = 'Cassandra'; 10001 = 'UniFi discovery'; 11211 = 'Memcached'; 27017 = 'MongoDB'; 51413 = 'BitTorrent' }
$script:HttpPorts = @{ 80 = 'HTTP'; 3000 = 'web app'; 3001 = 'web app'; 4000 = 'web app'; 5000 = 'web app'; 5001 = 'web app'; 5055 = 'web app'; 7878 = 'Radarr'; 8000 = 'web app'; 8080 = 'HTTP (alt)'
  8081 = 'HTTP (alt)'; 8096 = 'Jellyfin'; 8123 = 'Home Assistant'; 8181 = 'web app'; 8888 = 'web app'; 8989 = 'Sonarr'; 9000 = 'web app'; 9091 = 'Authelia / Transmission'; 9117 = 'Jackett'; 9696 = 'Prowlarr'
  32400 = 'Plex'; 3552 = 'Arcane'; 5678 = 'n8n'; 8384 = 'Syncthing' }
$script:HttpsPorts = @{ 443 = 'HTTPS'; 8443 = 'HTTPS (alt)'; 9443 = 'HTTPS (Portainer)'; 8920 = 'Jellyfin HTTPS' }

function Get-Prop($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Get-RuleHosts([string]$Rule) {
  return @([regex]::Matches([string]$Rule, 'Host\(\s*`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
}

# One `docker inspect` object -> the fields the UI may see.
function ConvertFrom-DockerInspect($C) {
  $config = Get-Prop $C 'Config'
  $state = Get-Prop $C 'State'
  $ns = Get-Prop $C 'NetworkSettings'
  $labels = Get-Prop $config 'Labels'
  $label = { param($k) if ($labels -and $labels.PSObject.Properties[$k]) { [string]$labels.$k } else { '' } }
  $image = [string](Get-Prop $config 'Image' '')
  $tag = ''
  if ($image -match '@sha256:') { $tag = 'digest' } elseif ($image -match ':([^:/]+)$') { $tag = $Matches[1] } else { $tag = 'latest (implicit)' }
  $networks = @()
  $nets = Get-Prop $ns 'Networks'
  if ($nets) { $networks = @($nets.PSObject.Properties | ForEach-Object { [ordered]@{ name = $_.Name; ipv4 = [string](Get-Prop $_.Value 'IPAddress' ''); aliases = @(Get-Prop $_.Value 'Aliases' @() | Where-Object { $_ }) } }) }
  $exposed = @()
  $ep = Get-Prop $config 'ExposedPorts'
  if ($ep) { $exposed = @($ep.PSObject.Properties | ForEach-Object { $p = $_.Name.Split('/'); [ordered]@{ port = [int]$p[0]; proto = $(if ($p.Count -gt 1) { $p[1] } else { 'tcp' }) } }) }
  $published = @()
  $pp = Get-Prop $ns 'Ports'
  if ($pp) {
    foreach ($prop in $pp.PSObject.Properties) {
      $p = $prop.Name.Split('/')
      foreach ($b in @($prop.Value)) {
        if ($null -eq $b) { continue }
        $published += [ordered]@{ port = [int]$p[0]; proto = $(if ($p.Count -gt 1) { $p[1] } else { 'tcp' }); hostIp = [string](Get-Prop $b 'HostIp' ''); hostPort = [int](Get-Prop $b 'HostPort' 0) }
      }
    }
  }
  # Ports that are only published (not declared with EXPOSE) are ports too.
  foreach ($p in $published) { if (-not @($exposed | Where-Object { $_.port -eq $p.port -and $_.proto -eq $p.proto }).Count) { $exposed += [ordered]@{ port = $p.port; proto = $p.proto } } }
  $traefik = [ordered]@{ enabled = (& $label 'traefik.enable'); routers = @(); servicePorts = @() }
  if ($labels) {
    foreach ($prop in $labels.PSObject.Properties) {
      if ($prop.Name -match '^traefik\.http\.routers\.([^.]+)\.rule$') { $traefik.routers += [ordered]@{ name = $Matches[1]; rule = [string]$prop.Value; hosts = @(Get-RuleHosts $prop.Value) } }
      elseif ($prop.Name -match '^traefik\.http\.services\.([^.]+)\.loadbalancer\.server\.port$') { $p = 0; if ([int]::TryParse([string]$prop.Value, [ref]$p)) { $traefik.servicePorts += $p } }
    }
  }
  $hc = Get-Prop $state 'Health'
  return [ordered]@{
    id = ([string](Get-Prop $C 'Id' '')).Substring(0, [Math]::Min(12, ([string](Get-Prop $C 'Id' '')).Length))
    name = ([string](Get-Prop $C 'Name' '')).TrimStart('/')
    image = $image; tag = $tag
    state = [string](Get-Prop $state 'Status' ''); health = $(if ($hc) { [string](Get-Prop $hc 'Status' '') } else { '' })
    restart = [string](Get-Prop (Get-Prop (Get-Prop $C 'HostConfig') 'RestartPolicy') 'Name' '')
    compose = [ordered]@{ project = (& $label 'com.docker.compose.project'); service = (& $label 'com.docker.compose.service'); workingDir = (& $label 'com.docker.compose.project.working_dir') }
    networks = $networks; exposed = @($exposed | Sort-Object { $_.port }); published = $published
    traefik = $traefik
    managedBy = (& $label 'org.traefik-proxy.app')
    # Reverse proxies, tunnel connectors and socket proxies are infrastructure, not applications to publish.
    infrastructure = [bool]($image -match '(^|/)(traefik|docker-socket-proxy|socket-proxy|cloudflared|caddy|nginx-proxy-manager)(:|@|$)' -and $image -notmatch 'traefik/whoami')
    # Databases, caches, message brokers and directory servers stay on private networks: never attached to the shared
    # proxy network or published, whatever their ports look like.
    privateService = [bool]($image -match '(^|/)(postgres|postgresql|mariadb|mysql|mongo|mongodb-community-server|redis|valkey|keydb|memcached|nats|rabbitmq|openldap|lldap)(:|@|$)')
  }
}

# Pure: a container's ports ranked by how likely they serve HTTP. Nothing here is "validated": that needs a probe.
function Get-PortCandidates($Container) {
  $list = @(foreach ($p in @($Container.exposed)) {
      $port = [int]$p.port; $score = 10; $guess = 'unknown'; $reason = 'No hint for this port.'
      if ($port -in 2375, 2376) { $guess = 'blocked'; $score = -200; $reason = 'Docker Engine API: publishing it would hand over control of this computer. Never publish it.' }
      elseif ($p.proto -ne 'tcp') { $guess = 'not-http'; $score = -100; $reason = "$($p.proto.ToUpperInvariant()) port: Traefik and Cloudflare Tunnel publish HTTP over TCP only." }
      elseif (@($Container.traefik.servicePorts) -contains $port) { $guess = 'http'; $score = 100; $reason = 'Named in the container''s own Traefik labels.' }
      elseif ($script:HttpsPorts.ContainsKey($port)) { $guess = 'https'; $score = 40; $reason = "Usually $($script:HttpsPorts[$port])." }
      elseif ($script:HttpPorts.ContainsKey($port)) { $guess = 'http'; $score = 60; $reason = "Usually $($script:HttpPorts[$port])." }
      elseif ($script:NotHttpPorts.ContainsKey($port)) { $guess = 'not-http'; $score = -50; $reason = "Usually $($script:NotHttpPorts[$port]), not a web page." }
      $pub = @($Container.published | Where-Object { $_.port -eq $port -and $_.proto -eq $p.proto } | Select-Object -First 1)
      [ordered]@{ port = $port; proto = $p.proto; guess = $guess; score = $score; reason = $reason; hostPort = $(if ($pub.Count) { $pub[0].hostPort } else { 0 }); hostIp = $(if ($pub.Count) { $pub[0].hostIp } else { '' }) }
    })
  return @($list | Sort-Object @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.port } })
}

# All containers on the engine (one inspect call). $ProxyNetwork marks containers Traefik can already reach.
function Get-DockerContainerInventory {
  param([string]$ProxyNetwork)
  $ids = Invoke-Docker ps -a -q --no-trunc
  if ($ids.ExitCode -ne 0) { throw "Docker is not available: $((@($ids.Output) -join ' ').Trim())" }
  $list = @($ids.Output | Where-Object { $_ -match '^[0-9a-f]{12,64}$' })
  if (-not $list.Count) { return @() }
  $r = Invoke-Docker @(@('inspect') + $list)
  if ($r.ExitCode -ne 0) { throw "docker inspect failed: $((@($r.Output) -join ' ').Trim())" }
  $raw = @((@($r.Output) -join "`n") | ConvertFrom-Json)
  return @($raw | ForEach-Object { $_ } | ForEach-Object {
      $c = ConvertFrom-DockerInspect $_
      $c.onProxyNetwork = [bool]($ProxyNetwork -and @($c.networks | Where-Object { $_.name -eq $ProxyNetwork }).Count)
      $c.ports = @(Get-PortCandidates $c)
      $c
    } | Sort-Object @{ Expression = { $_.state -ne 'running' } }, @{ Expression = { $_.name } })
}

# Pure: everything that already claims $Hostname, apart from $OwnService (the service being added or edited).
# Sources: registry services, routers loaded in this Traefik (any provider), Docker labels of any container.
function Find-HostnameClaims {
  param([Parameter(Mandatory = $true)][string]$Hostname, $Services = @(), $Routers = @(), $Containers = @(), [string]$OwnService = '', [string]$DashboardHostname = '')
  $h = $Hostname.ToLowerInvariant()
  $claims = New-Object System.Collections.ArrayList
  if ($DashboardHostname -and $DashboardHostname.ToLowerInvariant() -eq $h) { $null = $claims.Add([ordered]@{ source = 'dashboard'; name = 'public Traefik dashboard'; level = 'error'; detail = 'The public dashboard owns this hostname.' }) }
  foreach ($s in @($Services)) {
    if ($s.name -eq $OwnService) { continue }
    if (@($s.hostnames | ForEach-Object { ([string]$_).ToLowerInvariant() }) -contains $h) { $null = $claims.Add([ordered]@{ source = 'registry'; name = $s.name; level = 'error'; detail = "Service '$($s.name)' of this deployment already uses it." }) }
  }
  foreach ($r in @($Routers)) {
    $n = [string](Get-Prop $r 'name' '')
    if ($OwnService -and $n -match "^svc-$([regex]::Escape($OwnService))(-[a-z]+)?@file$") { continue }
    if ($n -match '^svc-[a-z0-9-]+@file$' -or $n -match '^public-dashboard') { continue }   # registry and dashboard are checked above
    if ((Get-RuleHosts (Get-Prop $r 'rule' '')) -contains $h) { $null = $claims.Add([ordered]@{ source = "traefik:$(Get-Prop $r 'provider' '')"; name = $n; level = 'error'; detail = "Router $n in this Traefik already matches it (rule $(Get-Prop $r 'rule' ''))." }) }
  }
  foreach ($c in @($Containers)) {
    foreach ($r in @($c.traefik.routers)) {
      if (@($r.hosts) -contains $h) { $null = $claims.Add([ordered]@{ source = 'labels'; name = "$($c.name) ($($r.name))"; level = 'warning'; detail = "Container $($c.name) declares a Traefik router for it in its labels (for this or another Traefik)." }) }
    }
  }
  return $claims.ToArray()
}

# Networks a probe can join to reach $Container: the proxy network first, then its user-defined networks.
function Get-ProbeNetwork($Container, [string]$ProxyNetwork) {
  $names = @($Container.networks | ForEach-Object { $_.name })
  if ($ProxyNetwork -and $names -contains $ProxyNetwork) { return [ordered]@{ network = $ProxyNetwork; target = $Container.name } }
  foreach ($n in $Container.networks) {
    if ($n.name -in @('host', 'none')) { continue }
    # The default bridge has no name resolution: use the address.
    if ($n.name -eq 'bridge') { if ($n.ipv4) { return [ordered]@{ network = 'bridge'; target = $n.ipv4 } } else { continue } }
    return [ordered]@{ network = $n.name; target = $Container.name }
  }
  return $null
}

# Pure: busybox wget -S output -> result.
function ConvertFrom-ProbeOutput([string[]]$Lines, [int]$ExitCode) {
  $text = (@($Lines) -join "`n")
  $m = [regex]::Match($text, 'HTTP/\d(?:\.\d)?\s+(\d{3})')
  if ($m.Success) { return [ordered]@{ result = 'http'; status = [int]$m.Groups[1].Value; detail = "Answers HTTP $($m.Groups[1].Value)." } }
  if ($text -match 'Connection refused') { return [ordered]@{ result = 'closed'; status = 0; detail = 'Nothing listens on this port (connection refused).' } }
  if ($text -match 'timed out|Timeout') { return [ordered]@{ result = 'timeout'; status = 0; detail = 'No answer within 4 seconds.' } }
  if ($text -match 'bad address|Name does not resolve|unknown host') { return [ordered]@{ result = 'error'; status = 0; detail = 'The container name does not resolve on that network.' } }
  if ($text -match 'bad header|error getting response|server returned error|Connection reset|unexpected') { return [ordered]@{ result = 'not-http'; status = 0; detail = 'Something listens, but it does not answer HTTP.' } }
  return [ordered]@{ result = 'error'; status = 0; detail = ($text.Trim() -split "`n" | Select-Object -Last 1) }
}

# Probes one port. Prefers a short-lived probe container on a network the target is on; falls back to a published
# host port. Never pulls an image. $Image: the instance's Traefik image (already present).
function Test-ContainerPort {
  param([Parameter(Mandatory = $true)]$Container, [Parameter(Mandatory = $true)][int]$Port, [string]$ProxyNetwork, [Parameter(Mandatory = $true)][string]$Image, [string]$NamePrefix = 'tpm', [string[]]$Schemes = @('http', 'https'))
  $out = [ordered]@{ port = $Port; method = ''; network = ''; result = 'error'; status = 0; scheme = ''; detail = '' }
  if ($Container.state -ne 'running') { $out.detail = "The container is $($Container.state)."; return $out }
  $net = Get-ProbeNetwork $Container $ProxyNetwork
  if ($net) {
    $out.method = 'probe-container'; $out.network = $net.network
    $probeName = "$NamePrefix-validate-probe-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    foreach ($scheme in $Schemes) {
      $args2 = @('run', '--rm', '--pull', 'never', '--name', $probeName, '--network', $net.network, '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--memory', '32m',
        '--label', 'org.traefik-proxy.probe=1', '--entrypoint', 'wget', $Image, '-S', '-q', '-O', '/dev/null', '-T', '4')
      if ($scheme -eq 'https') { $args2 += '--no-check-certificate' }
      $args2 += "${scheme}://$($net.target):$Port/"
      $r = Invoke-Docker @args2
      if (@($r.Output) -match 'Unable to find image|No such image') { $out.result = 'error'; $out.detail = "The probe image $Image is not present locally (it is never pulled)."; return $out }
      $p = ConvertFrom-ProbeOutput $r.Output $r.ExitCode
      $out.result = $p.result; $out.status = $p.status; $out.detail = $p.detail; $out.scheme = $scheme
      if ($p.result -eq 'http') { if ($scheme -eq 'https') { $out.result = 'https' }; return $out }
      if ($p.result -ne 'not-http') { return $out }
    }
    return $out
  }
  $pub = @($Container.published | Where-Object { $_.port -eq $Port -and $_.proto -eq 'tcp' -and $_.hostPort -gt 0 } | Select-Object -First 1)
  if ($pub.Count) {
    $out.method = 'host-port'; $out.network = "127.0.0.1:$($pub[0].hostPort)"
    foreach ($scheme in @('http', 'https')) {
      $r = Invoke-ProbeRequest "${scheme}://127.0.0.1:$($pub[0].hostPort)/"
      if ($r.Status -gt 0) { $out.result = $(if ($scheme -eq 'https') { 'https' } else { 'http' }); $out.status = $r.Status; $out.scheme = $scheme; $out.detail = "Answers HTTP $($r.Status) on the published port."; return $out }
    }
    $out.result = 'not-http'; $out.detail = 'The published port does not answer HTTP or HTTPS.'
    return $out
  }
  $out.detail = 'The container is on no network a probe can join and publishes no port.'
  return $out
}

Export-ModuleMember -Function ConvertFrom-DockerInspect, Get-PortCandidates, Get-DockerContainerInventory, Find-HostnameClaims, Get-ProbeNetwork, ConvertFrom-ProbeOutput, Test-ContainerPort, Get-RuleHosts
