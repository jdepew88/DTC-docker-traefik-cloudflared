Set-StrictMode -Version 2.0

# Request-path health of one service: DNS -> Cloudflare Access -> tunnel -> Traefik router -> Traefik service ->
# backend network -> application HTTP response (and, on request, the public URL). Every check says whether it was
# actually performed; a check that could not run is "skipped" with the reason, never "ok". A Cloudflare Access login
# redirect proves Access, not the application. Read-only: GET requests and docker inspect.

function New-HealthCheck([string]$Id, [string]$Label, [string]$State, [string]$Message, [bool]$Performed = $true) {
  return [ordered]@{ id = $Id; label = $Label; state = $State; performed = $Performed; message = $Message }
}

# Pure: an HTTP status seen through Traefik (Host header) -> check result. Traefik's own 404 is "404 page not found".
function ConvertFrom-RoutedStatus([int]$Status, [string]$Body, [string]$ErrorText, [string]$Hostname) {
  if ($Status -eq 0 -and $ErrorText -match 'timed out|timeout') { return @('failed', 'No answer within 10 seconds through Traefik: Traefik accepted the request and is waiting for the backend, which is slow or not reachable from Docker (for LAN addresses: check that Docker Desktop can route to that network).') }
  if ($Status -eq 0) { return @('failed', "Traefik did not answer: $ErrorText") }
  if ($Status -eq 404 -and $Body -match '^404 page not found\s*$') { return @('failed', "No Traefik router matched $Hostname (Traefik's own 404).") }
  if ($Status -eq 502) { return @('failed', 'Bad Gateway: Traefik could not connect to the backend (wrong port, scheme or network, or the app is down).') }
  if ($Status -eq 504) { return @('failed', 'Gateway Timeout: the backend did not answer in time.') }
  if ($Status -eq 500 -and $Body -match 'Internal Server Error' -and $Body.Length -lt 40) { return @('warning', 'HTTP 500 from Traefik or the app (for HTTPS backends: certificate verification).') }
  if ($Status -ge 500) { return @('warning', "The application answered HTTP $Status (an error inside the app).") }
  return @('ok', "The application answered HTTP $Status through Traefik.")
}

# Pure: the public URL's answer -> (Access state, app state). A redirect to *.cloudflareaccess.com proves Access only.
function ConvertFrom-PublicProbe([int]$Status, [string]$Location, [string]$ErrorText, [string]$Exposure) {
  if ($Status -ge 300 -and $Status -lt 400 -and $Location -match '^https://[^/]+\.cloudflareaccess\.com/') {
    return [ordered]@{ access = 'ok'; app = 'skipped'; message = 'Cloudflare Access shows its login page. The application behind it was not reached by this check (that needs a signed-in browser).' }
  }
  if ($Status -eq 0) { return [ordered]@{ access = 'skipped'; app = 'warning'; message = "The public URL did not answer ($ErrorText). New DNS records can take a few minutes." } }
  if ($Status -in 530, 1033) { return [ordered]@{ access = 'skipped'; app = 'failed'; message = "HTTP $Status from Cloudflare: the tunnel has no connected connector or no route." } }
  if ($Status -in 502, 504) { return [ordered]@{ access = 'skipped'; app = 'failed'; message = "HTTP $Status at Cloudflare: cloudflared could not reach Traefik, or Traefik could not reach the app." } }
  if ($Exposure -eq 'access') { return [ordered]@{ access = 'failed'; app = 'warning'; message = "The public URL answered HTTP $Status WITHOUT a Cloudflare login. Check the Access application now." } }
  if ($Status -ge 500) { return [ordered]@{ access = 'skipped'; app = 'warning'; message = "The public URL answered HTTP $Status." } }
  return [ordered]@{ access = 'skipped'; app = 'ok'; message = "The public URL answered HTTP $Status." }
}

function Get-ServiceHealth {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Service, [switch]$Public)
  $checks = New-Object System.Collections.ArrayList
  $add = { param($c) $null = $checks.Add($c) }
  $hostname = [string]@($Service.hostnames)[0]
  $exposure = $(if (-not $Service.cloudflare.publish) { 'local' } elseif ($Service.cloudflare.access) { 'access' } else { 'public' })
  $cf = Read-CloudflareConfig -Settings $Settings
  $token = Get-CloudflareApiTokenInfo -Settings $Settings
  $cfReady = $token.Stored -and $token.Readable -and $cf.accountId -and $cf.tunnelId
  $routerName = "svc-$($Service.name)@file"
  $pathPrefix = [string]$Service.pathPrefix

  # Cloudflare side.
  if ($exposure -eq 'local') {
    foreach ($x in @(@('dns', 'DNS record'), @('access', 'Cloudflare Access'), @('tunnel', 'Tunnel route'))) { & $add (New-HealthCheck $x[0] $x[1] 'skipped' 'Local only: not published through Cloudflare.' $false) }
  } elseif (-not $cfReady) {
    foreach ($x in @(@('dns', 'DNS record'), @('access', 'Cloudflare Access'), @('tunnel', 'Tunnel route'))) { & $add (New-HealthCheck $x[0] $x[1] 'skipped' 'Not checked: Cloudflare automation is not connected (no readable API token or no tunnel recorded).' $false) }
  } else {
    $zone = @($cf.domains | Where-Object { $hostname -eq $_.name -or $hostname.EndsWith(".$($_.name)") } | Sort-Object { $_.name.Length } -Descending | Select-Object -First 1)
    if (-not $zone.Count) { & $add (New-HealthCheck 'dns' 'DNS record' 'failed' "$hostname is not under an allowed domain.") }
    else {
      try {
        $records = @(Invoke-CloudflareApi -Settings $Settings -Path "/zones/$($zone[0].id)/dns_records" -Query @{ name = $hostname } -All)
        $target = "$($cf.tunnelId).cfargotunnel.com"
        $ours = @($records | Where-Object { $_.type -eq 'CNAME' -and $_.content -eq $target })
        if ($ours.Count -and $ours[0].proxied) { & $add (New-HealthCheck 'dns' 'DNS record' 'ok' "$hostname is a proxied CNAME to this tunnel.") }
        elseif ($ours.Count) { & $add (New-HealthCheck 'dns' 'DNS record' 'warning' "$hostname points at the tunnel but is not proxied.") }
        elseif ($records.Count) { & $add (New-HealthCheck 'dns' 'DNS record' 'failed' "$hostname exists as $($records[0].type) $($records[0].content), not as a CNAME to this tunnel.") }
        else { & $add (New-HealthCheck 'dns' 'DNS record' 'failed' "$hostname has no DNS record.") }
      } catch { & $add (New-HealthCheck 'dns' 'DNS record' 'warning' "Not checked: $($_.Exception.Message)" $false) }
    }
    if ($exposure -eq 'access') {
      $a = Test-DashboardAccess $Settings $cf.accountId $hostname
      & $add (New-HealthCheck 'access' 'Cloudflare Access' $(if ($a.Ok) { 'ok' } else { 'failed' }) $a.Message)
    } else { & $add (New-HealthCheck 'access' 'Cloudflare Access' 'skipped' 'This service is public: it relies on its own login.' $false) }
    try {
      $tc = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($cf.accountId)/cfd_tunnel/$($cf.tunnelId)/configurations"
      $rules = @()
      if ($tc -and $tc.PSObject.Properties['config'] -and $tc.config -and $tc.config.PSObject.Properties['ingress']) { $rules = @($tc.config.ingress | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq $hostname }) }
      $t = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($cf.accountId)/cfd_tunnel/$($cf.tunnelId)"
      $conns = @($(if ($t.PSObject.Properties['connections']) { $t.connections } else { @() })).Count
      if (-not $rules.Count) { & $add (New-HealthCheck 'tunnel' 'Tunnel route' 'failed' "Tunnel '$($cf.tunnelName)' has no route for $hostname.") }
      elseif ($rules[0].service -ne 'http://traefik:80') { & $add (New-HealthCheck 'tunnel' 'Tunnel route' 'failed' "The tunnel sends $hostname to $($rules[0].service), not to traefik:80.") }
      elseif ($conns -eq 0) { & $add (New-HealthCheck 'tunnel' 'Tunnel route' 'failed' "The route exists, but no connector is connected (status $($t.status)).") }
      else { & $add (New-HealthCheck 'tunnel' 'Tunnel route' 'ok' "Tunnel '$($cf.tunnelName)' sends $hostname to traefik:80; $conns connection(s).") }
    } catch { & $add (New-HealthCheck 'tunnel' 'Tunnel route' 'warning' "Not checked: $($_.Exception.Message)" $false) }
  }

  # Traefik.
  $routers = Get-TraefikApi $Settings '/api/http/routers'
  if ($null -eq $routers) {
    & $add (New-HealthCheck 'router' 'Traefik router' 'failed' 'Traefik''s API does not answer, so routers cannot be read.')
    & $add (New-HealthCheck 'service' 'Traefik service' 'skipped' 'Not checked: Traefik''s API does not answer.' $false)
  } else {
    $r = @($routers | Where-Object { $_.name -eq $routerName })
    if (-not $Service.enabled) { & $add (New-HealthCheck 'router' 'Traefik router' 'skipped' 'The service is disabled: no router is generated.' $false) }
    elseif (-not $r.Count) { & $add (New-HealthCheck 'router' 'Traefik router' 'failed' "Traefik has not loaded $routerName.") }
    elseif ($r[0].status -ne 'enabled') { & $add (New-HealthCheck 'router' 'Traefik router' 'failed' "Traefik reports $routerName as $($r[0].status).") }
    else { & $add (New-HealthCheck 'router' 'Traefik router' 'ok' "$routerName is loaded and enabled ($($r[0].rule)).") }
    $svcs = Get-TraefikApi $Settings '/api/http/services'
    $s = @($svcs | Where-Object { $_.name -eq $routerName })
    if (-not $Service.enabled) { & $add (New-HealthCheck 'service' 'Traefik service' 'skipped' 'The service is disabled.' $false) }
    elseif (-not $s.Count) { & $add (New-HealthCheck 'service' 'Traefik service' 'failed' "Traefik has not loaded the service $routerName.") }
    else {
      $down = @(); if ($s[0].PSObject.Properties['serverStatus'] -and $s[0].serverStatus) { $down = @($s[0].serverStatus.PSObject.Properties | Where-Object { $_.Value -ne 'UP' } | ForEach-Object { $_.Name }) }
      if ($down.Count) { & $add (New-HealthCheck 'service' 'Traefik service' 'failed' "Health check reports DOWN: $($down -join ', ').") }
      else { & $add (New-HealthCheck 'service' 'Traefik service' 'ok' "Loaded, forwarding to $(Get-ServiceUrl $Service).") }
    }
  }

  # Backend network.
  if ($Service.target.type -eq 'docker') {
    $i = Invoke-Docker inspect $Service.target.host --format '{{.State.Status}}|{{json .NetworkSettings.Networks}}'
    if ($i.ExitCode -ne 0) { & $add (New-HealthCheck 'backend' 'Backend on the network' 'failed' "No container named $($Service.target.host).") }
    else {
      $line = (@($i.Output) -join '').Trim(); $sep = $line.IndexOf('|')
      $st = $line.Substring(0, $sep); $nets = $line.Substring($sep + 1) | ConvertFrom-Json
      if ($st -ne 'running') { & $add (New-HealthCheck 'backend' 'Backend on the network' 'failed' "$($Service.target.host) is $st.") }
      elseif (-not $nets.PSObject.Properties[$Settings.ProxyNetwork]) { & $add (New-HealthCheck 'backend' 'Backend on the network' 'failed' "$($Service.target.host) is running but not attached to '$($Settings.ProxyNetwork)'.") }
      else { & $add (New-HealthCheck 'backend' 'Backend on the network' 'ok' "$($Service.target.host) is running on '$($Settings.ProxyNetwork)'.") }
    }
  } else {
    & $add (New-HealthCheck 'backend' 'Backend on the network' 'skipped' "$($Service.target.host) is outside Docker; the HTTP request below tests it." $false)
  }

  # Application through Traefik (bypasses Cloudflare; proves router -> service -> backend).
  if (-not $Service.enabled) { & $add (New-HealthCheck 'http' 'Application HTTP response' 'skipped' 'The service is disabled.' $false) }
  else {
    $path = $(if ($pathPrefix) { "$pathPrefix/" } else { '/' })
    $p = Invoke-ProbeRequest "http://127.0.0.1:$($Settings.HttpPort)$path" @{} $hostname
    $res = ConvertFrom-RoutedStatus $p.Status $p.Body $p.Error $hostname
    & $add (New-HealthCheck 'http' 'Application HTTP response' $res[0] "$($res[1]) (GET http://$hostname$path via 127.0.0.1:$($Settings.HttpPort))")
  }

  if ($Public -and $exposure -ne 'local') {
    $p = Invoke-ProbeRequest "https://$hostname$(if ($pathPrefix) { "$pathPrefix/" } else { '/' })"
    $pub = ConvertFrom-PublicProbe $p.Status $p.Location $p.Error $exposure
    & $add (New-HealthCheck 'public' 'Public URL' $(if ($pub.access -eq 'ok') { 'ok' } else { $pub.app }) $pub.message)
    if ($pub.access -eq 'failed') { foreach ($c in $checks) { if ($c.id -eq 'access') { $c.state = 'failed'; $c.message += ' The public URL answered without a login.' } } }
  } elseif ($exposure -ne 'local') {
    & $add (New-HealthCheck 'public' 'Public URL' 'skipped' 'Not requested (Check the public URL sends one GET to the hostname from this PC).' $false)
  }
  return [ordered]@{ service = $Service.name; hostname = $hostname; exposure = $exposure; checkedAt = (Get-Date -Format 's'); checks = $checks.ToArray()
    performed = @($checks | Where-Object { $_.performed }).Count; total = $checks.Count }
}

Export-ModuleMember -Function Get-ServiceHealth, ConvertFrom-RoutedStatus, ConvertFrom-PublicProbe, New-HealthCheck
