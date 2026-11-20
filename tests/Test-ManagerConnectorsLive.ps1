#requires -version 5.1
<#
.SYNOPSIS
  Live check of the optional Portainer / Arcane connectors (lib\ExternalManagers.psm1) against disposable instances.

.DESCRIPTION
  Starts throwaway Arcane and Portainer CE containers (the catalog's versions, fresh data volumes, loopback-only ports,
  names tpx-mgr-<id>-*), creates one small stack in each THROUGH that tool's own API (traefik/whoami), creates a
  least-privilege credential (Arcane: a key with read permissions only; Portainer: a token of a non-administrator user),
  and checks what DTC reads: stack identity, status, path and containers, the authority confirmed by the API on top of
  the Docker-label evidence, a refused key, a write refused for a read-only Arcane key, Portainer's stack sharing rule,
  and the fallback when the API is down. The user's own Portainer and Arcane are never contacted. Everything with the
  run prefix is removed afterwards and every other container is checked to be unchanged.
#>
param(
  [string]$ArcaneImage = 'getarcaneapp/manager:v2.16.1',
  [string]$PortainerImage = 'portainer/portainer-ce:2.45.2',
  [string]$StackImage = 'traefik/whoami:v1.12.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'TestResources.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WebUiTestHelpers.psm1') -Force
foreach ($m in 'TraefikProxy', 'DockerDiscovery', 'AppContract', 'ExternalManagers') { Import-Module (Join-Path $repo "lib\$m.psm1") -Force -DisableNameChecking }
Add-Type -AssemblyName System.Net.Http

$script:Pass = 0; $script:Fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { $script:Pass++; Write-Host "[PASS] $Name" -ForegroundColor Green } else { $script:Fail++; Write-Host "[FAIL] $Name  $Detail" -ForegroundColor Red } }
function Get-Fingerprint { $ids = @(Invoke-TrDocker ps -aq); if (-not $ids.Count) { return @() }; return @(Invoke-TrDocker inspect -f '{{.Name}} {{.Id}} {{.State.Status}} {{.State.StartedAt}} {{.RestartCount}}' @ids | Where-Object { $_ -notmatch '^/tp[xm]-' } | Sort-Object) }
function New-Secret { return -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) }) }
function Wait-Http([string]$Url, [int]$Seconds = 90) { $end = (Get-Date).AddSeconds($Seconds); while ((Get-Date) -lt $end) { try { $null = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3; return $true } catch { Start-Sleep -Seconds 2 } }; return $false }
function Get-HttpStatus([scriptblock]$Call) {
  try { $null = & $Call; return 200 }
  catch { $ex = $_.Exception; while ($ex) { if ($ex.PSObject.Properties['Response'] -and $ex.Response) { return [int]$ex.Response.StatusCode }; $ex = $ex.InnerException }; return 0 }
}
function Find-Container([string]$Project) { return @(Get-DockerContainerInventory -ProxyNetwork 'none' | Where-Object { [string]$_.compose.project -eq $Project })[0] }

$prefix = 'tpx-mgr-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
Register-TestRun -Prefix $prefix -Suite 'Test-ManagerConnectorsLive'
$before = Get-Fingerprint
$net = "$prefix-net"
try {
  $null = Invoke-TrDocker network create $net
  # --- Arcane ----------------------------------------------------------------------------------------------------
  $aPort = Get-FreeTcpPort
  $null = Invoke-TrDocker run -d --name "$prefix-arcane" --network $net -e APP_URL=http://localhost:3552 -e "ENCRYPTION_KEY=$(New-Secret)" -e "JWT_SECRET=$(New-Secret)" -v /var/run/docker.sock:/var/run/docker.sock -v "${prefix}-arcane-data:/app/data" -p "127.0.0.1:${aPort}:3552" $ArcaneImage
  $ab = "http://127.0.0.1:$aPort/api"
  Check 'arcane: the disposable instance starts' (Wait-Http "$ab/health")
  # Checked as text: Windows PowerShell's ConvertFrom-Json cannot parse this large document.
  $spec = (New-Object System.Net.Http.HttpClient).GetStringAsync("$ab/openapi.json").Result
  Check "arcane ($ArcaneImage): its OpenAPI document serves the paths DTC reads (/environments, /environments/{id}/projects, /environments/{id}/containers) with X-API-Key auth" (
    $spec.Contains('"/environments":') -and $spec.Contains('"/environments/{id}/projects":') -and $spec.Contains('"/environments/{id}/containers":') -and $spec -match '"in"\s*:\s*"header"\s*,\s*"name"\s*:\s*"X-API-Key"') ''
  $jwt = (Invoke-RestMethod -Method Post "$ab/auth/login" -ContentType 'application/json' -Body '{"username":"arcane","password":"arcane-admin"}').data.token
  $ah = @{ Authorization = "Bearer $jwt" }
  $client = New-Object System.Net.Http.HttpClient
  $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $jwt)
  $aProj = "$prefix-astack"
  $form = New-Object System.Net.Http.MultipartFormDataContent
  $form.Add((New-Object System.Net.Http.StringContent((@{ name = $aProj; composeContent = "services:`n  web:`n    image: $StackImage`n" } | ConvertTo-Json -Compress))), 'project')
  $form.Add((New-Object System.Net.Http.StringContent('{}')), 'manifest')
  $created = $client.PostAsync("$ab/environments/0/projects", $form).Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json
  $null = Invoke-RestMethod -Method Post "$ab/environments/0/projects/$($created.data.id)/up" -Headers $ah -ContentType 'application/json' -Body '{}'
  $end = (Get-Date).AddSeconds(90); while ((Get-Date) -lt $end -and -not (Find-Container $aProj)) { Start-Sleep -Seconds 2 }
  $perms = @('environments:list', 'environments:read', 'projects:list', 'projects:read', 'containers:list', 'containers:read') | ForEach-Object { @{ permission = $_ } }
  $aKey = (Invoke-RestMethod -Method Post "$ab/api-keys" -Headers $ah -ContentType 'application/json' -Body (@{ name = 'dtc read-only'; permissions = $perms } | ConvertTo-Json -Depth 4)).data.key
  $aConn = [pscustomobject]@{ id = 'arcane-live'; kind = 'arcane'; url = "http://127.0.0.1:$aPort" }
  $snap = Get-ManagerSnapshot -Connector $aConn -Key $aKey
  $st = @($snap.stacks | Where-Object { $_.project -eq $aProj })
  Check 'arcane: with a read-only key DTC lists the project (id, running, path) and its container, read from every page of the paginated container list' (
    $snap.ok -and $st.Count -eq 1 -and $st[0].status -eq 'running' -and $st[0].path -match "/app/data/projects/$aProj" -and @($st[0].containers | Where-Object { $_.service -eq 'web' -and $_.state -eq 'running' }).Count -eq 1) ($snap | ConvertTo-Json -Depth 5 -Compress)
  $c = Find-Container $aProj
  $dockerAuth = Get-ManagementAuthority $c
  $res = Resolve-ManagerAuthority $dockerAuth $aProj @($snap)
  Check 'arcane: Docker labels alone say "likely Arcane"; the API confirms it (evidence from both kept)' ($dockerAuth.id -eq 'arcane' -and $res.id -eq 'arcane' -and $res.confidence -eq 'confirmed' -and @($res.evidence).Count -ge 2) "$($dockerAuth.id)/$($dockerAuth.confidence) -> $($res.id)/$($res.confidence)"
  $write = Get-HttpStatus { Invoke-RestMethod -Method Post "$ab/environments/0/containers/$($c.id)/stop" -Headers @{ 'X-API-Key' = $aKey } }
  Check 'arcane: the read-only key cannot change anything (stop refused with 403)' ($write -eq 403) "HTTP $write"
  $bad = Get-ManagerSnapshot -Connector $aConn -Key 'arc_wrong_key_000000000000000000000000000000000000000000'
  Check 'arcane: a wrong or revoked key is reported as refused, the key value never appears' (-not $bad.ok -and $bad.error -eq 'unauthorized' -and ($bad | ConvertTo-Json -Depth 4) -notmatch 'arc_wrong_key') "$($bad.error)"
  $null = Invoke-TrDocker stop "$prefix-arcane"
  $down = Get-ManagerSnapshot -Connector $aConn -Key $aKey
  $resDown = Resolve-ManagerAuthority $dockerAuth $aProj @($down)
  $fDown = @(Get-ManagerDriftFindings $aProj $resDown @($down) $c)
  Check 'arcane: API down: reported as unreachable, ownership falls back to the Docker evidence ("likely"), one informational finding' (-not $down.ok -and $down.error -eq 'unreachable' -and $resDown.id -eq 'arcane' -and $resDown.confidence -ne 'confirmed' -and @($fDown | Where-Object { $_.id -eq 'manager-unavailable' -and $_.severity -eq 'info' }).Count -eq 1) "$($down.error) $($resDown.confidence)"
  $null = Invoke-TrDocker start "$prefix-arcane"

  # --- Portainer -------------------------------------------------------------------------------------------------
  $pPort = Get-FreeTcpPort
  $null = Invoke-TrDocker run -d --name "$prefix-portainer" --network $net -v /var/run/docker.sock:/var/run/docker.sock -v "${prefix}-portainer-data:/data" -p "127.0.0.1:${pPort}:9000" $PortainerImage
  $pb = "http://127.0.0.1:$pPort/api"
  Check 'portainer: the disposable instance starts' (Wait-Http "$pb/system/status")
  $ver = (Invoke-RestMethod "$pb/system/status").Version
  Start-Sleep -Seconds 2
  # Portainer 2.45 prints a one-time setup token (to stderr) that the first administrator setup must present.
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $plog = (& docker logs "$prefix-portainer" 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $ErrorActionPreference = $prevEap
  $setup = [regex]::Match($plog,'(?i)setup[ _-]?token[^A-Za-z0-9]*([A-Za-z0-9_\-]{16,})').Groups[1].Value
  $adminPw = 'Tpx-' + (New-Secret)
  $null = Invoke-RestMethod -Method Post "$pb/users/admin/init" -Headers @{ 'X-Setup-Token' = $setup } -ContentType 'application/json' -Body (@{ Username = 'admin'; Password = $adminPw } | ConvertTo-Json)
  $pjwt = (Invoke-RestMethod -Method Post "$pb/auth" -ContentType 'application/json' -Body (@{ Username = 'admin'; Password = $adminPw } | ConvertTo-Json)).jwt
  $ph = @{ Authorization = "Bearer $pjwt" }
  $pc = New-Object System.Net.Http.HttpClient
  $pc.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $pjwt)
  $ef = New-Object System.Net.Http.MultipartFormDataContent
  $ef.Add((New-Object System.Net.Http.StringContent('local')), 'Name'); $ef.Add((New-Object System.Net.Http.StringContent('1')), 'EndpointCreationType')
  $ep = $pc.PostAsync("$pb/endpoints", $ef).Result.Content.ReadAsStringAsync().Result | ConvertFrom-Json
  $userPw = 'Tpx-u-' + (New-Secret)
  $user = Invoke-RestMethod -Method Post "$pb/users" -Headers $ph -ContentType 'application/json' -Body (@{ username = 'dtc-reader'; password = $userPw; role = 2 } | ConvertTo-Json)
  $null = Invoke-RestMethod -Method Put "$pb/endpoints/$($ep.Id)" -Headers $ph -ContentType 'application/json' -Body (@{ UserAccessPolicies = @{ "$($user.Id)" = @{ RoleId = 0 } } } | ConvertTo-Json -Depth 4)
  $pProj = "$prefix-pstack"
  $stack = Invoke-RestMethod -Method Post "$pb/stacks/create/standalone/string?endpointId=$($ep.Id)" -Headers $ph -ContentType 'application/json' -Body (@{ Name = $pProj; StackFileContent = "services:`n  web:`n    image: $StackImage`n" } | ConvertTo-Json)
  $ujwt = (Invoke-RestMethod -Method Post "$pb/auth" -ContentType 'application/json' -Body (@{ Username = 'dtc-reader'; Password = $userPw } | ConvertTo-Json)).jwt
  $pKey = (Invoke-RestMethod -Method Post "$pb/users/$($user.Id)/tokens" -Headers @{ Authorization = "Bearer $ujwt" } -ContentType 'application/json' -Body (@{ description = 'dtc'; password = $userPw } | ConvertTo-Json)).rawAPIKey
  $pConn = [pscustomobject]@{ id = 'portainer-live'; kind = 'portainer'; url = "http://127.0.0.1:$pPort" }
  $end = (Get-Date).AddSeconds(90); while ((Get-Date) -lt $end -and -not (Find-Container $pProj)) { Start-Sleep -Seconds 2 }
  $pc1 = Find-Container $pProj
  $pDocker = Get-ManagementAuthority $pc1
  $s1 = Get-ManagerSnapshot -Connector $pConn -Key $pKey
  Check "portainer ${ver}: a non-administrator token sees no stack that is not shared with it; DTC says why and keeps the Docker evidence (likely Portainer)" (
    $s1.ok -and -not @($s1.stacks).Count -and $s1.message -match 'shared with it' -and $pDocker.id -eq 'portainer' -and (Resolve-ManagerAuthority $pDocker $pProj @($s1)).confidence -ne 'confirmed') "$($s1.message) / $($pDocker.id)"
  $rcId = (Invoke-RestMethod "$pb/stacks/$($stack.Id)" -Headers $ph).ResourceControl.Id
  $null = Invoke-RestMethod -Method Put "$pb/resource_controls/$rcId" -Headers $ph -ContentType 'application/json' -Body (@{ Public = $false; AdministratorsOnly = $false; Users = @($user.Id); Teams = @() } | ConvertTo-Json)
  $s2 = Get-ManagerSnapshot -Connector $pConn -Key $pKey
  $ps2 = @($s2.stacks | Where-Object { $_.project -eq $pProj })
  $pRes = Resolve-ManagerAuthority $pDocker $pProj @($s2)
  Check 'portainer: once shared, DTC lists the stack (id, active, /data/compose/<id>, environment) with its container, and the API confirms Portainer' (
    $s2.ok -and $ps2.Count -eq 1 -and $ps2[0].status -eq 'active' -and $ps2[0].path -eq "/data/compose/$($stack.Id)" -and $ps2[0].environment -eq [string]$ep.Id -and @($ps2[0].containers | Where-Object { $_.service -eq 'web' }).Count -eq 1 -and $pRes.confidence -eq 'confirmed') ($s2 | ConvertTo-Json -Depth 5 -Compress)
  $pw = Get-HttpStatus { Invoke-RestMethod -Method Post "$pb/endpoints/$($ep.Id)/docker/containers/$($pc1.id)/stop" -Headers @{ 'X-API-Key' = $pKey } }
  Check 'portainer: documented limit confirmed: the non-administrator token CAN stop a shared stack''s container (CE has no read-only token), so DTC''s GET-only rule is what keeps it read-only' ($pw -eq 200 -or $pw -eq 204) "HTTP $pw"
  $null = Invoke-TrDocker start $pc1.name
  $pBad = Get-ManagerSnapshot -Connector $pConn -Key 'ptr_wrong_000000000000000000000000000000000000'
  Check 'portainer: a wrong token is reported as refused' (-not $pBad.ok -and $pBad.error -eq 'unauthorized') $pBad.error
} finally {
  # Stacks first (their containers are named after the prefix), then the tools, volumes and the network.
  foreach ($cid in @(Invoke-TrDocker ps -aq --filter "name=$prefix")) { $null = Invoke-TrDocker rm -f $cid }
  foreach ($v in @(Invoke-TrDocker volume ls -q | Where-Object { $_ -like "$prefix*" })) { $null = Invoke-TrDocker volume rm $v }
  foreach ($n in @(Invoke-TrDocker network ls --format '{{.Name}}' | Where-Object { $_ -like "$prefix*" })) { $null = Invoke-TrDocker network rm $n }
  $left = @(Complete-TestRun $prefix)
  Check 'teardown: nothing with the run prefix is left' ($left.Count -eq 0) ($left -join ', ')
  $after = Get-Fingerprint
  Check "other containers untouched ($($before.Count) checked: same ids, states, start times, restart counts)" (@(Compare-Object $before $after).Count -eq 0) ((Compare-Object $before $after | ForEach-Object { $_.InputObject }) -join ' | ')
}
Write-Host ''
Write-Host "$script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
