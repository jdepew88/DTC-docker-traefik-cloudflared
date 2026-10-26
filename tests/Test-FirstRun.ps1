#requires -version 5.1
<#
.SYNOPSIS
  First-run regression test: the web UI and diagnostics run from the source folder before anything is installed.

.DESCRIPTION
  Starts webui.ps1 straight from this source folder with -InstallPath pointing at a folder that does not exist
  (the state of a new machine: no lib\, no scripts\, no .env there). Every read-only endpoint must answer
  without a server error and report "Not installed"; changes that need an installation must be refused with a
  clear message; the installer preview must work; and nothing may be written to the install folder. Also runs
  scripts\Get-Diagnostics.ps1 and tests\Test-Stack.ps1's module loading against an empty install path.
  No containers are started and no Cloudflare API is called.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-FirstRun.ps1
#>
[CmdletBinding()]
param([switch]$KeepFiles)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail }
}
# Runs a script in a child PowerShell; stderr is captured as text instead of stopping this test.
function Invoke-Ps([string]$File, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $File @Arguments 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Lines = @($out); Text = (@($out) -join "`n") }
}
# Calls the web UI as the signed-in browser and records every status code.
$script:Statuses = New-Object System.Collections.ArrayList
function Invoke-Ui([string]$Method, [string]$Path, $Body) {
  $r = Invoke-WebUi $ui $Method $Path $Body
  $null = $script:Statuses.Add([pscustomobject]@{ Status = $r.Status; Call = "$Method $Path"; Body = $r.Body })
  return $r
}
function Short($r) { if ($null -eq $r) { return '(no response)' }; return "HTTP $($r.Status) $($r.Body.Substring(0, [Math]::Min(400, $r.Body.Length)))" }

# Text that means a script could not find its own code (the original first-run bug) or crashed.
$BrokenPattern = 'is not recognized as the name|Cannot find path|was not loaded because no valid module file|could not be found|Exception|ParserError'

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpx-firstrun-$id"
$install = Join-Path $work 'not-installed\traefik-proxy'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$ui = $null

try {
  Test-Condition 'fixture: install folder does not exist' (-not (Test-Path -LiteralPath $install))

  # --- Port checks see listeners that Get-NetTCPConnection may miss -----------------------------------------
  $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
  $probe.Start()
  $probePort = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
  try { Test-Condition 'Get-PortUser: a loopback listener is reported' ([bool](Get-PortUser $probePort)) "port $probePort" }
  finally { $probe.Stop() }
  Test-Condition 'Get-PortUser: a free port is reported free' ($null -eq (Get-PortUser $probePort)) "port $probePort"

  # --- Diagnostics script from the source folder ----------------------------------------------------------
  $diag = Invoke-Ps (Join-Path $repo 'scripts\Get-Diagnostics.ps1') @('-ProjectPath', $install)
  $diagOut = $diag.Lines; $diagText = $diag.Text
  Test-Condition 'Get-Diagnostics.ps1 exits 0 with no installation' ($diag.ExitCode -eq 0) $diagText
  Test-Condition 'Get-Diagnostics.ps1 reports "Not installed"' ($diagText -match 'Not installed') $diagText
  Test-Condition 'Get-Diagnostics.ps1 shows no errors' ($diagText -notmatch $BrokenPattern) (($diagOut | Select-String $BrokenPattern | Select-Object -First 3) -join ' | ')

  # Test-Stack.ps1 must load its module from the source folder too (it fails later on purpose: no stack).
  $stack = Invoke-Ps (Join-Path $repo 'tests\Test-Stack.ps1') @('-ProjectPath', $install)
  $stackOut = $stack.Lines; $stackText = $stack.Text
  Test-Condition 'Test-Stack.ps1 loads its module from the source folder' ($stackText -notmatch 'TraefikProxy\.psm1|Get-StackSettings.*not recognized') (($stackOut | Select-Object -First 5) -join ' | ')
  Test-Condition 'Test-Stack.ps1 reports "Not installed"' ($stackText -match 'Not installed') (($stackOut | Select-Object -First 5) -join ' | ')

  # --- Web UI from the source folder ----------------------------------------------------------------------
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir $work
  $null = Connect-WebUi $ui
  Test-Condition 'web UI starts from the source folder and signs in' ([bool]$ui.Csrf)

  $page = Invoke-RawHttp -Port $ui.Port -Path '/' -Headers @{ Cookie = $ui.Cookie }
  Test-Condition 'web UI: page is served' ($page.Status -eq 200 -and $page.Body -match '<html') (Short $page)

  $r = Invoke-Ui GET '/api/status'
  Test-Condition 'status: 200 and installed=false' ($r.Status -eq 200 -and $r.Data.instance.installed -eq $false) (Short $r)
  if ($r.Status -eq 200) {
    Test-Condition 'status: source path is the repository' ([IO.Path]::GetFullPath($r.Data.instance.sourcePath).TrimEnd('\') -eq [IO.Path]::GetFullPath($repo).TrimEnd('\')) $r.Data.instance.sourcePath
    Test-Condition 'status: install path is the requested folder' ($r.Data.instance.installPath -eq [IO.Path]::GetFullPath($install)) $r.Data.instance.installPath
    Test-Condition 'status: installer available' ($r.Data.instance.canInstall -eq $true) (Short $r)
    Test-Condition 'status: stack reported as not installed' ($r.Data.stack.Installed -eq $false) (Short $r)
    # Default ports may belong to another Traefik on this PC; it must not be reported as this instance's.
    Test-Condition "status: another instance's Traefik API is not adopted" ($r.Data.stack.TraefikApi -eq $false -and @($r.Data.stack.Routers).Count -eq 0) (Short $r)
  }

  $r = Invoke-Ui GET '/api/services'
  Test-Condition 'services: 200, empty, installed=false' ($r.Status -eq 200 -and $r.Data.installed -eq $false -and @($r.Data.services).Count -eq 0) (Short $r)

  $r = Invoke-Ui GET '/api/backups'
  Test-Condition 'backups: 200 and empty' ($r.Status -eq 200 -and @($r.Data.backups).Count -eq 0) (Short $r)

  foreach ($role in @('traefik', 'cloudflared')) {
    $r = Invoke-Ui GET "/api/logs?role=$role&tail=10"
    Test-Condition "logs ($role): 200 with 'Not installed'" ($r.Status -eq 200 -and (@($r.Data.Lines) -join ' ') -match 'Not installed') (Short $r)
  }
  $r = Invoke-Ui GET '/api/logs?role=nope'
  Test-Condition 'logs: unknown role still refused' ($r.Status -eq 400) (Short $r)

  $r = Invoke-Ui GET '/api/audit'
  Test-Condition 'audit: 200 and empty' ($r.Status -eq 200 -and @($r.Data.lines).Count -eq 0) (Short $r)

  $r = Invoke-Ui GET '/api/cloudflare'
  Test-Condition 'cloudflare: 200, no token stored' ($r.Status -eq 200 -and $r.Data.token.Stored -eq $false -and $r.Data.connector.tokenFile -eq $false) (Short $r)

  foreach ($deep in @($false, $true)) {
    $r = Invoke-Ui POST '/api/validate' @{ deep = $deep }
    Test-Condition "validate (deep=$deep): 200 with 'Not installed'" ($r.Status -eq 200 -and $r.Data.installed -eq $false -and $r.Data.message -match 'Not installed') (Short $r)
  }

  $r = Invoke-Ui POST '/api/diagnostics' @{}
  $lines = @(); if ($r.Data) { $lines = @($r.Data.lines) }
  Test-Condition 'diagnostics: 200, ok, "Not installed"' ($r.Status -eq 200 -and $r.Data.ok -eq $true -and ($lines -join ' ') -match 'Not installed') (Short $r)
  Test-Condition 'diagnostics: no module/script errors' ((($lines -join "`n") -notmatch $BrokenPattern)) (($lines | Select-String $BrokenPattern | Select-Object -First 3) -join ' | ')

  $r = Invoke-Ui POST '/api/install/preview' @{}
  # The preview may legitimately stop on a port/subnet clash with other stacks on this PC; it must still run
  # from the source folder and get past loading its code.
  $previewText = ''; if ($r.Data) { $previewText = @($r.Data.lines) -join "`n" }
  Test-Condition 'installer preview: runs from the source folder' ($r.Status -eq 200 -and $previewText -match 'Checking Docker Desktop' -and $previewText -notmatch 'is not recognized as the name|module .* was not loaded|TraefikProxy\.psm1') (Short $r)

  # Changes that need an installation: refused with a clear 409, never a 500.
  $body = @{ op = 'add'; name = 'firstrun'; service = @{ name = 'firstrun'; hostnames = @('firstrun.example.test'); target = @{ type = 'auto'; host = '10.10.0.11'; port = 8080; protocol = 'http' }
      cloudflare = @{ publish = $false; access = $false }; middlewares = @() }; cloudflare = @{ automate = $false } }
  $r = Invoke-Ui POST '/api/services/plan' $body
  Test-Condition 'service preview: 409 "install first"' ($r.Status -eq 409 -and $r.Data.error -match 'install') (Short $r)
  $r = Invoke-Ui POST '/api/backups/restore' @{ id = 'x'; confirm = $true }
  Test-Condition 'rollback: 409 "install first"' ($r.Status -eq 409) (Short $r)
  # The API token may be saved before installation (Test-Onboarding.ps1 covers that against the mock); a malformed
  # one is refused locally, without any Cloudflare call.
  $r = Invoke-Ui POST '/api/cloudflare/token' @{ token = 'not a token' }
  Test-Condition 'malformed API token refused locally' ($r.Status -eq 400) (Short $r)
  $r = Invoke-Ui GET '/api/setup'
  Test-Condition 'setup wizard data: not installed, default settings, no deployment chosen' ($r.Status -eq 200 -and $r.Data.installed -eq $false -and $r.Data.settingsSource -eq 'defaults' -and -not $r.Data.deployment.mode -and $r.Data.cloudflare.tokenStored -eq $false) (Short $r)
  $r = Invoke-Ui POST '/api/cloudflare/connector' @{ confirm = $true }
  Test-Condition 'connector: 409' ($r.Status -eq 409) (Short $r)

  $errors = @($script:Statuses | Where-Object { $_.Status -ge 500 -or $_.Status -eq 0 })
  Test-Condition 'no server errors in any response' ($errors.Count -eq 0) (($errors | ForEach-Object { "$($_.Status) $($_.Call) $($_.Body)" }) -join ' | ')
  Test-Condition 'nothing was written to the install folder' (-not (Test-Path -LiteralPath $install)) (Get-ChildItem -LiteralPath $install -Recurse -ErrorAction SilentlyContinue | Select-Object -First 5 | Out-String)
} finally {
  Stop-TestServer $ui
  if (-not $KeepFiles) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "Files kept in $work" }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count -gt 0) { exit 1 }
