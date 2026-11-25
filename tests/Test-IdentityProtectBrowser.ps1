#requires -version 5.1
<#
.SYNOPSIS
  Browser test of the Identity & Access wizard's completion indicators and protection management (steps 8 and 9),
  without Docker or authentik (small memory footprint).

.DESCRIPTION
  Runs webui.ps1 for a throwaway install folder (Cloudflare API mock) in headless Edge. /api/identity is answered by an
  in-page stand-in: the real GET /api/identity response, completed as if authentik were installed, connected and the
  owner verified, with eight applications plus the authentik sign-in page. The stand-in returns ForwardAuth evidence
  only when the page asks for the probe (probe=apps), as the server does. Covers: step 8 and 9 green checks with the
  real protected count (8/8), returning to completed steps, a failing application, a deliberately skipped step 8,
  protecting more applications, and removing protection safely (preview of what stays, Cloudflare Access kept,
  acknowledgement before an application becomes public). Live protection is never touched.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-IdentityProtectBrowser.ps1 -ScreenshotDir .\ui-screens
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
  const realFetch = window.fetch.bind(window);
  const names = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
  const saved = (() => { try { return JSON.parse(sessionStorage.getItem('idpmock') || 'null'); } catch (e) { return null; } })();
  const st = window.__idpmock = Object.assign({ protected: names.slice(), failing: [], skippedAt: '', calls: [] }, saved || {});
  const persist = () => { try { sessionStorage.setItem('idpmock', JSON.stringify(st)); } catch (e) { } };
  const label = (n) => `App ${n.toUpperCase()}`;
  const host = (n) => `${n}.idtest.example`;
  const json = (o, status) => new Response(JSON.stringify(o), { status: status || 200, headers: { 'Content-Type': 'application/json' } });
  window.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    const method = ((init && init.method) || 'GET').toUpperCase();
    if (!url.pathname.startsWith('/api/identity')) return realFetch(input, init);
    const body = init && init.body ? JSON.parse(init.body) : null;
    st.calls.push({ method, path: url.pathname, query: url.search, body }); persist();
    if (url.pathname === '/api/identity' && method === 'GET') {
      let d = {};
      try { const r = await realFetch('/api/identity', init); if (r.ok) d = await r.json(); } catch (e) { }
      const probe = url.searchParams.get('probe') === 'apps';
      const cfg = d.config = d.config || {};
      cfg.provider = 'authentik'; cfg.authMode = 'local'; cfg.wizardStep = cfg.wizardStep || 'apps'; cfg.protectSkippedAt = st.skippedAt;
      cfg.authentik = Object.assign({}, cfg.authentik, { publicUrl: 'https://auth.idtest.example', hostname: 'auth.idtest.example', service: 'authentik',
        owner: { email: 'owner@idtest.example', makeAdmin: true, username: 'owner', verifiedAt: '2026-10-25T10:00:00' } });
      d.install = Object.assign({}, d.install, { server: { state: 'running', health: 'healthy' }, localUrl: 'http://127.0.0.1:9000', serverContainer: 'authentik-server' });
      d.health = Object.assign({}, d.health, { Ready: true, Setup: 'done' });
      d.credential = { status: 'valid', ok: true, stored: true, username: 'akadmin' };
      d.token = { ok: true, username: 'akadmin' };
      d.route = { exists: true, router: 'enabled', hostname: 'auth.idtest.example' };
      d.overview = Object.assign({}, d.overview, { outpost: { authentikHost: 'https://auth.idtest.example/' } });
      d.adminLinks = { base: 'https://auth.idtest.example' };
      d.services = names.map((n) => ({ name: n, displayName: label(n), enabled: true, hostnames: [host(n)], auth: st.protected.includes(n) ? 'authentik' : 'none', publish: n === 'b', access: false, isIdentity: false }))
        .concat([{ name: 'authentik', displayName: 'authentik (sign-in)', enabled: true, hostnames: ['auth.idtest.example'], auth: '', publish: true, access: false, isIdentity: true }]);
      d.apps = st.protected.map((n) => ({ service: n, displayName: label(n), hostname: host(n), protected: true, authentik: true, enabled: true, slug: `dm-${n}`, verifiedAt: '', rules: 1, ownerOnly: true,
        forwardAuth: { configured: true, loaded: true },
        challenge: probe ? (st.failing.includes(n) ? { State: 'open', Message: 'The application answered without asking for sign-in.' } : { State: 'auth', Message: 'Sign-in required (authentik).' }) : null }));
      // Launcher rows as the server builds them (lib\AccessDiagnostics.psm1): C is stopped, E's container is missing,
      // D still has the Cloudflare Access application DTC created (a redundant second login) until it is removed.
      d.adminLinks.public = true;
      const ctrs = { c: 'exited', e: 'missing' };
      d.launcher = names.map((n) => {
        const prot = st.protected.includes(n);
        const redundant = prot && n === 'd' && !st.accessRemoved;
        const ctr = ctrs[n] || 'running';
        const problems = [];
        if (redundant) problems.push({ state: 'redundant-access', tone: 'warn', label: 'Redundant Cloudflare login', message: "Cloudflare Access application 'd.idtest.example (stack)' asks for its own login (email code) before authentik. It was created by DTC and is no longer wanted: authentik protects this application.", fix: 'Remove the redundant Cloudflare Access (preview first).' });
        if (ctr === 'missing') problems.push({ state: 'missing-container', tone: 'err', label: 'Container missing', message: 'The target container does not exist. After signing in, visitors get "Bad gateway".', fix: 'Install or start the application.' });
        if (ctr === 'exited') problems.push({ state: 'stopped', tone: 'warn', label: 'Stopped', message: 'The container is exited. After signing in, visitors get "Bad gateway" (an availability error, not a sign-in problem).', fix: 'Start the application on the Installed apps page.' });
        const first = problems[0] || (prot ? { state: 'healthy', tone: 'ok', label: 'Healthy, protected', message: '', fix: '' } : n === 'b' ? { state: 'missing-protection', tone: 'warn', label: 'Public without sign-in', message: 'Anyone on the Internet can open it.', fix: '' } : { state: 'unpublished', tone: 'neutral', label: 'Local only (not published)', message: '', fix: '' });
        return { service: n, displayName: label(n), hostname: host(n), openUrl: n === 'b' ? `https://${host(n)}/` : `http://${host(n)}:8180/`, publish: n === 'b', enabled: true,
          authentikUrl: prot ? `https://auth.idtest.example/if/admin/#/core/applications/dm-${n}` : '', authentikUrlPublic: true,
          container: n === 'b' ? { name: '', state: 'host', listening: false } : { name: n, state: ctr }, router: 'enabled', target: `http://${n}:80`, authMode: prot ? 'authentik' : 'none', authModeLabel: prot ? 'authentik ForwardAuth' : 'No external sign-in',
          access: { checked: true, error: '', managedAppId: redundant ? 'acc-d' : '', apps: redundant ? [{ id: 'acc-d', name: 'd.idtest.example (stack)', pattern: host('d'), wildcard: false, pathOnly: false, createdByTool: true }] : [] },
          diagnosis: Object.assign({}, first, { problems }) };
      });
      return json(d);
    }
    if (url.pathname === '/api/identity/trace') {
      const n = body.service; const red = n === 'd' && !st.accessRemoved;
      const hop = red ? { url: `https://${host(n)}/`, status: 302, kind: 'cloudflare-access', next: `https://team.cloudflareaccess.com/cdn-cgi/access/login/${host(n)}`, error: '' } : { url: `https://${host(n)}/`, status: 302, kind: 'authentik', next: 'https://auth.idtest.example/application/o/authorize/', error: '' };
      return json({ service: n, hostname: host(n), mode: 'authentik', modeLabel: 'authentik ForwardAuth', checkedAt: '2026-11-24T10:00:00',
        public: { hops: [hop], component: red ? 'Cloudflare Access' : 'authentik', message: red ? 'Cloudflare Access answers first and asks for its own login (email code or its identity providers), before Traefik and authentik see the request. This is a redundant second login: authentik already protects this application.' : 'Traefik asked authentik (ForwardAuth); an anonymous visitor is sent to the central authentik sign-in.' },
        local: { hops: [{ url: `http://${host(n)}/ (via this PC's Traefik)`, status: 302, kind: 'authentik', next: 'https://auth.idtest.example/application/o/authorize/', error: '' }], component: 'authentik', message: 'Traefik asked authentik (ForwardAuth).' } });
    }
    if (url.pathname === '/api/identity/access/plan') {
      const n = body.service;
      return json({ planId: 'plan-a', service: n, hostname: host(n), canApply: true, challenge: { state: 'auth', message: 'Sign-in required: redirected to auth.idtest.example/application/o/authorize/.' },
        actions: [{ id: `access:delete:${host(n)}`, summary: `Delete Access application '${host(n)} (stack)' (created by this tool)`, detail: `Cloudflare Access was already turned off for ${host(n)}, but the Access application this tool created was left behind, so Cloudflare no longer asks for its own login (email code) first. authentik stays the sign-in.` }],
        notes: [], keeps: [`authentik ForwardAuth in front of ${host(n)} (verified just now: anonymous visitors are sent to sign in)`, 'The Traefik route, DNS record and tunnel route', 'Access applications DTC did not create'],
        rollback: `To put the Cloudflare login back, edit '${n}' on the Services page, turn on "Require Cloudflare Access" and choose layered authentication.` });
    }
    if (url.pathname === '/api/identity/access/apply') {
      st.accessRemoved = true; persist();
      return json({ ok: true, service: 'd', hostname: host('d'), steps: [{ name: `Delete Access application '${host('d')} (stack)' (created by this tool)`, status: 'Done', message: '' }], message: `Done: ${host('d')} now goes straight to authentik.` });
    }
    if (url.pathname === '/api/identity/wizard') { if (body && body.skip === 'apps') { st.skippedAt = '2026-10-26T09:00:00'; persist(); } return json({ ok: true }); }
    const tf = (n) => ({ traefik: { changes: [{ action: 'update', file: `svc-${n}.yml`, diff: '' }], issues: [] }, cloudflare: { actions: [] } });
    if (url.pathname === '/api/identity/protect/plan') {
      return json({ planId: 'plan-p', canApply: true, items: body.services.map((n) => ({ service: n, displayName: label(n), hostname: host(n), notes: [], authentik: [{ kind: 'none', object: 'application', summary: `Reuse application dm-${n}` }], traefik: tf(n) })) });
    }
    if (url.pathname === '/api/identity/protect/apply') {
      const plan = st.calls.filter((c) => c.path === '/api/identity/protect/plan').pop();
      const chosen = plan ? plan.body.services : [];
      chosen.forEach((n) => { if (!st.protected.includes(n)) st.protected.push(n); }); st.skippedAt = ''; persist();
      return json({ ok: true, message: `${chosen.length} application(s) protected.`, results: chosen.map((n) => ({ service: n, ok: true, challenge: { State: 'auth', Message: 'Anonymous visitors are sent to sign in.' }, traefik: { steps: [] } })) });
    }
    if (url.pathname === '/api/identity/unprotect/plan') {
      const n = body.service;
      return json({ planId: 'plan-u', canApply: true, items: [{ service: n, displayName: label(n), hostname: host(n), becomesPublic: n === 'b',
        notes: [n === 'b' ? 'After this, the application is reachable WITHOUT any sign-in by anyone on the Internet (public, no Cloudflare Access). Its own login is the only protection.' : 'After this, the application is reachable from this PC without sign-in.', 'The authentik application and its access rules stay in authentik; protecting it again reuses them.'],
        keeps: ['The container and the application itself', `The route: ${host(n)} still goes to http://${n}:80`, `authentik: the application dm-${n}, its provider, users, groups and access rules (protecting again reuses them)`, n === 'b' ? 'Cloudflare DNS record and tunnel route' : 'Local only: nothing is published'],
        authentik: [{ kind: 'update', object: 'outpost', summary: `Unassign 'dm-${n}' from the embedded outpost` }, { kind: 'none', object: 'application', summary: `Application 'dm-${n}', its provider and its access rules stay in authentik (protecting again reuses them)` }],
        traefik: tf(n) }] });
    }
    if (url.pathname === '/api/identity/unprotect/apply') {
      const plan = st.calls.filter((c) => c.path === '/api/identity/unprotect/plan').pop();
      st.protected = st.protected.filter((x) => x !== plan.body.service); persist();
      return json({ ok: true, message: 'Protection removed.', results: [{ service: plan.body.service, ok: true, traefik: { steps: [] } }] });
    }
    return json({ error: `Not available in this test (${url.pathname}).` }, 404);
  };
})();
'@

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-idp-$id"
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
# A full page load each time (a new query string), so the stand-in reads the state Set-Mock stored.
function Go([string]$Hash, [string]$Ready) { Open-Page $cdp "$base/?r=$([Guid]::NewGuid().ToString('N').Substring(0, 6))#$Hash"; return (Wait-PageCondition $cdp "document.readyState === 'complete' && ($Ready)" 30) }
# Mock state for the next page load (protected applications, failing ones, skip).
function Set-Mock([string[]]$Protected, [string[]]$Failing = @(), [string]$SkippedAt = '') {
  $s = ConvertTo-Json -Compress @{ protected = @($Protected); failing = @($Failing); skippedAt = $SkippedAt; calls = @() }
  $null = Js "sessionStorage.setItem('idpmock', $(ConvertTo-Json -Compress $s)); true"
}
$li = { param($step) "document.querySelector('.wizard-steps li[data-step=$step]')" }
function StepInfo([string]$Step) { Js "(() => { const li = $(& $li $Step); if (!li) return 'missing'; const n = li.querySelector('.step-num'); return JSON.stringify({ cls: li.className.trim().split(/\s+/).sort().join(' '), mark: n.textContent, color: getComputedStyle(n).color, badge: (li.querySelector('.step-badge') || {}).textContent || '' }); })()" | ConvertFrom-Json }
$panelReady = "!!document.querySelector('#wizard-panel h2') && !!document.querySelector('.wizard-steps li[data-step=apps]')"

try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-idp-$id"
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $base = "http://127.0.0.1:$($ui.Port)"
  $cdp = Start-EdgeSession -WorkDir $work
  $null = Invoke-Cdp $cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Shim }
  Set-Viewport $cdp 1366 800
  Open-Page $cdp $ui.LaunchUrl
  $null = Wait-PageCondition $cdp "document.readyState === 'complete' && !!window.TPMApp" 30

  # --- All eight protected and verified -------------------------------------------------------------------------------
  Set-Mock @('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h')
  $ok = Go 'identity/apps?level=beginner' $panelReady
  $s8 = StepInfo 'apps'; $s9 = StepInfo 'done'; $s7 = StepInfo 'owner'
  Test-Condition 'step 8: green check with the real count (8/8 protected) while it is the current step' ($ok -and $s8.cls -match '\bdone\b' -and $s8.cls -match '\bcurrent\b' -and $s8.mark -eq [string][char]0x2713 -and $s8.color -eq $s7.color -and $s8.badge -eq '8/8 protected') ($s8 | ConvertTo-Json -Compress)
  $status8 = [string](Js "document.querySelector('#id-apps-status').innerText")
  Test-Condition 'step 8: the status says 8 of 8 protected and ForwardAuth verified just now' ($status8 -match '8 of 8 application\(s\) protected' -and $status8 -match 'verified just now') $status8
  Test-Condition 'step 9: green check from the verified state (without visiting it)' ($s9.cls -match '\bdone\b' -and $s9.mark -eq [string][char]0x2713 -and $s9.color -eq $s7.color) ($s9 | ConvertTo-Json -Compress)
  $calls = [string](Js "JSON.stringify(window.__idpmock.calls.filter((c) => c.path === '/api/identity').map((c) => c.query))")
  Test-Condition 'verification: the page asks the server to probe ForwardAuth (probe=apps) on every load' ($calls -match 'probe=apps' -and $calls -notmatch '""\]|"",') $calls
  Shot 'identity-step8-complete'
  # Returning to completed steps: nothing turns blue or unfinished.
  $null = Js "document.querySelector('.wizard-steps li[data-step=done] button').click(); true"
  $okD = Wait-PageCondition $cdp "(document.querySelector('#wizard-title') || {}).textContent === 'Finished'" 10
  $s9b = StepInfo 'done'; $s8b = StepInfo 'apps'
  $done9 = [string](Js "document.querySelector('#id-done-status').innerText")
  Test-Condition 'revisit: on step 9 both steps keep their green checks (current step framed, not recoloured)' ($okD -and $s9b.cls -match '\bcurrent\b' -and $s9b.cls -match '\bdone\b' -and $s9b.color -eq $s7.color -and $s8b.cls -match '\bdone\b' -and $s8b.mark -eq [string][char]0x2713) "$($s9b | ConvertTo-Json -Compress) / $($s8b | ConvertTo-Json -Compress)"
  Test-Condition 'step 9: "Setup is complete" with the protected count and a way to manage protection' ($done9 -match 'Setup is complete' -and [string](Js "document.querySelector('#id-done-summary').innerText") -match '8 of 8 application\(s\) protected and verified' -and [bool](Js "!!document.querySelector('#id-manage-protection')")) $done9
  Shot 'identity-step9-complete'
  $null = Js "document.querySelector('#id-manage-protection').click(); true"
  $okM = Wait-PageCondition $cdp "(document.querySelector('#wizard-title') || {}).textContent === 'Protect applications'" 10
  $s8c = StepInfo 'apps'; $s9c = StepInfo 'done'
  Test-Condition 'revisit: back on step 8 (Manage protection) both checks stay green' ($okM -and $s8c.cls -match '\bdone\b' -and $s8c.color -eq $s7.color -and $s9c.cls -match '\bdone\b') ''

  # --- A protected application whose ForwardAuth is not enforced --------------------------------------------------------
  Set-Mock @('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h') @('c')
  $ok = Go 'identity/apps?level=beginner' $panelReady
  $s8f = StepInfo 'apps'; $s9f = StepInfo 'done'
  $st = [string](Js "document.querySelector('#id-apps-status').innerText")
  Test-Condition 'failing check: step 8 and 9 are not complete; the status names the application' ($ok -and $s8f.cls -notmatch '\bdone\b' -and $s9f.cls -notmatch '\bdone\b' -and $st -match 'not working for c') $st

  # --- Application launcher: links, status, diagnostics, trace, redundant Cloudflare login ------------------------------
  Set-Mock @('a', 'c', 'd', 'e', 'f', 'g', 'h')
  $ok = Go 'identity/apps?level=beginner' "$panelReady && !!document.querySelector('tr[data-app=d] .app-actions')"
  $rowA = Js "(() => { const r = document.querySelector('tr[data-app=a]'); const host = r.querySelector('a.app-host'); const open = [...r.querySelectorAll('.app-actions a')].find((a) => a.textContent.startsWith('Open')); const ak = [...r.querySelectorAll('.app-actions a')].find((a) => a.textContent.startsWith('Authentik')); return JSON.stringify({ host: host && host.getAttribute('href'), hostText: host && host.textContent.trim(), hostTarget: host && host.target, hostRel: host && host.rel, open: open && open.getAttribute('href'), openTarget: open && open.target, ak: ak && ak.getAttribute('href'), akTarget: ak && ak.target }); })()" | ConvertFrom-Json
  Test-Condition 'launcher: the hostname is a link to the application''s own address, in a new tab (no sign-in started by DTC)' ($ok -and $rowA.host -eq 'http://a.idtest.example:8180/' -and $rowA.hostText -match '^a\.idtest\.example' -and $rowA.hostTarget -eq '_blank' -and $rowA.hostRel -match 'noopener') ($rowA | ConvertTo-Json -Compress)
  Test-Condition 'launcher: Open goes to the same application address in a new tab' ($rowA.open -eq $rowA.host -and $rowA.openTarget -eq '_blank') ($rowA | ConvertTo-Json -Compress)
  Test-Condition 'launcher: Authentik opens the application''s admin page at the PUBLIC authentik address (not 127.0.0.1)' ($rowA.ak -eq 'https://auth.idtest.example/if/admin/#/core/applications/dm-a' -and $rowA.akTarget -eq '_blank' -and $rowA.ak -notmatch '127\.0\.0\.1') ($rowA | ConvertTo-Json -Compress)
  $rowB = Js "(() => { const r = document.querySelector('tr[data-app=b]'); return JSON.stringify({ open: ([...r.querySelectorAll('.app-actions a')].find((a) => a.textContent.startsWith('Open')) || {}).href || '', ak: !![...r.querySelectorAll('.app-actions a')].find((a) => a.textContent.startsWith('Authentik')), text: r.innerText }); })()" | ConvertFrom-Json
  Test-Condition 'launcher: a Windows-host target with nothing listening on its port says the service is not running' ($rowB.text -match 'Windows service not running') ($rowB | ConvertTo-Json -Compress)
  Test-Condition 'launcher: a published application opens at https://<hostname>/; unprotected rows have no Authentik button and warn' ($rowB.open -eq 'https://b.idtest.example/' -and -not $rowB.ak -and $rowB.text -match 'Public without sign-in') ($rowB | ConvertTo-Json -Compress)
  $rowC = [string](Js "document.querySelector('tr[data-app=c]').innerText"); $rowE = [string](Js "document.querySelector('tr[data-app=e]').innerText"); $rowF = [string](Js "document.querySelector('tr[data-app=f]').innerText")
  Test-Condition 'launcher: a stopped container is shown as an availability problem, not as a sign-in failure' ($rowC -match 'Stopped \(exited\)' -and $rowC -match 'availability error, not a sign-in problem' -and $rowC -notmatch 'Not enforced|failing') $rowC
  Test-Condition 'launcher: a missing container and a healthy protected application are distinguished' ($rowE -match 'Container missing' -and $rowF -match 'Running' -and $rowF -match 'Healthy, protected') "$rowE || $rowF"
  $banner = [string](Js "(document.querySelector('#id-redundant-access') || {}).innerText || ''")
  $rowD = [string](Js "document.querySelector('tr[data-app=d]').innerText")
  Test-Condition 'launcher: a redundant Cloudflare login is reported (banner + row), with its Access application' ($banner -match '1 application\(s\) ask visitors to sign in twice' -and $banner -match 'd\.idtest\.example' -and $rowD -match 'Redundant Cloudflare login' -and $rowD -match 'Cloudflare Access: d\.idtest\.example \(stack\)') "$banner || $rowD"
  Test-Condition 'launcher: no Authentik link uses the local 127.0.0.1 address' ([int](Js "[...document.querySelectorAll('.launcher-table a')].filter((a) => /127\.0\.0\.1/.test(a.href)).length") -eq 0) ''
  Shot 'identity-launcher'
  # Trace: read-only, shows which component asks for authentication first.
  $null = Js "[...document.querySelectorAll('tr[data-app=d] button')].find((b) => b.textContent === 'Trace').click(); true"
  $okT = Wait-PageCondition $cdp "!!document.querySelector('#id-trace-d')" 10
  $trace = [string](Js "(document.querySelector('#id-trace-d') || {}).innerText || ''")
  Test-Condition 'trace: names Cloudflare Access as the component asking first, without query strings' ($okT -and $trace -match 'Cloudflare Access:' -and $trace -match 'redundant second login' -and $trace -notmatch '\?') $trace
  Shot 'identity-trace'
  # Remove the redundant Cloudflare login: preview (authentik verified first, what stays), acknowledgement, apply.
  $null = Js "document.querySelector('#id-cleanup-d').click(); true"
  $okC = Wait-PageCondition $cdp "!!document.querySelector('#id-cleanup-review')" 10
  $rev = [string](Js "document.querySelector('#id-cleanup-review').innerText")
  $applyDisabled = [bool](Js "document.querySelector('#id-cleanup-apply').disabled")
  Test-Condition 'cleanup: the preview shows authentik verified, the one deletion, what stays and how to undo; Apply waits for the acknowledgement' ($okC -and $rev -match 'authentik protection verified just now' -and $rev -match "Delete Access application 'd\.idtest\.example \(stack\)'" -and $rev -match 'Stays as it is' -and $rev -match 'Access applications DTC did not create' -and $rev -match 'layered authentication' -and $applyDisabled) $rev
  Shot 'identity-cleanup-preview'
  $null = Js "document.querySelector('#id-cleanup-ack').click(); document.querySelector('#id-cleanup-apply').click(); true"
  $okC2 = Wait-PageCondition $cdp "!!document.querySelector('#id-cleanup-result') && !document.querySelector('#id-redundant-access')" 15
  $cleanCall = Js "JSON.stringify(window.__idpmock.calls.filter((c) => c.path === '/api/identity/access/apply').pop().body)" | ConvertFrom-Json
  Test-Condition 'cleanup: one confirmed apply with the preview id; afterwards no redundant login is reported' ($okC2 -and $cleanCall.planId -eq 'plan-a' -and $cleanCall.confirm -and [string](Js "document.querySelector('#id-cleanup-result').innerText") -match 'now goes straight to authentik') ($cleanCall | ConvertTo-Json -Compress)
  $opt = [string](Js "[...document.querySelectorAll('#id-p-access option')].map((o) => o.value + (o.selected ? '*' : '') + ':' + o.textContent).join(' | ')")
  Test-Condition 'protect: authentik-only is the default; layered (two sign-ins) is an explicit choice' ($opt -match '^remove\*:authentik only' -and $opt -match 'layered:Layered: keep Cloudflare Access in front as well \(two sign-ins\)') $opt
  # Narrow screen: the table becomes stacked rows without horizontal scrolling of the page.
  Set-Viewport $cdp 390 844 -Mobile
  Start-Sleep -Milliseconds 400
  $over = [int](Js "document.documentElement.scrollWidth - document.documentElement.clientWidth")
  Test-Condition 'launcher: no horizontal page scroll at phone width' ($over -le 1) "overflow $over px"
  Shot 'identity-launcher-mobile'
  Set-Viewport $cdp 1366 800

  # --- Remove protection safely -------------------------------------------------------------------------------------------
  Set-Mock @('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h')
  $ok = Go 'identity/apps?level=beginner' "$panelReady && document.querySelectorAll('.protect-table tbody tr.protected').length === 8"
  $null = Js "[...[...document.querySelectorAll('.protect-table tbody tr')].find((r) => r.innerText.includes('App B')).querySelectorAll('button')].find((b) => b.textContent.startsWith('Remove protection')).click(); true"
  $okR = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-review') && !!document.querySelector('#id-unprotect-keeps')" 10
  $planBody = Js "JSON.stringify(window.__idpmock.calls.filter((c) => c.path === '/api/identity/unprotect/plan').pop().body)" | ConvertFrom-Json
  $review = [string](Js "document.querySelector('#id-protect-review').innerText")
  Test-Condition 'remove: the preview asks for one application and keeps Cloudflare Access' ($okR -and $planBody.service -eq 'b' -and $planBody.cloudflareAccess -eq 'keep') ($planBody | ConvertTo-Json -Compress)
  Test-Condition 'remove: the preview lists what stays (container, route, authentik application, users, groups, rules)' ($review -match 'Stays as it is' -and $review -match 'container' -and $review -match 'still goes to' -and $review -match 'users, groups and access rules' -and $review -match 'Unassign') $review
  $applyBtn = "[...document.querySelectorAll('#id-protect-review button')].find((b) => b.textContent === 'Remove protection')"
  $null = Js "document.querySelector('#id-protect-review .actions input[type=checkbox]').click(); true"
  $disabledBeforeAck = [bool](Js "$applyBtn.disabled")
  Test-Condition 'remove: an application that would become public needs an explicit acknowledgement' ([bool](Js "!!document.querySelector('#id-public-warning')") -and $disabledBeforeAck) ''
  Shot 'identity-remove-preview'
  $null = Js "document.querySelector('#id-ack-public').click(); true"
  $null = Js "$applyBtn.click(); true"
  $okU = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-result') && document.querySelectorAll('.protect-table tbody tr.protected').length === 7" 15
  $applied = @(Js "JSON.stringify(window.__idpmock.calls.filter((c) => c.path === '/api/identity/unprotect/apply'))" | ConvertFrom-Json)
  $s8r = StepInfo 'apps'
  Test-Condition 'remove: one confirmed apply; afterwards 7/8 protected and step 8 stays complete (the rest verified)' ($okU -and $applied.Count -eq 1 -and $applied[0].body.confirm -and $applied[0].body.planId -eq 'plan-u' -and $s8r.badge -eq '7/8 protected' -and $s8r.cls -match '\bdone\b') ($s8r | ConvertTo-Json -Compress)
  Test-Condition 'remove: App B is selectable again (protect later)' ([bool](Js "!!document.querySelector('#sel-b')")) ''

  # --- Protect an additional application ----------------------------------------------------------------------------------
  $null = Js "document.querySelector('#sel-b').click(); document.querySelector('#id-protect-btn').click(); true"
  $okP = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-review') && [...document.querySelectorAll('#id-protect-review button')].some((b) => b.textContent.includes('Protect 1'))" 10
  $null = Js "(() => { document.querySelector('#id-protect-review .actions input[type=checkbox]').click(); [...document.querySelectorAll('#id-protect-review button')].find((b) => b.textContent.includes('Protect 1')).click(); return true; })()"
  $okP2 = Wait-PageCondition $cdp "document.querySelectorAll('.protect-table tbody tr.protected').length === 8" 15
  $s8p = StepInfo 'apps'
  Test-Condition 'protect more: App B protected again; the count returns to 8/8 and step 8 is complete' ($okP -and $okP2 -and $s8p.badge -eq '8/8 protected' -and $s8p.cls -match '\bdone\b') ($s8p | ConvertTo-Json -Compress)

  # --- Nothing protected: skip the optional step deliberately -------------------------------------------------------------
  Set-Mock @()
  $ok = Go 'identity/apps?level=beginner' $panelReady
  $s8n = StepInfo 'apps'; $s9n = StepInfo 'done'
  Test-Condition 'not protected, not skipped: step 8 open, step 9 not complete' ($ok -and $s8n.cls -notmatch '\bdone\b|\bskipped\b' -and $s9n.cls -notmatch '\bdone\b' -and $s8n.badge -eq '0/8 protected') ($s8n | ConvertTo-Json -Compress)
  $null = Js "[...document.querySelectorAll('.wizard-foot button')].find((b) => b.textContent.includes('Skip for now')).click(); true"
  $okS = Wait-PageCondition $cdp "(document.querySelector('#wizard-title') || {}).textContent === 'Finished' && document.querySelector('.wizard-steps li[data-step=apps]').classList.contains('skipped')" 15
  $skipCall = Js "JSON.stringify(window.__idpmock.calls.filter((c) => c.path === '/api/identity/wizard').pop().body)" | ConvertFrom-Json
  $s8s = StepInfo 'apps'; $s9s = StepInfo 'done'
  Test-Condition 'skip: "Skip for now" records the skip; step 8 shows skipped (not a green check)' ($okS -and $skipCall.skip -eq 'apps' -and $s8s.cls -match '\bskipped\b' -and $s8s.cls -notmatch '\bdone\b' -and $s8s.mark -ne [string][char]0x2713 -and $s8s.badge -eq 'skipped') ($s8s | ConvertTo-Json -Compress)
  Test-Condition 'skip: the skipped optional step does not block completion; step 9 is green and says protection was skipped' ($s9s.cls -match '\bdone\b' -and $s9s.mark -eq [string][char]0x2713 -and [string](Js "document.querySelector('#id-done-summary').innerText") -match 'skipped') ''
  Shot 'identity-step8-skipped'
  # Protecting later ends the skip.
  $ok = Go 'identity/apps?level=beginner' "$panelReady && !!document.querySelector('#sel-a')"
  $null = Js "document.querySelector('#sel-a').click(); document.querySelector('#id-protect-btn').click(); true"
  $null = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-review') && [...document.querySelectorAll('#id-protect-review button')].some((b) => b.textContent.includes('Protect 1'))" 10
  $null = Js "(() => { document.querySelector('#id-protect-review .actions input[type=checkbox]').click(); [...document.querySelectorAll('#id-protect-review button')].find((b) => b.textContent.includes('Protect 1')).click(); return true; })()"
  $okL = Wait-PageCondition $cdp "document.querySelectorAll('.protect-table tbody tr.protected').length === 1" 15
  $s8l = StepInfo 'apps'
  Test-Condition 'later: protecting one application after skipping makes step 8 complete (1/8 protected), no longer skipped' ($okL -and $s8l.cls -match '\bdone\b' -and $s8l.cls -notmatch '\bskipped\b' -and $s8l.badge -eq '1/8 protected') ($s8l | ConvertTo-Json -Compress)
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
