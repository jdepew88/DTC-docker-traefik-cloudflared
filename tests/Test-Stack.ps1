#requires -version 5.1
<#
.SYNOPSIS
  Live semantic tests for one running Traefik + cloudflared instance (docker compose config alone is not enough).

.DESCRIPTION
  Starts the disposable whoami echo backend (profile `test`), routes it with a file-provider route rendered by
  the same generator services.ps1 uses (written as traefik\dynamic\zz-test-whoami.yml, never into
  config\services.json), runs the checks below, then removes both.
    - Compose config, Traefik health and version, no ERR log lines, no unexpected socket-proxy denials
    - Socket proxy: allowed read-only endpoints work, image listing and POST are denied, 2375 not published
    - Container-name DNS over the shared proxy network
    - Generated route: host routing, path-prefix + strip-prefix, 404 for unknown hosts, dashboard only on loopback
    - X-Forwarded-* trusted only from the cloudflared address; spoofing from elsewhere is overwritten
    - WebSocket upgrade and a 25 MB streamed upload
    - Every enabled service in config\services.json has a loaded, enabled router (backend reachability is a warning)
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
Import-Module (Join-Path $ProjectPath 'lib\TraefikProxy.psm1') -Force

$settings = Get-StackSettings -InstallPath $ProjectPath
$ExpectedVersion = '3.7.15'
$TraefikC = $settings.TraefikContainer
$SocketC = $settings.SocketProxyContainer
$CloudflaredC = $settings.CloudflaredContainer
$WhoamiC = $settings.WhoamiContainer
$WhoamiHost = 'whoami.localhost'
$TestRouteFile = Join-Path $settings.DynamicDir 'zz-test-whoami.yml'
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

$composeBase = @('docker') + (Get-ComposeArgs -Settings $settings)
$base = "http://127.0.0.1:$($settings.HttpPort)"
$dashPort = $settings.DashboardPort

function Invoke-Curl {
  # curl.exe ships with Windows 10/11; unlike Invoke-WebRequest on 5.1 it can set the Host header.
  $r = Invoke-Native curl.exe -s -S --max-time 20 @args
  return $r
}

# Renders the test route with the production generator and makes Traefik load it.
function Set-TestRoute([string[]]$Hostnames) {
  $whoami = New-ServiceDefinition -Name 'whoami-test' -Hostname $Hostnames -TargetType docker -TargetHost $WhoamiC -Port 80 -Description 'Disposable test route (tests\Test-Stack.ps1)'
  $prefixed = New-ServiceDefinition -Name 'whoami-test-prefix' -Hostname $Hostnames[0] -TargetType docker -TargetHost $WhoamiC -Port 80 -PathPrefix '/prefixed' -StripPrefix
  # One file-provider document may hold only one http: block, so the two generated routes are merged.
  $yaml = Merge-RouteYaml (ConvertTo-TraefikRouteYaml $whoami) (ConvertTo-TraefikRouteYaml $prefixed)
  Write-TextFileAtomic $TestRouteFile $yaml
  $null = Sync-TraefikDynamic $settings
}

# Merges two generated single-service files (same section layout) into one file-provider document.
function Merge-RouteYaml([string]$A, [string]$B) {
  $sections = [ordered]@{ routers = @(); middlewares = @(); services = @(); serversTransports = @() }
  foreach ($doc in @($A, $B)) {
    $current = $null
    foreach ($line in ($doc -split "`n")) {
      if ($line -match '^  (routers|middlewares|services|serversTransports):\s*$') { $current = $Matches[1]; continue }
      if ($line -match '^\S' -or $line -eq '') { $current = $null; continue }
      if ($current) { $sections[$current] += $line }
    }
  }
  $out = @('# Disposable test routes written by tests\Test-Stack.ps1; removed when the tests finish.', 'http:')
  foreach ($key in $sections.Keys) { if ($sections[$key].Count -gt 0) { $out += "  ${key}:"; $out += $sections[$key] } }
  return ($out -join "`n") + "`n"
}

Write-Host "Testing instance '$($settings.StackName)' at $ProjectPath" -ForegroundColor Cyan

# --- Static / container state -------------------------------------------------------------------
$cfg = Invoke-Native @($composeBase + @('config', '--quiet'))
Test-Condition 'compose config' ($cfg.ExitCode -eq 0) $cfg.Text

$health = Invoke-Native docker inspect $TraefikC --format '{{.State.Health.Status}}'
Test-Condition 'traefik healthy' ($health.Text.Trim() -eq 'healthy') $health.Text.Trim()
if ($health.Text.Trim() -ne 'healthy') { Write-Host "Traefik ($TraefikC) is not running/healthy; start it with .\install.ps1 -Start" -ForegroundColor Red; exit 1 }

$version = Invoke-Curl "http://127.0.0.1:$dashPort/api/version"
Test-Condition 'traefik version' ($version.Text -match ('"Version":"' + [regex]::Escape($ExpectedVersion) + '"')) $version.Text

$publishedTraefik = (Invoke-Native docker port $TraefikC).Text
$loopbackOnly = -not ($publishedTraefik -split "`n" | Where-Object { $_ -and $_ -notmatch '-> 127\.0\.0\.1:' })
Test-Condition 'traefik ports loopback-only' $loopbackOnly ($publishedTraefik -replace "`n", '; ')

$entry = (Invoke-Curl "http://127.0.0.1:$dashPort/api/entrypoints/web").Text
Test-Condition 'static config from .env (trusted cloudflared IP)' ($entry -match [regex]::Escape($settings.CloudflaredIp + '/32')) $settings.CloudflaredIp
Test-Condition 'request hardening active (aliasHeadersStrategy)' ($entry -match '"aliasHeadersStrategy":"delete"') ''
$overview = (Invoke-Curl "http://127.0.0.1:$dashPort/api/overview").Text
Test-Condition 'docker and file providers enabled' ($overview -match '"providers":\[[^\]]*"Docker"' -and $overview -match '"providers":\[[^\]]*"File"') (([regex]::Match($overview, '"providers":\[[^\]]*\]')).Value)

# --- Socket proxy --------------------------------------------------------------------------------
$socketPorts = (Invoke-Native docker port $SocketC).Text.Trim()
Test-Condition 'socket-proxy not published' ($socketPorts -eq '') "docker port ${SocketC}: '$socketPorts'"
$allowed = Invoke-Native docker exec $TraefikC wget -q -O- http://socket-proxy:2375/version
Test-Condition 'socket-proxy allows /version' ($allowed.ExitCode -eq 0 -and $allowed.Text -match '"ApiVersion"') ''
$deniedImages = Invoke-Native docker exec $TraefikC wget -q -O- http://socket-proxy:2375/images/json
Test-Condition 'socket-proxy denies /images' ($deniedImages.Text -match '403') $deniedImages.Text
$deniedPost = Invoke-Native docker exec $TraefikC wget -q -O- --post-data '{}' http://socket-proxy:2375/containers/create
Test-Condition 'socket-proxy denies POST' ($deniedPost.Text -match '403') $deniedPost.Text

# --- Echo backend ----------------------------------------------------------------------------------
$up = Invoke-Native @($composeBase + @('--profile', 'test', 'up', '-d', 'whoami'))
Test-Condition 'whoami started' ($up.ExitCode -eq 0) $(if ($up.ExitCode -ne 0) { $up.Text } else { '' })

try {
  Set-TestRoute @($WhoamiHost)
  $deadline = (Get-Date).AddSeconds(30)
  do {
    Start-Sleep -Milliseconds 500
    $routers = (Invoke-Curl "http://127.0.0.1:$dashPort/api/http/routers").Text
  } while ($routers -notmatch 'svc-whoami-test-prefix@file' -and (Get-Date) -lt $deadline)
  Test-Condition 'file provider loaded generated route' ($routers -match 'svc-whoami-test@file' -and $routers -match 'svc-whoami-test-prefix@file') ''

  $dns = Invoke-Native docker exec $TraefikC wget -q -O- "http://$WhoamiC/"
  Test-Condition 'container-name DNS on proxy network' ($dns.Text -match 'Hostname:') "traefik -> http://$WhoamiC/"

  $routed = Invoke-Curl -H "Host: $WhoamiHost" "$base/"
  Test-Condition 'host routing (generated docker target)' ($routed.Text -match 'Hostname:' -and $routed.Text -match "Host: $WhoamiHost") "Host: $WhoamiHost"

  $prefixed = Invoke-Curl -H "Host: $WhoamiHost" "$base/prefixed/echo-path"
  Test-Condition 'path prefix + strip prefix' ($prefixed.Text -match 'GET /echo-path HTTP') ((($prefixed.Text -split "`n") | Where-Object { $_ -match '^GET ' }) -join '')

  $headers = Invoke-Curl -D - -o NUL -H "Host: $WhoamiHost" "$base/"
  Test-Condition 'default-headers middleware applied' ($headers.Text -match '(?im)^X-Content-Type-Options: nosniff' -and $headers.Text -match '(?im)^X-Frame-Options: DENY') ''

  $unknown = Invoke-Curl -o NUL -w '%{http_code}' -H 'Host: nothing.invalid' "$base/"
  Test-Condition 'unknown host -> 404' ($unknown.Text.Trim() -eq '404') $unknown.Text

  # On `web`, /api/version must fall through to the app (whoami echoes it), never to api@internal.
  $dashOnWeb = Invoke-Curl -H "Host: $WhoamiHost" "$base/api/version"
  Test-Condition 'dashboard API not on web entrypoint' ($dashOnWeb.Text -notmatch 'Codename') 'GET /api/version on :80'

  $spoof = Invoke-Curl -H "Host: $WhoamiHost" -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.9' "$base/"
  Test-Condition 'untrusted X-Forwarded-* overwritten' ($spoof.Text -match 'X-Forwarded-Proto: http\r?\n' -and $spoof.Text -notmatch '203\.0\.113\.9') 'loopback client sent X-Forwarded-Proto: https'

  $cfRunning = Test-ContainerRunning $CloudflaredC
  if ($cfRunning) {
    Add-Result 'SKIP' 'trusted X-Forwarded-* from cloudflared IP' "cloudflared holds $($settings.CloudflaredIp); covered by -PublicTestHost"
  } else {
    $trusted = Invoke-Native docker run --rm --network $settings.TunnelNetwork --ip $settings.CloudflaredIp --entrypoint wget $settings.TraefikImage -q -O- --header "Host: $WhoamiHost" --header 'X-Forwarded-Proto: https' http://traefik/
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
    $cfHealth = (Invoke-Native docker inspect $CloudflaredC --format '{{.State.Health.Status}}').Text.Trim()
    Test-Condition 'cloudflared healthy' ($cfHealth -eq 'healthy') $cfHealth
    $cfLogs = (Invoke-Native docker logs --tail 300 $CloudflaredC).Text
    Test-Condition 'tunnel connections registered' ($cfLogs -match 'Registered tunnel connection') ''
  } else {
    Add-Result 'SKIP' 'cloudflared' 'tunnel profile not running'
  }

  if ($PublicTestHost) {
    # Answer the public test host only for the duration of this check.
    Set-TestRoute @($WhoamiHost, $PublicTestHost.ToLowerInvariant())
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
    Set-TestRoute @($WhoamiHost)
  }

  # --- Registered services -----------------------------------------------------------------------
  $registry = Read-ServiceRegistry -Settings $settings
  $enabled = @($registry.services | Where-Object { $_.enabled })
  if ($enabled.Count -eq 0) {
    Add-Result 'SKIP' 'registered services' 'config\services.json has no enabled services'
  } else {
    $routerList = Get-TraefikApi $settings '/api/http/routers'
    foreach ($svc in $enabled) {
      $router = @($routerList | Where-Object { $_.name -eq "svc-$($svc.name)@file" })
      Test-Condition "service '$($svc.name)' router loaded" ($router.Count -eq 1 -and $router[0].status -eq 'enabled') $(if ($router.Count -eq 1) { $router[0].rule } else { 'missing' })
      $probePath = '/'
      if ($svc.pathPrefix) { $probePath = $svc.pathPrefix + '/' }
      $code = (Invoke-Curl -o NUL -w '%{http_code}' -H "Host: $($svc.hostnames[0])" "$base$probePath").Text.Trim()
      if ($code -match '^(502|503|504|000)$') { Add-Result 'WARN' "service '$($svc.name)' backend" "HTTP $code from $(Get-ServiceUrl $svc) - is the app running and reachable?" }
      else { Add-Result 'PASS' "service '$($svc.name)' backend" "HTTP $code" }
    }
  }
} finally {
  Remove-Item -LiteralPath $TestRouteFile -ErrorAction SilentlyContinue
  $null = Sync-TraefikDynamic $settings
  if (-not $KeepWhoami) {
    $null = Invoke-Native @($composeBase + @('--profile', 'test', 'rm', '-s', '-f', 'whoami'))
    $left = (Invoke-Native docker ps -a --filter "name=^$WhoamiC$" --format '{{.Names}}').Text.Trim()
    Test-Condition 'whoami removed after tests' ($left -eq '') ''
  }
  Test-Condition 'test route removed after tests' (-not (Test-Path -LiteralPath $TestRouteFile)) ''
}

# --- Logs --------------------------------------------------------------------------------------------
$traefikLogs = (Invoke-Native docker logs --since 30m $TraefikC).Text
$errLines = @($traefikLogs -split "`n" | Where-Object { $_ -match '\bERR\b' })
Test-Condition 'no Traefik ERR log lines (30 min)' ($errLines.Count -eq 0) (($errLines | Select-Object -First 3) -join ' | ')
$proxyLogs = (Invoke-Native docker logs --since 30m $SocketC).Text
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
