#requires -version 5.1
<#
.SYNOPSIS
  Live end-to-end check that authentik sign-in can actually complete, as far as it can be checked without a Google
  account. Every wait is bounded: a page that keeps spinning is a failure, not a hang.

.DESCRIPTION
  It does not block Google and checks the return leg too: a sign-in can look fine up to Google and still hang on a
  spinner afterwards when authentik's containers cannot reach Google's token endpoint (for example a hung Docker engine).
  Works with whatever sign-in flow the default brand uses (DTC's dm-authentication or a flow customized in authentik).

  Browser (Edge, real input, desktop and phone size):
    - a protected application address leads to authentik's sign-in page; the exact path and query are carried;
    - the flow executor answers and the sign-in stage renders (no spinner left after -StageSeconds);
    - the Google button lands on Google's real sign-in page, not on a Google error page;
    - local sign-in: typing the admin user name reaches the password step (no password is sent);
    - the recovery flow loads.
  HTTP:
    - the Google callback with a real OAuth state and a deliberately invalid code is answered within
      -CallbackSeconds (authentik reached Google's token endpoint). See Test-AuthentikGoogleCallback.

  NOT covered (needs a person): signing in to Google, session establishment, return to the application, session
  reuse across applications. Do the manual browser test for those.

.EXAMPLE
  powershell -File tests\Test-AuthentikSignInHealth.ps1 -InstallPath C:\Users\<you>\.docker\projects\traefik-proxy `
    -ProtectedUrl 'https://uptime.example.com/dashboard/1?x=1'
#>
param(
  [Parameter(Mandatory = $true)][string]$InstallPath,
  [Parameter(Mandatory = $true)][string]$ProtectedUrl,
  [string]$AdminUser = 'akadmin',
  [int]$StageSeconds = 20,
  [int]$CallbackSeconds = 10,
  [string]$ScreenshotDir = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'EdgeCdp.psm1') -Force
foreach ($m in 'SecretStore', 'IdentityProvider', 'Authentik') { Import-Module (Join-Path $repo "lib\$m.psm1") -Force -DisableNameChecking }
$script:pass = 0; $script:fail = 0
function Assert-That([bool]$Condition, [string]$Name, [string]$Detail = '') {
  if ($Condition) { $script:pass++; Write-Host "[PASS] $Name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red }
}

$id = [IO.File]::ReadAllText((Join-Path $InstallPath 'config\identity.json')) | ConvertFrom-Json
$base = [string]$id.authentik.localUrl
$publicUrl = ([string]$id.authentik.publicUrl).TrimEnd('/')
$publicHost = ([Uri]$publicUrl).Host
$token = Read-ProtectedSecret -Settings ([pscustomobject]@{ InstallPath = $InstallPath }) -Name (Get-IdentityTokenSecretName)
$conn = New-AuthentikConnection -BaseUrl $base -Token $token; $token = $null
$brands = @(Get-AuthentikList $conn '/core/brands/')
$brand = @($brands | Where-Object { [bool]$_.default })[0]
if (-not $brand) { $brand = $brands[0] }
$flowSlug = [string](@(Get-AuthentikList $conn '/flows/instances/' | Where-Object { [string]$_.pk -eq [string]$brand.flow_authentication })[0].slug)
if (-not $flowSlug) { throw "The default brand's sign-in flow $($brand.flow_authentication) was not found." }
$recoverySlug = 'default-authentication-flow'
Write-Host "Public sign-in flow: $flowSlug  (brand custom CSS: $(([string]$brand.branding_custom_css).Length) chars)"

# --- HTTP: the return leg -----------------------------------------------------------------------------------------
$cb = Test-AuthentikGoogleCallback -BaseUrl $base -HostHeader $publicHost -FlowSlug $flowSlug -MaxSeconds $CallbackSeconds
Assert-That $cb.ok "Google callback answered in $($cb.callbackMs) ms (limit $CallbackSeconds s)" $cb.message

# --- Browser ------------------------------------------------------------------------------------------------------
$deep = "function dq(r,s){const f=r.querySelector(s);if(f)return f;for(const e of r.querySelectorAll('*')){if(e.shadowRoot){const g=dq(e.shadowRoot,s);if(g)return g}}return null}"
$deepAll = "function da(r,s,o){o=o||[];r.querySelectorAll(s).forEach(e=>o.push(e));r.querySelectorAll('*').forEach(e=>{if(e.shadowRoot)da(e.shadowRoot,s,o)});return o}"
$googleBtn = 'button[name="source-google"]'
# Rendered = the identification stage with its Google button and user field, and no visible spinner.
$rendered = "(()=>{$deep;$deepAll;const b=dq(document,'$googleBtn');const u=dq(document,'input[name=uidField]');const sp=da(document,'.pf-c-spinner,ak-spinner,ak-loading-overlay').filter(e=>e.getBoundingClientRect().width>0);return !!(b&&u&&b.getBoundingClientRect().width>0&&sp.length===0)})()"
function Save-Shot($S, [string]$Name) { if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; Save-PageScreenshot $S (Join-Path $ScreenshotDir $Name) } }
function Wait-Url($S, [string]$Pattern, [int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do { Start-Sleep -Milliseconds 500; try { $h = [string](Invoke-PageScript $S 'location.href'); if ($h -match $Pattern) { return $h } } catch { } } while ((Get-Date) -lt $deadline)
  try { return [string](Invoke-PageScript $S 'location.href') } catch { return '' }
}

foreach ($size in @(@{ Name = 'desktop'; W = 1440; H = 900; Mobile = $false }, @{ Name = 'phone'; W = 390; H = 844; Mobile = $true })) {
  $s = Start-EdgeSession
  try {
    Set-Viewport $s $size.W $size.H -Mobile:$size.Mobile
    $null = Invoke-Cdp $s 'Emulation.setTouchEmulationEnabled' @{ enabled = [bool]$size.Mobile; maxTouchPoints = 1 }
    Write-Host "`n[$($size.Name) $($size.W)x$($size.H)] $ProtectedUrl"
    $s.Requests.Clear()
    Open-Page $s $ProtectedUrl
    $ok = Wait-PageCondition $s $rendered $StageSeconds
    Save-Shot $s "$($size.Name)-1-sign-in.png"
    $here = [string](Invoke-PageScript $s 'location.href')
    Assert-That $ok "[$($size.Name)] sign-in stage rendered without a spinner within $StageSeconds s" $here
    Assert-That ($here -match "/if/flow/$([regex]::Escape($flowSlug))/") "[$($size.Name)] protected address leads to the sign-in flow $flowSlug" $here
    $pu = [Uri]$ProtectedUrl
    $chain = (@($s.Requests | ForEach-Object { [Uri]::UnescapeDataString([Uri]::UnescapeDataString($_.Url)) }) + [Uri]::UnescapeDataString([Uri]::UnescapeDataString($here))) -join "`n"
    Assert-That ($chain.Contains($pu.Host) -and $chain.Contains($pu.PathAndQuery)) "[$($size.Name)] the sign-in round trip carries the application address ($($pu.Host)$($pu.PathAndQuery))"
    $execOk = @($s.Requests | Where-Object { $_.Url -match "/api/v3/flows/executor/$([regex]::Escape($flowSlug))/" }).Count -gt 0
    Assert-That $execOk "[$($size.Name)] the flow executor was called"
    Assert-That (@($s.Errors).Count -eq 0) "[$($size.Name)] no JavaScript errors" ($s.Errors -join ' | ')
    if ($ok) {
      # A customized page may relabel the button after the stage renders; the label is only reported.
      Start-Sleep -Milliseconds 800
      $label = [string](Invoke-PageScript $s "($deep)(document,'$googleBtn').textContent.trim()")
      Write-Host "  Google button: '$($label -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<address>')'"
      $r = Invoke-PageScript $s "JSON.stringify(($deep)(document,'$googleBtn').getBoundingClientRect())" | ConvertFrom-Json
      $x = $r.left + $r.width / 2; $y = $r.top + $r.height / 2
      if ($size.Mobile) {
        $null = Invoke-Cdp $s 'Input.dispatchTouchEvent' @{ type = 'touchStart'; touchPoints = @(@{ x = $x; y = $y }) }
        $null = Invoke-Cdp $s 'Input.dispatchTouchEvent' @{ type = 'touchEnd'; touchPoints = @() }
      } else {
        $null = Invoke-Cdp $s 'Input.dispatchMouseEvent' @{ type = 'mousePressed'; x = $x; y = $y; button = 'left'; clickCount = 1 }
        $null = Invoke-Cdp $s 'Input.dispatchMouseEvent' @{ type = 'mouseReleased'; x = $x; y = $y; button = 'left'; clickCount = 1 }
      }
      $g = Wait-Url $s '^https://accounts\.google\.com/(v3/)?signin/(?!oauth/error)' $StageSeconds
      Save-Shot $s "$($size.Name)-2-google.png"
      Assert-That ($g -match '^https://accounts\.google\.com/' -and $g -notmatch '/oauth/error') "[$($size.Name)] the Google button lands on Google's sign-in page (no Google error)" ($g -replace 'login_hint=[^&]+', 'login_hint=<hint>')
      $auth = @($s.Requests | Where-Object { $_.Url -match '^https://accounts\.google\.com/o/oauth2/' })[0]
      if ($auth) {
        $q = @{}
        foreach ($kv in ([Uri]$auth.Url).Query.TrimStart('?').Split('&')) { $p = $kv.Split('=', 2); if ($p.Count -eq 2) { $q[[Uri]::UnescapeDataString($p[0])] = [Uri]::UnescapeDataString(($p[1] -replace '\+', ' ')) } }
        Assert-That ($q['redirect_uri'] -eq "$publicUrl/source/oauth/callback/google/" -and ([string]$q['state']).Length -ge 16 -and -not $q.ContainsKey('prompt')) "[$($size.Name)] Google request: redirect_uri, state, no forced prompt$(if ($q['login_hint']) { ', login_hint' })"
      }
    }
  } finally { Stop-EdgeSession $s }
}

# Local administrator and recovery (desktop).
$s = Start-EdgeSession
try {
  Set-Viewport $s 1440 900
  Open-Page $s "$publicUrl/if/flow/$flowSlug/"
  $null = Wait-PageCondition $s $rendered $StageSeconds
  $null = Invoke-PageScript $s "(()=>{$deep;const u=dq(document,'input[name=uidField]');u.focus();u.value='';return true})()"
  $null = Invoke-Cdp $s 'Input.insertText' @{ text = $AdminUser }
  Send-Key $s 'Enter'
  $pw = Wait-PageCondition $s "(()=>{$deep;return !!dq(document,'input[type=password]')})()" $StageSeconds
  Assert-That $pw "local sign-in: '$AdminUser' reaches the password step within $StageSeconds s (no password sent)"
  Open-Page $s "$publicUrl/if/flow/$recoverySlug/"
  $rec = Wait-PageCondition $s "(()=>{$deep;return !!dq(document,'input[name=uidField]')})()" $StageSeconds
  Assert-That $rec "recovery flow $recoverySlug loads within $StageSeconds s"
  Assert-That (@($s.Errors).Count -eq 0) 'no JavaScript errors (local sign-in, recovery)' ($s.Errors -join ' | ')
} finally { Stop-EdgeSession $s }

Write-Host "`n$($script:pass) passed, $($script:fail) failed"
Write-Host 'Not covered here (needs you): Google account sign-in, return to the application, session reuse across applications.' -ForegroundColor Yellow
if ($script:fail) { exit 1 }
