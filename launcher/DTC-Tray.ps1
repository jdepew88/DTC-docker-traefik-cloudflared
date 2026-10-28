#requires -version 5.1
<#
.SYNOPSIS
  DTC system-tray app: runs the Deployment Manager in the background without a PowerShell window.

.DESCRIPTION
  Started by DTC.exe (windowless) from the shortcuts that Setup-Launcher.cmd creates, or by the Startup-folder entry.
  It starts Start-DeploymentManager.ps1 as a hidden child process (output in logs\manager.log), shows a tray icon and
  offers Open Dashboard, Choose Deployment, Restart Manager, Restart in Recovery Mode, Start with Windows, Open browser
  on manual start, Open Log Folder and Exit.

  Modes:
    default   open the saved default deployment (no question); the chooser with a notice when it is missing
    choose    open the deployment chooser (switch deployments or change the default)
    recovery  start without opening any deployment
  -Autostart (from the Startup folder): waits for Docker Desktop (launcher setting dockerWaitSeconds), starts silently and
  never opens a browser.

  Only one tray runs per state folder: a second start passes its request (open / choose / recovery) to the running tray
  and exits. Nothing here starts, stops or recreates a Docker container: Restart and Exit stop only the manager website.
  Errors are written to %LOCALAPPDATA%\TraefikProxy\logs\launcher.log (a development checkout: its own state folder).

.EXAMPLE
  launcher\DTC.exe                    # normal start (shortcut "DTC Deployment Manager")
  launcher\DTC.exe -Mode choose       # deployment chooser
  launcher\DTC.exe -Mode recovery     # recovery mode
#>
[CmdletBinding()]
param(
  [ValidateSet('default', 'choose', 'recovery')][string]$Mode = 'default',
  [switch]$Autostart,
  # Tests: a separate state folder and Startup folder; -NoBrowser never opens a browser.
  [string]$StateDir,
  [string]$StartupDir,
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Program = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $Program 'lib\Launcher.psm1') -Force
if (-not $StateDir) { $StateDir = Get-LauncherStateDir $Program }
$Files = Get-LauncherFiles $StateDir

function Log([string]$Level, [string]$Text) { Write-LauncherLog -StateDir $StateDir -Source 'tray' -Level $Level -Message $Text }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# --- Single instance ------------------------------------------------------------------------------------------------------

$mutex = New-Object System.Threading.Mutex($false, (Get-LauncherMutexName $StateDir))
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
  # Already running: hand over the request (Start with Windows never interrupts a running tray).
  if (-not $Autostart) { Send-TrayCommand $StateDir $(switch ($Mode) { 'choose' { 'choose' } 'recovery' { 'recovery' } default { 'open' } }) }
  Log 'INFO' "Another tray already runs for $StateDir; passed on '$Mode'$(if ($Autostart) { ' (autostart: nothing to do)' })."
  exit 0
}

# --- State ---------------------------------------------------------------------------------------------------------------

$S = @{
  Phase = 'idle'          # idle, docker, starting, running, stopped, failed
  Mode = $Mode
  Child = $null           # the Start-DeploymentManager.ps1 process this tray started
  Adopted = $false        # a manager that was already running (e.g. START-HERE.cmd)
  Port = 0
  Deployment = ''
  OpenWhenReady = $false
  OpenPage = ''
  Probe = $null           # docker info process
  DockerDeadline = [datetime]::MinValue
  NextProbe = [datetime]::MinValue
  StartDeadline = [datetime]::MinValue
  NextCheck = [datetime]::MinValue
  Message = ''
  Exiting = $false
}
$Settings = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
if ($Settings.problem) { Log 'WARN' $Settings.problem }
$Edition = Get-LauncherEdition $Program
$AppName = Get-LauncherAppName $Edition

# --- Tray icon and menu ----------------------------------------------------------------------------------------------------

$Icons = @{}
foreach ($k in @('ok', 'busy', 'error', 'off')) { $bmp = New-LauncherBitmap 32 $k; $Icons[$k] = [System.Drawing.Icon]::FromHandle($bmp.GetHicon()); $bmp.Dispose() }

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = $Icons['busy']
$Tray.Text = $(if ($Edition -eq 'development') { 'DTC (dev): starting' } else { 'DTC: starting' })
$Menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem([string]$Text, [scriptblock]$Action, [switch]$Bold) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
  if ($Bold) { $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Bold) }
  $item.add_Click({ param($sender, $e) Invoke-Safely $sender.Tag })
  $item.Tag = $Action
  $null = $Menu.Items.Add($item)
  return $item
}
$StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Starting...'); $StatusItem.Enabled = $false; $null = $Menu.Items.Add($StatusItem)
$null = $Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$null = Add-MenuItem 'Open Dashboard' { Open-Dashboard '' } -Bold
$null = Add-MenuItem 'Choose Deployment...' { Open-Dashboard 'projects' }
$null = Add-MenuItem 'Restart Manager' { Restart-Manager 'default' }
$null = Add-MenuItem 'Restart in Recovery Mode' { Restart-Manager 'recovery' }
$null = $Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$AutoItem = Add-MenuItem 'Start with Windows' { Switch-Autostart }
$BrowserItem = Add-MenuItem 'Open browser on manual start' { Switch-OpenBrowser }
$null = Add-MenuItem 'Open Log Folder' { New-Item -ItemType Directory -Force -Path $Files.LogDir | Out-Null; Start-Process explorer.exe -ArgumentList "`"$($Files.LogDir)`"" }
$null = $Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$null = Add-MenuItem 'Exit' { Exit-Tray }
$Tray.ContextMenuStrip = $Menu
$Menu.add_Opening({ Invoke-Safely { Update-MenuChecks } })
$Tray.add_MouseClick({ param($sender, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-Safely { Open-Dashboard '' } } })

# Event handlers must never throw into the message loop: log and show the problem instead.
function Invoke-Safely([scriptblock]$Action) {
  try { & $Action } catch { Log 'ERROR' "$($_.Exception.Message) ($($_.InvocationInfo.ScriptLineNumber))"; Show-Balloon 'DTC: something went wrong' "$($_.Exception.Message) See the log folder for details." 'Error' }
}

function Show-Balloon([string]$Title, [string]$Text, [string]$Kind = 'Info') {
  try { $Tray.ShowBalloonTip(6000, $Title, $(if ($Text.Length -gt 250) { $Text.Substring(0, 247) + '...' } else { $Text }), [System.Windows.Forms.ToolTipIcon]::$Kind) } catch { }
}

function Set-TrayState([string]$Phase, [string]$Message) {
  $S.Phase = $Phase; $S.Message = $Message
  $Tray.Icon = $Icons[$(switch ($Phase) { 'running' { 'ok' } 'failed' { 'error' } 'stopped' { 'off' } default { 'busy' } })]
  $dep = $(if ($S.Deployment) { $S.Deployment } elseif ($Phase -eq 'running') { 'no deployment open' } else { '' })
  $text = "DTC: $Message"
  if ($Edition -eq 'development') { $text = "DTC (dev): $Message" }
  # NotifyIcon.Text is limited to 63 characters.
  $Tray.Text = $(if ($text.Length -gt 63) { $text.Substring(0, 62) + '...' } else { $text })
  $StatusItem.Text = $(if ($Phase -eq 'running') { "Running on 127.0.0.1:$($S.Port)$(if ($dep) { " - $dep" })" } else { $Message })
}

function Update-MenuChecks {
  $s = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
  $AutoItem.Checked = [bool](Get-LauncherAutostart -ProgramPath $Program -StartupDir $StartupDir).enabled
  $BrowserItem.Checked = [bool]$s.openBrowserOnManualLaunch
}

# --- Manager control ------------------------------------------------------------------------------------------------------

function Get-DeploymentLabel([string]$StartMode) {
  if ($StartMode -eq 'recovery') { return 'recovery mode' }
  if ($StartMode -eq 'choose') { return 'choosing a deployment' }
  $s = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
  $plan = Resolve-LauncherStart $s 'default'
  if ($plan.installPath) { return $(if ($plan.stackName) { $plan.stackName } else { Split-Path -Leaf $plan.installPath }) }
  return 'choose a deployment'
}

# Starts Start-DeploymentManager.ps1 without a window. Readiness is checked by the timer, so the menu never freezes.
function Start-Manager([string]$StartMode, [bool]$OpenBrowser, [string]$Page) {
  $S.Mode = $StartMode; $S.OpenWhenReady = $OpenBrowser -and -not $NoBrowser; $S.OpenPage = $Page
  $running = Get-RunningManager $StateDir
  if ($running) {
    $S.Adopted = $true; $S.Child = $null; $S.Port = [int]$running.port; $S.Deployment = Get-DeploymentLabel 'default'
    Log 'INFO' "Using the manager that already runs on port $($S.Port) (process $($running.pid))."
    Set-TrayState 'running' "running on port $($S.Port)"
    if ($S.OpenWhenReady) { Open-LaunchLink $Page }
    return
  }
  $script = Join-Path $Program 'Start-DeploymentManager.ps1'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-Background', '-NoBrowser', '-IfRunning', 'open',
    '-StateDir', "`"$StateDir`"", '-StartMode', $StartMode, '-LogFile', "`"$($Files.ManagerLog)`"")
  if ($StartupDir) { $argList += @('-StartupDir', "`"$StartupDir`"") }
  $psi = New-Object System.Diagnostics.ProcessStartInfo((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), ($argList -join ' '))
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden; $psi.WorkingDirectory = $Program
  $S.Child = [System.Diagnostics.Process]::Start($psi)
  $S.Adopted = $false; $S.Deployment = Get-DeploymentLabel $StartMode
  $S.StartDeadline = (Get-Date).AddSeconds(90)
  Log 'INFO' "Starting the manager ($StartMode, process $($S.Child.Id), $($S.Deployment))."
  Set-TrayState 'starting' "starting ($($S.Deployment))"
}

function Open-LaunchLink([string]$Page) {
  $url = Get-ManagerLaunchUrl $StateDir $Page
  if (-not $url) { Show-Balloon 'DTC' 'The manager is still starting; try again in a moment.'; return }
  if ($NoBrowser) { Log 'INFO' "Would open the dashboard$(if ($Page) { " ($Page)" }) (-NoBrowser)."; return }
  Start-Process $url
}

# Open Dashboard / Choose Deployment: opens the running manager (switching deployments happens in the website and never
# restarts containers); starts the manager first when it is not running.
function Open-Dashboard([string]$Page) {
  if ($S.Phase -eq 'running' -and (Get-RunningManager $StateDir)) { Open-LaunchLink $Page; return }
  if ($S.Phase -in @('starting', 'docker')) { $S.OpenWhenReady = -not $NoBrowser; $S.OpenPage = $Page; Show-Balloon 'DTC' 'The manager is starting; the dashboard opens when it is ready.'; return }
  Start-Manager $(if ($Page -eq 'projects') { 'choose' } else { 'default' }) $true $Page
}

function Stop-Manager {
  $info = Get-RunningManager $StateDir
  if (-not $info) { $info = Get-ManagerRecord $StateDir }
  if (-not $info) { return $true }
  $ours = $S.Child -and -not $S.Child.HasExited -and [int]$info.pid -eq $S.Child.Id
  $ok = Stop-RunningManager -StateDir $StateDir -Info $info -TimeoutSeconds 20 -Kill:$ours
  Log $(if ($ok) { 'INFO' } else { 'WARN' }) "$(if ($ok) { 'Stopped' } else { 'Could not stop' }) the manager on port $($info.port) (process $($info.pid))."
  return $ok
}

# Restart: stops only the manager website (deployments keep running) and starts it again in the given mode.
function Restart-Manager([string]$StartMode) {
  Set-TrayState 'starting' 'restarting'
  if (-not (Stop-Manager)) { Set-TrayState 'failed' 'the running manager did not stop'; Show-Balloon 'DTC: restart failed' 'The running manager did not stop. Close its window (START-HERE.cmd) or see the log.' 'Error'; return }
  $S.Child = $null
  $s = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
  Start-Manager $StartMode ([bool]$s.openBrowserOnManualLaunch -or $StartMode -ne 'default') $(if ($StartMode -ne 'default') { 'projects' } else { '' })
}

function Switch-Autostart {
  $now = (Get-LauncherAutostart -ProgramPath $Program -StartupDir $StartupDir).enabled
  if (-not $now -and -not (Test-Path -LiteralPath (Get-LauncherExePath $Program))) {
    try { $null = New-LauncherExe -ProgramPath $Program } catch { Log 'WARN' "The windowless launcher could not be built: $($_.Exception.Message)" }
  }
  $r = Set-LauncherAutostart -ProgramPath $Program -Enabled (-not $now) -StartupDir $StartupDir
  $s = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program; $s.autostart = [bool]$r.enabled; Save-LauncherSettings $StateDir $s
  Log 'INFO' "Start with Windows: $($r.enabled) ($($r.path))."
  if ($r.enabled -and -not $r.allowedByWindows) { Show-Balloon 'DTC' 'Start with Windows is on, but Windows has it disabled in Task Manager > Startup apps. Enable it there as well.' 'Warning' }
  elseif ($r.enabled) { Show-Balloon 'DTC' 'DTC now starts silently when you sign in to Windows (after Docker Desktop is ready).' }
}

function Switch-OpenBrowser {
  $s = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
  $s.openBrowserOnManualLaunch = -not [bool]$s.openBrowserOnManualLaunch
  Save-LauncherSettings $StateDir $s
  Log 'INFO' "Open browser on manual start: $($s.openBrowserOnManualLaunch)."
}

function Exit-Tray {
  if ($S.Exiting) { return }
  $S.Exiting = $true
  Set-TrayState 'stopping' 'stopping'
  # A manager this tray started is stopped; one that was already running (START-HERE.cmd window) is left alone.
  if (-not $S.Adopted) { $null = Stop-Manager }
  Log 'INFO' 'Tray closed.'
  $Timer.Stop(); $Tray.Visible = $false; $Tray.Dispose()
  [System.Windows.Forms.Application]::ExitThread()
}

# --- Timer: Docker wait, start-up, health, commands from a second launch -----------------------------------------------------

function Invoke-Tick {
  $cmd = Receive-TrayCommand $StateDir
  if ($cmd) {
    Log 'INFO' "Request from another launch: $cmd."
    switch ($cmd) {
      'open' { Open-Dashboard '' }
      'choose' { Open-Dashboard 'projects' }
      'recovery' { Restart-Manager 'recovery' }
      'restart' { Restart-Manager 'default' }
      'exit' { Exit-Tray; return }
    }
  }
  $now = Get-Date
  switch ($S.Phase) {
    'docker' {
      if ($S.Probe -and -not $S.Probe.HasExited) {
        if ($now -gt $S.NextProbe.AddSeconds(20)) { try { $S.Probe.Kill() } catch { }; $S.Probe = $null }
        return
      }
      if ($S.Probe -and $S.Probe.ExitCode -eq 0) { $S.Probe = $null; Log 'INFO' 'Docker Desktop is ready.'; Start-Manager $S.Mode $S.OpenWhenReady $S.OpenPage; return }
      $S.Probe = $null
      if ($now -gt $S.DockerDeadline) {
        Log 'WARN' 'Docker Desktop did not become ready in time; starting the manager anyway (it shows Docker as not running).'
        Start-Manager $S.Mode $S.OpenWhenReady $S.OpenPage; return
      }
      if ($now -ge $S.NextProbe) {
        $S.Probe = Start-DockerProbe; $S.NextProbe = $now.AddSeconds(5)
        if (-not $S.Probe) { Log 'WARN' 'Docker is not installed; starting the manager without waiting.'; Start-Manager $S.Mode $S.OpenWhenReady $S.OpenPage }
      }
    }
    'starting' {
      $running = Get-RunningManager $StateDir
      if ($running -and (-not $S.Child -or [int]$running.pid -eq $S.Child.Id)) {
        $S.Port = [int]$running.port
        Log 'INFO' "The manager is running on http://127.0.0.1:$($S.Port)/ ($($S.Deployment))."
        Set-TrayState 'running' "running on port $($S.Port)"
        if ($S.OpenWhenReady) { $S.OpenWhenReady = $false; Open-LaunchLink $S.OpenPage }
        elseif (-not $Autostart -and -not $NoBrowser -and $S.Mode -eq 'default' -and -not $S.Exiting) { Show-Balloon $AppName "Running at http://127.0.0.1:$($S.Port)/ ($($S.Deployment)). Click the tray icon to open it." }
        return
      }
      if ($S.Child -and $S.Child.HasExited) {
        $tail = @(Get-LauncherLogTail $Files.ManagerLog 6 | Where-Object { $_ -match 'Problem:|error|stopped' })
        $why = $(if ($tail.Count) { $tail[-1] } else { "exit code $($S.Child.ExitCode)" })
        Log 'ERROR' "The manager did not start: $why"
        Set-TrayState 'failed' 'did not start (see log)'
        Show-Balloon 'DTC: the manager did not start' "$why  Use Restart Manager or Open Log Folder." 'Error'
        return
      }
      if ($now -gt $S.StartDeadline) {
        Log 'ERROR' 'The manager did not answer within 90 seconds.'
        Set-TrayState 'failed' 'not answering (see log)'
        Show-Balloon 'DTC: the manager is not answering' 'It did not answer within 90 seconds. Use Restart Manager or Open Log Folder.' 'Error'
      }
    }
    'running' {
      if ($now -lt $S.NextCheck) { return }
      $S.NextCheck = $now.AddSeconds(5)
      if (Get-RunningManager $StateDir) { return }
      if ($S.Child -and $S.Child.HasExited -and $S.Child.ExitCode -ne 0) {
        Log 'ERROR' "The manager stopped unexpectedly (exit code $($S.Child.ExitCode))."
        Set-TrayState 'failed' 'stopped unexpectedly (see log)'
        Show-Balloon 'DTC: the manager stopped' 'It stopped unexpectedly. Your deployments keep running. Use Restart Manager or Open Log Folder.' 'Error'
      } else {
        Log 'INFO' 'The manager was stopped (from the website or STOP-MANAGER.cmd).'
        Set-TrayState 'stopped' 'stopped - Open Dashboard starts it'
      }
    }
  }
}

# --- Go ----------------------------------------------------------------------------------------------------------------------

try {
  Log 'INFO' "Tray started: mode $Mode$(if ($Autostart) { ', autostart' }), program $Program ($Edition), state $StateDir."
  $Timer = New-Object System.Windows.Forms.Timer
  $Timer.Interval = 1000
  $Timer.add_Tick({ Invoke-Safely { Invoke-Tick } })
  $Tray.Visible = $true
  $Settings = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
  $openBrowser = (-not $Autostart) -and ($Mode -ne 'default' -or [bool]$Settings.openBrowserOnManualLaunch)
  $page = $(if ($Mode -ne 'default') { 'projects' } else { '' })
  if ($Autostart -and [int]$Settings.dockerWaitSeconds -gt 0) {
    $S.Mode = $Mode; $S.OpenWhenReady = $false; $S.OpenPage = ''
    $S.DockerDeadline = (Get-Date).AddSeconds([int]$Settings.dockerWaitSeconds)
    $S.Deployment = Get-DeploymentLabel $Mode
    Set-TrayState 'docker' 'waiting for Docker Desktop'
    Log 'INFO' "Waiting up to $($Settings.dockerWaitSeconds) s for Docker Desktop."
  } else {
    Start-Manager $Mode $openBrowser $page
  }
  $Timer.Start()
  [System.Windows.Forms.Application]::Run()
} catch {
  Log 'ERROR' "The tray stopped with an error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
  if (-not $Autostart) { [void][System.Windows.Forms.MessageBox]::Show("DTC could not start: $($_.Exception.Message)`n`nDetails: $($Files.LauncherLog)", 'DTC Deployment Manager', 'OK', 'Error') }
  exit 1
} finally {
  try { $Tray.Visible = $false; $Tray.Dispose() } catch { }
  try { $mutex.ReleaseMutex() } catch { }
}
exit 0
