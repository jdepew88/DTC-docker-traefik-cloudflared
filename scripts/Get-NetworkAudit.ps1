#requires -version 5.1
<#
.SYNOPSIS
  Read-only audit of Docker networks and containers: which project owns what, which networks are in use, required
  by stopped projects or unused, which ones overlap the LAN, and which ports are published on all interfaces.
  Nothing is changed: it only runs docker ps/inspect and docker network ls/inspect, and never prunes.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Get-NetworkAudit.ps1 -ProjectPath $env:USERPROFILE\.docker\projects\traefik-proxy
  powershell -ExecutionPolicy Bypass -File .\scripts\Get-NetworkAudit.ps1 -ProjectPath ... -JsonFile audit.json
#>
[CmdletBinding()]
param(
  [string]$ProjectPath,
  [string]$JsonFile
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $ProjectPath) { $ProjectPath = $toolRoot }
$ProjectPath = [IO.Path]::GetFullPath($ProjectPath)
Import-Module (Join-Path $toolRoot 'lib\TraefikProxy.psm1') -Force
$s = Get-StackSettings -InstallPath $ProjectPath

function Get-Label($Obj, [string]$Name) { if ($Obj -and $Obj.PSObject.Properties[$Name]) { [string]$Obj.$Name } else { '' } }
function ConvertTo-IpNumber([string]$Ip) { $b = ([Net.IPAddress]::Parse($Ip)).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
function Test-InSubnet([string]$Ip, [string]$Cidr) {
  $net, $len = $Cidr -split '/'; $len = [int]$len
  if ($Ip -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $net -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $false }
  $mask = $(if ($len -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $len)) })
  return ((ConvertTo-IpNumber $Ip) -band $mask) -eq ((ConvertTo-IpNumber $net) -band $mask)
}
function Test-SubnetOverlap([string]$A, [string]$B) {
  $na, $la = $A -split '/'; $nb, $lb = $B -split '/'
  $len = [Math]::Min([int]$la, [int]$lb)
  return (Test-InSubnet $na "$nb/$len") -and (Test-InSubnet $nb "$na/$len")
}

# Containers.
$ids = @(docker ps -aq | Where-Object { $_ })
$containers = @()
if ($ids.Count) {
  # Windows PowerShell returns a JSON array as one object: enumerate it with foreach, not @().
  $inspected = (docker inspect $ids) -join "`n" | ConvertFrom-Json
  foreach ($c in $inspected) {
    $l = $c.Config.Labels
    $ports = @()
    if ($c.NetworkSettings.Ports) {
      foreach ($p in $c.NetworkSettings.Ports.PSObject.Properties) {
        if ($p.Value) { foreach ($b in @($p.Value)) { if ($b.HostIp -ne '::') { $ports += [ordered]@{ container = $p.Name; hostIp = $(if ($b.HostIp) { $b.HostIp } else { '0.0.0.0' }); hostPort = $b.HostPort } } } }
      }
    }
    $image = [string]$c.Config.Image
    $containers += [ordered]@{
      name = $c.Name.TrimStart('/'); state = [string]$c.State.Status; image = $image
      project = (Get-Label $l 'com.docker.compose.project'); service = (Get-Label $l 'com.docker.compose.service')
      configFile = (Get-Label $l 'com.docker.compose.project.config_files'); app = (Get-Label $l 'org.traefik-proxy.app')
      networks = @($c.NetworkSettings.Networks.PSObject.Properties | ForEach-Object { $_.Name })
      ports = $ports
      role = $(if ($image -match '(^|/)(traefik)(:|@|$)' -and $image -notmatch 'whoami') { 'reverse proxy' }
        elseif ($image -match 'cloudflared') { 'tunnel connector' }
        elseif ($image -match 'socket-proxy') { 'Docker socket proxy' }
        elseif ($image -match '(^|/)(postgres|mariadb|mysql|mongo|mongodb-community-server|immich-app/postgres)(:|@|$)') { 'database' }
        elseif ($image -match '(^|/)(redis|valkey|keydb|memcached)(:|@|$)') { 'cache' }
        elseif ($image -match '(^|/)(nats|rabbitmq)(:|@|$)') { 'message broker' }
        elseif ($image -match '(^|/)(openldap|lldap)(:|@|$)') { 'directory' }
        else { 'application' })
    }
  }
}

# LAN subnets of this PC and LAN targets of published services: a Docker network on the same range captures that traffic.
$lan = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|WSL|Loopback' } |
    ForEach-Object { $o = (ConvertTo-IpNumber $_.IPAddress) -band [uint32]([uint32]::MaxValue -shl (32 - $_.PrefixLength)); $b = [BitConverter]::GetBytes([uint32]$o); [Array]::Reverse($b); "$(([Net.IPAddress]::new($b)).ToString())/$($_.PrefixLength)" } | Select-Object -Unique)
$lanTargets = @()
$svcFile = Join-Path $ProjectPath 'config\services.json'
if (Test-Path -LiteralPath $svcFile) { $lanTargets = @(@(([IO.File]::ReadAllText($svcFile) | ConvertFrom-Json).services) | Where-Object { $_.target.type -eq 'lan' } | ForEach-Object { [ordered]@{ service = $_.name; host = [string]$_.target.host; port = [int]$_.target.port } }) }

# Networks.
$networks = @()
$netInspect = (docker network inspect @(docker network ls -q)) -join "`n" | ConvertFrom-Json
foreach ($n in $netInspect) {
  $members = @($containers | Where-Object { $_.networks -contains $n.Name })
  $running = @($members | Where-Object { $_.state -eq 'running' })
  $subnets = @($n.IPAM.Config | Where-Object { $_ -and $_.PSObject.Properties['Subnet'] } | ForEach-Object { [string]$_.Subnet })
  $project = Get-Label $n.Labels 'com.docker.compose.project'
  $conflicts = @()
  foreach ($sn in $subnets) {
    foreach ($l in $lan) { if (Test-SubnetOverlap $sn $l) { $conflicts += "overlaps this PC's LAN $l" } }
    foreach ($t in $lanTargets) { if (Test-InSubnet $t.host $sn) { $conflicts += "contains LAN target $($t.host):$($t.port) of service '$($t.service)': traffic from containers to it stays inside Docker" } }
  }
  $status = $(if ($n.Name -in 'bridge', 'host', 'none') { 'built-in' }
    elseif ($running.Count) { 'in use' }
    elseif ($members.Count) { 'required by stopped containers' }
    else { 'unused' })
  $roles = @($members | ForEach-Object { $_.role } | Select-Object -Unique)
  $networks += [ordered]@{
    name = $n.Name; driver = [string]$n.Driver; internal = [bool]$n.Internal; subnets = $subnets; project = $project
    status = $status; conflicts = $conflicts; isProxyNetwork = ($n.Name -eq $s.ProxyNetwork)
    members = @($members | ForEach-Object { "$($_.name) ($($_.state), $($_.role))" })
    sensitiveOnProxy = $(if ($n.Name -eq $s.ProxyNetwork) { @($members | Where-Object { $_.role -in 'database', 'cache', 'message broker', 'directory', 'Docker socket proxy' } | ForEach-Object { $_.name }) } else { @() })
    roles = $roles
  }
}

# Report.
"Docker network audit ($(Get-Date -Format 's')) - read-only. Shared proxy network: $($s.ProxyNetwork)"
''
'NETWORKS'
foreach ($n in $networks | Sort-Object { $_.status }, { $_.name }) {
  '{0} [{1}{2}] {3} - {4}{5}' -f $n.name, $n.driver, $(if ($n.internal) { ', internal' } else { '' }), ($n.subnets -join ','), $n.status, $(if ($n.project) { " (Compose project $($n.project))" } else { '' })
  foreach ($m in $n.members) { "    $m" }
  foreach ($c in $n.conflicts) { "    CONFLICT: $c" }
  foreach ($x in $n.sensitiveOnProxy) { "    WARNING: $x is a sensitive dependency on the shared proxy network" }
}
''
'CONTAINERS'
foreach ($c in $containers | Sort-Object { $_.project }, { $_.name }) {
  $cf = $(if ($c.configFile) { $(if (Test-Path -LiteralPath (($c.configFile -split ',')[0])) { 'compose file present' } else { 'COMPOSE FILE MISSING' }) } else { 'not Compose' })
  '{0} [{1}] {2} project={3} ({4}) networks={5}' -f $c.name, $c.state, $c.role, $(if ($c.project) { $c.project } else { '-' }), $cf, ($c.networks -join ',')
  foreach ($p in $c.ports) {
    $warn = $(if ($p.hostIp -eq '0.0.0.0') { $(if ($c.role -in 'database', 'cache', 'message broker', 'directory', 'Docker socket proxy') { '  WARNING: sensitive port published on all interfaces (LAN)' } else { '  note: published on all interfaces (LAN)' }) } else { '' })
    "    $($p.hostIp):$($p.hostPort) -> $($p.container)$warn"
  }
}
if ($JsonFile) { [IO.File]::WriteAllText($JsonFile, ([ordered]@{ proxyNetwork = $s.ProxyNetwork; lan = $lan; lanTargets = $lanTargets; networks = $networks; containers = $containers } | ConvertTo-Json -Depth 8)) }
