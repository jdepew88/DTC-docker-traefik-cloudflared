#requires -version 5.1
<#
.SYNOPSIS
  Sets up the one-click DTC launcher for this Windows user: builds launcher\DTC.exe, creates the shortcuts, saves the
  default deployment and (optionally) turns on Start with Windows. Used by Setup-Launcher.cmd.

.DESCRIPTION
  - DTC.exe is compiled here from launcher\DtcLauncher.cs with the C# compiler of the .NET Framework that is part of Windows
    (no download). It starts the tray app (launcher\DTC-Tray.ps1) without any console window.
  - Shortcuts: on the desktop "DTC Deployment Manager"; in the Start menu (folder "DTC Deployment Manager") the same plus
    "DTC - Choose deployment" and "DTC - Recovery mode". A development checkout gets names ending in "(development)".
  - Start with Windows (-Autostart) is a shortcut in this user's Startup folder: per user, no administrator rights, visible
    and switchable in Task Manager > Startup apps. It waits for Docker Desktop and never opens a browser.
  - The default deployment is -DefaultDeployment, else the one already saved, else the deployment the manager opened last.
  - Changes nothing in any deployment, in Docker or in Cloudflare. Running it again updates the shortcuts.

.EXAMPLE
  .\launcher\Install-Launcher.ps1                                   # shortcuts; default = last opened deployment
  .\launcher\Install-Launcher.ps1 -Autostart                        # ... and start silently with Windows
  .\launcher\Install-Launcher.ps1 -DefaultDeployment C:\Users\me\.docker\projects\traefik-proxy -Autostart
  .\launcher\Install-Launcher.ps1 -NoAutostart                      # turn Start with Windows off again
  .\launcher\Install-Launcher.ps1 -Uninstall                        # remove shortcuts and autostart (settings and logs are kept)
#>
[CmdletBinding()]
param(
  [string]$DefaultDeployment,
  [switch]$Autostart,
  [switch]$NoAutostart,
  [ValidateSet('keep', 'yes', 'no')][string]$OpenBrowser = 'keep',
  [switch]$NoDesktopShortcut,
  [switch]$Uninstall,
  # Start the tray now (normal mode) when setup is done.
  [switch]$Launch,
  # Tests: separate folders instead of this user's state, desktop, Start menu and Startup folders.
  [string]$StateDir,
  [string]$DesktopDir,
  [string]$StartMenuDir,
  [string]$StartupDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Program = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $Program 'lib\Launcher.psm1') -Force

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Fail([string]$Text) { Say ''; Say "Problem: $Text" 'Red'; Write-LauncherLog -StateDir $StateDir -Source 'setup' -Level 'ERROR' -Message $Text; exit 1 }

if ($Autostart -and $NoAutostart) { throw 'Use either -Autostart or -NoAutostart.' }
if (-not $StateDir) { $StateDir = Get-LauncherStateDir $Program }
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath('Desktop') }
if (-not $StartMenuDir) { $StartMenuDir = [Environment]::GetFolderPath('Programs') }
$Edition = Get-LauncherEdition $Program
$AppName = Get-LauncherAppName $Edition
$Suffix = $(if ($Edition -eq 'development') { ' (development)' } else { '' })
$MenuDir = Join-Path $StartMenuDir $AppName
$Shortcuts = @(
  [pscustomobject]@{ Path = (Join-Path $DesktopDir "$AppName.lnk"); Mode = 'default'; Description = 'Opens the DTC Deployment Manager with your default deployment (runs in the system tray).'; Desktop = $true }
  [pscustomobject]@{ Path = (Join-Path $MenuDir "$AppName.lnk"); Mode = 'default'; Description = 'Opens the DTC Deployment Manager with your default deployment (runs in the system tray).'; Desktop = $false }
  [pscustomobject]@{ Path = (Join-Path $MenuDir "DTC - Choose deployment$Suffix.lnk"); Mode = 'choose'; Description = 'Opens the DTC deployment chooser: switch deployments or change the default.'; Desktop = $false }
  [pscustomobject]@{ Path = (Join-Path $MenuDir "DTC - Recovery mode$Suffix.lnk"); Mode = 'recovery'; Description = 'Starts the DTC Deployment Manager without opening any deployment (troubleshooting).'; Desktop = $false }
)

Say "$AppName - launcher setup" 'Cyan'
Say "Program folder: $Program ($Edition)"
Say "Settings and logs: $StateDir"
if ($Edition -eq 'development') { Say 'This is a development checkout: it uses its own settings, port and shortcuts and never controls the installed manager.' 'Yellow' }

# --- Uninstall ---------------------------------------------------------------------------------------------------------------
if ($Uninstall) {
  foreach ($s in $Shortcuts) { if (Test-Path -LiteralPath $s.Path) { Remove-Item -LiteralPath $s.Path -Force; Say "Removed $($s.Path)" } }
  if ((Test-Path -LiteralPath $MenuDir) -and -not @(Get-ChildItem -LiteralPath $MenuDir -Force).Count) { Remove-Item -LiteralPath $MenuDir -Force }
  $a = Set-LauncherAutostart -ProgramPath $Program -Enabled $false -StartupDir $StartupDir
  $settings = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
  $settings.autostart = $false
  Save-LauncherSettings $StateDir $settings
  Write-LauncherLog -StateDir $StateDir -Source 'setup' -Message 'Shortcuts and Start with Windows removed.'
  Say 'Shortcuts and Start with Windows removed. Settings and logs were kept; nothing in your deployments or Docker changed.' 'Green'
  exit 0
}

# --- Settings and default deployment ---------------------------------------------------------------------------------------
$settings = Read-LauncherSettings -StateDir $StateDir -ProgramPath $Program
if ($settings.problem) { Say $settings.problem 'Yellow' }
if ($DefaultDeployment) {
  $path = [IO.Path]::GetFullPath($DefaultDeployment).TrimEnd('\')
  $d = Get-LauncherDeployment $path
  if (-not $d.usable) { Fail "$path is not an installed deployment of this tool ($($d.kind)). Choose the folder that contains its .env and compose.yaml." }
  $settings.defaultDeployment = $path; $settings.defaultStackName = $d.stackName
} elseif (-not $settings.defaultDeployment) {
  $seed = Find-LauncherSeedDeployment $StateDir
  if ($seed) { $settings.defaultDeployment = $seed.path; $settings.defaultStackName = $seed.stackName }
}
if ($OpenBrowser -ne 'keep') { $settings.openBrowserOnManualLaunch = ($OpenBrowser -eq 'yes') }
$settings.programPath = $Program; $settings.edition = $Edition

# --- Windowless launcher -------------------------------------------------------------------------------------------------------
$windowless = $true
try { $null = New-LauncherExe -ProgramPath $Program; Say 'Built launcher\DTC.exe (starts the tray without a console window).' 'Green' }
catch {
  $windowless = $false
  Say "DTC.exe could not be built ($($_.Exception.Message))." 'Yellow'
  Say 'The shortcuts start PowerShell hidden instead; a console window may flash briefly when you start DTC.' 'Yellow'
  Write-LauncherLog -StateDir $StateDir -Source 'setup' -Level 'WARN' -Message "DTC.exe could not be built: $($_.Exception.Message)"
}

# --- Shortcuts ---------------------------------------------------------------------------------------------------------------
foreach ($s in $Shortcuts) {
  if ($s.Desktop -and $NoDesktopShortcut) { if (Test-Path -LiteralPath $s.Path) { Remove-Item -LiteralPath $s.Path -Force }; continue }
  New-LauncherShortcut -Path $s.Path -Command (Get-LauncherCommand $Program $s.Mode) -WorkingDirectory $Program -Description $s.Description
  Say "Shortcut: $($s.Path)"
}

# --- Start with Windows ----------------------------------------------------------------------------------------------------------
$auto = Get-LauncherAutostart -ProgramPath $Program -StartupDir $StartupDir
if ($Autostart -or ($auto.enabled -and -not $NoAutostart)) { $auto = Set-LauncherAutostart -ProgramPath $Program -Enabled $true -StartupDir $StartupDir }
elseif ($NoAutostart) { $auto = Set-LauncherAutostart -ProgramPath $Program -Enabled $false -StartupDir $StartupDir }
$settings.autostart = [bool]$auto.enabled
Save-LauncherSettings $StateDir $settings
Write-LauncherLog -StateDir $StateDir -Source 'setup' -Message "Setup done: default '$($settings.defaultDeployment)', autostart $($auto.enabled), windowless $windowless."

# --- Summary -----------------------------------------------------------------------------------------------------------------
Say ''
if ($settings.defaultDeployment) { Say "Default deployment: $(if ($settings.defaultStackName) { $settings.defaultStackName } else { '(unnamed)' }) - $($settings.defaultDeployment)" 'Green' }
else { Say 'Default deployment: not set yet. The first start opens the chooser; select "Make default" on a deployment there.' 'Yellow' }
if ($auto.enabled) {
  Say "Start with Windows: on ($($auto.path))" 'Green'
  if (-not $auto.allowedByWindows) { Say 'Windows has this entry disabled in Task Manager > Startup apps; enable it there as well.' 'Yellow' }
} else { Say 'Start with Windows: off (turn it on with -Autostart, in the tray menu or on the Deployments page).' }
Say "Open the browser on manual start: $(if ($settings.openBrowserOnManualLaunch) { 'yes' } else { 'no' })"
Say "Bookmark: http://127.0.0.1:$($settings.port)/ (after you have opened the dashboard once from the tray, this browser stays signed in for $($settings.rememberDays) days)"
Say ''
Say "Start DTC: double-click '$AppName' on the desktop or in the Start menu." 'Cyan'

if ($Launch) {
  $c = Get-LauncherCommand $Program 'default'
  if ($c.Arguments) { Start-Process -FilePath $c.Target -ArgumentList $c.Arguments -WorkingDirectory $Program } else { Start-Process -FilePath $c.Target -WorkingDirectory $Program }
}
exit 0
