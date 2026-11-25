#requires -version 5.1
# Shared backend for install.ps1, services.ps1, the tunnel wizard, the tests and the web UI (webui.ps1).
# Cloudflare API access lives in lib\CloudflareApi.psm1.
#
# Proxied applications are described in a service registry (config\services.json). Each enabled service is
# rendered into one Traefik file-provider route, traefik\dynamic\svc-<name>.yml. Changes are always computed
# as a plan first (preview), validated (shallow rules + optionally a throwaway Traefik container), backed up
# and only then written. Nothing in this module starts, stops or recreates stack containers.
Set-StrictMode -Version 2.0

$script:TraefikImage = 'traefik:v3.7.15'   # keep in sync with compose.yaml
# Version of this manager (scripts + web UI). Recorded in configuration backups; bump it when the package changes.
$script:ManagerVersion = '1.3.0'
$script:RegistryVersion = 1
$script:ManagedPrefix = 'svc-'
$script:HostnamePattern = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
$script:ServiceNamePattern = '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'
$script:ContainerNamePattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'
$script:HostTargetPattern = '^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
$script:MiddlewarePattern = '^[A-Za-z0-9][A-Za-z0-9-]{0,62}(@(file|docker|internal))?$'
$script:PathPrefixPattern = '^/[A-Za-z0-9._~/-]*$'
$script:TargetTypes = @('docker', 'host', 'lan')
$script:Protocols = @('http', 'https', 'h2c')
$script:WindowsHost = 'host.docker.internal'
$script:DefaultMiddlewares = @('default-headers@file')
# Sign-in providers a service route can use (ForwardAuth rendered into its own svc-<name>.yml).
$script:AuthProviders = @('authentik')
$script:AuthEndpointPattern = '^http://[A-Za-z0-9][A-Za-z0-9_.-]{0,127}:\d{1,5}$'
$script:AuthMiddlewareHint = '(?i)authelia|authentik|forward-?auth|oauth2?-proxy|sso'
# authentik's embedded outpost: ForwardAuth endpoint for Traefik, the path prefix its own pages and callbacks use on
# every protected hostname, and the headers it returns to the application (docs.goauthentik.io, proxy provider, Traefik).
$script:AuthentikOutpostPrefix = '/outpost.goauthentik.io/'
$script:AuthentikResponseHeaders = @('X-authentik-username', 'X-authentik-groups', 'X-authentik-entitlements', 'X-authentik-email', 'X-authentik-name', 'X-authentik-uid',
  'X-authentik-jwt', 'X-authentik-meta-jwks', 'X-authentik-meta-outpost', 'X-authentik-meta-provider', 'X-authentik-meta-app', 'X-authentik-meta-version')
# Names, hostnames or ports that suggest a media server (Cloudflare restricts video delivery).
$script:MediaHints = '(?i)plex|jellyfin|emby|video|stream|media|movie|tv'
$script:MediaPorts = @(32400, 8096, 8920)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- General helpers -------------------------------------------------------------------------------

# Runs docker without letting PowerShell 5.1 turn native stderr output into terminating errors.
# Plain function (no param block) so docker flags such as -q / -f are not parsed as PowerShell parameters.
function Invoke-Docker {
  $DockerArgs = @($args | ForEach-Object { $_ })
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & docker @DockerArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  return [pscustomobject]@{ ExitCode = $code; Output = @($output) }
}

function Read-DotEnv([string]$Path) {
  $values = @{}
  if (Test-Path -LiteralPath $Path) {
    foreach ($line in Get-Content -LiteralPath $Path) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
  }
  return $values
}

function Get-FileSha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-TextSha256([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  return [BitConverter]::ToString($sha.ComputeHash($script:Utf8NoBom.GetBytes($Text))).Replace('-', '')
}

function Get-ManagerVersion { return $script:ManagerVersion }

# One line of a deployment review, shown grouped by stage in the web UI:
#   Stage: prepared | validated | applied | verified | action (requires user action)
#   State: ok | failed | warning | pending | info
function New-ReviewItem([string]$Stage, [string]$State, [string]$Label, [string]$Message = '') {
  return [pscustomobject][ordered]@{ stage = $Stage; state = $State; label = $Label; message = $Message }
}

# image: lines of a compose file, as role -> image (e.g. traefik -> traefik:v3.7.15@sha256:...).
function Get-ComposeImages([string]$ComposePath) {
  $images = [ordered]@{}
  if (-not (Test-Path -LiteralPath $ComposePath)) { return $images }
  $service = ''
  foreach ($line in [IO.File]::ReadAllLines($ComposePath)) {
    if ($line -match '^  ([a-z0-9-]+):\s*$') { $service = $Matches[1] }
    elseif ($service -and $line -match '^    image:\s*(\S+)') { $images[$service] = $Matches[1] }
  }
  return $images
}

# Writes UTF-8 (no BOM) with LF line endings via a temporary file, so readers never see a half-written file.
function Write-TextFileAtomic([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $tmp = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  [IO.File]::WriteAllText($tmp, $Content.Replace("`r`n", "`n"), $script:Utf8NoBom)
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertTo-IPv4Range([string]$Cidr) {
  $parts = $Cidr.Split('/')
  $bytes = ([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
  [Array]::Reverse($bytes)
  $address = [BitConverter]::ToUInt32($bytes, 0)
  $size = [Math]::Pow(2, 32 - [int]$parts[1])
  $first = [Math]::Floor($address / $size) * $size
  return @($first, ($first + $size - 1))
}

function Test-CidrOverlap([string]$A, [string]$B) {
  $ra = ConvertTo-IPv4Range $A
  $rb = ConvertTo-IPv4Range $B
  return ($ra[0] -le $rb[1]) -and ($rb[0] -le $ra[1])
}

function Test-IPv4Address([string]$Value) {
  if ($Value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
  foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
  return $true
}

function Test-PrivateIPv4([string]$Value) {
  return ($Value -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)')
}

# --- Stack settings --------------------------------------------------------------------------------

# Instance settings from <InstallPath>\.env (falls back to .env.example, then to built-in defaults).
function Get-StackSettings {
  param([Parameter(Mandatory = $true)][string]$InstallPath, [string]$EnvPath)
  if (-not $EnvPath) { $EnvPath = Join-Path $InstallPath '.env' }
  $values = Read-DotEnv $EnvPath
  if ($values.Count -eq 0) { $values = Read-DotEnv (Join-Path $InstallPath '.env.example') }
  return ConvertTo-StackSettings -InstallPath $InstallPath -Values $values
}

# Instance settings from .env-style values (KEY = value); missing keys get the built-in defaults.
function ConvertTo-StackSettings {
  param([Parameter(Mandatory = $true)][string]$InstallPath, [hashtable]$Values = @{})
  $values = $Values
  $get = {
    param($Key, $Default)
    if ($values.ContainsKey($Key) -and $values[$Key]) { return $values[$Key] }
    return $Default
  }
  $stack = & $get 'STACK_NAME' 'traefik-proxy'
  if ($stack -notmatch '^[a-z0-9][a-z0-9_-]{0,40}$') { throw "STACK_NAME '$stack' is invalid: use lowercase letters, digits, '-' and '_'." }
  return [pscustomobject]@{
    InstallPath          = $InstallPath
    StackName            = $stack
    HttpPort             = [int](& $get 'TRAEFIK_HTTP_PORT' '8180')
    DashboardPort        = [int](& $get 'TRAEFIK_DASHBOARD_PORT' '8181')
    ProxyNetwork         = & $get 'PROXY_NETWORK' 'proxy'
    TunnelSubnet         = & $get 'TUNNEL_SUBNET' '172.31.250.0/28'
    TunnelIpRange        = & $get 'TUNNEL_IP_RANGE' '172.31.250.0/29'
    CloudflaredIp        = & $get 'CLOUDFLARED_IP' '172.31.250.10'
    TraefikContainer     = "$stack-traefik"
    SocketProxyContainer = "$stack-socket-proxy"
    CloudflaredContainer = "$stack-cloudflared"
    WhoamiContainer      = "$stack-whoami"
    TunnelNetwork        = "${stack}_tunnel"
    DynamicDir           = Join-Path $InstallPath 'traefik\dynamic'
    RegistryPath         = Join-Path $InstallPath 'config\services.json'
    BackupRoot           = Join-Path $InstallPath 'backups'
    TraefikImage         = $script:TraefikImage
  }
}

# Consistency checks for .env values that Compose cannot express (returns error messages).
function Test-StackSettings($Settings) {
  $errors = @()
  foreach ($p in @('HttpPort', 'DashboardPort')) { if ($Settings.$p -lt 1 -or $Settings.$p -gt 65535) { $errors += "$p must be 1-65535." } }
  if ($Settings.HttpPort -eq $Settings.DashboardPort) { $errors += 'TRAEFIK_HTTP_PORT and TRAEFIK_DASHBOARD_PORT must differ.' }
  if ($Settings.ProxyNetwork -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { $errors += "PROXY_NETWORK '$($Settings.ProxyNetwork)' is not a valid network name." }
  $cidr = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
  if ($Settings.TunnelSubnet -notmatch $cidr -or $Settings.TunnelIpRange -notmatch $cidr -or -not (Test-IPv4Address $Settings.CloudflaredIp)) {
    $errors += 'TUNNEL_SUBNET / TUNNEL_IP_RANGE must be IPv4 CIDRs and CLOUDFLARED_IP an IPv4 address.'
    return $errors
  }
  $subnet = ConvertTo-IPv4Range $Settings.TunnelSubnet
  $range = ConvertTo-IPv4Range $Settings.TunnelIpRange
  $ip = ConvertTo-IPv4Range ($Settings.CloudflaredIp + '/32')
  if ($range[0] -lt $subnet[0] -or $range[1] -gt $subnet[1]) { $errors += 'TUNNEL_IP_RANGE must lie inside TUNNEL_SUBNET.' }
  if ($ip[0] -le $subnet[0] -or $ip[0] -ge $subnet[1]) { $errors += 'CLOUDFLARED_IP must be a host address inside TUNNEL_SUBNET.' }
  if ($ip[0] -ge $range[0] -and $ip[0] -le $range[1]) { $errors += 'CLOUDFLARED_IP must be outside TUNNEL_IP_RANGE (that range is handed out to other containers).' }
  return $errors
}

# The .env keys that make an instance unique, with the settings property each one maps to.
$script:InstanceKeys = [ordered]@{
  STACK_NAME = 'StackName'; TRAEFIK_HTTP_PORT = 'HttpPort'; TRAEFIK_DASHBOARD_PORT = 'DashboardPort'; PROXY_NETWORK = 'ProxyNetwork'
  TUNNEL_SUBNET = 'TunnelSubnet'; TUNNEL_IP_RANGE = 'TunnelIpRange'; CLOUDFLARED_IP = 'CloudflaredIp'
}

function ConvertTo-InstanceValues($Settings) {
  $values = [ordered]@{}
  foreach ($k in $script:InstanceKeys.Keys) { $values[$k] = [string]$Settings.($script:InstanceKeys[$k]) }
  return $values
}

# .env text: the template (normally .env.example) with the instance keys replaced; comments are kept.
function New-DotEnvContent([string]$Template, $Values) {
  $done = @{}
  $lines = @(foreach ($line in ($Template -split "`r?`n")) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=' -and $Values.Contains($Matches[1])) { $done[$Matches[1]] = $true; "$($Matches[1])=$($Values[$Matches[1]])" }
      else { $line }
    })
  foreach ($k in $Values.Keys) { if (-not $done.ContainsKey($k)) { $lines += "$k=$($Values[$k])" } }
  return (($lines -join "`n").TrimEnd() + "`n")
}

function Test-DockerEngine {
  return [bool]((Get-Command docker -ErrorAction SilentlyContinue) -and (Invoke-Docker info --format '{{.OSType}}').ExitCode -eq 0)
}

# Read-only checks of instance settings against what already exists on this PC: container names, loopback ports,
# the tunnel subnet and the shared network. Returns @{ Key; Level = error|warning|info; Message }.
function Get-StackConflicts {
  param([Parameter(Mandatory = $true)]$Settings)
  $out = New-Object System.Collections.ArrayList
  $add = { param($Key, $Level, $Message) $null = $out.Add([pscustomobject][ordered]@{ Key = $Key; Level = $Level; Message = $Message }) }
  foreach ($e in @(Test-StackSettings $Settings)) { & $add 'settings' 'error' $e }
  if (-not (Test-DockerEngine)) {
    & $add 'docker' 'warning' 'Docker is not running, so names, ports and networks could not be checked yet.'
    return $out.ToArray()
  }
  $ownTraefik = $false
  foreach ($name in @($Settings.TraefikContainer, $Settings.SocketProxyContainer, $Settings.CloudflaredContainer)) {
    $r = Invoke-Docker inspect $name --format '{{json .Config.Labels}}'
    if ($r.ExitCode -ne 0) { continue }
    $labels = $null
    try { $labels = (@($r.Output)[-1]) | ConvertFrom-Json } catch { }
    $project = ''; $dir = ''
    if ($labels -and $labels.PSObject.Properties['com.docker.compose.project']) { $project = [string]$labels.'com.docker.compose.project' }
    if ($labels -and $labels.PSObject.Properties['com.docker.compose.project.working_dir']) { $dir = [string]$labels.'com.docker.compose.project.working_dir' }
    $sameDir = $dir -and ([IO.Path]::GetFullPath($dir).TrimEnd('\') -eq [IO.Path]::GetFullPath($Settings.InstallPath).TrimEnd('\'))
    if ($project -eq $Settings.StackName -and $sameDir) {
      & $add 'STACK_NAME' 'info' "Container '$name' belongs to this instance."
      if ($name -eq $Settings.TraefikContainer) { $ownTraefik = $true }
    } else {
      $owner = if ($project) { "project '$project'" } else { 'another program' }
      & $add 'STACK_NAME' 'error' "A container named '$name' already exists ($owner). Choose another instance name."
    }
  }
  foreach ($p in @(@('TRAEFIK_HTTP_PORT', $Settings.HttpPort), @('TRAEFIK_DASHBOARD_PORT', $Settings.DashboardPort))) {
    $user = Get-PortUser $p[1]
    if (-not $user) { continue }
    if ($ownTraefik -and $user -eq "container '$($Settings.TraefikContainer)'") { continue }
    & $add $p[0] 'error' "Port $($p[1]) is already in use on this PC (by $user)."
  }
  if ($Settings.TunnelSubnet -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    foreach ($id in @((Invoke-Docker network ls -q).Output | Where-Object { $_ })) {
      $parts = ([string](@((Invoke-Docker network inspect $id --format '{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}').Output)[-1])).Split('|')
      if ($parts.Count -lt 2 -or $parts[0] -eq $Settings.TunnelNetwork) { continue }
      foreach ($subnet in ($parts[1].Trim() -split '\s+')) {
        if ($subnet -match '^\d+\.\d+\.\d+\.\d+/\d+$' -and (Test-CidrOverlap $subnet $Settings.TunnelSubnet)) {
          & $add 'TUNNEL_SUBNET' 'error' "Docker network '$($parts[0])' already uses $subnet, which overlaps $($Settings.TunnelSubnet)."
        }
      }
    }
  }
  $net = Invoke-Docker network inspect $Settings.ProxyNetwork --format '{{len .Containers}}'
  if ($net.ExitCode -eq 0) {
    & $add 'PROXY_NETWORK' 'warning' "The Docker network '$($Settings.ProxyNetwork)' already exists ($((@($net.Output))[-1]) containers attached) and would be shared: every container on it can reach every other one. Choose a new name for an isolated instance."
  }
  return $out.ToArray()
}

# Instance settings that collide with nothing on this PC (container names, ports, networks, subnets). Read-only.
function Get-SuggestedStackSettings {
  param([Parameter(Mandatory = $true)][string]$InstallPath)
  $containers = @(); $networks = @(); $subnets = @()
  if (Test-DockerEngine) {
    $containers = @((Invoke-Docker ps -a --format '{{.Names}}').Output | Where-Object { $_ })
    foreach ($id in @((Invoke-Docker network ls -q).Output | Where-Object { $_ })) {
      $parts = ([string](@((Invoke-Docker network inspect $id --format '{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}').Output)[-1])).Split('|')
      $networks += $parts[0]
      if ($parts.Count -gt 1) { $subnets += @($parts[1].Trim() -split '\s+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' }) }
    }
  }
  $stack = 'traefik-proxy'
  for ($i = 2; $i -le 20; $i++) {
    if (@(@("$stack-traefik", "$stack-socket-proxy", "$stack-cloudflared") | Where-Object { $containers -contains $_ }).Count -eq 0) { break }
    $stack = "traefik-proxy-$i"
  }
  $http = 8180
  foreach ($base in @(8180, 8280, 8380, 8480, 8580, 8680, 8780, 8880, 8980, 9180, 9280)) {
    $http = $base
    if (-not (Get-PortUser $base) -and -not (Get-PortUser ($base + 1))) { break }
  }
  $network = 'proxy'
  if ($networks -contains $network) { $network = "$stack-proxy" }
  $third = 0; $second = 31
  :find foreach ($s in @(31, 30, 29, 28)) {
    for ($t = 250; $t -ge 200; $t--) {
      if (@($subnets | Where-Object { Test-CidrOverlap $_ "172.$s.$t.0/28" }).Count -eq 0) { $second = $s; $third = $t; break find }
    }
  }
  if ($third -eq 0) { $third = 250 }
  return ConvertTo-StackSettings -InstallPath $InstallPath -Values @{
    STACK_NAME = $stack; TRAEFIK_HTTP_PORT = "$http"; TRAEFIK_DASHBOARD_PORT = "$($http + 1)"; PROXY_NETWORK = $network
    TUNNEL_SUBNET = "172.$second.$third.0/28"; TUNNEL_IP_RANGE = "172.$second.$third.0/29"; CLOUDFLARED_IP = "172.$second.$third.10"
  }
}

function Get-ComposeArgs {
  param([Parameter(Mandatory = $true)]$Settings, [string[]]$Profiles = @())
  $composeArgs = @('compose', '--project-directory', $Settings.InstallPath, '-f', (Join-Path $Settings.InstallPath 'compose.yaml'))
  foreach ($p in $Profiles) { $composeArgs += @('--profile', $p) }
  return $composeArgs
}

function Test-ContainerRunning([string]$Name) {
  return (((Invoke-Docker inspect $Name --format '{{.State.Running}}').Output -join '').Trim() -eq 'true')
}

# Who is using a TCP port on this PC. Get-NetTCPConnection does not always list Docker Desktop's port
# forwards, so a loopback connect and the published ports of running containers are checked as well.
# Returns $null when the port is free, otherwise a short description of the user.
function Get-PortUser([int]$Port) {
  if (@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count -gt 0) { return 'a listening process' }
  $r = Invoke-Docker ps --format '{{.Names}}|{{.Ports}}'
  if ($r.ExitCode -eq 0) {
    foreach ($line in @($r.Output)) {
      $parts = ([string]$line).Split('|', 2)
      if ($parts.Count -eq 2 -and $parts[1] -match ('(^|[\s,])[^\s,]*:' + $Port + '->')) { return "container '$($parts[0])'" }
    }
  }
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync([System.Net.IPAddress]::Loopback, $Port)
    if ($task.Wait(500) -and $client.Connected) { return 'a process accepting connections' }
  } catch { } finally { $client.Close() }
  return $null
}

# Docker Desktop does not forward file-change events from Windows paths into the Linux VM, so Traefik's
# file provider never notices edits made on Windows. Touching a file from a container inside the VM does
# raise the event, and Traefik reloads traefik\dynamic\ without a restart.
function Sync-TraefikDynamic {
  param([Parameter(Mandatory = $true)]$Settings)
  $dir = $Settings.DynamicDir
  $r = Invoke-Docker run --rm --network none -v "${dir}:/d" --entrypoint sh $Settings.TraefikImage -c 'touch /d/.reload'
  if ($r.ExitCode -ne 0) { return ('Could not trigger a Traefik reload: ' + ($r.Output -join ' ') + " - run: docker restart $($Settings.TraefikContainer)") }
  return $null
}

# --- Service registry --------------------------------------------------------------------------------

function Get-ServiceProperty($Object, [string]$Name, $Default) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
  return $Default
}

# Returns a service definition with every field present and normalized (lowercase hostnames, int port, ...).
# Accepts objects from JSON, hashtables or the web UI. Invalid values are kept as-is for Test-ServiceDefinition.
function ConvertTo-ServiceDefinition($InputObject) {
  if ($InputObject -is [hashtable]) { $InputObject = [pscustomobject]$InputObject }
  $target = Get-ServiceProperty $InputObject 'target' $null
  if ($target -is [hashtable]) { $target = [pscustomobject]$target }
  $cloudflare = Get-ServiceProperty $InputObject 'cloudflare' $null
  if ($cloudflare -is [hashtable]) { $cloudflare = [pscustomobject]$cloudflare }
  # Cloudflare Access defaults to on, except for a service protected by authentik: two interactive logins are never a
  # default (layered authentication is chosen explicitly).
  $authIn = Get-ServiceProperty $InputObject 'auth' $null
  if ($authIn -is [hashtable]) { $authIn = [pscustomobject]$authIn }
  $accessDefault = -not (([string](Get-ServiceProperty $authIn 'provider' '')).Trim().ToLowerInvariant() -eq 'authentik')

  $type = ([string](Get-ServiceProperty $target 'type' 'docker')).Trim().ToLowerInvariant()
  $hostValue = ([string](Get-ServiceProperty $target 'host' '')).Trim()
  if ($type -eq 'host' -and -not $hostValue) { $hostValue = $script:WindowsHost }
  if ($type -ne 'docker') { $hostValue = $hostValue.ToLowerInvariant() }
  $portValue = Get-ServiceProperty $target 'port' 0
  $port = 0
  if (-not [int]::TryParse([string]$portValue, [ref]$port)) { $port = -1 }

  $hostnames = @(Get-ServiceProperty $InputObject 'hostnames' @() | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
  $middlewares = @(Get-ServiceProperty $InputObject 'middlewares' $script:DefaultMiddlewares | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })

  $definition = [ordered]@{
    name        = ([string](Get-ServiceProperty $InputObject 'name' '')).Trim().ToLowerInvariant()
    description = [string](Get-ServiceProperty $InputObject 'description' '')
    enabled     = [bool](Get-ServiceProperty $InputObject 'enabled' $true)
    hostnames   = $hostnames
    pathPrefix  = ([string](Get-ServiceProperty $InputObject 'pathPrefix' '')).Trim()
    stripPrefix = [bool](Get-ServiceProperty $InputObject 'stripPrefix' $false)
    target      = [pscustomobject][ordered]@{
      type          = $type
      host          = $hostValue
      port          = $port
      protocol      = ([string](Get-ServiceProperty $target 'protocol' 'http')).Trim().ToLowerInvariant()
      tlsSkipVerify = [bool](Get-ServiceProperty $target 'tlsSkipVerify' $false)
    }
    middlewares = $middlewares
    cloudflare  = [pscustomobject][ordered]@{
      publish = [bool](Get-ServiceProperty $cloudflare 'publish' $true)
      access  = [bool](Get-ServiceProperty $cloudflare 'access' $accessDefault)
    }
  }
  # Optional human-readable name ("Notflix"); the name above stays the id. Only stored when set, so registries
  # written by earlier versions are unchanged.
  $displayName = ([string](Get-ServiceProperty $InputObject 'displayName' '')).Trim()
  if ($displayName) { $definition.Insert(1, 'displayName', $displayName) }
  # Optional sign-in in front of the application (identity provider ForwardAuth). Only stored when set, like
  # displayName, so registries without it are unchanged. The endpoint is the provider's internal address on the
  # shared network (Docker DNS name and container port), never an IP address.
  $auth = Get-ServiceProperty $InputObject 'auth' $null
  if ($auth -is [hashtable]) { $auth = [pscustomobject]$auth }
  $authProvider = ([string](Get-ServiceProperty $auth 'provider' '')).Trim().ToLowerInvariant()
  if ($authProvider -and $authProvider -ne 'none') {
    $definition['auth'] = [pscustomobject][ordered]@{
      provider = $authProvider
      endpoint = ([string](Get-ServiceProperty $auth 'endpoint' '')).Trim().TrimEnd('/')
    }
    # Layered authentication (Cloudflare Access in front of authentik) is a deliberate choice, stored only when made.
    if ([bool](Get-ServiceProperty $auth 'layered' $false)) { $definition['auth'] | Add-Member -NotePropertyName layered -NotePropertyValue $true }
  }
  # Optional owner of the route (docs/universal-apps.md): the integration or instance that created it, so removing an
  # integration removes only its own routes. Only stored when set, so registries without it are unchanged.
  $owner = Get-ServiceProperty $InputObject 'owner' $null
  if ($owner -is [hashtable]) { $owner = [pscustomobject]$owner }
  $ownerKind = ([string](Get-ServiceProperty $owner 'kind' '')).Trim().ToLowerInvariant()
  if ($ownerKind) {
    $definition['owner'] = [pscustomobject][ordered]@{
      kind          = $ownerKind
      instanceId    = ([string](Get-ServiceProperty $owner 'instanceId' '')).Trim()
      integrationId = ([string](Get-ServiceProperty $owner 'integrationId' '')).Trim()
    }
  }
  return [pscustomobject]$definition
}

function New-ServiceDefinition {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Hostname,
    [Parameter(Mandatory = $true)][ValidateSet('docker', 'host', 'lan')][string]$TargetType,
    [string]$TargetHost,
    [Parameter(Mandatory = $true)][int]$Port,
    [string]$Protocol = 'http',
    [switch]$TlsSkipVerify,
    [string]$PathPrefix,
    [switch]$StripPrefix,
    [string[]]$Middleware = $script:DefaultMiddlewares,
    [string]$Description,
    [switch]$Disabled,
    [bool]$Publish = $true,
    [bool]$Access = $true
  )
  return ConvertTo-ServiceDefinition @{
    name = $Name; description = $Description; enabled = (-not $Disabled); hostnames = $Hostname
    pathPrefix = $PathPrefix; stripPrefix = [bool]$StripPrefix; middlewares = $Middleware
    target = @{ type = $TargetType; host = $TargetHost; port = $Port; protocol = $Protocol; tlsSkipVerify = [bool]$TlsSkipVerify }
    cloudflare = @{ publish = $Publish; access = $Access }
  }
}

function Read-ServiceRegistry {
  param([Parameter(Mandatory = $true)]$Settings)
  $path = $Settings.RegistryPath
  if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ version = $script:RegistryVersion; services = @() } }
  try { $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json }
  catch { throw "config\services.json is not valid JSON: $($_.Exception.Message)" }
  $services = @(Get-ServiceProperty $json 'services' @() | ForEach-Object { ConvertTo-ServiceDefinition $_ })
  return [pscustomobject]@{ version = (Get-ServiceProperty $json 'version' $script:RegistryVersion); services = $services }
}

# Small deterministic JSON writer (2-space indent, arrays of scalars on one line). Windows PowerShell 5.1's
# ConvertTo-Json output is hard to read and diff, and stable output keeps backups and previews meaningful.
function ConvertTo-StableJson($Value, [int]$Indent = 0) {
  $pad = '  ' * ($Indent + 1)
  $end = '  ' * $Indent
  if ($null -eq $Value) { return 'null' }
  if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
  if ($Value -is [string]) { return (ConvertTo-Json -InputObject $Value -Compress) }
  if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
    # A list, not @(... ,@(k, v)): with a single pair PowerShell 5.1 would flatten it into (k, v).
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { $pairs.Add(@($k, $Value[$k])) } }
    else { foreach ($p in $Value.PSObject.Properties) { $pairs.Add(@($p.Name, $p.Value)) } }
    if ($pairs.Count -eq 0) { return '{}' }
    $items = foreach ($p in $pairs) { $pad + (ConvertTo-Json -InputObject ([string]$p[0]) -Compress) + ': ' + (ConvertTo-StableJson $p[1] ($Indent + 1)) }
    return "{`n" + ($items -join ",`n") + "`n$end}"
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    $arr = @($Value)
    if ($arr.Count -eq 0) { return '[]' }
    if (@($arr | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -or $_ -is [System.Collections.IDictionary] }).Count -eq 0) {
      return '[' + ((@($arr | ForEach-Object { ConvertTo-StableJson $_ })) -join ', ') + ']'
    }
    return "[`n" + ((@($arr | ForEach-Object { $pad + (ConvertTo-StableJson $_ ($Indent + 1)) })) -join ",`n") + "`n$end]"
  }
  return (ConvertTo-Json -InputObject ([string]$Value) -Compress)
}

function ConvertTo-RegistryJson($Services) {
  $doc = [ordered]@{ version = $script:RegistryVersion; services = @($Services | Sort-Object name) }
  return (ConvertTo-StableJson $doc) + "`n"
}

# --- Validation ----------------------------------------------------------------------------------------

function New-Issue([string]$Level, [string]$Service, [string]$Field, [string]$Message) {
  return [pscustomobject]@{ Level = $Level; Service = $Service; Field = $Field; Message = $Message }
}

# Middleware names defined by hand-written files in traefik\dynamic (generated svc-*.yml excluded).
function Get-AvailableMiddlewares {
  param([Parameter(Mandatory = $true)]$Settings)
  $names = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $Settings.DynamicDir)) { return @() }
  foreach ($file in Get-ChildItem -LiteralPath $Settings.DynamicDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' -and -not $_.Name.StartsWith($script:ManagedPrefix) }) {
    $inBlock = $false
    foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
      if ($line -match '^  middlewares:\s*$') { $inBlock = $true; continue }
      if ($inBlock -and $line -match '^  \S') { $inBlock = $false }
      if ($inBlock -and $line -match '^    ([A-Za-z0-9-]+):\s*$') { $names.Add($Matches[1]) }
    }
  }
  return @($names | Select-Object -Unique)
}

# Returns a list of issues (Level Error|Warning). A definition with no Error issues can be rendered.
function Test-ServiceDefinition {
  param(
    [Parameter(Mandatory = $true)]$Service,
    $OtherServices = @(),
    [string[]]$AvailableMiddlewares
  )
  $s = ConvertTo-ServiceDefinition $Service
  $n = $s.name
  $issues = New-Object System.Collections.ArrayList
  $err = { param($f, $m) $null = $issues.Add((New-Issue 'Error' $n $f $m)) }
  $warn = { param($f, $m) $null = $issues.Add((New-Issue 'Warning' $n $f $m)) }

  if ($s.PSObject.Properties['displayName'] -and ($s.displayName.Length -gt 60 -or $s.displayName -match '[\x00-\x1f<>]')) { & $err 'displayName' 'Display name: at most 60 characters, no line breaks or angle brackets.' }
  if ($n -notmatch $script:ServiceNamePattern) { & $err 'name' 'Name must be 1-40 lowercase letters, digits or dashes (e.g. plex, home-assistant).' }
  elseif (@($OtherServices | Where-Object { $_.name -eq $n }).Count -gt 0) { & $err 'name' "A service named '$n' already exists." }

  if (@($s.hostnames).Count -eq 0) { & $err 'hostnames' 'At least one hostname is required (e.g. app.example.com).' }
  foreach ($h in $s.hostnames) {
    if ($h -notmatch $script:HostnamePattern) { & $err 'hostnames' "'$h' is not a valid fully qualified hostname." ; continue }
    foreach ($o in @($OtherServices | Where-Object { $_.enabled -and $s.enabled })) {
      if (@($o.hostnames) -contains $h -and $o.pathPrefix -eq $s.pathPrefix) {
        & $err 'hostnames' "$h$($s.pathPrefix) is already routed by service '$($o.name)'."
      }
    }
  }
  if (@($s.hostnames | Select-Object -Unique).Count -ne @($s.hostnames).Count) { & $err 'hostnames' 'Hostnames are listed more than once.' }
  if ($s.PSObject.Properties['owner']) {
    $o = $s.owner
    if ($o.kind -notin 'integration', 'provision', 'app' -or $o.instanceId -notmatch '^(x|i)-[0-9a-f]{6,12}$' -or ($o.integrationId -and $o.integrationId -notmatch '^int-[0-9a-f]{12}$')) {
      & $err 'owner' 'The route owner must be an integration, provisioning operation or app with a valid instance id.'
    }
  }

  if ($s.pathPrefix) {
    if ($s.pathPrefix -notmatch $script:PathPrefixPattern -or $s.pathPrefix -eq '/') { & $err 'pathPrefix' "Path prefix must start with / and contain only letters, digits and . _ ~ / - (e.g. /api)." }
  } elseif ($s.stripPrefix) { & $err 'stripPrefix' 'Strip prefix needs a path prefix.' }

  $t = $s.target
  if ($script:TargetTypes -notcontains $t.type) { & $err 'target.type' "Target type must be one of: $($script:TargetTypes -join ', ')." }
  if ($t.port -lt 1 -or $t.port -gt 65535) { & $err 'target.port' 'Port must be a number from 1 to 65535.' }
  if ($script:Protocols -notcontains $t.protocol) { & $err 'target.protocol' "Protocol must be one of: $($script:Protocols -join ', ')." }
  if ($t.tlsSkipVerify -and $t.protocol -ne 'https') { & $err 'target.tlsSkipVerify' 'Skipping certificate verification only applies to https targets.' }
  switch ($t.type) {
    'docker' {
      if ($t.host -notmatch $script:ContainerNamePattern) { & $err 'target.host' 'Enter the container name (or Compose service alias) as shown by docker ps.' }
      else { & $warn 'target.host' "The container '$($t.host)' must be attached to the shared proxy network; use the port the app listens on INSIDE the container." }
    }
    'host' {
      if ($t.host -ne $script:WindowsHost) { & $err 'target.host' "Windows host targets always use $($script:WindowsHost)." }
      & $warn 'target.host' "The Windows app must listen on 0.0.0.0 (not only 127.0.0.1) and Windows Firewall must allow port $($t.port) from the Docker Desktop VM."
    }
    'lan' {
      if ($t.host -match '^127\.|^localhost$|^0\.0\.0\.0$') { & $err 'target.host' 'Loopback addresses point at the Traefik container itself. Use target type "host" for apps on this PC.' }
      elseif (Test-IPv4Address $t.host) {
        if (-not (Test-PrivateIPv4 $t.host)) { & $warn 'target.host' "$($t.host) is not a private (RFC 1918) address. Make sure this is really the device you want to publish." }
      } elseif ($t.host -match ':') { & $err 'target.host' 'IPv6 targets are not supported; use an IPv4 address or a DNS name.' }
      elseif ($t.host -notmatch $script:HostTargetPattern) { & $err 'target.host' 'Enter an IPv4 address (e.g. 10.10.0.11) or a DNS name.' }
      elseif ($t.host -notmatch '\.') { & $warn 'target.host' "Single-label names like '$($t.host)' often do not resolve inside Docker Desktop; prefer an IP address or a fully qualified name." }
      if ($t.protocol -eq 'https' -and -not $t.tlsSkipVerify -and (Test-IPv4Address $t.host)) {
        & $warn 'target.tlsSkipVerify' 'An https target addressed by IP rarely has a certificate for that IP. Enable "skip certificate verification" if the device uses a self-signed certificate.'
      }
    }
  }
  if ($t.tlsSkipVerify) { & $warn 'target.tlsSkipVerify' 'Certificate verification to the backend is disabled (acceptable on a trusted LAN only).' }

  foreach ($m in $s.middlewares) {
    if ($m -notmatch $script:MiddlewarePattern) { & $err 'middlewares' "'$m' is not a valid middleware reference (name or name@provider)."; continue }
    $base = ($m -split '@')[0]
    $provider = if ($m.Contains('@')) { ($m -split '@')[1] } else { 'file' }
    if ($provider -eq 'file' -and $null -ne $AvailableMiddlewares -and $AvailableMiddlewares -notcontains $base) {
      & $err 'middlewares' "Middleware '$base' is not defined in traefik\dynamic (available: $($AvailableMiddlewares -join ', '))."
    }
  }
  if ($s.PSObject.Properties['auth']) {
    $a = $s.auth
    if ($script:AuthProviders -notcontains $a.provider) { & $err 'auth.provider' "Sign-in provider '$($a.provider)' is not supported here (supported: $($script:AuthProviders -join ', '))." }
    if ($a.endpoint -notmatch $script:AuthEndpointPattern) { & $err 'auth.endpoint' "The sign-in service address must be an internal http://<container>:<port> address on the shared network (got '$($a.endpoint)')." }
    elseif ($t.type -eq 'docker' -and ($a.endpoint -replace '^http://([^:/]+):\d+$', '$1') -ieq $t.host) {
      & $err 'auth' 'The sign-in service cannot protect itself: its own login pages would require a login (an endless redirect loop).'
    }
    foreach ($m in $s.middlewares) {
      if (($m -split '@')[0] -match $script:AuthMiddlewareHint) { & $err 'middlewares' "Middleware '$m' looks like another sign-in (ForwardAuth) middleware. Only one sign-in provider may protect a route; remove it or choose 'No additional sign-in'." }
    }
    if ($s.cloudflare.publish -and $s.cloudflare.access) {
      # Two interactive gateways are never enabled silently: Cloudflare Access + authentik must be chosen as layered.
      if ($a.PSObject.Properties['layered'] -and $a.layered) { & $warn 'auth' 'Layered authentication: visitors sign in twice (first Cloudflare Access, then authentik). Chosen explicitly.' }
      else { & $err 'auth' 'Cloudflare Access and authentik would both ask for a login (two sign-ins). authentik already protects this service: turn off "Require Cloudflare Access", or choose layered authentication explicitly.' }
    }
  }
  if ($s.middlewares -notcontains 'default-headers@file' -and $s.middlewares -notcontains 'default-headers') {
    & $warn 'middlewares' 'default-headers is not applied: browsers will not get the standard security headers.'
  }

  if ($s.cloudflare.publish) {
    if (-not $s.cloudflare.access -and -not $s.PSObject.Properties['auth']) {
      & $warn 'cloudflare.access' 'Without Cloudflare Access anyone on the Internet can reach this app. Only do this if the app has its own login.'
    }
    $text = ($n + ' ' + $s.description + ' ' + ($s.hostnames -join ' '))
    if ($text -match $script:MediaHints -or $script:MediaPorts -contains $t.port) {
      & $warn 'cloudflare' ('Possible media streaming service. Cloudflare''s self-serve terms restrict serving video or a disproportionate ' +
        'amount of non-HTML content through its proxy/Tunnel unless you use a dedicated Cloudflare media product; heavy streaming ' +
        'can be throttled or the account suspended. Requests are also capped at 100 MB (Free/Pro). Consider the app''s own ' +
        'remote access or a private network (WARP / Cloudflare One) for streaming.')
    }
  }
  return $issues.ToArray()
}

# Validates the whole set: every definition against all the others.
# $ExtraMiddlewares: names defined by files that are about to be written (a restore), counted as available.
function Test-ServiceRegistry {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Services, [string[]]$ExtraMiddlewares = @())
  $available = @(@(Get-AvailableMiddlewares $Settings) + @($ExtraMiddlewares) | Select-Object -Unique)
  $issues = @()
  $list = @($Services)
  for ($i = 0; $i -lt $list.Count; $i++) {
    $others = @(for ($j = 0; $j -lt $list.Count; $j++) { if ($j -ne $i) { $list[$j] } })
    $issues += Test-ServiceDefinition -Service $list[$i] -OtherServices $others -AvailableMiddlewares $available
    # A protected service adds the router svc-<name>-outpost; no other service may own that router name.
    $si = ConvertTo-ServiceDefinition $list[$i]
    if ($si.PSObject.Properties['auth'] -and @($others | Where-Object { ([string]$_.name).ToLowerInvariant() -eq "$($si.name)-outpost" }).Count) {
      $issues += New-Issue 'Error' $si.name 'name' "A service named '$($si.name)-outpost' exists; its route would collide with the sign-in route of '$($si.name)'. Rename one of them."
    }
  }
  return $issues
}

# --- Rendering -------------------------------------------------------------------------------------------

function Get-ServiceFileName([string]$Name) { return "$($script:ManagedPrefix)$Name.yml" }

function Get-ServiceUrl($Service) {
  $t = $Service.target
  return '{0}://{1}:{2}' -f $t.protocol, $t.host, $t.port
}

function Get-ServiceRule($Service) {
  $hostRule = (@($Service.hostnames) | ForEach-Object { 'Host(`' + $_ + '`)' }) -join ' || '
  if (@($Service.hostnames).Count -gt 1) { $hostRule = "($hostRule)" }
  if ($Service.pathPrefix) { return $hostRule + ' && PathPrefix(`' + $Service.pathPrefix + '`)' }
  return $hostRule
}

# Traefik file-provider YAML for one service. All values were validated against strict patterns, so the
# only quoting needed is around the rule.
function ConvertTo-TraefikRouteYaml($Service) {
  $s = ConvertTo-ServiceDefinition $Service
  $id = "$($script:ManagedPrefix)$($s.name)"
  $middlewares = @($s.middlewares)
  $auth = $(if ($s.PSObject.Properties['auth']) { $s.auth } else { $null })
  # Sign-in runs first: an unauthenticated request never reaches the application or its other middlewares.
  if ($auth) { $middlewares = @("$id-authentik") + $middlewares }
  if ($s.stripPrefix) { $middlewares = @("$id-strip") + $middlewares }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Generated from config/services.json (service '$($s.name)'). Do not edit by hand:")
  $lines.Add('# changes here are overwritten. Use services.ps1 or the web UI instead.')
  if ($s.description) { $lines.Add('# ' + ($s.description -replace '[\r\n]+', ' ')) }
  if ($s.PSObject.Properties['owner']) { $lines.Add("# Owner: $($s.owner.kind) $($s.owner.instanceId)$(if ($s.owner.integrationId) { " ($($s.owner.integrationId))" }). Removing that integration removes this route; the application's containers are not touched.") }
  if ($auth) { $lines.Add("# Sign-in: authentik ForwardAuth (embedded outpost at $($auth.endpoint)). If authentik is unreachable, Traefik refuses the request.") }
  $lines.Add('http:')
  $lines.Add('  routers:')
  $lines.Add("    ${id}:")
  $lines.Add("      rule: '" + (Get-ServiceRule $s) + "'")
  $lines.Add('      entryPoints: [web]')
  if ($middlewares.Count -gt 0) { $lines.Add('      middlewares: [' + ($middlewares -join ', ') + ']') }
  $lines.Add("      service: $id")
  if ($auth) {
    # The outpost's own pages (sign-in start, callback, sign-out) on the application's hostname go to authentik
    # without ForwardAuth; the longer rule gives this router priority over the application router.
    $hostRule = (@($s.hostnames) | ForEach-Object { 'Host(`' + $_ + '`)' }) -join ' || '
    if (@($s.hostnames).Count -gt 1) { $hostRule = "($hostRule)" }
    $outpostMiddlewares = @($s.middlewares | Where-Object { $_ -match '^default-headers(@file)?$' })
    $lines.Add("    ${id}-outpost:")
    $lines.Add("      rule: '" + $hostRule + ' && PathPrefix(`' + $script:AuthentikOutpostPrefix + '`)' + "'")
    $lines.Add('      entryPoints: [web]')
    if ($outpostMiddlewares.Count -gt 0) { $lines.Add('      middlewares: [' + ($outpostMiddlewares -join ', ') + ']') }
    $lines.Add("      service: $id-outpost")
  }
  if ($s.stripPrefix -or $auth) { $lines.Add('  middlewares:') }
  if ($auth) {
    $lines.Add("    ${id}-authentik:")
    $lines.Add('      forwardAuth:')
    $lines.Add("        address: $($auth.endpoint)$($script:AuthentikOutpostPrefix)auth/traefik")
    # Safe: the web entry point already replaces X-Forwarded-* from everyone except cloudflared.
    $lines.Add('        trustForwardHeader: true')
    $lines.Add('        maxResponseBodySize: 4194304')
    $lines.Add('        authResponseHeaders:')
    foreach ($hn in $script:AuthentikResponseHeaders) { $lines.Add("          - $hn") }
  }
  if ($s.stripPrefix) {
    $lines.Add("    ${id}-strip:")
    $lines.Add('      stripPrefix:')
    $lines.Add("        prefixes: ['$($s.pathPrefix)']")
  }
  $lines.Add('  services:')
  $lines.Add("    ${id}:")
  $lines.Add('      loadBalancer:')
  $lines.Add('        passHostHeader: true')
  if ($s.target.tlsSkipVerify) { $lines.Add("        serversTransport: $id-transport") }
  $lines.Add('        servers:')
  $lines.Add('          - url: ' + (Get-ServiceUrl $s))
  if ($auth) {
    $lines.Add("    ${id}-outpost:")
    $lines.Add('      loadBalancer:')
    # The outpost finds the application's provider by the Host header.
    $lines.Add('        passHostHeader: true')
    $lines.Add('        servers:')
    $lines.Add("          - url: $($auth.endpoint)")
  }
  if ($s.target.tlsSkipVerify) {
    $lines.Add('  serversTransports:')
    $lines.Add("    ${id}-transport:")
    $lines.Add('      insecureSkipVerify: true')
  }
  return ($lines -join "`n") + "`n"
}

# --- Plan / apply -----------------------------------------------------------------------------------------

# Compares the desired files (from $Services) with traefik\dynamic\svc-*.yml. Never writes anything.
function Get-ServicePlan {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Services, [string[]]$ExtraMiddlewares = @())
  $list = @($Services | ForEach-Object { ConvertTo-ServiceDefinition $_ })
  $issues = @(Test-ServiceRegistry -Settings $Settings -Services $list -ExtraMiddlewares $ExtraMiddlewares)
  $desired = @{}
  foreach ($s in $list | Where-Object { $_.enabled }) {
    if (@($issues | Where-Object { $_.Level -eq 'Error' -and $_.Service -eq $s.name }).Count -gt 0) { continue }
    $desired[(Get-ServiceFileName $s.name)] = [pscustomobject]@{ Service = $s; Content = (ConvertTo-TraefikRouteYaml $s) }
  }
  $existing = @{}
  if (Test-Path -LiteralPath $Settings.DynamicDir) {
    foreach ($f in Get-ChildItem -LiteralPath $Settings.DynamicDir -File -Filter "$($script:ManagedPrefix)*.yml") {
      $existing[$f.Name] = ([IO.File]::ReadAllText($f.FullName)).Replace("`r`n", "`n")
    }
  }
  $changes = @()
  foreach ($file in @($desired.Keys | Sort-Object)) {
    $d = $desired[$file]
    $action = 'add'
    $old = $null
    if ($existing.ContainsKey($file)) { $old = $existing[$file]; $action = if ($old -eq $d.Content) { 'unchanged' } else { 'update' } }
    $changes += [pscustomobject]@{ File = $file; Action = $action; Service = $d.Service.name; OldContent = $old; NewContent = $d.Content }
  }
  foreach ($file in @($existing.Keys | Sort-Object)) {
    if (-not $desired.ContainsKey($file)) {
      $svc = $file.Substring($script:ManagedPrefix.Length, $file.Length - $script:ManagedPrefix.Length - 4)
      $changes += [pscustomobject]@{ File = $file; Action = 'remove'; Service = $svc; OldContent = $existing[$file]; NewContent = $null }
    }
  }
  $currentJson = $null
  if (Test-Path -LiteralPath $Settings.RegistryPath) { $currentJson = ([IO.File]::ReadAllText($Settings.RegistryPath)).Replace("`r`n", "`n") }
  $newJson = ConvertTo-RegistryJson $list
  return [pscustomobject]@{
    Services        = $list
    Changes         = $changes
    Issues          = $issues
    HasErrors       = (@($issues | Where-Object { $_.Level -eq 'Error' }).Count -gt 0)
    RegistryJson    = $newJson
    RegistryChanged = ($currentJson -ne $newJson)
    FileChanges     = @($changes | Where-Object { $_.Action -ne 'unchanged' }).Count
  }
}

# Minimal line diff for previews (LCS on lines; files are small).
function Get-LineDiff([string]$Old, [string]$New) {
  $a = @(); if ($Old) { $a = @($Old.TrimEnd("`n") -split "`n") }
  $b = @(); if ($New) { $b = @($New.TrimEnd("`n") -split "`n") }
  $m = $a.Count; $n = $b.Count
  # Flat (m+1)x(n+1) table; cell (i,j) is at i*w+j.
  $w = $n + 1
  $lcs = New-Object 'int[]' (($m + 1) * $w)
  for ($i = $m - 1; $i -ge 0; $i--) {
    for ($j = $n - 1; $j -ge 0; $j--) {
      if ($a[$i] -eq $b[$j]) { $lcs[$i * $w + $j] = $lcs[($i + 1) * $w + $j + 1] + 1 }
      else {
        $down = $lcs[($i + 1) * $w + $j]
        $right = $lcs[$i * $w + $j + 1]
        $lcs[$i * $w + $j] = [Math]::Max($down, $right)
      }
    }
  }
  $out = New-Object System.Collections.Generic.List[string]
  $i = 0; $j = 0
  while ($i -lt $m -and $j -lt $n) {
    if ($a[$i] -eq $b[$j]) { $out.Add('  ' + $a[$i]); $i++; $j++ }
    elseif ($lcs[($i + 1) * $w + $j] -ge $lcs[$i * $w + $j + 1]) { $out.Add('- ' + $a[$i]); $i++ }
    else { $out.Add('+ ' + $b[$j]); $j++ }
  }
  while ($i -lt $m) { $out.Add('- ' + $a[$i]); $i++ }
  while ($j -lt $n) { $out.Add('+ ' + $b[$j]); $j++ }
  return @($out)
}

# Text rendering of a plan, shared by services.ps1 and the wizard.
function Format-ServicePlan($Plan, [switch]$ShowUnchanged) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($issue in $Plan.Issues) { $out.Add(('[{0}] {1}: {2}' -f $issue.Level.ToUpperInvariant(), $issue.Service, $issue.Message)) }
  if (@($Plan.Issues).Count -gt 0) { $out.Add('') }
  foreach ($c in $Plan.Changes) {
    if ($c.Action -eq 'unchanged' -and -not $ShowUnchanged) { continue }
    $out.Add(('{0,-9} traefik\dynamic\{1}' -f $c.Action.ToUpperInvariant(), $c.File))
    if ($c.Action -ne 'unchanged') { foreach ($line in (Get-LineDiff $c.OldContent $c.NewContent)) { $out.Add('    ' + $line) } }
  }
  if ($Plan.FileChanges -eq 0) { $out.Add('No route file changes.') }
  if ($Plan.RegistryChanged) { $out.Add('config\services.json will be updated.') }
  return @($out)
}

function New-ServiceBackup {
  param([Parameter(Mandatory = $true)]$Settings, [string]$Suffix = '')
  $dir = Join-Path (Join-Path $Settings.BackupRoot 'services') ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + $Suffix)
  New-Item -ItemType Directory -Force -Path (Join-Path $dir 'dynamic') | Out-Null
  $files = @()
  if (Test-Path -LiteralPath $Settings.DynamicDir) {
    foreach ($f in Get-ChildItem -LiteralPath $Settings.DynamicDir -File -Filter "$($script:ManagedPrefix)*.yml") {
      Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dir 'dynamic')
      $files += $f.Name
    }
  }
  $hadRegistry = Test-Path -LiteralPath $Settings.RegistryPath
  if ($hadRegistry) { Copy-Item -LiteralPath $Settings.RegistryPath -Destination (Join-Path $dir 'services.json') }
  $meta = [pscustomobject]@{ createdAt = (Get-Date -Format 's'); registry = $hadRegistry; files = $files }
  Write-TextFileAtomic (Join-Path $dir 'snapshot.json') (ConvertTo-Json -InputObject $meta -Depth 3)
  return $dir
}

function Get-ServiceBackups {
  param([Parameter(Mandatory = $true)]$Settings)
  $root = Join-Path $Settings.BackupRoot 'services'
  if (-not (Test-Path -LiteralPath $root)) { return @() }
  return @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'snapshot.json') } |
      Sort-Object Name -Descending | ForEach-Object {
        $meta = [IO.File]::ReadAllText((Join-Path $_.FullName 'snapshot.json')) | ConvertFrom-Json
        [pscustomobject]@{ Id = $_.Name; Path = $_.FullName; CreatedAt = $meta.createdAt; Files = @($meta.files); Restored = $_.Name.EndsWith('-restored'); PreRollback = $_.Name.EndsWith('-pre-rollback') }
      })
}

# Writes a plan: backup -> registry -> route files -> Traefik reload. Refuses plans with errors.
function Invoke-ServicePlan {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Plan, [switch]$NoReload)
  if ($Plan.HasErrors) { throw 'The configuration has errors; nothing was changed.' }
  if ($Plan.FileChanges -eq 0 -and -not $Plan.RegistryChanged) {
    return [pscustomobject]@{ Changed = $false; Backup = $null; ReloadWarning = $null; Reloaded = $false }
  }
  $backup = New-ServiceBackup $Settings
  Write-TextFileAtomic $Settings.RegistryPath $Plan.RegistryJson
  foreach ($c in $Plan.Changes) {
    $path = Join-Path $Settings.DynamicDir $c.File
    switch ($c.Action) {
      'add' { Write-TextFileAtomic $path $c.NewContent }
      'update' { Write-TextFileAtomic $path $c.NewContent }
      'remove' { Remove-Item -LiteralPath $path -Force }
    }
  }
  $reloadWarning = $null
  $reloaded = $false
  if (-not $NoReload -and $Plan.FileChanges -gt 0 -and (Test-ContainerRunning $Settings.TraefikContainer)) {
    $reloadWarning = Sync-TraefikDynamic $Settings
    $reloaded = -not $reloadWarning
  }
  return [pscustomobject]@{ Changed = $true; Backup = $backup; ReloadWarning = $reloadWarning; Reloaded = $reloaded }
}

# Restores the newest (or the given) snapshot. The current state is saved first as <id>-pre-rollback.
function Restore-ServiceBackup {
  param([Parameter(Mandatory = $true)]$Settings, [string]$Id, [switch]$NoReload)
  $candidates = @(Get-ServiceBackups $Settings | Where-Object { -not $_.Restored -and -not $_.PreRollback })
  if ($Id) { $candidates = @(Get-ServiceBackups $Settings | Where-Object { $_.Id -eq $Id }) }
  if ($candidates.Count -eq 0) { throw 'No service backup to restore.' }
  $snap = $candidates[0]
  $meta = [IO.File]::ReadAllText((Join-Path $snap.Path 'snapshot.json')) | ConvertFrom-Json
  $safety = New-ServiceBackup $Settings -Suffix '-pre-rollback'
  foreach ($f in @(Get-ChildItem -LiteralPath $Settings.DynamicDir -File -Filter "$($script:ManagedPrefix)*.yml")) {
    if (@($meta.files) -notcontains $f.Name) { Remove-Item -LiteralPath $f.FullName -Force }
  }
  foreach ($name in @($meta.files)) {
    Copy-Item -LiteralPath (Join-Path (Join-Path $snap.Path 'dynamic') $name) -Destination (Join-Path $Settings.DynamicDir $name) -Force
  }
  if ($meta.registry) { Copy-Item -LiteralPath (Join-Path $snap.Path 'services.json') -Destination $Settings.RegistryPath -Force }
  elseif (Test-Path -LiteralPath $Settings.RegistryPath) { Remove-Item -LiteralPath $Settings.RegistryPath -Force }
  if (-not $snap.Restored) { Rename-Item -LiteralPath $snap.Path -NewName ($snap.Id + '-restored') }
  $reloadWarning = $null
  if (-not $NoReload -and (Test-ContainerRunning $Settings.TraefikContainer)) { $reloadWarning = Sync-TraefikDynamic $Settings }
  return [pscustomobject]@{ Restored = $snap.Id; SavedCurrentAs = (Split-Path -Leaf $safety); ReloadWarning = $reloadWarning }
}

# --- Deep validation --------------------------------------------------------------------------------------

# Loads the planned traefik\dynamic directory into a throwaway Traefik container (no network, removed
# afterwards) and asks Traefik itself whether every router, service and middleware is valid.
# $ExtraFiles (name -> content) are added to (or replace files in) the staged directory; $ExpectRouters are router
# names (name@file) that must load in addition to the plan's generated ones.
function Test-TraefikDynamicConfig {
  param([Parameter(Mandatory = $true)]$Settings, $Plan, [int]$TimeoutSeconds = 20, [hashtable]$ExtraFiles = @{}, [string[]]$ExpectRouters = @())
  $stage = Join-Path ([IO.Path]::GetTempPath()) ('traefik-validate-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $stage | Out-Null
  $name = "$($Settings.StackName)-validate-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $result = [pscustomobject]@{ Ok = $false; Errors = @(); Warnings = @(); Routers = @() }
  try {
    if (Test-Path -LiteralPath $Settings.DynamicDir) {
      foreach ($f in Get-ChildItem -LiteralPath $Settings.DynamicDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' }) {
        if ($Plan -and $f.Name.StartsWith($script:ManagedPrefix)) { continue }
        Copy-Item -LiteralPath $f.FullName -Destination $stage
      }
    }
    $expected = @($ExpectRouters)
    if ($Plan) {
      foreach ($c in $Plan.Changes | Where-Object { $_.NewContent }) {
        [IO.File]::WriteAllText((Join-Path $stage $c.File), $c.NewContent, $script:Utf8NoBom)
        $expected += "$($script:ManagedPrefix)$($c.Service)@file"
      }
    }
    foreach ($name in $ExtraFiles.Keys) {
      $target = Join-Path $stage $name
      if ($null -eq $ExtraFiles[$name]) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
      else { [IO.File]::WriteAllText($target, $ExtraFiles[$name], $script:Utf8NoBom) }
    }
    $run = Invoke-Docker run -d --name $name --network none --read-only -v "${stage}:/etc/traefik/dynamic:ro" $Settings.TraefikImage `
      --api=true --entryPoints.web.address=:80 --entryPoints.traefik.address=:8080 --api.insecure=true `
      --providers.file.directory=/etc/traefik/dynamic --log.level=INFO
    if ($run.ExitCode -ne 0) { $result.Errors = @('Could not start the validation container: ' + ($run.Output -join ' ')); return $result }

    $routers = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
      Start-Sleep -Milliseconds 700
      $r = Invoke-Docker exec $name wget -q -O- http://127.0.0.1:8080/api/http/routers
      if ($r.ExitCode -eq 0) {
        $routers = @(($r.Output -join '') | ConvertFrom-Json | ForEach-Object { $_ })
        $loaded = @($routers | ForEach-Object { $_.name })
        if (@($expected | Where-Object { $loaded -notcontains $_ }).Count -eq 0) { break }
      }
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $routers) { $result.Errors = @('Traefik did not start in the validation container: ' + ((Invoke-Docker logs $name).Output -join ' ')); return $result }

    $errors = @(); $warnings = @()
    $loaded = @($routers | ForEach-Object { $_.name })
    foreach ($e in $expected) { if ($loaded -notcontains $e) { $errors += "Router $e was not loaded (YAML rejected?)." } }
    foreach ($kind in @('routers', 'services', 'middlewares')) {
      $items = $routers
      if ($kind -ne 'routers') {
        $resp = Invoke-Docker exec $name wget -q -O- "http://127.0.0.1:8080/api/http/$kind"
        $items = @(($resp.Output -join '') | ConvertFrom-Json | ForEach-Object { $_ })
      }
      foreach ($item in $items) {
        if ($item.PSObject.Properties['error'] -and $item.error) {
          $msg = "$kind/$($item.name): " + (@($item.error) -join '; ')
          # Middlewares from the Docker provider do not exist in the isolated validator.
          if ($msg -match '@docker') { $warnings += $msg + ' (cannot be checked offline)' } else { $errors += $msg }
        }
      }
    }
    foreach ($line in (Invoke-Docker logs $name).Output) {
      if ($line -match '\bERR\b' -and $line -notmatch '@docker') { $errors += ($line -replace '^\S+\s+', '') }
    }
    $result.Errors = @($errors | Select-Object -Unique)
    $result.Warnings = $warnings
    $result.Routers = @($routers | Where-Object { $_.name -like "$($script:ManagedPrefix)*" -or $ExpectRouters -contains $_.name } | ForEach-Object { [pscustomobject]@{ Name = $_.name; Rule = $_.rule; Status = $_.status } })
    $result.Ok = ($result.Errors.Count -eq 0)
    return $result
  } finally {
    $null = Invoke-Docker rm -f $name
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- Live state ---------------------------------------------------------------------------------------------

function Get-TraefikApi {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Path)
  # PS 5.1 Invoke-RestMethod emits a JSON array as ONE object; ForEach-Object unrolls it.
  try { return @(Invoke-RestMethod -TimeoutSec 5 ("http://127.0.0.1:{0}{1}" -f $Settings.DashboardPort, $Path) | ForEach-Object { $_ }) } catch { return $null }
}

# Waits until Traefik reports the router of every enabled service (after an apply + reload).
function Wait-ServiceRouters {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Services, [int]$TimeoutSeconds = 20)
  $want = @($Services | Where-Object { $_.enabled } | ForEach-Object { "$($script:ManagedPrefix)$($_.name)@file" })
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $routers = Get-TraefikApi $Settings '/api/http/routers'
    if ($null -ne $routers) {
      $names = @($routers | ForEach-Object { $_.name })
      $missing = @($want | Where-Object { $names -notcontains $_ })
      if ($missing.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Missing = @(); Routers = $routers } }
    }
    Start-Sleep -Milliseconds 700
  } while ((Get-Date) -lt $deadline)
  if ($null -eq $routers) { $missing = $want }
  return [pscustomobject]@{ Ok = $false; Missing = $missing; Routers = $routers }
}

# --- Tunnel connector ----------------------------------------------------------------------------------------

# A tunnel token is base64(JSON {"a": account tag, "t": tunnel id, "s": secret}).
$script:TunnelTokenPattern = 'eyJ[A-Za-z0-9_\-=+/]{40,}'

function Get-TunnelTokenPattern { return $script:TunnelTokenPattern }

# Returns only the account tag and tunnel id of a token (never the secret), or $null if it is not a token.
function ConvertFrom-TunnelToken([string]$Token) {
  try {
    $b64 = $Token.Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    if ($json.PSObject.Properties['t'] -and $json.PSObject.Properties['s']) {
      return [pscustomobject]@{ AccountTag = [string]$json.a; TunnelId = [string]$json.t }
    }
  } catch { }
  return $null
}

# Returns the name of another container already running a connector for this tunnel, if any.
# Tokens of other containers are compared in memory only and never returned or printed.
function Find-ConnectorForTunnel {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$TunnelId)
  foreach ($line in (Invoke-Docker ps -a --format '{{.Names}}|{{.Image}}').Output) {
    $parts = $line.Split('|')
    if ($parts.Count -lt 2 -or $parts[1] -notmatch 'cloudflared' -or $parts[0] -eq $Settings.CloudflaredContainer) { continue }
    $config = (Invoke-Docker inspect $parts[0] --format '{{json .Config.Cmd}} {{json .Config.Env}}').Output -join ' '
    foreach ($match in [regex]::Matches($config, $script:TunnelTokenPattern)) {
      $decoded = ConvertFrom-TunnelToken $match.Value
      if ($decoded -and $decoded.TunnelId -eq $TunnelId) { return $parts[0] }
    }
  }
  return $null
}

# Readable by the current user, SYSTEM and Administrators only.
function Set-SecretFileAcl([string]$Path) {
  $null = & icacls $Path /inheritance:r /grant:r "${env:USERNAME}:(R,W)" '*S-1-5-18:(R)' '*S-1-5-32-544:(R)'
}

# Writes secrets\cloudflare_tunnel_token (the previous token, if any, is copied to backups\<timestamp>\secrets\).
# Returns the backup path or $null.
function Save-TunnelTokenFile {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Token)
  if (-not (ConvertFrom-TunnelToken $Token)) { throw 'That is not a valid tunnel token.' }
  $path = Join-Path $Settings.InstallPath 'secrets\cloudflare_tunnel_token'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  $saved = $null
  if (Test-Path -LiteralPath $path) {
    $saved = Join-Path $Settings.BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '\secrets\cloudflare_tunnel_token')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null
    Copy-Item -LiteralPath $path -Destination $saved -Force
    Set-SecretFileAcl $saved
  }
  [IO.File]::WriteAllText($path, $Token)
  Set-SecretFileAcl $path
  return $saved
}

function Test-TunnelTokenFile($Settings) {
  return (Test-Path -LiteralPath (Join-Path $Settings.InstallPath 'secrets\cloudflare_tunnel_token'))
}

# docker compose up for this instance only (Traefik + socket proxy, plus cloudflared with -WithTunnel).
function Start-ProxyStack {
  param([Parameter(Mandatory = $true)]$Settings, [switch]$WithTunnel)
  $profiles = @()
  if ($WithTunnel) {
    if (-not (Test-TunnelTokenFile $Settings)) { throw 'secrets\cloudflare_tunnel_token is missing; install the tunnel connector token first.' }
    $profiles = @('tunnel')
  }
  $up = Invoke-Docker @((Get-ComposeArgs -Settings $Settings -Profiles $profiles) + @('up', '-d', '--wait', '--wait-timeout', '120'))
  return [pscustomobject]@{ Ok = ($up.ExitCode -eq 0); Output = @(ConvertTo-RedactedText $up.Output) }
}

# Starts (or recreates, after a token change) this instance's cloudflared and waits for registered connections.
function Start-TunnelConnector {
  param([Parameter(Mandatory = $true)]$Settings, [switch]$Recreate, [int]$TimeoutSeconds = 60)
  if (-not (Test-TunnelTokenFile $Settings)) { throw 'secrets\cloudflare_tunnel_token is missing.' }
  $upArgs = (Get-ComposeArgs -Settings $Settings -Profiles @('tunnel')) + @('up', '-d', '--wait', '--wait-timeout', '120')
  if ($Recreate) { $upArgs += @('--force-recreate', 'cloudflared') }
  $cf = $Settings.CloudflaredContainer
  $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $up = Invoke-Docker @upArgs
  $result = [pscustomobject]@{ Ok = $false; Connections = 0; Locations = ''; Message = ''; Output = @(ConvertTo-RedactedText $up.Output) }
  if ($up.ExitCode -ne 0) {
    $logs = (Invoke-Docker logs --tail 30 $cf).Output -join "`n"
    if ($logs -match 'Unauthorized|invalid token|tunnel credentials') { $result.Message = 'cloudflared rejected the tunnel token. Fetch or paste it again.' }
    else { $result.Message = "Starting cloudflared failed. See: docker logs --tail 100 $cf" }
    return $result
  }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $logs = ''
  do {
    $logs = (Invoke-Docker logs --since $since $cf).Output -join "`n"
    $result.Connections = [regex]::Matches($logs, 'Registered tunnel connection').Count
    if ($result.Connections -ge 1) { break }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  if ($result.Connections -lt 1) { $result.Message = "cloudflared started but registered no tunnel connections within $TimeoutSeconds s. Check: docker logs $cf"; return $result }
  $result.Locations = ([regex]::Matches($logs, 'location=(\S+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ', '
  $result.Ok = $true
  $result.Message = "cloudflared connected: $($result.Connections) connection(s) to Cloudflare ($($result.Locations))."
  return $result
}

# --- Status, logs ---------------------------------------------------------------------------------------------

# Masks tunnel tokens, bearer tokens and anything labelled token/secret/password.
function ConvertTo-RedactedText([string[]]$Lines) {
  foreach ($line in $Lines) {
    $l = [string]$line -replace 'eyJ[A-Za-z0-9_\-=+/.]{20,}', 'eyJ...REDACTED'
    $l = $l -replace '(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}', '$1REDACTED'
    $l -replace '(?i)((token|secret|password|api[_-]?key)["'']?\s*[:=]\s*["'']?)[^\s"'',;]{8,}', '$1REDACTED'
  }
}

# Docker Desktop prerequisites: CLI, engine, Linux containers, Compose v2.
function Get-DockerStatus {
  $status = [ordered]@{ CliFound = $false; EngineRunning = $false; ServerVersion = ''; OsType = ''; ComposeVersion = ''; ComposeOk = $false; Context = ''; Problems = @() }
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $status.Problems = @('The docker command was not found. Install Docker Desktop (https://www.docker.com/products/docker-desktop/) and reopen this window.')
    return [pscustomobject]$status
  }
  $status.CliFound = $true
  $info = Invoke-Docker info --format '{{.ServerVersion}}|{{.OSType}}'
  $line = (@($info.Output) | Where-Object { $_ -match '\|' } | Select-Object -First 1)
  if ($info.ExitCode -eq 0 -and $line) {
    $parts = ([string]$line).Split('|')
    $status.EngineRunning = $true
    $status.ServerVersion = $parts[0]
    $status.OsType = $parts[1]
    if ($parts[1] -ne 'linux') { $status.Problems += 'Docker Desktop is in Windows-containers mode. Right-click the Docker tray icon and choose "Switch to Linux containers".' }
  } else {
    $status.Problems += 'The Docker engine is not reachable. Start Docker Desktop and wait until it reports "Engine running".'
  }
  $compose = Invoke-Docker compose version --short
  if ($compose.ExitCode -eq 0) {
    $status.ComposeVersion = ((@($compose.Output) -join '').Trim())
    $status.ComposeOk = $status.ComposeVersion -match '^v?2|^v?[3-9]'
    if (-not $status.ComposeOk) { $status.Problems += "Docker Compose v2 or later is required (found $($status.ComposeVersion)). Update Docker Desktop." }
  } else { $status.Problems += 'docker compose is not available. Update Docker Desktop.' }
  $status.Context = ((Invoke-Docker context show).Output -join '').Trim()
  return [pscustomobject]$status
}

function Get-StackContainerNames($Settings) {
  return [ordered]@{ traefik = $Settings.TraefikContainer; 'socket-proxy' = $Settings.SocketProxyContainer; cloudflared = $Settings.CloudflaredContainer }
}

# Read-only snapshot of this instance: containers, Traefik ping, tunnel token presence, loaded routers.
function Get-StackStatus {
  param([Parameter(Mandatory = $true)]$Settings, [switch]$SkipDocker)
  $containers = @()
  $names = Get-StackContainerNames $Settings
  foreach ($role in $names.Keys) {
    $c = [ordered]@{ Role = $role; Name = $names[$role]; Exists = $false; State = 'missing'; Health = ''; Image = ''; StartedAt = '' }
    if (-not $SkipDocker) {
      $r = Invoke-Docker inspect $names[$role] --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Config.Image}}|{{.State.StartedAt}}'
      if ($r.ExitCode -eq 0) {
        $p = ((@($r.Output) -join '').Trim()).Split('|')
        $c.Exists = $true; $c.State = $p[0]; $c.Health = $p[1]; $c.Image = $p[2]; $c.StartedAt = $p[3]
      }
    }
    $containers += [pscustomobject]$c
  }
  $version = $null
  $routers = $null
  # Only ask the dashboard port when this instance's own Traefik runs; otherwise another Traefik on the same
  # port (e.g. before the first install, with default settings) would be reported as this one.
  $traefikRunning = @($containers | Where-Object { $_.Role -eq 'traefik' -and $_.State -eq 'running' }).Count -gt 0
  if (-not $SkipDocker -and $traefikRunning) {
    $version = Get-TraefikApi $Settings '/api/version'
    if ($null -ne $version) { $routers = Get-TraefikApi $Settings '/api/http/routers' }
  }
  return [pscustomobject]@{
    Installed          = (Test-Path -LiteralPath (Join-Path $Settings.InstallPath 'compose.yaml'))
    Containers         = $containers
    TraefikApi         = ($null -ne $version)
    TraefikVersion     = $(if ($version) { [string]@($version)[0].Version } else { '' })
    Routers            = @(if ($null -ne $routers) { $routers | ForEach-Object { [pscustomobject]@{ Name = $_.name; Status = $_.status; Rule = $_.rule } } })
    TunnelTokenPresent = (Test-TunnelTokenFile $Settings)
  }
}

# Last lines of one of this instance's containers (redacted). $Role: traefik | socket-proxy | cloudflared.
function Get-StackLogs {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Role, [int]$Tail = 200)
  $names = Get-StackContainerNames $Settings
  if (-not $names.Contains($Role)) { throw "Unknown container role '$Role'." }
  $Tail = [Math]::Max(1, [Math]::Min(2000, $Tail))
  $r = Invoke-Docker logs --tail $Tail --timestamps $names[$Role]
  return [pscustomobject]@{ Container = $names[$Role]; Ok = ($r.ExitCode -eq 0); Lines = @(ConvertTo-RedactedText $r.Output) }
}

Export-ModuleMember -Function Invoke-Docker, New-Issue, Read-DotEnv, Get-FileSha256, Get-TextSha256, Get-ManagerVersion, New-ReviewItem, Get-ComposeImages, Write-TextFileAtomic,
  Get-ServiceProperty, ConvertTo-StableJson, ConvertTo-IPv4Range, Test-CidrOverlap,
  Get-TunnelTokenPattern, ConvertFrom-TunnelToken, Find-ConnectorForTunnel, Set-SecretFileAcl, Save-TunnelTokenFile, Test-TunnelTokenFile,
  Start-ProxyStack, Start-TunnelConnector, Get-PortUser, ConvertTo-RedactedText, Get-DockerStatus, Get-StackContainerNames, Get-StackStatus, Get-StackLogs,
  Test-PrivateIPv4, Test-IPv4Address, Get-StackSettings, ConvertTo-StackSettings, ConvertTo-InstanceValues, New-DotEnvContent,
  Test-DockerEngine, Get-StackConflicts, Get-SuggestedStackSettings, Test-StackSettings, Get-ComposeArgs, Test-ContainerRunning, Sync-TraefikDynamic, ConvertTo-ServiceDefinition,
  New-ServiceDefinition, Read-ServiceRegistry, ConvertTo-RegistryJson, Get-AvailableMiddlewares, Test-ServiceDefinition,
  Test-ServiceRegistry, Get-ServiceFileName, Get-ServiceUrl, Get-ServiceRule, ConvertTo-TraefikRouteYaml, Get-ServicePlan,
  Get-LineDiff, Format-ServicePlan, New-ServiceBackup, Get-ServiceBackups, Invoke-ServicePlan, Restore-ServiceBackup,
  Test-TraefikDynamicConfig, Get-TraefikApi, Wait-ServiceRouters
