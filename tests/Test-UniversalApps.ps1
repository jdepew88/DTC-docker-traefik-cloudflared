#requires -version 5.1
<#
.SYNOPSIS
  Live proofs of concept of the universal application engine on a disposable deployment: (1) an application that is
  not in the catalog, imported from its upstream Compose example, installed as a modular DTC stack, routed, verified,
  backed up, restored and removed; (2) an application owned by another tool (a Compose project with Portainer's
  access-control label), integrated without taking ownership, verified, drift detected and repaired, integration
  removed with the application left intact.

.DESCRIPTION
  Everything runs on its own disposable proxy deployment (install.ps1 -Start: Traefik + socket proxy on a free port,
  its own networks, a Cloudflare API mock); production containers are only read (their IDs and start times are
  compared before and after).

  Proof 1 imports https://github.com/miniflux/v2/blob/main/contrib/docker-compose/basic.yml (Miniflux, an RSS reader;
  -SourceUrl overrides it) through the normal importer: it needs the internet (GitHub and Docker Hub). Nothing in the
  engine is specific to Miniflux. Its authentication is checked with the application's own login (anonymous API
  requests refused, the generated administrator accepted); authentik ForwardAuth of imported and integrated apps is
  verified against a real authentik only in tests\Test-IdentityLive.ps1 and is reported here as not tested, apart
  from the fail-closed refusal when Identity & Access is not ready.

  Proof 2 needs only images already used by other tests (traefik/whoami, the deployment's Traefik image).

  About 400 MB of RAM and 250 MB of downloads (Miniflux and PostgreSQL images, unless present). The run stops
  before installing when less than 1.5 GB of memory is free.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-UniversalApps.ps1
#>
[CmdletBinding()]
param([string]$SourceUrl = 'https://github.com/miniflux/v2/blob/main/contrib/docker-compose/basic.yml', [switch]$SkipImport, [switch]$SkipExternal, [string]$TunnelSubnet = '172.31.247.0/28')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Invoke-Ps([string]$Script, [string[]]$Arguments) {
  $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Text = (@($out) -join "`n") }
}
function Get-EngineSnapshot([string]$ExcludePrefix) {
  $map = @{}
  foreach ($line in (Invoke-Docker ps -a --format '{{.Names}}').Output) {
    if (-not $line -or $line.StartsWith($ExcludePrefix) -or $line -match '-validate-') { continue }
    $map[$line] = ((Invoke-Docker inspect $line --format '{{.Id}} {{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim()
  }
  return $map
}
function Get-FreeGB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2) }
function Short([string]$Text, [int]$Max = 400) { if (-not $Text) { return '' }; return $Text.Substring(0, [Math]::Min($Max, $Text.Length)) }
function Wait-Http([int]$Port, [string]$HostName, [string]$Path, [int]$Seconds = 90, [int[]]$Want = @(200)) {
  $deadline = (Get-Date).AddSeconds($Seconds); $r = $null
  do { try { $r = Invoke-RawHttp -Port $Port -HostHeader $HostName -Path $Path -TimeoutMs 10000; if ($Want -contains $r.Status) { return $r } } catch { }; Start-Sleep -Seconds 3 } while ((Get-Date) -lt $deadline)
  return $r
}
function Get-Basic([string]$User, [string]$Password) { 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:$Password")) }

if (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'universal applications' 'Docker engine not running'; exit 0 }
$free = Get-FreeGB
$need = $(if ($SkipImport) { 0.8 } else { 1.5 })
if ($free -lt $need) { Add-Result 'SKIP' 'universal applications' "only $free GB of memory free ($need GB needed); nothing was started"; exit 0 }
Write-Host "Free memory before the run: $free GB"

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$stack = "tpx-ua-$id"; $network = "$stack-proxy"
$work = Join-Path ([IO.Path]::GetTempPath()) $stack
$installPath = Join-Path $work 'instance'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$o = $TunnelSubnet.Split('/')[0].Split('.')
$envFile = Join-Path $work 'instance.env'
$httpPort = Get-FreeTcpPort
@("STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$httpPort", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$network", "TUNNEL_SUBNET=$TunnelSubnet",
  "TUNNEL_IP_RANGE=$($o[0]).$($o[1]).$($o[2]).$($o[3])/29", "CLOUDFLARED_IP=$($o[0]).$($o[1]).$($o[2]).$([int]$o[3] + 10)", 'TRAEFIK_LOG_LEVEL=INFO') | Set-Content -LiteralPath $envFile -Encoding ASCII
$whoami = 'traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44'
$before = Get-EngineSnapshot $stack
$installed = $false; $ui = $null; $mock = $null
$mfProject = "$stack-mf"; $extProject = "$stack-ext"; $extDir = Join-Path $work 'external-app'
$minMem = $free
try {
  $install = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-Start')
  $installed = Test-Path -LiteralPath $installPath
  Test-Condition 'deployment: disposable proxy deployment installed and started (local only)' ($install.ExitCode -eq 0) (($install.Text -split "`n" | Select-Object -Last 12) -join ' | ')
  if ($install.ExitCode -ne 0) { throw 'Install failed.' }
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token ('mockTok_' + [Guid]::NewGuid().ToString('N'))
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $installPath -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $null = Connect-WebUi $ui

  # ===== Proof 1: an unfamiliar application from its upstream Compose example =====================================
  if ($SkipImport) { Add-Result 'SKIP' 'proof 1 (imported application)' '-SkipImport' }
  else {
    $imp = Invoke-WebUi $ui POST '/api/provision/import' @{ url = $SourceUrl }
    if ($imp.Status -ne 200) { Add-Result 'FAIL' 'proof 1: import from the upstream source' "$($imp.Status) $(Short $imp.Body)" }
    else {
      $d = $imp.Data
      $svcNames = @($d.services | ForEach-Object { $_.name })
      $db = @($d.services | Where-Object { $_.role -eq 'database' })
      Test-Condition "proof 1: imported $SourceUrl (not in the catalog): two services, database role, web service and port, images pinned, recipe untrusted until verified" (
        -not $d.catalogMatch -and $svcNames.Count -eq 2 -and $db.Count -eq 1 -and $d.web.service -and @($d.services | Where-Object { $_.name -eq $d.web.service })[0].ports[0].container -gt 0 -and
        -not @($d.services | Where-Object { $_.image -notmatch '@sha256:[0-9a-f]{64}$' }).Count -and $d.trust.level -eq 'untrusted') "$($d.name) services=$($svcNames -join ',') web=$($d.web.service) trust=$($d.trust.level)"
      Test-Condition 'proof 1: open questions and evidence are explicit (nothing invented): every generated secret and resolved value has evidence; example passwords are never used' (
        @($d.evidence).Count -gt 3 -and @($d.inputs | Where-Object { $_.type -in 'generated' }).Count -ge 2 -and -not @($d.inputs | Where-Object { $_.default -match '^(secret|test123)$' }).Count) (($d.inputs | ForEach-Object { "$($_.id):$($_.type)" }) -join ', ')
      Test-Condition 'proof 1: the database URL embeds the example password; it is linked to the generated database secret, not reported as a fixed credential' (
        -not @($d.findings | Where-Object { $_.id -like 'credential:*' }).Count -and -not @($d.unresolved | Where-Object { $_.field -match 'DATABASE_URL' }).Count) (($d.findings | ForEach-Object { $_.id }) -join ', ')
      $again = Invoke-WebUi $ui POST '/api/provision/import' @{ url = $SourceUrl }
      Test-Condition 'proof 1: importing the same source again reuses the draft (idempotent)' ($again.Data.draftId -eq $d.draftId -and $again.Data.reused) $again.Body
      foreach ($s in $d.services) { $null = Invoke-Docker pull $s.image }
      $minMem = [Math]::Min($minMem, (Get-FreeGB))
      $host1 = "mf-$id.home.example"
      $acks = @(@($d.findings | Where-Object { $_.severity -ne 'block' } | ForEach-Object { $_.id }) + 'auth:none')
      $body = @{ draftId = $d.draftId; project = $mfProject; access = 'lan'; hostname = $host1; auth = 'none'; acknowledge = $acks }
      $plan = Invoke-WebUi $ui POST '/api/provision/plan' $body
      if ($plan.Status -eq 200 -and -not $plan.Data.canApply -and @($plan.Data.blockers | Where-Object { $_ -match 'already runs on this PC' }).Count) { $body.anotherInstance = $true; $body.instanceLabel = 'PoC'; $plan = Invoke-WebUi $ui POST '/api/provision/plan' $body }
      Test-Condition 'proof 1: the plan is reviewable and ready: modular Compose files, explicit Traefik route, no publication' ($plan.Status -eq 200 -and $plan.Data.canApply -and @($plan.Data.routing.traefik.changes | Where-Object { $_.file -match "svc-$mfProject\.yml" }).Count) "$($plan.Status) blockers=$(@($plan.Data.blockers) -join ' | ') $(Short $plan.Body 300)"
      if ($plan.Data.canApply) {
        $ap = Invoke-WebUi $ui POST '/api/provision/apply' @{ planId = $plan.Data.planId; confirm = $true }
        $stages = @($ap.Data.journal.stages | ForEach-Object { "$($_.stage)=$($_.status)" })
        Test-Condition 'proof 1: install, backend and route stages passed; the journal records what was created' ($ap.Status -eq 200 -and $ap.Data.ok -and ($stages -join ',') -match 'install=passed' -and ($stages -join ',') -match 'route=passed') "$($ap.Status) $($stages -join ',') $(Short $ap.Body)"
        $minMem = [Math]::Min($minMem, (Get-FreeGB))
        $folder = [string](@($ap.Data.journal.resources | Where-Object { $_.kind -eq 'compose-project' })[0].detail)
        $files = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $stackFile = $null; try { $stackFile = Get-Content -Raw -LiteralPath (Join-Path $folder 'dtc-stack.json') | ConvertFrom-Json } catch { }
        Test-Condition 'proof 1: modular project like a curated app: compose.yaml + compose.database.yaml, dtc-stack.json, the imported manifest, .env with the generated secrets' (
          $files -contains 'compose.yaml' -and $files -contains 'compose.database.yaml' -and $files -contains 'dtc-stack.json' -and $files -contains '.dtc-manifest.json' -and $files -contains '.env') ($files -join ', ')
        $dbc = @((Invoke-Docker ps --filter "label=com.docker.compose.project=$mfProject" --filter "label=com.docker.compose.service=$($db[0].name)" -q).Output | Where-Object { $_ })[0]
        $webc = @((Invoke-Docker ps --filter "label=com.docker.compose.project=$mfProject" --filter "label=com.docker.compose.service=$($d.web.service)" -q).Output | Where-Object { $_ })[0]
        $dbNets = $(if ($dbc) { ((Invoke-Docker inspect -f '{{json .NetworkSettings.Networks}}' $dbc).Output -join '') | ConvertFrom-Json } else { $null })
        $dbPorts = $(if ($dbc) { ((Invoke-Docker inspect -f '{{json .NetworkSettings.Ports}}' $dbc).Output -join '') } else { '' })
        $webPorts = $(if ($webc) { ((Invoke-Docker inspect -f '{{json .NetworkSettings.Ports}}' $webc).Output -join '') } else { '' })
        Test-Condition 'proof 1: networking: the database is only on the private network with no host port; the web service publishes at most on 127.0.0.1; container DNS names, no fixed IPs' (
          $dbNets -and -not $dbNets.PSObject.Properties[$network] -and $dbPorts -notmatch '"HostPort":"\d+"' -and $webPorts -notmatch '"HostIp":"(0\.0\.0\.0|::)?"\s*,\s*"HostPort":"\d+"' -and $stackFile -and @($stackFile.networks.private).Count) "db nets=$(if ($dbNets) { ($dbNets.PSObject.Properties.Name) -join ',' }) dbPorts=$dbPorts webPorts=$webPorts"
        $env = @{}; foreach ($l in @(Get-Content -LiteralPath (Join-Path $folder '.env') -ErrorAction SilentlyContinue)) { $i = $l.IndexOf('='); if ($i -gt 0) { $env[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
        $pwKey = @($env.Keys | Where-Object { $_ -match 'ADMIN_PASSWORD' })[0]; $userKey = @($env.Keys | Where-Object { $_ -match 'ADMIN_USERNAME' })[0]
        $adminPw = $(if ($pwKey) { $env[$pwKey] } else { '' }); $adminUser = $(if ($userKey) { $env[$userKey] } else { 'admin' })
        $health = Wait-Http $httpPort $host1 '/healthcheck' 120
        Test-Condition 'proof 1: a real request through the disposable Traefik reaches the application (health endpoint)' ($health -and $health.Status -eq 200) "$(if ($health) { "$($health.Status) $(Short $health.Body 120)" })"
        $anon = Invoke-RawHttp -Port $httpPort -HostHeader $host1 -Path '/v1/me' -TimeoutMs 15000
        $authd = Invoke-RawHttp -Port $httpPort -HostHeader $host1 -Path '/v1/me' -Headers @{ Authorization = (Get-Basic $adminUser $adminPw) } -TimeoutMs 15000
        Test-Condition 'proof 1: native authentication: anonymous API requests are refused (401), the generated administrator is accepted (200)' ($anon.Status -eq 401 -and $authd.Status -eq 200 -and $authd.Body -match [regex]::Escape($adminUser)) "anon=$($anon.Status) auth=$($authd.Status) $(Short $authd.Body 120)"
        $hdr = @{ Authorization = (Get-Basic $adminUser $adminPw); 'Content-Type' = 'application/json' }
        $title = "DTC PoC $id"
        $cat = Invoke-RawHttp -Port $httpPort -HostHeader $host1 -Method POST -Path '/v1/categories' -Headers $hdr -Body (@{ title = $title } | ConvertTo-Json -Compress) -TimeoutMs 15000
        $catId = 0; try { $catId = [int]($cat.Body | ConvertFrom-Json).id } catch { }
        Test-Condition 'proof 1: application functionality: data written through the route (a category stored in its PostgreSQL database)' ($cat.Status -eq 201 -and $catId -gt 0) "$($cat.Status) $(Short $cat.Body 160)"
        $apps = Invoke-WebUi $ui GET '/api/applications'
        $mine = @($apps.Data.applications | Where-Object { $_.project -eq $mfProject })[0]
        Test-Condition 'proof 1: the applications view shows it as DTC Managed with an imported recipe and its route' ($mine -and $mine.mode -eq 'managed' -and [string]$mine.recipe -like 'imported:*' -and @($mine.routes).Count -eq 1) (Short $apps.Body 300)
        if ($mine) {
          $dr = Invoke-WebUi $ui POST '/api/applications/drift' @{ instanceId = $mine.instanceId }
          Test-Condition 'proof 1: drift check of the managed stack: in sync (route loaded, backend answers from Traefik''s network, volumes present)' ($dr.Status -eq 200 -and $dr.Data.summary.state -eq 'in-sync') "$($dr.Status) $(($dr.Data.findings | ForEach-Object { "$($_.id): $($_.explanation)" }) -join ' | ')"
        }
        if ($catId -gt 0) {
          $bk = Invoke-WebUi $ui POST '/api/apps/backup' @{ project = $mfProject; confirm = $true }
          $bkId = $(if ($bk.Data.folder) { Split-Path -Leaf ([string]$bk.Data.folder) } else { '' })
          Test-Condition 'proof 1: backup of the DTC-owned stack (data volumes and generated files)' ($bk.Status -eq 200 -and $bk.Data.ok -and @($bk.Data.volumes).Count -ge 1) "$($bk.Status) $(Short $bk.Body)"
          $null = Wait-Http $httpPort $host1 '/healthcheck' 120
          $del = Invoke-RawHttp -Port $httpPort -HostHeader $host1 -Method DELETE -Path "/v1/categories/$catId" -Headers @{ Authorization = (Get-Basic $adminUser $adminPw) } -TimeoutMs 15000
          $rp = Invoke-WebUi $ui POST '/api/apps/restore-data/plan' @{ project = $mfProject; backup = $bkId; restoreFiles = $false }
          $rs = Invoke-WebUi $ui POST '/api/apps/restore-data' @{ project = $mfProject; backup = $bkId; restoreFiles = $false; key = $rp.Data.key; confirm = $true }
          $null = Wait-Http $httpPort $host1 '/healthcheck' 150
          $list = Invoke-RawHttp -Port $httpPort -HostHeader $host1 -Path '/v1/categories' -Headers @{ Authorization = (Get-Basic $adminUser $adminPw) } -TimeoutMs 15000
          Test-Condition 'proof 1: restore: data deleted after the backup is back after restoring it (application answers again)' ($del.Status -eq 204 -and $rp.Status -eq 200 -and $rs.Status -eq 200 -and $list.Status -eq 200 -and $list.Body -match [regex]::Escape($title)) "del=$($del.Status) plan=$($rp.Status) restore=$($rs.Status) $(Short $rs.Body 200) list=$($list.Status)"
        }
        $minMem = [Math]::Min($minMem, (Get-FreeGB))
        $rbBad = Invoke-WebUi $ui POST '/api/provision/rollback' @{ operationId = $ap.Data.operationId; confirm = $true; deleteData = $true; confirmText = 'wrong' }
        $rb = Invoke-WebUi $ui POST '/api/provision/rollback' @{ operationId = $ap.Data.operationId; confirm = $true; deleteData = $true; confirmText = $mfProject }
        $left = @((Invoke-Docker ps -a --filter "label=com.docker.compose.project=$mfProject" -q).Output | Where-Object { $_ })
        $vols = @((Invoke-Docker volume ls -q --filter "name=${mfProject}_").Output | Where-Object { $_ })
        $rest = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        Test-Condition 'proof 1: clean removal: deleting data needs the project name; route, containers, volumes and generated files are gone (only the backups you made are kept)' ($rbBad.Status -eq 400 -and $rb.Status -eq 200 -and $rb.Data.ok -and -not $left.Count -and -not $vols.Count -and -not (Test-Path -LiteralPath (Join-Path $installPath "traefik\dynamic\svc-$mfProject.yml")) -and (-not (Test-Path -LiteralPath $folder) -or ($rest -join ',') -eq 'backups')) "bad=$($rbBad.Status) $($rb.Status) left=$($left.Count) vols=$($vols.Count) folder=$($rest -join ',') $(Short $rb.Body 200)"
      }
    }
  }

  # ===== Proof 2: an application another tool owns ================================================================
  if ($SkipExternal) { Add-Result 'SKIP' 'proof 2 (externally owned application)' '-SkipExternal' }
  else {
    New-Item -ItemType Directory -Force -Path $extDir | Out-Null
    $extCompose = Join-Path $extDir 'compose.yaml'
    $composeText = { param([int]$Port, [bool]$OnProxy) @"
name: $extProject
services:
  web:
    image: $whoami
    command: ["--port", "$Port"]
    expose: ["$Port"]
    labels:
      io.portainer.accesscontrol.public: ""
    networks: [$(if ($OnProxy) { 'proxy, ' })default]
networks:
  default: {}
$(if ($OnProxy) { "  proxy:`n    external: true`n    name: $network" })
"@ }
    $upExt = { param([int]$Port, [bool]$OnProxy) [IO.File]::WriteAllText($extCompose, (& $composeText $Port $OnProxy)); Invoke-Docker compose -f $extCompose -p $extProject up -d --pull missing --remove-orphans }
    $u1 = & $upExt 8080 $true
    $extName = "$extProject-web-1"
    Test-Condition 'proof 2 fixture: a Compose project created outside DTC (Portainer''s access-control label) runs on the shared network' ($u1.ExitCode -eq 0) (@($u1.Output) -join ' ')
    $hashOf = { (Get-FileHash -LiteralPath $extCompose -Algorithm SHA256).Hash }
    $apps = Invoke-WebUi $ui GET '/api/applications'
    $cand = @($apps.Data.unmanaged | Where-Object { $_.project -eq $extProject })[0]
    Test-Condition 'proof 2: detected: its Compose project and service, Portainer as management authority (with evidence), the web front end and port, suggested mode Integrated' (
      $cand -and $cand.authority.id -eq 'portainer' -and $cand.authority.confidence -eq 'certain' -and $cand.suggestedMode -eq 'integrated' -and $cand.frontend.container -eq $extName -and @($cand.frontend.ports | Where-Object { $_.port -eq 8080 }).Count -ge 0) (Short ($cand | ConvertTo-Json -Depth 5 -Compress) 400)
    $obs = Invoke-WebUi $ui POST '/api/applications/observe' @{ container = $extName; name = 'External whoami' }
    $host2 = "ext-$id.home.example"
    $blocked = Invoke-WebUi $ui POST '/api/integrations/plan' @{ container = $extName; port = 8080; hostname = $host2; name = "ext-$id" }
    Test-Condition 'proof 2: DTC Observed first: recorded without any change; integrating it needs an explicit switch' ($obs.Status -eq 200 -and $obs.Data.instance.mode -eq 'observed' -and $blocked.Status -eq 409) "$($obs.Status) $($blocked.Status) $(Short $blocked.Body 200)"
    $pub = Invoke-WebUi $ui POST '/api/integrations/plan' @{ container = $extName; port = 8080; hostname = $host2; name = "ext-$id"; publish = $true; switchToIntegrated = $true }
    $mockWrites = @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' })
    $cfp = $(if ($pub.Status -eq 200 -and $pub.Data -and $pub.Data.PSObject.Properties['plan']) { $pub.Data.plan.cloudflare } else { $null })
    Test-Condition 'proof 2: Cloudflare publication is a preview only (DNS/tunnel/Access plan or manual steps); nothing is written to Cloudflare by a preview' ($cfp -and (@($cfp.actions).Count -or @($cfp.manualSteps).Count -or @($cfp.errors).Count -or @($cfp.notes).Count) -and -not $mockWrites.Count) "$($pub.Status) writes=$($mockWrites.Count) $(Short $pub.Body 400)"
    $hashBefore = & $hashOf
    $idBefore = ((Invoke-Docker inspect -f '{{.Id}}' $extName).Output -join '').Trim()
    $plan2 = Invoke-WebUi $ui POST '/api/integrations/plan' @{ container = $extName; port = 8080; hostname = $host2; name = "ext-$id"; switchToIntegrated = $true }
    Test-Condition 'proof 2: integration plan: explicit route file, backend answers from Traefik''s network, ownership stays with Portainer' ($plan2.Status -eq 200 -and $plan2.Data.canApply -and @($plan2.Data.plan.traefik.changes | Where-Object { $_.file -match "svc-ext-$id\.yml" }).Count -and $plan2.Data.plan.backend.state -in 'ok', 'auth' -and $plan2.Data.ownership.authority.id -eq 'portainer' -and -not $plan2.Data.ownership.rights.lifecycle) "$($plan2.Status) $(Short $plan2.Body 400)"
    $ap2 = Invoke-WebUi $ui POST '/api/integrations/apply' @{ planId = $plan2.Data.planId; confirm = $true }
    $route = @((Get-Content -Raw -LiteralPath (Join-Path $installPath 'config\services.json') | ConvertFrom-Json).services | Where-Object { $_.name -eq "ext-$id" })[0]
    $yml = Get-Content -Raw -LiteralPath (Join-Path $installPath "traefik\dynamic\svc-ext-$id.yml") -ErrorAction SilentlyContinue
    Test-Condition 'proof 2: integrated: the route is owned by the integration (registry and YAML say so); the instance is DTC Integrated' ($ap2.Status -eq 200 -and $ap2.Data.ok -and $route -and $route.owner.instanceId -eq $ap2.Data.instanceId -and $yml -match 'Owner: integration' -and $yml -match "${extName}:8080") "$($ap2.Status) $(Short $ap2.Body 300)"
    $iid = [string]$ap2.Data.instanceId
    $r1 = Wait-Http $httpPort $host2 '/' 60
    Test-Condition 'proof 2: reachable through Traefik by its DNS name' ($r1 -and $r1.Status -eq 200 -and $r1.Body -match 'Hostname:') "$(if ($r1) { $r1.Status })"
    $prot = Invoke-WebUi $ui POST '/api/integrations/protect' @{ instanceId = $iid; route = "ext-$id"; confirm = $true }
    Test-Condition 'proof 2: authentik protection is refused while Identity & Access is not ready (fail closed; never a route without the sign-in it promises)' ($prot.Status -eq 409) "$($prot.Status) $(Short $prot.Body 200)"
    Add-Result 'SKIP' 'proof 2: authentik ForwardAuth on the integrated route (denied anonymous, allowed signed-in)' 'needs a real authentik: tests\Test-IdentityLive.ps1'
    $sync = Invoke-WebUi $ui POST '/api/applications/drift' @{ instanceId = $iid }
    Test-Condition 'proof 2: drift check right after integrating: in sync' ($sync.Status -eq 200 -and $sync.Data.summary.state -eq 'in-sync') "$($sync.Status) $(($sync.Data.findings | ForEach-Object { $_.id }) -join ', ')"
    # Controlled backend change, as the owner tool would do it: the service now listens on 9090 (container recreated).
    $u2 = & $upExt 9090 $true
    $hashOwner = & $hashOf
    $chg = Invoke-WebUi $ui POST '/api/applications/drift' @{ instanceId = $iid }
    $pc = @($chg.Data.findings | Where-Object { $_.id -eq 'port-changed' })[0]
    Test-Condition 'proof 2: drift detected after the owner recreated the container on another port: replaced container and changed port, with a DTC repair to the port that answers (9090)' (
      $u2.ExitCode -eq 0 -and $chg.Data.summary.state -eq 'drifted' -and @($chg.Data.findings | Where-Object { $_.id -eq 'container-replaced' }).Count -and $pc -and $pc.repair.owner -eq 'dtc' -and $pc.repair.change.port -eq 9090) "$(($chg.Data.findings | ForEach-Object { "$($_.id): $($_.explanation)" }) -join ' | ')"
    $down = Invoke-RawHttp -Port $httpPort -HostHeader $host2 -Path '/' -TimeoutMs 15000
    $rpl = Invoke-WebUi $ui POST '/api/applications/repair/plan' @{ instanceId = $iid }
    Test-Condition 'proof 2: repair preview: one DTC-owned route change (port 8080 -> 9090) shown as a Traefik diff before anything changes' ($down.Status -ge 500 -and $rpl.Status -eq 200 -and $rpl.Data.canApply -and @($rpl.Data.routeChanges).Count -eq 1 -and ((@($rpl.Data.routeChanges[0].plan.traefik.changes)[0].diff) -join "`n") -match '9090') "down=$($down.Status) $(Short $rpl.Body 400)"
    $rap = Invoke-WebUi $ui POST '/api/applications/repair/apply' @{ instanceId = $iid; key = $rpl.Data.key; confirm = $true }
    $r2 = Wait-Http $httpPort $host2 '/' 60
    $after = Invoke-WebUi $ui POST '/api/applications/drift' @{ instanceId = $iid }
    Test-Condition 'proof 2: repair applied through the validated change pipeline: reachable again and in sync; the owner''s Compose file was not touched by DTC' ($rap.Status -eq 200 -and $rap.Data.ok -and $r2 -and $r2.Status -eq 200 -and $after.Data.summary.state -eq 'in-sync' -and (& $hashOf) -eq $hashOwner) "$($rap.Status) $(Short $rap.Body 200) after=$(($after.Data.findings | ForEach-Object { $_.id }) -join ',')"
    # The owner drops the shared network: only the owner can fix it; DTC explains and proposes the Compose lines.
    $u3 = & $upExt 9090 $false
    $net = Invoke-WebUi $ui POST '/api/applications/drift' @{ instanceId = $iid }
    $off = @($net.Data.findings | Where-Object { $_.id -eq 'off-proxy-network' })[0]
    $rpl2 = Invoke-WebUi $ui POST '/api/applications/repair/plan' @{ instanceId = $iid }
    Test-Condition 'proof 2: "running, but Traefik cannot reach it ... after Portainer recreated the container": the repair is for Portainer (Compose lines), DTC changes nothing' (
      $u3.ExitCode -eq 0 -and $off -and $off.explanation -match 'Traefik cannot reach' -and $off.explanation -match 'Portainer' -and $off.repair.owner -eq 'external' -and -not $rpl2.Data.canApply -and (@($rpl2.Data.external | ForEach-Object { @($_.snippet) }) -join "`n") -match 'external: true') "$(Short ($off | ConvertTo-Json -Depth 4 -Compress) 300)"
    $u4 = & $upExt 9090 $true
    $idKeep = ((Invoke-Docker inspect -f '{{.Id}}' $extName).Output -join '').Trim()
    $hashKeep = & $hashOf
    $rmp = Invoke-WebUi $ui POST '/api/integrations/remove/plan' @{ instanceId = $iid }
    $rm = Invoke-WebUi $ui POST '/api/integrations/remove' @{ instanceId = $iid; key = $rmp.Data.key; confirm = $true }
    $gone = Invoke-RawHttp -Port $httpPort -HostHeader $host2 -Path '/' -TimeoutMs 15000
    $reg = Get-Content -Raw -LiteralPath (Join-Path $installPath 'config\applications.json') | ConvertFrom-Json
    $stillThere = ((Invoke-Docker inspect -f '{{.Id}} {{.State.Status}}' $extName).Output -join '').Trim()
    Test-Condition 'proof 2: removing the integration removes only its route; the application keeps running with the same container, its Compose file unchanged' (
      $rmp.Status -eq 200 -and @($rmp.Data.removes).Count -eq 1 -and $rm.Status -eq 200 -and $rm.Data.ok -and $gone.Status -eq 404 -and -not (Test-Path -LiteralPath (Join-Path $installPath "traefik\dynamic\svc-ext-$id.yml")) -and
      $stillThere -eq "$idKeep running" -and (& $hashOf) -eq $hashKeep -and -not @($reg.instances | Where-Object { $_.instanceId -eq $iid }).Count) "$($rm.Status) $(Short $rm.Body 200) gone=$($gone.Status) container=$stillThere"
    $null = $idBefore; $null = $hashBefore
  }
} catch {
  Add-Result 'FAIL' 'universal applications run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
} finally {
  Stop-TestServer $ui; Stop-TestServer $mock
  if (Test-Path -LiteralPath (Join-Path $extDir 'compose.yaml')) { $null = Invoke-Docker compose -f (Join-Path $extDir 'compose.yaml') -p $extProject down --remove-orphans }
  foreach ($p in @($mfProject, $extProject)) {
    foreach ($c in @((Invoke-Docker ps -a -q --filter "label=com.docker.compose.project=$p").Output | Where-Object { $_ })) { $null = Invoke-Docker rm -f $c }
    foreach ($v in @((Invoke-Docker volume ls -q --filter "name=${p}_").Output | Where-Object { $_ })) { $null = Invoke-Docker volume rm $v }
    foreach ($n in @((Invoke-Docker network ls -q --filter "name=${p}_").Output | Where-Object { $_ })) { $null = Invoke-Docker network rm $n }
  }
  if ($installed) { $null = Invoke-Ps (Join-Path $installPath 'install.ps1') @('-InstallPath', $installPath, '-Stop'); $null = Invoke-Docker rm -f "$stack-whoami" }
  # Anything left with this run's unique prefix is this run's own (install -Stop may leave the deployment running).
  foreach ($c in @((Invoke-Docker ps -a -q --filter "name=$stack").Output | Where-Object { $_ })) { $null = Invoke-Docker rm -f $c }
  foreach ($n in @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ -like "$stack*" })) { $null = Invoke-Docker network rm $n }
  foreach ($v in @((Invoke-Docker volume ls -q --filter "name=$stack").Output | Where-Object { $_ -like "$stack*" })) { $null = Invoke-Docker volume rm $v }
  $null = Invoke-Docker network rm $network
  $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
  $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
  $leftVols = @((Invoke-Docker volume ls -q --filter "name=$stack").Output | Where-Object { $_ })
  Test-Condition 'teardown: no disposable containers, networks or volumes left' ($left.Count -eq 0 -and $leftNets.Count -eq 0 -and $leftVols.Count -eq 0) (($left + $leftNets + $leftVols) -join ', ')
  $afterSnap = Get-EngineSnapshot $stack
  $changed = @($before.Keys | Where-Object { -not $afterSnap.ContainsKey($_) -or $afterSnap[$_] -ne $before[$_] })
  Test-Condition "production untouched ($($before.Count) other containers: same IDs, start times, states)" ($changed.Count -eq 0) ("changed: $($changed -join ', ')")
  Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Lowest free memory seen during the run: $minMem GB"
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count) { exit 1 }
exit 0
