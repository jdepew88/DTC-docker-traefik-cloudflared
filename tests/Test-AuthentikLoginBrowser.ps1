#requires -version 5.1
<#
.SYNOPSIS
  Browser tests of the DTC sign-in experience (personalized Google button and picture shortcut), with real mouse,
  keyboard and touch input through Edge DevTools.

.DESCRIPTION
  Default: the offline preview (assets\authentik-login\preview.html), where the Google button is a stand-in that only
  counts presses. Nothing contacts Google or authentik.

  -Live -Url <sign-in page>: a real authentik sign-in page with the experience enabled (for example the local preview
  brand http://localhost:9000/if/flow/dm-login/). Requests to Google are BLOCKED in the test browser: the test reads
  the outgoing Google authorization address (login_hint, scope, state, prompt) and never signs in. With
  -ProtectedUrl it first opens a protected application address and checks that authentik keeps it (path and query)
  in the sign-in flow.

.EXAMPLE
  powershell -File tests\Test-AuthentikLoginBrowser.ps1
  powershell -File tests\Test-AuthentikLoginBrowser.ps1 -Live -Url http://localhost:9000/if/flow/dm-login/ -ExpectEmail joeydepew@gmail.com
#>
param(
  [string]$Url = '',
  [switch]$Live,
  [string]$ExpectEmail = 'joeydepew@gmail.com',
  [string]$ProtectedUrl = '',
  [string]$ScreenshotDir = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EdgeCdp.psm1') -Force
if (-not $Url) { $Url = ([Uri](Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\authentik-login\preview.html')).AbsoluteUri }
$script:pass = 0; $script:fail = 0
function Assert-That([bool]$Condition, [string]$Name, [string]$Detail = '') {
  if ($Condition) { $script:pass++; Write-Host "[PASS] $Name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red }
}

$deep = "function dq(r,s){const f=r.querySelector(s);if(f)return f;for(const e of r.querySelectorAll('*')){if(e.shadowRoot){const g=dq(e.shadowRoot,s);if(g)return g}}return null}"
$s = $null
function Open-SignIn([int]$W, [int]$H, [switch]$Touch, [string]$Hash = '') {
  Set-Viewport $s $W $H -Mobile:$Touch
  $null = Invoke-Cdp $s 'Emulation.setTouchEmulationEnabled' @{ enabled = [bool]$Touch; maxTouchPoints = 1 }
  $s.Requests.Clear()
  Open-Page $s 'about:blank'; Start-Sleep -Milliseconds 200
  Open-Page $s ($Url + $Hash)
  $ok = Wait-PageCondition $s "window.DtcLogin && DtcLogin.currentTargets && DtcLogin.currentTargets() && ($deep)(document,'button[data-dtc-continue]')" 40
  if ($ok) {
    $null = Invoke-PageScript $s "window.__starts=0;document.addEventListener('dtc-login:start',e=>{window.__starts++;window.__origin=e.detail.origin});true"
    Start-Sleep -Milliseconds 300
  }
  return $ok
}
function Get-Targets { return @(Invoke-PageScript $s 'JSON.stringify(DtcLogin.currentTargets())' | ConvertFrom-Json) }
function Get-Rect([string]$Selector) { return (Invoke-PageScript $s "JSON.stringify(($deep)(document,'$Selector').getBoundingClientRect())" | ConvertFrom-Json) }
function Send-Tap([double]$X, [double]$Y, [switch]$Touch) {
  if ($Touch) {
    $null = Invoke-Cdp $s 'Input.dispatchTouchEvent' @{ type = 'touchStart'; touchPoints = @(@{ x = $X; y = $Y }) }
    $null = Invoke-Cdp $s 'Input.dispatchTouchEvent' @{ type = 'touchEnd'; touchPoints = @() }
  } else {
    $null = Invoke-Cdp $s 'Input.dispatchMouseEvent' @{ type = 'mousePressed'; x = $X; y = $Y; button = 'left'; clickCount = 1 }
    $null = Invoke-Cdp $s 'Input.dispatchMouseEvent' @{ type = 'mouseReleased'; x = $X; y = $Y; button = 'left'; clickCount = 1 }
  }
  Start-Sleep -Milliseconds 120
}
function Send-Taps($Targets, [int[]]$Order, [switch]$Touch) { foreach ($i in $Order) { Send-Tap $Targets[$i].x $Targets[$i].y -Touch:$Touch } }
# Presses of the Google action: the preview's stand-in counter, or (live) requests to authentik's Google source.
function Get-Starts {
  if ($Live) { Start-Sleep -Milliseconds 1500; $null = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = '1' }; return @($s.Requests | Where-Object { $_.Url -match '/source/oauth/login/' }).Count }
  return [int](Invoke-PageScript $s 'window.previewGoogleClicks || 0')
}
function Save-Shot([string]$Name) { if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; Save-PageScreenshot $s (Join-Path $ScreenshotDir $Name) } }
function Test-Inside($T, $W, $H) { return ($T.x -ge 0 -and $T.y -ge 0 -and $T.x -le $W -and $T.y -le $H) }
function Test-Clear($T, $R) { return -not ($T.x -ge $R.left -and $T.x -le $R.right -and $T.y -ge $R.top -and $T.y -le $R.bottom) }

try {
  $s = Start-EdgeSession
  if ($Live) { $null = Invoke-Cdp $s 'Network.setBlockedURLs' @{ urls = @('*accounts.google.com*', '*googleapis.com*') } }
  Write-Host "Testing $Url$(if ($Live) { ' (live; Google requests are blocked)' } else { ' (offline preview)' })"

  # --- Deep link: a protected application address is kept through the sign-in flow (live only) ---------------------
  if ($Live -and $ProtectedUrl) {
    $s.Requests.Clear()
    Set-Viewport $s 1440 900
    Open-Page $s $ProtectedUrl
    $null = Wait-PageCondition $s "location.pathname.indexOf('/if/flow/')===0 && window.DtcLogin && ($deep)(document,'button[data-dtc-continue]')" 40
    $here = [string](Invoke-PageScript $s 'location.href')
    Write-Host "  sign-in page reached: $(([Uri]$here).GetLeftPart([UriPartial]::Path))"
    $pu = [Uri]$ProtectedUrl
    $chain = (@($s.Requests | ForEach-Object { [Uri]::UnescapeDataString([Uri]::UnescapeDataString($_.Url)) }) + [Uri]::UnescapeDataString([Uri]::UnescapeDataString($here))) -join "`n"
    Assert-That ($here -match '/if/flow/') 'protected address leads to the sign-in page' $here
    Assert-That ($chain.Contains($pu.Host)) 'the sign-in round trip carries the application host'
    Assert-That ($chain.Contains($pu.PathAndQuery)) "the sign-in round trip carries the exact path and query ($($pu.PathAndQuery))"
    $btnLive = [bool](Invoke-PageScript $s "!!($deep)(document,'button[data-dtc-continue]')")
    Assert-That $btnLive 'personalized button on the page reached from the protected address'
    $null = Invoke-PageScript $s "($deep)(document,'button[data-dtc-continue]').click();true"
    Start-Sleep -Seconds 3; $null = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = '1' }
    $g = @($s.Requests | Where-Object { $_.Url -match '^https://accounts\.google\.com/' })[0]
    Assert-That ([bool]$g) 'button leads to a Google authorization request'
    if ($g) {
      $q = @{}; foreach ($kv in ([Uri]$g.Url).Query.TrimStart('?').Split('&')) { $p = $kv.Split('=', 2); $q[[Uri]::UnescapeDataString($p[0])] = [Uri]::UnescapeDataString(($p[1] -replace '\+', ' ')) }
      Write-Host ("  Google request parameters: " + (($q.Keys | Sort-Object | Where-Object { $_ -notin 'state', 'code_challenge' } | ForEach-Object { "$_=$($q[$_])" }) -join '  ') + '  state=<' + ([string]$q['state']).Length + ' chars>')
      Assert-That ($q['login_hint'] -eq $ExpectEmail) "Google request has login_hint=$ExpectEmail" "login_hint=$($q['login_hint'])"
      Assert-That ([string]$q['state'] -match '^.{16,}$') 'Google request has an OAuth state'
      Assert-That (-not $q.ContainsKey('prompt')) 'no prompt parameter (Google may reuse its session; no forced account picker)' "prompt=$($q['prompt'])"
      $scopes = @(([string]$q['scope']).Split(' ') | Where-Object { $_ })
      Assert-That ((@($scopes | Where-Object { $_ -notin 'email', 'profile', 'openid' }).Count -eq 0) -and ($scopes -contains 'email')) 'only identity scopes requested' ($scopes -join ' ')
      Assert-That ([string]$q['redirect_uri'] -match '/source/oauth/callback/[a-z0-9_-]+/$') 'redirect_uri is authentik''s Google callback' $q['redirect_uri']
      Write-Host "  redirect_uri=$($q['redirect_uri'])"
    }
  }

  # --- Desktop ---------------------------------------------------------------------------------------------------
  Assert-That (Open-SignIn 1440 900) 'desktop: page, button and picture targets ready'
  $label = [string](Invoke-PageScript $s "($deep)(document,'button[data-dtc-continue]').textContent.trim()")
  $aria = [string](Invoke-PageScript $s "($deep)(document,'button[data-dtc-continue]').getAttribute('aria-label')")
  Assert-That ($label -eq "Continue as $ExpectEmail") 'button reads "Continue as <owner>"' $label
  Assert-That ($aria -eq "Continue as $ExpectEmail") 'button has a matching accessible name' $aria
  $t = Get-Targets
  $card = Get-Rect 'main.pf-c-login__main'
  Assert-That ($t.Count -ge 2) "picture targets present ($($t.Count))"
  Assert-That (@($t | Where-Object { -not (Test-Inside $_ 1440 900) }).Count -eq 0) 'desktop: every landmark is on screen'
  Assert-That (@($t | Where-Object { -not (Test-Clear $_ $card) }).Count -eq 0) 'desktop: no landmark is under the sign-in card'
  Save-Shot 'desktop.png'

  if (-not $Live) {
    # Keyboard: Tab reaches the button, Enter presses it once.
    $null = Invoke-PageScript $s 'document.activeElement && document.activeElement.blur(); true'
    $reached = $false
    for ($i = 0; $i -lt 12 -and -not $reached; $i++) {
      Send-Key $s 'Tab'
      $reached = [bool](Invoke-PageScript $s "(function(){let a=document.activeElement;while(a&&a.shadowRoot&&a.shadowRoot.activeElement)a=a.shadowRoot.activeElement;return !!(a&&a.hasAttribute&&a.hasAttribute('data-dtc-continue'))})()")
    }
    Assert-That $reached 'keyboard: Tab reaches the button'
    Send-Key $s 'Enter'
    Assert-That ((Get-Starts) -eq 1) 'keyboard: Enter presses it once'

    # Wrong order, a miss and a long pause reset quietly; the right order then works exactly once.
    $null = Open-SignIn 1440 900; $t = Get-Targets
    Send-Taps $t @(0, 2, 1)
    Assert-That ((Get-Starts) -eq 0 -and [int](Invoke-PageScript $s 'DtcLogin.sequenceStep()') -eq 0) 'wrong order: nothing happens, sequence reset'
    Send-Taps $t @(0, 1); Send-Tap 120 720; Send-Taps $t @(2)
    Assert-That ((Get-Starts) -eq 0) 'a tap on empty picture in between resets'
    Send-Taps $t @(0, 1); Start-Sleep -Milliseconds 6500; Send-Taps $t @(2)
    Assert-That ((Get-Starts) -eq 0 -and [int](Invoke-PageScript $s 'DtcLogin.sequenceStep()') -eq 0) 'pause longer than the timeout: reset'
    Send-Taps $t @(0); Send-Tap ($card.left + 12) ($card.top + 12); Send-Taps $t @(1, 2)
    Assert-That ((Get-Starts) -eq 1) 'correct order (with a tap on the card in between, which is ignored): one Google action'
    Assert-That ([string](Invoke-PageScript $s 'window.__origin') -eq 'picture') 'the action came from the picture'
    Send-Taps $t @(0, 1, 2, 0, 1, 2)
    Assert-That ((Get-Starts) -eq 1) 'more taps after completion do nothing'
    $btnOk = [bool](Invoke-PageScript $s "(function(){const b=($deep)(document,'button[data-dtc-continue]');return !!b&&!b.disabled})()")
    Assert-That $btnOk 'the button stays usable'
  }

  # --- Phone (touch, portrait) -------------------------------------------------------------------------------------
  Assert-That (Open-SignIn 390 844 -Touch) 'phone: page ready'
  $t = Get-Targets
  $card = Get-Rect 'main.pf-c-login__main'
  $btn = Get-Rect 'button[data-dtc-continue]'
  Assert-That (@($t | Where-Object { -not (Test-Inside $_ 390 844) }).Count -eq 0) 'phone: every landmark is on screen'
  Assert-That (@($t | Where-Object { -not (Test-Clear $_ $card) }).Count -eq 0) 'phone: no landmark is under the sign-in card'
  Assert-That (@($t | Where-Object { $_.r -lt 28 }).Count -eq 0) 'phone: every target is at least 56 px across'
  $minGap = 9999; for ($i = 0; $i -lt $t.Count; $i++) { for ($j = $i + 1; $j -lt $t.Count; $j++) { $minGap = [Math]::Min($minGap, [Math]::Sqrt([Math]::Pow($t[$i].x - $t[$j].x, 2) + [Math]::Pow($t[$i].y - $t[$j].y, 2))) } }
  Assert-That ($minGap -ge 56) "phone: targets do not overlap (closest centres $([int]$minGap) px apart)"
  Assert-That ($btn.top -ge 0 -and $btn.bottom -le 844 -and $btn.width -ge 200) 'phone: the button is fully visible without scrolling'
  $scrollW = [int](Invoke-PageScript $s 'document.documentElement.scrollWidth')
  Assert-That ($scrollW -le 390) "phone: no horizontal scrolling ($scrollW px)"
  Save-Shot 'phone.png'
  if (-not $Live) {
    Send-Taps $t @(1, 0, 2) -Touch
    Assert-That ((Get-Starts) -eq 0) 'phone: wrong order does nothing'
    Send-Taps $t @(0, 1, 2) -Touch
    Assert-That ((Get-Starts) -eq 1) 'phone: correct touches start the Google action once'
  }

  # --- Tablet portrait and small laptop: landmarks reachable -------------------------------------------------------
  foreach ($vp in @(@(820, 1180, $true), @(1280, 720, $false), @(1920, 1080, $false))) {
    $null = Open-SignIn $vp[0] $vp[1] -Touch:$vp[2]
    $t = Get-Targets; $card = Get-Rect 'main.pf-c-login__main'
    $okVis = @($t | Where-Object { -not (Test-Inside $_ $vp[0] $vp[1]) -or -not (Test-Clear $_ $card) }).Count -eq 0
    Assert-That $okVis "$($vp[0])x$($vp[1]): every landmark visible and clear of the card"
    Save-Shot "$($vp[0])x$($vp[1]).png"
  }

  # --- Calibration mode never signs in -----------------------------------------------------------------------------
  $null = Open-SignIn 1440 900 -Hash '#dtc-calibrate'
  $t = Get-Targets
  Send-Taps $t @(0, 1, 2)
  Assert-That ((Get-Starts) -eq 0) 'calibration mode: taps never start sign-in'
  $panel = [string](Invoke-PageScript $s "(document.getElementById('dtc-calibration')||{}).textContent||''")
  Assert-That ($panel -match '"x": 0\.\d+, "y": 0\.\d+') 'calibration mode: shows picture coordinates' $panel
  Save-Shot 'calibrate.png'

  if ($Live) {
    $null = Open-SignIn 1440 900; $t = Get-Targets
    Send-Taps $t @(0, 1, 2)
    Assert-That ((Get-Starts) -eq 1) 'live: picture shortcut opens authentik''s Google sign-in exactly once'
    $g = @($s.Requests | Where-Object { $_.Url -match '^https://accounts\.google\.com/' })[0]
    Assert-That ($g -and $g.Url -match ('[?&]login_hint=' + [Regex]::Escape([Uri]::EscapeDataString($ExpectEmail)) + '(&|$)')) "live: the picture's Google request has login_hint=$ExpectEmail"
  }
  $errs = @($s.Errors | Where-Object { $_ -notmatch 'ERR_BLOCKED_BY_CLIENT|net::ERR' })
  Assert-That ($errs.Count -eq 0) 'no script errors on the page' ($errs -join ' | ')
} finally {
  Stop-EdgeSession $s
}
Write-Host "`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
