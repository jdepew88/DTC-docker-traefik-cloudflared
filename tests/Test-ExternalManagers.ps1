#requires -version 5.1
<#
.SYNOPSIS
  Optional read-only Portainer / Arcane connectors (lib\ExternalManagers.psm1): mocked API responses for the logic,
  then the web API against a local mock server (no real Portainer or Arcane, no production credentials).

.DESCRIPTION
  Part 1 (pure, mocked transport): endpoint rules, GET-only requests with the right header, Portainer stacks with
  their containers, Arcane projects (documented agents path and the environments fallback), refused or expired keys,
  unreachable servers, ownership confirmed / conflicting / unknown, restarted containers and stacks stopped in the
  manager, and that Docker-only discovery is unchanged without connectors.
  Part 2 (throwaway instance + a loopback mock server speaking the Portainer API): save a connector (the key is
  stored with DPAPI, never written to managers.json or returned), test it, an unreachable connector, delete.
  These are mocks: they do not prove compatibility with a live Portainer or Arcane.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-ExternalManagers.ps1
#>
[CmdletBinding()]
param([switch]$SkipApi)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in @('TraefikProxy', 'ExternalManagers', 'AppContract')) { Import-Module (Join-Path $repo "lib\$m.psm1") -Force }
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }

# --- Part 1a: endpoints ------------------------------------------------------------------------------------------------
$okUrls = @('https://portainer.example.com', 'http://127.0.0.1:9000', 'http://192.168.1.20:3552', 'http://nas.lan:9000', 'https://10.0.0.5:9443/')
$badUrls = @{ 'http://portainer.example.com' = 'https'; 'https://user:pw@host.example' = 'user name'; 'ftp://x.example' = 'http'; 'https://x.example/?a=1' = '\?' ; 'not a url' = 'http' }
Test-Condition 'endpoints: https anywhere, plain http only to this PC or a private address; no credentials, queries or other schemes in the address' (
  -not @($okUrls | Where-Object { -not (Test-ManagerConnectorUrl $_).Ok }).Count -and -not @($badUrls.Keys | Where-Object { $r = Test-ManagerConnectorUrl $_; $r.Ok -or $r.Reason -notmatch $badUrls[$_] }).Count) ''
$kinds = Get-ExternalManagerKinds
Test-Condition 'scopes: Arcane keys can be read-only (permissions named); Portainer CE tokens cannot, and the page says so' ($kinds.arcane.readOnlyScopes -and ($kinds.arcane.scopeNote -match 'projects:read') -and -not $kinds.portainer.readOnlyScopes -and $kinds.portainer.scopeNote -match 'no read-only role') ''

# --- Part 1b: mocked transports --------------------------------------------------------------------------------------------
$calls = New-Object System.Collections.ArrayList
$mkTransport = { param([hashtable]$Routes, [string]$Key, [string]$Header)
  { param($method, $url, $headers)
    $null = $calls.Add([pscustomobject]@{ Method = $method; Url = $url; Header = [string]$headers[$Header] })
    if ([string]$headers[$Header] -ne $Key) { return [pscustomobject]@{ Status = 401; Body = '{"message":"Unauthorized"}' } }
    $path = ([Uri]$url).PathAndQuery
    if ($Routes.ContainsKey($path)) { return [pscustomobject]@{ Status = 200; Body = ($Routes[$path] | ConvertTo-Json -Depth 8) } }
    return [pscustomobject]@{ Status = 404; Body = '' } }.GetNewClosure() }
$pc = { param($name, $project, $service, $state, [string[]]$nets) [ordered]@{ Names = @("/$name"); State = $state; Labels = [ordered]@{ 'com.docker.compose.project' = $project; 'com.docker.compose.service' = $service }; NetworkSettings = [ordered]@{ Networks = [ordered]@{ ($nets[0]) = @{}; } } } }
$portRoutes = @{
  '/api/stacks' = @(@{ Id = 3; Name = 'wiki'; Type = 2; EndpointId = 1; Status = 1; ProjectPath = '/data/compose/3'; GitConfig = @{ URL = 'https://github.com/example/wiki-stack' } }, @{ Id = 4; Name = 'Old'; Type = 2; EndpointId = 1; Status = 2; ProjectPath = '/data/compose/4' })
  '/api/endpoints/1/docker/containers/json?all=1' = @((& $pc 'wiki-web-1' 'wiki' 'web' 'running' @('proxy')), (& $pc 'wiki-db-1' 'wiki' 'db' 'running' @('wiki_default')), (& $pc 'old-app-1' 'old' 'app' 'running' @('old_default')))
}
$pt = & $mkTransport $portRoutes 'ptr_good_key_123' 'X-API-Key'
$conn = [pscustomobject]@{ id = 'portainer'; kind = 'portainer'; url = 'http://127.0.0.1:9000' }
$calls.Clear()
$snap = Get-ManagerSnapshot -Connector $conn -Key 'ptr_good_key_123' -Transport $pt
$wiki = @($snap.stacks | Where-Object { $_.name -eq 'wiki' })[0]
Test-Condition 'portainer: stacks with id, environment, status, project path, Git source and their containers (from the read-only Docker proxy)' (
  $snap.ok -and @($snap.stacks).Count -eq 2 -and $wiki.stackId -eq '3' -and $wiki.status -eq 'active' -and $wiki.path -eq '/data/compose/3' -and $wiki.source -match 'wiki-stack' -and @($wiki.containers).Count -eq 2 -and
  @($snap.stacks | Where-Object { $_.name -eq 'Old' })[0].status -eq 'inactive') ($snap | ConvertTo-Json -Depth 6 -Compress)
Test-Condition 'portainer: only GET requests, each with the X-API-Key header' ($calls.Count -ge 2 -and -not @($calls | Where-Object { $_.Method -ne 'GET' -or $_.Header -ne 'ptr_good_key_123' }).Count) (($calls | ForEach-Object { "$($_.Method) $($_.Url)" }) -join ', ')
$bad = Get-ManagerSnapshot -Connector $conn -Key 'expired-or-revoked' -Transport $pt
$down = Get-ManagerSnapshot -Connector $conn -Key 'x' -Transport { param($m, $u, $h) [pscustomobject]@{ Status = 0; Body = '' } }
$odd = Get-ManagerSnapshot -Connector $conn -Key 'x' -Transport { param($m, $u, $h) [pscustomobject]@{ Status = 200; Body = '<html>login</html>' } }
Test-Condition 'portainer: a refused or expired key, an unreachable server and a non-JSON answer are reported (never thrown); the key never appears in messages' (
  -not $bad.ok -and $bad.error -eq 'unauthorized' -and $bad.message -match 'expired' -and -not $down.ok -and $down.error -eq 'unreachable' -and -not $odd.ok -and $odd.error -eq 'error' -and (($bad | ConvertTo-Json -Depth 5) -notmatch 'expired-or-revoked')) "$($bad.error) $($down.error) $($odd.error)"

$arcRoutes = @{
  '/api/environments' = @{ data = @(@{ id = '0'; name = 'Local' }) }
  '/api/environments/0/projects' = @{ data = @(@{ id = 'p1'; name = 'notes'; status = 'RUNNING'; path = '/app/data/projects/notes' }) }
  '/api/environments/0/containers' = @{ data = @((& $pc 'notes-web-1' 'notes' 'web' 'running' @('proxy'))) }
}
$at = & $mkTransport $arcRoutes 'arc_key_456' 'X-Api-Key'
$aconn = [pscustomobject]@{ id = 'arcane'; kind = 'arcane'; url = 'http://192.168.1.20:3552' }
$calls.Clear()
$asnap = Get-ManagerSnapshot -Connector $aconn -Key 'arc_key_456' -Transport $at
Test-Condition 'arcane: environments, projects (documented agents path first, environments path as fallback) and their containers; only GET with X-Api-Key' (
  $asnap.ok -and @($asnap.stacks).Count -eq 1 -and $asnap.stacks[0].project -eq 'notes' -and $asnap.stacks[0].status -eq 'running' -and @($asnap.stacks[0].containers).Count -eq 1 -and
  @($calls | Where-Object { $_.Url -match '/api/agents/0/projects' }).Count -eq 1 -and -not @($calls | Where-Object { $_.Method -ne 'GET' -or $_.Header -ne 'arc_key_456' }).Count) (($calls | ForEach-Object { $_.Url }) -join ', ')
$arcAgents = @{ '/api/environments' = @{ data = @(@{ id = '0' }) }; '/api/agents/0/projects' = @(@{ name = 'Blog'; status = 'stopped' }); '/api/agents/0/containers' = @() }
$asnap2 = Get-ManagerSnapshot -Connector $aconn -Key 'k2-arcane-key' -Transport (& $mkTransport $arcAgents 'k2-arcane-key' 'X-Api-Key')
Test-Condition 'arcane: plain arrays on the documented /api/agents/{id}/projects path are read too' ($asnap2.ok -and $asnap2.stacks[0].project -eq 'blog' -and $asnap2.stacks[0].status -eq 'stopped') ($asnap2 | ConvertTo-Json -Depth 5 -Compress)

# --- Part 1c: ownership and drift with API evidence -------------------------------------------------------------------------
$dockerPortainer = [ordered]@{ id = 'portainer'; label = 'Portainer'; confidence = 'likely'; evidence = @("Compose working folder '/data/compose/3'") }
$dockerCompose = [ordered]@{ id = 'compose'; label = 'Docker Compose'; confidence = 'certain'; evidence = @("Compose project 'wiki'") }
$dockerArcane = [ordered]@{ id = 'arcane'; label = 'Arcane'; confidence = 'certain'; evidence = @('label com.getarcaneapp.project') }
$confirmed = Resolve-ManagerAuthority $dockerPortainer 'wiki' @($snap)
$upgraded = Resolve-ManagerAuthority $dockerCompose 'wiki' @($snap)
$conflict = Resolve-ManagerAuthority $dockerArcane 'wiki' @($snap)
$none = Resolve-ManagerAuthority $dockerCompose 'unknown-project' @($snap, $asnap)
$offline = Resolve-ManagerAuthority $dockerPortainer 'wiki' @($down)
Test-Condition 'ownership: the API confirms Docker''s guess (evidence from both), names the owner of a plain Compose project, reports a conflict when labels and the API disagree, and changes nothing when no API knows the project or the API is down' (
  $confirmed.confidence -eq 'confirmed' -and ($confirmed.evidence -join ' ') -match 'Portainer API: stack' -and ($confirmed.evidence -join ' ') -match '/data/compose/3' -and $upgraded.id -eq 'portainer' -and
  $conflict.id -eq 'conflict' -and $conflict.confidence -eq 'conflict' -and $none.id -eq 'compose' -and $offline.confidence -eq 'likely') "$($confirmed.confidence) $($upgraded.id) $($conflict.id) $($none.id) $($offline.confidence)"
$oldAuth = Resolve-ManagerAuthority $dockerCompose 'old' @($snap)
$fStopped = @(Get-ManagerDriftFindings 'old' $oldAuth @($snap) ([ordered]@{ name = 'old-app-1'; state = 'running' }))
$fUnknown = @(Get-ManagerDriftFindings 'wiki' $confirmed @($snap) ([ordered]@{ name = 'wiki-web-2'; state = 'running' }))
$fConflict = @(Get-ManagerDriftFindings 'wiki' $conflict @($snap) $null)
$fDown = @(Get-ManagerDriftFindings 'wiki' $offline @($down) $null)
Test-Condition 'drift with API evidence: stack stopped in the manager while its container runs, a recreated container the manager does not list, conflicting owners, API unavailable; every repair is advice for the owner (never automatic)' (
  @($fStopped | Where-Object { $_.id -eq 'manager-status-mismatch' }).Count -and @($fUnknown | Where-Object { $_.id -eq 'manager-container-unknown' }).Count -and @($fConflict | Where-Object { $_.id -eq 'ownership-conflict' }).Count -and
  @($fDown | Where-Object { $_.id -eq 'manager-unavailable' -and $_.severity -eq 'info' }).Count -and -not @(@($fStopped) + @($fUnknown) + @($fConflict) | Where-Object { $_.repair -and ($_.repair.automatic -or $_.repair.owner -ne 'external') }).Count) ''
$dockerOnly = Get-ManagementAuthority ([ordered]@{ name = 'wiki-web-1'; compose = [ordered]@{ project = 'wiki'; service = 'web'; workingDir = '/data/compose/3'; configFiles = '' }; authorityHints = @() })
Test-Condition 'fallback: without connectors, Docker-only detection is unchanged' ($dockerOnly.id -eq 'portainer' -and $dockerOnly.confidence -eq 'likely') ($dockerOnly | ConvertTo-Json -Compress)

# --- Part 2: web API with a loopback mock speaking the Portainer API ------------------------------------------------------
if ($SkipApi) { Add-Result 'SKIP' 'web API' '-SkipApi' }
else {
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
  $work = Join-Path ([IO.Path]::GetTempPath()) "tpm-em-$id"
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $ui = $null; $mock = $null; $job = $null
  $mockPort = Get-FreeTcpPort
  $mockKey = 'ptr_' + [Guid]::NewGuid().ToString('N')
  try {
    $stacksJson = (@(@{ Id = 7; Name = 'mockstack'; EndpointId = 1; Status = 1; ProjectPath = '/data/compose/7' }) | ConvertTo-Json -Compress -Depth 4)
    $job = Start-Job -ArgumentList $mockPort, $mockKey, $stacksJson -ScriptBlock {
      param($port, $key, $stacks)
      $l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port); $l.Start()
      $deadline = (Get-Date).AddMinutes(5)
      while ((Get-Date) -lt $deadline) {
        if (-not $l.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $c = $l.AcceptTcpClient(); $s = $c.GetStream(); $r = New-Object IO.StreamReader($s)
        $first = $r.ReadLine(); $hdr = @{}
        while (($line = $r.ReadLine()) -and $line -ne '') { $i = $line.IndexOf(':'); if ($i -gt 0) { $hdr[$line.Substring(0, $i).Trim().ToLowerInvariant()] = $line.Substring($i + 1).Trim() } }
        $method, $path = ($first -split ' ')[0, 1]
        $status = 404; $body = '{}'
        if ($method -ne 'GET') { $status = 405 }
        elseif ($hdr['x-api-key'] -ne $key) { $status = 401; $body = '{"message":"Unauthorized"}' }
        elseif ($path -eq '/api/stacks') { $status = 200; $body = $stacks }
        elseif ($path -like '/api/endpoints/1/docker/containers/json*') { $status = 200; $body = '[]' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status X`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
        $s.Write($head, 0, $head.Length); $s.Write($bytes, 0, $bytes.Length); $s.Flush(); $c.Close()
        Add-Content -LiteralPath (Join-Path $env:TEMP "tpm-em-mock-$port.log") -Value "$method $path"
      }
      $l.Stop()
    }
    $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-em-$id" -Subnet '172.31.243.0/28'
    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token 'cf-test-token'
    $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
    $null = Connect-WebUi $ui
    $e0 = Invoke-WebUi $ui GET '/api/managers'
    Test-Condition 'api: no connector by default (optional); both kinds described with their scope limits' ($e0.Status -eq 200 -and -not @($e0.Data.connectors).Count -and $e0.Data.kinds.portainer.scopeNote) $e0.Body
    $noConfirm = Invoke-WebUi $ui POST '/api/managers/save' @{ kind = 'portainer'; url = "http://127.0.0.1:$mockPort"; key = $mockKey }
    $badUrl = Invoke-WebUi $ui POST '/api/managers/save' @{ kind = 'portainer'; url = 'http://portainer.example.com'; key = $mockKey; confirm = $true }
    $sv = Invoke-WebUi $ui POST '/api/managers/save' @{ kind = 'portainer'; url = "http://127.0.0.1:$mockPort"; key = $mockKey; confirm = $true }
    $cfgPath = Join-Path $install 'config\managers.json'; $cfgText = $(if (Test-Path -LiteralPath $cfgPath) { [IO.File]::ReadAllText($cfgPath) } else { '' })
    $list = Invoke-WebUi $ui GET '/api/managers'
    Test-Condition 'api: saving needs confirmation and a safe address; the key is stored with DPAPI, never in managers.json or any response' ($noConfirm.Status -ge 400 -and $badUrl.Status -eq 400 -and $sv.Status -eq 200 -and $cfgText -notmatch [regex]::Escape($mockKey) -and $list.Data.connectors[0].keyStored -and $list.Body -notmatch [regex]::Escape($mockKey) -and (Test-Path -LiteralPath (Join-Path $install 'secrets\manager-portainer-api.dpapi'))) "$($noConfirm.Status) $($badUrl.Status) $($sv.Status) $($sv.Body)"
    $t = Invoke-WebUi $ui POST '/api/managers/test' @{ id = 'portainer' }
    Test-Condition 'api: testing the connector reads the stacks over real HTTP (GET with the stored key)' ($t.Status -eq 200 -and $t.Data.ok -and $t.Data.stacks[0].name -eq 'mockstack' -and $t.Data.stacks[0].status -eq 'active') $t.Body
    $sv2 = Invoke-WebUi $ui POST '/api/managers/save' @{ id = 'portainer'; kind = 'portainer'; url = "http://127.0.0.1:$mockPort"; key = 'wrong-key-0000'; confirm = $true }
    $t2 = Invoke-WebUi $ui POST '/api/managers/test' @{ id = 'portainer' }
    Test-Condition 'api: a replaced key that the server refuses is reported as refused or expired' ($sv2.Status -eq 200 -and -not $t2.Data.ok -and $t2.Data.error -eq 'unauthorized') $t2.Body
    $sv3 = Invoke-WebUi $ui POST '/api/managers/save' @{ id = 'arc-down'; kind = 'arcane'; url = "http://127.0.0.1:$(Get-FreeTcpPort)"; key = 'arcane-key-1234'; confirm = $true }
    $t3 = Invoke-WebUi $ui POST '/api/managers/test' @{ id = 'arc-down' }
    Test-Condition 'api: an unreachable connector is reported, nothing fails' ($sv3.Status -eq 200 -and $t3.Status -eq 200 -and $t3.Data.error -eq 'unreachable') $t3.Body
    $mockLog = Join-Path $env:TEMP "tpm-em-mock-$mockPort.log"
    $methods = @(Get-Content -LiteralPath $mockLog -ErrorAction SilentlyContinue | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique)
    Test-Condition 'api: the mock server only ever received GET requests' ($methods.Count -ge 1 -and -not @($methods | Where-Object { $_ -ne 'GET' }).Count) ($methods -join ',')
    $del = Invoke-WebUi $ui POST '/api/managers/delete' @{ id = 'portainer'; confirm = $true }
    Test-Condition 'api: deleting a connector removes its stored key' ($del.Status -eq 200 -and -not (Test-Path -LiteralPath (Join-Path $install 'secrets\manager-portainer-api.dpapi'))) $del.Body
    $logs = @(Get-ChildItem -LiteralPath $install -Recurse -File -Include '*.log', '*.jsonl', 'audit*' -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Test-Condition 'api: no key value in the audit log or any log file' ($logs -notmatch [regex]::Escape($mockKey) -and $logs -notmatch 'arcane-key-1234') ''
    Remove-Item -LiteralPath $mockLog -Force -ErrorAction SilentlyContinue
  } finally {
    if ($ui) { Stop-TestServer $ui }
    if ($mock) { Stop-TestServer $mock }
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count) { exit 1 }
