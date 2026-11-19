#requires -version 5.1
<#
.SYNOPSIS
  DTC launcher and startup: settings, start modes, remembered browsers, autostart, shortcuts, the tray app and DTC.exe.

.DESCRIPTION
  Everything runs in a temporary folder: its own launcher state folder, Startup / desktop / Start menu folders, two
  never-started test deployments and a Cloudflare API mock. Your real %LOCALAPPDATA%\TraefikProxy, Startup folder,
  desktop, Start menu, deployments and containers are not touched; Docker is only read (container ids and start times
  before and after, to prove that switching or changing the default deployment never restarts anything).

  Sections: module (no processes) / Start-DeploymentManager.ps1 -Background (default, choose, recovery, missing default,
  duplicate start, port conflict, start failure, remembered browsers, settings API) / Install-Launcher.ps1 / the tray app
  end to end through the real launcher\DTC.exe (built here, git-ignored) / the Deployments page in headless Edge.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Launcher.ps1
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Launcher.ps1 -SkipBrowser -SkipTray
#>
[CmdletBinding()]
param([switch]$SkipTray, [switch]$SkipBrowser, [switch]$KeepFiles)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\Launcher.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\EdgeCdp.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Short($r) { if ($null -eq $r) { return '(no response)' }; return "HTTP $($r.Status) $($r.Body.Substring(0, [Math]::Min(400, $r.Body.Length)))" }
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 60) { $d = (Get-Date).AddSeconds($Seconds); while ((Get-Date) -lt $d) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 300 }; return [bool](& $Condition) }
function Get-FolderSnapshot([string]$Path) { return (@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) -join "`n") }
function Read-Log([string]$StateDir) { return (Read-LauncherText (Get-LauncherFiles $StateDir).LauncherLog) }

# Container ids, start times and restart counts: unchanged means nothing was started, stopped or recreated.
$script:DockerOk = $false
function Get-DockerSnapshot {
  if (-not $script:DockerOk) { return '' }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $ids = @(& docker ps -a -q 2>$null)
    if (-not $ids.Count) { return '(none)' }
    return ((@(& docker inspect -f '{{.Id}} {{.State.StartedAt}} {{.RestartCount}} {{.State.Status}}' @ids 2>$null) | Sort-Object) -join "`n")
  } finally { $ErrorActionPreference = $prev }
}

# Start-DeploymentManager.ps1 the way the tray starts it (hidden, -Background, output to the manager log).
function Start-Manager([string]$StateDir, [string]$Mode, [string[]]$More = @(), [switch]$NoWait) {
  $files = Get-LauncherFiles $StateDir
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $repo 'Start-DeploymentManager.ps1')`"", '-Background', '-NoBrowser', '-StateDir', "`"$StateDir`"",
    '-LogFile', "`"$($files.ManagerLog)`"", '-ProjectsRoot', "`"$root`"", '-CloudflareApiBase', $mock.Base, '-StartupDir', "`"$startup`"")
  if ($Mode) { $a += @('-StartMode', $Mode) }
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList ($a + $More)
  $null = $p.Handle
  $null = $script:Processes.Add($p)
  if ($NoWait) { return [pscustomobject]@{ Process = $p; Info = $null } }
  $null = Wait-Until { (Get-RunningManager $StateDir) -or $p.HasExited } 60
  return [pscustomobject]@{ Process = $p; Info = (Get-RunningManager $StateDir) }
}
function Stop-Manager([string]$StateDir) { $i = Get-RunningManager $StateDir; if ($i) { $null = Stop-RunningManager -StateDir $StateDir -Info $i -TimeoutSeconds 20 -Kill } }
# Signs in like a browser following the launch link from the tray. Returns a server object for Invoke-WebUi.
function Connect-Manager([string]$StateDir) {
  $info = Get-RunningManager $StateDir
  $null = Wait-Until { Get-ManagerLaunchUrl $StateDir '' } 15
  $server = [pscustomobject]@{ Port = [int]$info.port; LaunchUrl = (Get-ManagerLaunchUrl $StateDir ''); Cookie = ''; Csrf = ''; Bodies = (New-Object System.Collections.ArrayList); SetCookie = '' }
  $r = Connect-WebUi $server
  $server.SetCookie = [string]$r.Headers['set-cookie']
  return $server
}
function Get-TrayProcesses([string]$StateDir) {
  return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { [string]$_.CommandLine -match 'DTC-Tray\.ps1' -and [string]$_.CommandLine -like "*$StateDir*" })
}

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpx-launcher-$id"
$root = Join-Path $work 'projects'
$startup = Join-Path $work 'Startup'
$pathA = Join-Path $root 'alpha'; $pathB = Join-Path $root 'beta'; $gone = Join-Path $root 'gone'; $plain = Join-Path $root 'plain'
$stackA = "tpx-ln-a-$id"; $stackB = "tpx-ln-b-$id"
New-Item -ItemType Directory -Force -Path $work, $root, $startup, $plain | Out-Null
$script:Processes = New-Object System.Collections.ArrayList
$mock = $null; $cdp = $null; $listeners = New-Object System.Collections.ArrayList
$exeBuilt = $false
$autoPath = Join-Path $startup ((Get-LauncherAppName (Get-LauncherEdition $repo)) + '.lnk')

try {
  $null = New-TestInstance -Repo $repo -Path $pathA -StackName $stackA -Subnet '172.31.238.0/28'
  $null = New-TestInstance -Repo $repo -Path $pathB -StackName $stackB -Subnet '172.31.238.16/28'
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token ('mockTok_' + [Guid]::NewGuid().ToString('N'))
  $script:DockerOk = ((Test-DockerReady 15000) -eq 'ready')
  $dockerBefore = Get-DockerSnapshot
  $snapA = Get-FolderSnapshot $pathA; $snapB = Get-FolderSnapshot $pathB

  # --- Module ------------------------------------------------------------------------------------------------------------
  $ed = Join-Path $work 'editions'
  New-Item -ItemType Directory -Force -Path "$ed\dev\.git", "$ed\installed", "$ed\package" | Out-Null
  [IO.File]::WriteAllText("$ed\installed\.install-manifest.json", '{}')
  Test-Condition 'edition: git checkout = development, install manifest = installed, else package' ((Get-LauncherEdition "$ed\dev") -eq 'development' -and (Get-LauncherEdition "$ed\installed") -eq 'installed' -and (Get-LauncherEdition "$ed\package") -eq 'package')
  $devState = Get-LauncherStateDir "$ed\dev"
  Test-Condition 'state folder: installed = %LOCALAPPDATA%\TraefikProxy, development = its own folder outside it' ((Get-LauncherStateDir "$ed\installed") -eq (Get-LauncherBaseDir) -and $devState -like "$(Get-LauncherBaseDir)-dev\dev-*" -and $devState -notlike "$(Get-LauncherBaseDir)\*" -and $devState -ne (Get-LauncherStateDir "$ed\package")) $devState
  Test-Condition 'default port: 8190 installed, 8290 development (both can run)' ((Get-LauncherDefaultPort 'installed') -eq 8190 -and (Get-LauncherDefaultPort 'development') -eq 8290)

  $st = Join-Path $work 'state-unit'
  $s = Read-LauncherSettings $st $repo
  Test-Condition 'settings: defaults without a file (browser on manual start, 300 s Docker wait, remember 30 days, autostart off)' ($s.openBrowserOnManualLaunch -and $s.dockerWaitSeconds -eq 300 -and $s.rememberBrowser -and $s.rememberDays -eq 30 -and -not $s.autostart -and -not $s.defaultDeployment -and -not $s.problem)
  $s.defaultDeployment = $pathA; $s.openBrowserOnManualLaunch = $false; $s.port = 18190
  Save-LauncherSettings $st $s
  $s2 = Read-LauncherSettings $st $repo
  Test-Condition 'settings: saved and read back' ($s2.defaultDeployment -eq $pathA -and -not $s2.openBrowserOnManualLaunch -and $s2.port -eq 18190 -and $s2.updatedAt)
  [IO.File]::WriteAllText((Get-LauncherFiles $st).Settings, '{"port": 80, "defaultDeployment": "relative\\x", "autostart": "yes", "rememberDays": 0}')
  $s3 = Read-LauncherSettings $st $repo
  Test-Condition 'settings: invalid values fall back to defaults' ($s3.port -eq (Get-LauncherDefaultPort (Get-LauncherEdition $repo)) -and $s3.defaultDeployment -eq '' -and $s3.autostart -eq $false -and $s3.rememberDays -eq 30)
  [IO.File]::WriteAllText((Get-LauncherFiles $st).Settings, '{ not json')
  $s4 = Read-LauncherSettings $st $repo
  Test-Condition 'settings: a damaged file is reported, defaults are used, the file is left as it was' ($s4.problem -and ([IO.File]::ReadAllText((Get-LauncherFiles $st).Settings)) -eq '{ not json')

  $dA = Get-LauncherDeployment $pathA
  Test-Condition 'deployment check: an installed deployment with its stack name' ($dA.usable -and $dA.kind -eq 'manager' -and $dA.stackName -eq $stackA) "$($dA.kind) $($dA.stackName)"
  Test-Condition 'deployment check: missing, not a deployment, relative path' ((Get-LauncherDeployment $gone).kind -eq 'missing' -and (Get-LauncherDeployment $plain).kind -eq 'other' -and (Get-LauncherDeployment 'x\y').kind -eq 'invalid')

  $set = Get-LauncherDefaults $repo; $set.defaultDeployment = $pathA
  $r = Resolve-LauncherStart $set 'default'
  Test-Condition 'start plan: default opens the saved deployment without the chooser' ($r.installPath -eq $pathA -and -not $r.chooser -and $r.stackName -eq $stackA -and -not $r.notice)
  $set.defaultDeployment = $gone
  $r = Resolve-LauncherStart $set 'default'
  Test-Condition 'start plan: a missing default opens the chooser with a warning and keeps the default' ($r.chooser -and -not $r.installPath -and $r.level -eq 'warn' -and $r.notice -match 'was not found' -and $set.defaultDeployment -eq $gone)
  $set.defaultDeployment = ''
  $r = Resolve-LauncherStart $set 'default'
  Test-Condition 'start plan: no default yet opens the chooser with a hint' ($r.chooser -and $r.notice -match 'Make default')
  $set.defaultDeployment = $pathA
  $rc = Resolve-LauncherStart $set 'choose'; $rr = Resolve-LauncherStart $set 'recovery'
  Test-Condition 'start plan: choose and recovery never open a deployment' ($rc.chooser -and -not $rc.installPath -and $rr.chooser -and -not $rr.installPath -and $rr.notice -match 'Recovery mode')
  $threw = $false; try { $null = Resolve-LauncherStart $set 'other' } catch { $threw = $true }
  Test-Condition 'start plan: an unknown mode is refused' $threw

  New-Item -ItemType Directory -Force -Path $st | Out-Null
  [IO.File]::WriteAllText((Get-LauncherFiles $st).WebState, (ConvertTo-Json @{ installPath = $pathA }))
  $seed = Find-LauncherSeedDeployment $st
  Test-Condition 'seed: the deployment the manager opened last becomes the first default' ($seed -and $seed.path -eq $pathA)

  $secret = 'Z' * 43
  Write-LauncherLog -StateDir $st -Source 'test' -Level 'WARN' -Message "open http://127.0.0.1:8190/?k=$secret token=abc123 cookie tpx_session_8190=sid123 Bearer eyJhbGciOi.x.y"
  $log = Read-Log $st
  Test-Condition 'log: written with level and source, secrets redacted' ($log -match 'WARN  \[test\]' -and $log -notmatch $secret -and $log -notmatch 'abc123' -and $log -notmatch 'sid123' -and $log -notmatch 'eyJhbGciOi' -and $log -match '\?k=\[redacted\]')
  [IO.File]::WriteAllText((Get-LauncherFiles $st).LauncherLog, ('x' * 1100000))
  Write-LauncherLog -StateDir $st -Message 'after rotation'
  Test-Condition 'log: rotated at 1 MB' ((Test-Path -LiteralPath ((Get-LauncherFiles $st).LauncherLog + '.1')) -and (Get-Item -LiteralPath (Get-LauncherFiles $st).LauncherLog).Length -lt 1000)

  Send-TrayCommand $st 'choose'
  $c1 = Receive-TrayCommand $st; $c2 = Receive-TrayCommand $st
  [IO.File]::WriteAllText((Get-LauncherFiles $st).Command, 'format c:')
  $c3 = Receive-TrayCommand $st
  Test-Condition 'tray commands: delivered once; unknown commands ignored' ($c1 -eq 'choose' -and $null -eq $c2 -and $null -eq $c3)
  Test-Condition 'single instance: one mutex per state folder' ((Get-LauncherMutexName $st) -eq (Get-LauncherMutexName "$st\") -and (Get-LauncherMutexName $st) -ne (Get-LauncherMutexName $work) -and (Get-LauncherMutexName $st) -like 'Local\DTC-Tray-*')

  $ico = Join-Path $work 'icon\DTC.ico'
  New-LauncherIconFile -Path $ico
  $b = [IO.File]::ReadAllBytes($ico)
  Test-Condition 'icon: a valid multi-size .ico' ($b[0] -eq 0 -and $b[2] -eq 1 -and [BitConverter]::ToUInt16($b, 4) -eq 6)

  $exe = $null
  try { $exe = New-LauncherExe -ProgramPath $repo -Force; $exeBuilt = $true } catch { Add-Result 'FAIL' 'DTC.exe: built' $_.Exception.Message }
  if ($exe) { Test-Condition 'DTC.exe: built locally as a Windows (GUI) program, so no console window opens' ((Get-PeSubsystem $exe) -eq 2 -and (Test-Path -LiteralPath (Get-LauncherIconPath $repo))) }

  $autoPath = Get-AutostartShortcutPath (Get-LauncherEdition $repo) $startup
  $a = Set-LauncherAutostart -ProgramPath $repo -Enabled $true -StartupDir $startup
  $lnk = Read-LauncherShortcut $autoPath
  Test-Condition 'autostart: a per-user Startup-folder shortcut to DTC.exe -Autostart' ($a.enabled -and $a.pointsHere -and $a.windowless -and $lnk.Target -eq (Get-LauncherExePath $repo) -and $lnk.Arguments -eq '-Autostart' -and (Split-Path -Leaf $autoPath) -match '\(development\)\.lnk$') "$($lnk.Target) $($lnk.Arguments)"
  $a = Set-LauncherAutostart -ProgramPath $repo -Enabled $false -StartupDir $startup
  Test-Condition 'autostart: turned off removes the shortcut' (-not $a.enabled -and -not (Test-Path -LiteralPath $autoPath))
  Test-Condition 'autostart: no registry Run entry, no scheduled task is used' (-not (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty | Where-Object { $_.Name -match 'DTC' }))

  # --- Start-DeploymentManager.ps1 -Background ---------------------------------------------------------------------------------
  $state = Join-Path $work 'state'
  $port = Get-FreeTcpPort
  $set = Get-LauncherDefaults $repo; $set.defaultDeployment = $pathA; $set.defaultStackName = $stackA; $set.port = $port
  Save-LauncherSettings $state $set

  $m = Start-Manager $state 'default'
  Test-Condition 'default mode: the manager starts in the background on the saved port' ($m.Info -and [int]$m.Info.port -eq $port) "exited=$($m.Process.HasExited)"
  $ui = Connect-Manager $state
  $sess = Invoke-WebUi $ui GET '/api/session'
  Test-Condition 'default mode: the saved default deployment is open (no chooser, no question)' ($sess.Data.chosen -and $sess.Data.installPath -eq $pathA -and $sess.Data.startMode -eq 'default' -and $sess.Data.launcher -and $sess.Data.remembered) (Short $sess)
  Test-Condition 'remembered browser: the sign-in cookie lasts 30 days (bookmark keeps working)' ($ui.SetCookie -match 'Max-Age=2592000' -and $ui.SetCookie -match 'HttpOnly' -and $ui.SetCookie -match 'SameSite=Strict') $ui.SetCookie
  $sid = $ui.Cookie.Split('=', 2)[1]
  $sessText = [IO.File]::ReadAllText((Get-LauncherFiles $state).Sessions)
  $acl = (& icacls (Get-LauncherFiles $state).Sessions) -join ' '
  Test-Condition 'remembered browser: only a hash of the cookie is stored, readable by this user only' ($sessText -match (Get-TextSha256 $sid) -and $sessText -notmatch [regex]::Escape($sid) -and $acl -notmatch 'BUILTIN\\Users|Everyone|Authenticated Users')
  $mlog = (Get-LauncherFiles $state).ManagerLog
  Test-Condition 'manager log: written to disk, without the sign-in link' ((Test-Path -LiteralPath $mlog) -and (Read-LauncherText $mlog) -notmatch '\?k=[A-Za-z0-9_-]{20}')

  $to = Get-ManagerLaunchUrl $state 'projects'
  $r1 = Invoke-RawHttp -Port $port -Path ([Uri]$to).PathAndQuery
  $bad = (Get-ManagerLaunchUrl $state '') + '&to=//evil.example'
  $r2 = Invoke-RawHttp -Port $port -Path ([Uri]$bad).PathAndQuery
  Test-Condition 'launch link: opens a page after sign-in (Choose Deployment) and accepts page names only' ($r1.Status -eq 303 -and $r1.Headers['location'] -eq '/#projects' -and $r2.Status -eq 303 -and $r2.Headers['location'] -eq '/') "$($r1.Headers['location']) / $($r2.Headers['location'])"

  $l = Invoke-WebUi $ui GET '/api/launcher'
  Test-Condition 'startup settings: reported to the website (default, bookmark, autostart, edition)' ($l.Data.available -and $l.Data.defaultDeployment.usable -and $l.Data.defaultDeployment.stackName -eq $stackA -and $l.Data.bookmarkUrl -eq "http://127.0.0.1:$port/" -and $l.Data.edition -eq 'development' -and -not $l.Data.autostart.enabled) (Short $l)

  $pidBefore = [int](Get-ManagerRecord $state).pid
  $dup = Start-Manager $state 'default' -NoWait
  $null = $dup.Process.WaitForExit(30000)
  Test-Condition 'duplicate start: a second start reuses the running manager and exits' ($dup.Process.HasExited -and $dup.Process.ExitCode -eq 0 -and [int](Get-ManagerRecord $state).pid -eq $pidBefore -and (Get-RunningManager $state)) "exit=$($dup.Process.ExitCode)"

  $x = Invoke-WebUi $ui POST '/api/launcher/settings' @{ openBrowserOnManualLaunch = $false }
  Test-Condition 'settings API: open browser on manual start saved' ($x.Status -eq 200 -and -not (Read-LauncherSettings $state $repo).openBrowserOnManualLaunch) (Short $x)
  $x = Invoke-WebUi $ui POST '/api/launcher/settings' @{ autostart = 'yes' }
  $y = Invoke-WebUi $ui POST '/api/launcher/settings' @{ defaultDeployment = $plain }
  Test-Condition 'settings API: wrong types and non-deployments are refused; the default is unchanged' ($x.Status -eq 400 -and $y.Status -eq 409 -and (Read-LauncherSettings $state $repo).defaultDeployment -eq $pathA) "$(Short $x) / $(Short $y)"
  $x = Invoke-WebUi $ui POST '/api/launcher/settings' @{ autostart = $true }
  Test-Condition 'settings API: Start with Windows on creates the Startup shortcut' ($x.Status -eq 200 -and $x.Data.autostart.enabled -and $x.Data.autostart.pointsHere -and (Test-Path -LiteralPath $autoPath) -and (Read-LauncherSettings $state $repo).autostart) (Short $x)
  $x = Invoke-WebUi $ui POST '/api/launcher/settings' @{ autostart = $false }
  Test-Condition 'settings API: Start with Windows off removes it' ($x.Status -eq 200 -and -not (Test-Path -LiteralPath $autoPath)) (Short $x)
  $nx = Invoke-RawHttp -Port $port -Method POST -Path '/api/launcher/settings' -Headers @{ 'Content-Type' = 'application/json'; Origin = "http://127.0.0.1:$port" } -Body '{"autostart":true}'
  Test-Condition 'settings API: needs a signed-in browser and its CSRF token' ($nx.Status -eq 401 -and -not (Test-Path -LiteralPath $autoPath))

  # Switch deployment and change the default: settings and a read-only open, never a container change.
  $att = Invoke-WebUi $ui POST '/api/projects/attach' @{ path = $pathB }
  $md = Invoke-WebUi $ui POST '/api/launcher/settings' @{ defaultDeployment = $pathB }
  Test-Condition 'switch deployment and make it the default' ($att.Status -eq 200 -and $md.Status -eq 200 -and (Read-LauncherSettings $state $repo).defaultDeployment -eq $pathB -and $md.Data.defaultDeployment.stackName -eq $stackB) "$(Short $att) / $(Short $md)"
  if ($script:DockerOk) { Test-Condition 'switching and changing the default left every container as it was (ids, start times, restarts)' ((Get-DockerSnapshot) -eq $dockerBefore) }
  else { Add-Result 'SKIP' 'containers unchanged' 'Docker is not running' }
  Test-Condition 'switching and changing the default wrote nothing into either deployment folder' ((Get-FolderSnapshot $pathA) -eq $snapA -and (Get-FolderSnapshot $pathB) -eq $snapB)

  # Restart: the remembered browser stays signed in; the new default opens.
  Stop-Manager $state
  Test-Condition 'stop: the website stops (stop file), its records are removed' (-not (Get-RunningManager $state) -and -not (Test-Path -LiteralPath (Get-LauncherFiles $state).Manager))
  $m = Start-Manager $state 'default'
  $again = Invoke-WebUi $ui GET '/api/session'
  Test-Condition 'restart: the bookmarked browser is still signed in, with a new CSRF token, and the new default is open' ($again.Status -eq 200 -and $again.Data.installPath -eq $pathB -and $again.Data.csrf -and $again.Data.csrf -ne $ui.Csrf) (Short $again)
  $ui.Csrf = $again.Data.csrf
  $so = Invoke-WebUi $ui POST '/api/session/signout' @{}
  $after = Invoke-WebUi $ui GET '/api/session'
  Test-Condition 'sign out this browser: the cookie stops working and its hash is removed' ($so.Status -eq 200 -and $so.Headers['set-cookie'] -match 'Max-Age=0' -and $after.Status -eq 401 -and ([IO.File]::ReadAllText((Get-LauncherFiles $state).Sessions)) -notmatch (Get-TextSha256 $sid)) "$(Short $so) / $(Short $after)"
  Stop-Manager $state

  # Missing default deployment.
  $set = Read-LauncherSettings $state $repo; $set.defaultDeployment = $gone; Save-LauncherSettings $state $set
  $m = Start-Manager $state 'default'
  $ui = Connect-Manager $state
  $sess = Invoke-WebUi $ui GET '/api/session'; $l = Invoke-WebUi $ui GET '/api/launcher'
  Test-Condition 'missing default: starts on the chooser with a notice; the default is kept' ($sess.Data.chosen -eq $false -and $l.Data.notice -match 'was not found' -and $l.Data.defaultDeployment.kind -eq 'missing' -and (Read-LauncherSettings $state $repo).defaultDeployment -eq $gone) (Short $l)
  Test-Condition 'missing default: logged as a warning' ((Read-Log $state) -match 'WARN  \[manager\] Start mode default')
  Stop-Manager $state

  # Recovery and choose.
  $set = Read-LauncherSettings $state $repo; $set.defaultDeployment = $pathA; Save-LauncherSettings $state $set
  $m = Start-Manager $state 'recovery'
  $ui = Connect-Manager $state
  $sess = Invoke-WebUi $ui GET '/api/session'; $l = Invoke-WebUi $ui GET '/api/launcher'
  $blocked = Invoke-WebUi $ui POST '/api/services/plan' @{ services = @() }
  Test-Condition 'recovery mode: no deployment is opened, and changes are refused until one is chosen' ($sess.Data.chosen -eq $false -and $sess.Data.startMode -eq 'recovery' -and $l.Data.notice -match 'Recovery mode' -and $blocked.Status -eq 409) "$(Short $sess) / $(Short $blocked)"
  Stop-Manager $state
  $m = Start-Manager $state 'choose'
  $ui = Connect-Manager $state
  $sess = Invoke-WebUi $ui GET '/api/session'
  Test-Condition 'choose mode: starts on the chooser even with a default' ($sess.Data.chosen -eq $false -and $sess.Data.startMode -eq 'choose') (Short $sess)
  Stop-Manager $state

  # Port conflict: the preferred port is taken by another program.
  $blocker = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port); $blocker.Start(); $null = $listeners.Add($blocker)
  $m = Start-Manager $state 'default'
  $ui = $null
  if ($m.Info) { $ui = Connect-Manager $state; $l = Invoke-WebUi $ui GET '/api/launcher' }
  Test-Condition 'port conflict: runs on the next free port and says so' ($m.Info -and [int]$m.Info.port -ne $port -and $l.Data.preferredPort -eq $port -and $l.Data.port -eq [int]$m.Info.port -and $l.Data.notice -match "Port $port is used by another program") "$(if ($m.Info) { $m.Info.port })"
  Test-Condition 'port conflict: logged' ((Read-Log $state) -match "WARN  \[manager\] Port $port is used")
  Stop-Manager $state

  # Start failure: every port in the range is taken.
  for ($p = $port + 1; $p -le $port + 30; $p++) { try { $t = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p); $t.Start(); $null = $listeners.Add($t) } catch { } }
  $m = Start-Manager $state 'default' -NoWait
  $null = $m.Process.WaitForExit(60000)
  Test-Condition 'start failure: exits with an error that is logged to disk' ($m.Process.HasExited -and $m.Process.ExitCode -ne 0 -and (Read-Log $state) -match 'ERROR \[manager\] Ports \d+-\d+ on 127\.0\.0\.1 are all in use') "exit=$($m.Process.ExitCode)"

  # --- Install-Launcher.ps1 ------------------------------------------------------------------------------------------------------
  $ist = Join-Path $work 'state-setup'; $desk = Join-Path $work 'Desktop'; $menu = Join-Path $work 'StartMenu'
  $setupArgs = @('-StateDir', $ist, '-DesktopDir', $desk, '-StartMenuDir', $menu, '-StartupDir', $startup)
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'launcher\Install-Launcher.ps1') @setupArgs -DefaultDeployment $pathA -Autostart -OpenBrowser no 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  $menuDir = Join-Path $menu 'DTC Deployment Manager (development)'
  $main = Read-LauncherShortcut (Join-Path $desk 'DTC Deployment Manager (development).lnk')
  $choose = Read-LauncherShortcut (Join-Path $menuDir 'DTC - Choose deployment (development).lnk')
  $recov = Read-LauncherShortcut (Join-Path $menuDir 'DTC - Recovery mode (development).lnk')
  $menuMain = Read-LauncherShortcut (Join-Path $menuDir 'DTC Deployment Manager (development).lnk')
  $exePath = Get-LauncherExePath $repo
  Test-Condition 'setup: shortcuts for normal start, deployment selection and recovery (desktop + Start menu)' ($code -eq 0 -and $main -and $menuMain -and $main.Target -eq $exePath -and $main.Arguments -eq '' -and $choose.Arguments -eq '-Mode choose' -and $recov.Arguments -eq '-Mode recovery' -and $main.WorkingDirectory -eq $repo) (($out | Select-Object -Last 6) -join ' | ')
  $is = Read-LauncherSettings $ist $repo
  Test-Condition 'setup: default deployment, autostart and browser preference saved; installation path recorded' ($is.defaultDeployment -eq $pathA -and $is.defaultStackName -eq $stackA -and $is.autostart -and -not $is.openBrowserOnManualLaunch -and $is.programPath -eq $repo -and (Read-LauncherShortcut $autoPath).Arguments -eq '-Autostart')
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'launcher\Install-Launcher.ps1') @setupArgs -DefaultDeployment $plain 2>&1 | ForEach-Object { "$_" }
  Test-Condition 'setup: a folder that is not a deployment is refused as the default' ($LASTEXITCODE -ne 0 -and (Read-LauncherSettings $ist $repo).defaultDeployment -eq $pathA)
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'launcher\Install-Launcher.ps1') @setupArgs -NoAutostart 2>&1
  Test-Condition 'setup: -NoAutostart turns Start with Windows off again' ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $autoPath) -and -not (Read-LauncherSettings $ist $repo).autostart -and (Read-LauncherSettings $ist $repo).defaultDeployment -eq $pathA)
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'launcher\Install-Launcher.ps1') @setupArgs -Uninstall 2>&1
  Test-Condition 'setup: -Uninstall removes the shortcuts and keeps the settings' ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $desk 'DTC Deployment Manager (development).lnk')) -and -not (Test-Path -LiteralPath $menuDir) -and (Read-LauncherSettings $ist $repo).defaultDeployment -eq $pathA)
  $seedState = Join-Path $work 'state-seed'
  New-Item -ItemType Directory -Force -Path $seedState | Out-Null
  [IO.File]::WriteAllText((Get-LauncherFiles $seedState).WebState, (ConvertTo-Json @{ installPath = $pathB }))
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'launcher\Install-Launcher.ps1') -StateDir $seedState -DesktopDir $desk -StartMenuDir $menu -StartupDir $startup -NoDesktopShortcut 2>&1
  Test-Condition 'setup: without -DefaultDeployment the deployment opened last becomes the default' ($LASTEXITCODE -eq 0 -and (Read-LauncherSettings $seedState $repo).defaultDeployment -eq $pathB -and -not (Test-Path -LiteralPath (Join-Path $desk 'DTC Deployment Manager (development).lnk')))
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'launcher\Install-Launcher.ps1') -StateDir $seedState -DesktopDir $desk -StartMenuDir $menu -StartupDir $startup -Uninstall 2>&1

  # --- Tray app through DTC.exe -----------------------------------------------------------------------------------------------
  foreach ($t in $listeners) { try { $t.Stop() } catch { } }; $listeners.Clear()
  if ($SkipTray) { Add-Result 'SKIP' 'tray app' '-SkipTray' }
  elseif (-not $exeBuilt) { Add-Result 'SKIP' 'tray app' 'DTC.exe was not built' }
  else {
    $tst = Join-Path $work 'state-tray'
    $tport = Get-FreeTcpPort
    $set = Get-LauncherDefaults $repo; $set.defaultDeployment = $pathA; $set.port = $tport; $set.openBrowserOnManualLaunch = $false; $set.dockerWaitSeconds = 0
    Save-LauncherSettings $tst $set
    $trayArgs = @('-StateDir', "`"$tst`"", '-StartupDir', "`"$startup`"", '-NoBrowser')
    $e = Start-Process -FilePath $exePath -PassThru -ArgumentList $trayArgs
    $null = $e.WaitForExit(15000)
    $up = Wait-Until { Get-RunningManager $tst } 90
    $trays = @(Get-TrayProcesses $tst)
    Test-Condition 'DTC.exe: starts the tray and exits; the manager comes up with the default deployment' ($e.HasExited -and $e.ExitCode -eq 0 -and $up -and $trays.Count -eq 1) "exe exit=$($e.ExitCode) trays=$($trays.Count)"
    if ($up) {
      $mi = Get-RunningManager $tst
      $windows = @(@($trays | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }) + @(Get-Process -Id ([int]$mi.pid) -ErrorAction SilentlyContinue) | Where-Object { $_ -and $_.MainWindowHandle -ne [IntPtr]::Zero })
      Test-Condition 'no window: neither the tray nor the manager has a console or other window' ($windows.Count -eq 0) "$($windows.Count) window(s)"
      $ui = Connect-Manager $tst
      $sess = Invoke-WebUi $ui GET '/api/session'
      Test-Condition 'tray: default mode opened the saved deployment' ($sess.Data.installPath -eq $pathA -and $sess.Data.chosen) (Short $sess)
      $e2 = Start-Process -FilePath $exePath -PassThru -ArgumentList (@('-Mode', 'choose') + $trayArgs)
      $null = $e2.WaitForExit(15000)
      $handed = Wait-Until { (Read-Log $tst) -match 'Request from another launch: choose' } 30
      Test-Condition 'second launch: handed to the running tray (one tray, same manager)' ($handed -and @(Get-TrayProcesses $tst).Count -eq 1 -and [int](Get-RunningManager $tst).pid -eq [int]$mi.pid -and (Read-Log $tst) -match 'Another tray already runs')
      $before = Get-DockerSnapshot
      Send-TrayCommand $tst 'restart'
      $restarted = Wait-Until { $r = Get-RunningManager $tst; $r -and [int]$r.pid -ne [int]$mi.pid } 90
      Test-Condition 'Restart Manager: a new manager process, same port' ($restarted -and [int](Get-RunningManager $tst).port -eq $tport)
      Send-TrayCommand $tst 'recovery'
      $rec = Wait-Until { (Read-Log $tst) -match 'Starting the manager \(recovery' -and (Get-RunningManager $tst) } 90
      $ok = $false
      if ($rec) { $null = Wait-Until { Get-ManagerLaunchUrl $tst '' } 15; $u2 = Connect-Manager $tst; $s2 = Invoke-WebUi $u2 GET '/api/session'; $ok = ($s2.Data.chosen -eq $false -and $s2.Data.startMode -eq 'recovery') }
      Test-Condition 'Restart in Recovery Mode: no deployment open' $ok
      if ($script:DockerOk) { Test-Condition 'restarts from the tray left every container as it was' ((Get-DockerSnapshot) -eq $before) }
      Send-TrayCommand $tst 'exit'
      $gone2 = Wait-Until { @(Get-TrayProcesses $tst).Count -eq 0 -and -not (Get-RunningManager $tst) } 40
      Test-Condition 'Exit: the tray closes and stops the manager it started' ($gone2 -and -not (Test-Path -LiteralPath (Get-LauncherFiles $tst).Manager))
    }

    # Start with Windows: waits for Docker Desktop, then starts without a browser.
    $set = Read-LauncherSettings $tst $repo; $set.dockerWaitSeconds = 20; Save-LauncherSettings $tst $set
    $e3 = Start-Process -FilePath $exePath -PassThru -ArgumentList (@('-Autostart') + $trayArgs)
    $null = $e3.WaitForExit(15000)
    $up = Wait-Until { Get-RunningManager $tst } 90
    $tlog = Read-Log $tst
    Test-Condition 'autostart: waits for Docker Desktop, then starts the manager silently' ($up -and $tlog -match 'Waiting up to 20 s for Docker Desktop' -and ($tlog -match 'Docker Desktop is ready' -or $tlog -match 'did not become ready' -or $tlog -match 'Docker is not installed')) ((@($tlog -split "`n") | Select-Object -Last 4) -join ' | ')
    $autoNoBrowser = -not ((@($tlog -split "`n") | Select-Object -Last 8) -join "`n" -match 'Would open the dashboard')
    Test-Condition 'autostart: no browser is opened' $autoNoBrowser
    Send-TrayCommand $tst 'exit'
    $null = Wait-Until { @(Get-TrayProcesses $tst).Count -eq 0 } 40

    # A manager that cannot start: the tray stays, shows the error and logs it.
    $blk = New-Object System.Collections.ArrayList
    for ($p = $tport; $p -le $tport + 30; $p++) { try { $t = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p); $t.Start(); $null = $blk.Add($t) } catch { } }
    $set = Read-LauncherSettings $tst $repo; $set.dockerWaitSeconds = 0; Save-LauncherSettings $tst $set
    $e4 = Start-Process -FilePath $exePath -PassThru -ArgumentList $trayArgs
    $failed = Wait-Until { (Read-Log $tst) -match 'ERROR \[tray\] The manager did not start' } 90
    Test-Condition 'tray: a start failure is logged and the tray keeps running (Restart Manager / Open Log Folder)' ($failed -and @(Get-TrayProcesses $tst).Count -eq 1)
    Send-TrayCommand $tst 'exit'
    $null = Wait-Until { @(Get-TrayProcesses $tst).Count -eq 0 } 40
    foreach ($t in $blk) { try { $t.Stop() } catch { } }
  }

  # --- Deployments page in headless Edge -----------------------------------------------------------------------------------------
  if ($SkipBrowser) { Add-Result 'SKIP' 'browser' '-SkipBrowser' }
  elseif (-not (Get-EdgePath)) { Add-Result 'SKIP' 'browser' 'Microsoft Edge not found' }
  else {
    $bst = Join-Path $work 'state-browser'
    $set = Get-LauncherDefaults $repo; $set.defaultDeployment = $pathA; $set.port = (Get-FreeTcpPort); Save-LauncherSettings $bst $set
    $m = Start-Manager $bst 'recovery'
    $cdp = Start-EdgeSession -WorkDir $work
    Set-Viewport $cdp 1280 900
    $null = Wait-Until { Get-ManagerLaunchUrl $bst 'projects' } 15
    Open-Page $cdp (Get-ManagerLaunchUrl $bst 'projects')
    $shown = Wait-PageCondition $cdp "!!document.querySelector('#launcher-card') && !!document.querySelector('#launcher-notice')" 30
    $txt = [string](Invoke-PageScript $cdp "document.querySelector('#launcher-notice') ? document.querySelector('#launcher-notice').textContent : ''")
    Test-Condition 'page: recovery banner and the Startup card on the Deployments page' ($shown -and $txt -match 'Recovery mode') $txt
    $isDefault = [bool](Invoke-PageScript $cdp "[...document.querySelectorAll('.rv')].some((c) => c.textContent.includes('$stackA') && c.textContent.includes('Default at startup'))")
    $hasMake = [bool](Invoke-PageScript $cdp "!!document.querySelector('[data-make-default]')")
    Test-Condition 'page: the default deployment is marked; others offer Make default' ($isDefault -and $hasMake)
    $shots = Join-Path $work 'shots'; New-Item -ItemType Directory -Force -Path $shots | Out-Null
    Save-PageScreenshot $cdp (Join-Path $shots 'launcher-1-recovery.png')
    # The chooser also lists real running stacks (e.g. traefik-ext1): click the button of this test's deployment only.
    $clicked = [bool](Invoke-PageScript $cdp "(() => { const b = [...document.querySelectorAll('[data-make-default]')].find((x) => x.dataset.makeDefault === $(ConvertTo-Json $pathB)); if (b) b.click(); return !!b; })()")
    if (-not $clicked) { Add-Result 'FAIL' 'page: Make default button of the test deployment' 'not found' }
    $made = Wait-Until { (Read-LauncherSettings $bst $repo).defaultDeployment -eq $pathB } 20
    $marked = Wait-PageCondition $cdp "[...document.querySelectorAll('.rv')].some((c) => c.textContent.includes('$stackB') && c.textContent.includes('Default at startup'))" 15
    Test-Condition 'page: Make default saves the new default and marks it' ($made -and $marked)
    $null = Invoke-PageScript $cdp "document.querySelector('#launcher-autostart').click(); true"
    $autoOn = Wait-Until { Test-Path -LiteralPath $autoPath } 20
    $null = Wait-PageCondition $cdp "!!document.querySelector('#launcher-autostart') && document.querySelector('#launcher-autostart').checked" 15
    Save-PageScreenshot $cdp (Join-Path $shots 'launcher-2-autostart.png')
    $null = Invoke-PageScript $cdp "document.querySelector('#launcher-autostart').click(); true"
    $autoOff = Wait-Until { -not (Test-Path -LiteralPath $autoPath) } 20
    Test-Condition 'page: the Start with Windows switch adds and removes the Startup shortcut' ($autoOn -and $autoOff)
    Set-Viewport $cdp 390 844 -Mobile
    Start-Sleep -Milliseconds 600
    $overflow = [bool](Invoke-PageScript $cdp 'document.documentElement.scrollWidth > window.innerWidth + 1')
    Save-PageScreenshot $cdp (Join-Path $shots 'launcher-3-mobile.png')
    Test-Condition 'page: no sideways scrolling at 390 px' (-not $overflow)
    $errs = @($cdp.Errors)
    Test-Condition 'page: no script errors' ($errs.Count -eq 0) (($errs | Select-Object -First 3) -join ' | ')
    Stop-EdgeSession $cdp; $cdp = $null
    Stop-Manager $bst
    if ($KeepFiles) { Write-Host "Screenshots: $shots" }
  }

  if ($script:DockerOk) { Test-Condition 'the whole run left every container as it was' ((Get-DockerSnapshot) -eq $dockerBefore) }
  Test-Condition 'the whole run wrote nothing into the deployment folders' ((Get-FolderSnapshot $pathA) -eq $snapA -and (Get-FolderSnapshot $pathB) -eq $snapB)
} catch {
  Add-Result 'FAIL' 'unexpected error' "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
} finally {
  foreach ($t in $listeners) { try { $t.Stop() } catch { } }
  if ($cdp) { try { Stop-EdgeSession $cdp } catch { } }
  foreach ($dir in @('state', 'state-tray', 'state-browser')) { $sd = Join-Path $work $dir; if (Test-Path -LiteralPath $sd) { try { Send-TrayCommand $sd 'exit' } catch { }; try { Stop-Manager $sd } catch { } } }
  Start-Sleep -Milliseconds 500
  # Anything still running from this test (only processes whose command line names this test's folder).
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { [string]$_.CommandLine -like "*$work*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  foreach ($p in $script:Processes) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
  if ($mock) { Stop-TestServer ([pscustomobject]@{ StopFile = $mock.StopFile; Port = $mock.Port; Process = $mock.Process }) }
  if ($autoPath) { Remove-Item -LiteralPath $autoPath -Force -ErrorAction SilentlyContinue }
  if (-not $KeepFiles) { Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$passed = @($script:Results | Where-Object { $_.Status -eq 'PASS' })
$skipped = @($script:Results | Where-Object { $_.Status -eq 'SKIP' })
Write-Host ''
Write-Host ("{0} passed, {1} failed, {2} skipped" -f $passed.Count, $failed.Count, $skipped.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
exit $(if ($failed.Count) { 1 } else { 0 })
