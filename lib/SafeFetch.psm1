#requires -version 5.1
# Hardened HTTPS fetching for the application importers (Docker Hub, GitHub, registries, Unraid templates, directories).
#
# Everything an importer downloads is untrusted. A URL is fetched only when:
#   - it is absolute https on the default port, without user name or password in it;
#   - its host is on the allow-list (exact name, or a subdomain of an allowed '.suffix'), never an IP literal;
#   - every address the host resolves to is public (no loopback, private, link-local, CGNAT, multicast or reserved
#     range, IPv4 or IPv6), so a URL can never reach this PC, the LAN or a cloud metadata service;
#   - every redirect target passes the same checks again (at most 4 hops; redirects are never followed automatically);
#   - the response stays below a size limit (read incrementally, the download stops at the limit).
# Requests carry no cookies and no credentials except an explicit registry bearer token for the registry that issued
# it. Tests replace the network with Set-SafeFetchHandler; the URL checks still run first.
Set-StrictMode -Version 2.0

$script:DefaultAllowedHosts = @(
  'hub.docker.com', 'registry-1.docker.io', 'auth.docker.io', 'production.cloudflare.docker.com', 'production.cloudfront.docker.com',
  'ghcr.io', 'pkg-containers.githubusercontent.com', 'lscr.io', 'quay.io', '.quay.io', 'cdn01.quay.io', 'cdn02.quay.io', 'cdn03.quay.io',
  'api.github.com', 'github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com', 'codeload.github.com',
  'ca.unraid.net'
)
$script:Handler = $null
$script:Resolver = $null

function Get-SafeFetchAllowedHosts { return $script:DefaultAllowedHosts }

# Tests: a scriptblock param($Url, $Headers) returning @{ Status; ContentType; Body; Headers; Location } replaces the
# network; $null restores it. A resolver scriptblock param($HostName) returning address strings replaces DNS.
function Set-SafeFetchHandler($Handler) { $script:Handler = $Handler }
function Set-SafeFetchResolver($Resolver) { $script:Resolver = $Resolver }

# Pure: whether an address is publicly routable (IPv4 and IPv6, including IPv4-mapped IPv6).
function Test-PublicAddress([string]$Address) {
  $ip = $null
  if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
  if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
    if ($ip.IsIPv4MappedToIPv6) { return (Test-PublicAddress ($ip.MapToIPv4().ToString())) }
    $b = $ip.GetAddressBytes()
    if ([Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([Net.IPAddress]::IPv6None) -or $ip.Equals([Net.IPAddress]::IPv6Any)) { return $false }
    if ($ip.IsIPv6LinkLocal -or $ip.IsIPv6SiteLocal -or $ip.IsIPv6Multicast) { return $false }
    if (($b[0] -band 0xFE) -eq 0xFC) { return $false }                # fc00::/7 unique local
    if ($b[0] -eq 0x20 -and $b[1] -eq 0x01 -and $b[2] -eq 0x0D -and $b[3] -eq 0xB8) { return $false }  # documentation
    if ($b[0] -eq 0x00 -and $b[1] -eq 0x64 -and $b[2] -eq 0xFF -and $b[3] -eq 0x9B) { return $false }  # 64:ff9b:: NAT64
    if ($b[0] -eq 0x20 -and $b[1] -eq 0x02) { return $false }         # 2002::/16 6to4 (embeds IPv4)
    return $true
  }
  $o = $ip.GetAddressBytes()
  switch ($o[0]) {
    0 { return $false }; 10 { return $false }; 127 { return $false }
    100 { if ($o[1] -ge 64 -and $o[1] -le 127) { return $false } }
    169 { if ($o[1] -eq 254) { return $false } }
    172 { if ($o[1] -ge 16 -and $o[1] -le 31) { return $false } }
    192 { if (($o[1] -eq 168) -or ($o[1] -eq 0 -and $o[2] -in 0, 2) -or ($o[1] -eq 88 -and $o[2] -eq 99)) { return $false } }
    198 { if ($o[1] -in 18, 19 -or ($o[1] -eq 51 -and $o[2] -eq 100)) { return $false } }
    203 { if ($o[1] -eq 0 -and $o[2] -eq 113) { return $false } }
  }
  if ($o[0] -ge 224) { return $false }                                # multicast, reserved, broadcast
  return $true
}

function Test-HostAllowed([string]$HostName, [string[]]$AllowedHosts) {
  $h = $HostName.ToLowerInvariant().TrimEnd('.')
  foreach ($a in $AllowedHosts) {
    $x = $a.ToLowerInvariant()
    if ($x.StartsWith('.')) { if ($h.EndsWith($x) -and $h.Length -gt $x.Length) { return $true } }
    elseif ($h -eq $x) { return $true }
  }
  return $false
}

# Pure (apart from DNS): whether a URL may be fetched. Returns { Ok; Reason; Uri }.
function Test-ImportUrl {
  param([Parameter(Mandatory = $true)][string]$Url, [string[]]$AllowedHosts = $script:DefaultAllowedHosts, [switch]$SkipDns)
  $fail = { param($r) [pscustomobject]@{ Ok = $false; Reason = $r; Uri = $null } }
  if ($Url.Length -gt 2048) { return & $fail 'The address is too long.' }
  if ($Url -match '[\s\x00-\x1f"<>\\^`{|}]') { return & $fail 'The address contains characters that are not allowed.' }
  $u = $null
  if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return & $fail 'Not an absolute web address.' }
  if ($u.Scheme -ne 'https') { return & $fail 'Only https:// addresses are accepted.' }
  if ($u.UserInfo) { return & $fail 'Addresses with a user name or password are not accepted.' }
  if (-not $u.IsDefaultPort) { return & $fail 'Only the standard https port (443) is accepted.' }
  $ip = $null
  if ([Net.IPAddress]::TryParse($u.Host.Trim('[', ']'), [ref]$ip) -or $u.HostNameType -in 'IPv4', 'IPv6') { return & $fail 'IP addresses are not accepted; use the official host name.' }
  if (-not (Test-HostAllowed $u.Host $AllowedHosts)) { return & $fail "$($u.Host) is not a supported source. Supported: Docker Hub, GitHub, GitHub Container Registry, Quay, LinuxServer (lscr.io) and Unraid template links." }
  if (-not $SkipDns) {
    $addrs = @()
    try { $addrs = @(if ($script:Resolver) { & $script:Resolver $u.Host } else { [Net.Dns]::GetHostAddresses($u.Host) | ForEach-Object { $_.ToString() } }) } catch { return & $fail "$($u.Host) could not be resolved." }
    if (-not $addrs.Count) { return & $fail "$($u.Host) could not be resolved." }
    $bad = @($addrs | Where-Object { -not (Test-PublicAddress ([string]$_)) })
    if ($bad.Count) { return & $fail "$($u.Host) resolves to a private or local address ($($bad[0])); refused." }
  }
  return [pscustomobject]@{ Ok = $true; Reason = ''; Uri = $u }
}

# Fetches one URL under the rules above. Returns { Status; ContentType; Text; FinalUrl; Headers; Bytes }. Throws with a
# readable message on refusal, oversize, timeout or network failure; HTTP error statuses are returned, not thrown.
function Invoke-SafeFetch {
  param([Parameter(Mandatory = $true)][string]$Url, [int]$MaxBytes = 2MB, [hashtable]$Headers = @{}, [string]$Method = 'GET',
    [string[]]$AllowedHosts = $script:DefaultAllowedHosts, [int]$TimeoutSeconds = 20, [int]$MaxRedirects = 4)
  $current = $Url
  for ($hop = 0; $hop -le $MaxRedirects; $hop++) {
    $check = Test-ImportUrl -Url $current -AllowedHosts $AllowedHosts
    if (-not $check.Ok) { throw $check.Reason }
    # A bearer token is only sent to the host it was meant for (never along a redirect to a CDN).
    $sendHeaders = @{}
    foreach ($k in $Headers.Keys) { if ($k -ne 'Authorization' -or $hop -eq 0) { $sendHeaders[$k] = $Headers[$k] } }
    $resp = $null
    if ($script:Handler) {
      $r = & $script:Handler $current $sendHeaders
      if ($null -eq $r) { throw "No fixture for $current" }
      $body = [string](Get-SfProp $r 'Body' '')
      $bytes = [Text.Encoding]::UTF8.GetBytes($body)
      if ($bytes.Length -gt $MaxBytes) { throw "The response from $($check.Uri.Host) is larger than $([int]($MaxBytes / 1KB)) KB; refused." }
      $resp = [pscustomobject]@{ Status = [int](Get-SfProp $r 'Status' 200); ContentType = [string](Get-SfProp $r 'ContentType' 'application/json'); Location = [string](Get-SfProp $r 'Location' ''); Headers = (Get-SfProp $r 'Headers' @{}); Bytes = $bytes }
    } else {
      $resp = Invoke-SfNetwork -Uri $check.Uri -Method $Method -Headers $sendHeaders -MaxBytes $MaxBytes -TimeoutSeconds $TimeoutSeconds
    }
    if ($resp.Status -in 301, 302, 303, 307, 308) {
      if (-not $resp.Location) { throw "Redirect without a target from $($check.Uri.Host)." }
      $next = $null
      if (-not [Uri]::TryCreate($check.Uri, $resp.Location, [ref]$next)) { throw 'Invalid redirect target.' }
      $current = $next.AbsoluteUri
      continue
    }
    $text = ''
    if ($resp.Bytes) { $text = [Text.Encoding]::UTF8.GetString($resp.Bytes) }
    return [pscustomobject]@{ Status = $resp.Status; ContentType = $resp.ContentType; Text = $text; FinalUrl = $current; Headers = $resp.Headers; Bytes = $resp.Bytes.Length }
  }
  throw "Too many redirects (more than $MaxRedirects)."
}

function Get-SfProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Invoke-SfNetwork($Uri, [string]$Method, [hashtable]$Headers, [int]$MaxBytes, [int]$TimeoutSeconds) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $req = [Net.HttpWebRequest]::Create($Uri)
  $req.Method = $Method
  $req.AllowAutoRedirect = $false
  $req.Timeout = $TimeoutSeconds * 1000
  $req.ReadWriteTimeout = $TimeoutSeconds * 1000
  $req.UserAgent = 'DeploymentManager-Importer/1 (+https://github.com/jdepew88/traefik-cloudflared-windows)'
  $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
  $req.CookieContainer = $null
  $req.Proxy = $null
  foreach ($k in $Headers.Keys) { if ($k -eq 'Accept') { $req.Accept = $Headers[$k] } else { $req.Headers[$k] = $Headers[$k] } }
  $res = $null
  try { $res = $req.GetResponse() } catch [Net.WebException] {
    if ($_.Exception.Response) { $res = $_.Exception.Response } else { throw "Could not reach $($Uri.Host): $($_.Exception.Message)" }
  }
  try {
    $hdr = @{}
    foreach ($k in $res.Headers.AllKeys) { $hdr[$k] = $res.Headers[$k] }
    if ($res.ContentLength -gt $MaxBytes) { throw "The response from $($Uri.Host) is larger than $([int]($MaxBytes / 1KB)) KB; refused." }
    $ms = New-Object IO.MemoryStream
    if ($Method -ne 'HEAD') {
      $s = $res.GetResponseStream()
      $buf = New-Object byte[] 65536
      while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) {
        $ms.Write($buf, 0, $n)
        if ($ms.Length -gt $MaxBytes) { throw "The response from $($Uri.Host) is larger than $([int]($MaxBytes / 1KB)) KB; refused." }
      }
    }
    return [pscustomobject]@{ Status = [int]$res.StatusCode; ContentType = [string]$res.ContentType; Location = [string]$res.Headers['Location']; Headers = $hdr; Bytes = $ms.ToArray() }
  } finally { $res.Close() }
}

# Fetches JSON (throws on HTTP errors with the status code in the message).
function Invoke-SafeJson {
  param([Parameter(Mandatory = $true)][string]$Url, [hashtable]$Headers = @{}, [int]$MaxBytes = 2MB)
  $r = Invoke-SafeFetch -Url $Url -Headers $Headers -MaxBytes $MaxBytes
  if ($r.Status -ge 400) { $e = New-Object Exception "HTTP $($r.Status) from $(([Uri]$r.FinalUrl).Host)"; $e.Data['Status'] = $r.Status; throw $e }
  try { return ($r.Text | ConvertFrom-Json) } catch { throw "The response from $(([Uri]$r.FinalUrl).Host) is not valid JSON." }
}

Export-ModuleMember -Function Get-SafeFetchAllowedHosts, Set-SafeFetchHandler, Set-SafeFetchResolver, Test-PublicAddress, Test-HostAllowed, Test-ImportUrl, Invoke-SafeFetch, Invoke-SafeJson
