#requires -version 5.1
<#
.SYNOPSIS
  Browser tests of the web UI in headless Microsoft Edge (DevTools protocol), against the Cloudflare API mock.

.DESCRIPTION
  Part 1 (folder A, never installed): first run, token handling and redaction, detail levels (presentation only,
  remembered, no server calls), Beginner hides network settings, automatic hostname naming with manual override and
  reset, review marking / collapsing / invalidation, separate local and Cloudflare approvals, nothing changed in
  Docker or Cloudflare before installation.
  Part 2 (folder B): a local-only installation of a uniquely named disposable instance through the UI (step 7),
  verification and the "ready" screen, the Overview, the simplified service form (display name -> subdomain, manual
  subdomain kept), then teardown.
  Every page is checked at phone (390), tablet (820) and desktop (1366) widths for horizontal overflow, for JavaScript
  errors, for accessible names of controls and for keyboard access. Screenshots go to -ScreenshotDir.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-UiBrowser.ps1 -ScreenshotDir .\ui-screens
#>
[CmdletBinding()]
param([string]$ScreenshotDir, [switch]$SkipInstall)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
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

# --- Page helpers (JavaScript run in the page) ------------------------------------------------------------------------
$JsHelpers = @'
window.__t = {
  btn: (text, root) => { const all = [...(root || document).querySelectorAll('button, a.btn')]; return all.find((b) => b.textContent.trim() === text) || all.find((b) => b.textContent.trim().includes(text)); },
  click: (text, root) => { const b = __t.btn(text, root); if (!b) throw new Error('no button ' + text); b.click(); return true; },
  set: (sel, value) => { const el = document.querySelector(sel); if (!el) throw new Error('no ' + sel); el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return true; },
  // checkVisibility() also sees content inside closed <details> (content-visibility), which offsetParent does not.
  shown: (el) => !!(el && (el.checkVisibility ? el.checkVisibility({ checkVisibilityCSS: true }) : el.offsetParent !== null)),
  visible: (sel) => __t.shown(document.querySelector(sel)),
  text: (sel) => { const el = document.querySelector(sel); return el ? el.innerText : ''; },
  overflow: () => document.documentElement.scrollWidth - window.innerWidth,
  unnamed: () => {
    const name = (el) => {
      if (el.getAttribute('aria-label') || el.getAttribute('title')) return true;
      if (el.getAttribute('aria-labelledby')) return true;
      if (el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`)) return true;
      if (el.closest('label')) return true;
      if (['BUTTON', 'A'].includes(el.tagName) && el.textContent.trim()) return true;
      return false;
    };
    return [...document.querySelectorAll('button, a[href], input:not([type=hidden]), select, textarea')]
      .filter((el) => __t.shown(el) && !name(el)).map((el) => `${el.tagName.toLowerCase()}#${el.id || ''}.${el.className}`);
  },
  imgsWithoutAlt: () => [...document.querySelectorAll('img')].filter((i) => !i.hasAttribute('alt')).length,
  h1: () => document.querySelectorAll('main h1').length,
};
true
'@
function Js([string]$Expr) { return Invoke-PageScript $cdp $Expr }
function Prepare-Page { $null = Invoke-PageScript $cdp $JsHelpers }
function Go([string]$Hash, [string]$Ready) {
  Open-Page $cdp "$base/#$Hash"
  if (-not (Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && ($Ready)" 30)) { throw "Page #$Hash did not render ($Ready)." }
  Prepare-Page
}
function Shot([string]$Name) {
  if (-not $ScreenshotDir) { return }
  try { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$Name.png") } catch { Write-Host "  (screenshot $Name skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}
function Check-Layout([string]$Page, [string]$Ready) {
  $bad = @()
  foreach ($w in @(390, 820, 1366)) {
    Set-Viewport $cdp $w 900 -Mobile:($w -lt 800)
    Go $Page $Ready
    $o = [int](Js '__t.overflow()')
    if ($o -gt 1) { $bad += "$w px overflows by $o px" }
  }
  Set-Viewport $cdp 1366 900
  Test-Condition "responsive: #$Page fits 390 / 820 / 1366 px without horizontal scrolling" ($bad.Count -eq 0) ($bad -join '; ')
  Go $Page $Ready
  $unnamed = @(Js '__t.unnamed()')
  Test-Condition "accessibility: #$Page controls have names, images have alt, one h1" ($unnamed.Count -eq 0 -and [int](Js '__t.imgsWithoutAlt()') -eq 0 -and [int](Js '__t.h1()') -eq 1) ($unnamed -join ', ')
}
function Get-DockerSnapshot {
  $c = @((Invoke-Docker ps -a --format '{{.ID}} {{.Names}} {{.State}}').Output | Where-Object { $_ -and $_ -notmatch '-validate-' } | Sort-Object)
  $n = @((Invoke-Docker network ls --format '{{.ID}} {{.Name}}').Output | Where-Object { $_ } | Sort-Object)
  return (($c + $n) -join '|')
}
function Get-Writes { return @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' -and $_.path -notmatch '/_state$' }) }

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-ui-$id"
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
$pathA = Join-Path $work 'a'
$pathB = Join-Path $work 'b'
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$stackB = "tpm-ui-$id"
$mock = $null; $ui = $null; $cdp = $null; $uiB = $null; $installedB = $false

try {
  $dockerBefore = Get-DockerSnapshot
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $pathA -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui-a')).FullName -ApiBase $mock.Base
  $base = "http://127.0.0.1:$($ui.Port)"
  $null = Connect-WebUi $ui   # a separate API session for the test itself (the browser has its own)
  $cdp = Start-EdgeSession -WorkDir $work
  Set-Viewport $cdp 1366 900
  Open-Page $cdp $ui.LaunchUrl
  $ok = Wait-PageCondition $cdp "document.querySelector('#step-1 h2')" 30
  Prepare-Page

  # --- First run ------------------------------------------------------------------------------------------------------
  Test-Condition 'first run: the seven-step journey renders, step 1 is the current, open step' ($ok -and [int](Js "document.querySelectorAll('[id^=step-] .step-card').length") -eq 7 -and
    [bool](Js "!!document.querySelector('#step-1 .step.current #step-body-1')") -and [int](Js "document.querySelectorAll('#rail .rail-steps li').length") -eq 7) ''
  $href = [string](Js "document.querySelector('#cf-create-token').href")
  $u = [Uri]$href
  Test-Condition 'step 1: Create Cloudflare API Token opens the official template page in a new tab' ($u.Host -eq 'dash.cloudflare.com' -and $u.AbsolutePath -eq '/profile/api-tokens' -and $href -match 'permissionGroupKeys=' -and
    [string](Js "document.querySelector('#cf-create-token').target") -eq '_blank' -and [string](Js "document.querySelector('#cf-create-token').rel") -match 'noopener') $href
  Test-Condition 'step 1: the token field is masked; local-only skip offered' ([string](Js "document.querySelector('#wiz-token').type") -eq 'password' -and [bool](Js "!!__t.btn('Skip: install for local use only')")) ''
  Shot 'setup-1-first-run-beginner-1366'

  # --- Detail levels ----------------------------------------------------------------------------------------------------
  $before = $cdp.Requests.Count
  $null = Js "document.querySelector('input[name=detail-level][value=expert]').click(); true"
  Start-Sleep -Milliseconds 400
  $writes = @($cdp.Requests | Select-Object -Skip $before | Where-Object { $_.Method -ne 'GET' })
  Test-Condition 'detail level: switching changes the presentation only (no server change requests)' ([string](Js 'document.body.dataset.level') -eq 'expert' -and $writes.Count -eq 0) (($writes | ForEach-Object { "$($_.Method) $($_.Url)" }) -join ', ')
  Go 'setup' "document.querySelector('#step-1 h2')"
  Test-Condition 'detail level: remembered across reloads' ([string](Js 'document.body.dataset.level') -eq 'expert' -and [string](Js "localStorage.getItem('tpm.level')") -eq 'expert') ''
  $null = Js "document.querySelector('input[name=detail-level][value=beginner]').click(); true"

  # --- Token (through the UI) -------------------------------------------------------------------------------------------
  $null = Js "__t.set('#wiz-token', '$apiToken'); document.querySelector('#wiz-token').closest('form').requestSubmit(); true"
  $ok = Wait-PageCondition $cdp "document.querySelector('#step-1') && document.querySelector('#step-1').innerText.includes('What this token can do')" 30
  if (-not $ok) { $null = Js "document.querySelector('#step-1 .rv-toggle').click(); true"; $ok = Wait-PageCondition $cdp "document.querySelector('#step-1').innerText.includes('What this token can do')" 15 }
  $leak = [bool](Js "document.documentElement.outerHTML.includes('$apiToken') || JSON.stringify(localStorage).includes('$apiToken') || JSON.stringify(sessionStorage).includes('$apiToken')")
  Test-Condition 'token: verified through the UI; never in the page, the field, or browser storage' ($ok -and -not $leak -and [string](Js "document.querySelector('#wiz-token').value") -eq '') ''
  $null = Js "[...document.querySelectorAll('#step-1 fieldset.chips input')].forEach((b, i) => { b.checked = i === 0; }); __t.click('Save allowed domains', document.querySelector('#step-1')); true"
  $ok = Wait-PageCondition $cdp "document.querySelector('#step-1').innerText.includes('Allowed now')" 20
  Test-Condition 'step 1: one domain allowed; step done; account/zone permission levels explained' ($ok -and [string](Js "document.querySelector('#step-1').innerText") -match 'Zone level' -and [string](Js "document.querySelector('#step-1').innerText") -match 'Account level') ''

  # --- Step 2 ----------------------------------------------------------------------------------------------------------------
  $ok = Wait-PageCondition $cdp "document.querySelector('#step-2') && document.querySelector('#step-2 .step-summary').innerText.length > 0 && !document.querySelector('#step-2 .step-summary').innerText.includes('Not checked')" 40
  $null = Js "if (!document.querySelector('#step-body-2')) document.querySelector('#step-2 .rv-toggle').click(); true"
  $t2 = [string](Js "document.querySelector('#step-2').innerText")
  Test-Condition 'step 2: Docker, folder, names, ports, networks, subnet and other containers are checked automatically, with reasons' ($ok -and $t2 -match 'Docker Engine running' -and $t2 -match 'Install folder is writable' -and
    $t2 -match 'Required ports are free' -and $t2 -match 'No subnet overlap' -and $t2 -match 'Other containers stay unchanged' -and $t2 -match 'must not be using them') ($t2.Substring(0, [Math]::Min(400, $t2.Length)))

  # --- Step 3: levels and naming ------------------------------------------------------------------------------------------------
  $null = Js "if (!document.querySelector('#step-body-3')) document.querySelector('#step-3 .rv-toggle').click(); true"
  $null = Wait-PageCondition $cdp "document.querySelector('#wiz-STACK_NAME')" 10
  $vis = @('#wiz-STACK_NAME', '#wiz-TUNNEL_SUBNET', '#wiz-CLOUDFLARED_IP') | ForEach-Object { [bool](Js "__t.visible('$_')") }
  Test-Condition 'Beginner: Docker network, subnet and static address fields are tucked away; instance name shown' ($vis[0] -and -not $vis[1] -and -not $vis[2]) "visible: $($vis -join ',') level=$(Js 'document.body.dataset.level')"
  $null = Js "document.querySelector('input[name=detail-level][value=advanced]').click(); true"
  $null = Wait-PageCondition $cdp "document.querySelector('#wiz-TUNNEL_SUBNET')" 10; Prepare-Page
  Test-Condition 'Advanced: network, subnet and static address fields are shown' ((Js "__t.visible('#wiz-TUNNEL_SUBNET')") -and (Js "__t.visible('#wiz-CLOUDFLARED_IP')") -and (Js "__t.visible('#wiz-PROXY_NETWORK')")) ''
  $null = Js "__t.set('#wiz-STACK_NAME', 'traefik-ext1'); true"
  $sub1 = [string](Js "document.querySelector('#dash-sub').value"); $prev1 = [string](Js "document.querySelector('#dash-preview').textContent")
  $null = Js "__t.set('#dash-sub', 'admin'); __t.set('#wiz-STACK_NAME', 'traefik-ext2'); true"
  $sub2 = [string](Js "document.querySelector('#dash-sub').value")
  $null = Js "__t.click('Reset to automatic', document.querySelector('#step-3')); true"; Prepare-Page
  $sub3 = [string](Js "document.querySelector('#dash-sub').value")
  Test-Condition 'naming: dashboard hostname follows the instance name, a manual edit is kept, reset restores it' ($sub1 -eq 'traefik-ext1' -and $prev1 -eq 'https://traefik-ext1.example.test/dashboard/' -and $sub2 -eq 'admin' -and $sub3 -eq 'traefik-ext2') "$sub1 $prev1 $sub2 $sub3"
  $sugg = Invoke-WebUi $ui POST '/api/setup/suggest' @{}
  $null = Js "__t.set('#wiz-STACK_NAME', '$($sugg.Data.settings.STACK_NAME)'); __t.set('#dash-sub', 'traefik-dash'); __t.click('Save settings', document.querySelector('#step-3')); true"
  $ok = Wait-PageCondition $cdp "document.querySelector('#step-3 .step-summary').innerText.includes('Instance ')" 30
  $d = (Invoke-WebUi $ui GET '/api/dashboard').Data
  Test-Condition 'step 3: settings and the edited dashboard hostname are saved (still editable later)' ($ok -and $d.subdomain -eq 'traefik-dash' -and $d.subdomainCustom) "$($d.subdomain) $($d.subdomainCustom)"
  Shot 'setup-3-configure-advanced-1366'

  # --- Step 4 --------------------------------------------------------------------------------------------------------------
  $null = Js "document.querySelector('input[name=detail-level][value=intermediate]').click(); true"
  $null = Js "if (!document.querySelector('#step-body-4')) document.querySelector('#step-4 .rv-toggle').click(); true"
  $null = Wait-PageCondition $cdp "document.querySelector('input[name=wiz-mode][value=tunnel]')" 10; Prepare-Page
  Test-Condition 'step 4: public-IP ingress is shown as planned and cannot be chosen' ([bool](Js "document.querySelector('input[name=wiz-mode][value=\'public-ip\']').disabled") -and [string](Js "document.querySelector('#step-4').innerText") -match 'Planned') ''
  $null = Js "document.querySelector('input[name=wiz-mode][value=tunnel]').click(); true"; Start-Sleep -Milliseconds 300; Prepare-Page
  $null = Js "document.querySelector('input[name=wiz-tchoice][value=existing]').click(); true"; Start-Sleep -Milliseconds 300; Prepare-Page
  $null = Js "__t.set('#wiz-tunnel', '11111111-2222-3333-4444-555555555555'); __t.click('Save ingress method', document.querySelector('#step-4')); true"
  $ok = Wait-PageCondition $cdp "document.querySelector('#step-4 .step-summary').innerText.includes('existing-tunnel')" 20
  Test-Condition 'step 4: existing tunnel chosen with account, connector and destination summary' $ok ''

  # --- Step 5: review ------------------------------------------------------------------------------------------------------
  $null = Js "if (!document.querySelector('#step-body-5')) document.querySelector('#step-5 .rv-toggle').click(); true"
  $null = Wait-PageCondition $cdp "__t.btn('Run the checks')" 10; Prepare-Page
  $null = Js "__t.set('#wiz-contact', 'owner@example.test'); __t.click('Save', document.querySelector('#wiz-contact').closest('.card')); true"
  Start-Sleep -Seconds 2; Prepare-Page
  $null = Js "__t.click('Run the checks', document.querySelector('#step-5')); true"
  $ok = Wait-PageCondition $cdp "document.querySelector('#rv-local-checks')" 120; Prepare-Page
  Shot 'setup-5-review-intermediate-1366'
  $statusBefore = [string](Js "document.querySelector('#rv-local-config .rv-head .chip').textContent")
  $null = Js "__t.click('Mark reviewed', document.querySelector('#rv-local-config')); true"; Start-Sleep -Milliseconds 300
  $collapsed = [bool](Js "document.querySelector('#rv-local-config .rv-body').hidden")
  $chips = [string](Js "document.querySelector('#rv-local-config .rv-head').innerText")
  Test-Condition 'review: marking reviewed collapses the section, keeps its summary and leaves the validation status unchanged' ($ok -and $collapsed -and $chips -match 'Reviewed' -and $chips -match [regex]::Escape($statusBefore) -and $chips -match 'Instance') $chips
  # A setting changes behind the review -> the review is invalidated.
  $cur = (Invoke-WebUi $ui GET '/api/setup').Data.settings
  $null = Invoke-WebUi $ui POST '/api/setup/settings' @{ settings = @{ STACK_NAME = $cur.STACK_NAME; TRAEFIK_HTTP_PORT = [string]([int]$cur.TRAEFIK_HTTP_PORT + 2); TRAEFIK_DASHBOARD_PORT = [string]([int]$cur.TRAEFIK_DASHBOARD_PORT + 2); PROXY_NETWORK = $cur.PROXY_NETWORK; TUNNEL_SUBNET = $cur.TUNNEL_SUBNET; TUNNEL_IP_RANGE = $cur.TUNNEL_IP_RANGE; CLOUDFLARED_IP = $cur.CLOUDFLARED_IP } }
  Go 'setup/5' "__t !== undefined || true"
  $null = Wait-PageCondition $cdp "document.querySelector('#step-body-5')" 15; Prepare-Page
  $null = Js "__t.click('Run the checks', document.querySelector('#step-5')); true"
  $null = Wait-PageCondition $cdp "document.querySelector('#rv-local-config') && document.querySelector('#rv-local-config').innerText.includes('Changed since review')" 120; Prepare-Page
  $chips = [string](Js "document.querySelector('#rv-local-config .rv-head').innerText")
  Test-Condition 'review: a configuration change invalidates the earlier review ("Changed since review")' ($chips -match 'Changed since review' -and [bool](Js "!document.querySelector('#rv-local-config .rv-body').hidden")) $chips
  $canApprove = -not [bool](Js "document.querySelector('#step-5 .card.flat:last-of-type input[type=checkbox]').disabled")
  $null = Js "(() => { const b=[...document.querySelectorAll('#step-5 input[type=checkbox]')].pop(); if (!b.disabled) b.click(); })(); true"; Start-Sleep -Milliseconds 400; Prepare-Page
  $t5 = [string](Js "document.querySelector('#step-5').innerText")
  Test-Condition 'step 5: local changes approved separately; the journey moves to the Cloudflare review' ($canApprove -and [string](Js "document.querySelector('#step-5 .step-summary').innerText") -eq 'Approved') ($t5.Substring([Math]::Max(0, $t5.Length - 900)))

  # --- Step 6 ----------------------------------------------------------------------------------------------------------------
  $ok = Wait-PageCondition $cdp "document.querySelector('#rv-cf-dashboard') && document.querySelector('#rv-cf-dashboard').innerText.includes('Access')" 60; Prepare-Page
  $t6 = [string](Js "document.querySelector('#step-6').innerText")
  Test-Condition 'step 6: Cloudflare changes reviewed separately: tunnel, dashboard (Access first), DNS (email records untouched), security' ($ok -and $t6 -match 'Reuse tunnel' -and $t6 -match 'MX, SPF, DKIM, DMARC' -and $t6 -match 'Turnstile' -and $t6 -match 'traefik-dash\.example\.test') ($t6.Substring(0, [Math]::Min(500, $t6.Length)))
  Shot 'setup-6-cloudflare-review-intermediate-1366'
  $null = Js "if (!document.querySelector('#step-body-7')) document.querySelector('#step-7 .rv-toggle').click(); true"; Start-Sleep -Milliseconds 300; Prepare-Page
  $installEnabledBefore = -not [bool](Js "__t.btn('Install and verify', document.querySelector('#step-body-7')).disabled")
  $approveBox = [string](Js "(() => { const b=[...document.querySelectorAll('#step-6 input[type=checkbox]')].pop(); return b ? (b.disabled ? 'disabled: ' : 'enabled: ') + b.closest('label').innerText : 'none'; })()")
  $null = Js "(() => { const b=[...document.querySelectorAll('#step-6 input[type=checkbox]')].pop(); b.click(); })(); true"; Start-Sleep -Milliseconds 400; Prepare-Page
  $installEnabled = -not [bool](Js "__t.btn('Install and verify', document.querySelector('#step-body-7')).disabled")
  Test-Condition 'step 7: Install is enabled only after both approvals' (-not $installEnabledBefore -and $installEnabled) "$installEnabledBefore $installEnabled [$approveBox] $(Js 'JSON.stringify(TPMApp.state.approvals) + TPMApp.state.setup.deployment.mode')"
  Test-Condition 'server: an installation without explicit confirmation is refused' ((Invoke-WebUi $ui POST '/api/setup/install' @{ planKey = 'x' }).Status -eq 400) ''
  Test-Condition 'dry-run safety: no Docker resource and no Cloudflare resource changed during the whole review' ((Get-DockerSnapshot) -eq $dockerBefore -and @(Get-Writes).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $pathA 'compose.yaml'))) "writes: $(@(Get-Writes).Count)"
  Test-Condition 'no JavaScript errors during the journey' ($cdp.Errors.Count -eq 0) ($cdp.Errors -join ' | ')

  # --- Layout and accessibility of every page (not installed) -----------------------------------------------------------------
  Check-Layout 'setup' "document.querySelector('#step-7 h2')"
  Check-Layout 'backups' "document.querySelector('main h1') && document.querySelector('main').innerText.includes('Export')"
  Check-Layout 'help' "document.querySelector('.learn-card')"
  Check-Layout 'settings' "document.querySelector('main').innerText.includes('Detail level')"
  Check-Layout 'diagnostics' "document.querySelector('main').innerText.includes('Container logs')"
  Set-Viewport $cdp 390 844 -Mobile
  Go 'setup' "document.querySelector('#step-7 h2')"; Shot 'setup-journey-phone-390'
  Set-Viewport $cdp 820 1180 -Mobile
  Go 'help' "document.querySelector('.learn-card')"; Shot 'help-tablet-820'
  Set-Viewport $cdp 1366 900
  Go 'help/cf-turnstile' "document.querySelector('#topic-cf-turnstile.focus')"
  Test-Condition 'help: contextual links open the matching learning topic' ([bool](Js "document.activeElement && document.activeElement.id === 'topic-cf-turnstile'")) ''
  Open-Page $cdp 'about:blank'; Start-Sleep -Milliseconds 300
  Go 'setup' "document.querySelector('#step-1 h2')"
  Send-Key $cdp 'Tab'
  $first = [string](Js "document.activeElement.className")
  Test-Condition 'keyboard: the first Tab reaches the skip link' ($first -match 'skip-link') $first
  $null = Js "document.querySelector('#step-1 .rv-toggle').focus(); true"
  $exp1 = [string](Js "document.querySelector('#step-1 .rv-toggle').getAttribute('aria-expanded')")
  Send-Key $cdp 'Enter'; Start-Sleep -Milliseconds 300
  $exp2 = [string](Js "document.querySelector('#step-1 .rv-toggle').getAttribute('aria-expanded')")
  Test-Condition 'keyboard: steps open and close with Enter (aria-expanded updates)' ($exp1 -ne $exp2) "$exp1 -> $exp2"
  $null = Js "(() => { const x = document.querySelector('#step-3 .help-btn') || document.querySelector('.help-btn'); x.click(); })(); true"
  Test-Condition 'contextual help: a ? control shows a short explanation from the learning catalog' ([bool](Js "!!document.querySelector('.help-panel') && document.querySelector('.help-panel').innerText.length > 40")) ''

  # --- Part 2: local-only installation through the UI (disposable instance) ----------------------------------------------------
  if ($SkipInstall) { Add-Result 'SKIP' 'installation through the UI' '-SkipInstall' }
  else {
    Stop-TestServer $ui; $ui = $null
    $uiB = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $pathB -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui-b')).FullName -ApiBase $mock.Base
    $null = Connect-WebUi $uiB
    $sug = (Invoke-WebUi $uiB POST '/api/setup/suggest' @{}).Data.settings
    $sug.STACK_NAME = $stackB; $sug.PROXY_NETWORK = "$stackB-proxy"
    $null = Invoke-WebUi $uiB POST '/api/setup/settings' @{ settings = $sug }
    $base = "http://127.0.0.1:$($uiB.Port)"
    Open-Page $cdp $uiB.LaunchUrl
    $null = Wait-PageCondition $cdp "document.querySelector('#step-1 h2')" 30; Prepare-Page
    $null = Js "__t.click('Skip: install for local use only'); true"
    $null = Wait-PageCondition $cdp "document.querySelector('#step-4 .step-summary') && document.querySelector('#step-4 .step-summary').innerText.includes('Local only')" 20
    Go 'setup/5' "document.querySelector('#step-body-5')"
    $null = Js "__t.click('Run the checks', document.querySelector('#step-5')); true"
    $null = Wait-PageCondition $cdp "document.querySelector('#rv-local-checks')" 120; Prepare-Page
    $null = Js "(() => { const b=[...document.querySelectorAll('#step-5 input[type=checkbox]')].pop(); b.click(); })(); true"; Start-Sleep -Milliseconds 400; Prepare-Page
    Test-Condition 'local only: step 6 needs no Cloudflare approval' ([string](Js "document.querySelector('#step-6 .step-summary').innerText") -match 'Not needed') ''
    $null = Js "__t.click('Install and verify'); true"; Start-Sleep -Milliseconds 500
    $null = Js "document.querySelector('#confirm-ok').click(); true"
    $installedB = $true
    $ok = Wait-PageCondition $cdp "document.querySelector('#step-7') && (document.querySelector('#step-7').innerText.includes('Your reverse proxy is ready') || document.querySelector('#step-7').innerText.includes('Not everything is healthy'))" 300
    $t7 = [string](Js "document.querySelector('#step-7').innerText")
    Shot 'setup-7-ready-1366'
    Test-Condition 'step 7: installs, verifies each component and shows "Your reverse proxy is ready."' ($ok -and $t7 -match 'Your reverse proxy is ready' -and $t7 -match 'Traefik container' -and $t7 -match 'Docker socket proxy' -and $t7 -match 'Traefik local dashboard' -and $t7 -match 'Dashboard internal router') ($t7.Substring(0, [Math]::Min(800, $t7.Length)))
    Go 'overview' "document.querySelector('.tiles')"
    $null = Wait-PageCondition $cdp "!document.querySelector('main').innerText.includes('Loading')" 30; Prepare-Page
    $tov = [string](Js "document.querySelector('main').innerText")
    Test-Condition 'overview: health tiles, request-flow topology, local dashboard link' ($tov -match 'Deployment' -and $tov -match '2 of 2 running' -and [bool](Js "!!document.querySelector('.topology, .xp-diagram')") -and $tov -match 'Local dashboard') ($tov.Substring(0, [Math]::Min(500, $tov.Length)))
    Test-Condition 'navigation: after installation the operational menu replaces the setup steps' ([int](Js "document.querySelectorAll('#rail a[href=\'#overview\'], #rail a[href=\'#services\'], #rail a[href=\'#diagnostics\']').length") -eq 3) ''
    Shot 'overview-1366'
    Go 'services' "document.querySelector('main h1') && document.querySelector('main h1').textContent === 'Services'"; Prepare-Page
    $null = Js "location.hash = '#services/add'; true"
    $null = Wait-PageCondition $cdp "document.querySelector('#svc-display')" 10; Prepare-Page
    $null = Js "__t.set('#svc-display', 'Notflix'); true"
    $s1 = [string](Js "document.querySelector('#svc-sub').value")
    $null = Js "__t.set('#svc-sub', 'movies'); __t.set('#svc-display', 'Notflix HD'); true"
    $s2 = [string](Js "document.querySelector('#svc-sub').value"); $disp = [string](Js "document.querySelector('#svc-display').value")
    Test-Condition 'services: subdomain suggested from the display name; a manual subdomain survives later name changes' ($s1 -eq 'notflix' -and $s2 -eq 'movies' -and $disp -eq 'Notflix HD') "$s1 $s2 $disp"
    $null = Js "__t.set('#svc-sub', 'movies'); document.querySelector('[aria-label=Domain]').value='example.test'; document.querySelector('[aria-label=Domain]').dispatchEvent(new Event('input', {bubbles:true})); __t.set('#svc-host', '10.99.0.5'); __t.set('#svc-port', '4119'); document.querySelector('input[name=svc-kind][value=lan]').click(); true"
    Start-Sleep -Milliseconds 300; Prepare-Page
    $null = Js "__t.set('#svc-host', '10.99.0.5'); __t.set('#svc-port', '4119'); document.querySelector('#svc-display').closest('form').requestSubmit(); true"
    $ok = Wait-PageCondition $cdp "document.querySelector('#plan-dialog').open && document.querySelector('#plan-title').textContent.includes('notflix')" 60; Prepare-Page
    Test-Condition 'services: Preview opens the change dialog (Traefik diff, nothing applied yet)' ($ok -and -not (Test-Path -LiteralPath (Join-Path $pathB 'traefik\dynamic\svc-notflix.yml'))) ([string](Js "document.querySelector('#plan-title').textContent"))
    Shot 'services-preview-1366'
    $null = Js "document.querySelector('#plan-reviewed').click(); __t.click('Apply changes', document.querySelector('#plan-dialog')); true"
    $ok = Wait-PageCondition $cdp "document.querySelector('#plan-title').textContent.includes('Changes applied')" 120
    $null = Js "document.querySelector('#plan-dialog').close(); true"
    Go 'services' "document.querySelector('tbody tr')"; Prepare-Page
    $row = [string](Js "document.querySelector('tbody tr').innerText")
    Test-Condition 'services: applied; the list shows the display name and the manual hostname' ($ok -and $row -match 'Notflix HD' -and $row -match 'movies\.example\.test') $row
    $reg = Get-Content -Raw (Join-Path $pathB 'config\services.json') | ConvertFrom-Json
    Test-Condition 'services: registry keeps id (from the name), display name and the manual hostname separately' ($reg.services[0].name -eq 'notflix-hd' -and $reg.services[0].displayName -eq 'Notflix HD' -and $reg.services[0].hostnames[0] -eq 'movies.example.test') ($reg | ConvertTo-Json -Depth 5 -Compress)
    Check-Layout 'overview' "document.querySelector('.tiles')"
    Check-Layout 'services' "document.querySelector('tbody tr')"
    Check-Layout 'cloudflare' "document.querySelector('main').innerText.includes('API token')"
    Check-Layout 'dashboard' "document.querySelector('main').innerText.includes('On this PC')"
    Check-Layout 'backups' "document.querySelector('main').innerText.includes('Recovery points')"
    Set-Viewport $cdp 390 844 -Mobile
    Go 'overview' "document.querySelector('.tiles')"; Start-Sleep -Seconds 2; Shot 'overview-phone-390'
    Go 'services' "document.querySelector('tbody tr')"; Shot 'services-phone-390'
    Set-Viewport $cdp 1366 900
    Go 'overview' "document.querySelector('.tiles')"
    $null = Js "TPMUI.setTheme('light'); true"; Start-Sleep -Seconds 2; Shot 'overview-light-1366'; $null = Js "TPMUI.setTheme('dark'); true"
    $null = Js "TPMUI.setLevel('expert'); true"
    Go 'diagnostics' "document.querySelector('main').innerText.includes('Generated configuration')"; Prepare-Page
    $null = Js "__t.click('Show generated configuration'); true"
    $ok = Wait-PageCondition $cdp "document.querySelector('#expert-out details')" 30
    $exp = [string](Js "document.querySelector('#expert-out').innerText")
    Test-Condition 'expert: generated configuration and exact commands are inspectable, without secrets' ($ok -and $exp -match 'install.ps1' -and $exp -match 'docker compose' -and $exp -notmatch [regex]::Escape($apiToken)) ''
    Shot 'diagnostics-expert-1366'
    Test-Condition 'no JavaScript errors on the operational pages' ($cdp.Errors.Count -eq 0) ($cdp.Errors -join ' | ')
  }
} catch {
  Add-Result 'FAIL' 'browser test run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
} finally {
  Stop-EdgeSession $cdp
  if ($installedB) {
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') -InstallPath $pathB -Stop 2>&1
    $null = Invoke-Docker network rm "$stackB-proxy"
    $left = @((Invoke-Docker ps -a --filter "name=$stackB" --format '{{.Names}}').Output | Where-Object { $_ })
    Test-Condition 'teardown: the disposable instance is gone' ($left.Count -eq 0) ($left -join ', ')
  }
  Stop-TestServer $ui; Stop-TestServer $uiB; Stop-TestServer $mock
  Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
