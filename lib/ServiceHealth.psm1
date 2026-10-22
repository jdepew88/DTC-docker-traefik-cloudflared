Set-StrictMode -Version 2.0

# Request-path health of one service: DNS -> Cloudflare Access -> tunnel -> Traefik router -> Traefik service ->
# backend network -> application HTTP response (and, on request, the public URL). Every check says whether it was
# actually performed; a check that could not run is "skipped" with the reason, never "ok". A Cloudflare Access login
# redirect proves Access, not the application. Read-only: GET requests and docker inspect.

function New-HealthCheck([string]$Id, [string]$Label, [string]$State, [string]$Message, [bool]$Performed = $true) {
  return [ordered]@{ id = $Id; label = $Label; state = $State; performed = $Performed; message = $Message }
}

# The order of the hops a public request takes; the first failed one is the failing segment.
$script:HopOrder = @('dns', 'access', 'tunnel', 'router', 'service', 'backend', 'http', 'public')
# Bodies of apps that refuse a Host header they do not know (Homepage, Vite, Django, webpack-dev-server, ...).
$script:HostRejection = 'Host validation failed|Invalid Host header|DisallowedHost|Invalid HTTP_HOST|host is not allowed|Blocked request\. This host|not in the list of allowed hosts|allowedHosts'

# Pure: an application's own answer -> (state, message). 401/403 is "auth": the app asks for a login, so the route
# and the backend work but signing in is not tested. 400/421 means the app refuses the request; for a proxied app
# that is nearly always its allowed-hosts list lacking the public hostname.
function ConvertFrom-AppStatus([int]$Status, [string]$Body, [string]$Hostname, [string]$Via = '') {
  if (($Status -in 400, 403, 421) -and $Body -match $script:HostRejection) {
    return @('failed', "The application rejected the hostname $Hostname (HTTP $Status$Via, '$(($Body -replace '\s+', ' ').Trim().Substring(0, [Math]::Min(80, ($Body -replace '\s+', ' ').Trim().Length)))'). Add $Hostname to the app's allowed hosts (Homepage: HOMEPAGE_ALLOWED_HOSTS) and recreate its container.")
  }
  if ($Status -in 401, 403) { return @('auth', "The application answered HTTP $Status$Via`: it asks for a login. The route and the backend work; signing in is not tested.") }
  if ($Status -in 400, 421) {
    if ($Body -match 'HTTP request to an HTTPS server') { return @('failed', "HTTP $Status$Via`: the backend speaks HTTPS. Set the target protocol to https.") }
    return @('failed', "The application answered HTTP $Status$Via for Host: $Hostname. The network path works, but the app refuses the request; most often its allowed-hosts setting lacks $Hostname (Homepage: HOMEPAGE_ALLOWED_HOSTS, Django: ALLOWED_HOSTS, Vite: server.allowedHosts).")
  }
  if ($Status -ge 400 -and $Status -lt 500 -and $Status -ne 404) { return @('warning', "The application answered HTTP $Status$Via.") }
  if ($Status -ge 500) { return @('warning', "The application answered HTTP $Status (an error inside the app).") }
  return @('ok', "The application answered HTTP $Status$Via.")
}

# Pure: an HTTP status seen through Traefik (Host header) -> check result. Traefik's own 404 is "404 page not found".
# $Location: a redirect's target; one to an internal address (a container name or a port) cannot be followed by a browser.
function ConvertFrom-RoutedStatus([int]$Status, [string]$Body, [string]$ErrorText, [string]$Hostname, [string]$Location = '') {
  if ($Status -eq 0 -and $ErrorText -match 'timed out|timeout') { return @('failed', 'No answer within 10 seconds through Traefik: Traefik accepted the request and is waiting for the backend, which is slow or not reachable from Docker (for LAN addresses: check that Docker Desktop can route to that network).') }
  if ($Status -eq 0) { return @('failed', "Traefik did not answer: $ErrorText") }
  if ($Status -eq 404 -and $Body -match '^404 page not found\s*$') { return @('failed', "No Traefik router matched $Hostname (Traefik's own 404).") }
  if ($Status -eq 502) { return @('failed', 'Bad Gateway: Traefik could not connect to the backend (wrong port, scheme or network, or the app is down).') }
  if ($Status -eq 504) { return @('failed', 'Gateway Timeout: the backend did not answer in time.') }
  if ($Status -eq 500 -and $Body -match 'Internal Server Error' -and $Body.Length -lt 40) { return @('warning', 'HTTP 500 from Traefik or the app (for HTTPS backends: certificate verification).') }
  if ($Status -ge 300 -and $Status -lt 400 -and $Location -match '^https?://([^/:]+)(:\d+)?' -and $Matches[1] -ne $Hostname -and ($Matches[2] -or $Matches[1] -notmatch '\.')) {
    return @('warning', "The application redirects to $Location, an internal address a browser cannot reach. Set the app's public URL (base URL) to https://$Hostname.")
  }
  return ConvertFrom-AppStatus $Status $Body $Hostname ' through Traefik'
}

# Pure: what a LAN target means from inside Docker Desktop. $LocalAddresses: this PC's IPv4 addresses.
# $DockerSubnets: @{ name; subnet } of the engine's networks. Containers reach this PC as host.docker.internal; an
# address inside a Docker network's subnet is delivered into that network and never reaches the LAN.
function Get-LanTargetIssues([string]$TargetHost, [string[]]$LocalAddresses = @(), $DockerSubnets = @()) {
  $issues = @()
  if ($TargetHost -match '^(127\.|localhost$|0\.0\.0\.0$)') {
    $issues += [ordered]@{ state = 'failed'; message = "$TargetHost inside a container is that container itself (Traefik), not Windows. For an app on this PC use host.docker.internal (target type 'host')." }
    return $issues
  }
  if (-not (Test-IPv4Address $TargetHost)) { return $issues }
  foreach ($n in @($DockerSubnets)) {
    if ($n.subnet -match '^\d+\.\d+\.\d+\.\d+/\d+$' -and (Test-CidrOverlap "$TargetHost/32" $n.subnet)) {
      $issues += [ordered]@{ state = 'failed'; message = "$TargetHost lies inside Docker network '$($n.name)' ($($n.subnet)): containers send this traffic into that network, never to the LAN. Move that network to another subnet (or remove it), or use host.docker.internal for an app on this PC." }
    }
  }
  if ($LocalAddresses -contains $TargetHost) {
    $issues += [ordered]@{ state = 'warning'; message = "$TargetHost is this PC's own address. From containers, reach apps on this PC as host.docker.internal (target type 'host'): it does not depend on Docker Desktop routing to the LAN." }
  }
  return $issues
}

# The IPv4 subnets of every Docker network (read-only).
function Get-DockerSubnets {
  $ids = @((Invoke-Docker network ls -q).Output | Where-Object { $_ -match '^[0-9a-f]+$' })
  if (-not $ids.Count) { return @() }
  $r = Invoke-Docker network inspect @ids --format '{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}'
  return @($r.Output | ForEach-Object { $p = ([string]$_).Split('|'); if ($p.Count -eq 2) { foreach ($sn in $p[1].Trim().Split(' ')) { if ($sn -match '^\d+\.\d+\.\d+\.\d+/\d+$') { [ordered]@{ name = $p[0]; subnet = $sn } } } } })
}

function Get-LocalIPv4Addresses {
  try { return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object { $_.IPAddress }) } catch { return @() }
}

# Requests the backend the way Traefik does: a short-lived container in Traefik's network namespace (same networks,
# same name resolution, same host.docker.internal) running Traefik's own image (never pulled), one GET with the public
# Host header. When the configured scheme fails in a way that suggests the other one, the other scheme is tried too.
# Certificates are not verified by this probe (busybox wget); it tests reachability and protocol only.
function Test-BackendFromTraefik {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Service, [int]$TimeoutSeconds = 5)
  $t = $Service.target
  $hostname = [string]@($Service.hostnames)[0]
  $path = $(if ($Service.pathPrefix -and -not $Service.stripPrefix) { "$($Service.pathPrefix)/" } else { '/' })
  if (-not (Test-ContainerRunning $Settings.TraefikContainer)) { return [ordered]@{ performed = $false; tries = @(); detail = "Traefik ($($Settings.TraefikContainer)) is not running, so the backend cannot be requested from its network." } }
  $try = {
    param([string]$Scheme)
    $url = "${Scheme}://$($t.host):$($t.port)$path"
    $a = @('run', '--rm', '--pull', 'never', '--network', "container:$($Settings.TraefikContainer)", '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
      '--memory', '32m', '--label', 'org.traefik-proxy.probe=1', '--entrypoint', 'wget', $Settings.TraefikImage, '-S', '-q', '-O', '/dev/null', '-T', "$TimeoutSeconds")
    if ($hostname) { $a += @('--header', "Host: $hostname") }
    if ($Scheme -eq 'https') { $a += '--no-check-certificate' }
    $r = Invoke-Docker @($a + $url)
    $text = (@($r.Output) -join "`n")
    $p = ConvertFrom-ProbeOutput $r.Output $r.ExitCode
    if ($text -match 'SSL_connect|ssl_client|wrong version number') { $p = [ordered]@{ result = 'not-http'; status = 0; detail = 'TLS handshake failed.' } }
    if ($text -match 'Unable to find image|No such image') { $p = [ordered]@{ result = 'error'; status = 0; detail = "The probe image $($Settings.TraefikImage) is not present locally." } }
    return [ordered]@{ scheme = $Scheme; url = $url; result = $p.result; status = $p.status; detail = $p.detail }
  }
  $first = & $try $t.protocol
  $tries = @($first)
  $other = $(if ($t.protocol -eq 'https') { 'http' } else { 'https' })
  if ($first.result -eq 'not-http' -or ($t.protocol -eq 'http' -and $first.result -eq 'http' -and $first.status -eq 400)) { $tries += & $try $other }
  return [ordered]@{ performed = $true; tries = $tries; timeout = $TimeoutSeconds; hostname = $hostname }
}

# Pure: Test-BackendFromTraefik's result -> (state, message) for the "Traefik -> backend" hop.
function ConvertFrom-BackendProbe($Probe, $Service, [string]$ProxyNetwork = 'the shared network') {
  if (-not $Probe.performed) { return @('skipped', $Probe.detail) }
  $t = $Service.target
  $first = $Probe.tries[0]
  $alt = $(if (@($Probe.tries).Count -gt 1) { $Probe.tries[1] } else { $null })
  $where = "$($t.host):$($t.port)"
  if ($alt -and $alt.result -eq 'http' -and $alt.status -ne 400) {
    return @('failed', "The backend at $where speaks $($alt.scheme.ToUpper()), not $($first.scheme.ToUpper()): it answered HTTP $($alt.status) over $($alt.scheme). Set the target protocol to $($alt.scheme)$(if ($alt.scheme -eq 'https') { ' (with skip certificate verification for a self-signed certificate)' }).")
  }
  switch ($first.result) {
    'http' { $v = ConvertFrom-AppStatus $first.status '' $Probe.hostname " from Traefik's network ($($first.url))"; return $v }
    'https' { $v = ConvertFrom-AppStatus $first.status '' $Probe.hostname " from Traefik's network ($($first.url))"; return $v }
    'closed' { return @('failed', "Connection refused at $where from Traefik's network: nothing listens on that port. Check the port (the one the app listens on inside its container, not a published Windows port) and that the app does not listen only on 127.0.0.1.") }
    'timeout' { return @('failed', "No answer from $where within $($Probe.timeout) seconds from Traefik's network. For a LAN address: Docker Desktop cannot route there (a Docker network on the same subnet captures it, or the device is off). For host.docker.internal: Windows Firewall blocks the port, or the app listens only on 127.0.0.1.") }
    'not-http' { return @('failed', "Something listens at $where, but it does not answer $($first.scheme.ToUpper()) ($($first.detail)).") }
    default { if ($first.detail -match 'resolve') { return @('failed', "$($t.host) does not resolve from Traefik's network: the container is not attached to '$ProxyNetwork' or the name is wrong.") } return @('failed', "The backend request failed: $($first.detail)") }
  }
}

# Pure: the tunnel's ingress rules for one hostname -> (state, message). cloudflared runs in its own container, so
# localhost or 127.0.0.1 there is cloudflared itself; the origin must be Traefik's web entry point, plain HTTP.
function ConvertFrom-TunnelRoute($Rules, [string]$Hostname, [int]$Connections, [string]$TunnelName, [string]$TunnelStatus = '') {
  $r = @($Rules | Where-Object { $_ -and $_.PSObject.Properties['hostname'] -and $_.hostname -eq $Hostname })
  if (-not $r.Count) { return @('failed', "Tunnel '$TunnelName' has no route for $Hostname (the catch-all answers 404).") }
  $svc = [string]$r[0].service
  if ($svc -match '^https?://(localhost|127\.[\d.]+)(:|/|$)') { return @('failed', "The tunnel sends $Hostname to $svc. Inside the cloudflared container that is cloudflared itself, not Windows or Traefik; use http://traefik:80.") }
  if ($svc -match '^https://traefik(:|/|$)') { return @('failed', "The tunnel sends $Hostname to $svc. Traefik's web entry point is plain HTTP inside Docker (Cloudflare terminates HTTPS); use http://traefik:80.") }
  if ($svc -ne 'http://traefik:80') { return @('failed', "The tunnel sends $Hostname to $svc, not to traefik:80, so this Traefik never sees the request.") }
  if ($r[0].PSObject.Properties['path'] -and $r[0].path) { return @('warning', "The tunnel route for $Hostname only matches the path $($r[0].path).") }
  if ($Connections -eq 0) { return @('failed', "The route exists, but no connector is connected (status $TunnelStatus).") }
  return @('ok', "Tunnel '$TunnelName' sends $Hostname to traefik:80; $Connections connection(s).")
}

# Pure: the first failed hop in request order, or $null.
function Get-FirstFailure($Checks) {
  foreach ($id in $script:HopOrder) {
    $c = @($Checks | Where-Object { $_.id -eq $id -and $_.state -eq 'failed' })
    if ($c.Count) { return [ordered]@{ id = $c[0].id; label = $c[0].label; message = $c[0].message } }
  }
  return $null
}

# Pure: the public URL's answer -> (Access state, app state). A redirect to *.cloudflareaccess.com proves Access only.
function ConvertFrom-PublicProbe([int]$Status, [string]$Location, [string]$ErrorText, [string]$Exposure) {
  if ($Status -ge 300 -and $Status -lt 400 -and $Location -match '^https://[^/]+\.cloudflareaccess\.com/') {
    return [ordered]@{ access = 'ok'; app = 'auth'; message = 'Cloudflare Access shows its login page (authentication required). The application behind it was not reached by this check (that needs a signed-in browser or an Access service token).' }
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
      $tr = ConvertFrom-TunnelRoute $rules $hostname $conns $cf.tunnelName ([string]$t.status)
      & $add (New-HealthCheck 'tunnel' 'Tunnel route' $tr[0] $tr[1])
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
      else { & $add (New-HealthCheck 'service' 'Traefik service' 'ok' "Loaded, forwarding to $(Get-ServiceUrl $Service). (Traefik shows a server as UP unless a health check is configured; the backend check below makes a real request.)") }
    }
  }

  # Traefik -> backend: membership of the shared network (containers), what a LAN address means inside Docker, then one
  # real request from Traefik's own network namespace.
  $backendIssue = $null; $backendNote = ''
  if ($Service.target.type -eq 'docker') {
    $i = Invoke-Docker inspect $Service.target.host --format '{{.State.Status}}|{{json .NetworkSettings.Networks}}'
    if ($i.ExitCode -ne 0) { $backendIssue = @('failed', "No container named $($Service.target.host).") }
    else {
      $line = (@($i.Output) -join '').Trim(); $sep = $line.IndexOf('|')
      $st = $line.Substring(0, $sep); $nets = $line.Substring($sep + 1) | ConvertFrom-Json
      if ($st -ne 'running') { $backendIssue = @('failed', "$($Service.target.host) is $st.") }
      elseif (-not $nets.PSObject.Properties[$Settings.ProxyNetwork]) { $backendIssue = @('failed', "$($Service.target.host) is running but not attached to '$($Settings.ProxyNetwork)'.") }
    }
  } elseif ($Service.target.type -eq 'lan') {
    $li = @(Get-LanTargetIssues $Service.target.host (Get-LocalIPv4Addresses) (Get-DockerSubnets))
    $bad = @($li | Where-Object { $_.state -eq 'failed' })
    if ($bad.Count) { $backendIssue = @('failed', (@($li | ForEach-Object { $_.message }) -join ' ')) }
    elseif ($li.Count) { $backendNote = (@($li | ForEach-Object { $_.message }) -join ' ') }
  }
  if ($backendIssue) { & $add (New-HealthCheck 'backend' 'Traefik to backend' $backendIssue[0] $backendIssue[1]) }
  elseif (-not $Service.enabled) { & $add (New-HealthCheck 'backend' 'Traefik to backend' 'skipped' 'The service is disabled.' $false) }
  else {
    $bp = ConvertFrom-BackendProbe (Test-BackendFromTraefik -Settings $Settings -Service $Service) $Service $Settings.ProxyNetwork
    $msg = $bp[1]
    if ($Service.target.type -eq 'docker' -and $bp[0] -ne 'skipped') { $msg = "$($Service.target.host) is running on '$($Settings.ProxyNetwork)'. $msg" }
    if ($backendNote) { $msg += " Note: $backendNote" }
    & $add (New-HealthCheck 'backend' 'Traefik to backend' $bp[0] $msg ($bp[0] -ne 'skipped'))
  }

  # Application through Traefik (bypasses Cloudflare; proves router -> service -> backend).
  if (-not $Service.enabled) { & $add (New-HealthCheck 'http' 'Application HTTP response' 'skipped' 'The service is disabled.' $false) }
  else {
    $path = $(if ($pathPrefix) { "$pathPrefix/" } else { '/' })
    $p = Invoke-ProbeRequest "http://127.0.0.1:$($Settings.HttpPort)$path" @{} $hostname
    $res = ConvertFrom-RoutedStatus $p.Status $p.Body $p.Error $hostname $p.Location
    & $add (New-HealthCheck 'http' 'Application HTTP response' $res[0] "$($res[1]) (GET http://$hostname$path via 127.0.0.1:$($Settings.HttpPort))")
  }

  if ($Public -and $exposure -ne 'local') {
    $p = Invoke-ProbeRequest "https://$hostname$(if ($pathPrefix) { "$pathPrefix/" } else { '/' })"
    $pub = ConvertFrom-PublicProbe $p.Status $p.Location $p.Error $exposure
    & $add (New-HealthCheck 'public' 'Public URL' $pub.app $pub.message)
    if ($pub.access -eq 'failed') { foreach ($c in $checks) { if ($c.id -eq 'access') { $c.state = 'failed'; $c.message += ' The public URL answered without a login.' } } }
  } elseif ($exposure -ne 'local') {
    & $add (New-HealthCheck 'public' 'Public URL' 'skipped' 'Not requested (Check the public URL sends one GET to the hostname from this PC).' $false)
  }
  return [ordered]@{ service = $Service.name; hostname = $hostname; exposure = $exposure; checkedAt = (Get-Date -Format 's'); checks = $checks.ToArray()
    performed = @($checks | Where-Object { $_.performed }).Count; total = $checks.Count; firstFailure = (Get-FirstFailure $checks.ToArray()) }
}

Export-ModuleMember -Function Get-ServiceHealth, ConvertFrom-RoutedStatus, ConvertFrom-PublicProbe, New-HealthCheck, ConvertFrom-AppStatus, Get-LanTargetIssues,
  Get-DockerSubnets, Get-LocalIPv4Addresses, Test-BackendFromTraefik, ConvertFrom-BackendProbe, ConvertFrom-TunnelRoute, Get-FirstFailure
