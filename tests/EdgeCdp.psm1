#requires -version 5.1
# Minimal Chrome DevTools Protocol client for headless Microsoft Edge (tests only). Lets browser tests emulate exact
# viewport sizes (phone, tablet, desktop), evaluate JavaScript, collect page errors and network requests, press keys
# and take full-page screenshots, without Node.js or any extra download.
Set-StrictMode -Version 2.0

function Get-EdgePath {
  return @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Start-EdgeSession {
  param([string]$WorkDir = [IO.Path]::GetTempPath())
  $edge = Get-EdgePath
  if (-not $edge) { throw 'Microsoft Edge was not found.' }
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
  $profileDir = Join-Path $WorkDir ('edge-cdp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  $p = Start-Process -FilePath $edge -PassThru -WindowStyle Hidden -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--hide-scrollbars',
    "--remote-debugging-port=$port", "--user-data-dir=`"$profileDir`"", '--window-size=1366,900', 'about:blank')
  $deadline = (Get-Date).AddSeconds(30); $target = $null
  while (-not $target -and (Get-Date) -lt $deadline) {
    try { $list = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 2; $target = @($list | Where-Object { $_.type -eq 'page' })[0] } catch { Start-Sleep -Milliseconds 300 }
  }
  if (-not $target) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw 'Edge DevTools endpoint did not come up.' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
  $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $s = [pscustomobject]@{ Process = $p; Port = $port; Socket = $ws; NextId = 0; Errors = (New-Object System.Collections.ArrayList); Requests = (New-Object System.Collections.ArrayList); ProfileDir = $profileDir }
  $null = Invoke-Cdp $s 'Runtime.enable'
  $null = Invoke-Cdp $s 'Page.enable'
  $null = Invoke-Cdp $s 'Network.enable'
  return $s
}

function Receive-CdpMessage($Session, [int]$TimeoutMs = 30000) {
  $buffer = New-Object byte[] 1048576
  $ms = New-Object System.IO.MemoryStream
  $cts = New-Object Threading.CancellationTokenSource $TimeoutMs
  do {
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $buffer)
    $task = $Session.Socket.ReceiveAsync($seg, $cts.Token)
    try { $task.Wait() } catch { throw 'DevTools: no message within the timeout.' }
    $ms.Write($buffer, 0, $task.Result.Count)
  } while (-not $task.Result.EndOfMessage)
  $msg = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
  # Events are recorded on the session: uncaught page errors and every network request.
  if ($msg.PSObject.Properties['method']) {
    if ($msg.method -eq 'Runtime.exceptionThrown') { $null = $Session.Errors.Add([string]$msg.params.exceptionDetails.exception.description) }
    elseif ($msg.method -eq 'Runtime.consoleAPICalled' -and $msg.params.type -eq 'error') { $null = $Session.Errors.Add('console.error: ' + ((@($msg.params.args) | ForEach-Object { if ($_.PSObject.Properties['value']) { [string]$_.value } elseif ($_.PSObject.Properties['description']) { [string]$_.description } }) -join ' ')) }
    elseif ($msg.method -eq 'Network.requestWillBeSent') { $null = $Session.Requests.Add([pscustomobject]@{ Method = $msg.params.request.method; Url = $msg.params.request.url }) }
  }
  return $msg
}

function Invoke-Cdp($Session, [string]$Method, $Params = @{}, [int]$TimeoutMs = 60000) {
  $Session.NextId++
  $id = $Session.NextId
  $json = ConvertTo-Json -Compress -Depth 10 -InputObject ([ordered]@{ id = $id; method = $Method; params = $Params })
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)
  $Session.Socket.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    $msg = Receive-CdpMessage $Session $TimeoutMs
    if ($msg.PSObject.Properties['id'] -and $msg.id -eq $id) {
      if ($msg.PSObject.Properties['error']) { throw "DevTools $Method failed: $($msg.error.message)" }
      return $msg.result
    }
  }
  throw "DevTools $Method timed out."
}

# Evaluates a JavaScript expression in the page and returns its (JSON-serializable) value.
function Invoke-PageScript($Session, [string]$Expression) {
  $r = Invoke-Cdp $Session 'Runtime.evaluate' @{ expression = $Expression; returnByValue = $true; awaitPromise = $true }
  if ($r.PSObject.Properties['exceptionDetails']) { throw "Page script failed: $($r.exceptionDetails.text) $(if ($r.exceptionDetails.PSObject.Properties['exception']) { $r.exceptionDetails.exception.description })" }
  if ($r.result.PSObject.Properties['value']) { return $r.result.value }
  return $null
}

function Set-Viewport($Session, [int]$Width, [int]$Height = 900, [switch]$Mobile) {
  $null = Invoke-Cdp $Session 'Emulation.setDeviceMetricsOverride' @{ width = $Width; height = $Height; deviceScaleFactor = 1; mobile = [bool]$Mobile }
}

function Open-Page($Session, [string]$Url) { $null = Invoke-Cdp $Session 'Page.navigate' @{ url = $Url } }

# Waits until the expression is truthy (polling). Returns $true or $false on timeout.
function Wait-PageCondition($Session, [string]$Expression, [int]$Seconds = 20) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    try { if (Invoke-PageScript $Session "!!($Expression)") { return $true } } catch { }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Send-Key($Session, [string]$Key, [int]$Modifiers = 0) {
  $codes = @{ Tab = 9; Enter = 13; Escape = 27; ArrowRight = 39; ArrowLeft = 37; ' ' = 32 }
  $code = if ($codes.ContainsKey($Key)) { $codes[$Key] } else { 0 }
  # keyDown with text produces the character event that activates buttons (Enter, Space).
  $text = @{ Enter = "`r"; ' ' = ' ' }[$Key]
  foreach ($type in @('keyDown', 'keyUp')) {
    $p = @{ type = $(if ($type -eq 'keyDown' -and -not $text) { 'rawKeyDown' } else { $type }); key = $Key; code = $(if ($Key -eq ' ') { 'Space' } else { $Key }); windowsVirtualKeyCode = $code; modifiers = $Modifiers }
    if ($type -eq 'keyDown' -and $text) { $p['text'] = $text }
    $null = Invoke-Cdp $Session 'Input.dispatchKeyEvent' $p
  }
}

# Full-page PNG at the current viewport width.
function Save-PageScreenshot($Session, [string]$Path) {
  $metrics = Invoke-Cdp $Session 'Page.getLayoutMetrics'
  $w = [int][Math]::Ceiling($metrics.cssContentSize.width); $hgt = [int][Math]::Min(8000, [Math]::Ceiling($metrics.cssContentSize.height))
  $shot = Invoke-Cdp $Session 'Page.captureScreenshot' @{ format = 'png'; captureBeyondViewport = $true; clip = @{ x = 0; y = 0; width = $w; height = $hgt; scale = 1 } } 120000
  [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($shot.data))
}

function Stop-EdgeSession($Session) {
  if (-not $Session) { return }
  try { $null = Invoke-Cdp $Session 'Browser.close' @{} 5000 } catch { }
  try { $Session.Socket.Dispose() } catch { }
  if (-not $Session.Process.WaitForExit(5000)) { Stop-Process -Id $Session.Process.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
  Remove-Item -LiteralPath $Session.ProfileDir -Recurse -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-EdgePath, Start-EdgeSession, Invoke-Cdp, Invoke-PageScript, Set-Viewport, Open-Page, Wait-PageCondition, Send-Key, Save-PageScreenshot, Stop-EdgeSession
