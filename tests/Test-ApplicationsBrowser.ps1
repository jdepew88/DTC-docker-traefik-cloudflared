#requires -version 5.1
<#
.SYNOPSIS
  Browser test of the Applications page (ownership modes, Add application entry points, integrate, drift, repair,
  removal) and of the pasted Compose / Unraid inputs on the New app page, in headless Edge without Docker (small
  memory footprint).

.DESCRIPTION
  Runs webui.ps1 for a throwaway install folder (Cloudflare API mock). /api/applications*, /api/integrations* and
  POST /api/provision/import are answered by an in-page stand-in with server-shaped responses; everything else goes
  to the real server. Checks that each mode is labelled, that the management tool and its evidence are shown, that
  integrate / repair / removal stay disabled until reviewed, that a repair the owner must make is shown as
  instructions (never applied), detail levels and a 390 px layout.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-ApplicationsBrowser.ps1 -ScreenshotDir .\ui-screens
#>
param([string]$ScreenshotDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
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

$Shim = @'
(() => {
  window.__errs = [];
  window.addEventListener('error', (e) => window.__errs.push(String(e.message)));
  window.addEventListener('unhandledrejection', (e) => window.__errs.push(String(e.reason && e.reason.message || e.reason)));
  const realFetch = window.fetch.bind(window);
  const st = window.__appmock = { calls: [], integrated: false, repaired: false, removed: false };
  const json = (o, status) => new Response(JSON.stringify(o), { status: status || 200, headers: { 'Content-Type': 'application/json' } });
  const modes = { managed: { summary: 'DTC owns the stack.', lifecycle: true, routes: true }, integrated: { summary: 'Another tool owns the stack; DTC owns only its routes.', lifecycle: false, routes: true }, observed: { summary: 'DTC only lists and monitors it.', lifecycle: false, routes: false } };
  const portainer = { id: 'portainer', label: 'Portainer', confidence: 'certain', evidence: ['label io.portainer.accesscontrol.public'] };
  const apps = () => ({ contractVersion: 1, proxyNetwork: 'dm-proxy', modes,
    entryPoints: [{ id: 'catalog', label: 'Browse curated applications', href: '#catalog' }, { id: 'link', label: 'Paste a Docker Hub or GitHub link', href: '#provision' }, { id: 'compose', label: 'Import Compose', href: '#provision?source=compose' }, { id: 'unraid', label: 'Import an Unraid template', href: '#provision?source=unraid' }, { id: 'discover', label: 'Discover existing Docker applications', href: '#applications' }],
    applications: [
      { instanceId: 'i-a1b2c3', name: 'Uptime Kuma', mode: 'managed', authority: { id: 'dtc', label: 'DTC (this Deployment Manager)', confidence: 'certain', evidence: ['Registered in apps.json (installed)'] }, recipe: 'catalog:uptime-kuma@2026.10.21', trust: { level: 'curated', status: 'verified' }, project: 'kuma', containers: [{ name: 'kuma-app-1', state: 'running', health: 'healthy' }], routes: [{ name: 'kuma', hostnames: ['kuma.home.example'], enabled: true, owner: 'unrecorded', protection: '', publish: false }] },
    ].concat(st.integrated && !st.removed ? [{ instanceId: 'x-0123456789ab', name: 'Wiki', mode: 'integrated', authority: portainer, recipe: 'none', trust: { level: 'external', status: 'not-applicable' }, project: 'wiki', containers: [{ name: 'wiki-web-1', state: 'running', health: '' }], routes: [{ name: 'wiki', hostnames: ['wiki.home.example'], enabled: true, owner: 'this-instance', protection: '', publish: false }], found: true }] : []),
    unmanaged: st.integrated && !st.removed ? [] : [{ key: 'project:wiki', name: 'wiki', project: 'wiki', authority: portainer, suggestedMode: 'integrated', frontend: { container: 'wiki-web-1', service: 'web', onProxyNetwork: true, ports: [{ port: 3000, guess: 'http' }] }, containers: [{ name: 'wiki-web-1', image: 'example/wiki:2', state: 'running', privateService: false }, { name: 'wiki-db-1', image: 'postgres:16', state: 'running', privateService: true }], routes: [] }] });
  const drift = () => st.repaired ? { instanceId: 'x-0123456789ab', mode: 'integrated', summary: { state: 'in-sync', errors: 0, warnings: 0, total: 0 }, findings: [], repair: { canApply: false, external: [] } }
    : { instanceId: 'x-0123456789ab', mode: 'integrated', summary: { state: 'drifted', errors: 2, warnings: 0, total: 3 }, findings: [
      { id: 'container-replaced', severity: 'info', title: 'The container was recreated', explanation: 'Portainer replaced the container.', repair: null },
      { id: 'port-changed', severity: 'error', title: 'The application no longer listens on port 3000', explanation: 'The route uses port 3000, but the container now exposes 3001.', repair: { kind: 'route-update', owner: 'dtc', automatic: true, description: 'Use port 3001 in the route.', change: { route: 'wiki', port: 3001 } } },
      { id: 'off-proxy-network', severity: 'error', title: 'Traefik cannot reach the application', explanation: 'The application is running, but Traefik cannot reach its configured backend. Its network membership changed after Portainer recreated the container.', repair: { kind: 'network-connect', owner: 'external', automatic: false, description: "Add the shared network in Portainer's Compose file.", snippet: ['networks:', '  dm-proxy:', '    external: true'] } }],
      repair: { canApply: true, external: [{ finding: 'off-proxy-network' }] } };
  window.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    const method = ((init && init.method) || 'GET').toUpperCase();
    const ours = url.pathname.startsWith('/api/applications') || url.pathname.startsWith('/api/integrations') || url.pathname === '/api/provision/import';
    if (!ours) return realFetch(input, init);
    const body = init && init.body ? JSON.parse(init.body) : null;
    st.calls.push({ method, path: url.pathname, body });
    switch (url.pathname) {
      case '/api/applications': return json(apps());
      case '/api/applications/observe': return json({ ok: true, instance: { instanceId: 'x-0000000000aa', mode: 'observed' } });
      case '/api/integrations/plan': return json({ planId: 'ip1', container: body.container, route: 'wiki', hostname: body.hostname, backendUrl: 'http://wiki-web-1:3000', warnings: [], canApply: true, needsBackendAck: false,
        ownership: { mode: 'integrated', authority: portainer, rights: modes.integrated, keeps: ['wiki-web-1 and its Compose project stay with Portainer: DTC does not recreate, restart or edit them.', 'Only the route created here belongs to DTC.'] },
        authentication: { recommended: 'local-only', options: [{ id: 'native', name: "The application's own login", state: 'not-configured', available: true, notes: ['Never disabled by DTC.'] }, { id: 'authentik-forwardauth', name: 'authentik ForwardAuth', state: 'not-configured', available: false, notes: ['Identity & Access (authentik) is not ready in this deployment.'] }] },
        plan: { traefik: { changes: [{ file: 'traefik\\dynamic\\svc-wiki.yml', action: 'create', diff: ['+ http:', '+   # Owner: integration x-0123456789ab'] }], issues: [] }, cloudflare: { actions: [], notes: [], errors: [], manualSteps: [] }, backend: { state: 'ok', message: 'HTTP 200 from the shared network' } } });
      case '/api/integrations/apply': st.integrated = true; return json({ ok: true, instanceId: 'x-0123456789ab', route: 'wiki' });
      case '/api/applications/drift': return json(drift());
      case '/api/applications/repair/plan': return json({ instanceId: 'x-0123456789ab', key: 'k1', canApply: true, routeChanges: [{ summary: "Update route 'wiki'", plan: { traefik: { changes: [{ file: 'traefik\\dynamic\\svc-wiki.yml', action: 'update', diff: ['-     - url: http://wiki-web-1:3000', '+     - url: http://wiki-web-1:3001'] }] } } }],
        external: [{ finding: 'off-proxy-network', description: "Add the shared network in Portainer's Compose file.", snippet: ['networks:', '  dm-proxy:', '    external: true'], owner: 'external' }], notes: ['Only routes DTC owns are changed.'] });
      case '/api/applications/repair/apply': st.repaired = true; return json({ ok: true, results: [{ summary: "Update route 'wiki'", ok: true }] });
      case '/api/integrations/remove/plan': return json({ instanceId: 'x-0123456789ab', name: 'Wiki', key: 'r1', removes: [{ route: 'wiki', hostnames: ['wiki.home.example'], protection: '', cloudflare: false }], keeps: ['The containers, Compose files, volumes and networks of Wiki (Portainer) are not touched.'] });
      case '/api/integrations/remove': st.removed = true; return json({ ok: true, steps: ['Route wiki: removed'] });
      case '/api/provision/import': return json({ error: 'The project link must be an https:// address.' }, 422);
      default: return json({ error: `Not available in this test (${url.pathname}).` }, 404);
    }
  };
})();
'@

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-appsb-$id"
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
$mock = $null; $ui = $null; $cdp = $null
function Js([string]$Expr) { return Invoke-PageScript $cdp $Expr }
function Shot([string]$Name) { if (-not $ScreenshotDir) { return }; try { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$Name.png") } catch { Write-Host "  (screenshot $Name skipped: $($_.Exception.Message))" } }
function Click([string]$Sel) { return (Js "(() => { const e = document.querySelector('$Sel'); if (!e) return 'missing'; if (e.disabled) return 'disabled'; e.click(); return 'ok'; })()") }
function Wait([string]$Cond, [int]$Seconds = 15) { return (Wait-PageCondition $cdp $Cond $Seconds) }
function Calls([string]$Path) { return @((Js "JSON.stringify(window.__appmock.calls.filter((c) => c.path === '$Path'))") | ConvertFrom-Json) }

try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-appsb-$id"
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token ('mockTok_' + [Guid]::NewGuid().ToString('N'))
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $base = "http://127.0.0.1:$($ui.Port)"
  $cdp = Start-EdgeSession -WorkDir $work
  $null = Invoke-Cdp $cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Shim }
  Set-Viewport $cdp 1366 800
  Open-Page $cdp $ui.LaunchUrl
  $null = Wait "document.readyState === 'complete' && !!window.TPMApp" 30
  Open-Page $cdp "$base/?r=$id#applications?level=intermediate"
  $ok = Wait "!!document.querySelector('#apps-list') && !!document.querySelector('#apps-unmanaged')" 30
  Test-Condition 'page: Applications is in the navigation; known applications and containers found on the engine are listed' ($ok -and (Js "!!document.querySelector('#rail a[href=""#applications""]')")) ''
  $entries = Js "Array.from(document.querySelectorAll('.entry-card[data-entry]')).map((a) => a.dataset.entry).join(',')"
  Test-Condition 'add application: catalog, link, Compose, Unraid template and existing Docker apps converge on one flow' ($entries -eq 'catalog,link,compose,unraid,discover') $entries
  $card = Js "document.querySelector('[data-instance=i-a1b2c3]').textContent"
  $found = Js "document.querySelector('[data-unmanaged=wiki]').textContent"
  Test-Condition 'modes and authority: a managed app is labelled DTC Managed with its recipe and trust; a found Portainer stack shows Portainer and a suggested mode; its database is marked private' (
    $card -match 'DTC Managed' -and $card -match 'catalog:uptime-kuma' -and $card -match 'curated' -and $found -match 'Portainer' -and $found -match 'suggested: DTC Integrated' -and $found -match 'wiki-db-1 \(private\)') "$card | $found"
  Shot 'applications-1-list'

  # Integrate the found stack.
  $null = Click '[data-unmanaged=wiki] [data-action=integrate]'
  $null = Wait "!!document.querySelector('[data-unmanaged=wiki] form')" 10
  $null = Js "document.querySelector('[data-unmanaged=wiki] input[type=text]').value = 'wiki.home.example'; true"
  $null = Click '[data-unmanaged=wiki] [data-action=integrate-plan]'
  $ok = Wait "!!document.querySelector('[data-action=integrate-apply]')" 10
  $preview = Js "document.querySelector('[data-unmanaged=wiki] .app-detail').textContent"
  Test-Condition 'integrate: the preview shows the route file, that the containers stay with Portainer, the sign-in options and states; Integrate is disabled until reviewed' (
    $ok -and $preview -match 'svc-wiki.yml' -and $preview -match 'stay with Portainer' -and $preview -match 'not-configured' -and (Js "document.querySelector('[data-action=integrate-apply]').disabled")) $preview
  $plan = @(Calls '/api/integrations/plan')[0]
  Test-Condition 'integrate: the plan request names the container, its web port and the host name; nothing is published unless chosen' ($plan.body.container -eq 'wiki-web-1' -and $plan.body.port -eq 3000 -and $plan.body.hostname -eq 'wiki.home.example' -and -not $plan.body.publish) ($plan | ConvertTo-Json -Compress)
  $null = Js "document.querySelector('[data-unmanaged=wiki] .app-detail .actions input[type=checkbox]').click(); true"
  $null = Click '[data-action=integrate-apply]'
  $ok = Wait "!!document.querySelector('[data-instance=x-0123456789ab]')" 15
  Test-Condition 'integrate: after approval the app is listed as DTC Integrated with the route it owns' ($ok -and (Js "document.querySelector('[data-instance=x-0123456789ab]').textContent") -match 'DTC Integrated' -and (Js "document.querySelector('[data-instance=x-0123456789ab]').textContent") -match 'route owned by this integration') ''

  # Drift and repair.
  $null = Click '[data-instance=x-0123456789ab] [data-action=drift]'
  $ok = Wait "!!document.querySelector('[data-instance=x-0123456789ab] [data-drift]')" 10
  $dr = Js "document.querySelector('[data-instance=x-0123456789ab] .app-detail').textContent"
  Test-Condition 'drift: findings with their explanation, and who must act (DTC or the application''s owner)' ($ok -and $dr -match 'Drift found' -and $dr -match 'after Portainer recreated' -and $dr -match 'DTC can repair this' -and $dr -match "For the application's owner") $dr
  $null = Click '[data-instance=x-0123456789ab] [data-action=repair-plan]'
  $ok = Wait "!!document.querySelector('[data-action=repair-apply]')" 10
  $rp = Js "document.querySelector('[data-instance=x-0123456789ab] .app-detail').textContent"
  Test-Condition 'repair: the DTC-owned route change is shown as a diff; the owner''s part is instructions with the Compose lines; Apply is disabled until reviewed' ($ok -and $rp -match '3001' -and $rp -match 'external: true' -and $rp -match 'DTC does not change it' -and (Js "document.querySelector('[data-action=repair-apply]').disabled")) $rp
  Shot 'applications-2-repair'
  $null = Js "document.querySelector('[data-instance=x-0123456789ab] .app-detail .actions input[type=checkbox]').click(); true"
  $null = Click '[data-action=repair-apply]'
  $null = Wait "window.__appmock.repaired && !!document.querySelector('[data-instance=x-0123456789ab]')" 10
  $apply = @(Calls '/api/applications/repair/apply')[0]
  Test-Condition 'repair: the apply request confirms the reviewed preview (key)' ($apply.body.confirm -and $apply.body.key -eq 'k1') ($apply | ConvertTo-Json -Compress)

  # Removal leaves the application.
  $null = Wait "!!document.querySelector('[data-instance=x-0123456789ab] [data-action=remove]')" 10
  $null = Click '[data-instance=x-0123456789ab] [data-action=remove]'
  $ok = Wait "!!document.querySelector('[data-action=remove-apply]')" 10
  $rm = Js "document.querySelector('[data-instance=x-0123456789ab] .app-detail').textContent"
  Test-Condition 'remove: the preview lists the route to remove and what is kept (containers, Compose files, volumes); disabled until confirmed' ($ok -and $rm -match 'Route wiki' -and $rm -match 'not touched' -and (Js "document.querySelector('[data-action=remove-apply]').disabled")) $rm

  # Optional Portainer / Arcane connectors (real server: the key is stored with DPAPI; nothing answers on the address).
  Open-Page $cdp "$base/?r=$id#applications?level=intermediate"
  $ok = Wait "!!document.querySelector('#mgr-form')" 30
  $null = Js "{ const k = document.querySelector('#mgr-kind'); k.value = 'arcane'; k.dispatchEvent(new Event('change')); true }"
  Test-Condition 'connectors: optional; Arcane shows its read-only permissions, the key field is a password field' ($ok -and (Js "document.querySelector('#mgr-scope').textContent") -match 'projects:read' -and (Js "document.querySelector('#mgr-key').type") -eq 'password') (Js "document.querySelector('#mgr-scope').textContent")
  $null = Js "{ const k = document.querySelector('#mgr-kind'); k.value = 'portainer'; k.dispatchEvent(new Event('change')); true }"
  Test-Condition 'connectors: Portainer says its token cannot be restricted to read-only' ((Js "document.querySelector('#mgr-scope').textContent") -match 'no read-only role') ''
  $deadPort = Get-FreeTcpPort
  $null = Js "document.querySelector('#mgr-url').value = 'http://127.0.0.1:$deadPort'; document.querySelector('#mgr-key').value = 'browser-test-key-123'; true"
  $null = Click '#mgr-save'
  $ok = Wait "!!document.querySelector('[data-connector=portainer]')" 20
  $null = Click '[data-connector=portainer] [data-action=manager-test]'
  $null = Wait "/did not answer/.test(document.querySelector('[data-connector=portainer]').textContent)" 30
  Test-Condition 'connectors: saved, tested (the address does not answer: reported, nothing breaks), the key never shown' ($ok -and (Js "document.querySelector('[data-connector=portainer]').textContent") -match 'did not answer' -and (Js "document.body.textContent") -notmatch 'browser-test-key-123') ''
  $null = Click '[data-connector=portainer] [data-action=manager-delete]'
  $ok = Wait "!document.querySelector('[data-connector=portainer]') && !!document.querySelector('#mgr-form')" 20
  Test-Condition 'connectors: removing it removes the stored key too' ($ok -and -not (Test-Path -LiteralPath (Join-Path $install 'secrets\manager-portainer-api.dpapi'))) ''

  # Expert level shows the raw registry view.
  Open-Page $cdp "$base/?r=$id#applications?level=expert"
  $ok = Wait "!!document.querySelector('#apps-list')" 20
  Test-Condition 'expert: the complete registry view (contract version) is inspectable' ($ok -and (Js "document.body.textContent") -match 'contract version 1') ''

  # New app: pasted Compose and Unraid templates.
  Open-Page $cdp "$base/?r=$id#provision?source=compose&level=intermediate"
  $ok = Wait "!!document.querySelector('#prov-text-0') && !!document.querySelector('#prov-source-url')" 30
  Test-Condition 'new app: "Import Compose" opens the pasted Compose form (main file, override file, project link)' ($ok -and (Js "!!document.querySelector('#prov-text-1')") -and (Js "document.querySelector('input[name=prov-source][value=compose]').checked")) ''
  $null = Js "document.querySelector('#prov-text-0').value = 'services:\n  a:\n    image: x'; document.querySelector('#prov-source-url').value = 'http://example.com'; true"
  $null = Click '#prov-import-text'
  $null = Wait "window.__appmock.calls.some((c) => c.path === '/api/provision/import')" 10
  $imp = @(Calls '/api/provision/import')[0]
  $null = Wait "document.querySelector('#toast') && /https/.test(document.querySelector('#toast').textContent)" 10
  Test-Condition 'new app: the pasted text is sent as Compose with its project link; a refusal is shown with the reason' ($imp.body.format -eq 'compose' -and @($imp.body.texts).Count -eq 1 -and $imp.body.sourceUrl -eq 'http://example.com' -and (Js "document.querySelector('#toast').textContent") -match 'https') ($imp | ConvertTo-Json -Compress)
  $null = Js "document.querySelector('input[name=prov-source][value=unraid]').click(); true"
  $ok = Wait "!!document.querySelector('#prov-text-0') && !document.querySelector('#prov-text-1')" 10
  Test-Condition 'new app: the Unraid template form takes one template' ($ok) ''

  Open-Page $cdp "$base/?r=$id#applications?level=beginner"
  $null = Wait "!!document.querySelector('#apps-list')" 20
  Set-Viewport $cdp 390 844 -Mobile
  Start-Sleep -Milliseconds 400
  $overflow = Js "document.documentElement.scrollWidth - document.documentElement.clientWidth"
  Test-Condition 'mobile: the Applications page fits a 390 px wide screen' ([int]$overflow -le 1) "overflow=$overflow"
  Shot 'applications-3-mobile'
  $errs = Js "JSON.stringify(window.__errs || [])"
  Test-Condition 'no script errors' ($errs -eq '[]') $errs
} finally {
  if ($cdp) { Stop-EdgeSession $cdp }
  if ($ui) { Stop-TestServer $ui }
  if ($mock) { New-Item -ItemType File -Force -Path $mock.StopFile | Out-Null; Start-Sleep -Milliseconds 300; Stop-Process -Id $mock.Process.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count) { exit 1 }
