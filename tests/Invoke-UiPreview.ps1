#requires -version 5.1
<#
.SYNOPSIS
  Developer tool: renders the web UI in headless Microsoft Edge and saves screenshots and rendered DOM of the
  principal screens, at several detail levels and viewport sizes.

.DESCRIPTION
  Starts the Cloudflare API mock and webui.ps1 for a throwaway install folder in %TEMP% (or -InstallPath, read-only
  use only), then opens each page with Edge (--headless). Detail level and theme are passed in the URL fragment
  (#page?level=expert), which the app reads once at start for previews. Nothing in Docker or Cloudflare is changed
  unless -Prepare is given, which drives the API like a user (token, domains, settings, deployment) against the mock.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Invoke-UiPreview.ps1 -OutDir .\preview -Prepare
#>
[CmdletBinding()]
param(
  [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'tpm-ui-preview'),
  [string]$InstallPath,
  [switch]$Prepare,
  # Comma-separated page@level@width entries (page may end in ~light).
  [string]$Shots = 'setup@beginner@1366,setup@expert@1366,setup@beginner@390,help@beginner@1366',
  [int]$Budget = 9000,
  [switch]$DomOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found.' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('tpm-preview-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (-not $InstallPath) { $InstallPath = Join-Path $work 'instance' }
$token = 'mockTok_' + [Guid]::NewGuid().ToString('N') + 'abcdefgh'
$mock = $null; $ui = $null
$results = New-Object System.Collections.ArrayList
try {
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $token
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $InstallPath -WorkDir $work -ApiBase $mock.Base
  if ($Prepare) {
    $null = Connect-WebUi $ui
    $null = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = $token }
    $null = Invoke-WebUi $ui POST '/api/cloudflare/domains' @{ zoneIds = @('zone00000000000000000000000000001') }
    $sug = Invoke-WebUi $ui POST '/api/setup/suggest' @{}
    $null = Invoke-WebUi $ui POST '/api/setup/settings' @{ settings = $sug.Data.settings }
    $null = Invoke-WebUi $ui POST '/api/setup/deployment' @{ mode = 'tunnel'; tunnelChoice = 'existing'; tunnelId = '11111111-2222-3333-4444-555555555555' }
    $null = Invoke-WebUi $ui POST '/api/setup/contact' @{ email = 'owner@example.test' }
  }
  foreach ($shot in @($Shots -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $page, $level, $width = $shot.Split('@')
    $theme = 'dark'
    if ($page -match '^(.*)~(light|dark)$') { $page = $Matches[1]; $theme = $Matches[2] }
    $name = ($shot -replace '[^A-Za-z0-9@~-]', '_')
    $url = "$($ui.LaunchUrl)#${page}?level=${level}&theme=${theme}"
    $profileDir = Join-Path $work ("edge-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $common = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--hide-scrollbars', "--user-data-dir=$profileDir", "--virtual-time-budget=$Budget", "--window-size=$width,2600")
    $dom = Join-Path $OutDir "$name.html"
    $p = Start-Process -FilePath $edge -ArgumentList ($common + @('--dump-dom', "`"$url`"")) -RedirectStandardOutput $dom -RedirectStandardError (Join-Path $work "$name.err") -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(90000)) { Stop-Process -Id $p.Id -Force }
    $png = $null
    if (-not $DomOnly) {
      $png = Join-Path $OutDir "$name.png"
      $p = Start-Process -FilePath $edge -ArgumentList ($common + @("--screenshot=`"$png`"", "`"$url`"")) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $work "$name.shot.err")
      if (-not $p.WaitForExit(90000)) { Stop-Process -Id $p.Id -Force }
    }
    $null = $results.Add([pscustomobject]@{ Shot = $shot; Dom = $dom; Png = $png; DomBytes = $(if (Test-Path $dom) { (Get-Item $dom).Length } else { 0 }) })
  }
} finally {
  Stop-TestServer $ui
  Stop-TestServer $mock
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$results
