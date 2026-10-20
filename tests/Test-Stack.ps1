#requires -version 5.1
<#
.SYNOPSIS
  Live semantic tests for the Traefik + cloudflared stack (docker compose config alone is not enough).

.DESCRIPTION
  Starts the disposable whoami echo backend (profile `test`), runs the checks below, then removes it.
    - Compose config, Traefik health and version, no ERR log lines, no unexpected socket-proxy denials
    - Socket proxy: allowed read-only endpoints work, image listing and POST are denied, 2375 not published
    - Container-name DNS over the shared `proxy` network
    - Host-based routing, 404 for unknown hosts, dashboard only on loopback
    - X-Forwarded-* trusted only from the cloudflared address; spoofing from elsewhere is overwritten
    - WebSocket upgrade and a 25 MB streamed upload
    - OmniVoice routes (if traefik\dynamic\omnivoice.yml exists)
    - cloudflared connector health (if running); end-to-end through Cloudflare with -PublicTestHost

.PARAMETER PublicTestHost
  A tunnel public hostname that temporarily points at http://traefik:80 (e.g. whoami-test.example.com).
  whoami answers that Host only while this script runs. Delete the hostname in Cloudflare afterwards.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Stack.ps1
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Stack.ps1 -PublicTestHost whoami-test.example.com
#>
[CmdletBinding()]
param(
  [string]$ProjectPath,
  [string]$PublicTestHost,
  [switch]$KeepWhoami
)

$ErrorActionPreference = 'Stop'
# Resolved here: $PSScriptRoot/$MyInvocation are not populated in param() defaults on PowerShell 5.1.
if (-not $ProjectPath) { $ProjectPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
Set-StrictMode -Version 2.0

$TraefikImage = 'traefik:v3.7.15'
$ExpectedVersion = '3.7.15'
$CloudflaredIp = '172.31.250.10'
$TunnelNetwork = 'traefik-cloudflared_tunnel'
$WhoamiHost = 'whoami.localhost'
$script:Results = New-Object System.Collections.ArrayList

function Invoke-Native {
  $all = @($args | ForEach-Object { $_ })
  $exe = $all[0]
  $rest = @()
  if ($all.Count -gt 1) { $rest = $all[1..($all.Count - 1)] }
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $exe @rest 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Text = (@($output) -join "`n") }
}

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow'; WARN = 'Yellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}

function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail) {
  if ($Condition) { Add-Result 'PASS' $Name $Detail } else { Add-Result 'FAIL' $Name $Detail }
}

$composeBase = @('docker', 'compose', '--project-directory', $ProjectPath, '-f', (Join-Path $ProjectPath 'compose.yaml'))
$dotEnv = @{}
$envFile = Join-Path $ProjectPath '.env'
if (Test-Path -LiteralPath $envFile) {
  foreach ($line in Get-Content -LiteralPath $envFile) { if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $dotEnv[$Matches[1]] = $Matches[2] } }
}
$httpPort = 8180; if ($dotEnv.ContainsKey('TRAEFIK_HTTP_PORT') -and $dotEnv['TRAEFIK_HTTP_PORT']) { $httpPort = [int]$dotEnv['TRAEFIK_HTTP_PORT'] }
$dashPort = 8181; if ($dotEnv.ContainsKey('TRAEFIK_DASHBOARD_PORT') -and $dotEnv['TRAEFIK_DASHBOARD_PORT']) { $dashPort = [int]$dotEnv['TRAEFIK_DASHBOARD_PORT'] }
$base = "http://127.0.0.1:$httpPort"

function Invoke-Curl {
  # curl.exe ships with Windows 10/11; unlike Invoke-WebRequest on 5.1 it can set the Host header.
  $r = Invoke-Native curl.exe -s -S --max-time 20 @args
  return $r
}

Write-Host "Testing project at $ProjectPath" -ForegroundColor Cyan

# --- Static / container state -------------------------------------------------------------------
$cfg = Invoke-Native @($composeBase + @('config', '--quiet'))
Test-Condition 'compose config' ($cfg.ExitCode -eq 0) $cfg.Text

$health = Invoke-Native docker inspect traefik --format '{{.State.Health.Status}}'
Test-Condition 'traefik healthy' ($health.Text.Trim() -eq 'healthy') $health.Text.Trim()
if ($health.Text.Trim() -ne 'healthy') { Write-Host 'Traefik is not running/healthy; start it with docker compose up -d' -ForegroundColor Red; exit 1 }

$version = Invoke-Curl "http://127.0.0.1:$dashPort/api/version"
Test-Condition 'traefik version' ($version.Text -match ('"Version":"' + [regex]::Escape($ExpectedVersion) + '"')) $version.Text

$publishedTraefik = (Invoke-Native docker port traefik).Text
$loopbackOnly = -not ($publishedTraefik -split "`n" | Where-Object { $_ -and $_ -notmatch '-> 127\.0\.0\.1:' })
Test-Condition 'traefik ports loopback-only' $loopbackOnly ($publishedTraefik -replace "`n", '; ')

# --- Socket proxy --------------------------------------------------------------------------------
$socketPorts = (Invoke-Native docker port socket-proxy).Text.Trim()
Test-Condition 'socket-proxy not published' ($socketPorts -eq '') "docker port socket-proxy: '$socketPorts'"
$allowed = Invoke-Native docker exec traefik wget -q -O- http://socket-proxy:2375/version
Test-Condition 'socket-proxy allows /version' ($allowed.ExitCode -eq 0 -and $allowed.Text -match '"ApiVersion"') ''
$deniedImages = Invoke-Native docker exec traefik wget -q -O- http://socket-proxy:2375/images/json
Test-Condition 'socket-proxy denies /images' ($deniedImages.Text -match '403') $deniedImages.Text
$deniedPost = Invoke-Native docker exec traefik wget -q -O- --post-data '{}' http://socket-proxy:2375/containers/create
Test-Condition 'socket-proxy denies POST' ($deniedPost.Text -match '403') $deniedPost.Text

# --- Echo backend ----------------------------------------------------------------------------------
$up = Invoke-Native @($composeBase + @('--profile', 'test', 'up', '-d', 'whoami'))
Test-Condition 'whoami started' ($up.ExitCode -eq 0) ''
$deadline = (Get-Date).AddSeconds(30)
do {
  Start-Sleep -Milliseconds 500
  $routers = (Invoke-Curl "http://127.0.0.1:$dashPort/api/http/routers").Text
} while ($routers -notmatch 'whoami-test@docker' -and (Get-Date) -lt $deadline)
Test-Condition 'docker provider discovered whoami' ($routers -match 'whoami-test@docker') ''

try {
  $dns = Invoke-Native docker exec traefik wget -q -O- http://whoami-test/
  Test-Condition 'container-name DNS on proxy network' ($dns.Text -match 'Hostname:') 'traefik -> http://whoami-test/'

  $routed = Invoke-Curl -H "Host: $WhoamiHost" "$base/"
  Test-Condition 'host routing' ($routed.Text -match 'Hostname:' -and $routed.Text -match "Host: $WhoamiHost") "Host: $WhoamiHost"

  $unknown = Invoke-Curl -o NUL -w '%{http_code}' -H 'Host: nothing.invalid' "$base/"
  Test-Condition 'unknown host -> 404' ($unknown.Text.Trim() -eq '404') $unknown.Text

  # On `web`, /api/version must fall through to the app (whoami echoes it), never to api@internal.
  $dashOnWeb = Invoke-Curl -H "Host: $WhoamiHost" "$base/api/version"
  Test-Condition 'dashboard API not on web entrypoint' ($dashOnWeb.Text -notmatch 'Codename') 'GET /api/version on :80'

  $spoof = Invoke-Curl -H "Host: $WhoamiHost" -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.9' "$base/"
  Test-Condition 'untrusted X-Forwarded-* overwritten' ($spoof.Text -match 'X-Forwarded-Proto: http\r?\n' -and $spoof.Text -notmatch '203\.0\.113\.9') 'loopback client sent X-Forwarded-Proto: https'

  $cfRunning = (Invoke-Native docker inspect cloudflared --format '{{.State.Running}}').Text.Trim() -eq 'true'
  if ($cfRunning) {
    Add-Result 'SKIP' 'trusted X-Forwarded-* from cloudflared IP' "cloudflared holds $CloudflaredIp; covered by -PublicTestHost"
  } else {
    $trusted = Invoke-Native docker run --rm --network $TunnelNetwork --ip $CloudflaredIp --entrypoint wget $TraefikImage -q -O- --header "Host: $WhoamiHost" --header 'X-Forwarded-Proto: https' http://traefik/
    Test-Condition 'trusted X-Forwarded-* from cloudflared IP' ($trusted.Text -match 'X-Forwarded-Proto: https') "tunnel network -> http://traefik/ (also proves DNS on tunnel network)"
  }

  $ws = Invoke-Curl -i -N --http1.1 --max-time 3 -H "Host: $WhoamiHost" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$base/echo"
  Test-Condition 'websocket upgrade' ($ws.Text -match 'HTTP/1.1 101') (($ws.Text -split "`n") -match '^HTTP/' | Select-Object -First 1)

  $tmp = [IO.Path]::GetTempFileName()
  try {
    $bytes = New-Object byte[] (25MB)
    (New-Object Random).NextBytes($bytes)
    [IO.File]::WriteAllBytes($tmp, $bytes)
    $upload = Invoke-Curl -o NUL -w '%{http_code} %{size_upload}' -H "Host: $WhoamiHost" -H 'Content-Type: application/octet-stream' --data-binary "@$tmp" "$base/"
    Test-Condition '25 MB streamed upload' ($upload.Text -match '^200 26214400') $upload.Text
  } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }

  # --- Tunnel ------------------------------------------------------------------------------------
  if ($cfRunning) {
    $cfHealth = (Invoke-Native docker inspect cloudflared --format '{{.State.Health.Status}}').Text.Trim()
    Test-Condition 'cloudflared healthy' ($cfHealth -eq 'healthy') $cfHealth
    $cfLogs = (Invoke-Native docker logs --tail 300 cloudflared).Text
    Test-Condition 'tunnel connections registered' ($cfLogs -match 'Registered tunnel connection') ''
  } else {
    Add-Result 'SKIP' 'cloudflared' 'tunnel profile not running'
  }

  if ($PublicTestHost) {
    # Re-label whoami for the public test host only for the duration of this check.
    $env:WHOAMI_TEST_HOST = $PublicTestHost
    $null = Invoke-Native @($composeBase + @('--profile', 'test', 'up', '-d', 'whoami'))
    Remove-Item Env:\WHOAMI_TEST_HOST
    Start-Sleep -Seconds 3
    $public = Invoke-Curl -i "https://$PublicTestHost/"
    if ($public.Text -match 'Hostname:') {
      Test-Condition 'public: reached whoami through Cloudflare' $true $PublicTestHost
      Test-Condition 'public: X-Forwarded-Proto https preserved' ($public.Text -match 'X-Forwarded-Proto: https') ''
      Test-Condition 'public: Host header is public hostname' ($public.Text -match ('Host: ' + [regex]::Escape($PublicTestHost))) ''
      Test-Condition 'public: Cf-Connecting-Ip present' ($public.Text -match 'Cf-Connecting-Ip:') ''
    } elseif ($public.Text -match 'cloudflareaccess.com|HTTP/\S+ 30[23]') {
      Add-Result 'PASS' 'public: Cloudflare Access is enforcing login' $PublicTestHost
    } else {
      Add-Result 'FAIL' 'public: tunnel round trip' ((($public.Text -split "`n") | Select-Object -First 3) -join ' | ')
    }
    $null = Invoke-Native @($composeBase + @('--profile', 'test', 'up', '-d', 'whoami'))
  }

  # --- OmniVoice ---------------------------------------------------------------------------------
  $omniFile = Join-Path $ProjectPath 'traefik\dynamic\omnivoice.yml'
  if (Test-Path -LiteralPath $omniFile) {
    $omniHost = $null
    if ((Get-Content -LiteralPath $omniFile -Raw) -match 'Host\(`([^`]+)`\)') { $omniHost = $Matches[1] }
    foreach ($svc in @('omnivoice-triton-api', 'omnivoice-perform-api')) {
      $nets = (Invoke-Native docker inspect $svc --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}').Text
      Test-Condition "$svc attached to proxy" ($nets -match '(^|\s)proxy(\s|$)') $nets.Trim()
    }
    $api = Invoke-Curl -H "Host: $omniHost" "$base/api/health"
    Test-Condition 'OmniVoice /api/health via Traefik' ($api.Text -match '"status":\s*"ok"') $api.Text
    $perform = Invoke-Curl -H "Host: $omniHost" "$base/perform-api/health"
    Test-Condition 'OmniVoice /perform-api/health via Traefik' ($perform.Text -match '"status":\s*"ok"') ''
    $ui = Invoke-Curl -o NUL -w '%{http_code}' -H "Host: $omniHost" "$base/"
    if ($ui.Text.Trim() -eq '200') { Add-Result 'PASS' 'OmniVoice UI via Traefik' 'host.docker.internal:8010' }
    else { Add-Result 'WARN' 'OmniVoice UI via Traefik' "HTTP $($ui.Text.Trim()) - is the Vite server running (npm run dev / preview on port 8010)?" }
  } else {
    Add-Result 'SKIP' 'OmniVoice' 'traefik\dynamic\omnivoice.yml not present'
  }
} finally {
  if (-not $KeepWhoami) {
    $null = Invoke-Native @($composeBase + @('--profile', 'test', 'rm', '-s', '-f', 'whoami'))
    $left = (Invoke-Native docker ps -a --filter name=^whoami-test$ --format '{{.Names}}').Text.Trim()
    Test-Condition 'whoami removed after tests' ($left -eq '') ''
  }
}

# --- Logs --------------------------------------------------------------------------------------------
$traefikLogs = (Invoke-Native docker logs --since 30m traefik).Text
$errLines = @($traefikLogs -split "`n" | Where-Object { $_ -match '\bERR\b' })
Test-Condition 'no Traefik ERR log lines (30 min)' ($errLines.Count -eq 0) (($errLines | Select-Object -First 3) -join ' | ')
$proxyLogs = (Invoke-Native docker logs --since 30m socket-proxy).Text
$unexpected = @($proxyLogs -split "`n" | Where-Object { $_ -match '" 403 |\s403\s' -and $_ -notmatch '/images/json|/containers/create' })
Test-Condition 'no unexpected socket-proxy denials' ($unexpected.Count -eq 0) (($unexpected | Select-Object -First 3) -join ' | ')

# --- Summary -----------------------------------------------------------------------------------------
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} warnings, {3} skipped' -f `
  @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count,
  @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count,
  @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
