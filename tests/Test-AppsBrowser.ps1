#requires -version 5.1
<#
.SYNOPSIS
  Browser test of the App Catalog and Installed apps pages without Docker containers (small memory footprint).

.DESCRIPTION
  Runs webui.ps1 for a throwaway install folder in headless Edge. The catalog comes from the real API (a registry with
  two Rocket.Chat installations, one written as 'rocket-chat'). The installed apps, their details and the install
  defaults are answered in the page from models built by the real lib\ComposeLifecycle.psm1 from facts shaped like the
  live Rocket.Chat project (three long-running services, two completed setup jobs) and a prepared second installation.
  Covers: Arcane, Portainer and What's Up Docker offered, no Diun or Watchtower card, one Rocket.Chat entry with its
  installations, the corrected status, expandable service details (roles, health, exit codes, dependencies, networks),
  no scroll jump, the duplicate-installation panel, secrets never shown, and the phone layout. Screenshots go to
  -ScreenshotDir.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-AppsBrowser.ps1 -ScreenshotDir .\ui-screens
#>
param([string]$ScreenshotDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\AppCatalog.psm1') -Force
Import-Module (Join-Path $repo 'lib\ComposeLifecycle.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\EdgeCdp.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
if (-not (Get-EdgePath)) { Add-Result 'SKIP' 'browser tests' 'Microsoft Edge not found'; exit 0 }

# --- Fixture models (real lifecycle code, invented facts shaped like the live Rocket.Chat project) -------------------------
$rcm = Get-CatalogApp (Join-Path $repo 'catalog') 'rocketchat'
$secret = 'mongodb://admin:Sup3rSecretPw@mongodb'
function New-Fact([string]$Svc, [string]$State, [int]$Exit, [string]$Health, [bool]$Hc, [string]$Restart, $Deps = @(), $Nets = @(), $Ports = @(), $Mounts = @()) {
  return [ordered]@{ id = 'x'; name = "rocket-chat-$Svc"; project = 'rocket-chat'; service = $Svc; workingDir = 'C:\Users\me\.docker\projects\rocket-chat'; oneoff = $false; app = 'rocket-chat'; managedProject = 'rocket-chat'
    image = ([string]$rcm.services.$Svc.image); imageId = 'sha256:' + ('b' * 64); state = $State; exitCode = $Exit; health = $Health; hasHealthcheck = $Hc; restartPolicy = $Restart; restartCount = 0
    startedAt = '2026-10-23T09:47:19Z'; finishedAt = $(if ($State -eq 'exited') { '2026-10-23T09:47:27Z' } else { '0001-01-01T00:00:00Z' }); dependsOn = @($Deps); networks = @($Nets); ports = @($Ports); mounts = @($Mounts) }
}
$int = { param($s) [ordered]@{ name = 'rocket-chat_internal'; ip = "172.21.0.$([Math]::Abs($s.GetHashCode()) % 200 + 2)"; dnsNames = @("rocket-chat-$s", $s) } }
$facts = @(
  (New-Fact 'rocketchat' 'running' 0 'healthy' $true 'unless-stopped' @([ordered]@{ service = 'mongodb'; condition = 'service_healthy' }, [ordered]@{ service = 'nats'; condition = 'service_started' }) @([ordered]@{ name = 'proxynet'; ip = '172.25.0.9'; dnsNames = @('rocket-chat-rocketchat', 'rocketchat') }, (& $int 'rocketchat')) @([ordered]@{ container = '3000/tcp'; hostIp = '127.0.0.1'; hostPort = '3100' }) @([ordered]@{ type = 'volume'; name = 'rocket-chat_uploads'; source = ''; target = '/app/uploads'; readOnly = $false })),
  (New-Fact 'mongodb' 'running' 0 'healthy' $true 'unless-stopped' @() @(& $int 'mongodb') @() @([ordered]@{ type = 'volume'; name = 'rocket-chat_mongodb'; source = ''; target = '/data/db'; readOnly = $false })),
  (New-Fact 'nats' 'running' 0 '' $false 'unless-stopped' @() @(& $int 'nats')),
  (New-Fact 'mongodb-fix-permission' 'exited' 0 '' $false 'on-failure' @() @(& $int 'mongodb-fix-permission')),
  (New-Fact 'mongodb-init' 'exited' 0 '' $false 'on-failure' @() @(& $int 'mongodb-init')))
$lcRun = Get-DeploymentLifecycle -Containers $facts -Manifest $rcm
$lcPrep = Get-DeploymentLifecycle -Defined @($rcm.services.PSObject.Properties | ForEach-Object { $_.Name }) -Manifest $rcm -Prepared
$failFacts = @($facts | ForEach-Object { $c = [ordered]@{}; foreach ($k in $_.Keys) { $c[$k] = $_[$k] }; $c }); $failFacts[4].exitCode = 1
$lcFail = Get-DeploymentLifecycle -Containers $failFacts -Manifest $rcm
$appA = [ordered]@{ project = 'rocket-chat'; instanceId = 'legacy-rocket-chat'; appId = 'rocketchat'; recordedAppId = 'rocket-chat'; applicationId = 'rocketchat'; availability = 'offered'; name = 'Rocket.Chat'; label = ''; origin = 'installed'; archived = $false; archivedAt = ''
  folder = 'C:\Users\me\.docker\projects\rocket-chat'; installedAt = '2026-10-21T21:34:33'; folderExists = $true; containers = @(); running = 3; total = 5; lifecycle = $lcRun; siblings = @('rocketchat'); localUrl = 'http://127.0.0.1:3100/'
  routes = @([ordered]@{ name = 'rocket-chat'; hostnames = @('chat.example.com'); publish = $true; authProvider = 'authentik' }); prepared = $false; composeChanged = $false; updateAvailable = $false; updates = @(); catalog = $null }
$appB = [ordered]@{}; foreach ($k in $appA.Keys) { $appB[$k] = $appA[$k] }
$appB.project = 'rocketchat'; $appB.instanceId = 'legacy-rocketchat'; $appB.folder = 'C:\Users\me\.docker\projects\rocketchat'; $appB.lifecycle = $lcPrep; $appB.siblings = @('rocket-chat'); $appB.localUrl = 'http://127.0.0.1:3101/'; $appB.routes = @(); $appB.prepared = $true; $appB.running = 0; $appB.total = 0; $appB.composeChanged = $null
$appC = [ordered]@{}; foreach ($k in $appA.Keys) { $appC[$k] = $appA[$k] }
$appC.project = 'chat-lab'; $appC.label = 'Lab'; $appC.lifecycle = $lcFail; $appC.siblings = @(); $appC.routes = @()
$fillers = @(1..4 | ForEach-Object { $x = [ordered]@{}; foreach ($k in $appA.Keys) { $x[$k] = $appA[$k] }; $x.project = "filler-$_"; $x.name = "Filler $_"; $x.appId = 'echo'; $x.applicationId = 'echo'; $x.siblings = @(); $x.routes = @(); $x.lifecycle = (Get-DeploymentLifecycle -Containers @((New-Fact 'rocketchat' 'running' 0 '' $false 'unless-stopped'))); $x })
$detail = [ordered]@{ project = 'rocket-chat'; instanceId = 'legacy-rocket-chat'; name = 'Rocket.Chat'; label = ''; appId = 'rocketchat'; applicationId = 'rocketchat'; origin = 'installed'; folder = $appA.folder; archived = $false
  lifecycle = $lcRun; cleanup = @(Get-JobCleanupCandidates $lcRun); routes = $appA.routes
  networks = @([ordered]@{ name = 'proxynet'; shared = $true; private = $false; members = @([ordered]@{ container = 'rocket-chat-rocketchat'; project = 'rocket-chat'; service = 'rocketchat'; inThisApp = $true; ip = '172.25.0.9'; dnsNames = @('rocket-chat-rocketchat', 'rocketchat') }, [ordered]@{ container = 'traefik-ext1-traefik'; project = 'traefik-ext1'; service = 'traefik'; inThisApp = $false; ip = '172.25.0.5'; dnsNames = @('traefik-ext1-traefik', 'traefik') }) }
    [ordered]@{ name = 'rocket-chat_internal'; shared = $false; private = $true; members = @($facts | ForEach-Object { [ordered]@{ container = $_.name; project = 'rocket-chat'; service = $_.service; inThisApp = $true; ip = $_.networks[-1].ip; dnsNames = @($_.networks[-1].dnsNames) } }) })
  published = @([ordered]@{ container = 'rocket-chat-rocketchat'; port = '3000/tcp'; hostIp = '127.0.0.1'; hostPort = '3100'; localOnly = $true })
  volumes = @([ordered]@{ container = 'rocket-chat-rocketchat'; name = 'rocket-chat_uploads'; target = '/app/uploads'; readOnly = $false; anonymous = $false }, [ordered]@{ container = 'rocket-chat-mongodb'; name = 'rocket-chat_mongodb'; target = '/data/db'; readOnly = $false; anonymous = $false })
  cloudflare = @([ordered]@{ hostname = 'chat.example.com'; dnsRecord = $true; accessApp = $false }); authentik = @([ordered]@{ service = 'rocket-chat'; slug = 'dm-rocket-chat' }); composeChanged = $false; checkedAt = '2026-10-25T22:00:00' }
$existing = @([ordered]@{ source = 'registry'; project = 'rocket-chat'; instanceId = 'legacy-rocket-chat'; label = ''; folder = $appA.folder; archived = $false; origin = 'installed'; state = 'running'; headline = $lcRun.headline; containers = 5; hostnames = @('chat.example.com'); reason = "Registered in the manager as rocketchat (recorded as 'rocket-chat', an alias)." },
  [ordered]@{ source = 'registry'; project = 'rocketchat'; instanceId = 'legacy-rocketchat'; label = ''; folder = $appB.folder; archived = $false; origin = 'installed'; state = 'prepared'; headline = $lcPrep.headline; containers = 0; hostnames = @(); reason = "Registered in the manager as rocketchat (recorded as 'rocket-chat', an alias)." })
$fixtureJson = ConvertTo-Json -Depth 14 -Compress ([ordered]@{ apps = @(@($appA, $appB, $appC) + $fillers); detail = $detail; existing = $existing; secret = $secret })
$Shim = @'
(() => {
  const realFetch = window.fetch.bind(window);
  const F = __FIXTURES__;
  const calls = window.__apcalls = JSON.parse(sessionStorage.getItem('apcalls') || '[]');
  const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } });
  window.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    const record = () => { calls.push({ path: url.pathname + url.search, body: init && init.body ? String(init.body) : '' }); sessionStorage.setItem('apcalls', JSON.stringify(calls)); };
    if (url.pathname === '/api/apps') { record(); return json({ apps: F.apps, archived: [], discovered: [], checkedAt: '2026-10-25T22:00:00' }); }
    if (url.pathname === '/api/apps/detail') { record(); return url.searchParams.get('project') === 'rocket-chat' ? json(F.detail) : json(Object.assign({}, F.detail, { project: url.searchParams.get('project'), lifecycle: (F.apps.find((a) => a.project === url.searchParams.get('project')) || {}).lifecycle, cleanup: [], networks: [], published: [], volumes: [] })); }
    if (url.pathname === '/api/catalog/defaults') { record(); const r = await realFetch(input, init); const d = await r.json(); if (url.searchParams.get('id') === 'rocketchat') d.existing = F.existing; return json(d); }
    if (url.pathname === '/api/catalog/plan') { record(); }
    return realFetch(input, init);
  };
})();
'@.Replace('__FIXTURES__', $fixtureJson)

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-apb-$id"
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N')
$mock = $null; $ui = $null; $cdp = $null
function Js([string]$Expr) { return Invoke-PageScript $cdp $Expr }
function Shot([string]$Name) {
  if (-not $ScreenshotDir) { return }
  try { $null = Js 'window.scrollTo(0, 0); true'; $w = [int](Js 'window.innerWidth'); $hh = [int](Js 'window.innerHeight'); $full = [Math]::Min(8000, [int](Js 'document.documentElement.scrollHeight'))
    Set-Viewport $cdp $w $full -Mobile:($w -lt 800); Start-Sleep -Milliseconds 300; Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$Name.png"); Set-Viewport $cdp $w $hh -Mobile:($w -lt 800) } catch { Write-Host "  (screenshot $Name skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}
function Go([string]$Hash, [string]$Ready) { Open-Page $cdp "$base/#$Hash"; return (Wait-PageCondition $cdp "document.readyState === 'complete' && ($Ready)" 30) }

try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-apb-$id"
  $recs = @([ordered]@{ project = 'rocket-chat'; appId = 'rocket-chat'; name = 'Rocket.Chat'; folder = (Join-Path $work 'apps\rocket-chat'); prepared = $true; localPort = 3100 }, [ordered]@{ project = 'rocketchat'; appId = 'rocket-chat'; name = 'Rocket.Chat'; folder = (Join-Path $work 'apps\rocketchat'); prepared = $true; localPort = 3101 })
  [IO.File]::WriteAllText((Join-Path $install 'config\apps.json'), (([ordered]@{ version = 1; apps = $recs }) | ConvertTo-Json -Depth 5))
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $base = "http://127.0.0.1:$($ui.Port)"
  $cdp = Start-EdgeSession -WorkDir $work
  $null = Invoke-Cdp $cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Shim }
  Set-Viewport $cdp 1366 900
  Open-Page $cdp $ui.LaunchUrl
  $null = Wait-PageCondition $cdp "document.readyState === 'complete' && !!window.TPMApp" 30

  # --- Catalog --------------------------------------------------------------------------------------------------------
  $ok = Go 'catalog?level=intermediate' "document.querySelectorAll('.cat-card').length > 5"
  $cards = [string](Js "[...document.querySelectorAll('.cat-card')].map((c) => c.dataset.app).join(',')")
  Test-Condition 'catalog: Arcane, Portainer and What''s Up Docker have Install buttons' ($ok -and [int](Js "['arcane','portainer','whats-up-docker'].filter((i) => document.querySelector('.cat-card[data-app=' + JSON.stringify(i) + '] a[href=' + JSON.stringify('#install/' + i) + ']')).length") -eq 3) $cards
  Test-Condition 'catalog: Diun and Watchtower are not offered (no card, no install link)' ($cards -notmatch '(^|,)(diun|watchtower)(,|$)' -and [int](Js "document.querySelectorAll('a[href=\'#install/diun\'], a[href=\'#install/watchtower\']').length") -eq 0) $cards
  $rcCard = [string](Js "(document.querySelector('.cat-card[data-app=rocketchat]') || {}).innerText || ''")
  Test-Condition 'catalog: one Rocket.Chat entry, marked installed (2 instances) with Manage and "Install another…"' ([int](Js "[...document.querySelectorAll('.cat-card h2')].filter((x) => x.textContent === 'Rocket.Chat').length") -eq 1 -and $rcCard -match 'Installed: 2 instances' -and $rcCard -match 'Manage installations' -and $rcCard -match 'Install another') $rcCard
  Test-Condition 'catalog: Arcane is recommended; Dispatcharr''s modular compose is listed under Dispatcharr, not as its own card' ([string](Js "document.querySelector('.cat-card[data-app=arcane]').innerText") -match 'Recommended' -and $cards -notmatch 'dispatcharr-modular' -and [string](Js "document.querySelector('.cat-card[data-app=dispatcharr]').innerText") -match 'other ways to install') $cards
  Test-Condition 'catalog: PostgreSQL and Redis are building blocks, not app cards' ($cards -notmatch 'postgresql|redis' -and [string](Js "(document.querySelector('#cat-reference') || {}).textContent || ''") -match 'PostgreSQL') ''
  Shot 'catalog-offered'
  $null = Go 'catalog?level=advanced' "!!document.querySelector('#cat-retired')"
  $null = Js "document.querySelector('#cat-retired').open = true; document.querySelector('#cat-retired').scrollIntoView(); true"
  $ret = [string](Js "document.querySelector('#cat-retired').innerText")
  Test-Condition 'catalog (advanced): Diun and Watchtower are explained as no longer offered, existing installations kept' ($ret -match 'Diun' -and $ret -match 'Watchtower' -and $ret -match 'never removed' -and [int](Js "document.querySelectorAll('#cat-retired a[href^=\'#install\']').length") -eq 0) $ret
  Shot 'catalog-no-longer-offered'

  # --- Installed apps -----------------------------------------------------------------------------------------------------
  $ok = Go 'apps?level=intermediate' "document.querySelectorAll('.dep-card').length >= 3"
  $st = [string](Js "document.querySelector('#dep-rocket-chat-card .dep-status').innerText")
  Test-Condition 'apps: Rocket.Chat reads "3/3 running · 2 setup jobs completed" (not running 3/5), state running' ($ok -and $st -match '3/3 running' -and $st -match '2 setup jobs completed' -and $st -notmatch '3/5' -and [string](Js "document.querySelector('#dep-rocket-chat-card').dataset.state") -eq 'running') $st
  $hl = [string](Js "document.querySelector('#dep-rocket-chat-card .dep-health').innerText")
  Test-Condition 'apps: the health line says no failure was detected and NATS readiness is not verified (not "healthy")' ($hl -match 'No failures detected' -and $hl -match 'no health check') $hl
  Test-Condition 'apps: the prepared second installation is a separate card, "Prepared, not started", with the other one named' ([string](Js "document.querySelector('#dep-rocketchat-card .dep-status').innerText") -match 'Prepared, not started' -and [string](Js "document.querySelector('#dep-rocketchat-card').innerText") -match 'Another installation of Rocket.Chat is registered: rocket-chat') ''
  Test-Condition 'apps: a failed setup job turns the status into a problem' ([string](Js "document.querySelector('#dep-chat-lab-card').dataset.state") -eq 'failed' -and [string](Js "document.querySelector('#dep-chat-lab-card .dep-status').innerText") -match '1 setup job failed') ''
  Shot 'apps-status'
  # Expand the details, keeping the scroll position.
  $null = Js "document.querySelector('#dep-rocket-chat-card').scrollIntoView(); window.scrollBy(0, -80); true"; Start-Sleep -Milliseconds 200
  $y0 = [int](Js 'Math.round(window.scrollY)')
  $null = Js "document.querySelector('#dep-rocket-chat-card .dep-status').click(); true"
  $okD = Wait-PageCondition $cdp "document.querySelectorAll('#dep-rocket-chat .dep-svc').length === 5" 20
  $y1 = [int](Js 'Math.round(window.scrollY)')
  Test-Condition 'details: the status opens the service details in place (aria-expanded, no scroll jump)' ($okD -and [string](Js "document.querySelector('#dep-rocket-chat-card .dep-status').getAttribute('aria-expanded')") -eq 'true' -and [Math]::Abs($y1 - $y0) -le 2) "$y0 -> $y1"
  $groups = [string](Js "[...document.querySelectorAll('#dep-rocket-chat .dep-group h3')].map((x) => x.textContent).join('|')")
  Test-Condition 'details: long-running services (3) and setup jobs (2) are separate groups' ($groups -match 'Long-running services \(3\)' -and $groups -match 'Setup jobs \(run once, then exit\) \(2\)') $groups
  $svcState = [string](Js "[...document.querySelectorAll('#dep-rocket-chat .dep-svc')].map((x) => x.dataset.service + '=' + x.dataset.status).join(',')")
  Test-Condition 'details: Rocket.Chat and MongoDB healthy, NATS running without health check, both jobs completed' ($svcState -eq 'rocketchat=healthy,mongodb=healthy,nats=running-unverified,mongodb-fix-permission=completed,mongodb-init=completed') $svcState
  $init = [string](Js "document.querySelector('#dep-rocket-chat .dep-svc[data-service=\'mongodb-init\']').innerText")
  Test-Condition 'details: a job shows its exit code, that exiting was expected, its role and purpose, and a Logs button' ($init -match 'Exit code 0 \(expected\)' -and $init -match 'Setup job' -and $init -match 'replica set' -and $init -match 'Logs') $init
  $rcTxt = [string](Js "document.querySelector('#dep-rocket-chat .dep-svc[data-service=\'rocketchat\']').innerText")
  Test-Condition 'details: the app service shows its image (tag and digest), health check and dependencies' ($rcTxt -match 'rocket\.chat:8\.9\.0 @ sha256:' -and $rcTxt -match 'Health check: healthy' -and $rcTxt -match 'Waits for' -and $rcTxt -match 'mongodb \(healthy\)' -and $rcTxt -match 'nats \(started\)') $rcTxt
  $null = Js "[...document.querySelectorAll('#dep-rocket-chat details.dep-net')].forEach((d) => d.open = true); true"
  $net = [string](Js "[...document.querySelectorAll('#dep-rocket-chat .dep-net')].map((d) => d.innerText).join(' || ')")
  Test-Condition 'details: networks list the containers on them with their DNS names (shared proxynet with Traefik, the private network)' ($net -match 'proxynet' -and $net -match 'shared with Traefik' -and $net -match 'traefik-ext1-traefik' -and $net -match 'rocket-chat_internal' -and $net -match 'private to this app' -and $net -match 'mongodb') $net
  $pv = [string](Js "document.querySelector('#dep-rocket-chat').innerText")
  Test-Condition 'details: published port (127.0.0.1 only), volumes, hostname and authentik application are shown; tidy-up offered' ($pv -match '127\.0\.0\.1:3100' -and $pv -match 'This PC only' -and $pv -match 'rocket-chat_mongodb' -and $pv -match 'chat\.example\.com' -and $pv -match 'dm-rocket-chat' -and $pv -match 'Tidy up completed setup containers') ''
  Test-Condition 'secrets: no secret value appears on the page' ([string](Js 'document.body.innerText') -notmatch [regex]::Escape('Sup3rSecretPw')) ''
  Shot 'apps-rocketchat-details'
  # Refresh keeps the details open and the place on the page.
  $y2 = [int](Js 'Math.round(window.scrollY)')
  $null = Js "[...document.querySelectorAll('.page-head button')].find((b) => /Refresh/.test(b.textContent)).click(); true"
  Start-Sleep -Milliseconds 300
  $okR = Wait-PageCondition $cdp "document.querySelectorAll('#dep-rocket-chat .dep-svc').length === 5" 20
  $y3 = [int](Js 'Math.round(window.scrollY)')
  Test-Condition 'refresh: the details stay open and the page does not jump' ($okR -and [Math]::Abs($y3 - $y2) -le 4) "$y2 -> $y3"
  # Deep link from the catalog's Manage button.
  $ok = Go 'apps/rocketchat?level=intermediate' "!!document.querySelector('#dep-rocketchat:not([hidden]) .dep-svc')"
  Test-Condition 'navigation: #apps/<project> opens that installation''s details' $ok ''

  # --- Duplicate detection when installing ----------------------------------------------------------------------------
  $ok = Go 'install/rocketchat?level=intermediate' "!!document.querySelector('#inst-existing')"
  $ex = [string](Js "document.querySelector('#inst-existing').innerText")
  Test-Condition 'install: "Rocket.Chat is already installed" lists both installations with Manage / Archive / Uninstall' ($ok -and $ex -match 'already installed on this PC' -and $ex -match 'rocket-chat' -and $ex -match 'rocketchat' -and $ex -match 'Manage existing' -and $ex -match 'Archive obsolete record' -and $ex -match 'Uninstall') $ex
  Test-Condition 'install: the archive choice is offered only for the record without containers (rocketchat)' ([int](Js "[...document.querySelectorAll('#inst-existing .dep-existing')].filter((li) => /Archive obsolete record/.test(li.innerText)).map((li) => li.dataset.project).filter((p) => p === 'rocketchat').length") -eq 1 -and [int](Js "[...document.querySelectorAll('#inst-existing .dep-existing')].filter((li) => /Archive obsolete record/.test(li.innerText)).length") -eq 1) ''
  $null = Js "document.querySelector('#inst-existing').scrollIntoView(); true"
  Shot 'install-duplicate-detected'
  $null = Js "document.querySelector('#inst-another').click(); true"
  $okL = Wait-PageCondition $cdp "!!document.querySelector('#inst-label')" 10
  $null = Js "const l = document.querySelector('#inst-label'); l.value = 'Testing'; l.dispatchEvent(new Event('change')); true"
  $null = Js "[...document.querySelectorAll('button')].find((b) => /Preview the Compose project|Preview again/.test(b.textContent)).click(); true"
  $okP = Wait-PageCondition $cdp "JSON.stringify(window.__apcalls || []).includes('anotherInstance')" 30
  $body = [string](Js "JSON.stringify((window.__apcalls || []).filter((c) => c.path === '/api/catalog/plan').slice(-1)[0] || {})")
  Test-Condition 'install: choosing "another, separate instance" asks for a label and sends it with the preview' ($okL -and $okP -and $body -match 'anotherInstance\\":true' -and $body -match 'Testing') $body

  # --- Phone layout ---------------------------------------------------------------------------------------------------------
  Set-Viewport $cdp 390 844 -Mobile
  $ok = Go 'apps/rocket-chat?level=intermediate' "document.querySelectorAll('#dep-rocket-chat .dep-svc').length === 5"
  $over = [int](Js 'document.scrollingElement.scrollWidth - window.innerWidth')
  $btnW = [int](Js "Math.round(document.querySelector('#dep-rocket-chat-card .dep-status').getBoundingClientRect().width)")
  Test-Condition 'phone (390 px): details readable without horizontal scrolling; the status spans the card' ($ok -and $over -le 1 -and $btnW -gt 250) "overflow=$over status=$btnW"
  Shot 'apps-rocketchat-details-390'
  $ok = Go 'catalog?level=intermediate' "document.querySelectorAll('.cat-card').length > 5"
  Test-Condition 'phone (390 px): the catalog has no horizontal scrolling' ($ok -and [int](Js 'document.scrollingElement.scrollWidth - window.innerWidth') -le 1) ''
} finally {
  if ($cdp) { Stop-EdgeSession $cdp }
  if ($ui) { Stop-TestServer $ui }
  if ($mock) { Stop-TestServer $mock }
  Get-ChildItem $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host ("`n{0} passed, {1} failed, {2} skipped" -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $fail, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($fail) { exit 1 }
