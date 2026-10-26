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
  if ($Status -ge 300 -and $Status -lt 400 -and $Location -match '(?i)(^|/)(login|signin|sign-in|sign_in|auth|sso|oauth2?|session/new)([/?#]|$)') {
    return @('auth', "The application answered HTTP $Status through Traefik and redirects to its login page ($Location): the route works; signing in is not tested.")
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
      $issues += [ordered]@{ state = 'failed'; cause = 'subnet-overlap'; message = "Your Docker network overlaps the destination subnet. Traffic to $TargetHost may be routed into Docker instead of reaching $(if ($LocalAddresses -contains $TargetHost) { 'your Windows computer' } else { 'that device' }): it lies inside Docker network '$($n.name)' ($($n.subnet)). Move that network to another subnet (or remove it once nothing uses it), or use host.docker.internal for an app on this PC." }
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

# A field of a probe try (an ordered dictionary or an object) that older or hand-made tries may lack.
function Get-TryField($Try, [string]$Name, $Default = $null) {
  if ($null -eq $Try) { return $Default }
  if ($Try -is [System.Collections.IDictionary]) { if ($Try.Contains($Name) -and $null -ne $Try[$Name]) { return $Try[$Name] } return $Default }
  $p = $Try.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# Pure: the probe lines worth showing as evidence: status lines, redirect targets, server, content type and the
# wget / TLS error lines. Cookies and every other header are dropped; query values that look like secrets are masked.
function Get-ProbeEvidence([string[]]$Lines) {
  return @(@($Lines) | ForEach-Object { ([string]$_).Trim() } |
      Where-Object { $_ -match '^(HTTP/\d|Location:|Server:|Content-Type:|WWW-Authenticate:|wget:|ssl_client:|Connecting to )' -or $_ -match 'certificate verify failed' } |
      ForEach-Object {
        if ($_ -match 'certificate verify failed') { 'TLS: certificate verify failed' }
        elseif ($_ -match '^WWW-Authenticate:\s*(\S+)') { "WWW-Authenticate: $($Matches[1])" }
        else { $_ -replace '(?i)([?&](token|key|code|state|sig|signature|password|secret)=)[^&\s]*', '$1<redacted>' }
      } | Select-Object -First 12)
}

# Requests the backend the way Traefik does: a short-lived container in Traefik's network namespace (same networks,
# same name resolution, same host.docker.internal) running Traefik's own image (never pulled), one GET with the public
# Host header. HTTPS is requested with certificate verification first; when that fails the request is repeated without
# it, so a self-signed certificate is told apart from a dead port. When the configured scheme fails in a way that
# suggests the other one, the other scheme is tried too. Redirects are followed; the first answer and the last are kept.
# -CompareHostHeader: when the backend answered HTTP, it is requested once more with its own address as the Host
# header (what a browser opening it directly sends), so an app that rejects the public hostname is told apart from one
# that rejects every request (hostCheck).
function Test-BackendFromTraefik {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Service, [int]$TimeoutSeconds = 5, [switch]$CompareHostHeader)
  $t = $Service.target
  $hostname = [string]@($Service.hostnames)[0]
  $path = $(if ($Service.pathPrefix -and -not $Service.stripPrefix) { "$($Service.pathPrefix)/" } else { '/' })
  if (-not (Test-ContainerRunning $Settings.TraefikContainer)) { return [ordered]@{ performed = $false; tries = @(); detail = "Traefik ($($Settings.TraefikContainer)) is not running, so the backend cannot be requested from its network." } }
  $try = {
    param([string]$Scheme, [bool]$Verify, [bool]$PublicHost = $true)
    $url = "${Scheme}://$($t.host):$($t.port)$path"
    $a = @('run', '--rm', '--pull', 'never', '--network', "container:$($Settings.TraefikContainer)", '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
      '--memory', '32m', '--label', 'org.traefik-proxy.probe=1', '--entrypoint', 'wget', $Settings.TraefikImage, '-S', '-O', '/dev/null', '-T', "$TimeoutSeconds")
    if ($hostname -and $PublicHost) { $a += @('--header', "Host: $hostname") }
    if ($Scheme -eq 'https' -and -not $Verify) { $a += '--no-check-certificate' }
    $r = Invoke-Docker @($a + $url)
    $lines = @($r.Output | ForEach-Object { [string]$_ })
    $text = $lines -join "`n"
    $p = ConvertFrom-ProbeOutput $lines $r.ExitCode
    $tlsFailed = $text -match 'certificate verify failed'
    if ($tlsFailed) { $p = [ordered]@{ result = 'tls'; status = 0; detail = 'The certificate could not be verified.' } }
    elseif ($p.result -ne 'http' -and $text -match 'SSL_connect|ssl_client|wrong version number') { $p = [ordered]@{ result = 'not-http'; status = 0; detail = 'TLS handshake failed.' } }
    if ($text -match 'Unable to find image|No such image') { $p = [ordered]@{ result = 'error'; status = 0; detail = "The probe image $($Settings.TraefikImage) is not present locally." } }
    $codes = @([regex]::Matches($text, 'HTTP/\d(?:\.\d)?\s+(\d{3})') | ForEach-Object { [int]$_.Groups[1].Value })
    $loc = [regex]::Match($text, '(?im)^\s*Location:\s*(\S+)')
    # busybox wget (without -q) prints "Connecting to name:port (address:port)" once the name resolved.
    $conn = [regex]::Match($text, 'Connecting to \S+ \(([^)]+)\)')
    return [ordered]@{ scheme = $Scheme; url = $url; result = $p.result; status = $p.status; detail = $p.detail
      finalStatus = $(if ($codes.Count) { $codes[-1] } else { 0 }); location = $(if ($loc.Success) { $loc.Groups[1].Value } else { '' })
      resolved = $(if ($conn.Success) { $conn.Groups[1].Value } else { '' }); hostHeader = $(if ($hostname -and $PublicHost) { $hostname } else { "$($t.host):$($t.port)" })
      verified = ($Scheme -eq 'https' -and $Verify -and -not $tlsFailed -and $p.result -eq 'http'); evidence = @(Get-ProbeEvidence $lines) }
  }
  $first = & $try $t.protocol ($t.protocol -eq 'https')
  $tries = @($first)
  $other = $(if ($t.protocol -eq 'https') { 'http' } else { 'https' })
  if ($first.result -eq 'tls') { $tries += & $try 'https' $false }
  elseif ($first.result -eq 'not-http' -or ($t.protocol -eq 'http' -and $first.result -eq 'http' -and $first.status -eq 400)) { $tries += & $try $other $false }
  $hostCheck = $null
  if ($CompareHostHeader -and $hostname -and @($tries | Where-Object { $_.result -eq 'http' }).Count) {
    $hostCheck = & $try $t.protocol (-not ($t.protocol -eq 'https' -and $first.result -eq 'tls')) $false
  }
  return [ordered]@{ performed = $true; tries = $tries; timeout = $TimeoutSeconds; hostname = $hostname; hostCheck = $hostCheck }
}

# What each verification result is called. Only "verified" and "redirect" (to a page that answers) are a pass;
# "auth" means reachable with a login in front; everything else is a failure or a warning, never green.
$script:BackendResultLabels = [ordered]@{
  verified = 'Verified reachable'; auth = 'Reachable, authentication required'; redirect = 'Application redirect'; 'wrong-protocol' = 'Wrong protocol'
  'wrong-port' = 'Wrong port'; dns = 'DNS resolution failure'; refused = 'Connection refused'; timeout = 'Timeout'; 'host-rejected' = 'Hostname rejected'
  tls = 'TLS verification failure'; unavailable = 'Application error'; 'http-error' = 'Unexpected HTTP answer'; error = 'Test failed'; 'not-tested' = 'Not tested'
}

# Pure: one HTTP answer of the backend -> (result, state, message). $Answer: a probe try (status, location, finalStatus).
function Get-BackendAnswerVerdict($Answer, [string]$Hostname, [string]$From) {
  $s = [int]$Answer.status
  $loc = [string](Get-TryField $Answer 'location' '')
  $final = [int](Get-TryField $Answer 'finalStatus' 0)
  if ($s -ge 300 -and $s -lt 400) {
    $locPath = $(if ($loc -match '^https?://[^/]+(/.*)?$') { [string]$Matches[1] } else { $loc })
    if ($locPath -match '(?i)(^|/)(login|signin|sign-in|sign_in|auth|sso|oauth2?|session/new)([/?#]|$)') {
      return @('auth', 'auth', "The application answered HTTP $s$From and redirects to its login page ($loc): reachable, signing in is not tested.")
    }
    if ($loc -match '^https?://([^/:]+)(:\d+)?' -and $Matches[1] -ne $Hostname -and ($Matches[2] -or $Matches[1] -notmatch '\.')) {
      return @('redirect', 'warning', "The application redirects to $loc$From, an internal address a browser cannot reach. Set the app's public URL (base URL) to https://$Hostname.")
    }
    if ($final -ge 400) { return @('redirect', 'warning', "The application redirects to $loc$From, and that page answered HTTP $final.") }
    return @('redirect', 'ok', "The application answered HTTP $s$From, redirecting to $(if ($loc) { $loc } else { 'another page' })$(if ($final -ge 200 -and $final -lt 300) { ", which answered HTTP $final" }).")
  }
  if ($s -in 401, 403) { return @('auth', 'auth', "The application answered HTTP $s$From`: it asks for a login. Reachable; signing in is not tested.") }
  if ($s -in 400, 421) { return @('host-rejected', 'failed', "The application answered HTTP $s$From for Host: $Hostname. The network path works, but the app refuses the request; most often its allowed-hosts setting lacks $Hostname (Homepage: HOMEPAGE_ALLOWED_HOSTS, Django: ALLOWED_HOSTS, Vite: server.allowedHosts).") }
  if ($s -ge 500) { return @('unavailable', 'warning', "The application answered HTTP $s$From (an error inside the app, or it is still starting).") }
  if ($s -ge 400) { return @('http-error', 'warning', "The application answered HTTP $s$From`: something answers, but not with a page at this path. Check the port and the path prefix.") }
  return @('verified', 'ok', "The application answered HTTP $s$From.")
}

# Pure: Test-BackendFromTraefik's result -> the verification verdict { result; state; label; message; url; evidence }.
# $KnownPorts: the ports a Docker target declares; a refused connection on another port is a wrong port.
function Get-BackendVerdictCore($Probe, $Service, [string]$ProxyNetwork = 'the shared network', [int[]]$KnownPorts = @()) {
  $v = { param($Result, $State, $Message, $Try) [ordered]@{ result = $Result; state = $State; label = $script:BackendResultLabels[$Result]; message = $Message
      url = $(if ($Try) { $Try.url } else { '' }); evidence = @(@($Probe.tries) | ForEach-Object { $ev = @(Get-TryField $_ 'evidence' @()); if ($ev.Count) { "$($_.url)"; @($ev | ForEach-Object { "  $_" }) } }) } }
  if (-not $Probe.performed) { return & $v 'not-tested' 'skipped' $Probe.detail $null }
  $t = $Service.target
  $first = $Probe.tries[0]
  $alt = $(if (@($Probe.tries).Count -gt 1) { $Probe.tries[1] } else { $null })
  $where = "$($t.host):$($t.port)"
  $answer = $first
  $note = ''
  if ($first.result -eq 'tls') {
    if (-not ($alt -and $alt.result -eq 'http')) { return & $v 'tls' 'failed' "The TLS handshake with $where failed: its certificate cannot be verified, and nothing answers HTTPS without verification either." $first }
    if (-not (Get-TryField $t 'tlsSkipVerify' $false)) {
      return & $v 'tls' 'failed' "The backend at $where answers HTTPS (HTTP $($alt.status)), but its certificate cannot be verified (self-signed, or issued for another name). Prefer the app's plain-HTTP port inside Docker if it has one (Portainer: 9000): Cloudflare already encrypts the public side. Skip certificate verification only for a trusted private backend." $first
    }
    $answer = $alt; $note = ' The certificate is not verified (skip certificate verification is set for this service).'
  }
  if ($alt -and $alt.scheme -ne $first.scheme -and $alt.result -eq 'http' -and $alt.status -ne 400) {
    return & $v 'wrong-protocol' 'failed' "The backend at $where speaks $($alt.scheme.ToUpper()), not $($first.scheme.ToUpper()): it answered HTTP $($alt.status) over $($alt.scheme). Set the target protocol to $($alt.scheme)$(if ($alt.scheme -eq 'https') { ' (with skip certificate verification for a self-signed certificate)' })." $alt
  }
  switch ($answer.result) {
    'http' { $r = Get-BackendAnswerVerdict $answer $Probe.hostname " from Traefik's network ($($answer.url))"; return & $v $r[0] $r[1] ($r[2] + $note) $answer }
    'closed' {
      if ($t.type -eq 'docker' -and @($KnownPorts).Count -and @($KnownPorts) -notcontains [int]$t.port) {
        return & $v 'wrong-port' 'failed' "Connection refused at $where from Traefik's network: $($t.host) declares port(s) $((@($KnownPorts) | Sort-Object) -join ', '), not $($t.port). Use the port the app listens on inside its container, not a published Windows port." $answer
      }
      return & $v 'refused' 'failed' "Connection refused at $where from Traefik's network: nothing listens on that port. Check the port (the one the app listens on inside its container, not a published Windows port) and that the app does not listen only on 127.0.0.1." $answer
    }
    'timeout' { return & $v 'timeout' 'failed' "No answer from $where within $($Probe.timeout) seconds from Traefik's network. For a LAN address: Docker Desktop cannot route there (a Docker network on the same subnet captures it, or the device is off). For host.docker.internal: Windows Firewall blocks the port, or the app listens only on 127.0.0.1." $answer }
    'not-http' { return & $v 'wrong-protocol' 'failed' "Something listens at $where, but it does not answer $($answer.scheme.ToUpper()) ($($answer.detail))." $answer }
    default {
      if ($answer.detail -match 'resolve') { return & $v 'dns' 'failed' "$($t.host) does not resolve from Traefik's network: the container is not attached to '$ProxyNetwork' or the name is wrong." $answer }
      return & $v 'error' 'failed' "The backend request failed: $($answer.detail)" $answer
    }
  }
}

# Pure: Test-BackendFromTraefik's result -> the verification verdict { result; state; label; message; url; evidence },
# plus what each step showed (steps: DNS, TCP, HTTP, TLS, redirect, Host header) and the Host header comparison.
function Get-BackendVerdict($Probe, $Service, [string]$ProxyNetwork = 'the shared network', [int[]]$KnownPorts = @()) {
  $r = Get-BackendVerdictCore $Probe $Service $ProxyNetwork $KnownPorts
  $r.steps = [ordered]@{}
  if (-not $Probe.performed -or -not @($Probe.tries).Count) { return $r }
  $t = $Service.target
  $first = $Probe.tries[0]
  $res = [string]$first.result
  $ip = [string](Get-TryField $first 'resolved' '')
  $isIp = Test-IPv4Address ([string]$t.host)
  $r.steps.dns = $(if ($isIp) { 'not needed (an IP address)' } elseif ($ip) { "$($t.host) resolves to $(($ip -split ':')[0])" } elseif ($r.result -eq 'dns') { "$($t.host) does not resolve" } else { 'not reported' })
  $r.steps.tcp = $(switch ($res) { 'http' { 'connected' } 'tls' { 'connected' } 'not-http' { 'connected' } 'closed' { 'refused' } 'timeout' { 'no answer (timeout)' } default { 'not reached' } })
  $answer = @(@($Probe.tries) | Where-Object { $_.result -eq 'http' } | Select-Object -First 1)
  $r.steps.http = $(if ($answer.Count) { "HTTP $($answer[0].status) over $(Get-TryField $answer[0] 'scheme' $t.protocol)" } else { 'no HTTP answer' })
  if ($t.protocol -eq 'https' -or @(@($Probe.tries) | Where-Object { (Get-TryField $_ 'scheme' '') -eq 'https' }).Count) { $r.steps.tls = $(if ($res -eq 'tls') { 'certificate not verified' } elseif (@(@($Probe.tries) | Where-Object { (Get-TryField $_ 'scheme' '') -eq 'https' -and (Get-TryField $_ 'verified' $false) }).Count) { 'certificate verified' } elseif ($res -eq 'not-http') { 'handshake failed' } else { 'not used' }) }
  if ($answer.Count -and [string](Get-TryField $answer[0] 'location' '')) { $r.steps.redirect = "to $($answer[0].location)$(if ([int](Get-TryField $answer[0] 'finalStatus' 0)) { " (final answer HTTP $($answer[0].finalStatus))" })" }
  $hc = Get-TryField $Probe 'hostCheck' $null
  if ($answer.Count) { $r.steps.hostHeader = "Host: $(Get-TryField $answer[0] 'hostHeader' $Probe.hostname) -> HTTP $($answer[0].status)" }
  if ($hc) {
    $r.steps.hostHeader += "; Host: $(Get-TryField $hc 'hostHeader' '') -> $(if ($hc.result -eq 'http') { "HTTP $($hc.status)" } else { $hc.result })"
    $r.hostCheck = [ordered]@{ publicHost = $Probe.hostname; publicStatus = $(if ($answer.Count) { [int]$answer[0].status } else { 0 }); backendHost = [string](Get-TryField $hc 'hostHeader' ''); backendStatus = [int]$hc.status }
    if ($r.result -eq 'host-rejected' -and $hc.result -eq 'http' -and [int]$hc.status -lt 400) {
      $r.message = "The application answers with its own address as Host header (HTTP $($hc.status)) but refuses Host: $($Probe.hostname) (HTTP $($r.hostCheck.publicStatus)). The network path works; add $($Probe.hostname) to the app's allowed hosts or trusted domains."
    }
    $r.evidence = @($r.evidence) + @("$($hc.url) (Host: $(Get-TryField $hc 'hostHeader' ''))") + @(@(Get-TryField $hc 'evidence' @()) | ForEach-Object { "  $_" })
  }
  return $r
}

# Pure: Test-BackendFromTraefik's result -> (state, message) for the "Traefik -> backend" hop.
function ConvertFrom-BackendProbe($Probe, $Service, [string]$ProxyNetwork = 'the shared network') {
  $r = Get-BackendVerdict $Probe $Service $ProxyNetwork
  return @($r.state, $r.message)
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
  if ($Status -ge 300 -and $Status -lt 400 -and $Location -match '^https://[^/]+\.cloudflareaccess\.com/' -and $Exposure -ne 'access') {
    return [ordered]@{ access = 'warning'; app = 'auth'; message = 'Cloudflare Access shows its login page, although this service is not set to use Cloudflare Access: an Access application still covers this hostname. The request never reaches the tunnel, Traefik or authentik.' }
  }
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
    } else {
      # Not supposed to use Access: an Access application left for this hostname still puts Cloudflare's login in front.
      try {
        $apps = @(Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($cf.accountId)/access/apps" -All | Where-Object {
            ($_.PSObject.Properties['domain'] -and ($_.domain -eq $hostname -or $_.domain -like "$hostname/*")) -or ($_.PSObject.Properties['self_hosted_domains'] -and @($_.self_hosted_domains) -contains $hostname) })
        if ($apps.Count) {
          $mine = [bool]((Get-ManagedResource $cf $hostname 'accessAppId') -eq $apps[0].id)
          & $add (New-HealthCheck 'access' 'Cloudflare Access' 'warning' "Access application '$($apps[0].name)'$(if ($mine) { ' (created by this tool)' }) still asks visitors for a Cloudflare login, although this service does not use Cloudflare Access. Delete it in Cloudflare Zero Trust (Access > Applications) if the application's own login or authentik should be the only one.")
        } else { & $add (New-HealthCheck 'access' 'Cloudflare Access' 'skipped' $(if ($Service.PSObject.Properties['auth'] -and $Service.auth -and [string]$Service.auth.provider -eq 'authentik') { 'Not used: authentik is the login.' } else { 'This service is public: it relies on its own login.' }) $false) }
      } catch { & $add (New-HealthCheck 'access' 'Cloudflare Access' 'skipped' "Not checked: $($_.Exception.Message)" $false) }
    }
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
  $backendIssue = $null; $backendNote = ''; $knownPorts = @()
  if ($Service.target.type -eq 'docker') {
    $i = Invoke-Docker inspect $Service.target.host --format '{{.State.Status}}|{{json .Config.ExposedPorts}}|{{json .NetworkSettings.Networks}}'
    if ($i.ExitCode -ne 0) { $backendIssue = @('failed', "No container named $($Service.target.host).") }
    else {
      $parts = (@($i.Output) -join '').Trim().Split([char[]]'|', 3)
      $st = $parts[0]; $nets = $parts[2] | ConvertFrom-Json
      $ep = $parts[1] | ConvertFrom-Json
      if ($ep) { $knownPorts = @($ep.PSObject.Properties | Where-Object { $_.Name -match '^\d+/tcp$' } | ForEach-Object { [int]$_.Name.Split('/')[0] }) }
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
    $bv = Get-BackendVerdict (Test-BackendFromTraefik -Settings $Settings -Service $Service) $Service $Settings.ProxyNetwork $knownPorts
    $msg = $bv.message
    if ($Service.target.type -eq 'docker' -and $bv.state -ne 'skipped') { $msg = "$($Service.target.host) is running on '$($Settings.ProxyNetwork)'. $msg" }
    if ($backendNote) { $msg += " Note: $backendNote" }
    $c = New-HealthCheck 'backend' 'Traefik to backend' $bv.state $msg ($bv.state -ne 'skipped')
    $c.result = $bv.result; $c.resultLabel = $bv.label; $c.evidence = @($bv.evidence)
    & $add $c
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
    if ($pub.access -eq 'warning') { foreach ($c in $checks) { if ($c.id -eq 'access' -and $c.state -ne 'warning') { $c.state = 'warning'; $c.performed = $true; $c.message = $pub.message } } }
  } elseif ($exposure -ne 'local') {
    & $add (New-HealthCheck 'public' 'Public URL' 'skipped' 'Not requested (Check the public URL sends one GET to the hostname from this PC).' $false)
  }
  return [ordered]@{ service = $Service.name; hostname = $hostname; exposure = $exposure; checkedAt = (Get-Date -Format 's'); checks = $checks.ToArray()
    performed = @($checks | Where-Object { $_.performed }).Count; total = $checks.Count; firstFailure = (Get-FirstFailure $checks.ToArray()) }
}

Export-ModuleMember -Function Get-ServiceHealth, ConvertFrom-RoutedStatus, ConvertFrom-PublicProbe, New-HealthCheck, ConvertFrom-AppStatus, Get-LanTargetIssues,
  Get-DockerSubnets, Get-LocalIPv4Addresses, Test-BackendFromTraefik, ConvertFrom-BackendProbe, ConvertFrom-TunnelRoute, Get-FirstFailure,
  Get-ProbeEvidence, Get-BackendAnswerVerdict, Get-BackendVerdict
