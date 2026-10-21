#requires -version 5.1
<#
.SYNOPSIS
  In-memory mock of the parts of the Cloudflare v4 API the web UI uses, on 127.0.0.1 only. Tests point
  webui.ps1 -CloudflareApiBase at it, so no real Cloudflare resource is ever read or changed.

  Every request is appended to -LogFile as one JSON line (method, path, query, body, whether the bearer token
  matched). The Authorization header itself is never logged. Stops when -StopFile appears.
#>
param(
  [Parameter(Mandatory = $true)][int]$Port,
  [Parameter(Mandatory = $true)][string]$Token,
  [Parameter(Mandatory = $true)][string]$LogFile,
  [Parameter(Mandatory = $true)][string]$StopFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\LocalHttp.psm1') -Force

$acct = 'acc0000000000000000000000000001'
$tunnelId = '11111111-2222-3333-4444-555555555555'
$db = @{
  accounts = @([pscustomobject]@{ id = $acct; name = 'Test Account' })
  zones    = @(
    [pscustomobject]@{ id = 'zone00000000000000000000000000001'; name = 'example.test'; status = 'active'; account = [pscustomobject]@{ id = $acct } },
    [pscustomobject]@{ id = 'zone00000000000000000000000000002'; name = 'other.test'; status = 'active'; account = [pscustomobject]@{ id = $acct } }
  )
  tunnels  = New-Object System.Collections.ArrayList
  configs  = @{}
  dns      = New-Object System.Collections.ArrayList
  apps     = New-Object System.Collections.ArrayList
  seq      = 100
}
$null = $db.tunnels.Add([pscustomobject]@{ id = $tunnelId; name = 'existing-tunnel'; status = 'inactive'; remote_config = $true; config_src = 'cloudflare'; connections = @() })
$null = $db.tunnels.Add([pscustomobject]@{ id = '99999999-2222-3333-4444-555555555555'; name = 'local-tunnel'; status = 'healthy'; remote_config = $false; config_src = 'local'; connections = @() })
$db.configs[$tunnelId] = [pscustomobject]@{ ingress = @([pscustomobject]@{ hostname = 'keep.example.test'; service = 'http://somewhere:8080' }, [pscustomobject]@{ service = 'http_status:404' }); 'warp-routing' = [pscustomobject]@{ enabled = $false } }
$null = $db.dns.Add([pscustomobject]@{ id = 'rec-taken'; zone = 'zone00000000000000000000000000001'; type = 'CNAME'; name = 'taken.example.test'; content = 'elsewhere.example.net'; proxied = $true })
$null = $db.dns.Add([pscustomobject]@{ id = 'rec-a'; zone = 'zone00000000000000000000000000001'; type = 'A'; name = 'a-record.example.test'; content = '192.0.2.10'; proxied = $true })
$null = $db.dns.Add([pscustomobject]@{ id = 'rec-keep'; zone = 'zone00000000000000000000000000001'; type = 'CNAME'; name = 'keep.example.test'; content = "$tunnelId.cfargotunnel.com"; proxied = $true })
$null = $db.apps.Add([pscustomobject]@{ id = 'app-existing'; name = 'Existing app'; domain = 'protected.example.test'; type = 'self_hosted' })

function New-Id { $db.seq++; return ('id{0:D30}' -f $db.seq) }
function Ok($Result, [int]$Status = 200) {
  $envelope = [ordered]@{ success = $true; errors = @(); messages = @(); result = $Result }
  if ($Result -is [System.Array] -or $Result -is [System.Collections.ArrayList]) { $envelope['result_info'] = @{ page = 1; per_page = 50; total_pages = 1; count = @($Result).Count; total_count = @($Result).Count } }
  return @{ Status = $Status; ContentType = 'application/json'; Body = (ConvertTo-Json -InputObject $envelope -Depth 20 -Compress) }
}
function Fail([int]$Status, [int]$Code, [string]$Message) {
  return @{ Status = $Status; ContentType = 'application/json'; Body = (ConvertTo-Json -Compress -Depth 5 -InputObject ([ordered]@{ success = $false; errors = @(@{ code = $Code; message = $Message }); messages = @(); result = $null })) }
}

$handler = {
  param($req)
  $auth = if ($req.Headers.ContainsKey('authorization')) { $req.Headers['authorization'] } else { '' }
  # -Token has every permission. Tokens named mock<Profile>_<random> simulate restricted tokens:
  #   One       only the zone example.test        NoZone    no Zone Read (no zones, no DNS)
  #   NoTunnel  no Cloudflare Tunnel permission    NoAccess  no Access permission
  #   Disabled  verify reports status 'disabled'   ReadOnly  reads everything, every write fails (403)
  $tokenProfile = ''
  if ($auth -eq "Bearer $Token") { $tokenProfile = 'Full' }
  elseif ($auth -match '^Bearer mock(One|NoZone|NoTunnel|NoAccess|Disabled|ReadOnly)_[A-Za-z0-9]{24,}$') { $tokenProfile = $Matches[1] }
  $authOk = ($tokenProfile -eq 'Full')
  $entry = [ordered]@{ method = $req.Method; path = $req.Path; query = $req.Query; body = $req.Body; authOk = $authOk; profile = $tokenProfile }
  [IO.File]::AppendAllText($LogFile, (ConvertTo-Json -InputObject $entry -Compress -Depth 5) + "`n")
  if (-not $tokenProfile) { return Fail 401 10000 'Authentication error' }
  $p = $req.Path -replace '^/client/v4', ''
  $body = $null
  if ($req.Body) { $body = $req.Body | ConvertFrom-Json }
  $m = $req.Method
  if ($m -eq 'GET' -and $p -eq '/user/tokens/verify') { return Ok ([pscustomobject]@{ id = 'tok'; status = $(if ($tokenProfile -eq 'Disabled') { 'disabled' } else { 'active' }) }) }
  if ($tokenProfile -eq 'Disabled') { return Fail 401 1000 'Invalid API Token' }
  if ($tokenProfile -ne 'Full' -and $m -ne 'GET') { return Fail 403 10000 'Authentication error' }
  if ($tokenProfile -eq 'NoTunnel' -and $p -match '/cfd_tunnel') { return Fail 403 10000 'Authentication error' }
  if ($tokenProfile -eq 'NoAccess' -and $p -match '/access/') { return Fail 403 10000 'Authentication error' }
  if ($tokenProfile -eq 'NoZone' -and $p -match '^/zones/') { return Fail 403 10000 'Authentication error' }
  if ($m -eq 'GET' -and $p -eq '/user') {
    if ($tokenProfile -ne 'Full') { return Fail 403 9109 'Unauthorized to access requested resource' }
    return Ok ([pscustomobject]@{ id = 'user1'; email = 'owner@example.test' })
  }
  if ($m -eq 'GET' -and $p -eq '/accounts') { return Ok $db.accounts }
  if ($m -eq 'GET' -and $p -eq '/zones') {
    $z = @($db.zones)
    if ($tokenProfile -eq 'NoZone') { $z = @() }
    if ($tokenProfile -eq 'One') { $z = @($z | Where-Object { $_.name -eq 'example.test' }) }
    if ($req.Query.ContainsKey('account.id')) { $z = @($z | Where-Object { $_.account.id -eq $req.Query['account.id'] }) }
    return Ok $z
  }
  if ($p -match "^/accounts/([^/]+)/cfd_tunnel$") {
    if ($Matches[1] -ne $acct) { return Fail 403 9109 'Unauthorized to access requested resource' }
    if ($m -eq 'GET') { return Ok @($db.tunnels) }
    if ($m -eq 'POST') {
      $t = [pscustomobject]@{ id = [Guid]::NewGuid().ToString(); name = $body.name; status = 'inactive'; remote_config = ($body.config_src -eq 'cloudflare'); config_src = $body.config_src; connections = @() }
      $null = $db.tunnels.Add($t)
      $db.configs[$t.id] = $null
      return Ok $t
    }
  }
  if ($m -eq 'GET' -and $p -match '^/accounts/([^/]+)/cfd_tunnel/([0-9a-f-]{36})$') {
    if ($Matches[1] -ne $acct) { return Fail 403 9109 'Unauthorized to access requested resource' }
    $id = $Matches[2]
    $t = @($db.tunnels | Where-Object { $_.id -eq $id })
    if ($t.Count -eq 0) { return Fail 404 1003 'Tunnel not found' }
    return Ok $t[0]
  }
  if ($m -eq 'GET' -and $p -match '^/accounts/[^/]+/cfd_tunnel/([^/]+)/token$') {
    $json = ConvertTo-Json -Compress -InputObject ([ordered]@{ a = $acct; t = $Matches[1]; s = 'bW9jay1zZWNyZXQtbm90LXJlYWwtMDEyMzQ1Njc4OWFiY2RlZg==' })
    return Ok ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
  }
  if ($p -match '^/accounts/[^/]+/cfd_tunnel/([^/]+)/configurations$') {
    $id = $Matches[1]
    if ($m -eq 'GET') { return Ok ([pscustomobject]@{ tunnel_id = $id; version = 1; config = $db.configs[$id] }) }
    if ($m -eq 'PUT') { $db.configs[$id] = $body.config; return Ok ([pscustomobject]@{ tunnel_id = $id; version = 2; config = $body.config }) }
  }
  if ($p -match '^/zones/([^/]+)/dns_records$') {
    $zone = $Matches[1]
    if ($m -eq 'GET') {
      $r = @($db.dns | Where-Object { $_.zone -eq $zone })
      if ($req.Query.ContainsKey('name')) { $r = @($r | Where-Object { $_.name -eq $req.Query['name'] }) }
      return Ok $r
    }
    if ($m -eq 'POST') {
      if (@($db.dns | Where-Object { $_.name -eq $body.name }).Count -gt 0) { return Fail 400 81053 'An A, AAAA, or CNAME record with that host already exists.' }
      $rec = [pscustomobject]@{ id = (New-Id); zone = $zone; type = $body.type; name = $body.name; content = $body.content; proxied = [bool]$body.proxied; comment = $body.comment }
      $null = $db.dns.Add($rec)
      return Ok $rec
    }
  }
  if ($p -match '^/zones/([^/]+)/dns_records/([^/]+)$') {
    $id = $Matches[2]
    $rec = @($db.dns | Where-Object { $_.id -eq $id })
    if ($rec.Count -eq 0) { return Fail 404 81044 'Record does not exist.' }
    if ($m -eq 'GET') { return Ok $rec[0] }
    if ($m -eq 'PUT') { $rec[0].type = $body.type; $rec[0].content = $body.content; $rec[0].proxied = [bool]$body.proxied; return Ok $rec[0] }
    if ($m -eq 'DELETE') { $db.dns.Remove($rec[0]); return Ok ([pscustomobject]@{ id = $id }) }
  }
  if ($p -match '^/accounts/[^/]+/access/apps$') {
    if ($m -eq 'GET') { return Ok @($db.apps) }
    if ($m -eq 'POST') {
      $app = [pscustomobject]@{ id = (New-Id); name = $body.name; domain = $body.domain; type = $body.type; policies = $body.policies }
      $null = $db.apps.Add($app)
      return Ok $app
    }
  }
  if ($m -in @('GET', 'DELETE') -and $p -match '^/accounts/[^/]+/access/apps/([^/]+)$') {
    $id = $Matches[1]
    $app = @($db.apps | Where-Object { $_.id -eq $id })
    if ($app.Count -eq 0) { return Fail 404 12130 'access.api.error.not_found' }
    if ($m -eq 'GET') { return Ok $app[0] }
    $db.apps.Remove($app[0])
    return Ok ([pscustomobject]@{ id = $id })
  }
  if ($tokenProfile -ne 'Full' -and $p -eq '/_state') { return Fail 403 10000 'Authentication error' }
  if ($m -eq 'GET' -and $p -eq '/_state') { return Ok ([pscustomobject]@{ tunnels = @($db.tunnels); configs = $db.configs; dns = @($db.dns); apps = @($db.apps) }) }
  return Fail 404 7003 "No route for $m $p"
}

$listener = New-LoopbackListener $Port
try { Start-HttpLoop -Listener $listener -Handler $handler -StopFile $StopFile } finally { $listener.Stop() }
