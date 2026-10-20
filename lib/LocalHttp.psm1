#requires -version 5.1
# Minimal HTTP/1.1 server primitives on a raw TcpListener bound to 127.0.0.1.
#
# Used by webui.ps1 and by the Cloudflare API mock in tests\. A TcpListener on IPAddress.Loopback is used instead
# of System.Net.HttpListener because HttpListener (http.sys) listens on every interface and only filters by Host
# header, and needs a URL ACL for non-admin users. A loopback socket is unreachable from the LAN by construction.
#
# One request per connection (Connection: close), bounded header and body sizes, read timeouts.
Set-StrictMode -Version 2.0

$script:MaxHeaderBytes = 16384
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:StatusText = @{
  200 = 'OK'; 201 = 'Created'; 204 = 'No Content'; 303 = 'See Other'; 400 = 'Bad Request'; 401 = 'Unauthorized'
  403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict'; 413 = 'Payload Too Large'
  415 = 'Unsupported Media Type'; 421 = 'Misdirected Request'; 500 = 'Internal Server Error'; 502 = 'Bad Gateway'
}

function New-LoopbackListener([int]$Port) {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
  # Fail instead of sharing the port with another process.
  $listener.ExclusiveAddressUse = $true
  $listener.Start()
  return $listener
}

function ConvertFrom-QueryString([string]$Query) {
  $values = @{}
  if (-not $Query) { return $values }
  foreach ($pair in $Query.TrimStart('?').Split('&')) {
    if (-not $pair) { continue }
    $kv = $pair.Split('=', 2)
    $key = [Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
    $value = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
    $values[$key] = $value
  }
  return $values
}

# Reads one request. Returns $null for a connection that closed or sent garbage; throws on oversized input
# with a message starting with '413' or '400' so the caller can answer before closing.
function Read-HttpRequest {
  param([Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client, [int]$MaxBodyBytes = 1048576, [int]$TimeoutMs = 10000)
  $Client.ReceiveTimeout = $TimeoutMs
  $stream = $Client.GetStream()
  $stream.ReadTimeout = $TimeoutMs
  $buffer = New-Object byte[] 8192
  $data = New-Object System.IO.MemoryStream
  $headerEnd = -1
  while ($headerEnd -lt 0) {
    $n = $stream.Read($buffer, 0, $buffer.Length)
    if ($n -le 0) { return $null }
    $data.Write($buffer, 0, $n)
    $bytes = $data.ToArray()
    for ($i = [Math]::Max(0, $bytes.Length - $n - 3); $i -le $bytes.Length - 4; $i++) {
      if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10 -and $bytes[$i + 2] -eq 13 -and $bytes[$i + 3] -eq 10) { $headerEnd = $i; break }
    }
    if ($headerEnd -lt 0 -and $bytes.Length -gt $script:MaxHeaderBytes) { throw '431 request headers too large' }
  }
  $bytes = $data.ToArray()
  $head = [Text.Encoding]::ASCII.GetString($bytes, 0, $headerEnd)
  $lines = $head -split "`r`n"
  $requestLine = $lines[0] -split ' '
  if ($requestLine.Count -ne 3 -or $requestLine[2] -notmatch '^HTTP/1\.[01]$') { throw '400 malformed request line' }
  $headers = @{}
  foreach ($line in $lines[1..($lines.Count - 1)]) {
    if (-not $line) { continue }
    $idx = $line.IndexOf(':')
    if ($idx -le 0) { throw '400 malformed header' }
    $name = $line.Substring(0, $idx).Trim().ToLowerInvariant()
    # Duplicate Host / Content-Length headers are a request-smuggling smell; refuse them.
    if ($headers.ContainsKey($name) -and $name -in @('host', 'content-length', 'origin', 'cookie')) { throw "400 duplicate $name header" }
    $headers[$name] = $line.Substring($idx + 1).Trim()
  }
  if ($headers.ContainsKey('transfer-encoding')) { throw '400 chunked request bodies are not supported' }
  $length = 0
  if ($headers.ContainsKey('content-length')) {
    if (-not [int]::TryParse($headers['content-length'], [ref]$length) -or $length -lt 0) { throw '400 invalid Content-Length' }
    if ($length -gt $MaxBodyBytes) { throw '413 request body too large' }
  }
  $bodyStart = $headerEnd + 4
  $body = New-Object System.IO.MemoryStream
  if ($bytes.Length -gt $bodyStart) { $body.Write($bytes, $bodyStart, [Math]::Min($bytes.Length - $bodyStart, $length)) }
  while ($body.Length -lt $length) {
    $n = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $length - $body.Length))
    if ($n -le 0) { throw '400 truncated body' }
    $body.Write($buffer, 0, $n)
  }
  $target = $requestLine[1]
  $path = $target; $query = ''
  $q = $target.IndexOf('?')
  if ($q -ge 0) { $path = $target.Substring(0, $q); $query = $target.Substring($q + 1) }
  return [pscustomobject]@{
    Method  = $requestLine[0].ToUpperInvariant()
    Target  = $target
    Path    = [Uri]::UnescapeDataString($path)
    Query   = ConvertFrom-QueryString $query
    Headers = $headers
    Body    = $script:Utf8NoBom.GetString($body.ToArray())
  }
}

# $Body may be a string (sent as UTF-8) or a byte[].
function Send-HttpResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client,
    [int]$Status = 200,
    [string]$ContentType = 'text/plain; charset=utf-8',
    $Body = '',
    [hashtable]$Headers = @{}
  )
  # Plain assignments: an if-expression would unroll the byte array (and turn an empty one into $null).
  [byte[]]$bytes = New-Object byte[] 0
  if ($Body -is [byte[]]) { $bytes = $Body }
  elseif ($null -ne $Body) { $bytes = $script:Utf8NoBom.GetBytes([string]$Body) }
  $reason = if ($script:StatusText.ContainsKey($Status)) { $script:StatusText[$Status] } else { 'Status' }
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append("HTTP/1.1 $Status $reason`r`n")
  $null = $sb.Append("Content-Type: $ContentType`r`n")
  $null = $sb.Append("Content-Length: $($bytes.Length)`r`n")
  $null = $sb.Append("Connection: close`r`n")
  foreach ($key in $Headers.Keys) {
    foreach ($value in @($Headers[$key])) {
      if ([string]$value -match '[\r\n]') { throw "Header $key contains a line break." }
      $null = $sb.Append("${key}: $value`r`n")
    }
  }
  $null = $sb.Append("`r`n")
  $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
  $stream = $Client.GetStream()
  $stream.WriteTimeout = 10000
  $stream.Write($head, 0, $head.Length)
  if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
  $stream.Flush()
}

# Accept loop. Connections are only read once they have data, so idle browser pre-connections never block the
# (single-threaded) server. $Handler receives the parsed request and returns @{ Status; ContentType; Body; Headers }.
# Stops when $StopFile appears (used by tests) or on Ctrl+C.
function Start-HttpLoop {
  param(
    [Parameter(Mandatory = $true)]$Listener,
    [Parameter(Mandatory = $true)][scriptblock]$Handler,
    [int]$MaxBodyBytes = 1048576,
    [string]$StopFile
  )
  $pending = New-Object System.Collections.ArrayList
  while ($true) {
    if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { break }
    $busy = $false
    while ($Listener.Pending()) {
      $null = $pending.Add([pscustomobject]@{ Client = $Listener.AcceptTcpClient(); Since = [DateTime]::UtcNow })
      $busy = $true
    }
    foreach ($entry in @($pending)) {
      $c = $entry.Client
      $ready = $false
      try { $ready = $c.Available -gt 0 } catch { $ready = $false }
      if (-not $ready) {
        $closed = $false
        try { $closed = $c.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $c.Available -eq 0 } catch { $closed = $true }
        if ($closed -or ([DateTime]::UtcNow - $entry.Since).TotalSeconds -gt 30) { $pending.Remove($entry); $c.Close() }
        continue
      }
      $pending.Remove($entry)
      $busy = $true
      try {
        $request = $null
        try { $request = Read-HttpRequest -Client $c -MaxBodyBytes $MaxBodyBytes }
        catch {
          $msg = $_.Exception.Message
          $code = if ($msg -match '^(\d{3}) ') { [int]$Matches[1] } else { 400 }
          if ($code -eq 431) { $code = 400 }
          try {
            Send-HttpResponse -Client $c -Status $code -Body "$msg`n"
            # Graceful close: closing with unread request bytes would reset the connection and the client
            # might never see the error. Discard what is already in flight (bounded in size and time).
            $c.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
            $drain = New-Object byte[] 65536
            $stream = $c.GetStream(); $stream.ReadTimeout = 1000
            $total = 0
            while ($total -lt 4 * $MaxBodyBytes) { $n = $stream.Read($drain, 0, $drain.Length); if ($n -le 0) { break }; $total += $n }
          } catch { }
        }
        if ($request) {
          $response = $null
          try { $response = & $Handler $request }
          catch { $response = @{ Status = 500; ContentType = 'application/json; charset=utf-8'; Body = (ConvertTo-Json -Compress @{ error = 'Internal error: ' + $_.Exception.Message }) } }
          $headers = @{}
          if ($response.ContainsKey('Headers') -and $response.Headers) { $headers = $response.Headers }
          $ct = if ($response.ContainsKey('ContentType') -and $response.ContentType) { $response.ContentType } else { 'text/plain; charset=utf-8' }
          $bodyOut = ''
          if ($response.ContainsKey('Body')) { $bodyOut = $response.Body }
          Send-HttpResponse -Client $c -Status $response.Status -ContentType $ct -Body $bodyOut -Headers $headers
        }
      } catch {
        # Client went away mid-response; nothing to do.
      } finally { $c.Close() }
    }
    if (-not $busy) { Start-Sleep -Milliseconds 15 }
  }
}

Export-ModuleMember -Function New-LoopbackListener, ConvertFrom-QueryString, Read-HttpRequest, Send-HttpResponse, Start-HttpLoop
