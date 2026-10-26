#requires -version 5.1
# Host-platform adapters for the provisioning engine. The manifest, recipe format, dependency analysis, Compose
# generation, Traefik model and identity contract are platform-independent; what differs per host (paths, secret
# storage, GPU and device access, host networking, the Docker socket, the host-gateway name, how the manager starts and
# how it is reached) lives here as a declarative description.
#
# Only 'windows-docker-desktop' is implemented and tested. The other adapters describe the design so the core can be
# reused; they are marked status 'planned' and tested = $false, and the manager never claims support for them.
Set-StrictMode -Version 2.0

$script:Adapters = [ordered]@{
  'windows-docker-desktop' = [ordered]@{
    id = 'windows-docker-desktop'; name = 'Windows 11 with Docker Desktop (WSL2)'; status = 'implemented'; tested = $true
    architectures = @('linux/amd64'); hostGateway = 'host.docker.internal'; dockerSocket = '/var/run/docker.sock'
    appdataRoot = '%USERPROFILE%\.docker\projects'; secretStore = 'DPAPI (current Windows user)'; filePermissions = 'NTFS ACL (user, SYSTEM, Administrators)'
    gpu = 'nvidia-experimental'; devices = 'none'; hostNetwork = 'limited'; udpPorts = 'published only for the web port'; firewall = 'not managed (loopback-only ports)'
    startup = 'START-HERE.cmd launcher (per user)'; managementAccess = 'browser on this PC (http://127.0.0.1)'
    notes = @('GPU access needs NVIDIA drivers with WSL2 support and is experimental.', 'Host devices (/dev/...) of the PC are not available inside Docker Desktop containers.', 'Host networking is limited on Docker Desktop: ports are not bound on the Windows host the way they are on Linux.')
  }
  'debian-docker' = [ordered]@{
    id = 'debian-docker'; name = 'Debian-based Linux with Docker Engine'; status = 'planned'; tested = $false
    architectures = @('linux/amd64', 'linux/arm64'); hostGateway = 'host-gateway (extra_hosts)'; dockerSocket = '/var/run/docker.sock'
    appdataRoot = '/opt/appdata'; secretStore = 'root-owned files, mode 0600 (planned)'; filePermissions = 'POSIX owner and mode'
    gpu = 'nvidia-container-toolkit'; devices = 'available'; hostNetwork = 'available'; udpPorts = 'available'; firewall = 'nftables/ufw (planned, never opened automatically)'
    startup = 'systemd unit (planned)'; managementAccess = 'headless: SSH bootstrap, then Cloudflare Tunnel with Access (planned)'
    notes = @('Not tested; not offered by this version.')
  }
  'arch-docker' = [ordered]@{
    id = 'arch-docker'; name = 'Arch-based Linux with Docker Engine'; status = 'planned'; tested = $false
    architectures = @('linux/amd64'); hostGateway = 'host-gateway (extra_hosts)'; dockerSocket = '/var/run/docker.sock'
    appdataRoot = '/opt/appdata'; secretStore = 'root-owned files, mode 0600 (planned)'; filePermissions = 'POSIX owner and mode'
    gpu = 'nvidia-container-toolkit'; devices = 'available'; hostNetwork = 'available'; udpPorts = 'available'; firewall = 'nftables (planned)'
    startup = 'systemd unit (planned)'; managementAccess = 'headless: SSH bootstrap, then Cloudflare Tunnel with Access (planned)'
    notes = @('Not tested; not offered by this version.')
  }
  'unraid' = [ordered]@{
    id = 'unraid'; name = 'Unraid'; status = 'planned'; tested = $false
    architectures = @('linux/amd64'); hostGateway = 'host-gateway (extra_hosts)'; dockerSocket = '/var/run/docker.sock'
    appdataRoot = '/mnt/user/appdata'; secretStore = 'files on the flash/appdata share (planned)'; filePermissions = 'nobody:users (99:100)'
    gpu = 'nvidia plugin'; devices = 'available'; hostNetwork = 'available'; udpPorts = 'available'; firewall = 'not managed'
    startup = 'User Scripts or a container (planned)'; managementAccess = 'LAN browser, then Cloudflare Tunnel (planned)'
    notes = @('Older Unraid releases ship older Docker Engine and Compose versions; recipes record them.', 'Not tested; not offered by this version.')
  }
  'macos-docker-desktop' = [ordered]@{
    id = 'macos-docker-desktop'; name = 'macOS with Docker Desktop'; status = 'planned'; tested = $false
    architectures = @('linux/arm64', 'linux/amd64'); hostGateway = 'host.docker.internal'; dockerSocket = '/var/run/docker.sock'
    appdataRoot = '~/.docker/projects'; secretStore = 'Keychain (planned)'; filePermissions = 'POSIX owner and mode'
    gpu = 'none'; devices = 'none'; hostNetwork = 'limited'; udpPorts = 'published only for the web port'; firewall = 'not managed'
    startup = 'launchd agent (planned)'; managementAccess = 'browser on this Mac'
    notes = @('Apple silicon runs linux/amd64 images under emulation (slow).', 'Not tested; not offered by this version.')
  }
  'vps-headless' = [ordered]@{
    id = 'vps-headless'; name = 'Headless Linux VPS'; status = 'planned'; tested = $false
    architectures = @('linux/amd64', 'linux/arm64'); hostGateway = 'host-gateway (extra_hosts)'; dockerSocket = '/var/run/docker.sock'
    appdataRoot = '/opt/appdata'; secretStore = 'root-owned files, mode 0600 (planned)'; filePermissions = 'POSIX owner and mode'
    gpu = 'none'; devices = 'available'; hostNetwork = 'available'; udpPorts = 'available'; firewall = 'required: nothing but SSH open; never expose the manager on the public IP'
    startup = 'systemd unit (planned)'
    managementAccess = 'Bound to 127.0.0.1 on the server; first access through an SSH tunnel with a one-time bootstrap token, then an approved Cloudflare Tunnel hostname protected by Cloudflare Access or authentik (planned). Never an unauthenticated public port.'
    notes = @('"localhost" on a VPS is the server itself, not your browser: the manager must not assume a local browser.', 'Not tested; not offered by this version.')
  }
}

function Get-HostAdapters { return @($script:Adapters.Values) }
function Get-HostAdapter([string]$Id) { if ($script:Adapters.Contains($Id)) { return $script:Adapters[$Id] }; return $null }

# The adapter of the machine the manager runs on. Only Windows is implemented; anything else is reported, not guessed.
function Get-CurrentHostAdapter {
  if ($env:OS -eq 'Windows_NT') {
    $a = [ordered]@{}; foreach ($k in $script:Adapters['windows-docker-desktop'].Keys) { $a[$k] = $script:Adapters['windows-docker-desktop'][$k] }
    $arch = [string]$env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'ARM64') { $a.architectures = @('linux/arm64'); $a.notes = @($a.notes) + 'Windows on ARM: linux/amd64 images run under emulation if at all.' }
    return $a
  }
  return [ordered]@{ id = 'unknown'; name = 'This host'; status = 'unsupported'; tested = $false; architectures = @(); gpu = 'none'; devices = 'none'; hostNetwork = 'limited'; udpPorts = 'unknown'; notes = @('Only Windows 11 with Docker Desktop is supported in this version.') }
}

# Facts about this host for recipes and compatibility, without anything identifying: no host name, user name, paths
# or addresses. $DockerVersionJson (tests) replaces `docker version --format json`.
function Get-HostFingerprint {
  param($DockerVersionJson = $null)
  $os = 'unknown'; $osVersion = ''
  try { $ci = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $os = 'windows'; $osVersion = [string]$ci.Version } catch { if ($env:OS -eq 'Windows_NT') { $os = 'windows' } }
  $dv = $DockerVersionJson
  if (-not $dv) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $raw = & docker version --format '{{json .}}' 2>$null; if ($LASTEXITCODE -eq 0) { $dv = ($raw -join '') | ConvertFrom-Json } } catch { } finally { $ErrorActionPreference = $prev }
  }
  $server = $(if ($dv -and $dv.PSObject.Properties['Server']) { $dv.Server } else { $null })
  $compose = ''
  try { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $c = & docker compose version --short 2>$null; if ($LASTEXITCODE -eq 0) { $compose = ([string]($c | Select-Object -First 1)).Trim() } } catch { } finally { $ErrorActionPreference = $prev }
  $adapter = Get-CurrentHostAdapter
  return [ordered]@{
    platform = $adapter.id; os = $os; osVersion = $osVersion
    architecture = $(if ($server -and $server.PSObject.Properties['Arch']) { "linux/$($server.Arch)" } else { @($adapter.architectures)[0] })
    kernel = $(if ($server -and $server.PSObject.Properties['KernelVersion']) { [string]$server.KernelVersion } else { '' })
    dockerEngine = $(if ($server -and $server.PSObject.Properties['Version']) { [string]$server.Version } else { '' })
    dockerCompose = $compose
    runtime = $(if ($server -and $server.PSObject.Properties['Platform'] -and [string]$server.Platform.Name -match 'Desktop') { 'docker-desktop' } elseif ($server) { 'docker-engine' } else { 'unknown' })
  }
}

Export-ModuleMember -Function Get-HostAdapters, Get-HostAdapter, Get-CurrentHostAdapter, Get-HostFingerprint
