#requires -version 5.1
# Finding and inspecting existing deployments ("attach"), read-only.
#
# - Candidates come from a limited set of places: the remembered (recent) folders, the folder the manager runs from,
#   the immediate subfolders of the user's Docker projects folder, and the working folders of Compose projects whose
#   containers include both a `traefik` and a `socket-proxy` service. Nothing is scanned recursively.
# - An inspection reads files, Docker metadata and (on request) Cloudflare with GET requests only. It never writes to the
#   deployment folder, never changes Docker and never returns a secret: for secrets only "present" and "readable" are
#   reported (and the tunnel id inside a connector token, which is not secret).
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'TraefikProxy.psm1')
Import-Module (Join-Path $PSScriptRoot 'CloudflareApi.psm1')
Import-Module (Join-Path $PSScriptRoot 'Dashboard.psm1')

$script:ConfigFiles = [ordered]@{
  '.env' = 'Instance settings'; 'compose.yaml' = 'Compose project definition'; '.install-manifest.json' = 'Installed files and their checksums'
  'config\setup.json' = 'Setup choices'; 'config\cloudflare.json' = 'Cloudflare account, tunnel, domains and created resources'
  'config\dashboard.json' = 'Public Traefik dashboard'; 'config\services.json' = 'Service registry'; 'tunnel.json' = 'Console wizard state (earlier versions)'
}

# --- Paths ------------------------------------------------------------------------------------------------------------

# A local, absolute folder path, normalized; throws a readable message otherwise. Network (UNC) and device paths are
# refused: opening them could send Windows credentials to another computer.
function ConvertTo-ProjectPath([string]$Path) {
  $p = ([string]$Path).Trim().Trim('"')
  if (-not $p) { throw 'Enter a folder path.' }
  if ($p -match '^(\\\\|//)') { throw 'Network and device paths (\\server\share, \\?\...) are not supported. Choose a folder on this PC.' }
  if ($p -notmatch '^[A-Za-z]:[\\/]') { throw 'Enter a full path that starts with a drive letter, for example C:\Users\you\.docker\projects\traefik-proxy.' }
  if ($p -match '[<>"|?*]' -or $p.Length -gt 240) { throw 'That folder path contains characters Windows does not allow, or is too long.' }
  try { $full = [IO.Path]::GetFullPath($p).TrimEnd('\') } catch { throw 'That is not a valid folder path.' }
  if ($full -match '^[A-Za-z]:$') { throw 'Choose a folder, not the root of a drive.' }
  if ($env:windir -and ($full + '\').StartsWith($env:windir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Choose a folder outside the Windows directory.' }
  return $full
}

function Test-SamePath([string]$A, [string]$B) { return [string]::Equals(([string]$A).TrimEnd('\'), ([string]$B).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }

# --- Kind ----------------------------------------------------------------------------------------------------------------

# manager: a deployment of this tool (compose.yaml uses STACK_NAME; installed). draft: settings saved by the setup wizard,
# not installed yet. package: the manager's own files without a deployment (a downloaded copy). legacy: the earlier single-app layout (fixed container names, traefik\traefik.yml). other: not a
# deployment. missing: the folder does not exist.
function Get-ProjectKind([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 'missing' }
  $compose = Join-Path $Path 'compose.yaml'
  if (Test-Path -LiteralPath $compose) {
    $text = [IO.File]::ReadAllText($compose)
    # The manager's own package folder also has compose.yaml; a deployment additionally has .env or an install manifest.
    if ($text -match '\$\{STACK_NAME' -and $text -match 'socket-proxy') {
      if ((Test-Path -LiteralPath (Join-Path $Path '.env')) -or (Test-Path -LiteralPath (Join-Path $Path '.install-manifest.json'))) { return 'manager' }
      if (Test-Path -LiteralPath (Join-Path $Path 'config\setup.json')) { return 'draft' }
      return 'package'
    }
    if ($text -match '(?m)^\s*container_name:\s*traefik\s*$' -or (Test-Path -LiteralPath (Join-Path $Path 'traefik\traefik.yml'))) { return 'legacy' }
    return 'other'
  }
  if (Test-Path -LiteralPath (Join-Path $Path 'config\setup.json')) { return 'draft' }
  return 'other'
}

# Settings of a folder: .env, else the setup draft, else built-in defaults (read-only).
function Get-ProjectSettings([string]$Path) {
  if (Test-Path -LiteralPath (Join-Path $Path '.env')) { return Get-StackSettings -InstallPath $Path }
  $values = @{}
  $draft = Join-Path $Path 'config\setup.json'
  if (Test-Path -LiteralPath $draft) {
    try { $j = [IO.File]::ReadAllText($draft) | ConvertFrom-Json; if ($j.PSObject.Properties['settings'] -and $j.settings) { foreach ($p in $j.settings.PSObject.Properties) { $values[$p.Name] = [string]$p.Value } } } catch { }
  }
  return ConvertTo-StackSettings -InstallPath $Path -Values $values
}

function Read-JsonFile([string]$Path) {
  try { return [pscustomobject]@{ Ok = $true; Value = ([IO.File]::ReadAllText($Path) | ConvertFrom-Json); Error = '' } } catch { return [pscustomobject]@{ Ok = $false; Value = $null; Error = $_.Exception.Message } }
}

# --- Upgrade status --------------------------------------------------------------------------------------------------------

# Files the installer manages, from install.ps1 of the manager source ($ManagedFiles block).
function Get-ManagedFileList([string]$SourceRoot) {
  $text = [IO.File]::ReadAllText((Join-Path $SourceRoot 'install.ps1'))
  $m = [regex]::Match($text, '\$ManagedFiles = @\(([\s\S]*?)\n\)')
  if (-not $m.Success) { return @() }
  return @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}

function Get-VersionFromModule([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $m = [regex]::Match([IO.File]::ReadAllText($Path), "\`$script:ManagerVersion = '([^']+)'")
  if ($m.Success) { return $m.Groups[1].Value }
  return 'earlier than 1.1.0'
}

# Compares the installed copies of the managed files with the manager source. state: current | available | unknown.
function Get-UpgradeStatus {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$SourceRoot)
  $out = [ordered]@{ state = 'unknown'; installedVersion = ''; sourceVersion = (Get-ManagerVersion); changed = @(); added = @(); modified = @(); composeChanged = $false; sameFolder = (Test-SamePath $Path $SourceRoot) }
  if (-not (Test-Path -LiteralPath (Join-Path $Path 'compose.yaml'))) { return [pscustomobject]$out }
  $out.installedVersion = Get-VersionFromModule (Join-Path $Path 'lib\TraefikProxy.psm1')
  if ($out.sameFolder) { $out.state = 'current'; return [pscustomobject]$out }
  $manifest = @{}
  $mf = Join-Path $Path '.install-manifest.json'
  if (Test-Path -LiteralPath $mf) { $r = Read-JsonFile $mf; if ($r.Ok) { foreach ($p in $r.Value.PSObject.Properties) { $manifest[$p.Name] = [string]$p.Value } } }
  foreach ($rel in (Get-ManagedFileList $SourceRoot)) {
    $src = Join-Path $SourceRoot $rel; $dst = Join-Path $Path $rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if (-not (Test-Path -LiteralPath $dst)) { $out.added += $rel; continue }
    $srcHash = Get-FileSha256 $src; $dstHash = Get-FileSha256 $dst
    if ($srcHash -eq $dstHash) { continue }
    if ($manifest.ContainsKey($rel) -and $manifest[$rel] -ne $dstHash) { $out.modified += $rel } else { $out.changed += $rel }
    if ($rel -eq 'compose.yaml') { $out.composeChanged = $true }
  }
  $out.state = if ($out.changed.Count + $out.added.Count -gt 0) { 'available' } else { 'current' }
  return [pscustomobject]$out
}

# --- Candidates ------------------------------------------------------------------------------------------------------------

# Folders worth showing: remembered ones, the manager's own folder if it is a deployment, subfolders (one level) of the
# Docker projects folder, and Compose working folders of traefik + socket-proxy projects. Returns path + where it was found.
function Find-ProjectCandidates {
  param([string[]]$Remembered = @(), [string]$SourceRoot, [string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.docker\projects'), [switch]$NoDocker)
  $found = [ordered]@{}
  $add = { param($P, $Source) if (-not $P) { return }; try { $k = [IO.Path]::GetFullPath($P).TrimEnd('\') } catch { return }
    $key = $k.ToLowerInvariant(); if (-not $found.Contains($key)) { $found[$key] = [pscustomobject][ordered]@{ path = $k; sources = @($Source) } } elseif (@($found[$key].sources) -notcontains $Source) { $found[$key].sources += $Source } }
  foreach ($r in $Remembered) { & $add $r 'recent' }
  if ($SourceRoot -and (Get-ProjectKind $SourceRoot) -eq 'manager') { & $add $SourceRoot 'manager folder' }
  if ($ProjectsRoot -and (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) {
    foreach ($d in @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 200)) {
      if ((Get-ProjectKind $d.FullName) -in @('manager', 'draft', 'legacy')) { & $add $d.FullName 'projects folder' }
    }
  }
  if (-not $NoDocker -and (Test-DockerEngine)) {
    $byProject = @{}
    foreach ($name in @((Invoke-Docker ps -a --format '{{.Names}}').Output | Where-Object { $_ })) {
      $r = Invoke-Docker inspect $name --format '{{json .Config.Labels}}'
      if ($r.ExitCode -ne 0) { continue }
      try { $l = (@($r.Output)[-1]) | ConvertFrom-Json } catch { continue }
      if (-not $l -or -not $l.PSObject.Properties['com.docker.compose.project.working_dir']) { continue }
      $dir = [string]$l.'com.docker.compose.project.working_dir'
      $svc = if ($l.PSObject.Properties['com.docker.compose.service']) { [string]$l.'com.docker.compose.service' } else { '' }
      if (-not $byProject.ContainsKey($dir)) { $byProject[$dir] = @() }
      $byProject[$dir] += $svc
    }
    foreach ($dir in $byProject.Keys) {
      if (@($byProject[$dir]) -contains 'traefik' -and @($byProject[$dir]) -contains 'socket-proxy' -and $dir -match '^[A-Za-z]:\\') { & $add $dir 'docker' }
    }
  }
  return @($found.Values)
}

# --- Summary and inspection ---------------------------------------------------------------------------------------------------

function New-CheckItem([string]$Section, [string]$Id, [string]$Label, [string]$Status, [string]$Message, $Detail = $null) {
  # Status: detected | verified | missing | reconnect | upgrade | warning | failed | info
  return [pscustomobject][ordered]@{ section = $Section; id = $Id; label = $Label; status = $Status; message = $Message; detail = $Detail }
}

# Docker facts of one container (labels, state, ports), $null when it does not exist.
function Get-ContainerFacts([string]$Name) {
  $r = Invoke-Docker inspect $Name --format '{{json .}}'
  if ($r.ExitCode -ne 0) { return $null }
  try { $j = ($r.Output -join '') | ConvertFrom-Json } catch { return $null }
  if ($j -is [array]) { $j = $j[0] }
  $labels = $j.Config.Labels
  $get = { param($k) if ($labels -and $labels.PSObject.Properties[$k]) { [string]$labels.$k } else { '' } }
  $ports = @()
  if ($j.HostConfig.PortBindings) { foreach ($p in $j.HostConfig.PortBindings.PSObject.Properties) { foreach ($b in @($p.Value)) { $ports += "$($b.HostIp):$($b.HostPort)->$($p.Name)" } } }
  return [pscustomobject][ordered]@{
    id = ([string]$j.Id).Substring(0, 12); state = [string]$j.State.Status
    health = $(if ($j.State.PSObject.Properties['Health'] -and $j.State.Health) { [string]$j.State.Health.Status } else { '' })
    image = [string]$j.Config.Image; project = (& $get 'com.docker.compose.project'); workingDir = (& $get 'com.docker.compose.project.working_dir'); ports = $ports
  }
}

# Quick facts for the project list (no network calls).
function Get-ProjectSummary {
  param([Parameter(Mandatory = $true)][string]$Path, [string]$SourceRoot, [switch]$NoDocker)
  $kind = Get-ProjectKind $Path
  $s = [ordered]@{ path = $Path; kind = $kind; exists = ($kind -ne 'missing'); stackName = ''; installed = $false; mode = ''; tunnelName = ''; domains = @(); dashboardUrl = ''
    services = 0; containers = ''; running = $false; tokenStored = $false; tokenReadable = $false; upgrade = ''; installedVersion = ''; usable = $false; note = '' }
  if ($kind -in @('missing', 'other', 'package')) { $s.note = $(if ($kind -eq 'missing') { 'The folder no longer exists (moved or deleted).' } elseif ($kind -eq 'package') { 'This is a copy of the manager itself, not a deployment. Choose the install folder (for example %USERPROFILE%\.docker\projects\traefik-proxy).' } else { 'Not a deployment of this tool.' }); return [pscustomobject]$s }
  if ($kind -eq 'legacy') {
    $s.note = 'Earlier single-app layout (fixed container names). It is shown for information only and is never changed; see "Migrating from the earlier single-app layout" in the README.'
    $s.stackName = $(if (Test-Path -LiteralPath (Join-Path $Path 'compose.yaml')) { $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $Path 'compose.yaml')), '(?m)^name:\s*(\S+)'); if ($m.Success) { $m.Groups[1].Value } else { '' } } else { '' })
    if (-not $NoDocker -and (Test-DockerEngine)) { $t = Get-ContainerFacts 'traefik'; if ($t -and (Test-SamePath $t.workingDir $Path)) { $s.containers = "traefik: $($t.state)"; $s.running = $t.state -eq 'running' } }
    return [pscustomobject]$s
  }
  try { $settings = Get-ProjectSettings $Path } catch { $s.note = "Settings cannot be read: $($_.Exception.Message)"; return [pscustomobject]$s }
  $s.stackName = $settings.StackName
  $s.installed = $kind -eq 'manager'
  $s.usable = $true
  $cf = $null; try { $cf = Read-CloudflareConfig -Settings $settings } catch { }
  if ($cf) { $s.tunnelName = $cf.tunnelName; $s.domains = @($cf.domains | ForEach-Object { $_.name }) }
  $setup = Join-Path $Path 'config\setup.json'
  if (Test-Path -LiteralPath $setup) { $r = Read-JsonFile $setup; if ($r.Ok -and $r.Value.PSObject.Properties['deployment'] -and $r.Value.deployment) { $s.mode = [string]$r.Value.deployment.mode } }
  if (-not $s.mode -and $s.installed) { $s.mode = $(if (Test-TunnelTokenFile $settings) { 'tunnel' } else { 'local' }) }
  $dash = Read-DashboardConfig -Settings $settings
  if ($dash.enabled -and $dash.hostname) { $s.dashboardUrl = "https://$($dash.hostname)/dashboard/" }
  try { $s.services = @((Read-ServiceRegistry -Settings $settings).services).Count } catch { }
  $tok = Get-CloudflareApiTokenInfo -Settings $settings
  $s.tokenStored = [bool]$tok.Stored; $s.tokenReadable = [bool]$tok.Readable
  if ($s.installed -and $SourceRoot) { $u = Get-UpgradeStatus -Path $Path -SourceRoot $SourceRoot; $s.upgrade = $u.state; $s.installedVersion = $u.installedVersion }
  if (-not $NoDocker -and $s.installed -and (Test-DockerEngine)) {
    $roles = @($settings.TraefikContainer, $settings.SocketProxyContainer); if ($s.mode -eq 'tunnel') { $roles += $settings.CloudflaredContainer }
    $n = 0; foreach ($c in $roles) { $f = Get-ContainerFacts $c; if ($f -and $f.state -eq 'running' -and (Test-SamePath $f.workingDir $Path)) { $n++ } }
    $s.containers = "$n of $($roles.Count) running"; $s.running = $n -eq $roles.Count
  }
  return [pscustomobject]$s
}

# Everything the attach review shows. Read-only; -Cloudflare adds read-only API checks of the saved ids.
function Get-ProjectInspection {
  param([Parameter(Mandatory = $true)][string]$Path, [string]$SourceRoot, [switch]$Cloudflare, [switch]$NoDocker)
  $items = New-Object System.Collections.ArrayList
  $add = { param($Section, $Id, $Label, $Status, $Message, $Detail) $null = $items.Add((New-CheckItem $Section $Id $Label $Status $Message $Detail)) }
  $summary = Get-ProjectSummary -Path $Path -SourceRoot $SourceRoot -NoDocker:$NoDocker
  $result = [ordered]@{ path = $Path; summary = $summary; items = $null; usable = $summary.usable; blockers = @(); upgrade = $null; cloudflareChecked = $false; legacy = ($summary.kind -eq 'legacy') }
  if (-not $summary.usable) {
    $result.blockers = @($summary.note)
    if ($summary.kind -eq 'legacy') { & $add 'identity' 'kind' 'Layout' 'warning' $summary.note $null }
    $result.items = $items.ToArray(); return [pscustomobject]$result
  }
  $settings = Get-ProjectSettings $Path
  $docker = -not $NoDocker -and (Test-DockerEngine)

  # Identity and version.
  & $add 'identity' 'folder' 'Folder' 'detected' $Path $null
  & $add 'identity' 'instance' 'Instance name' 'detected' $settings.StackName "Compose project $($settings.StackName); containers $($settings.TraefikContainer), $($settings.SocketProxyContainer), $($settings.CloudflaredContainer)"
  & $add 'identity' 'state' 'Installation' $(if ($summary.installed) { 'detected' } else { 'info' }) $(if ($summary.installed) { "Installed ($($summary.mode) mode)." } else { 'Settings saved by the setup wizard; not installed yet. Opening it continues the setup journey.' }) $null
  if ($summary.installed -and $SourceRoot) {
    $u = Get-UpgradeStatus -Path $Path -SourceRoot $SourceRoot
    $result.upgrade = $u
    $msg = if ($u.state -eq 'available') { "Installed files are from manager $($u.installedVersion); this manager is $($u.sourceVersion). $($u.changed.Count + $u.added.Count) file(s) would be updated. Opening the deployment does not require an upgrade." }
           elseif ($u.state -eq 'current') { "The installed files match this manager ($($u.sourceVersion))." } else { 'The installed version cannot be determined.' }
    & $add 'identity' 'version' 'Application files' $(if ($u.state -eq 'available') { 'upgrade' } elseif ($u.state -eq 'current') { 'verified' } else { 'info' }) $msg ([ordered]@{ changed = $u.changed; added = $u.added; locallyModified = $u.modified; composeChanged = $u.composeChanged })
    if ($u.modified.Count) { & $add 'identity' 'modified' 'Locally edited files' 'warning' "$($u.modified -join ', ') were edited by hand; an upgrade keeps them and writes the new version next to them as .dist." $null }
  }

  # Saved configuration files.
  foreach ($rel in $script:ConfigFiles.Keys) {
    $full = Join-Path $Path $rel
    $exists = Test-Path -LiteralPath $full
    $optional = $rel -in @('config\dashboard.json', 'tunnel.json', 'config\setup.json', 'config\services.json', '.install-manifest.json') -or (-not $summary.installed -and $rel -in @('.env', 'compose.yaml'))
    if (-not $exists) {
      if ($rel -eq 'tunnel.json') { continue }
      & $add 'files' $rel $rel $(if ($optional) { 'info' } else { 'missing' }) "$($script:ConfigFiles[$rel]): not present$(if ($optional) { ' (optional)' })." $null
      continue
    }
    if ($rel.EndsWith('.json')) {
      $r = Read-JsonFile $full
      & $add 'files' $rel $rel $(if ($r.Ok) { 'detected' } else { 'failed' }) $(if ($r.Ok) { $script:ConfigFiles[$rel] + $(if ($rel -eq 'tunnel.json') { ' - recognized; its tunnel id is used when config\cloudflare.json has none.' } else { '' }) } else { "Not valid JSON: $($r.Error)" }) $null
    } else { & $add 'files' $rel $rel 'detected' $script:ConfigFiles[$rel] $null }
  }
  $settingErrors = @(Test-StackSettings $settings)
  if ($settingErrors.Count) { & $add 'files' 'settings' 'Instance settings' 'failed' ($settingErrors -join ' ') $null }

  # Docker resources.
  $mode = $summary.mode
  $traefikOk = $false
  if (-not $docker) { & $add 'docker' 'engine' 'Docker Desktop' 'warning' 'Docker is not running, so containers and networks could not be checked. You can still open the deployment.' $null }
  else {
    $roles = [ordered]@{ traefik = $settings.TraefikContainer; 'socket-proxy' = $settings.SocketProxyContainer; cloudflared = $settings.CloudflaredContainer }
    foreach ($role in $roles.Keys) {
      $name = $roles[$role]
      $f = Get-ContainerFacts $name
      $needed = $role -ne 'cloudflared' -or $mode -eq 'tunnel'
      if (-not $f) { if ($summary.installed -and $needed) { & $add 'docker' $role "Container $name" 'missing' 'Not found. Start the instance (Overview) or re-run the installer.' $null }; continue }
      $mine = (Test-SamePath $f.workingDir $Path) -and $f.project -eq $settings.StackName
      $detail = [ordered]@{ id = $f.id; image = $f.image; project = $f.project; workingDir = $f.workingDir; ports = $f.ports }
      if (-not $mine) { & $add 'docker' $role "Container $name" 'warning' "Exists, but belongs to $(if ($f.project) { "project '$($f.project)' in $($f.workingDir)" } else { 'another program' }). It is not managed from this folder." $detail; continue }
      $healthy = $f.state -eq 'running' -and ($f.health -in @('', 'healthy'))
      & $add 'docker' $role "Container $name" $(if ($healthy) { 'verified' } elseif ($f.state -eq 'running') { 'warning' } else { 'warning' }) "$($f.state)$(if ($f.health) { " ($($f.health))" })$(if ($f.ports.Count) { "; $($f.ports -join ', ')" })" $detail
      if ($role -eq 'traefik' -and $f.state -eq 'running') { $traefikOk = $true }
    }
    $net = Invoke-Docker network inspect $settings.ProxyNetwork --format '{{len .Containers}}'
    & $add 'docker' 'proxy-network' "Shared network $($settings.ProxyNetwork)" $(if ($net.ExitCode -eq 0) { 'verified' } elseif ($summary.installed) { 'missing' } else { 'info' }) $(if ($net.ExitCode -eq 0) { "Exists ($((@($net.Output))[-1]) container(s) attached)." } else { 'Not found.' }) $null
    $tn = Invoke-Docker network inspect $settings.TunnelNetwork --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
    if ($tn.ExitCode -eq 0) { $sub = ((@($tn.Output))[-1]).Trim(); & $add 'docker' 'tunnel-network' "Tunnel network $($settings.TunnelNetwork)" $(if ($sub -eq $settings.TunnelSubnet) { 'verified' } else { 'warning' }) "Subnet $sub$(if ($sub -ne $settings.TunnelSubnet) { " (.env says $($settings.TunnelSubnet))" })" $null }
    if (-not $traefikOk) {
      foreach ($p in @($settings.HttpPort, $settings.DashboardPort)) { $user = Get-PortUser $p; if ($user) { & $add 'docker' "port-$p" "Port $p" 'warning' "In use by $user while this instance's Traefik is not running." $null } }
    }
  }

  # Routes and services.
  $routers = $null
  if ($traefikOk) { $routers = Get-TraefikApi $settings '/api/http/routers' }
  $services = @()
  try { $services = @((Read-ServiceRegistry -Settings $settings).services) } catch { & $add 'services' 'registry' 'Service registry' 'failed' $_.Exception.Message $null }
  $routerNames = @(); if ($null -ne $routers) { $routerNames = @($routers | ForEach-Object { $_.name }) }
  foreach ($s in $services) {
    $file = Join-Path $settings.DynamicDir (Get-ServiceFileName $s.name)
    $label = if ($s.PSObject.Properties['displayName'] -and $s.displayName) { "$($s.displayName) ($($s.name))" } else { $s.name }
    $st = if (-not $s.enabled) { 'info' } elseif ($routerNames -contains "svc-$($s.name)@file") { 'verified' } elseif (Test-Path -LiteralPath $file) { 'detected' } else { 'missing' }
    $msg = "$(@($s.hostnames) -join ', ') -> $(Get-ServiceUrl $s)$(if (-not $s.enabled) { ' (disabled)' } elseif ($st -eq 'verified') { '; routed by Traefik' } elseif ($st -eq 'missing') { '; route file missing' })"
    & $add 'services' $s.name $label $st $msg ([ordered]@{ rule = (Get-ServiceRule $s); exposure = $(if (-not $s.cloudflare.publish) { 'local' } elseif ($s.cloudflare.access) { 'access' } else { 'public' }) })
  }
  if (-not $services.Count -and $summary.installed) { & $add 'services' 'none' 'Services' 'info' 'No services defined yet.' $null }
  if ($null -ne $routers) {
    $dashLoaded = $routerNames -contains 'dashboard@file'
    & $add 'services' 'local-dashboard' 'Local dashboard router' $(if ($dashLoaded) { 'verified' } else { 'warning' }) "http://127.0.0.1:$($settings.DashboardPort)/dashboard/" $null
  }

  # Cloudflare.
  $cf = Read-CloudflareConfig -Settings $settings
  $tok = Get-CloudflareApiTokenInfo -Settings $settings
  $legacyTunnel = ''
  $tj = Join-Path $Path 'tunnel.json'
  if (Test-Path -LiteralPath $tj) { $r = Read-JsonFile $tj; if ($r.Ok -and $r.Value.PSObject.Properties['tunnelId']) { $legacyTunnel = [string]$r.Value.tunnelId } }
  $tunnelId = if ($cf.tunnelId) { $cf.tunnelId } else { $legacyTunnel }
  if ($cf.accountId) { & $add 'cloudflare' 'account' 'Cloudflare account' 'detected' "$($cf.accountName)" ([ordered]@{ accountId = $cf.accountId }) }
  elseif ($mode -eq 'tunnel') { & $add 'cloudflare' 'account' 'Cloudflare account' 'info' 'No account recorded (the tunnel was probably set up by hand or with the console wizard).' $null }
  if ($tunnelId) { & $add 'cloudflare' 'tunnel' 'Tunnel' 'detected' "$(if ($cf.tunnelName) { $cf.tunnelName } else { 'from tunnel.json' })" ([ordered]@{ tunnelId = $tunnelId }) }
  foreach ($d in $cf.domains) { & $add 'cloudflare' "zone-$($d.id)" "Domain $($d.name)" 'detected' 'Allowed domain' ([ordered]@{ zoneId = $d.id }) }
  if (-not $tok.Stored) {
    if ($cf.accountId -or $mode -eq 'tunnel') { & $add 'cloudflare' 'token' 'API token' 'reconnect' 'No API token is stored. Reconnect Cloudflare to manage DNS, routes and Access from here; the saved account, tunnel and domains are kept. The tunnel itself keeps running.' $null }
  } elseif (-not $tok.Readable) {
    & $add 'cloudflare' 'token' 'API token' 'reconnect' 'The stored token cannot be decrypted by this Windows account (saved by another user or PC). Reconnect Cloudflare; nothing is deleted.' $null
  } else { & $add 'cloudflare' 'token' 'API token' 'detected' "Stored (encrypted), saved $($tok.SavedAt)." $null }
  if (Test-TunnelTokenFile $settings) {
    $decoded = ConvertFrom-TunnelToken ([IO.File]::ReadAllText((Join-Path $Path 'secrets\cloudflare_tunnel_token')).Trim())
    if (-not $decoded) { & $add 'cloudflare' 'connector-token' 'Connector token' 'failed' 'secrets\cloudflare_tunnel_token is not a valid tunnel token.' $null }
    elseif ($tunnelId -and $decoded.TunnelId -ne $tunnelId) { & $add 'cloudflare' 'connector-token' 'Connector token' 'warning' 'The connector token belongs to a different tunnel than the one recorded.' ([ordered]@{ tokenTunnelId = $decoded.TunnelId }) }
    else { & $add 'cloudflare' 'connector-token' 'Connector token' 'detected' 'Present for this tunnel (the secret is not shown).' $null }
  } elseif ($mode -eq 'tunnel' -and $summary.installed) { & $add 'cloudflare' 'connector-token' 'Connector token' 'missing' 'secrets\cloudflare_tunnel_token is missing; cloudflared cannot connect. Install it again on the Cloudflare page.' $null }
  $dash = Read-DashboardConfig -Settings $settings
  if ($dash.enabled -and $dash.hostname) { & $add 'cloudflare' 'dashboard' 'Public dashboard' 'detected' "https://$($dash.hostname)/dashboard/ (Cloudflare Access)" $null }
  if ($Cloudflare -and $tok.Stored -and $tok.Readable -and $cf.accountId) {
    $result.cloudflareChecked = $true
    $hostnames = @(foreach ($p in $cf.managed.PSObject.Properties) { [pscustomobject]@{ hostname = $p.Name; dnsRecordId = [string](Get-ServiceProperty $p.Value 'dnsRecordId' ''); accessAppId = [string](Get-ServiceProperty $p.Value 'accessAppId' '') } })
    $check = Get-CloudflareResourceCheck -Settings $settings -AccountId $cf.accountId -TunnelId $tunnelId -Domains $cf.domains -Hostnames $hostnames
    $map = @{ verified = 'verified'; missing = 'missing'; mismatch = 'warning'; unknown = 'warning'; none = 'info' }
    $upd = { param($Id, $x) $it = @($items | Where-Object { $_.id -eq $Id }); if ($it.Count -and $x) { $it[0].status = $map[$x.state]; $it[0].message = "$($it[0].message) - $($x.message)" } }
    & $upd 'account' $check.Account
    & $upd 'tunnel' $check.Tunnel
    foreach ($d in $check.Domains) { & $upd "zone-$($d.id)" $d }
    foreach ($h in $check.Hostnames) {
      foreach ($pair in @(@('DNS record', $h.dns), @('Access application', $h.access))) {
        if ($pair[1].state -ne 'none') { & $add 'cloudflare' "res-$($h.hostname)-$($pair[0])" "$($pair[0]) of $($h.hostname)" $map[$pair[1].state] $pair[1].message ([ordered]@{ id = $pair[1].id }) }
      }
    }
    if ($tunnelId) { $other = Find-ConnectorForTunnel -Settings $settings -TunnelId $tunnelId; if ($other) { & $add 'cloudflare' 'other-connector' 'Other connector' 'warning' "Container '$other' also runs a connector for this tunnel." $null } }
  }
  $result.items = $items.ToArray()
  $result.blockers = @($items | Where-Object { $_.status -eq 'failed' -and $_.section -eq 'files' } | ForEach-Object { "$($_.label): $($_.message)" })
  $result.usable = $result.blockers.Count -eq 0
  return [pscustomobject]$result
}

# Subfolders of a folder for the folder picker (names only, no files). Folders that look like deployments are marked.
function Get-FolderListing {
  param([Parameter(Mandatory = $true)][string]$Path)
  $full = ConvertTo-ProjectPathForBrowse $Path
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "The folder $full does not exist." }
  $dirs = @(Get-ChildItem -LiteralPath $full -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::System) -and ($_.Name -notmatch '^\$') } | Sort-Object Name | Select-Object -First 500)
  $parent = Split-Path -Parent $full
  return [pscustomobject][ordered]@{
    path = $full; parent = $(if ($parent -and $parent -ne $full) { $parent } else { '' })
    kind = Get-ProjectKind $full
    entries = @($dirs | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; path = $_.FullName; kind = (Get-ProjectKind $_.FullName) } })
  }
}

# Like ConvertTo-ProjectPath, but drive roots are allowed (browsing starts there).
function ConvertTo-ProjectPathForBrowse([string]$Path) {
  $p = ([string]$Path).Trim().Trim('"')
  if ($p -match '^[A-Za-z]:\\?$') { return $p.Substring(0, 2) + '\' }
  return ConvertTo-ProjectPath $p
}

function Get-FolderRoots {
  $roots = @([pscustomobject]@{ label = 'Docker projects'; path = (Join-Path $env:USERPROFILE '.docker\projects') }, [pscustomobject]@{ label = 'Your profile'; path = $env:USERPROFILE })
  foreach ($d in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -in @('Fixed', 'Removable') -and $_.IsReady })) { $roots += [pscustomobject]@{ label = "Drive $($d.Name.TrimEnd('\'))"; path = $d.Name } }
  return @($roots | Where-Object { Test-Path -LiteralPath $_.path })
}

Export-ModuleMember -Function ConvertTo-ProjectPath, Test-SamePath, Get-ProjectKind, Get-ProjectSettings, Get-ManagedFileList, Get-UpgradeStatus, Find-ProjectCandidates,
  Get-ProjectSummary, Get-ProjectInspection, Get-FolderListing, Get-FolderRoots
