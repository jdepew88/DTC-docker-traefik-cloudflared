#requires -version 5.1
<#
.SYNOPSIS
  Browser test of the New app page (Container -> Reverse proxy -> Authentication -> Review and deploy) in headless Edge,
  without Docker, authentik, Cloudflare or any AI provider (small memory footprint).

.DESCRIPTION
  Runs webui.ps1 for a throwaway install folder (Cloudflare API mock). /api/provision* is answered by an in-page
  stand-in with server-shaped responses: an imported multi-service draft with an open web-port question and findings
  to acknowledge, an AI estimate (exact request preview, maximum cost, approval), a review with Traefik, Cloudflare and
  authentik changes, a deployment result with verification stages and a rollback preview. Covers the step states
  (navigation vs completion), acknowledgements, the approval gates, honest verification states and mobile layout.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-ProvisionBrowser.ps1 -ScreenshotDir .\ui-screens
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
  const st = window.__provmock = { calls: [], webAnswered: false, aiRun: false, blocked: false };
  const json = (o, status) => new Response(JSON.stringify(o), { status: status || 200, headers: { 'Content-Type': 'application/json' } });
  const findings = [
    { id: 'socket:web', severity: 'high', area: 'privileges', message: "'web' mounts the Docker socket read-only: it can see every container and its settings." },
    { id: 'registry:web', severity: 'review', area: 'supply-chain', message: "The image of 'web' comes from registry.example.net, which is not one of the well-known public registries." },
    { id: 'unverified', severity: 'info', area: 'provenance', message: 'This installation recipe has not been verified on this kind of host yet.' },
  ];
  const draft = () => ({ draftId: 'abcdef0123456789', createdAt: '2026-10-26T10:00:00', url: 'https://github.com/example/notes', kind: 'github-repo', id: 'notes', name: 'Notes', description: 'A note-taking app with a database.',
    license: 'MIT', maintainer: 'example', source: { type: 'imported', kind: 'github', url: 'https://github.com/example/notes', upstream: 'https://github.com/example/notes' },
    docs: [{ title: 'GitHub repository', url: 'https://github.com/example/notes' }], architectures: ['linux/amd64', 'linux/arm64'],
    services: [{ name: 'web', role: 'app', image: 'registry.example.net/notes/web:2.1.0@sha256:' + 'a'.repeat(64), ports: [{ container: 3000, protocol: st.webAnswered ? 'http' : 'tcp', primary: st.webAnswered }, { container: 9229, protocol: 'tcp', primary: false }], volumes: [{ name: 'uploads', kind: 'volume', target: '/app/uploads' }], settings: ['DATABASE_URL', 'SECRET_KEY'], dependsOn: ['db (service_healthy)'] },
      { name: 'db', role: 'database', image: 'postgres:16-alpine@sha256:' + 'b'.repeat(64), ports: [], volumes: [{ name: 'pgdata', kind: 'volume', target: '/var/lib/postgresql/data' }], settings: ['POSTGRES_PASSWORD'], dependsOn: [] }],
    web: st.webAnswered ? { service: 'web' } : null, inputs: [{ id: 'secretKey', type: 'generated', label: 'SECRET_KEY', required: false, default: '' }], privileges: [{ kind: 'docker-socket', reason: "Service 'web' mounts the Docker socket (read-only)." }],
    unresolved: (st.webAnswered ? [] : [{ field: 'web.port', reason: "'web' has several ports (3000, 9229); none was published. Which one is the web interface?" }]).concat(st.aiRun ? [] : [{ field: 'environment', reason: 'Optional settings are not documented in the Compose file.' }]),
    unsupported: [], evidence: [{ field: 'services.db.role', value: 'database', source: 'GitHub example/notes/compose.yaml', how: 'recognized from the image' }],
    assumptions: st.aiRun ? ['AI: LOG_LEVEL defaults to info'] : [], knownIssues: [], verification: { status: 'unverified', checks: [] }, findings,
    compatibility: { status: 'limited', host: 'Windows 11 with Docker Desktop (WSL2)', items: [{ level: 'limited', message: 'Only the web interface is published; other ports (9229/tcp) are reachable only from other containers.' }] },
    manifestErrors: [], protection: { forwardAuth: 'compatible', nativeOidc: false, reasons: ['ForwardAuth asks authentik before every request.'], recommendation: 'ForwardAuth with authentik suits this application.' },
    catalogMatch: null, ai: { runs: st.aiRun ? 1 : 0, usd: st.aiRun ? 0.0004 : 0 }, deployable: st.webAnswered });
  const review = (b) => ({ planId: st.blocked ? '' : 'p1', canApply: !st.blocked, blockers: st.blocked ? ["Authentication 'authentik' is not available: Identity & Access is not ready: The authentik API token is missing or not accepted."] : [],
    warnings: ['Cloudflare: Create DNS record notes.provtest.example overwrites an existing resource; it needs your explicit confirmation.'],
    steps: ['Write the Compose project and start it (images pinned by digest; only the web port on 127.0.0.1)', 'Check that the containers and their dependencies are healthy and the web interface answers', `Add the Traefik route ${b.hostname} (explicit file-provider YAML), not public yet`, 'Protect it with authentik (application, provider, owner-only access, outpost), then verify that anonymous visitors are sent to sign in', `Publish ${b.hostname} through the existing Cloudflare Tunnel`, 'Verify every stage and record the result'],
    container: { project: b.project, folder: 'C:\\apps\\' + b.project, container: `${b.project}-web`, compose: 'services:\n  web:\n    image: registry.example.net/notes/web:2.1.0@sha256:...\n', services: [{ name: 'web', container: `${b.project}-web`, image: 'registry.example.net/notes/web:2.1.0@sha256:' + 'a'.repeat(64) }, { name: 'db', container: `${b.project}-db`, image: 'postgres:16-alpine@sha256:' + 'b'.repeat(64) }],
      images: [{ service: 'web', image: 'registry.example.net/notes/web:2.1.0@sha256:' + 'a'.repeat(64), present: false }, { service: 'db', image: 'postgres:16-alpine@sha256:' + 'b'.repeat(64), present: true }], volumes: [`${b.project}_uploads`, `${b.project}_pgdata`], privileges: [{ kind: 'docker-socket', reason: "Service 'web' mounts the Docker socket (read-only)." }], localUrl: 'http://127.0.0.1:3000/' },
    findings, routing: { traefik: { changes: [{ file: `traefik\\dynamic\\svc-${b.project}.yml`, action: 'create', diff: ['+ http:'] }], issues: [] }, cloudflare: { actions: [{ id: `dns:${b.hostname}`, step: 'dns', kind: 'create', summary: `Create DNS record ${b.hostname}`, detail: 'CNAME to the tunnel', overwrite: true }, { id: `tunnel:${b.hostname}`, step: 'tunnel', kind: 'create', summary: `Add tunnel route ${b.hostname}`, detail: '', overwrite: false }] } },
    authentication: { choice: b.auth, identity: { actions: [{ kind: 'create', object: 'proxy provider', summary: `Create proxy provider 'dm-${b.project}'` }, { kind: 'create', object: 'application', summary: `Create application 'Notes' (dm-${b.project})` }, { kind: 'none', object: 'outpost', summary: 'The embedded outpost is reused' }] } },
    access: { choice: b.access, hostname: b.hostname }, ai: { runs: st.aiRun ? 1 : 0, usd: st.aiRun ? 0.0004 : 0, note: 'No AI is used during deployment.' } });
  window.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    const method = ((init && init.method) || 'GET').toUpperCase();
    if (!url.pathname.startsWith('/api/provision')) return realFetch(input, init);
    const body = init && init.body ? JSON.parse(init.body) : null;
    st.calls.push({ method, path: url.pathname, body });
    switch (url.pathname) {
      case '/api/provision': {
        let d = {}; try { const r = await realFetch('/api/provision', init); if (r.ok) d = await r.json(); } catch (e) { }
        d.domains = ['provtest.example'];
        d.identity = { readiness: { ready: true, state: 'ready', missing: [] }, providers: [{ id: 'authentik', canProtectApplications: true, ready: true }] };
        d.ai = Object.assign({}, d.ai, { provider: 'anthropic', keyStored: true });
        d.drafts = [{ draftId: 'abcdef0123456789', name: 'Notes', kind: 'github-repo', url: 'https://github.com/example/notes', unresolved: 1 }];
        return json(d);
      }
      case '/api/provision/import': return body.url.startsWith('https://github.com/') ? json(draft()) : json({ error: 'Only https:// addresses are accepted.' }, 422);
      case '/api/provision/draft': return json(draft());
      case '/api/provision/draft/web': st.webAnswered = true; return json(draft());
      case '/api/provision/ai/estimate': return json({ estimateId: '1234abcd5678ef90', provider: 'anthropic', model: 'claude-haiku-5-5', estimate: { model: 'claude-haiku-5-5', inputTokens: 900, maxOutputTokens: 4000, maxUsd: 0.00209, typicalUsd: 0.00069 }, budget: { ok: true, reason: '' }, month: { spentUsd: 0, limitUsd: 2, calls: 0 }, redacted: { email: 1 }, preview: { system: 'You complete Docker deployment drafts...', user: 'Application: Notes\nOpen questions:\n- environment: ...\n<untrusted_documentation>\n# Notes\n</untrusted_documentation>', chars: 300 } });
      case '/api/provision/ai/run': st.aiRun = true; return json({ run: { cached: false, usage: { usd: 0.0004 }, applied: [{ field: 'services.web.environment.LOG_LEVEL', value: 'info' }], rejected: [] }, draft: draft() });
      case '/api/provision/plan': return json(review(body));
      case '/api/provision/apply': return json({ ok: true, operationId: 'aaaabbbbccccdddd', url: 'https://notes.provtest.example/', journal: { operationId: 'aaaabbbbccccdddd', state: 'deployed',
        stages: [{ stage: 'install', status: 'passed', message: 'Project notes' }, { stage: 'backend', status: 'passed', message: 'notes-web answers' }, { stage: 'route', status: 'passed', message: 'notes.provtest.example -> notes-web' }, { stage: 'authentication', status: 'passed', message: 'Protected: an unauthenticated request is sent to sign in.' }, { stage: 'publish', status: 'passed', message: 'https://notes.provtest.example' }],
        resources: [{ kind: 'compose-project', name: 'notes', ownership: 'created' }, { kind: 'authentik-outpost', name: 'embedded outpost', ownership: 'shared' }],
        verification: [{ stage: 'compose', status: 'passed', detail: 'docker compose config' }, { stage: 'containers', status: 'passed', detail: '2 running' }, { stage: 'backend', status: 'passed', detail: 'http: 200' }, { stage: 'router', status: 'passed', detail: 'Traefik router: loaded' }, { stage: 'public', status: 'passed', detail: 'HTTP 302: the sign-in layer answers (the application behind it is checked by the backend stage)' }, { stage: 'auth-challenge', status: 'passed', detail: 'Sign-in required' }, { stage: 'authorized-access', status: 'not-tested', detail: 'Needs a real sign-in in your browser.' }] } });
      case '/api/provision/rollback/plan': return json({ operationId: body.operationId, plan: { steps: [{ kind: 'cloudflare-dns', name: 'notes.provtest.example' }, { kind: 'authentik-application', name: 'dm-notes' }, { kind: 'traefik-route', name: 'notes' }, { kind: 'compose-project', name: 'notes' }], kept: [{ kind: 'authentik-outpost', name: 'embedded outpost', why: 'shared with other applications' }, { kind: 'data-volume', name: 'notes_pgdata', why: 'data is kept unless you choose to delete it' }] } });
      case '/api/provision/rollback': return json({ ok: true, done: ['Route removed'], kept: [], state: 'rolled-back' });
      default: return json({ error: `Not available in this test (${url.pathname}).` }, 404);
    }
  };
})();
'@

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-provb-$id"
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
$mock = $null; $ui = $null; $cdp = $null
function Js([string]$Expr) { return Invoke-PageScript $cdp $Expr }
function Shot([string]$Name) {
  if (-not $ScreenshotDir) { return }
  try { $null = Js 'window.scrollTo(0, 0); true'; $w = [int](Js 'window.innerWidth'); $hh = [int](Js 'window.innerHeight'); $full = [Math]::Min(8000, [int](Js 'document.documentElement.scrollHeight'))
    Set-Viewport $cdp $w $full -Mobile:($w -lt 800); Start-Sleep -Milliseconds 300; Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$Name.png"); Set-Viewport $cdp $w $hh -Mobile:($w -lt 800) } catch { Write-Host "  (screenshot $Name skipped: $($_.Exception.Message))" }
}
function Click([string]$Sel) { return (Js "(() => { const e = document.querySelector('$Sel'); if (!e) return 'missing'; if (e.disabled) return 'disabled'; e.click(); return 'ok'; })()") }
function Wait([string]$Cond, [int]$Seconds = 15) { return (Wait-PageCondition $cdp $Cond $Seconds) }
function Step([string]$Id) { return (Js "(() => { const li = document.querySelector('.wizard-steps li[data-step=$Id]'); return li ? JSON.stringify({ cls: li.className.trim().split(/\s+/).sort().join(' '), mark: li.querySelector('.step-num').textContent }) : 'missing'; })()" | ConvertFrom-Json) }

try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-provb-$id"
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token ('mockTok_' + [Guid]::NewGuid().ToString('N'))
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $base = "http://127.0.0.1:$($ui.Port)"
  $cdp = Start-EdgeSession -WorkDir $work
  $null = Invoke-Cdp $cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Shim }
  Set-Viewport $cdp 1366 800
  Open-Page $cdp $ui.LaunchUrl
  $null = Wait "document.readyState === 'complete' && !!window.TPMApp" 30
  Open-Page $cdp "$base/?r=$id#provision?level=advanced"
  $ok = Wait "!!document.querySelector('#prov-url') && !!document.querySelector('.wizard-steps li[data-step=container]')" 30
  Test-Condition 'page: New app is in the navigation and opens on step 1 (Container) with the link field' ($ok -and (Js "!!document.querySelector('#rail a[href=""#provision""]')") -and (Step 'container').cls -match 'current' -and (Step 'proxy').cls -match 'locked') ''
  Shot 'provision-1-empty'

  $null = Js "document.querySelector('#prov-url').value = 'http://127.0.0.1/x'; true"; $null = Click '#prov-import'
  $null = Wait "document.querySelector('#toast') && !document.querySelector('#toast').hidden"
  Test-Condition 'import: a refused link shows the reason and creates no draft' ((Js "document.querySelector('#toast').textContent") -match 'https' -and -not (Js "!!document.querySelector('#prov-draft')")) ''
  $null = Js "document.querySelector('#prov-url').value = 'https://github.com/example/notes'; true"; $null = Click '#prov-import'
  $ok = Wait "!!document.querySelector('#prov-draft')"
  $rows = [int](Js "document.querySelectorAll('#prov-services tbody tr').length")
  $acks = [int](Js "document.querySelectorAll('#prov-findings .prov-ack').length")
  Test-Condition 'draft: services (app and database), open questions, findings with acknowledgement boxes (high and review only) and compatibility are shown' ($ok -and $rows -eq 2 -and $acks -eq 2 -and (Js "!!document.querySelector('#prov-unresolved')") -and (Js "!!document.querySelector('#prov-web')") -and (Js "document.querySelector('#prov-compat').textContent") -match 'limitations') "rows=$rows acks=$acks"
  Test-Condition 'step 1: not complete while the web port is open; Continue is disabled and says why' (-not ((Step 'container').cls -match '\bdone\b') -and (Js "document.querySelector('#prov-next').disabled") -and (Js "document.querySelector('.wizard-steps li[data-step=container] .step-badge').textContent") -match 'cannot be deployed') ''
  Shot 'provision-2-draft'

  $null = Click '#prov-ai-estimate'
  $ok = Wait "!!document.querySelector('#prov-ai-run')"
  Test-Condition 'ai: the estimate shows the provider, the maximum cost and exactly what would be sent; sending stays disabled until approved' ($ok -and (Js "document.querySelector('#prov-ai').textContent") -match '0\.0021' -and (Js "document.querySelector('#prov-ai-preview pre').textContent") -match 'untrusted_documentation' -and (Js "document.querySelector('#prov-ai-run').disabled")) ''
  Shot 'provision-3-ai-estimate'
  $null = Js "{ const a = document.querySelector('#prov-ai-approve'); a.checked = true; a.dispatchEvent(new Event('change')); true }"
  $null = Click '#prov-ai-run'
  $ok = Wait "!window.__provmock.calls.some((c) => c.path === '/api/provision/ai/estimate' && !window.__provmock.aiRun) || document.querySelector('#prov-draft') && window.__provmock.aiRun"
  $null = Wait "window.__provmock.aiRun && /LOG_LEVEL/.test(document.querySelector('#prov-draft').textContent)"
  Test-Condition 'ai: after approval the answers are merged and shown as assumptions to check' ((Js "window.__provmock.calls.filter((c) => c.path === '/api/provision/ai/run' && c.body.confirm === true).length") -eq 1 -and (Js "document.querySelector('#prov-draft').textContent") -match 'Assumptions \(AI\)') ''

  $null = Js "document.querySelector('#prov-web-port').value = '3000'; true"; $null = Click '#prov-web-save'
  $ok = Wait "window.__provmock.webAnswered && !document.querySelector('#prov-web')"
  $s1 = Step 'container'
  Test-Condition 'step 1: answering the web port leaves the review items: still not complete, with the count' ($ok -and -not ($s1.cls -match '\bdone\b') -and (Js "document.querySelector('.wizard-steps li[data-step=container] .step-badge').textContent") -match '2 item') ($s1 | ConvertTo-Json -Compress)
  $null = Js "document.querySelectorAll('#prov-findings .prov-ack').forEach((b) => { if (!b.checked) { b.checked = true; b.dispatchEvent(new Event('change')); } }); true"
  $null = Wait "document.querySelector('.wizard-steps li[data-step=container]').classList.contains('done')"
  $s1 = Step 'container'
  Test-Condition 'step 1: acknowledging every high/review finding completes the step (green check) while it stays the open step' ($s1.cls -match '\bdone\b' -and $s1.cls -match '\bcurrent\b' -and $s1.mark -eq [string][char]0x2713 -and -not (Js "document.querySelector('#prov-next').disabled")) ($s1 | ConvertTo-Json -Compress)

  $null = Click '#prov-next'
  $null = Wait "!!document.querySelector('#prov-access')"
  $null = Js "{ const r = document.querySelector('input[name=prov-access][value=public]'); r.checked = true; r.dispatchEvent(new Event('change')); true }"
  $null = Wait "!!document.querySelector('#prov-hostname')"
  Test-Condition 'step 2: public access suggests <app>.<your Cloudflare domain> and the step completes with a valid host name' ((Js "document.querySelector('#prov-hostname').value") -eq 'notes.provtest.example' -and (Step 'proxy').cls -match '\bdone\b') (Js "document.querySelector('#prov-hostname').value")
  $null = Js "{ const h = document.querySelector('#prov-hostname'); h.value = 'not a host'; h.dispatchEvent(new Event('input')); h.dispatchEvent(new Event('change')); true }"
  $null = Wait "!document.querySelector('.wizard-steps li[data-step=proxy]').classList.contains('done')"
  Test-Condition 'step 2: an invalid host name makes the step incomplete again (Continue disabled)' ((Js "document.querySelector('#prov-next').disabled") -and -not ((Step 'proxy').cls -match '\bdone\b')) ''
  $null = Js "{ const h = document.querySelector('#prov-hostname'); h.value = 'notes.provtest.example'; h.dispatchEvent(new Event('input')); h.dispatchEvent(new Event('change')); true }"
  Shot 'provision-4-proxy'
  $null = Wait "!document.querySelector('#prov-next').disabled"
  $null = Click '#prov-next'
  $null = Wait "!!document.querySelector('#prov-auth')"
  $authOpts = (Js "Array.from(document.querySelectorAll('input[name=prov-auth]')).map((r) => r.value + (r.disabled ? '(off)' : '')).join(',')")
  Test-Condition "step 3: public offers authentik, Cloudflare Access and the app's own login (never 'no sign-in'); Authelia is shown as not available" ($authOpts -eq 'authentik,cloudflare-access,native,authelia(off)' -and (Js "document.querySelector('input[name=prov-auth]:checked').value") -eq 'authentik') $authOpts
  $null = Js "{ const r = document.querySelector('input[name=prov-auth][value=native]'); r.checked = true; r.dispatchEvent(new Event('change')); true }"
  $null = Wait "!!document.querySelector('#prov-public-native')"
  Test-Condition "step 3: the app's own login on a public address needs an explicit acknowledgement" ((Js "!!document.querySelector('#prov-ack-auth')")) ''
  $null = Js "{ const r = document.querySelector('input[name=prov-auth][value=authentik]'); r.checked = true; r.dispatchEvent(new Event('change')); true }"
  Shot 'provision-5-auth'
  $null = Wait "!document.querySelector('#prov-next').disabled"
  $null = Click '#prov-next'
  $null = Wait "!!document.querySelector('#prov-plan')"
  $null = Click '#prov-plan'
  $ok = Wait "!!document.querySelector('#prov-review')"
  $planCall = Js "JSON.stringify(window.__provmock.calls.filter((c) => c.path === '/api/provision/plan').pop().body)" | ConvertFrom-Json
  Test-Condition 'review: the plan request carries the draft, access, host name, authentication and every acknowledgement' ($ok -and $planCall.access -eq 'public' -and $planCall.auth -eq 'authentik' -and $planCall.hostname -eq 'notes.provtest.example' -and @($planCall.acknowledge).Count -eq 2) ($planCall | ConvertTo-Json -Compress)
  Test-Condition 'review: one summary lists the steps in order, containers, images, volumes, networks, host ports, Traefik, Cloudflare and authentik changes, and AI usage' ([int](Js "document.querySelectorAll('#prov-steps li').length") -eq 6 -and (Js "document.querySelector('#prov-review').textContent") -match 'pgdata' -and (Js "!!document.querySelector('#prov-traefik')") -and [int](Js "document.querySelectorAll('#prov-cloudflare li').length") -eq 2 -and [int](Js "document.querySelectorAll('#prov-authentik li').length") -eq 3 -and (Js "document.querySelector('#prov-review').textContent") -match 'none during deployment') ''
  Test-Condition 'review: Deploy stays disabled until the review is confirmed, the privilege allowed and the Cloudflare overwrite confirmed' ((Js "document.querySelector('#prov-deploy').disabled") -and (Js "!!document.querySelector('#prov-priv')") -and [int](Js "document.querySelectorAll('.prov-overwrite').length") -eq 1) ''
  $null = Js "['#prov-approve', '#prov-priv'].forEach((s) => { const b = document.querySelector(s); b.checked = true; b.dispatchEvent(new Event('change')); }); true"
  Test-Condition 'review: with the overwrite still unconfirmed, Deploy is still disabled' ((Js "document.querySelector('#prov-deploy').disabled")) ''
  $null = Js "{ const o = document.querySelector('.prov-overwrite'); o.checked = true; o.dispatchEvent(new Event('change')); true }"
  Test-Condition 'review: all confirmations given, Deploy is enabled' (-not (Js "document.querySelector('#prov-deploy').disabled")) ''
  Shot 'provision-6-review'
  $null = Click '#prov-deploy'
  $ok = Wait "!!document.querySelector('#prov-result')"
  $applyBody = Js "JSON.stringify(window.__provmock.calls.filter((c) => c.path === '/api/provision/apply').pop().body)" | ConvertFrom-Json
  Test-Condition 'deploy: the apply request confirms, allows the privilege and names the confirmed overwrite' ($ok -and $applyBody.confirm -and $applyBody.confirmPrivileges -and (@($applyBody.confirmOverwrites) -join ',') -eq 'dns:notes.provtest.example') ($applyBody | ConvertTo-Json -Compress)
  $notTested = Js "document.querySelector('#prov-verification li[data-stage=authorized-access]').textContent"
  Test-Condition 'deploy: the result lists each stage and each verification; a stage that was not tested says so (never shown as passed)' ([int](Js "document.querySelectorAll('#prov-stages li').length") -eq 5 -and $notTested -match 'Not tested' -and (Js "document.querySelector('#prov-result-status').textContent") -match '6 check\(s\) passed, 0 failed, 1 not tested' -and (Js "document.querySelector('#prov-url-out').href") -eq 'https://notes.provtest.example/' -and (Step 'review').cls -match '\bdone\b') $notTested
  Shot 'provision-7-result'
  $null = Click '#prov-rollback'
  $ok = Wait "!!document.querySelector('#prov-rollback-panel')"
  Test-Condition 'rollback: the preview lists what is removed and what is kept (shared outpost, data volume)' ($ok -and [int](Js "document.querySelectorAll('#prov-rb-steps li').length") -eq 4 -and (Js "document.querySelector('#prov-rb-kept').textContent") -match 'shared with other applications' -and (Js "document.querySelector('#prov-rb-kept').textContent") -match 'notes_pgdata') ''
  Shot 'provision-8-rollback'

  # Mobile: no horizontal scrolling on the review.
  Set-Viewport $cdp 390 844 -Mobile
  Start-Sleep -Milliseconds 400
  $overflow = Js "document.documentElement.scrollWidth - document.documentElement.clientWidth"
  Test-Condition 'mobile: the New app page fits a 390 px wide screen (no horizontal page scroll)' ([int]$overflow -le 1) "overflow=$overflow"
  Shot 'provision-9-mobile'
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
