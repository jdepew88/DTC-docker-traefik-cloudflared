#requires -version 5.1
<#
.SYNOPSIS
  Regression tests for the Traefik dashboard bootstrap (public dashboard behind Cloudflare Access).

.DESCRIPTION
  Uses a never-started instance folder in %TEMP% and the Cloudflare API mock. Traefik itself checks the generated
  route in a throwaway, network-less container. Live routing through a running Traefik is covered by
  tests\Invoke-IsolatedTest.ps1.
    - default hostname from the instance name, editable subdomain, domain from the allowlist only
    - the router: Host + /dashboard + /api, api@internal, `web` entry point, Cloudflare Access header required
    - fail closed: no Cloudflare automation, no Access permission, no sign-in emails, an Access write that fails
      (read-only token) -> nothing is published (no route file, no tunnel route, no DNS record)
    - publish: Access first, then route, tunnel route and DNS; a second run creates no duplicates; an existing Access
      application is reused; services cannot take the dashboard hostname; independent verification checks
    - removal deletes only what this tool created; the local dashboard (dashboard.yml) is never changed

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Dashboard.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $repo 'lib\Dashboard.psm1') -Force
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
function Short($r) { if ($null -eq $r) { return '(no response)' }; return "HTTP $($r.Status) $($r.Body.Substring(0, [Math]::Min(700, $r.Body.Length)))" }
function Ui([string]$Method, [string]$Path, $Body) { return Invoke-WebUi $ui $Method $Path $Body }
function Use-Token([string]$Token) { return Ui POST '/api/cloudflare/token' @{ token = $Token; confirmReplace = $true } }
function Get-Published([string]$Hostname) {
  $s = Get-MockState $mock
  $ingress = @()
  foreach ($p in $s.configs.PSObject.Properties) { if ($p.Value -and $p.Value.PSObject.Properties['ingress']) { $ingress += @($p.Value.ingress | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq $Hostname }) } }
  return [pscustomobject]@{
    Apps = @($s.apps | Where-Object { $_.domain -eq $Hostname }).Count
    Dns = @($s.dns | Where-Object { $_.name -eq $Hostname }).Count
    Routes = $ingress.Count
  }
}

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpx-dash-$id"
$path = Join-Path $work 'instance'
$stack = "tpx-dash-$id"
$acct = 'acc0000000000000000000000000001'
$tunnel = '11111111-2222-3333-4444-555555555555'
$zone1 = 'zone00000000000000000000000000001'
$zone2 = 'zone00000000000000000000000000002'
$hostname = "$stack.example.test"
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$mock = $null; $ui = $null

try {
  # --- Route generation and Traefik validation ------------------------------------------------------------------
  $yaml = ConvertTo-DashboardRouteYaml 'traefik-home.example.com'
  Test-Condition 'route: Host + /dashboard + /api to api@internal on the web entry point, Access header required' (
    $yaml -match [regex]::Escape("rule: 'Host(``traefik-home.example.com``) && (PathPrefix(``/dashboard``) || PathPrefix(``/api``)) && HeaderRegexp(``Cf-Access-Jwt-Assertion``, ``.+``)'") -and
    $yaml -match 'service: api@internal' -and $yaml -match 'entryPoints: \[web\]' -and $yaml -notmatch 'entryPoints: \[traefik\]' -and $yaml -match "replacement: '/dashboard/'") $yaml
  $null = New-TestInstance -Repo $repo -Path $path -StackName $stack
  $settings = Get-StackSettings -InstallPath $path
  $localBefore = Get-FileSha256 (Join-Path $path 'traefik\dynamic\dashboard.yml')
  if (Test-DockerEngine) {
    $deep = Test-TraefikDynamicConfig -Settings $settings -ExtraFiles @{ 'admin-dashboard.yml' = (ConvertTo-DashboardRouteYaml $hostname) } -ExpectRouters @('public-dashboard@file', 'public-dashboard-root@file')
    Test-Condition 'route: Traefik accepts it (throwaway container), local dashboard router unchanged' ($deep.Ok -and @($deep.Routers | Where-Object { $_.Name -eq 'public-dashboard@file' }).Count -eq 1) (@($deep.Errors) -join ' | ')
  } else { Add-Result 'SKIP' 'route: Traefik accepts it' 'Docker is not running' }
  Test-Condition 'default subdomain is the instance name' ((Get-DashboardDefaultSubdomain (ConvertTo-StackSettings -InstallPath $path -Values @{ STACK_NAME = 'traefik-home' })) -eq 'traefik-home') ''

  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $path -WorkDir $work -ApiBase $mock.Base
  $null = Connect-WebUi $ui

  $d = Ui GET '/api/dashboard'
  Test-Condition 'GET /api/dashboard: local URL always, suggestion from the instance name, Cloudflare not ready' ($d.Status -eq 200 -and $d.Data.localUrl -eq "http://127.0.0.1:$($settings.DashboardPort)/dashboard/" -and
    $d.Data.subdomain -eq $stack -and -not $d.Data.enabled -and -not $d.Data.cloudflareReady) (Short $d)
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone1; accessEmails = @('owner@example.com') }
  Test-Condition 'fail closed: without Cloudflare automation the dashboard cannot be published' ($p.Status -eq 200 -and -not $p.Data.canApply -and (@($p.Data.cloudflare.errors) -join ' ') -match 'needs Cloudflare automation') (Short $p)

  $null = Ui POST '/api/cloudflare/token' @{ token = $apiToken }
  $null = Ui POST '/api/cloudflare/select' @{ accountId = $acct; tunnelId = $tunnel }
  $null = Ui POST '/api/cloudflare/domains' @{ zoneIds = @($zone1) }
  $d = Ui GET '/api/dashboard'
  Test-Condition 'with Cloudflare connected: ready, domain suggested from the allowlist' ($d.Data.cloudflareReady -and $d.Data.zoneId -eq $zone1 -and @($d.Data.domains).Count -eq 1) (Short $d)
  $p = Ui POST '/api/dashboard/plan' @{ subdomain = 'bad_name!'; zoneId = $zone1; accessEmails = @('owner@example.com') }
  Test-Condition 'invalid subdomain refused' (-not $p.Data.canApply -and (@($p.Data.cloudflare.errors) -join ' ') -match 'not a valid subdomain') (Short $p)
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone2; accessEmails = @('owner@example.com') }
  Test-Condition 'only allowed domains can be used' (-not $p.Data.canApply -and (@($p.Data.cloudflare.errors) -join ' ') -match 'allowed Cloudflare domains') (Short $p)
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone1 }
  Test-Condition 'fail closed: no Access application and no sign-in emails -> blocked' (-not $p.Data.canApply -and @($p.Data.cloudflare.actions | Where-Object { $_.step -eq 'access' -and $_.kind -eq 'blocked' }).Count -eq 1) (Short $p)

  # Authorization failures.
  $null = Use-Token ('mockNoAccess_' + [Guid]::NewGuid().ToString('N'))
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone1; accessEmails = @('owner@example.com') }
  Test-Condition 'fail closed: a token without Access permission cannot publish the dashboard' ($p.Status -eq 200 -and -not $p.Data.canApply -and (@($p.Data.cloudflare.errors) -join ' ') -match 'Access protection cannot be ensured') (Short $p)
  $null = Use-Token ('mockReadOnly_' + [Guid]::NewGuid().ToString('N'))
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone1; accessEmails = @('owner@example.com') }
  $a = Ui POST '/api/dashboard/apply' @{ planId = $p.Data.planId; confirm = $true }
  $pub = Get-Published $hostname
  Test-Condition 'fail closed: Access creation refused by Cloudflare -> no route, tunnel route or DNS record' ($p.Data.canApply -and $a.Status -eq 200 -and -not $a.Data.ok -and $a.Data.failClosed -and
    -not (Test-Path -LiteralPath (Join-Path $path 'traefik\dynamic\admin-dashboard.yml')) -and $pub.Apps -eq 0 -and $pub.Dns -eq 0 -and $pub.Routes -eq 0 -and
    -not (Ui GET '/api/dashboard').Data.enabled) "$(Short $a) $($pub | ConvertTo-Json -Compress)"
  $null = Use-Token $apiToken

  # Publish.
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone1; accessEmails = @('owner@example.com') }
  $steps = @($p.Data.cloudflare.actions | ForEach-Object { "$($_.step):$($_.kind)" })
  Test-Condition 'plan: Access, tunnel route and DNS created; route file added; review shown' ($p.Status -eq 200 -and $p.Data.canApply -and $p.Data.hostname -eq $hostname -and
    ($steps -join ',') -eq 'access:create,tunnel:create,dns:create' -and @($p.Data.traefik.changes | Where-Object { $_.action -eq 'add' }).Count -eq 1 -and @($p.Data.review).Count -ge 3) (Short $p)
  $a = Ui POST '/api/dashboard/apply' @{ planId = $p.Data.planId }
  Test-Condition 'apply needs explicit confirmation' ($a.Status -eq 400 -and -not (Test-Path -LiteralPath (Join-Path $path 'traefik\dynamic\admin-dashboard.yml'))) (Short $a)
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone1; accessEmails = @('owner@example.com') }
  $a = Ui POST '/api/dashboard/apply' @{ planId = $p.Data.planId; confirm = $true }
  $pub = Get-Published $hostname
  $names = @($a.Data.steps | ForEach-Object { $_.name })
  $accessIdx = [array]::IndexOf($names, 'Confirm Cloudflare Access protection')
  $routeIdx = [array]::IndexOf($names, 'Write the dashboard route')
  $dnsIdx = @(for ($i = 0; $i -lt $names.Count; $i++) { if ($names[$i] -match '^Create DNS record') { $i } })[0]
  Test-Condition 'apply: Access confirmed before the route, the route before DNS; link returned' ($a.Status -eq 200 -and $a.Data.ok -and $a.Data.url -eq "https://$hostname/dashboard/" -and
    $accessIdx -ge 0 -and $routeIdx -gt $accessIdx -and $dnsIdx -gt $routeIdx -and $a.Data.recoveryPoint) (Short $a)
  Test-Condition 'apply: one Access app, one tunnel route, one DNS record; route file written; settings saved' ($pub.Apps -eq 1 -and $pub.Dns -eq 1 -and $pub.Routes -eq 1 -and
    ([IO.File]::ReadAllText((Join-Path $path 'traefik\dynamic\admin-dashboard.yml'))) -eq (ConvertTo-DashboardRouteYaml $hostname) -and (Ui GET '/api/dashboard').Data.enabled) ($pub | ConvertTo-Json -Compress)
  $p = Ui POST '/api/dashboard/plan' @{ zoneId = $zone1; accessEmails = @('owner@example.com') }
  $a = Ui POST '/api/dashboard/apply' @{ planId = $p.Data.planId; confirm = $true }
  $pub = Get-Published $hostname
  Test-Condition 'second run: nothing to change, no duplicate resources' ($p.Status -eq 200 -and -not $p.Data.hasWork -and $a.Status -eq 400 -and $pub.Apps -eq 1 -and $pub.Dns -eq 1 -and $pub.Routes -eq 1) (Short $p)
  $p = Ui POST '/api/dashboard/plan' @{ subdomain = 'other-name'; zoneId = $zone1; accessEmails = @('owner@example.com') }
  Test-Condition 'changing the hostname needs the old one removed first' (-not $p.Data.canApply -and (@($p.Data.cloudflare.errors) -join ' ') -match 'Remove it first') (Short $p)
  $svc = Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'add'; name = 'grab'; service = @{ name = 'grab'; hostnames = @($hostname); target = @{ type = 'lan'; host = '10.0.0.7'; port = 80 } }; cloudflare = @{ automate = $false } }
  Test-Condition 'a service cannot take the dashboard hostname' ($svc.Status -eq 400 -and $svc.Data.error -match 'dashboard') (Short $svc)

  $v = Ui POST '/api/dashboard/verify' @{ public = $false }
  $state = @{}; foreach ($c in @($v.Data.checks)) { $state[$c.id] = $c.state }
  Test-Condition 'verify: independent checks (Traefik not running here; route file, Access, tunnel route and DNS ok)' ($v.Status -eq 200 -and $state['local-dashboard'] -eq 'failed' -and
    $state['route-file'] -eq 'ok' -and $state['access'] -eq 'ok' -and $state['tunnel-route'] -eq 'ok' -and $state['dns'] -eq 'ok' -and $state.ContainsKey('connector') -and @($v.Data.review).Count -eq @($v.Data.checks).Count) (Short $v)

  # An Access application that already exists is reused, never duplicated (protected.example.test in the mock).
  $p = Ui POST '/api/dashboard/plan' @{ disable = $true }
  $a = Ui POST '/api/dashboard/apply' @{ planId = $p.Data.planId; confirm = $true }
  $pub = Get-Published $hostname
  Test-Condition 'remove: route removed first, then DNS, tunnel route and the Access app this tool created' ($a.Status -eq 200 -and $a.Data.ok -and $a.Data.steps[0].name -eq 'Remove the public dashboard route' -and
    -not (Test-Path -LiteralPath (Join-Path $path 'traefik\dynamic\admin-dashboard.yml')) -and $pub.Apps -eq 0 -and $pub.Dns -eq 0 -and $pub.Routes -eq 0 -and -not (Ui GET '/api/dashboard').Data.enabled) "$(Short $a) $($pub | ConvertTo-Json -Compress)"
  $p = Ui POST '/api/dashboard/plan' @{ subdomain = 'protected'; zoneId = $zone1 }
  $acc = @($p.Data.cloudflare.actions | Where-Object { $_.step -eq 'access' })
  Test-Condition 'an existing Access application is reused (no emails needed, nothing duplicated)' ($p.Data.canApply -and $acc.Count -eq 1 -and $acc[0].kind -eq 'none') (Short $p)
  $a = Ui POST '/api/dashboard/apply' @{ planId = $p.Data.planId; confirm = $true }
  $p = Ui POST '/api/dashboard/plan' @{ disable = $true }
  $a2 = Ui POST '/api/dashboard/apply' @{ planId = $p.Data.planId; confirm = $true }
  $pub = Get-Published 'protected.example.test'
  Test-Condition 'removing it keeps the Access application this tool did not create' ($a.Data.ok -and $a2.Data.ok -and $pub.Apps -eq 1 -and $pub.Dns -eq 0 -and $pub.Routes -eq 0) "$(Short $a2) $($pub | ConvertTo-Json -Compress)"
  Test-Condition 'the local dashboard route (dashboard.yml) was never changed' ((Get-FileSha256 (Join-Path $path 'traefik\dynamic\dashboard.yml')) -eq $localBefore) ''
  $all = @($ui.Bodies) -join "`n"
  Test-Condition 'no API response contains the API token' (-not $all.Contains($apiToken)) ''
} finally {
  Stop-TestServer $ui
  Stop-TestServer $mock
  Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
