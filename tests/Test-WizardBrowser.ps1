#requires -version 5.1
<#
.SYNOPSIS
  Focused browser test of the Add Service / Edit Service wizard's backend selection ("How should Traefik connect to
  this application?") in headless Microsoft Edge, against an INSTALLED instance, read-only.

.DESCRIPTION
  Starts a second web UI (own port, own session state) for -InstallPath and drives Services > Enter an HTTP backend
  manually like a user: an HTTP app on this Windows computer entered by its LAN address (the address entered versus
  the recommended host.docker.internal, each tested on its own from Traefik's network), the Docker host address, a
  Docker container on the shared network and one without a shared network, a custom backend URL, validation, all four
  detail levels, keyboard selection, switching options and browser back/forward, the change preview (exact backend
  URL, "Save the route anyway" for an unreachable backend, the Cloudflare preview) and Edit Service.

  Nothing is applied: the preview dialog is always closed with Cancel. The test fails if traefik\dynamic,
  config\services.json, the tunnel configuration or the Docker containers and networks differ afterwards. Cloudflare
  is only read (the preview computes the DNS, tunnel route and Access actions without performing them). Connection
  tests run short-lived, read-only probe containers in Traefik's network namespace.

.PARAMETER AppAddress
  This computer's LAN address of an HTTP app running directly on Windows (e.g. HFS on 10.20.30.11:80).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-WizardBrowser.ps1 -InstallPath $env:USERPROFILE\.docker\projects\traefik-proxy -AppAddress 10.20.30.11 -AppPort 80 -Subdomain files -ScreenshotDir .\wizard-shots
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstallPath,
  [Parameter(Mandatory = $true)][string]$AppAddress,
  [int]$AppPort = 80,
  [string]$Subdomain = 'files',
  [string]$Domain = '',
  [string]$Container = 'uptime-kuma',
  [string]$ContainerUrl = 'http://uptime-kuma:3001',
  [string]$EditService = 'mediabox',
  # Allowed email for the Cloudflare Access preview (the preview is blocked without one, by design).
  [string]$AccessEmail = '',
  [string]$ScreenshotDir
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\EdgeCdp.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor (@{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status])
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
if (-not (Get-EdgePath)) { Add-Result 'SKIP' 'wizard browser tests' 'Microsoft Edge not found'; exit 0 }
if (-not (Test-Path -LiteralPath (Join-Path $InstallPath '.env'))) { throw "No installed instance at $InstallPath." }

$JsHelpers = @'
window.__t = {
  btn: (text, root) => { const all = [...(root || document).querySelectorAll('button, a.btn')]; return all.find((b) => b.textContent.trim() === text) || all.find((b) => b.textContent.trim().includes(text)); },
  click: (text, root) => { const b = __t.btn(text, root); if (!b) throw new Error('no button ' + text); b.click(); return true; },
  set: (sel, value) => { const el = document.querySelector(sel); if (!el) throw new Error('no ' + sel); el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return true; },
  shown: (el) => !!(el && (el.checkVisibility ? el.checkVisibility({ checkVisibilityCSS: true }) : el.offsetParent !== null)),
  visible: (sel) => __t.shown(document.querySelector(sel)),
  text: (sel) => { const el = document.querySelector(sel); return el ? el.innerText : ''; },
  cand: (url) => document.querySelector(`#svc-candidates input[name=svc-cand][value="${url}"]`),
  row: (url) => { const i = __t.cand(url); return i ? i.closest('label').innerText : ''; },
  selected: () => __t.text('#svc-selected-url'),
  overflow: () => document.documentElement.scrollWidth - window.innerWidth,
  unnamed: () => {
    const name = (el) => el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('aria-labelledby') || (el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`)) || el.closest('label') || (['BUTTON', 'A'].includes(el.tagName) && el.textContent.trim());
    return [...document.querySelectorAll('button, a[href], input:not([type=hidden]), select, textarea')].filter((el) => __t.shown(el) && !name(el)).map((el) => `${el.tagName.toLowerCase()}#${el.id || ''}`);
  },
};
true
'@
function Js([string]$Expr) { return Invoke-PageScript $cdp $Expr }
function Prepare-Page { $null = Invoke-PageScript $cdp $JsHelpers }
function Wait([string]$Expr, [int]$Seconds = 60) { $ok = Wait-PageCondition $cdp $Expr $Seconds; Prepare-Page; return $ok }
function Go([string]$Hash, [string]$Ready) {
  Open-Page $cdp "$base/#$Hash"
  if (-not (Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && ($Ready)" 60)) { throw "Page #$Hash did not render ($Ready)." }
  Prepare-Page
}
function Shot([string]$Name) {
  if (-not $ScreenshotDir) { return }
  try { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "$Name.png") } catch { Write-Host "  (screenshot $Name skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}
function Backend { return [string](Js "__t.text('#svc-backend')") }
# A level switch re-renders the page (the form keeps its state); wait until the form is back.
function Set-Level([string]$Level) {
  $hadForm = [bool](Js "!!document.querySelector('#svc-backend')")
  $null = Js "TPMUI.setLevel('$Level'); true"; Start-Sleep -Milliseconds 300
  if ($hadForm) { $null = Wait-PageCondition $cdp "document.querySelector('#svc-display') && document.querySelector('#svc-backend') && !/Looking at Docker/.test(document.querySelector('#svc-backend').innerText)" 60 }
  Prepare-Page
}
function Close-Plan { $null = Js "(() => { const d = document.querySelector('#plan-dialog'); const c = d.querySelector('[data-close]'); if (c) c.click(); if (d.open) d.close(); return true; })()"; Start-Sleep -Milliseconds 300 }
# What must not change: generated routes, the registry, the tunnel configuration, containers and networks.
function Get-Fingerprint {
  $files = @()
  foreach ($rel in @('traefik\dynamic', 'config', 'cloudflared')) {
    $p = Join-Path $InstallPath $rel
    if (Test-Path -LiteralPath $p) { $files += @(Get-ChildItem -LiteralPath $p -File -Recurse | Sort-Object FullName | ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) }
  }
  $c = @((Invoke-Docker ps -a --format '{{.ID}} {{.Names}} {{.State}}').Output | Where-Object { $_ } | Sort-Object)
  $n = @((Invoke-Docker network ls --format '{{.ID}} {{.Name}}').Output | Where-Object { $_ } | Sort-Object)
  return (($files + $c + $n) -join "`n")
}

$entered = "http://${AppAddress}:$AppPort"
$gateway = "http://host.docker.internal:$AppPort"
$q = 'How should Traefik connect to this application?'
$work = Join-Path ([IO.Path]::GetTempPath()) ("tpm-wizard-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
$ui = $null; $cdp = $null
$before = Get-Fingerprint
try {
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $InstallPath -WorkDir $work
  $base = "http://127.0.0.1:$($ui.Port)"
  $cdp = Start-EdgeSession -WorkDir $work
  Set-Viewport $cdp 1366 900
  Open-Page $cdp $ui.LaunchUrl
  $null = Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp" 60
  Go 'services' "document.querySelector('main h1') && document.querySelector('main h1').textContent === 'Services'"
  # Services > Enter an HTTP backend manually.
  $null = Js "[...document.querySelectorAll('a.entry-card')].find((a) => a.innerText.includes('Enter an HTTP backend manually')).click(); true"
  if (-not (Wait "document.querySelector('#svc-display') && document.querySelector('#svc-backend')" 90)) {
    Shot 'wizard-0-not-opened'
    throw "The service form did not open: $([string](Js "__t.text('main')"))"
  }
  Set-Level 'intermediate'

  # --- The question and its options -----------------------------------------------------------------------------------
  $group = [string](Js "(document.querySelector('[role=radiogroup][aria-label=\'$q\']') || {}).innerText || ''")
  Test-Condition 'wizard: asks "How should Traefik connect to this application?" with three options and their descriptions' ([string](Js "__t.text('#svc-where-label')") -match [regex]::Escape($q) -and [int](Js "document.querySelectorAll('input[name=svc-where]').length") -eq 3 -and
    $group -match 'Docker container' -and $group -match 'container network name and internal port' -and $group -match 'Application on this computer' -and $group -match 'running directly on this Windows computer' -and
    $group -match 'Another computer or network device' -and $group -match 'IP address or hostname on your network') $group
  Test-Condition 'wizard: the old wording is gone' (-not [bool](Js "document.body.innerText.includes('Where is your application running?')")) ''

  # --- HFS on this computer, entered as its LAN address under "another computer or network device" ---------------------
  $null = Js "__t.set('#svc-display', '$Subdomain'); true"
  $zone = [string](Js "(() => { const d = document.querySelector('[aria-label=Domain]'); if (!d) return ''; if ('$Domain' && [...(d.options || [])].some((o) => o.value === '$Domain')) { d.value = '$Domain'; d.dispatchEvent(new Event('change', { bubbles: true })); } return d.value; })()")
  $null = Js "__t.set('#svc-sub', '$Subdomain'); document.querySelector('input[name=svc-where][value=lan]').click(); true"
  if ($AccessEmail) { $null = Js "document.querySelector('#svc-emails') && __t.set('#svc-emails', '$AccessEmail'); true" }
  $null = Wait "document.querySelector('#svc-address')" 10
  $null = Js "__t.set('#svc-address', '$AppAddress'); __t.set('#svc-port', '$AppPort'); true"
  $ok = Wait "__t.cand('$entered') && __t.cand('$gateway')" 90
  Test-Condition "selection: the address entered ($entered) and the recommended alternative ($gateway) each have a working control" ($ok -and -not [bool](Js "__t.cand('$entered').disabled") -and -not [bool](Js "__t.cand('$gateway').disabled") -and
    (Js "__t.row('$entered')") -match 'Address you entered' -and (Js "__t.row('$gateway')") -match 'Recommended alternative') (Backend)
  Test-Condition 'selection: the address entered stays selected; the recommendation does not replace it' ([bool](Js "__t.cand('$entered').checked") -and (Js '__t.selected()') -eq $entered -and -not [bool](Js "document.querySelector('input[name=svc-where][value=lan]') && !document.querySelector('input[name=svc-where][value=lan]').checked")) (Backend)
  $b = Backend
  Test-Condition 'explanation: why host.docker.internal is recommended, as a recommendation (not a warning)' ([bool](Js "!!document.querySelector('[data-guidance=own-lan-ip][data-category=recommendation]:not(.warn):not(.err)')") -and $b -match 'Docker Desktop provides host\.docker\.internal' -and $b -match 'Your LAN IP is also configurable') $b
  $overlap = [bool](Js "!!document.querySelector('[data-guidance=subnet-overlap]')")
  Test-Condition 'overlap: a Docker network on the same subnet is reported as a connectivity warning, by name (if one exists)' ((-not $overlap) -or ([string](Js "__t.text('[data-guidance=subnet-overlap]')") -match 'Your Docker network overlaps the destination subnet' -and [bool](Js "document.querySelector('[data-guidance=subnet-overlap]').classList.contains('warn')"))) ([string](Js "__t.text('[data-guidance=subnet-overlap]')"))
  Test-Condition 'validation: the old blocking message never appears' (-not ((Backend) -match 'Choose how Traefik reaches the app')) ''
  Shot 'wizard-1-entered-vs-recommended'

  # Each address tested on its own, from Traefik's network.
  $null = Js "__t.click('Test every address', document.querySelector('#svc-backend')); true"
  $ok = Wait "!/Testing/.test(__t.text('#svc-backend')) && /Verified|Timeout|refused|rejected|redirect|authentication|error|failure/i.test(__t.row('$entered')) && /Verified|Timeout|refused|rejected|redirect|authentication|error|failure/i.test(__t.row('$gateway'))" 120
  $rowE = [string](Js "__t.row('$entered')"); $rowG = [string](Js "__t.row('$gateway')")
  $enteredOk = $rowE -match 'Verified reachable|authentication required|Application redirect'
  $gatewayOk = $rowG -match 'Verified reachable|authentication required|Application redirect'
  Add-Result 'PASS' "connection test: $entered from Traefik -> $(($rowE -split "`n" | Where-Object { $_ -match 'Verified|Timeout|refused|rejected|redirect|authentication|error|failure' } | Select-Object -First 1))" ''
  Add-Result 'PASS' "connection test: $gateway from Traefik -> $(($rowG -split "`n" | Where-Object { $_ -match 'Verified|Timeout|refused|rejected|redirect|authentication|error|failure' } | Select-Object -First 1))" ''
  Test-Condition 'connection test: both addresses tested independently (each row has its own result)' ($ok) "$rowE | $rowG"
  if (-not $enteredOk) {
    $res = [string](Js "__t.text('#svc-test-result')")
    Test-Condition 'unreachable: "Traefik could not connect to …" with the attempted address, the failure, DNS/TCP steps and a way forward' ($res -match "Traefik could not connect to $([regex]::Escape("${AppAddress}:$AppPort"))|Traefik reached" -and $res -match 'TCP connection' -and $res -match 'save this route anyway|Choose another address') $res
    Test-Condition 'unreachable: the selection is not silently switched to the recommendation' ((Js '__t.selected()') -eq $entered) ''
    Shot 'wizard-2-unreachable-entered'
  }

  # Keyboard: arrow keys move between the candidate radios; the choice is kept.
  $null = Js "__t.cand('$entered').focus(); true"
  Send-Key $cdp 'ArrowDown'
  $ok = Wait "__t.selected() === '$gateway'" 20
  Test-Condition 'keyboard: arrow keys select the other candidate' $ok ([string](Js '__t.selected()'))
  if ($gatewayOk) {
    $res = [string](Js "__t.text('#svc-test-result')")
    Test-Condition 'reachable: "Traefik successfully connected to the selected application."; connectivity warnings disappear' ($res -match 'Traefik successfully connected to the selected application' -and -not [bool](Js "!!document.querySelector('[data-guidance=subnet-overlap]')")) $res
    Shot 'wizard-3-recommended-selected-verified'
  }
  # Unrelated changes keep the choice; changing the address or port recomputes.
  $null = Js "__t.set('#svc-display', '$Subdomain app'); __t.set('#svc-sub', '$Subdomain'); document.querySelector('input[name=svc-exp][value=local]').click(); true"; Start-Sleep -Milliseconds 1500; Prepare-Page
  $null = Js "document.querySelector('input[name=svc-exp][value=access]') && !document.querySelector('input[name=svc-exp][value=access]').disabled && document.querySelector('input[name=svc-exp][value=access]').click(); true"; Start-Sleep -Milliseconds 1200; Prepare-Page
  Test-Condition 'selection: unrelated form changes (name, exposure) do not overwrite the choice' ((Js '__t.selected()') -eq $gateway) ([string](Js '__t.selected()'))
  # Switching options and back keeps the typed address and the choice.
  $null = Js "document.querySelector('input[name=svc-where][value=docker]').click(); true"; $null = Wait "document.querySelector('#svc-container')" 20
  $null = Js "document.querySelector('input[name=svc-where][value=lan]').click(); true"; $null = Wait "__t.cand('$gateway')" 60
  Test-Condition 'options: switching to "Docker container" and back keeps the typed address and the chosen backend' ([string](Js "document.querySelector('#svc-address').value") -eq $AppAddress -and (Js '__t.selected()') -eq $gateway) "$([string](Js "document.querySelector('#svc-address').value")) $([string](Js '__t.selected()'))"
  # Back and forward in the browser.
  $null = Js "location.hash = '#overview'; true"; $null = Wait "document.querySelector('.tiles') || document.querySelector('main h1')" 30
  $null = Js "history.back(); true"; $ok = Wait "__t.cand('$gateway')" 60
  Test-Condition 'navigation: leaving the form and coming back (browser Back) keeps the address and the chosen backend' ($ok -and [string](Js "document.querySelector('#svc-address').value") -eq $AppAddress -and (Js '__t.selected()') -eq $gateway) ([string](Js '__t.selected()'))

  # Detail levels: what is shown changes, the selection does not.
  Set-Level 'beginner'; $t = Backend
  Test-Condition 'beginner: plain sentence and status; no Docker networks or subnets; selection unchanged' ($t -match 'Traefik will reach' -and $t -notmatch 'Docker subnets' -and -not (Js "__t.visible('#svc-custom')") -and [bool](Js "__t.cand('$gateway').checked")) $t
  Shot 'wizard-4-beginner'
  Set-Level 'intermediate'; $t = Backend
  Test-Condition 'intermediate: address entered, recommended alternative, Traefik will use, connection status' ($t -match 'Address you entered' -and $t -match 'Recommended alternative' -and $t -match 'Traefik will use' -and $t -match 'Connection status') $t
  Set-Level 'advanced'; $null = Js "__t.click('View diagnostic details', document.querySelector('#svc-backend')); true"; Start-Sleep -Milliseconds 300; Prepare-Page; $t = Backend
  Test-Condition 'advanced: protocol and custom backend URL fields, candidates, host gateway and networks' ((Js "__t.visible('#svc-custom')") -and (Js "__t.visible('#svc-protocol')") -and $t -match 'Candidates' -and $t -match 'Host gateway' -and $t -match "Traefik's networks") $t
  Set-Level 'expert'; $t = Backend
  Test-Condition 'expert: exact backend URL, Docker subnets, generated Traefik service with the selected URL, redacted test output' ($t -match 'Exact backend URL' -and $t -match 'Docker subnets' -and $t -match 'Generated Traefik service' -and $t -match [regex]::Escape("url: $gateway") -and $t -match 'Connection test output') $t.Substring(0, [Math]::Min(800, $t.Length))
  Shot 'wizard-5-expert'

  # Custom backend URL (Advanced and Expert): validated, kept exactly as typed.
  $null = Js "document.querySelector('#svc-custom').closest('.field').querySelector('input[type=checkbox]').click(); true"; Start-Sleep -Milliseconds 200
  $null = Js "__t.set('#svc-custom', '$entered/private'); true"; Start-Sleep -Milliseconds 300
  Test-Condition 'custom URL: a base path is refused with an explanation' ([string](Js "__t.text('#svc-custom-error')") -match 'Path prefix') ([string](Js "__t.text('#svc-custom-error')"))
  $null = Js "__t.set('#svc-custom', '$entered'); true"
  $ok = Wait "__t.cand('$entered') && __t.cand('$entered').checked && /Custom address/.test(__t.row('$entered'))" 60
  Test-Condition 'custom URL: kept exactly as typed and selected ("Custom address")' ($ok -and (Js '__t.selected()') -eq $entered) (Backend)
  $null = Js "document.querySelector('#svc-custom').closest('.field').querySelector('input[type=checkbox]').click(); true"
  $null = Wait "__t.cand('$gateway')" 60
  Set-Level 'intermediate'

  # --- Previews (never applied) -------------------------------------------------------------------------------------------
  foreach ($pick in @($entered, $gateway)) {
    $null = Js "__t.cand('$pick') && !__t.cand('$pick').checked && __t.cand('$pick').click(); true"
    $null = Wait "__t.selected() === '$pick' && !/Testing/.test(__t.text('#svc-backend'))" 60
    $null = Js "document.querySelector('#svc-display').closest('form').requestSubmit(); true"
    $ok = Wait "document.querySelector('#plan-dialog').open && document.querySelector('#plan-content') && document.querySelector('#plan-content').innerText.length > 50" 150
    $plan = [string](Js "__t.text('#plan-content')")
    $url = [string](Js "__t.text('#plan-backend-url')")
    $ack = [bool](Js "!!document.querySelector('#plan-backend-ack')")
    Test-Condition "preview ($pick): the exact selected backend is what the Traefik service will use" ($ok -and $url -eq $pick -and $plan -match [regex]::Escape("url: $pick")) "$url | $($plan.Substring(0, [Math]::Min(500, $plan.Length)))"
    $passed = $plan -match 'Traefik successfully connected|it asks for a login'
    if ($passed) { Test-Condition "preview ($pick): a reachable backend needs no extra confirmation" (-not $ack) '' }
    else {
      $applyDisabled = [bool](Js "(() => { const r = document.querySelector('#plan-reviewed'); if (!r) return true; r.click(); const b = __t.btn('Apply changes', document.querySelector('#plan-dialog')); const d = b.disabled; r.click(); return d; })()")
      Test-Condition "preview ($pick): an unreachable backend is not green and needs an explicit ""Save the route anyway""" ($ack -and $applyDisabled -and $plan -match 'Traefik could not connect|needs attention|rejected') $plan.Substring(0, [Math]::Min(600, $plan.Length))
    }
    if ($AccessEmail) { Test-Condition "preview ($pick): with an allowed email the change can be applied after review (not applied here)" ([bool](Js "!!document.querySelector('#plan-reviewed')")) ([string](Js "__t.text('#plan-foot')")) }
    Test-Condition "preview ($pick): Cloudflare publication is previewed (DNS, tunnel route, Access) and nothing is applied" ($plan -match 'Cloudflare' -and $plan -match 'DNS record' -and $plan -match 'tunnel route' -and -not [bool](Js "document.querySelector('#plan-title').textContent.includes('Changes applied')")) ''
    Shot $(if ($pick -eq $entered) { 'wizard-6-preview-entered' } else { 'wizard-7-preview-recommended' })
    Close-Plan
  }

  # --- No backend selected --------------------------------------------------------------------------------------------------
  $null = Js "__t.click('Cancel', document.querySelector('#service-form-host')); true"
  $ok = Wait "location.hash === '#services' && !document.querySelector('#svc-display') && [...document.querySelectorAll('a.entry-card')].some((a) => a.innerText.includes('Enter an HTTP backend manually'))" 60
  $null = Js "[...document.querySelectorAll('a.entry-card')].find((a) => a.innerText.includes('Enter an HTTP backend manually')).click(); true"
  $ok2 = Wait "document.querySelector('#svc-backend') && document.querySelector('#svc-display').value === ''" 60
  Test-Condition 'cancel: closing the form leaves #services/add; "Enter an HTTP backend manually" opens a fresh form again' ($ok -and $ok2) 
  $null = Js "__t.set('#svc-display', 'nobackend'); document.querySelector('input[name=svc-where][value=lan]').click(); true"; $null = Wait "document.querySelector('#svc-address')" 10
  Start-Sleep -Milliseconds 1200
  $null = Js "document.querySelector('#svc-display').closest('form').requestSubmit(); true"; Start-Sleep -Milliseconds 400
  $errText = [string](Js "__t.text('#service-form-host form > .form-error')")
  Test-Condition 'validation: with no candidates the message says what to enter (not "choose an option")' ($errText -match 'Enter the address and port of the application' -and $errText -notmatch 'Choose how Traefik reaches') $errText

  # --- Application on this computer (host gateway) -------------------------------------------------------------------------
  $null = Js "document.querySelector('input[name=svc-where][value=this-computer]').click(); true"; $null = Wait "document.querySelector('#svc-address')" 10
  $null = Js "__t.set('#svc-port', '$AppPort'); true"
  $ok = Wait "__t.selected() === '$gateway'" 60
  $null = Js "__t.click('Test connection', document.querySelector('#svc-backend')); true"
  $ok2 = Wait "!/Testing/.test(__t.text('#svc-backend')) && document.querySelector('#svc-test-result')" 60
  Test-Condition 'this computer: just the port -> host.docker.internal selected automatically (the only candidate) and tested' ($ok -and $ok2) (Backend)
  Shot 'wizard-8-this-computer'
  $null = Js "__t.set('#svc-address', '127.0.0.1:$AppPort'); true"
  $ok = Wait "document.querySelector('[data-guidance=loopback]') && __t.cand('http://127.0.0.1:$AppPort')" 60
  Test-Condition 'this computer: 127.0.0.1 is listed but cannot be selected; host.docker.internal is used' ($ok -and [bool](Js "__t.cand('http://127.0.0.1:$AppPort').disabled") -and (Js '__t.selected()') -eq $gateway) (Backend)

  # --- Docker containers ------------------------------------------------------------------------------------------------------
  $null = Js "document.querySelector('input[name=svc-where][value=docker]').click(); true"
  $hasC = Wait "[...document.querySelectorAll('#svc-container option')].some((o) => o.value === '$Container')" 60
  if ($hasC) {
    $null = Js "__t.set('#svc-container', '$Container'); true"
    $ok = Wait "/^http:\/\/${Container}:\d+$/.test(__t.selected())" 60
    $null = Js "__t.click('Test connection', document.querySelector('#svc-backend')); true"
    $ok2 = Wait "!/Testing/.test(__t.text('#svc-backend')) && document.querySelector('#svc-test-result')" 60
    $sel = [string](Js '__t.selected()')
    $tr = [string](Js "__t.text('#svc-test-result')")
    Test-Condition "docker: $Container -> its Docker DNS name and internal port ($ContainerUrl, not a port typed under another option), reachable from Traefik" ($ok -and $ok2 -and $sel -eq $ContainerUrl -and $tr -notmatch 'could not connect|Wrong port|refused') "$sel | $tr"
    Shot 'wizard-9-docker-container'
  } else { Add-Result 'SKIP' 'docker container selection' "no running container named $Container" }
  $iso = [string](Js "(() => { const o = [...document.querySelectorAll('#svc-container option')].find((x) => / \(not on /.test(x.textContent) && !x.disabled); return o ? o.value : ''; })()")
  if ($iso) {
    $null = Js "__t.set('#svc-container', '$iso'); true"
    $ok = Wait "document.querySelector('[data-guidance=not-shared]') || document.querySelector('[data-guidance=private]')" 60
    Test-Condition "docker: a container without a shared network ($iso) is explained, with options instead of a silent pick" ($ok -and ([bool](Js "!!document.querySelector('[data-guidance=private]')") -or [int](Js "document.querySelectorAll('#svc-candidates input[name=svc-cand]').length") -ge 1)) (Backend)
  } else { Add-Result 'SKIP' 'docker container without a shared network' 'none running' }

  # --- Edit Service ------------------------------------------------------------------------------------------------------------
  $null = Js "__t.click('Cancel', document.querySelector('#service-form-host')); true"; Start-Sleep -Milliseconds 300
  Go 'services' "document.querySelector('tbody tr')"
  $hasEdit = [bool](Js "!!document.querySelector('button[aria-label=\'Edit $EditService\']')")
  if ($hasEdit) {
    $null = Js "document.querySelector('button[aria-label=\'Edit $EditService\']').click(); true"
    $ok = Wait "document.querySelector('#svc-backend') && __t.selected()" 60
    Test-Condition 'edit service: the same question, the saved backend kept as the selection' ($ok -and [string](Js "__t.text('#svc-where-label')") -match [regex]::Escape($q) -and [string](Js '__t.selected()') -ne '') "$([string](Js '__t.selected()'))"
    Shot 'wizard-10-edit-service'
    $null = Js "__t.click('Cancel', document.querySelector('#service-form-host')); true"
  } else { Add-Result 'SKIP' 'edit service' "no service named $EditService" }

  # --- Layout and accessibility of the form ----------------------------------------------------------------------------------
  $bad = @()
  foreach ($w in @(390, 820, 1366)) {
    Set-Viewport $cdp $w 900 -Mobile:($w -lt 800)
    Go 'services/add' "document.querySelector('#svc-backend')"
    $null = Js "document.querySelector('input[name=svc-where][value=lan]').click(); true"; $null = Wait "document.querySelector('#svc-address')" 10
    $null = Js "__t.set('#svc-address', '$AppAddress'); __t.set('#svc-port', '$AppPort'); true"; $null = Wait "__t.cand('$entered')" 60
    $o = [int](Js '__t.overflow()'); if ($o -gt 1) { $bad += "$w px overflows by $o px" }
    if ($w -eq 390) { Shot 'wizard-11-phone-390' }
  }
  Set-Viewport $cdp 1366 900
  Test-Condition 'responsive: the wizard fits 390 / 820 / 1366 px without horizontal scrolling' ($bad.Count -eq 0) ($bad -join '; ')
  $unnamed = @(Js '__t.unnamed()')
  Test-Condition 'accessibility: every visible control in the wizard has a name; candidate radios are grouped under a legend' ($unnamed.Count -eq 0 -and [string](Js "__t.text('#svc-candidates legend')") -eq 'Address Traefik will use') ($unnamed -join ', ')
  $errs = @($cdp.Errors)
  Test-Condition 'browser: no JavaScript errors' ($errs.Count -eq 0) ($errs -join ' | ')
} finally {
  Stop-EdgeSession $cdp
  Stop-TestServer $ui
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$after = Get-Fingerprint
Test-Condition 'read-only: routes, registry, tunnel configuration, containers and networks are unchanged' ($before -eq $after) ((Compare-Object ($before -split "`n") ($after -split "`n") | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ' | ')

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
