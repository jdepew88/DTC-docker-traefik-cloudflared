#requires -version 5.1
# Helpers shared by tests\Test-WebUi.ps1 and tests\Invoke-IsolatedTest.ps1: start the Cloudflare API mock and the
# web UI as background processes, sign in like a browser, and call the API with raw HTTP (so tests can also send
# malicious Host / Origin / CSRF values).
Set-StrictMode -Version 2.0

function Get-FreeTcpPort {
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
  return $port
}

function Wait-TcpPort([int]$Port, [int]$Seconds = 30) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $Port); $c.Close(); return $true } catch { Start-Sleep -Milliseconds 300 } finally { $c.Dispose() }
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Start-CloudflareMock {
  param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$WorkDir, [Parameter(Mandatory = $true)][string]$Token)
  $port = Get-FreeTcpPort
  $log = Join-Path $WorkDir 'cf-mock.log'
  $stop = Join-Path $WorkDir 'cf-mock.stop'
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Repo 'tests\CloudflareMock.ps1')`"",
    '-Port', $port, '-Token', $Token, '-LogFile', "`"$log`"", '-StopFile', "`"$stop`"")
  if (-not (Wait-TcpPort $port)) { throw 'Cloudflare mock did not start.' }
  return [pscustomobject]@{ Port = $port; Base = "http://127.0.0.1:$port/client/v4"; Log = $log; StopFile = $stop; Process = $p; Token = $Token }
}

function Start-WebUiServer {
  param([Parameter(Mandatory = $true)][string]$Script, [Parameter(Mandatory = $true)][string]$InstallPath, [Parameter(Mandatory = $true)][string]$WorkDir, [string]$ApiBase)
  $port = Get-FreeTcpPort
  $urlFile = Join-Path $WorkDir 'webui.url'
  $stop = Join-Path $WorkDir 'webui.stop'
  $out = Join-Path $WorkDir 'webui.out'
  Remove-Item -LiteralPath $urlFile, $stop -ErrorAction SilentlyContinue
  $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"", '-Port', $port, '-InstallPath', "`"$InstallPath`"", '-NoBrowser',
    '-LaunchUrlFile', "`"$urlFile`"", '-StopFile', "`"$stop`"", '-StateFile', "`"$(Join-Path $WorkDir 'webui-state.json')`"")
  if ($ApiBase) { $args2 += @('-CloudflareApiBase', $ApiBase) }
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError ($out + '.err') -ArgumentList $args2
  if (-not (Wait-TcpPort $port 40)) { throw ('Web UI did not start: ' + (Get-Content -Raw -LiteralPath ($out + '.err') -ErrorAction SilentlyContinue)) }
  $deadline = (Get-Date).AddSeconds(10)
  while (-not (Test-Path -LiteralPath $urlFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  return [pscustomobject]@{ Port = $port; LaunchUrl = ([IO.File]::ReadAllText($urlFile)); StopFile = $stop; Process = $p; Cookie = ''; Csrf = ''; Bodies = (New-Object System.Collections.ArrayList) }
}

function Stop-TestServer($Server) {
  if (-not $Server) { return }
  New-Item -ItemType File -Force -Path $Server.StopFile | Out-Null
  # Poke the loop so it notices the stop file promptly.
  $c = New-Object System.Net.Sockets.TcpClient
  try { $c.Connect('127.0.0.1', $Server.Port) } catch { } finally { $c.Close() }
  if (-not $Server.Process.WaitForExit(10000)) { Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue }
}

# Raw HTTP request. Returns Status, Body (string), Headers (hashtable, lowercase names; set-cookie kept as-is).
function Invoke-RawHttp {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [string]$Method = 'GET',
    [string]$Path = '/',
    [string]$HostHeader,
    [hashtable]$Headers = @{},
    [string]$Body,
    [int]$TimeoutMs = 300000
  )
  if (-not $HostHeader) { $HostHeader = "127.0.0.1:$Port" }
  $client = New-Object System.Net.Sockets.TcpClient
  $client.Connect('127.0.0.1', $Port)
  $client.ReceiveTimeout = $TimeoutMs
  try {
    $stream = $client.GetStream()
    $bodyBytes = if ($Body) { [Text.Encoding]::UTF8.GetBytes($Body) } else { New-Object byte[] 0 }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append("$Method $Path HTTP/1.1`r`nHost: $HostHeader`r`nConnection: close`r`n")
    foreach ($k in $Headers.Keys) { $null = $sb.Append("${k}: $($Headers[$k])`r`n") }
    if (($Method -ne 'GET' -or $bodyBytes.Length -gt 0) -and -not $Headers.ContainsKey('Content-Length')) { $null = $sb.Append("Content-Length: $($bodyBytes.Length)`r`n") }
    $null = $sb.Append("`r`n")
    $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $stream.Write($head, 0, $head.Length)
    if ($bodyBytes.Length -gt 0) {
      try { $stream.Write($bodyBytes, 0, $bodyBytes.Length) } catch { }
    }
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 16384
    try { while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) } } catch { }
    $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray())
  } finally { $client.Close() }
  $split = $raw.IndexOf("`r`n`r`n")
  if ($split -lt 0) { return [pscustomobject]@{ Status = 0; Body = $raw; Headers = @{} } }
  $lines = $raw.Substring(0, $split) -split "`r`n"
  $status = [int]($lines[0] -split ' ')[1]
  $hdrs = @{}
  foreach ($l in $lines[1..($lines.Count - 1)]) { $i = $l.IndexOf(':'); if ($i -gt 0) { $hdrs[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() } }
  return [pscustomobject]@{ Status = $status; Body = $raw.Substring($split + 4); Headers = $hdrs }
}

# Follows the launch link like a browser and stores the session cookie + CSRF token on $Server.
function Connect-WebUi($Server) {
  $uri = [Uri]$Server.LaunchUrl
  $r = Invoke-RawHttp -Port $Server.Port -Path $uri.PathAndQuery
  if ($r.Status -ne 303 -or -not $r.Headers.ContainsKey('set-cookie')) { throw "Sign-in failed: HTTP $($r.Status)" }
  $Server.Cookie = ($r.Headers['set-cookie'] -split ';')[0]
  $s = Invoke-WebUi $Server GET '/api/session'
  $Server.Csrf = $s.Data.csrf
  return $r
}

# Calls the API as the signed-in browser. Returns Status, Data (parsed JSON) and Body.
function Invoke-WebUi {
  param($Server, [string]$Method, [string]$Path, $Body, [hashtable]$Headers = @{}, [switch]$NoCsrf, [string]$Origin)
  $h = @{ Cookie = $Server.Cookie; Accept = 'application/json' }
  if ($Method -ne 'GET') {
    $h['Content-Type'] = 'application/json'
    $h['Origin'] = if ($Origin) { $Origin } else { "http://127.0.0.1:$($Server.Port)" }
    if (-not $NoCsrf) { $h['X-CSRF-Token'] = $Server.Csrf }
  }
  foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  $json = $null
  if ($null -ne $Body) { $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 12 -Compress } }
  elseif ($Method -ne 'GET') { $json = '{}' }
  $r = Invoke-RawHttp -Port $Server.Port -Method $Method -Path $Path -Headers $h -Body $json
  $null = $Server.Bodies.Add($r.Body)
  $data = $null
  try { $data = $r.Body | ConvertFrom-Json } catch { }
  return [pscustomobject]@{ Status = $r.Status; Data = $data; Body = $r.Body; Headers = $r.Headers }
}

function Get-MockState($Mock) {
  $r = Invoke-RestMethod -Uri ($Mock.Base + '/_state') -Headers @{ Authorization = "Bearer $($Mock.Token)" }
  return $r.result
}

function Get-MockRequests($Mock) {
  if (-not (Test-Path -LiteralPath $Mock.Log)) { return @() }
  return @(Get-Content -LiteralPath $Mock.Log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

# Plan + apply through the API, the way the browser does it.
function Invoke-WebUiChange {
  param($Server, $Body, [string[]]$ConfirmOverwrites = @())
  $plan = Invoke-WebUi $Server POST '/api/services/plan' $Body
  if ($plan.Status -ne 200) { return [pscustomobject]@{ Plan = $plan; Apply = $null } }
  $apply = Invoke-WebUi $Server POST '/api/services/apply' @{ planId = $plan.Data.planId; confirm = $true; confirmOverwrites = $ConfirmOverwrites }
  return [pscustomobject]@{ Plan = $plan; Apply = $apply }
}

Export-ModuleMember -Function Get-FreeTcpPort, Wait-TcpPort, Start-CloudflareMock, Start-WebUiServer, Stop-TestServer, Invoke-RawHttp, Connect-WebUi,
  Invoke-WebUi, Get-MockState, Get-MockRequests, Invoke-WebUiChange
