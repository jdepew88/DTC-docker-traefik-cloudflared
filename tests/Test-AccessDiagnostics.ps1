#requires -version 5.1
<#
.SYNOPSIS
  Identity & Access diagnostics without Docker, authentik or a network (lib\AccessDiagnostics.psm1): Cloudflare
  Access coverage (exact, path-scoped, wildcard, multi-domain, destinations, SaaS ignored), authentication modes
  (authentik, Cloudflare Access, explicit layered, unconfirmed layering, native, none), one diagnosis per application
  (availability separate from authentication, redundant and foreign Access logins, provider and outpost errors,
  ForwardAuth states), redirect-hop classification (which component asks for authentication), URL redaction and
  browser-facing addresses. Also the service validation rule that refuses Cloudflare Access + authentik unless
  layered authentication was chosen, and the Cloudflare planner's handling of stale and wildcard Access applications
  (Cloudflare API mock).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-AccessDiagnostics.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\AccessDiagnostics.psm1') -Force
Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  $status = $(if ($Condition) { 'PASS' } else { 'FAIL' })
  $null = $script:Results.Add([pscustomobject]@{ Status = $status; Test = $Name })
  Write-Host ('[{0}] {1}  {2}' -f $status, $Name, $(if ($Condition) { '' } else { $Detail })) -ForegroundColor $(if ($Condition) { 'Green' } else { 'Red' })
}
function Show($R) { return ($R | ConvertTo-Json -Depth 6 -Compress) }
function App([string]$Id, [string]$Name, [string]$Domain, $Extra = @{}) { $a = [ordered]@{ id = $Id; name = $Name; domain = $Domain; type = 'self_hosted'; policies = @(@{ decision = 'allow' }) }; foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }; return [pscustomobject]$a }
function Svc([string]$Auth = '', [bool]$Access = $false, [bool]$Publish = $true, [bool]$Layered = $false) {
  $s = [ordered]@{ name = 'app'; hostnames = @('app.example.com'); enabled = $true; cloudflare = [pscustomobject]@{ publish = $Publish; access = $Access } }
  if ($Auth) { $a = [ordered]@{ provider = $Auth; endpoint = 'http://authentik-server:9000' }; if ($Layered) { $a.layered = $true }; $s.auth = [pscustomobject]$a }
  return [pscustomobject]$s
}

# --- Access coverage ---------------------------------------------------------------------------------------------------
Test-Condition 'pattern: exact hostname' (Test-AccessPatternCovers 'uptime.example.com' 'uptime.example.com')
Test-Condition 'pattern: other hostname does not match' (-not (Test-AccessPatternCovers 'uptime.example.com' 'remote.example.com'))
Test-Condition 'pattern: *.zone covers a subdomain and a deeper one, not the apex' ((Test-AccessPatternCovers '*.example.com' 'a.example.com') -and (Test-AccessPatternCovers '*.example.com' 'a.b.example.com') -and -not (Test-AccessPatternCovers '*.example.com' 'example.com'))
Test-Condition 'pattern: prefix wildcard (*-site.zone) and case-insensitivity' ((Test-AccessPatternCovers '*-site.Example.com' 'pr-1-site.example.COM') -and -not (Test-AccessPatternCovers '*-site.example.com' 'site.example.com'))
Test-Condition 'pattern: path-scoped (host/admin) covers the host; regex characters are literal' ((Test-AccessPatternCovers 'app.example.com/admin' 'app.example.com') -and -not (Test-AccessPatternCovers 'appXexample.com' 'app.example.com'))
$apps = @(
  (App 'dtc-1' 'uptime.example.com (stack)' 'uptime.example.com'),
  (App 'wild-1' 'All subdomains' '*.example.com'),
  (App 'path-1' 'Admin only' 'app.example.com/admin'),
  (App 'multi-1' 'Multi' 'x.other.com' @{ self_hosted_domains = @('x.other.com', 'app.example.com') }),
  (App 'dest-1' 'Destinations' '' @{ destinations = @(@{ uri = 'app.example.com/api' }) }),
  (App 'saas-1' 'SaaS' 'app.example.com' @{ type = 'saas' }),
  (App 'none-1' 'Elsewhere' 'unrelated.org'))
$cov = @(Get-AccessCoverage -Apps $apps -Hostname 'uptime.example.com' -ManagedAppId 'dtc-1')
Test-Condition 'coverage: DTC-created exact app and a wildcard app both cover uptime; DTC one marked' ($cov.Count -eq 2 -and @($cov | Where-Object { $_.Id -eq 'dtc-1' -and $_.CreatedByTool -and -not $_.Wildcard }).Count -eq 1 -and @($cov | Where-Object { $_.Id -eq 'wild-1' -and $_.Wildcard -and -not $_.CreatedByTool }).Count -eq 1) (Show $cov)
$cov2 = @(Get-AccessCoverage -Apps $apps -Hostname 'app.example.com')
Test-Condition 'coverage: wildcard, path-scoped, self_hosted_domains and destinations found; SaaS and unrelated ignored' ((@($cov2 | ForEach-Object { $_.Id }) -join ',') -eq 'wild-1,path-1,multi-1,dest-1' -and @($cov2 | Where-Object { $_.Id -eq 'path-1' -and $_.PathOnly }).Count -eq 1 -and @($cov2 | Where-Object { $_.Id -eq 'multi-1' -and -not $_.PathOnly }).Count -eq 1) (Show $cov2)
Test-Condition 'coverage: nothing covers an unrelated hostname' (@(Get-AccessCoverage -Apps $apps -Hostname 'remote.other.net').Count -eq 0)

# --- Modes --------------------------------------------------------------------------------------------------------------
Test-Condition 'mode: authentik' ((Get-ServiceAuthMode (Svc 'authentik')) -eq 'authentik')
Test-Condition 'mode: Cloudflare Access only' ((Get-ServiceAuthMode (Svc '' $true)) -eq 'cloudflare-access')
Test-Condition 'mode: authentik + Access chosen as layered' ((Get-ServiceAuthMode (Svc 'authentik' $true $true $true)) -eq 'layered')
Test-Condition 'mode: authentik + Access not confirmed as layered' ((Get-ServiceAuthMode (Svc 'authentik' $true)) -eq 'layered-unconfirmed')
Test-Condition 'mode: native (declared own login) and none' ((Get-ServiceAuthMode (Svc 'native')) -eq 'native' -and (Get-ServiceAuthMode (Svc)) -eq 'none')

# --- Diagnosis ----------------------------------------------------------------------------------------------------------
$base = @{ hostname = 'uptime.example.com'; enabled = $true; publish = $true; authMode = 'authentik'; container = 'running'; router = 'enabled'; forwardAuthConfigured = $true; forwardAuthLoaded = $true; authentikApp = $true; outpostAssigned = $true; challenge = 'auth'; providerExternalHost = 'https://uptime.example.com'; expectedExternalHost = 'https://uptime.example.com'; providerMode = 'forward_single'; accessCoverage = @() }
function D($Over) { $f = @{} + $base; foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }; return Get-AppAccessDiagnosis $f }
$d = D @{}
Test-Condition 'diagnosis: healthy protected application' ($d.state -eq 'healthy' -and $d.tone -eq 'ok' -and @($d.problems).Count -eq 0) (Show $d)
$d = D @{ container = 'exited' }
Test-Condition 'diagnosis: stopped container is an availability problem, not a sign-in failure' ($d.state -eq 'stopped' -and $d.message -match 'availability' -and -not @($d.problems | Where-Object { $_.state -match 'forwardauth|provider|oauth' }).Count) (Show $d)
$d = D @{ container = 'missing' }
Test-Condition 'diagnosis: missing container' ($d.state -eq 'missing-container') (Show $d)
$d = D @{ router = 'missing' }
Test-Condition 'diagnosis: missing Traefik route' ($d.state -eq 'missing-route') (Show $d)
$d = D @{ backend = 'unreachable' }
Test-Condition 'diagnosis: backend unreachable (container running)' ($d.state -eq 'backend-unreachable') (Show $d)
$d = D @{ authentikApp = $false }
Test-Condition 'diagnosis: authentik application missing = provider error' ($d.state -eq 'provider-error') (Show $d)
$d = D @{ providerExternalHost = 'https://old.example.com' }
Test-Condition 'diagnosis: provider external address differs from the hostname' ($d.state -eq 'provider-error' -and $d.message -match 'old\.example\.com') (Show $d)
$d = D @{ providerMode = 'proxy' }
Test-Condition 'diagnosis: provider not in ForwardAuth mode' ($d.state -eq 'provider-error') (Show $d)
$d = D @{ outpostAssigned = $false }
Test-Condition 'diagnosis: provider not on the embedded outpost' ($d.state -eq 'outpost-error') (Show $d)
$d = D @{ forwardAuthConfigured = $false }
Test-Condition 'diagnosis: route does not ask authentik' ($d.state -eq 'missing-protection') (Show $d)
$d = D @{ challenge = 'open' }
Test-Condition 'diagnosis: anonymous request reaches the app = not enforced' ($d.state -eq 'forwardauth-error' -and $d.label -match 'Not enforced') (Show $d)
$d = D @{ challenge = 'misrouted' }
Test-Condition 'diagnosis: sign-in sent to a non-public address' ($d.state -eq 'forwardauth-error' -and $d.label -match 'address') (Show $d)
$d = D @{ accessCoverage = @(Get-AccessCoverage -Apps $apps -Hostname 'uptime.example.com' -ManagedAppId 'dtc-1' | Where-Object { $_.Id -eq 'dtc-1' }) }
Test-Condition 'diagnosis: DTC-created Access app in front of authentik = redundant Cloudflare login' ($d.state -eq 'redundant-access' -and $d.message -match 'created by DTC') (Show $d)
$d = D @{ accessCoverage = @(Get-AccessCoverage -Apps $apps -Hostname 'uptime.example.com' | Where-Object { $_.Id -eq 'wild-1' }) }
Test-Condition 'diagnosis: foreign wildcard Access app = conflict (not removable by DTC)' ($d.state -eq 'access-conflict' -and $d.message -match 'wildcard' -and $d.fix -match 'Zero Trust') (Show $d)
$d = D @{ authMode = 'layered'; accessCoverage = @(Get-AccessCoverage -Apps $apps -Hostname 'uptime.example.com' -ManagedAppId 'dtc-1') }
Test-Condition 'diagnosis: explicitly layered = no redundant-login warning' ($d.state -eq 'healthy' -and -not @($d.problems | Where-Object { $_.state -match 'access' }).Count) (Show $d)
$d = D @{ accessCoverage = @(Get-AccessCoverage -Apps $apps -Hostname 'app.example.com' | Where-Object { $_.Id -eq 'path-1' }); hostname = 'app.example.com'; providerExternalHost = 'https://app.example.com'; expectedExternalHost = 'https://app.example.com' }
Test-Condition 'diagnosis: a path-only Access app is not reported as a second login for the whole site' ($d.state -eq 'healthy') (Show $d)
$d = D @{ authMode = 'cloudflare-access'; accessCoverage = @() }
Test-Condition 'diagnosis: Access mode without any covering Access app = missing' ($d.state -eq 'access-missing') (Show $d)
$d = D @{ authMode = 'none' }
Test-Condition 'diagnosis: published without any sign-in is warned about' ($d.state -eq 'missing-protection' -and $d.tone -eq 'warn') (Show $d)
$d = D @{ authMode = 'none'; publish = $false }
Test-Condition 'diagnosis: local-only without sign-in = unpublished' ($d.state -eq 'unpublished') (Show $d)
$d = D @{ enabled = $false }
Test-Condition 'diagnosis: disabled route' ($d.state -eq 'disabled') (Show $d)
$d = D @{ hostname = '' }
Test-Condition 'diagnosis: missing hostname comes first' ($d.state -eq 'missing-hostname') (Show $d)
$d = D @{ container = 'exited'; accessCoverage = @(Get-AccessCoverage -Apps $apps -Hostname 'uptime.example.com' -ManagedAppId 'dtc-1' | Where-Object { $_.Id -eq 'dtc-1' }) }
Test-Condition 'diagnosis: both problems are listed (redundant login first, stopped also present)' ($d.state -eq 'redundant-access' -and @($d.problems | Where-Object { $_.state -eq 'stopped' }).Count -eq 1) (Show $d)

# --- Redirect classification and redaction ------------------------------------------------------------------------------
Test-Condition 'hop: Cloudflare Access login' ((Get-RedirectHopKind -Status 302 -Location 'https://team.cloudflareaccess.com/cdn-cgi/access/login/uptime.example.com?kid=1&redirect_url=%2F' -AuthHostname 'auth.example.com') -eq 'cloudflare-access')
Test-Condition 'hop: authentik (central sign-in host or authorize path)' ((Get-RedirectHopKind -Status 302 -Location 'https://auth.example.com/application/o/authorize/?client_id=x' -AuthHostname 'auth.example.com') -eq 'authentik' -and (Get-RedirectHopKind -Status 302 -Location '/outpost.goauthentik.io/start?rd=x') -eq 'authentik')
Test-Condition 'hop: a loopback address is a misconfiguration (Google rejects it)' ((Get-RedirectHopKind -Status 302 -Location 'http://127.0.0.1:9000/if/admin/' -AuthHostname 'auth.example.com') -eq 'local-address')
Test-Condition 'hop: Google, challenge, tunnel, backend, not routed, app' ((Get-RedirectHopKind -Status 302 -Location 'https://accounts.google.com/o/oauth2/v2/auth?x') -eq 'google' -and (Get-RedirectHopKind -Status 403 -Headers @{ 'cf-mitigated' = 'challenge' }) -eq 'cloudflare-challenge' -and (Get-RedirectHopKind -Status 530) -eq 'tunnel-error' -and (Get-RedirectHopKind -Status 502) -eq 'backend-error' -and (Get-RedirectHopKind -Status 404) -eq 'not-routed' -and (Get-RedirectHopKind -Status 200) -eq 'app' -and (Get-RedirectHopKind -Status 301 -Location 'https://app.example.com/') -eq 'redirect')
$v = Get-RedirectVerdict @(@{ kind = 'cloudflare-access' }) 'authentik'
Test-Condition 'verdict: Cloudflare Access first on an authentik app = redundant second login' ($v.component -eq 'Cloudflare Access' -and $v.message -match 'redundant') (Show $v)
$v = Get-RedirectVerdict @(@{ kind = 'backend-error' }) 'authentik'
Test-Condition 'verdict: Bad gateway = availability, not sign-in' ($v.message -match 'availability problem, not a sign-in problem') (Show $v)
$v = Get-RedirectVerdict @(@{ kind = 'app' }) 'authentik'
Test-Condition 'verdict: anonymous 200 on a protected app = protection not enforced' ($v.message -match 'NOT enforced') (Show $v)
$safe = ConvertTo-SafeUrl 'https://auth.example.com/source/oauth/callback/google/?code=4/0Secret&state=abc#frag'
Test-Condition 'redaction: query string and fragment removed (no codes or states)' ($safe -eq 'https://auth.example.com/source/oauth/callback/google/' -and $safe -notmatch 'Secret|state') $safe
Test-Condition 'redaction: user info dropped, port kept' ((ConvertTo-SafeUrl 'http://user:pw@127.0.0.1:9000/x?y=1') -eq 'http://127.0.0.1:9000/x') (ConvertTo-SafeUrl 'http://user:pw@127.0.0.1:9000/x?y=1')
Test-Condition 'redaction: relative location' ((ConvertTo-SafeUrl '/flows/-/default/authentication/?next=%2F') -eq '/flows/-/default/authentication/')

# --- Browser-facing addresses ---------------------------------------------------------------------------------------------
$bb = Get-AuthentikBrowserBase 'https://auth.example.com/' 'http://127.0.0.1:9000'
Test-Condition 'authentik links use the public address when there is one (not 127.0.0.1)' ($bb.Base -eq 'https://auth.example.com' -and $bb.Public) (Show $bb)
$bb = Get-AuthentikBrowserBase '' 'http://127.0.0.1:9000'
Test-Condition 'authentik links fall back to the local address, flagged as not public' ($bb.Base -eq 'http://127.0.0.1:9000' -and -not $bb.Public) (Show $bb)
Test-Condition 'open URL: published = https on the hostname' ((Get-ServiceOpenUrl (Svc 'authentik') 8180) -eq 'https://app.example.com/')
Test-Condition 'open URL: local only = http on the Traefik port' ((Get-ServiceOpenUrl (Svc '' $false $false) 8180) -eq 'http://app.example.com:8180/' -and (Get-ServiceOpenUrl (Svc '' $false $false) 80) -eq 'http://app.example.com/')
$pp = [pscustomobject]@{ hostnames = @('app.example.com'); pathPrefix = '/tools'; cloudflare = [pscustomobject]@{ publish = $true } }
Test-Condition 'open URL: path prefix kept' ((Get-ServiceOpenUrl $pp) -eq 'https://app.example.com/tools/')
Test-Condition 'open URL: no hostname = empty' ((Get-ServiceOpenUrl ([pscustomobject]@{ hostnames = @() })) -eq '')

# --- Validation: two interactive gateways only when chosen -----------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("accdiag-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $mk = { param([bool]$Layered) $a = @{ provider = 'authentik'; endpoint = 'http://authentik-server:9000' }; if ($Layered) { $a.layered = $true }
    ConvertTo-ServiceDefinition @{ name = 'kuma'; hostnames = @('uptime.example.com'); middlewares = @('default-headers@file'); target = @{ type = 'docker'; host = 'uptime-kuma'; port = 3001; protocol = 'http' }; cloudflare = @{ publish = $true; access = $true }; auth = $a } }
  $plain = & $mk $false
  $issues = @(Test-ServiceDefinition $plain)
  Test-Condition 'validation: Cloudflare Access + authentik without layered is an error (no silent double login)' (@($issues | Where-Object { $_.Level -eq 'Error' -and $_.Field -eq 'auth' -and $_.Message -match 'layered' }).Count -eq 1) (Show $issues)
  $lay = & $mk $true
  $issues = @(Test-ServiceDefinition $lay)
  Test-Condition 'validation: explicitly layered is accepted with a warning, and layered is stored' ($lay.auth.layered -and -not @($issues | Where-Object { $_.Level -eq 'Error' -and $_.Field -eq 'auth' }).Count -and @($issues | Where-Object { $_.Level -eq 'Warning' -and $_.Message -match 'Layered' }).Count -eq 1) (Show $issues)
  $noLay = ConvertTo-ServiceDefinition @{ name = 'k2'; hostnames = @('k2.example.com'); middlewares = @('default-headers@file'); target = @{ type = 'docker'; host = 'k2'; port = 1; protocol = 'http' }; auth = @{ provider = 'authentik'; endpoint = 'http://authentik-server:9000' } }
  Test-Condition 'registry: layered is not stored unless chosen (existing registries unchanged)' (-not $noLay.auth.PSObject.Properties['layered']) (Show $noLay)
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
