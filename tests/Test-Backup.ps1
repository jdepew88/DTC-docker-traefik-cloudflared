#requires -version 5.1
<#
.SYNOPSIS
  Regression tests for portable configuration backups: export, import, restore, recovery points.

.DESCRIPTION
  Uses two never-started instance folders in %TEMP% and the Cloudflare API mock (no real Cloudflare, no container
  is started; Traefik validation runs in throwaway network-less containers as for every apply):
    - JSON and ZIP export: contents, inventory, credential exclusion (API token, tunnel token, secrets\, unknown
      .env keys), nothing from other applications or instances on this PC; exports that would contain a credential
      are refused
    - version compatibility: schema 1, a minimal schema-1 manifest, a plain services.json of an earlier version,
      a newer schema, foreign formats, invalid JSON / zip, credentials inside an import, unsafe zip entry names
    - restore round trip into a new folder (after a "manager upgrade"): verification of Cloudflare ids, adoption of
      verified ids only, separate local and Cloudflare approvals, the export of the restored instance matches
    - restore idempotency: a second restore changes nothing and Cloudflare resources are never duplicated; a
      missing DNS record is recreated once; an existing record is only overwritten after confirmation
    - authorization failures: no token, a token without tunnel permission
    - recovery points before changes (protected, listed, downloadable, restorable)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Backup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $repo 'lib\Dashboard.psm1') -Force
Import-Module (Join-Path $repo 'lib\ConfigBackup.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail }
}
function Short($r) { if ($null -eq $r) { return '(no response)' }; return "HTTP $($r.Status) $($r.Body.Substring(0, [Math]::Min(600, $r.Body.Length)))" }
function Read-Zip([byte[]]$Bytes) {
  $map = [ordered]@{}
  $zip = New-Object System.IO.Compression.ZipArchive((New-Object System.IO.MemoryStream(, $Bytes)), [System.IO.Compression.ZipArchiveMode]::Read)
  try { foreach ($e in $zip.Entries) { $r = New-Object IO.StreamReader($e.Open()); $map[$e.FullName] = $r.ReadToEnd(); $r.Dispose() } } finally { $zip.Dispose() }
  return $map
}
function New-Zip([hashtable]$Entries) {
  $ms = New-Object System.IO.MemoryStream
  $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
  foreach ($k in $Entries.Keys) { $w = New-Object IO.StreamWriter($zip.CreateEntry($k).Open()); $w.Write($Entries[$k]); $w.Dispose() }
  $zip.Dispose()
  return $ms.ToArray()
}
function Import-Preview($Server, [byte[]]$Bytes, [string]$Name, $Extra = @{}) {
  $body = @{ fileName = $Name; contentBase64 = [Convert]::ToBase64String($Bytes) }
  foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] }
  return Invoke-WebUi $Server POST '/api/backups/import/preview' $body
}
function Get-Writes { return @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' -and $_.path -notmatch '/_state$' }) }
function Get-DockerNames { return @((Invoke-Docker ps -a --format '{{.ID}} {{.Names}} {{.State}}').Output | Where-Object { $_ } | Sort-Object) }
function Get-Comparable($Manifest) {
  # The parts of a manifest that must survive a round trip.
  return ConvertTo-Json -Compress -Depth 12 -InputObject ([ordered]@{
      instance = $Manifest.instance; services = $Manifest.services; routes = $Manifest.routes
      cloudflare = $Manifest.cloudflare; dashboard = $Manifest.dashboard; customFiles = $Manifest.middlewares.customFiles
    })
}

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpx-backup-$id"
$pathA = Join-Path $work 'a'
$pathB = Join-Path $work 'b-after-upgrade'
$stack = "tpx-bk-$id"
$acct = 'acc0000000000000000000000000001'
$tunnel = '11111111-2222-3333-4444-555555555555'
$zone1 = 'zone00000000000000000000000000001'
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$fakeTunnelToken = 'eyJhIjoiYWNjMDAwIiwidCI6IjExMTExMTExIiwicyI6Im5vdC1yZWFsLXNlY3JldC0wMTIzNDU2Nzg5In0='
New-Item -ItemType Directory -Force -Path $work | Out-Null
$mock = $null; $uiA = $null; $uiB = $null

try {
  $dockerBefore = Get-DockerNames
  $null = New-TestInstance -Repo $repo -Path $pathA -StackName $stack
  # Things that must never be exported.
  New-Item -ItemType Directory -Force -Path (Join-Path $pathA 'secrets'), (Join-Path $pathA 'logs') | Out-Null
  [IO.File]::WriteAllText((Join-Path $pathA 'secrets\cloudflare_tunnel_token'), $fakeTunnelToken)
  [IO.File]::AppendAllText((Join-Path $pathA '.env'), "EXTRA_API_KEY=sk_live_0123456789abcdefghij`n")
  [IO.File]::WriteAllText((Join-Path $pathA 'logs\webui-audit.log'), "something`n")
  [IO.File]::WriteAllText((Join-Path $pathA 'traefik\dynamic\custom-mw.yml'), "http:`n  middlewares:`n    my-mw:`n      headers:`n        frameDeny: true`n")

  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $uiA = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $pathA -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui-a')).FullName -ApiBase $mock.Base
  $null = Connect-WebUi $uiA
  $null = Invoke-WebUi $uiA POST '/api/cloudflare/token' @{ token = $apiToken }
  $null = Invoke-WebUi $uiA POST '/api/cloudflare/select' @{ accountId = $acct; tunnelId = $tunnel }
  $null = Invoke-WebUi $uiA POST '/api/cloudflare/domains' @{ zoneIds = @($zone1) }
  $rpBefore = @((Invoke-WebUi $uiA GET '/api/backups').Data.recoveryPoints).Count
  $add = Invoke-WebUiChange $uiA @{ op = 'add'; name = 'web1'
    service = @{ name = 'web1'; hostnames = @('web1.example.test'); target = @{ type = 'lan'; host = '10.20.0.5'; port = 8080; protocol = 'http' }; middlewares = @('default-headers@file', 'my-mw@file'); cloudflare = @{ publish = $true; access = $true } }
    cloudflare = @{ automate = $true; accessEmails = @('owner@example.com') } }
  $add2 = Invoke-WebUiChange $uiA @{ op = 'add'; name = 'local1'
    service = @{ name = 'local1'; hostnames = @('local1.example.test'); target = @{ type = 'lan'; host = '10.20.0.6'; port = 80; protocol = 'http' }; cloudflare = @{ publish = $false; access = $false } }
    cloudflare = @{ automate = $false } }
  Test-Condition 'setup: two services applied on instance A (Access, tunnel route and DNS created in the mock)' ($add.Apply.Status -eq 200 -and $add.Apply.Data.ok -and $add2.Apply.Status -eq 200) "$(Short $add.Apply) $(Short $add2.Apply)"
  $backupsA = (Invoke-WebUi $uiA GET '/api/backups').Data
  Test-Condition 'recovery point written before each applied change (protected)' (@($backupsA.recoveryPoints).Count -eq $rpBefore + 2 -and @($backupsA.recoveryPoints | Where-Object { -not $_.protected }).Count -eq 0 -and
    (Get-Item -LiteralPath (Join-Path $pathA "backups\recovery\$(@($backupsA.recoveryPoints)[0].id)")).IsReadOnly) ($backupsA | ConvertTo-Json -Depth 4 -Compress)
  $stateA = Get-MockState $mock
  $appCount = @($stateA.apps | Where-Object { $_.domain -eq 'web1.example.test' }).Count
  $dnsCount = @($stateA.dns | Where-Object { $_.name -eq 'web1.example.test' }).Count

  # --- Export ------------------------------------------------------------------------------------------------------
  $j = Invoke-WebUiDownload $uiA '/api/backups/export?format=json'
  $jsonText = [Text.Encoding]::UTF8.GetString($j.Bytes)
  $m = $jsonText | ConvertFrom-Json
  Test-Condition 'export .json: download with a versioned file name' ($j.Status -eq 200 -and $j.Disposition -match "attachment; filename=`"traefik-proxy-$stack-\d{8}-\d{6}\.json`"" -and $j.ContentType -match 'application/json') "$($j.Status) $($j.Disposition)"
  Test-Condition 'export .json: format, schema version and manager version' ($m.format -eq 'traefik-proxy-config' -and $m.schemaVersion -eq 1 -and $m.managerVersion -eq (Get-ManagerVersion)) $jsonText.Substring(0, 300)
  $h = @($m.cloudflare.hostnames | Where-Object { $_.hostname -eq 'web1.example.test' })
  Test-Condition 'export .json: instance, Docker, Cloudflare ids, hostnames, routes, middlewares, services' (
    $m.instance.STACK_NAME -eq $stack -and $m.docker.containers.traefik -eq "$stack-traefik" -and $m.docker.images.traefik -match '^traefik:v3' -and
    $m.cloudflare.accountId -eq $acct -and $m.cloudflare.tunnelId -eq $tunnel -and @($m.cloudflare.domains | Where-Object { $_.id -eq $zone1 }).Count -eq 1 -and
    $h.Count -eq 1 -and $h[0].dnsRecordId -and $h[0].accessAppId -and @($h[0].accessEmails) -contains 'owner@example.com' -and
    @($m.services).Count -eq 2 -and @($m.routes | Where-Object { $_.rule -eq 'Host(`web1.example.test`)' }).Count -eq 1 -and
    @($m.middlewares.available) -contains 'my-mw@file' -and @($m.middlewares.customFiles) -contains 'custom-mw.yml') $jsonText
  Test-Condition 'export .json: credentials listed as not included' (@($m.credentials).Count -eq 2 -and @($m.credentials | Where-Object { $_.included }).Count -eq 0 -and
    @($m.credentials | Where-Object { $_.id -eq 'tunnel-connector-token' -and $_.present }).Count -eq 1) ($m.credentials | ConvertTo-Json -Compress)
  $leaks = @($apiToken, $fakeTunnelToken, 'eyJ', 'sk_live_', 'EXTRA_API_KEY=', '"data"') | Where-Object { $jsonText.Contains($_) }
  Test-Condition 'export .json: no API token, tunnel token, unknown .env values or DPAPI data (left-out keys named only)' (@($leaks).Count -eq 0 -and @($m.omittedEnvKeys) -contains 'EXTRA_API_KEY') ($leaks -join ', ')
  # Container names that are plain role words (traefik, cloudflared, ...) also occur in this instance's own names.
  $others = @((Invoke-Docker ps -a --format '{{.Names}}').Output | Where-Object { $_ -and -not $_.StartsWith($stack) -and $_ -notin @('traefik', 'socket-proxy', 'cloudflared', 'whoami') })
  $foreign = @($others | Where-Object { $jsonText.Contains($_) })
  Test-Condition "export .json: nothing from the $($others.Count) other containers on this engine (or OmniVoice)" ($foreign.Count -eq 0 -and $jsonText -notmatch '(?i)omnivoice') ($foreign -join ', ')

  $z = Invoke-WebUiDownload $uiA '/api/backups/export?format=zip'
  $entries = Read-Zip $z.Bytes
  $zm = $entries['manifest.json'] | ConvertFrom-Json
  Test-Condition 'export .zip: manifest, inventory and this instance''s configuration files' ($z.Status -eq 200 -and $z.Disposition -match '\.zip"' -and
    $entries.Contains('manifest.json') -and $entries.Contains('INVENTORY.txt') -and $entries.Contains('files/config/services.json') -and $entries.Contains('files/config/cloudflare.json') -and
    $entries.Contains('files/traefik/dynamic/svc-web1.yml') -and $entries.Contains('files/traefik/dynamic/custom-mw.yml') -and $entries.Contains('files/.env') -and
    @($zm.archive.files).Count -eq (@($entries.Keys).Count - 2)) (@($entries.Keys) -join ', ')
  $zipText = (@($entries.Values) -join "`n")
  $zipLeaks = @($apiToken, $fakeTunnelToken, 'eyJ', 'sk_live_', 'EXTRA_API_KEY=') | Where-Object { $zipText.Contains($_) }
  Test-Condition 'export .zip: no secrets\, logs\ or backups\ entries and no credentials in any file' (@($entries.Keys | Where-Object { $_ -match '(^|/)(secrets|logs|backups)/' }).Count -eq 0 -and @($zipLeaks).Count -eq 0 -and
    @($zm.archive.excluded | Where-Object { $_.path -eq 'secrets\' }).Count -eq 1 -and $entries['INVENTORY.txt'] -match 'Credentials to reconnect') (($zipLeaks -join ', ') + ' ' + (@($entries.Keys) -join ', '))

  # Exports that would contain a credential are refused; a credential-like hand-written file is left out of the zip.
  $tmpS = Join-Path $work 'secret-desc'
  $null = New-TestInstance -Repo $repo -Path $tmpS -StackName "$stack-s"
  $sS = Get-StackSettings -InstallPath $tmpS
  $svc = New-ServiceDefinition -Name 'leaky' -Hostname 'leaky.example.test' -TargetType lan -TargetHost '10.0.0.9' -Port 80 -Description 'admin password=Sup3rSecretValue123456'
  [IO.File]::WriteAllText($sS.RegistryPath, (ConvertTo-RegistryJson @($svc)))
  $refused = $null
  try { $null = Export-ConfigManifest -Settings $sS -SourceRoot $repo } catch { $refused = $_.Exception.Message }
  Test-Condition 'export refused when a field looks like a credential' ($refused -match 'Export refused') "$refused"
  [IO.File]::WriteAllText($sS.RegistryPath, (ConvertTo-RegistryJson @()))
  [IO.File]::WriteAllText((Join-Path $tmpS 'traefik\dynamic\auth.yml'), "http:`n  middlewares:`n    basic:`n      basicAuth:`n        users: ['x']`n# api_key: abcdefghijklmnop1234`n")
  $arch = New-ConfigBackupArchive -Settings $sS -SourceRoot $repo
  $archEntries = Read-Zip $arch.Bytes
  Test-Condition 'export .zip: a credential-like file is left out and listed' (-not $archEntries.Contains('files/traefik/dynamic/auth.yml') -and @($arch.Excluded | Where-Object { $_.path -eq 'traefik\dynamic\auth.yml' }).Count -eq 1) (@($archEntries.Keys) -join ', ')

  # --- Version compatibility and validation ------------------------------------------------------------------------
  $enc = [Text.Encoding]::UTF8
  $r = Import-Preview $uiA $enc.GetBytes('{"format":"traefik-proxy-config","schemaVersion":2,"managerVersion":"9.0.0","services":[]}') 'future.json'
  Test-Condition 'import: a newer schema is refused with an upgrade hint' ($r.Status -eq 400 -and $r.Data.error -match 'newer manager \(schema 2') (Short $r)
  $r = Import-Preview $uiA $enc.GetBytes('{"hello":"world"}') 'other.json'
  Test-Condition 'import: a foreign JSON file is refused' ($r.Status -eq 400 -and $r.Data.error -match 'not a traefik-proxy configuration backup') (Short $r)
  $r = Import-Preview $uiA $enc.GetBytes('{not json') 'broken.json'
  Test-Condition 'import: invalid JSON is refused' ($r.Status -eq 400 -and $r.Data.error -match 'not valid JSON') (Short $r)
  $r = Import-Preview $uiA $enc.GetBytes(($jsonText -replace '"services": \[', ('"note": "' + $fakeTunnelToken + '", "services": ['))) 'with-secret.json'
  Test-Condition 'import: a backup containing a credential is refused' ($r.Status -eq 400 -and $r.Data.error -match 'looks like a Cloudflare tunnel token') (Short $r)
  $r = Import-Preview $uiA (New-Zip @{ 'manifest.json' = $jsonText; '../evil.yml' = 'x' }) 'evil.zip'
  Test-Condition 'import: unsafe zip entry names are refused' ($r.Status -eq 400 -and $r.Data.error -match 'Unexpected file name') (Short $r)
  $r = Import-Preview $uiA (New-Zip @{ 'readme.txt' = 'x' }) 'nomanifest.zip'
  Test-Condition 'import: a zip without manifest.json is refused' ($r.Status -eq 400 -and $r.Data.error -match 'no manifest.json') (Short $r)
  $legacy = [IO.File]::ReadAllBytes((Join-Path $pathA 'config\services.json'))
  $r = Import-Preview $uiA $legacy 'services.json'
  Test-Condition 'import: a plain services.json of an earlier version is accepted (services only)' ($r.Status -eq 200 -and $r.Data.source.kind -eq 'legacy-services' -and -not $r.Data.local.hasWork -and
    $r.Data.cloudflare.message -match 'no Cloudflare information') (Short $r)
  $minimal = '{"format":"traefik-proxy-config","schemaVersion":1,"instance":{"STACK_NAME":"' + $stack + '"},"services":[],"futureField":{"x":1}}'
  $r = Import-Preview $uiA $enc.GetBytes($minimal) 'minimal.json'
  Test-Condition 'import: a minimal schema-1 manifest with unknown fields is accepted' ($r.Status -eq 200 -and @($r.Data.local.items | Where-Object { $_.area -eq 'services' -and $_.action -eq 'update' }).Count -eq 1) (Short $r)
  $r = Import-Preview $uiA $z.Bytes 'same.zip'
  Test-Condition 'import into the same instance: nothing to change' ($r.Status -eq 200 -and -not $r.Data.local.hasWork -and -not $r.Data.cloudflare.hasWork) (Short $r)

  # --- Round trip into a new folder (a reinstall / manager upgrade) --------------------------------------------------
  $uiB = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $pathB -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui-b')).FullName -ApiBase $mock.Base
  $null = Connect-WebUi $uiB
  $writesBefore = @(Get-Writes).Count
  $p = Import-Preview $uiB $z.Bytes 'backup.zip'
  Test-Condition 'restore preview without a token: local part ready, Cloudflare not verified, credentials to reconnect' ($p.Status -eq 200 -and $p.Data.local.canApply -and -not $p.Data.cloudflare.connected -and
    $p.Data.cloudflare.message -match 'Connect Cloudflare' -and @($p.Data.credentials | Where-Object { -not $_.present }).Count -eq 2 -and
    @($p.Data.actions | Where-Object { $_ -match 'not adopted' }).Count -eq 1 -and -not (Test-Path -LiteralPath $pathB)) (Short $p)
  $tok = Invoke-WebUi $uiB POST '/api/cloudflare/token' @{ token = $apiToken }
  $p = Import-Preview $uiB $z.Bytes 'backup.zip'
  $reviewStates = @($p.Data.review | Where-Object { $_.stage -eq 'validated' -and $_.label -match 'account|tunnel|DNS record|Access application' } | ForEach-Object { $_.state })
  Test-Condition 'restore preview with the token: account, tunnel, DNS record and Access app verified' ($tok.Status -eq 200 -and $p.Status -eq 200 -and $p.Data.cloudflare.connected -and
    $reviewStates.Count -ge 4 -and @($reviewStates | Where-Object { $_ -ne 'ok' }).Count -eq 0) (Short $p)
  $cfItem = @($p.Data.local.items | Where-Object { $_.area -eq 'cloudflare' })
  Test-Condition 'restore preview: Cloudflare selections and verified ids are adopted; all Cloudflare resources already exist' ($cfItem.Count -eq 1 -and $cfItem[0].action -in @('create', 'update') -and
    ((@($cfItem[0].diff) -join "`n") -match 'accessAppId') -and -not $p.Data.cloudflare.hasWork -and $p.Data.cloudflare.needsLocal) (Short $p)
  $r = Invoke-WebUi $uiB POST '/api/backups/import/apply' @{ importId = $p.Data.importId; part = 'cloudflare'; confirm = $true }
  Test-Condition 'restore: the Cloudflare part cannot run before the local part' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $uiB POST '/api/backups/import/apply' @{ importId = $p.Data.importId; part = 'local' }
  Test-Condition 'restore: the local part needs explicit confirmation' ($r.Status -eq 400 -and -not (Test-Path -LiteralPath (Join-Path $pathB 'config\services.json'))) (Short $r)
  $r = Invoke-WebUi $uiB POST '/api/backups/import/apply' @{ importId = $p.Data.importId; part = 'local'; confirm = $true }
  $draftB = [IO.File]::ReadAllText((Join-Path $pathB 'config\setup.json')) | ConvertFrom-Json
  $cfB = [IO.File]::ReadAllText((Join-Path $pathB 'config\cloudflare.json')) | ConvertFrom-Json
  Test-Condition 'restore local: configuration written, no .env, setup draft points at the existing tunnel' ($r.Status -eq 200 -and $r.Data.result.ok -and $r.Data.result.recoveryPoint -and
    -not (Test-Path -LiteralPath (Join-Path $pathB '.env')) -and $draftB.settings.STACK_NAME -eq $stack -and $draftB.deployment.tunnelChoice -eq 'existing' -and $draftB.deployment.tunnelId -eq $tunnel -and
    $cfB.accountId -eq $acct -and $cfB.tunnelId -eq $tunnel -and $cfB.managed.'web1.example.test'.accessAppId -and
    (Test-Path -LiteralPath (Join-Path $pathB 'traefik\dynamic\svc-web1.yml')) -and (Test-Path -LiteralPath (Join-Path $pathB 'traefik\dynamic\custom-mw.yml')) -and
    -not (Test-Path -LiteralPath (Join-Path $pathB 'secrets\cloudflare_tunnel_token'))) (Short $r)
  Test-Condition 'restore local: afterwards nothing is left to do (idempotent)' (-not $r.Data.local.hasWork -and -not $r.Data.cloudflare.hasWork -and -not $r.Data.cloudflare.needsLocal) (Short $r)
  $setupB = (Invoke-WebUi $uiB GET '/api/setup').Data
  Test-Condition 'after the restore the Setup page continues at "Review and install" (no onboarding again)' ($setupB.settingsSource -eq 'draft' -and $setupB.deployment.mode -eq 'tunnel' -and
    $setupB.deployment.tunnelId -eq $tunnel -and @($setupB.cloudflare.domains).Count -eq 1 -and -not $setupB.installed) ($setupB | ConvertTo-Json -Depth 3 -Compress)
  $ej = Invoke-WebUiDownload $uiB '/api/backups/export?format=json'
  $mB = [Text.Encoding]::UTF8.GetString($ej.Bytes) | ConvertFrom-Json
  Test-Condition 'round trip: the restored instance exports the same configuration' ((Get-Comparable $mB) -eq (Get-Comparable $m)) "A: $(Get-Comparable $m)`nB: $(Get-Comparable $mB)"
  Test-Condition 'round trip: no Cloudflare writes, nothing duplicated' (@(Get-Writes).Count -eq $writesBefore -and @((Get-MockState $mock).apps | Where-Object { $_.domain -eq 'web1.example.test' }).Count -eq $appCount -and
    @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'web1.example.test' }).Count -eq $dnsCount) "writes $(@(Get-Writes).Count - $writesBefore)"

  # --- Idempotency with Cloudflare work, overwrite protection ------------------------------------------------------
  $rec = @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'web1.example.test' })[0]
  $null = Invoke-RestMethod -Method Delete -Uri "$($mock.Base)/zones/$zone1/dns_records/$($rec.id)" -Headers @{ Authorization = "Bearer $apiToken" }
  $p = Import-Preview $uiB $z.Bytes 'backup.zip'
  $dnsAct = @($p.Data.cloudflare.actions | Where-Object { $_.step -eq 'dns' -and $_.hostname -eq 'web1.example.test' })
  $accAct = @($p.Data.cloudflare.actions | Where-Object { $_.step -eq 'access' -and $_.hostname -eq 'web1.example.test' })
  Test-Condition 'restore preview: a deleted DNS record is detected and planned once; the Access app is reused' ($dnsAct.Count -eq 1 -and $dnsAct[0].kind -eq 'create' -and $accAct.Count -eq 1 -and $accAct[0].kind -eq 'none' -and
    $p.Data.cloudflare.canApply -and @($p.Data.review | Where-Object { $_.label -match 'DNS record of web1' -and $_.state -eq 'warning' }).Count -eq 1) (Short $p)
  $r = Invoke-WebUi $uiB POST '/api/backups/import/apply' @{ importId = $p.Data.importId; part = 'cloudflare' }
  Test-Condition 'restore Cloudflare: needs its own confirmation' ($r.Status -eq 400 -and @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'web1.example.test' }).Count -eq 0) (Short $r)
  $r = Invoke-WebUi $uiB POST '/api/backups/import/apply' @{ importId = $p.Data.importId; part = 'cloudflare'; confirm = $true }
  Test-Condition 'restore Cloudflare: the missing record is created, nothing else' ($r.Status -eq 200 -and $r.Data.result.ok -and @($r.Data.result.steps).Count -eq 1 -and
    @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'web1.example.test' }).Count -eq 1 -and @((Get-MockState $mock).apps | Where-Object { $_.domain -eq 'web1.example.test' }).Count -eq $appCount) (Short $r)
  $p2 = Import-Preview $uiB $z.Bytes 'backup.zip'
  Test-Condition 'restore again: nothing to change, no duplicates' ($p2.Status -eq 200 -and -not $p2.Data.local.hasWork -and -not $p2.Data.cloudflare.hasWork) (Short $p2)
  $rec = @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'web1.example.test' })[0]
  $null = Invoke-RestMethod -Method Put -Uri "$($mock.Base)/zones/$zone1/dns_records/$($rec.id)" -Headers @{ Authorization = "Bearer $apiToken" } -ContentType 'application/json' -Body '{"type":"CNAME","name":"web1.example.test","content":"elsewhere.example.net","proxied":true}'
  $p = Import-Preview $uiB $z.Bytes 'backup.zip'
  $ov = @($p.Data.cloudflare.actions | Where-Object { $_.overwrite })
  $r = Invoke-WebUi $uiB POST '/api/backups/import/apply' @{ importId = $p.Data.importId; part = 'cloudflare'; confirm = $true }
  $still = @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'web1.example.test' })[0].content
  Test-Condition 'restore Cloudflare: a changed DNS record is only overwritten after a per-record confirmation' ($ov.Count -eq 1 -and $r.Status -eq 400 -and $r.Data.error -match 'Confirm each overwrite' -and $still -eq 'elsewhere.example.net') (Short $r)
  $r = Invoke-WebUi $uiB POST '/api/backups/import/apply' @{ importId = $p.Data.importId; part = 'cloudflare'; confirm = $true; confirmOverwrites = @($ov[0].id) }
  $now = @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'web1.example.test' })
  Test-Condition 'restore Cloudflare: overwrite confirmed -> record points at the tunnel again' ($r.Status -eq 200 -and $now.Count -eq 1 -and $now[0].content -eq "$tunnel.cfargotunnel.com") (Short $r)

  # --- Restore into an instance with other settings -------------------------------------------------------------
  $envBefore = [IO.File]::ReadAllText((Join-Path $pathA '.env'))
  $other = $jsonText -replace ('"STACK_NAME": "' + [regex]::Escape($stack) + '"'), '"STACK_NAME": "some-other-instance"'
  $p = Import-Preview $uiA $enc.GetBytes($other) 'other-instance.json'
  Test-Condition 'restore into an installed instance with other settings: its .env is kept' ($p.Status -eq 200 -and @($p.Data.local.items | Where-Object { $_.area -eq 'instance' -and $_.action -eq 'keep' }).Count -eq 1 -and
    [IO.File]::ReadAllText((Join-Path $pathA '.env')) -eq $envBefore) (Short $p)

  # --- Authorization failures ------------------------------------------------------------------------------------
  $noTunnel = 'mockNoTunnel_' + [Guid]::NewGuid().ToString('N')
  $null = Invoke-WebUi $uiB POST '/api/cloudflare/token' @{ token = $noTunnel; confirmReplace = $true }
  $p = Import-Preview $uiB $z.Bytes 'backup.zip'
  Test-Condition 'authorization: a token without tunnel permission -> Cloudflare part not applicable, explained' ($p.Status -eq 200 -and -not $p.Data.cloudflare.connected -and -not $p.Data.cloudflare.canApply -and
    @($p.Data.review | Where-Object { $_.label -eq 'Cloudflare tunnel' -and $_.state -eq 'warning' }).Count -eq 1) (Short $p)
  $null = Invoke-WebUi $uiB POST '/api/cloudflare/token/delete' @{ confirm = $true }
  $p = Import-Preview $uiB $z.Bytes 'backup.zip'
  Test-Condition 'authorization: without a token the Cloudflare part is not applicable' ($p.Status -eq 200 -and -not $p.Data.cloudflare.canApply -and $p.Data.cloudflare.message -match 'Connect Cloudflare') (Short $p)

  # --- Recovery points -------------------------------------------------------------------------------------------
  $list = (Invoke-WebUi $uiB GET '/api/backups').Data
  $rp = @($list.recoveryPoints)
  $dl = Invoke-WebUiDownload $uiB "/api/backups/recovery/download?id=$($rp[0].id)"
  $dlEntries = Read-Zip $dl.Bytes
  Test-Condition 'recovery points: listed, downloadable as a backup zip' ($rp.Count -ge 3 -and $dl.Status -eq 200 -and $dlEntries.Contains('manifest.json')) "count $($rp.Count) HTTP $($dl.Status)"
  $r = Invoke-WebUi $uiB POST '/api/backups/import/preview' @{ recoveryId = $rp[0].id }
  Test-Condition 'recovery points: can be previewed for restore' ($r.Status -eq 200 -and $r.Data.source.fileName -eq $rp[0].id) (Short $r)
  $r = Invoke-WebUi $uiB POST '/api/backups/import/preview' @{ recoveryId = '..\..\secrets\cloudflare_api.dpapi' }
  $r2 = Invoke-WebUiDownload $uiB '/api/backups/recovery/download?id=..%5C..%5C.env'
  Test-Condition 'recovery points: ids are validated (no path traversal)' ($r.Status -eq 404 -and $r2.Status -eq 404) "$($r.Status) $($r2.Status)"
  $allBodies = (@($uiA.Bodies) + @($uiB.Bodies)) -join "`n"
  Test-Condition 'no API response contains the API token or the tunnel token' (-not $allBodies.Contains($apiToken) -and -not $allBodies.Contains($fakeTunnelToken)) ''
  Test-Condition 'no container or network was created, started or removed' (((Get-DockerNames) -join '|') -eq ($dockerBefore -join '|')) ''
} finally {
  Stop-TestServer $uiA
  Stop-TestServer $uiB
  Stop-TestServer $mock
  Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
