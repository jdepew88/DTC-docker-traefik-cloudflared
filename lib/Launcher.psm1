#requires -version 5.1
# Windows launcher and startup support for the Deployment Manager (DTC): settings, start modes, logging, the running
# manager, Docker readiness, per-user autostart and shortcuts. Used by launcher\DTC-Tray.ps1 (system-tray app),
# launcher\Install-Launcher.ps1 (shortcuts), Start-DeploymentManager.ps1 and webui.ps1 (settings page).
#
# - Nothing here starts, stops or changes a Docker container. Choosing or changing the default deployment only records a
#   folder path; the manager opens it read-only, exactly like "Review and open" in the website.
# - Everything is per Windows user: state in %LOCALAPPDATA%\TraefikProxy (a development checkout gets its own subfolder so
#   it never controls the installed manager), autostart through a shortcut in the user's Startup folder. No administrator
#   rights, no registry writes, no scheduled tasks, no services.
# - No secret is stored in the launcher settings. The sign-in link file and the remembered-browser file are written by
#   webui.ps1 with a user-only ACL; log lines are redacted.
Set-StrictMode -Version 2.0

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Modes = @('default', 'choose', 'recovery')
$script:LogLimitBytes = 1MB

# --- Program folder, edition and state folder ----------------------------------------------------------------------

# development: a git checkout (or worktree); installed: a deployment folder written by install.ps1; package: an extracted ZIP.
function Get-LauncherEdition([string]$ProgramPath) {
  if (Test-Path -LiteralPath (Join-Path $ProgramPath '.git')) { return 'development' }
  if (Test-Path -LiteralPath (Join-Path $ProgramPath '.install-manifest.json')) { return 'installed' }
  return 'package'
}

function Get-LauncherBaseDir { return (Join-Path $env:LOCALAPPDATA 'TraefikProxy') }

# The installed manager and extracted packages share %LOCALAPPDATA%\TraefikProxy (as before). A development checkout gets
# its own folder, so its tray, port, sign-in link and settings never touch the installed manager's.
function Get-LauncherStateDir([string]$ProgramPath) {
  $base = Get-LauncherBaseDir
  if ((Get-LauncherEdition $ProgramPath) -ne 'development') { return $base }
  $full = [IO.Path]::GetFullPath($ProgramPath).TrimEnd('\').ToLowerInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  $hash = (-join ($sha.ComputeHash($script:Utf8NoBom.GetBytes($full))[0..3] | ForEach-Object { $_.ToString('x2') }))
  $name = (Split-Path -Leaf $full) -replace '[^A-Za-z0-9._-]', '_'
  return (Join-Path $base "dev\$name-$hash")
}

function Get-LauncherDefaultPort([string]$Edition) { if ($Edition -eq 'development') { return 8290 }; return 8190 }

function Get-LauncherFiles([string]$StateDir) {
  $logs = Join-Path $StateDir 'logs'
  return [pscustomobject]@{
    StateDir = $StateDir; Settings = (Join-Path $StateDir 'launcher.json'); Manager = (Join-Path $StateDir 'manager.json')
    LaunchUrl = (Join-Path $StateDir 'launch.url'); Stop = (Join-Path $StateDir 'manager.stop'); Command = (Join-Path $StateDir 'tray.command')
    Sessions = (Join-Path $StateDir 'sessions.json'); WebState = (Join-Path $StateDir 'webui.json'); LogDir = $logs
    LauncherLog = (Join-Path $logs 'launcher.log'); ManagerLog = (Join-Path $logs 'manager.log')
  }
}

# --- Settings ----------------------------------------------------------------------------------------------------------------

function Get-LauncherDefaults([string]$ProgramPath) {
  $edition = Get-LauncherEdition $ProgramPath
  return [ordered]@{
    schema = 1
    programPath = [IO.Path]::GetFullPath($ProgramPath).TrimEnd('\')
    edition = $edition
    defaultDeployment = ''
    defaultStackName = ''
    autostart = $false
    openBrowserOnManualLaunch = $true
    port = (Get-LauncherDefaultPort $edition)
    dockerWaitSeconds = 300
    rememberBrowser = $true
    rememberDays = 30
    updatedAt = ''
  }
}

# Settings with defaults for missing or invalid values. A damaged file is reported in .problem and never overwritten here.
function Read-LauncherSettings([string]$StateDir, [string]$ProgramPath) {
  $s = Get-LauncherDefaults $ProgramPath
  $s['problem'] = ''
  $file = (Get-LauncherFiles $StateDir).Settings
  if (-not (Test-Path -LiteralPath $file)) { return $s }
  try { $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json }
  catch { $s.problem = "The launcher settings file could not be read ($($_.Exception.Message)); defaults are used."; return $s }
  if ($null -eq $j) { return $s }
  $get = { param($n) if ($j.PSObject.Properties[$n]) { return $j.$n }; return $null }
  $v = & $get 'defaultDeployment'; if ($v -is [string] -and ($v -eq '' -or $v -match '^[A-Za-z]:\\')) { $s.defaultDeployment = $v.TrimEnd('\') }
  $v = & $get 'defaultStackName'; if ($v -is [string]) { $s.defaultStackName = $v }
  foreach ($b in @('autostart', 'openBrowserOnManualLaunch', 'rememberBrowser')) { $v = & $get $b; if ($v -is [bool]) { $s[$b] = $v } }
  $v = & $get 'port'; if ($null -ne $v -and "$v" -match '^\d{4,5}$' -and [int]$v -ge 1024 -and [int]$v -le 65535) { $s.port = [int]$v }
  $v = & $get 'dockerWaitSeconds'; if ($null -ne $v -and "$v" -match '^\d{1,4}$') { $s.dockerWaitSeconds = [Math]::Min(1800, [int]$v) }
  $v = & $get 'rememberDays'; if ($null -ne $v -and "$v" -match '^\d{1,3}$' -and [int]$v -ge 1) { $s.rememberDays = [Math]::Min(365, [int]$v) }
  $v = & $get 'updatedAt'; if ($v -is [string]) { $s.updatedAt = $v }
  return $s
}

function Save-LauncherSettings([string]$StateDir, $Settings) {
  $out = [ordered]@{}
  foreach ($k in @('schema', 'programPath', 'edition', 'defaultDeployment', 'defaultStackName', 'autostart', 'openBrowserOnManualLaunch', 'port', 'dockerWaitSeconds', 'rememberBrowser', 'rememberDays')) { $out[$k] = $Settings[$k] }
  $out['updatedAt'] = (Get-Date -Format 's')
  $file = (Get-LauncherFiles $StateDir).Settings
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  $tmp = $file + '.tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $out) + "`n", $script:Utf8NoBom)
  Move-Item -LiteralPath $tmp -Destination $file -Force
}

# --- Deployments -------------------------------------------------------------------------------------------------------------

# Same rule as ProjectDiscovery's Get-ProjectKind for an installed deployment, without loading the heavier modules.
function Get-LauncherDeployment([string]$Path) {
  $r = [ordered]@{ path = $Path; kind = 'missing'; stackName = ''; usable = $false }
  if (-not $Path) { $r.kind = 'none'; return $r }
  if ($Path -notmatch '^[A-Za-z]:\\') { $r.kind = 'invalid'; return $r }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $r }
  $compose = Join-Path $Path 'compose.yaml'
  $r.kind = 'other'
  if (Test-Path -LiteralPath $compose) {
    $text = [IO.File]::ReadAllText($compose)
    if ($text -match '\$\{STACK_NAME' -and $text -match 'socket-proxy') {
      if ((Test-Path -LiteralPath (Join-Path $Path '.env')) -or (Test-Path -LiteralPath (Join-Path $Path '.install-manifest.json'))) { $r.kind = 'manager'; $r.usable = $true }
      elseif (Test-Path -LiteralPath (Join-Path $Path 'config\setup.json')) { $r.kind = 'draft' }
      else { $r.kind = 'package' }
    }
  } elseif (Test-Path -LiteralPath (Join-Path $Path 'config\setup.json')) { $r.kind = 'draft' }
  $envFile = Join-Path $Path '.env'
  if (Test-Path -LiteralPath $envFile) {
    foreach ($line in [IO.File]::ReadAllLines($envFile)) { if ($line -match '^\s*STACK_NAME\s*=\s*"?([^"#\s]+)') { $r.stackName = $Matches[1]; break } }
  }
  return $r
}

# The deployment the manager remembered last (webui.json), used once to seed the default. Looks in this state folder, then
# (for a development checkout) in the installed manager's, read-only.
function Find-LauncherSeedDeployment([string]$StateDir) {
  foreach ($dir in @($StateDir, (Get-LauncherBaseDir)) | Select-Object -Unique) {
    $file = (Get-LauncherFiles $dir).WebState
    if (-not (Test-Path -LiteralPath $file)) { continue }
    try { $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { continue }
    if ($j -and $j.PSObject.Properties['installPath'] -and [string]$j.installPath) {
      $d = Get-LauncherDeployment ([string]$j.installPath)
      if ($d.usable) { return $d }
    }
  }
  return $null
}

# What a start in the given mode does. Never fails: a missing or unusable default falls back to the chooser with a notice.
function Resolve-LauncherStart($Settings, [string]$Mode) {
  if ($script:Modes -notcontains $Mode) { throw "Unknown start mode '$Mode' (use default, choose or recovery)." }
  $r = [ordered]@{ mode = $Mode; installPath = ''; stackName = ''; chooser = $true; notice = ''; level = 'info' }
  if ($Mode -eq 'recovery') { $r.notice = 'Recovery mode: no deployment was opened automatically. Nothing was started, stopped or changed.'; return $r }
  if ($Mode -eq 'choose') { return $r }
  $path = [string]$Settings.defaultDeployment
  if (-not $path) { $r.notice = 'No default deployment is set yet. Open one and select "Make default" to skip this page next time.'; return $r }
  $d = Get-LauncherDeployment $path
  if ($d.usable) { $r.installPath = $path; $r.stackName = $d.stackName; $r.chooser = $false; return $r }
  $r.level = 'warn'
  $r.notice = switch ($d.kind) {
    'missing' { "The default deployment folder $path was not found (moved, renamed or on a disconnected drive). Choose a deployment; the default was kept." }
    'draft' { "The default deployment $path has not finished setup. Choose it below to continue the setup." }
    default { "The default deployment $path is no longer a deployment of this tool. Choose a deployment; the default was kept." }
  }
  return $r
}

# --- Logging -------------------------------------------------------------------------------------------------------------

# Removes things that must never reach a log: sign-in keys, cookies, bearer tokens and long secret-looking strings.
function Protect-LauncherLogText([string]$Text) {
  if (-not $Text) { return '' }
  $t = $Text -replace '([?&]k=)[A-Za-z0-9_-]+', '$1[redacted]'
  $t = $t -replace '(?i)(tpx_session_\d+=)[^;\s]+', '$1[redacted]'
  $t = $t -replace '(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+', '$1[redacted]'
  $t = $t -replace '(?i)((?:token|secret|password|api[_-]?key)\s*[=:]\s*)\S+', '$1[redacted]'
  $t = $t -replace '\b[A-Za-z0-9_-]{40,}\b', '[redacted]'
  return $t
}

# Appends one line to logs\launcher.log (or -Path); the file is rotated to .1 at 1 MB. Never throws.
function Write-LauncherLog {
  param([Parameter(Mandatory = $true)][string]$StateDir, [string]$Source = 'launcher', [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO', [string]$Message, [string]$Path)
  try {
    if (-not $Path) { $Path = (Get-LauncherFiles $StateDir).LauncherLog }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt $script:LogLimitBytes) { Move-Item -LiteralPath $Path -Destination "$Path.1" -Force }
    $line = '{0} {1,-5} [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Source, ((Protect-LauncherLogText $Message) -replace '\r?\n', ' | ')
    [IO.File]::AppendAllText($Path, $line + "`r`n", $script:Utf8NoBom)
  } catch { }
}

# Reads a file that another process may still be writing (the manager's transcript keeps manager.log open).
function Read-LauncherText([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { $sr = New-Object IO.StreamReader($fs, $true); return $sr.ReadToEnd() } finally { $fs.Dispose() }
}

function Get-LauncherLogTail([string]$Path, [int]$Lines = 20) {
  try { return @((Read-LauncherText $Path) -split '\r?\n' | Where-Object { $_ } | Select-Object -Last $Lines | ForEach-Object { Protect-LauncherLogText $_ }) } catch { return @() }
}

# --- The running manager ---------------------------------------------------------------------------------------------------

function Get-ManagerRecord([string]$StateDir) {
  $file = (Get-LauncherFiles $StateDir).Manager
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { return [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { return $null }
}

# True when a Deployment Manager answers on the port (its API says "not signed in" with its own JSON shape).
function Test-ManagerEndpoint([int]$Port, [int]$TimeoutMs = 3000) {
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/api/session"); $req.Proxy = $null; $req.Timeout = $TimeoutMs
    try { $res = $req.GetResponse() } catch [System.Net.WebException] { $res = $_.Exception.Response }
    if (-not $res) { return $false }
    $body = (New-Object IO.StreamReader($res.GetResponseStream())).ReadToEnd(); $res.Close()
    return ($body -match '"signedOut"\s*:\s*true')
  } catch { return $false }
}

# The manager recorded in this state folder, when its process is alive and it answers; else $null.
function Get-RunningManager([string]$StateDir) {
  $info = Get-ManagerRecord $StateDir
  if (-not $info -or -not $info.PSObject.Properties['pid'] -or -not $info.PSObject.Properties['port']) { return $null }
  if (-not (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)) { return $null }
  if (Test-ManagerEndpoint ([int]$info.port)) { return $info }
  return $null
}

function Test-LoopbackPortFree([int]$Port) {
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
  try { $l.ExclusiveAddressUse = $true; $l.Start(); return $true } catch { return $false } finally { try { $l.Stop() } catch { } }
}

# The preferred port, else the next free one within 30; $null when none is free.
function Find-ManagerPort([int]$Preferred) {
  foreach ($p in @($Preferred) + @(($Preferred + 1)..($Preferred + 30))) { if ($p -le 65535 -and (Test-LoopbackPortFree $p)) { return $p } }
  return $null
}

# Asks the manager to stop (stop file + a poke) and waits. Only the website stops; containers are not touched.
# Returns $true when it stopped. -Kill ends the given process when it does not stop in time (the tray's own child only).
function Stop-RunningManager([string]$StateDir, $Info, [int]$TimeoutSeconds = 20, [switch]$Kill) {
  if (-not $Info) { return $true }
  $files = Get-LauncherFiles $StateDir
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  [IO.File]::WriteAllText($files.Stop, 'stop')
  $c = New-Object System.Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', [int]$Info.port) } catch { } finally { $c.Close() }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline -and (Get-Process -Id ([int]$Info.pid) -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 250 }
  if (Get-Process -Id ([int]$Info.pid) -ErrorAction SilentlyContinue) {
    if (-not $Kill) { return $false }
    Stop-Process -Id ([int]$Info.pid) -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
  }
  foreach ($f in @($files.Stop, $files.LaunchUrl)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
  $now = Get-ManagerRecord $StateDir
  if ($now -and [int]$now.pid -eq [int]$Info.pid) { Remove-Item -LiteralPath $files.Manager -Force -ErrorAction SilentlyContinue }
  return (-not (Get-Process -Id ([int]$Info.pid) -ErrorAction SilentlyContinue))
}

# The current sign-in link (single use), optionally opening a page after sign-in. $null when the manager has not written it.
function Get-ManagerLaunchUrl([string]$StateDir, [string]$Page) {
  $file = (Get-LauncherFiles $StateDir).LaunchUrl
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  $url = ([IO.File]::ReadAllText($file)).Trim()
  if ($url -notmatch '^http://127\.0\.0\.1:\d+/\?k=[A-Za-z0-9_-]+$') { return $null }
  if ($Page -match '^[a-z][a-z-]{0,30}$') { $url += "&to=$Page" }
  return $url
}

# --- Docker readiness ------------------------------------------------------------------------------------------------------

# Starts `docker info` without a window; the caller polls .HasExited (the tray must not block its menu). $null: no docker CLI.
function Start-DockerProbe {
  $docker = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $docker) { return $null }
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo.FileName = $docker.Source; $p.StartInfo.Arguments = 'info --format "{{.ServerVersion}}"'
  $p.StartInfo.UseShellExecute = $false; $p.StartInfo.RedirectStandardOutput = $true; $p.StartInfo.RedirectStandardError = $true; $p.StartInfo.CreateNoWindow = $true
  $null = $p.Start()
  return $p
}

# Blocking check: ready / notRunning / notInstalled.
function Test-DockerReady([int]$TimeoutMs = 15000) {
  $p = Start-DockerProbe
  if (-not $p) { return 'notInstalled' }
  if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return 'notRunning' }
  if ($p.ExitCode -eq 0) { return 'ready' }
  return 'notRunning'
}

# --- Tray single instance and commands -----------------------------------------------------------------------------------

function Get-LauncherMutexName([string]$StateDir) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $hash = -join ($sha.ComputeHash($script:Utf8NoBom.GetBytes($StateDir.TrimEnd('\').ToLowerInvariant()))[0..7] | ForEach-Object { $_.ToString('x2') })
  return "Local\DTC-Tray-$hash"
}

# A second launch hands its request to the running tray through this file (open, choose, recovery, restart, exit).
function Send-TrayCommand([string]$StateDir, [ValidateSet('open', 'choose', 'recovery', 'restart', 'exit')][string]$Command) {
  if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
  [IO.File]::WriteAllText((Get-LauncherFiles $StateDir).Command, $Command)
}

function Receive-TrayCommand([string]$StateDir) {
  $file = (Get-LauncherFiles $StateDir).Command
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { $c = ([IO.File]::ReadAllText($file)).Trim(); Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } catch { return $null }
  if ($c -in @('open', 'choose', 'recovery', 'restart', 'exit')) { return $c }
  return $null
}

# --- Shortcuts and autostart -----------------------------------------------------------------------------------------------

function Get-LauncherExePath([string]$ProgramPath) { return (Join-Path $ProgramPath 'launcher\DTC.exe') }
function Get-LauncherIconPath([string]$ProgramPath) { return (Join-Path $ProgramPath 'launcher\DTC.ico') }

function Get-LauncherAppName([string]$Edition) { if ($Edition -eq 'development') { return 'DTC Deployment Manager (development)' }; return 'DTC Deployment Manager' }

# How a shortcut starts the tray: the small windowless DTC.exe when it was built, else powershell.exe hidden (a console
# window may flash briefly with Windows Terminal as the default terminal).
function Get-LauncherCommand([string]$ProgramPath, [ValidateSet('default', 'choose', 'recovery')][string]$Mode = 'default', [switch]$Autostart) {
  $exe = Get-LauncherExePath $ProgramPath
  $tray = Join-Path $ProgramPath 'launcher\DTC-Tray.ps1'
  $extra = @()
  if ($Mode -ne 'default') { $extra += @('-Mode', $Mode) }
  if ($Autostart) { $extra += '-Autostart' }
  $icon = Get-LauncherIconPath $ProgramPath
  if (Test-Path -LiteralPath $exe) {
    return [pscustomobject]@{ Target = $exe; Arguments = ($extra -join ' '); WindowStyle = 1; Icon = $(if (Test-Path -LiteralPath $icon) { "$icon,0" } else { "$exe,0" }); Windowless = $true }
  }
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $args = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$tray`"") + $extra) -join ' '
  return [pscustomobject]@{ Target = $ps; Arguments = $args; WindowStyle = 7; Icon = $(if (Test-Path -LiteralPath $icon) { "$icon,0" } else { "$ps,0" }); Windowless = $false }
}

function New-LauncherShortcut([string]$Path, $Command, [string]$WorkingDirectory, [string]$Description) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $shell = New-Object -ComObject WScript.Shell
  try {
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Command.Target; $lnk.Arguments = $Command.Arguments; $lnk.WorkingDirectory = $WorkingDirectory
    $lnk.WindowStyle = $Command.WindowStyle; $lnk.IconLocation = $Command.Icon; $lnk.Description = $Description
    $lnk.Save()
  } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Read-LauncherShortcut([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $shell = New-Object -ComObject WScript.Shell
  try { $l = $shell.CreateShortcut($Path); return [pscustomobject]@{ Target = $l.TargetPath; Arguments = $l.Arguments; WorkingDirectory = $l.WorkingDirectory; Icon = $l.IconLocation; WindowStyle = $l.WindowStyle } }
  finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Get-LauncherStartupDir([string]$StartupDir) { if ($StartupDir) { return $StartupDir }; return [Environment]::GetFolderPath('Startup') }

function Get-AutostartShortcutPath([string]$Edition, [string]$StartupDir) { return (Join-Path (Get-LauncherStartupDir $StartupDir) ((Get-LauncherAppName $Edition) + '.lnk')) }

# Whether Windows lets the Startup-folder entry run: Task Manager's "Startup apps" switch writes StartupApproved (read only here).
function Test-StartupApproved([string]$FileName) {
  try {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    $v = (Get-ItemProperty -LiteralPath $key -Name $FileName -ErrorAction Stop).$FileName
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
  } catch { }
  return $true
}

function Get-LauncherAutostart([string]$ProgramPath, [string]$StartupDir) {
  $edition = Get-LauncherEdition $ProgramPath
  $path = Get-AutostartShortcutPath $edition $StartupDir
  $lnk = Read-LauncherShortcut $path
  $r = [ordered]@{ enabled = $false; path = $path; pointsHere = $false; allowedByWindows = $true; windowless = $false; mechanism = 'Startup folder shortcut (per user)' }
  if (-not $lnk) { return $r }
  $r.enabled = $true
  $cmd = Get-LauncherCommand $ProgramPath -Autostart
  $r.pointsHere = ([string]$lnk.Target -ieq [string]$cmd.Target) -and ([string]$lnk.Arguments -eq [string]$cmd.Arguments)
  $r.windowless = ([string]$lnk.Target -like '*\DTC.exe')
  $r.allowedByWindows = Test-StartupApproved (Split-Path -Leaf $path)
  return $r
}

# Adds or removes the per-user Startup-folder shortcut. Autostart runs the tray with -Autostart: it waits for Docker Desktop,
# starts the manager without a window and never opens a browser.
function Set-LauncherAutostart([string]$ProgramPath, [bool]$Enabled, [string]$StartupDir) {
  $edition = Get-LauncherEdition $ProgramPath
  $path = Get-AutostartShortcutPath $edition $StartupDir
  if ($Enabled) { New-LauncherShortcut -Path $path -Command (Get-LauncherCommand $ProgramPath -Autostart) -WorkingDirectory $ProgramPath -Description 'Starts the DTC Deployment Manager in the background (system tray) when you sign in.' }
  else { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
  return (Get-LauncherAutostart $ProgramPath $StartupDir)
}

# --- Icon and windowless launcher ------------------------------------------------------------------------------------------

# The program icon (the website's icon, see webui\icon.svg) with an optional status dot: ok, busy, error, off.
function New-LauncherBitmap([int]$Size, [string]$Status = '') {
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $k = $Size / 32.0
    $r = [single](7 * $k); $d = 2 * $r
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $w = [single]($Size - 0.5)
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90); $path.AddArc($w - $d, $w - $d, $d, $d, 0, 90); $path.AddArc(0, $w - $d, $d, $d, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0x23, 0x57, 0xd9))), $path)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single][Math]::Max(1.6, 2.6 * $k))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round; $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawLine($pen, [single](8 * $k), [single](16 * $k), [single](17 * $k), [single](16 * $k))
    $g.DrawLines($pen, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF([single](13.5 * $k), [single](11.5 * $k))), (New-Object System.Drawing.PointF([single](17 * $k), [single](16 * $k))), (New-Object System.Drawing.PointF([single](13.5 * $k), [single](20.5 * $k)))))
    $cr = [single](3.2 * $k)
    $g.FillEllipse([System.Drawing.Brushes]::White, [single](23 * $k - $cr), [single](16 * $k - $cr), 2 * $cr, 2 * $cr)
    $colors = @{ ok = @(0x1f, 0xa9, 0x5a); busy = @(0xf0, 0xa2, 0x02); error = @(0xd9, 0x2d, 0x20); off = @(0x8a, 0x8f, 0x98) }
    if ($colors.ContainsKey($Status)) {
      $c = $colors[$Status]; $dr = [single](6.5 * $k); $cx = [single]($Size - $dr - 0.5)
      $g.FillEllipse([System.Drawing.Brushes]::White, $cx - $dr, $cx - $dr, 2 * $dr, 2 * $dr)
      $inner = [single]($dr - [Math]::Max(1, 1.6 * $k))
      $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2]))), $cx - $inner, $cx - $inner, 2 * $inner, 2 * $inner)
    }
  } finally { $g.Dispose() }
  return $bmp
}

# A multi-size .ico (PNG frames, supported by Windows Vista and later).
function New-LauncherIconFile([string]$Path, [string]$Status = '') {
  $sizes = @(16, 24, 32, 48, 64, 256)
  $frames = @(foreach ($s in $sizes) {
      $bmp = New-LauncherBitmap $s $Status
      $ms = New-Object IO.MemoryStream
      try { $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
      , $ms.ToArray()
    })
  $out = New-Object IO.MemoryStream
  $bw = New-Object IO.BinaryWriter($out)
  $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
  $offset = 6 + 16 * $sizes.Count
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $frames[$i].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
  }
  foreach ($f in $frames) { $bw.Write([byte[]]$f) }
  $bw.Flush()
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllBytes($Path, $out.ToArray())
}

# Compiles launcher\DtcLauncher.cs into launcher\DTC.exe (a windowless program that starts the tray) with the .NET Framework
# compiler that ships with Windows. Rebuilt when the source is newer. Returns the exe path.
function New-LauncherExe([string]$ProgramPath, [switch]$Force, [string]$OutputPath) {
  $src = Join-Path $ProgramPath 'launcher\DtcLauncher.cs'
  if (-not (Test-Path -LiteralPath $src)) { throw "launcher\DtcLauncher.cs is missing in $ProgramPath." }
  $exe = $(if ($OutputPath) { $OutputPath } else { Get-LauncherExePath $ProgramPath })
  $icon = $(if ($OutputPath) { [IO.Path]::ChangeExtension($OutputPath, '.ico') } else { Get-LauncherIconPath $ProgramPath })
  if (-not $Force -and (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $icon) -and (Get-Item -LiteralPath $exe).LastWriteTimeUtc -ge (Get-Item -LiteralPath $src).LastWriteTimeUtc) { return $exe }
  New-LauncherIconFile -Path $icon
  $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
  $cp = New-Object System.CodeDom.Compiler.CompilerParameters
  $cp.GenerateExecutable = $true; $cp.GenerateInMemory = $false; $cp.OutputAssembly = $exe; $cp.IncludeDebugInformation = $false
  $null = $cp.ReferencedAssemblies.Add('System.dll'); $null = $cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')
  $cp.CompilerOptions = "/target:winexe /optimize+ /win32icon:`"$icon`""
  $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('dtc-build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  $cp.TempFiles = New-Object System.CodeDom.Compiler.TempFileCollection($tmpDir, $false)
  try {
    $result = $provider.CompileAssemblyFromSource($cp, [IO.File]::ReadAllText($src))
    $errors = @($result.Errors | Where-Object { -not $_.IsWarning })
    if ($errors.Count) { throw ('The launcher could not be compiled: ' + (@($errors | ForEach-Object { "line $($_.Line): $($_.ErrorText)" }) -join '; ')) }
  } finally { $provider.Dispose(); Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
  return $exe
}

# 2 = Windows GUI (no console window), 3 = console. Reads the PE header.
function Get-PeSubsystem([string]$Path) {
  $b = [IO.File]::ReadAllBytes($Path)
  $pe = [BitConverter]::ToInt32($b, 0x3C)
  return [int][BitConverter]::ToUInt16($b, $pe + 24 + 68)
}

Export-ModuleMember -Function Get-LauncherEdition, Get-LauncherBaseDir, Get-LauncherStateDir, Get-LauncherDefaultPort, Get-LauncherFiles, Get-LauncherDefaults,
  Read-LauncherSettings, Save-LauncherSettings, Get-LauncherDeployment, Find-LauncherSeedDeployment, Resolve-LauncherStart, Protect-LauncherLogText,
  Write-LauncherLog, Read-LauncherText, Get-LauncherLogTail, Get-ManagerRecord, Test-ManagerEndpoint, Get-RunningManager, Test-LoopbackPortFree, Find-ManagerPort,
  Stop-RunningManager, Get-ManagerLaunchUrl, Start-DockerProbe, Test-DockerReady, Get-LauncherMutexName, Send-TrayCommand, Receive-TrayCommand,
  Get-LauncherExePath, Get-LauncherIconPath, Get-LauncherAppName, Get-LauncherCommand, New-LauncherShortcut, Read-LauncherShortcut, Get-LauncherStartupDir,
  Get-AutostartShortcutPath, Test-StartupApproved, Get-LauncherAutostart, Set-LauncherAutostart, New-LauncherBitmap, New-LauncherIconFile, New-LauncherExe,
  Get-PeSubsystem
