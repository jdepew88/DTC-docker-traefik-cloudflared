#requires -version 5.1
<#
.SYNOPSIS
  Browser test of the Authentication & Routing page without Docker or authentik (small memory footprint).

.DESCRIPTION
  Runs webui.ps1 for a throwaway install folder (Cloudflare API mock) in headless Edge. GET /api/routing is answered in
  the page with models built by the real lib\RoutingModel.psm1 from fixture facts: Mediabox with the sign-in redirect
  to http://127.0.0.1:9000 and a leftover Cloudflare Access application, a healthy application and an unprotected one.
  Covers the link from Identity & Access and the way back, application selection, both views, failed-stage details,
  the "?" help, Run checks, redaction and the desktop and phone layouts. Screenshots go to -ScreenshotDir.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-RoutingBrowser.ps1 -ScreenshotDir .\ui-screens
#>
param([string]$ScreenshotDir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\RoutingModel.psm1') -Force
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

# --- Fixture models (real model code, invented facts) -------------------------------------------------------------------
$state = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.c2VjcmV0LXN0YXRl.c2lnbmF0dXJl'
function New-Facts([string]$Name, [string]$Display, [bool]$Probe, [string]$OutpostHost = 'https://auth.example.com/', [bool]$Protected = $true, [bool]$LeftoverAccess = $false) {
  $h = "$Name.example.com"
  $loc = "$($OutpostHost.TrimEnd('/'))/application/o/authorize/?client_id=TpxTestClient00Abcd1&redirect_uri=https%3A%2F%2F$h%2Foutpost.goauthentik.io%2Fcallback%3FX-authentik-auth-callback%3Dtrue&response_type=code&state=$state"
  $mis = (Test-BrowserEndpoint $OutpostHost 'auth.example.com').ok -eq $false
  $checks = @(
    [ordered]@{ id = 'dns'; state = 'ok'; performed = $true; message = "$h is a proxied CNAME to this tunnel." }
    [ordered]@{ id = 'access'; state = $(if ($LeftoverAccess) { 'warning' } else { 'skipped' }); performed = $LeftoverAccess; message = $(if ($LeftoverAccess) { "Access application '$h (traefik-home)' (created by this tool) still asks visitors for a Cloudflare login." } else { 'Not used.' }) }
    [ordered]@{ id = 'tunnel'; state = 'ok'; performed = $true; message = "Tunnel 'home' sends $h to traefik:80; 4 connection(s)." }
    [ordered]@{ id = 'router'; state = 'ok'; performed = $true; message = "svc-$Name@file is loaded and enabled." }
    [ordered]@{ id = 'backend'; state = 'ok'; performed = $true; message = 'The application answered HTTP 200 from Traefik''s network (http://host.docker.internal:4119/).' }
    [ordered]@{ id = 'public'; state = $(if ($LeftoverAccess) { 'auth' } else { 'ok' }); performed = $true; message = $(if ($LeftoverAccess) { 'Cloudflare Access shows its login page, although this service is not set to use Cloudflare Access.' } else { 'The public URL answered HTTP 302.' }) })
  return [ordered]@{
    service = [ordered]@{ name = $Name; displayName = $Display; hostname = $h; enabled = $true; publish = $true; access = $false; authProvider = $(if ($Protected) { 'authentik' } else { '' }); targetUrl = 'http://host.docker.internal:4119'; targetType = 'host'; targetHost = 'host.docker.internal' }
    route = [ordered]@{ fileExists = $true; rule = "Host(``$h``)"; entryPoints = @('web'); middlewares = $(if ($Protected) { @("svc-$Name-authentik", 'default-headers@file') } else { @('default-headers@file') }); forwardAuthAddress = $(if ($Protected) { 'http://authentik-server:9000/outpost.goauthentik.io/auth/traefik' } else { '' }); outpostRouter = $Protected; backendUrl = 'http://host.docker.internal:4119' }
    traefik = [ordered]@{ apiOk = $true; routers = @{ "svc-$Name@file" = 'enabled'; "svc-$Name-outpost@file" = 'enabled' } }
    identity = [ordered]@{ publicUrl = 'https://auth.example.com'; authHostname = 'auth.example.com'; serverContainer = 'authentik-server'; onProxyNetwork = $true; googleConfigured = $true; appVerifiedAt = '' }
    authentik = [ordered]@{ connected = $true; error = ''; outpostName = 'authentik Embedded Outpost'; outpostHost = $OutpostHost; outpostBrowserHost = ''; providerFound = $true; providerExternalHost = "https://$h"; providerMode = 'forward_single'; providerAssigned = $true; applicationFound = $true; rules = 1 }
    cloudflare = [ordered]@{ connected = $true; tunnelName = 'home'; accessAppName = $(if ($LeftoverAccess) { "$h (traefik-home)" } else { '' }); accessAppByDtc = $LeftoverAccess }
    networks = [ordered]@{ proxy = 'proxynet'; traefik = @('proxynet', 'traefik-home_tunnel'); authentik = @('proxynet', 'authentik_internal'); backend = $null }
    health = $(if ($Probe) { [ordered]@{ checks = $checks } } else { $null })
    challenge = $(if ($Probe -and $Protected) { [pscustomobject]@{ State = $(if ($mis) { 'misrouted' } else { 'auth' }); Status = 302; Location = (Get-RedactedUrl $loc); Chain = @("$h/ -> 302"); Message = 'x' } } else { $null })
    publicAuth = $(if ($Probe -and $Protected) { [ordered]@{ status = 200; location = ''; error = '' } } else { $null })
    checkedAt = '2026-10-25T20:00:00'
  }
}
$services = @(
  [ordered]@{ name = 'mediabox'; displayName = 'Mediabox'; hostname = 'mediabox.example.com'; protected = $true; publish = $true; enabled = $true }
  [ordered]@{ name = 'uptime'; displayName = 'Uptime Kuma'; hostname = 'uptime.example.com'; protected = $true; publish = $true; enabled = $true }
  [ordered]@{ name = 'homepage'; displayName = 'Homepage'; hostname = 'homepage.example.com'; protected = $false; publish = $true; enabled = $true })
$fixtures = [ordered]@{
  'mediabox' = (Get-RoutingModel (New-Facts 'mediabox' 'Mediabox' $false 'http://127.0.0.1:9000' $true $true))
  'mediabox|probe' = (Get-RoutingModel (New-Facts 'mediabox' 'Mediabox' $true 'http://127.0.0.1:9000' $true $true))
  'uptime' = (Get-RoutingModel (New-Facts 'uptime' 'Uptime Kuma' $false))
  'uptime|probe' = (Get-RoutingModel (New-Facts 'uptime' 'Uptime Kuma' $true))
  'homepage' = (Get-RoutingModel (New-Facts 'homepage' 'Homepage' $false 'https://auth.example.com/' $false))
  'homepage|probe' = (Get-RoutingModel (New-Facts 'homepage' 'Homepage' $true 'https://auth.example.com/' $false))
}
$fixtureJson = ConvertTo-Json -Depth 12 -Compress ([ordered]@{ services = $services; models = $fixtures })
$Shim = @'
(() => {
  const realFetch = window.fetch.bind(window);
  const F = __FIXTURES__;
  const calls = window.__rtcalls = JSON.parse(sessionStorage.getItem('rtcalls') || '[]');
  window.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    if (url.pathname !== '/api/routing') return realFetch(input, init);
    calls.push(url.pathname + url.search); sessionStorage.setItem('rtcalls', JSON.stringify(calls));
    const svc = url.searchParams.get('service') || 'mediabox';
    const key = svc + (url.searchParams.get('probe') === '1' ? '|probe' : '');
    if (!F.models[key]) return new Response(JSON.stringify({ error: `No service named '${svc}'.` }), { status: 404, headers: { 'Content-Type': 'application/json' } });
    return new Response(JSON.stringify({ mode: 'guided', services: F.services, selected: svc, model: F.models[key] }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
})();
'@.Replace('__FIXTURES__', $fixtureJson)

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-rtb-$id"
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
function Go([string]$Hash, [string]$Ready) { Open-Page $cdp "$base/#$Hash"; return (Wait-PageCondition $cdp "document.readyState === 'complete' && ($Ready)" 30) }
$ready = "!!document.querySelector('#rt-view') && !!document.querySelector('#rt-app')"

try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-rtb-$id"
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $base = "http://127.0.0.1:$($ui.Port)"
  $cdp = Start-EdgeSession -WorkDir $work
  $null = Invoke-Cdp $cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Shim }
  Set-Viewport $cdp 1366 900
  Open-Page $cdp $ui.LaunchUrl
  $null = Wait-PageCondition $cdp "document.readyState === 'complete' && !!window.TPMApp" 30

  # --- From Identity & Access and back ------------------------------------------------------------------------------
  $okI = Go 'identity?level=beginner' "!!document.querySelector('#id-flow-link')"
  Test-Condition 'navigation: Identity & Access has a prominent "View Authentication Flow" link' ($okI -and [string](Js "document.querySelector('#id-flow-link').textContent") -match 'View Authentication Flow') ''
  $null = Js "document.querySelector('#id-flow-link').click(); true"
  $okR = Wait-PageCondition $cdp $ready 30
  $nav = [string](Js "document.querySelector('#rail').innerText")
  Test-Condition 'navigation: the link opens the routing page; it has no sidebar entry of its own' ($okR -and $nav -notmatch 'Authentication & Routing' -and [string](Js 'document.querySelector("h1").textContent') -eq 'Authentication & Routing') ''
  $null = Js "document.querySelector('#rt-back').click(); true"
  $okB = Wait-PageCondition $cdp "location.hash === '#identity' && !!document.querySelector('#id-flow-link')" 30
  Test-Condition 'navigation: "Back to Identity & Access" returns to Identity & Access' $okB ''

  # --- Configuration view (Mediabox) ---------------------------------------------------------------------------------
  $ok = Go 'routing/mediabox?level=beginner' $ready
  $first = [string](Js "(document.querySelector('#rt-first') || {}).innerText || ''")
  Test-Condition 'mediabox (configuration only): the local sign-in address is already the first problem; nothing claims "Verified"' ($ok -and $first -match 'Redirect to the sign-in page' -and $first -match '127\.0\.0\.1' -and [int](Js "document.querySelectorAll('#rt-view [data-state=verified]').length") -eq 0) $first
  $jSteps = [int](Js "document.querySelectorAll('.rt-journey > li').length")
  $paths = [string](Js "[...document.querySelectorAll('.rt-journey > li')].map((li) => li.className.match(/path-(\w+)/)[1]).join(',')")
  Test-Condition 'journey: ten steps; browser hops and server-to-server hops are marked' ($jSteps -eq 10 -and $paths -eq 'browser,server,server,server,browser,browser,server,browser,server,browser') $paths
  $txt = [string](Js "document.querySelector('#rj-forwardauth').innerText")
  Test-Condition 'journey: ForwardAuth is shown as server to server; the browser never talks to the internal outpost' ($txt -match 'Server to server' -and $txt -match 'never talks to this internal address') $txt
  Shot 'routing-journey-config'

  # --- Run checks -----------------------------------------------------------------------------------------------------
  $null = Js "document.querySelector('#rt-run').click(); true"
  $okC = Wait-PageCondition $cdp "(document.querySelector('#rt-run') || {}).textContent === 'Check again'" 30
  $calls = [string](Js 'JSON.stringify(window.__rtcalls)')
  Test-Condition 'run checks: requests the probed view for the selected application' ($okC -and $calls -match 'service=mediabox&probe=1') $calls
  $state5 = [string](Js "document.querySelector('#rj-redirect').dataset.state"); $state2 = [string](Js "document.querySelector('#rj-cloudflare').dataset.state")
  $j5 = [string](Js "document.querySelector('#rj-redirect').innerText")
  $j67 = [string](Js "['rj-choose', 'rj-policies'].map((i) => document.getElementById(i).dataset.state).join(',')")
  Test-Condition 'journey: choosing Google and the access decision are never marked verified without a real sign-in' ($j67 -notmatch 'verified') $j67
  Test-Condition 'journey (checked): step 5 failed with the explanation; step 2 warns about the Cloudflare login' ($state5 -eq 'failed' -and $state2 -eq 'warning' -and $j5 -match '127\.0\.0\.1' -and $j5 -match 'only works on the PC') "$state5 / $state2"
  Shot 'routing-journey-checked'

  # --- Internal view --------------------------------------------------------------------------------------------------
  $null = Js "document.querySelector('#rt-tab-internal').click(); true"
  $okV = Wait-PageCondition $cdp "!!document.querySelector('.rt-stages')" 10
  $det = [string](Js "document.querySelector('#rt-redirect details.rt-detail[open]') ? document.querySelector('#rt-redirect details.rt-detail').innerText : ''")
  Test-Condition 'internal: the failed redirect stage is expanded: tested endpoint, expected, actual, why, what to do' ($okV -and $det -match 'Tested' -and $det -match 'Expected' -and $det -match 'https://auth\.example\.com/application/o/authorize' -and $det -match 'Actual' -and $det -match 'http://127\.0\.0\.1:9000/' -and $det -match 'What to do' -and $det -match 'authentik_host') $det
  $acc = [string](Js "document.querySelector('#rt-access').innerText")
  Test-Condition 'internal: the leftover Cloudflare Access application is named as the source of the challenge' ($acc -match 'challenge' -and $acc -match 'mediabox\.example\.com \(traefik-home\)' -and [string](Js "document.querySelector('#rt-access').dataset.state") -eq 'warning') $acc
  $eps = [string](Js "[...document.querySelectorAll('#rt-signin .rt-endpoints li')].map((li) => li.innerText).join(' | ')")
  Test-Condition 'internal: browser and internal endpoints are labelled (public sign-in page vs authentik-server:9000)' ($eps -match '(?s)Browser endpoint.*https://auth\.example\.com' -and $eps -match '(?s)Internal endpoint.*http://authentik-server:9000') $eps
  $ver = [string](Js "[...document.querySelectorAll('#rt-forwardauth .rt-stage-meta')].map((x) => x.innerText).join('')")
  Test-Condition 'internal: a verified stage says it was proven by a real request' ($ver -match 'Verified' -and $ver -match 'Proven by a real request') $ver
  $null = Js "document.querySelector('#rt-redirect .help-btn').click(); true"
  $help = [string](Js "(document.querySelector('#rt-redirect .rt-help') || {}).innerText || ''")
  Test-Condition 'help: "?" explains what, why, what the manager sets up, what you manage and common failures' ($help -match 'What it does' -and $help -match 'Why it is needed' -and $help -match 'What the manager sets up' -and $help -match 'What you may manage yourself' -and $help -match 'Common reasons it fails') $help
  Shot 'routing-internal-failed'
  $page = [string](Js 'document.body.innerText')
  Test-Condition 'redaction: no state token, client id or cookie appears on the page' ($page -notmatch [regex]::Escape($state) -and $page -notmatch 'TpxTestClient' -and $page -notmatch '(?i)set-cookie') ''

  # --- Application selection ------------------------------------------------------------------------------------------
  $opts = [string](Js "[...document.querySelectorAll('#rt-app option')].map((o) => o.value).join(',')")
  $null = Js "(() => { const s = document.querySelector('#rt-app'); s.value = 'uptime'; s.dispatchEvent(new Event('change', { bubbles: true })); return true; })()"
  $okU = Wait-PageCondition $cdp "location.hash === '#routing/uptime' && (document.querySelector('.rt-summary-card h2') || {}).textContent.startsWith('Uptime Kuma')" 20
  Test-Condition 'selection: every published application is offered (protected first); choosing one shows its own path' ($opts -eq 'mediabox,uptime,homepage' -and $okU) $opts
  $null = Js "document.querySelector('#rt-run').click(); true"
  $null = Wait-PageCondition $cdp "(document.querySelector('#rt-run') || {}).textContent === 'Check again'" 30
  Test-Condition 'selection: a healthy protected application shows no problem after the checks' (-not [bool](Js "!!document.querySelector('#rt-first')") -and [string](Js "document.querySelector('.rt-summary-card').innerText") -match 'No problem found') ''
  $okH = Go 'routing/homepage?level=beginner' "(document.querySelector('.rt-summary-card h2') || {}).textContent.startsWith('Homepage')"
  $null = Js "document.querySelector('#rt-tab-journey').click(); true"; $okH = $okH -and (Wait-PageCondition $cdp "!!document.querySelector('.rt-journey')" 10)
  $hj = [string](Js "[...document.querySelectorAll('.rt-journey > li')].filter((li) => li.dataset.state === 'na').map((li) => li.id).join(',')")
  Test-Condition 'selection: an application without authentik shows the sign-in steps as not applicable' ($okH -and $hj -match 'rj-redirect' -and $hj -match 'rj-return' -and [string](Js "document.querySelector('.rt-summary-card').innerText") -match 'not protected by authentik') $hj

  # --- Layouts --------------------------------------------------------------------------------------------------------
  $over = @()
  foreach ($w in 1366, 390) {
    Set-Viewport $cdp $w 900 -Mobile:($w -lt 800)
    foreach ($tab in 'journey', 'internal') {
      $null = Go 'routing/mediabox?level=beginner' $ready
      $null = Js "document.querySelector('#rt-tab-$tab').click(); true"; Start-Sleep -Milliseconds 300
      $o = [int](Js 'document.documentElement.scrollWidth - window.innerWidth')
      if ($o -gt 0) { $over += "$w/$tab=$o" }
      if ($w -eq 390) { Shot "routing-$tab-390" }
    }
  }
  Test-Condition 'layout: no horizontal page scroll at 1366 px and 390 px, in both views' ($over.Count -eq 0) ($over -join ', ')
  $errs = @($cdp.Errors | Where-Object { $_ -notmatch 'favicon' })
  Test-Condition 'no script errors in the page' ($errs.Count -eq 0) ($errs -join ' | ')
}
catch { Add-Result 'FAIL' 'routing browser run' "$($_.Exception.Message) $($_.ScriptStackTrace)" }
finally {
  if ($cdp) { Stop-EdgeSession $cdp }
  if ($ui) { Stop-TestServer $ui }; if ($mock) { Stop-TestServer $mock }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
$pass = @($script:Results | Where-Object Status -eq 'PASS').Count; $fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
Write-Host ''; Write-Host "$pass passed, $fail failed"
if ($fail) { exit 1 }
