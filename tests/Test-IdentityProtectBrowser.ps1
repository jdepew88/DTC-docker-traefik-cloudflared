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
      return json(d);
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

  # --- Remove protection safely -------------------------------------------------------------------------------------------
  Set-Mock @('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h')
  $ok = Go 'identity/apps?level=beginner' "$panelReady && document.querySelectorAll('.protect-table tbody tr.protected').length === 8"
  $null = Js "[...document.querySelectorAll('.protect-table tbody tr')].find((r) => r.innerText.includes('App B')).querySelector('button.ghost').click(); true"
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
