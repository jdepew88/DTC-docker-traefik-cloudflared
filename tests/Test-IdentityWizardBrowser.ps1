#requires -version 5.1
<#
.SYNOPSIS
  Browser test of the Identity & Access wizard UI without Docker or authentik (small memory footprint).

.DESCRIPTION
  Runs webui.ps1 for a throwaway install folder (Cloudflare API mock) in headless Edge. The page's /api/identity calls
  are answered by an in-page stand-in: the real GET /api/identity response, completed as if authentik were installed,
  connected and the owner verified, with nine applications (echo2 already protected). Covers what only the browser can
  show: Select all / Clear all / count, ticking and unticking without the page moving, already protected applications
  labelled and never selectable, the exact selection sent for protection, and the per-application result.
  Whether authentik and Traefik actually protect the applications is tested by Test-IdentityLive.ps1.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-IdentityWizardBrowser.ps1 -ScreenshotDir .\ui-screens
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

# Stand-in for the authentik side of /api/identity (installed before the app's own scripts on every page load).
$Shim = @'
(() => {
  const realFetch = window.fetch.bind(window);
  const names = ['echo', 'b1', 'b2', 'b3', 'b4', 'b5', 'b6', 'b7', 'echo2'];
  const saved = (() => { try { return JSON.parse(sessionStorage.getItem('idmock') || 'null'); } catch (e) { return null; } })();
  const st = window.__idmock = { protected: (saved && saved.protected) || ['echo2'], calls: (saved && saved.calls) || [] };
  const persist = () => { try { sessionStorage.setItem('idmock', JSON.stringify(st)); } catch (e) { } };
  const label = (n) => (n === 'echo' ? 'Echo' : n === 'echo2' ? 'Echo 2' : `Batch ${n}`);
  const host = (n) => `${n}.idtest.example`;
  const json = (o, status) => new Response(JSON.stringify(o), { status: status || 200, headers: { 'Content-Type': 'application/json' } });
  window.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    const method = ((init && init.method) || 'GET').toUpperCase();
    if (!url.pathname.startsWith('/api/identity')) return realFetch(input, init);
    const body = init && init.body ? JSON.parse(init.body) : null;
    if (method !== 'GET') { st.calls.push({ method, path: url.pathname, body }); persist(); }
    if (url.pathname === '/api/identity' && method === 'GET') {
      let d = {};
      try { const r = await realFetch(input, init); if (r.ok) d = await r.json(); } catch (e) { }
      const cfg = d.config = d.config || {};
      cfg.provider = 'authentik'; cfg.authMode = 'google'; cfg.wizardStep = cfg.wizardStep || 'apps';
      cfg.authentik = Object.assign({}, cfg.authentik, { publicUrl: 'https://auth.idtest.example', hostname: 'auth.idtest.example',
        owner: { email: 'owner@idtest.example', makeAdmin: true, username: 'owner', verifiedAt: '2026-10-25T10:00:00', subject: '109876543210' },
        loginPage: { appliedAt: '2026-10-25T10:05:00', brand: 'authentik-default', previousFlow: 'default-authentication-flow', previousTitle: 'authentik' } });
      d.install = Object.assign({}, d.install, { server: { state: 'running', health: 'healthy' }, localUrl: 'http://127.0.0.1:9000' });
      d.health = Object.assign({}, d.health, { Ready: true, Setup: 'done' });
      d.credential = { status: 'valid', ok: true, stored: true, username: 'akadmin' };
      d.token = { ok: true, username: 'akadmin' };
      d.route = { exists: true, router: 'enabled', hostname: 'auth.idtest.example' };
      d.overview = Object.assign({}, d.overview, { outpost: { authentikHost: 'https://auth.idtest.example/' } });
      d.google = Object.assign({}, d.google, { source: { slug: 'google', name: 'Google', clientId: '109876543210-test.apps.googleusercontent.com' } });
      d.adminLinks = { base: 'https://auth.idtest.example' };
      d.services = names.map((n) => ({ name: n, displayName: label(n), enabled: true, hostnames: [host(n)], auth: st.protected.includes(n) ? 'authentik' : 'none', publish: false, access: false }));
      d.apps = st.protected.map((n) => ({ service: n, displayName: label(n), hostname: host(n), protected: true, authentik: true, slug: `dm-${n}`,
        challenge: { State: 'auth', Message: 'Sign-in required (authentik).' }, verifiedAt: '', rules: n === 'echo2' ? 2 : 1, ownerOnly: n !== 'echo2' }));
      return json(d);
    }
    if (url.pathname === '/api/identity/wizard') { if (body && body.step) { } return json({ ok: true }); }
    if (url.pathname === '/api/identity/protect/plan') {
      return json({ planId: 'plan-ui-1', canApply: true, items: body.services.map((n) => ({ service: n, displayName: label(n), hostname: host(n), notes: [],
        authentik: [{ kind: 'create', object: 'proxy provider', summary: `Create provider dm-${n}` }, { kind: 'create', object: 'application', summary: `Create application dm-${n}` }, { kind: 'update', object: 'outpost', summary: 'Assign to the embedded outpost' }],
        traefik: { traefik: { changes: [{ action: 'update', file: `svc-${n}.yml`, diff: '' }], issues: [] }, cloudflare: { actions: [] } } })) });
    }
    if (url.pathname === '/api/identity/protect/apply') {
      const plan = st.calls.filter((c) => c.path === '/api/identity/protect/plan').pop();
      const chosen = plan ? plan.body.services : [];
      chosen.forEach((n) => { if (!st.protected.includes(n)) st.protected.push(n); }); persist();
      return json({ ok: true, message: `${chosen.length} application(s) protected.`, results: chosen.map((n) => ({ service: n, ok: true,
        challenge: { State: 'auth', Message: 'Anonymous visitors are sent to sign in.' },
        traefik: { steps: [{ name: 'Backend reachable from Traefik', status: 'Done', message: 'HTTP 200 from the backend.' }, { name: 'Traefik reload', status: 'Done', message: 'Route loaded.' }] } })) });
    }
    return json({ error: `Not available in this test (${url.pathname}).` }, 404);
  };
})();
'@

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-idw-$id"
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$mock = $null; $ui = $null; $cdp = $null
function Js([string]$Expr) { return Invoke-PageScript $cdp $Expr }
function Shot([string]$Name) {
  if (-not $ScreenshotDir) { return }
  # Full-page captures stitch the fixed header into the middle when the page is scrolled.
  try { $null = Js 'window.scrollTo(0, 0); true'; $w = [int](Js 'window.innerWidth'); $hh = [int](Js 'window.innerHeight'); $full = [Math]::Min(8000, [int](Js 'document.documentElement.scrollHeight'))
    Set-Viewport $cdp $w $full -Mobile:($w -lt 800); Start-Sleep -Milliseconds 300; Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$Name.png"); Set-Viewport $cdp $w $hh -Mobile:($w -lt 800) } catch { Write-Host "  (screenshot $Name skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}
function Go([string]$Hash, [string]$Ready) {
  Open-Page $cdp "$base/#$Hash"
  return (Wait-PageCondition $cdp "document.readyState === 'complete' && ($Ready)" 30)
}

try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-idw-$id"
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $base = "http://127.0.0.1:$($ui.Port)"
  $cdp = Start-EdgeSession -WorkDir $work
  $null = Invoke-Cdp $cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Shim }
  Set-Viewport $cdp 1366 700
  Open-Page $cdp $ui.LaunchUrl
  $null = Wait-PageCondition $cdp "document.readyState === 'complete' && !!window.TPMApp" 30

  # --- The wizard ---------------------------------------------------------------------------------------------------
  $okW = Go 'identity/mode?level=beginner' "!!document.querySelector('.wizard-steps') && !!document.querySelector('#wizard-panel h2')"
  $rail = [string](Js "document.querySelector('.wizard-steps').innerText")
  Test-Condition 'wizard: nine numbered steps for the Google path, the panel says which step this is' ($okW -and [string](Js "document.querySelector('#wizard-panel').innerText") -match 'Step 1 of 9' -and $rail -match 'Register with Google' -and $rail -match 'Protect applications') $rail
  Shot 'wizard-1-mode'
  $okO = Go 'identity/owner?level=beginner' "!!document.querySelector('.verified-banner')"
  Test-Condition 'wizard: a verified owner is shown as verified (no manual completion button)' ($okO -and [string](Js "document.querySelector('.verified-banner').innerText") -match 'Owner verified' -and -not [bool](Js "[...document.querySelectorAll('#wizard-panel button')].some((b) => /mark .*(done|complete|verified)/i.test(b.textContent))")) ''
  Shot 'wizard-7-owner-verified'
  if (Go 'identity/signin?level=beginner' "!!document.querySelector('.login-preview')") { Shot 'wizard-6-signin-preview' }

  # --- Application selection ----------------------------------------------------------------------------------------
  $okA = Go 'identity/apps?level=beginner' "!!document.querySelector('#id-sel-all') && document.querySelectorAll('.protect-table tbody tr').length === 9"
  $boxes = "[...document.querySelectorAll('.protect-table tbody input[type=checkbox]')]"
  $tableText = [string](Js "document.querySelector('.protect-table').innerText")
  Test-Condition 'apps: eight selectable applications; echo2 (already protected) is labelled and has no checkbox' ($okA -and [int](Js "$boxes.length") -eq 8 -and -not [bool](Js "!!document.querySelector('#sel-echo2')") -and $tableText -match 'Already protected' -and [string](Js "document.querySelector('.sel-count').textContent") -eq '0 of 8 selected') $tableText
  $null = Js "document.querySelector('.protect-table tbody tr:last-child').scrollIntoView({ block: 'end' }); window.scrollBy(0, 120); true"
  Start-Sleep -Milliseconds 300
  $y0 = [int](Js 'Math.round(window.scrollY)')
  $null = Js "document.querySelector('#id-sel-all').click(); true"
  $c1 = [string](Js "document.querySelector('.sel-count').textContent"); $all1 = [bool](Js "$boxes.every((b) => b.checked)")
  $null = Js "document.querySelector('#id-sel-none').click(); true"
  $c0 = [string](Js "document.querySelector('.sel-count').textContent"); $none = [bool](Js "$boxes.every((b) => !b.checked)")
  $null = Js "document.querySelector('#id-sel-all').click(); true"
  $y1 = [int](Js 'Math.round(window.scrollY)')
  # Real clicks on the checkbox (mouse events at its position), as a person would.
  $pt = Js "(() => { const r = document.querySelector('#sel-b3').getBoundingClientRect(); return JSON.stringify({ x: r.x + r.width / 2, y: r.y + r.height / 2 }); })()" | ConvertFrom-Json
  foreach ($t in 'mousePressed', 'mouseReleased') { $null = Invoke-Cdp $cdp 'Input.dispatchMouseEvent' @{ type = $t; x = $pt.x; y = $pt.y; button = 'left'; clickCount = 1 } }
  $null = Js "document.querySelector('#sel-b5').click(); document.querySelector('#sel-b5').click(); true"
  Start-Sleep -Milliseconds 300
  $y2 = [int](Js 'Math.round(window.scrollY)')
  $c2 = [string](Js "document.querySelector('.sel-count').textContent")
  $states = [string](Js "$boxes.map((b) => b.dataset.name + '=' + b.checked).join(',')")
  Test-Condition 'apps: Select all selects all eight, Clear all clears them' ($c1 -eq '8 of 8 selected' -and $all1 -and $c0 -eq '0 of 8 selected' -and $none) "$c1 / $c0"
  Test-Condition 'apps: the page is scrolled while selecting (the check is meaningful)' ($y0 -gt 0) "scrollY $y0"
  Test-Condition 'apps: Select all, Clear all and ticking never move the page' ($y1 -eq $y0 -and $y2 -eq $y0) "scrollY $y0 -> $y1 -> $y2"
  Test-Condition 'apps: deselecting one leaves the other seven selected (7 of 8)' ($c2 -eq '7 of 8 selected' -and $states -eq 'echo=true,b1=true,b2=true,b3=false,b4=true,b5=true,b6=true,b7=true') "$c2 / $states"
  Test-Condition 'apps: the action button names the count' ([string](Js "document.querySelector('#id-protect-btn').textContent") -match 'Protect 7 selected') ''
  Shot 'wizard-8-apps-selection'

  # --- Protect the seven --------------------------------------------------------------------------------------------
  $null = Js "document.querySelector('#id-protect-btn').click(); true"
  $okP = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-review') && [...document.querySelectorAll('#id-protect-review button')].some((b) => b.textContent.includes('Protect 7'))" 20
  $planReq = Js "JSON.stringify(window.__idmock.calls.filter((c) => c.path === '/api/identity/protect/plan').pop().body)" | ConvertFrom-Json
  $sent = @($planReq.services | Sort-Object) -join ','
  Test-Condition 'protect: exactly the seven ticked applications are sent (not b3, not the already protected echo2)' ($okP -and $sent -eq 'b1,b2,b4,b5,b6,b7,echo' -and $planReq.cloudflareAccess -eq 'keep') $sent
  Test-Condition 'protect: Apply stays disabled until the preview was reviewed' ([bool](Js "[...document.querySelectorAll('#id-protect-review button')].find((b) => b.textContent.includes('Protect 7')).disabled")) ''
  Shot 'wizard-8-apps-review'
  $null = Js "(() => { document.querySelector('#id-protect-review input[type=checkbox]').click(); [...document.querySelectorAll('#id-protect-review button')].find((b) => b.textContent.includes('Protect 7')).click(); return true; })()"
  $okR = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-result') && document.querySelectorAll('.protect-table tbody input[type=checkbox]').length === 1" 30
  $res = [string](Js "(document.querySelector('#id-protect-result') || {}).innerText || ''")
  $applyReq = @(Js "JSON.stringify(window.__idmock.calls.filter((c) => c.path === '/api/identity/protect/apply'))" | ConvertFrom-Json)
  Test-Condition 'protect: one apply of the reviewed plan; the result lists every application with backend, route and ForwardAuth' ($okR -and $applyReq.Count -eq 1 -and $applyReq[0].body.planId -eq 'plan-ui-1' -and $applyReq[0].body.confirm -and ([regex]::Matches($res, 'ForwardAuth enforced')).Count -eq 7 -and ([regex]::Matches($res, 'Route loaded by Traefik')).Count -eq 7 -and ([regex]::Matches($res, 'Backend reachable')).Count -eq 7) $res.Substring(0, [Math]::Min(300, $res.Length))
  $after = [string](Js "document.querySelector('.protect-table').innerText")
  Test-Condition 'protect: afterwards eight are labelled protected; only b3 remains selectable and unticked' ([int](Js "document.querySelectorAll('.protect-table tbody tr.protected').length") -eq 8 -and [bool](Js "!document.querySelector('.protect-table tbody tr:nth-child(4)').classList.contains('protected')") -and [bool](Js "!!document.querySelector('#sel-b3') && !document.querySelector('#sel-b3').checked") -and [string](Js "document.querySelector('.sel-count').textContent") -eq '0 of 1 selected') $after
  Test-Condition 'protect: nothing asked to remove protection at any point' (@(Js "JSON.stringify(window.__idmock.calls.map((c) => c.path))" | ConvertFrom-Json | Where-Object { $_ -match 'unprotect' }).Count -eq 0) ''
  Shot 'wizard-8-apps-result'

  # --- Phone width ----------------------------------------------------------------------------------------------------
  Set-Viewport $cdp 390 844 -Mobile
  $null = Go 'identity/apps?level=beginner' "!!document.querySelector('#id-sel-all')"
  $ov = [int](Js 'document.documentElement.scrollWidth - window.innerWidth')
  Test-Condition 'phone (390 px): the wizard has no horizontal page scroll' ($ov -le 0) "overflow $ov px"
  Shot 'wizard-390-apps'
  $errs = @($cdp.Errors | Where-Object { $_ -notmatch 'favicon' })
  Test-Condition 'no script errors in the page' ($errs.Count -eq 0) ($errs -join ' | ')
}
catch { Add-Result 'FAIL' 'identity wizard browser run' "$($_.Exception.Message) $($_.ScriptStackTrace)" }
finally {
  if ($cdp) { Stop-EdgeSession $cdp }
  if ($ui) { Stop-TestServer $ui }; if ($mock) { Stop-TestServer $mock }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
$pass = @($script:Results | Where-Object Status -eq 'PASS').Count; $fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
Write-Host ''; Write-Host "$pass passed, $fail failed"
if ($fail) { exit 1 }
