#requires -version 5.1
<#
.SYNOPSIS
  Starts the Deployment Manager website (webui.ps1) and opens it in your browser. Used by START-HERE.cmd.

.DESCRIPTION
  - Checks Windows PowerShell, the program files next to this script and (for information only) Docker Desktop.
    The website works without Docker; installing or managing containers needs it.
  - If the manager already runs for this Windows user, offers to open it again (or restart / stop it) instead of
    starting a second copy. Otherwise picks a free 127.0.0.1 port (8190 or the next free one) and starts it.
  - The sign-in link is never printed or passed on a command line by this script: webui.ps1 writes it to a file only
    this Windows user can read (%LOCALAPPDATA%\TraefikProxy\launch.url), and each link works once.
  - Runs until you close the window, press Ctrl+C, select "Stop the manager" in the website, or run STOP-MANAGER.cmd.
  - Needs no administrator rights. Paths are relative to this script, so it works from any extracted ZIP.

.EXAMPLE
  .\Start-DeploymentManager.ps1                 # start (or reopen) and open the browser
  .\Start-DeploymentManager.ps1 -Stop           # stop a running manager
  .\Start-DeploymentManager.ps1 -Restart
  .\Start-DeploymentManager.ps1 -Status
  .\Start-DeploymentManager.ps1 -InstallPath D:\proxy   # open one deployment directly (skip the chooser)
#>
[CmdletBinding()]
param(
  [ValidateRange(1024, 65535)][int]$Port = 8190,
  [string]$InstallPath,
  [switch]$NoBrowser,
  [switch]$Stop,
  [switch]$Restart,
  [switch]$Status,
  # What to do when the manager already runs: ask (interactive), open, restart or quit.
  [ValidateSet('ask', 'open', 'restart', 'quit')][string]$IfRunning = 'ask',
  # Tests: a separate state folder (default %LOCALAPPDATA%\TraefikProxy) and a projects folder to search.
  [string]$StateDir,
  [string]$ProjectsRoot,
  [string]$CloudflareApiBase
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'TraefikProxy' }
$managerFile = Join-Path $StateDir 'manager.json'
$launchFile = Join-Path $StateDir 'launch.url'
$stopFile = Join-Path $StateDir 'manager.stop'

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Fail([string]$Text, [int]$Code = 1) { Say ''; Say "Problem: $Text" 'Red'; exit $Code }

# --- Checks --------------------------------------------------------------------------------------------------------------

if ($PSVersionTable.PSVersion -lt [version]'5.1') { Fail "Windows PowerShell 5.1 or later is required (found $($PSVersionTable.PSVersion)). It is part of Windows 10 and 11." }
$required = @('webui.ps1', 'install.ps1', 'compose.yaml', 'lib\TraefikProxy.psm1', 'lib\CloudflareApi.psm1', 'lib\LocalHttp.psm1', 'lib\Dashboard.psm1', 'lib\ConfigBackup.psm1',
  'lib\ProjectDiscovery.psm1', 'lib\Infrastructure.psm1', 'lib\DockerDiscovery.psm1', 'lib\ServiceHealth.psm1', 'lib\AppCatalog.psm1',
  'webui\explorer.js', 'webui\brands.js', 'webui\discover.js', 'webui\catalog.js', 'catalog\apps\echo.json', 'webui\index.html', 'webui\app.js', 'webui\ui.js', 'webui\logic.js', 'webui\setup.js', 'webui\pages.js', 'webui\projects.js', 'webui\app.css', 'webui\learn.json')
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $here $_)) })
if ($missing.Count) { Fail ("These program files are missing next to Start-DeploymentManager.ps1: $($missing -join ', '). Extract the whole ZIP again (all folders) and start START-HERE.cmd from the extracted folder.") }

# Group Policy can force signed scripts; then nothing here can run unsigned, whatever the command line says.
$policies = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -in @('AllSigned', 'Restricted') })
if ($policies.Count) { Say "Note: your organization's policy requires signed scripts ($(@($policies | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', ')). If the manager does not start, ask your administrator or use a signed release." 'Yellow' }

function Read-ManagerInfo {
  if (-not (Test-Path -LiteralPath $managerFile)) { return $null }
  try { return [IO.File]::ReadAllText($managerFile) | ConvertFrom-Json } catch { return $null }
}

# True when a Deployment Manager answers on the port (its API says "not signed in" with its own JSON shape).
function Test-ManagerEndpoint([int]$P) {
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$P/api/session"); $req.Proxy = $null; $req.Timeout = 3000
    try { $res = $req.GetResponse() } catch [System.Net.WebException] { $res = $_.Exception.Response }
    if (-not $res) { return $false }
    $body = (New-Object IO.StreamReader($res.GetResponseStream())).ReadToEnd(); $res.Close()
    return ($body -match '"signedOut"\s*:\s*true')
  } catch { return $false }
}

function Get-RunningManager {
  $info = Read-ManagerInfo
  if (-not $info) { return $null }
  $proc = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
  if ($proc -and (Test-ManagerEndpoint ([int]$info.port))) { return $info }
  return $null
}

function Test-PortFree([int]$P) {
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $P)
  try { $l.ExclusiveAddressUse = $true; $l.Start(); return $true } catch { return $false } finally { try { $l.Stop() } catch { } }
}

function Open-ManagerInBrowser {
  if ($NoBrowser) { Say 'The manager is running. (-NoBrowser: not opening the browser.)'; return }
  if (-not (Test-Path -LiteralPath $launchFile)) { Say 'The sign-in link file is missing; restart the manager (Start-DeploymentManager.ps1 -Restart).' 'Yellow'; return }
  Start-Process ([IO.File]::ReadAllText($launchFile).Trim())
  Say 'Opened the Deployment Manager in your browser.' 'Green'
}

function Stop-Manager($Info) {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  [IO.File]::WriteAllText($stopFile, 'stop')
  # Poke the server so it notices the stop file at once.
  $c = New-Object System.Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', [int]$Info.port) } catch { } finally { $c.Close() }
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and (Get-Process -Id ([int]$Info.pid) -ErrorAction SilentlyContinue) -and (Test-ManagerEndpoint ([int]$Info.port))) { Start-Sleep -Milliseconds 300 }
  if (Test-ManagerEndpoint ([int]$Info.port)) { Fail "The manager on port $($Info.port) did not stop. Close its window (process $($Info.pid))." }
  Say "Stopped the Deployment Manager (port $($Info.port))." 'Green'
}

# --- Stop / status / already running ------------------------------------------------------------------------------------------

$running = Get-RunningManager
if ($Status) {
  if ($running) { Say "Running: http://127.0.0.1:$($running.port)/ (process $($running.pid), started $($running.startedAt), program $($running.sourcePath))" 'Green' } else { Say 'Not running.' }
  exit 0
}
if ($Stop) { if ($running) { Stop-Manager $running } else { Say 'The Deployment Manager is not running.' }; exit 0 }
if ($running) {
  $choice = if ($Restart) { 'restart' } else { $IfRunning }
  if ($choice -eq 'ask') {
    Say "The Deployment Manager is already running (port $($running.port), from $($running.sourcePath))." 'Cyan'
    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    $answer = if ($interactive) { Read-Host 'Open it again [O], restart it [R] or quit [Q]? (Enter = open)' } else { 'O' }
    $choice = switch -Regex ($answer) { '^[Rr]' { 'restart' } '^[Qq]' { 'quit' } default { 'open' } }
  }
  if ($choice -eq 'quit') { exit 0 }
  if ($choice -eq 'open') { Open-ManagerInBrowser; exit 0 }
  Stop-Manager $running
} elseif ($Restart) { Say 'The manager was not running; starting it.' }

# --- Start ----------------------------------------------------------------------------------------------------------------------

$chosen = $Port
if (-not (Test-PortFree $chosen)) {
  $chosen = @(($Port + 1)..($Port + 30) | Where-Object { Test-PortFree $_ })[0]
  if (-not $chosen) { Fail "Ports $Port-$($Port + 30) on 127.0.0.1 are all in use. Start with -Port <another port>." }
  Say "Port $Port is used by another program; using $chosen instead." 'Yellow'
}

Say 'Deployment Manager (Traefik + Cloudflare)' 'Cyan'
Say "Program folder: $here"
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { Say 'Docker Desktop: not found. The website opens anyway and explains how to install it.' 'Yellow' }
else {
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo.FileName = $docker.Source; $p.StartInfo.Arguments = 'info --format "{{.ServerVersion}}"'
  $p.StartInfo.UseShellExecute = $false; $p.StartInfo.RedirectStandardOutput = $true; $p.StartInfo.RedirectStandardError = $true; $p.StartInfo.CreateNoWindow = $true
  $null = $p.Start()
  if ($p.WaitForExit(15000) -and $p.ExitCode -eq 0) { Say "Docker Desktop: running (engine $($p.StandardOutput.ReadToEnd().Trim()))." 'Green' }
  else { try { $p.Kill() } catch { }; Say 'Docker Desktop: not running. The website opens anyway; start Docker Desktop before installing or managing containers.' 'Yellow' }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Remove-Item -LiteralPath $stopFile, $launchFile -Force -ErrorAction SilentlyContinue
# No secret in this file: process id, port and folders only.
[IO.File]::WriteAllText($managerFile, (ConvertTo-Json -Compress -InputObject ([ordered]@{ pid = $PID; port = $chosen; startedAt = (Get-Date -Format 's'); sourcePath = $here })))
Say "Starting on http://127.0.0.1:$chosen/ (this PC only). Keep this window open; close it or press Ctrl+C to stop."
$webArgs = @{ Port = $chosen; LaunchUrlFile = $launchFile; StopFile = $stopFile; SingleUseLaunch = $true; OpenBrowser = (-not $NoBrowser); StateFile = (Join-Path $StateDir 'webui.json') }
if ($InstallPath) { $webArgs['InstallPath'] = $InstallPath }
if ($ProjectsRoot) { $webArgs['ProjectsRoot'] = $ProjectsRoot }
if ($CloudflareApiBase) { $webArgs['CloudflareApiBase'] = $CloudflareApiBase }
$exitCode = 0
try {
  & (Join-Path $here 'webui.ps1') @webArgs
} catch {
  $exitCode = 1
  Say ''
  Say "The Deployment Manager stopped with an error: $($_.Exception.Message)" 'Red'
  Say 'If this keeps happening, run tests\Test-FirstRun.ps1 or open an issue with this message (it contains no secrets).'
} finally {
  $info = Read-ManagerInfo
  if ($info -and [int]$info.pid -eq $PID) { Remove-Item -LiteralPath $managerFile -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $launchFile, $stopFile -Force -ErrorAction SilentlyContinue
}
exit $exitCode
