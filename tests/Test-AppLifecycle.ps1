#requires -version 5.1
<#
.SYNOPSIS
  Application catalog identity, Compose service lifecycle and installed instances: unit tests, the web API on a
  throwaway instance, and (unless -SkipDocker) a small disposable Compose project.

.DESCRIPTION
  Part 1 (no Docker): canonical ids and aliases, variants, retired and reference entries, manifest rules, the lifecycle
  of a Rocket.Chat-shaped application (three long-running services and two setup jobs, failed job, unexpectedly stopped
  service, missing health check, unknown role, dependencies), instances, duplicate detection that ignores dependency
  images, and the removal inventory (shared volumes and networks are never deleted).
  Part 2 (throwaway instance, never started): /api/catalog lists one entry per application without Watchtower,
  planning a retired app is refused, archiving a record changes nothing but the record, an existing installation
  blocks a silent second one, and an intentional second instance is allowed.
  Part 3 (Docker, small): a disposable Compose project made of the Traefik image already on this PC (a few MB per
  container): one-time jobs (declared by depends_on, inferred from the restart policy, failing), a service without a
  health check, a healthy one; real `docker inspect` facts, the details API (no secrets), and tidying up a completed job
  container without touching anything else. Every other container keeps its ID, start time and state.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-AppLifecycle.ps1 -SkipDocker
#>
[CmdletBinding()]
param([switch]$SkipDocker)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\AppCatalog.psm1') -Force
Import-Module (Join-Path $repo 'lib\ComposeLifecycle.psm1') -Force
Import-Module (Join-Path $repo 'lib\AppInstances.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\TestResources.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
$dot = [char]0x00B7

# --- Part 1a: catalog identity ----------------------------------------------------------------------------------------
$catalogDir = Join-Path $repo 'catalog'
$apps = @(Get-CatalogApps -CatalogDir $catalogDir)
$valid = @($apps | Where-Object { -not @($_.errors).Count })
$m = @{}; foreach ($a in $valid) { $m[$a.id] = $a.manifest }
Test-Condition 'catalog: every manifest is valid with the identity fields (aliases, variants, availability, roles)' ($valid.Count -eq $apps.Count) (@($apps | Where-Object { @($_.errors).Count } | ForEach-Object { "$($_.id): $($_.errors -join '; ')" }) -join ' | ')
$offered = { param($id) (Get-ManifestAvailability $m[$id]) -eq 'offered' -and (Get-PlatformSupport $m[$id]).installable }
Test-Condition 'catalog: Arcane, Portainer and What''s Up Docker stay installable' ((& $offered 'arcane') -and (& $offered 'portainer') -and (& $offered 'whats-up-docker')) ''
Test-Condition 'catalog: Arcane is the recommended Docker management tool, Portainer the alternative (one choice group)' ($m.arcane.choiceGroup.id -eq 'docker-management' -and $m.arcane.choiceGroup.recommended -and $m.portainer.choiceGroup.id -eq 'docker-management' -and -not $m.portainer.choiceGroup.recommended) ''
Test-Condition 'catalog: What''s Up Docker only notifies (no update trigger, read-only socket proxy that refuses POST/DELETE)' (-not @($m.'whats-up-docker'.services.app.environment.PSObject.Properties | Where-Object { $_.Name -match '^WUD_TRIGGER_' }).Count -and $m.'whats-up-docker'.services.'socket-proxy'.environment.POST -eq '0' -and $m.'whats-up-docker'.services.'socket-proxy'.environment.DELETE -eq '0') ''
Test-Condition 'catalog: Watchtower is retired (not offered, not installable, with a note and a replacement)' ((Get-ManifestAvailability $m.watchtower) -eq 'retired' -and -not $m.watchtower.installable -and @($m.watchtower.retired.replacement) -contains 'whats-up-docker' -and $m.watchtower.retired.note) ''
Test-Condition 'catalog: Diun is offered again as a headless, notification-only app (choice group with What''s Up Docker)' ((Get-ManifestAvailability $m.diun) -eq 'offered' -and $m.diun.installable -and $m.diun.web.headless -and $m.diun.choiceGroup.id -eq $m.'whats-up-docker'.choiceGroup.id -and $m.'whats-up-docker'.choiceGroup.recommended) ''
Test-Condition 'catalog: PostgreSQL and Redis are reference entries (building blocks), not applications' ((Get-ManifestAvailability $m.postgresql) -eq 'reference' -and (Get-ManifestAvailability $m.redis) -eq 'reference') ''
$res = @('rocket-chat', 'rocketchat', 'Rocket.Chat', 'ROCKET_CHAT') | ForEach-Object { $e = Resolve-CatalogEntry $apps $_; if ($e) { $e.id } else { '-' } }
Test-Condition 'identity: rocket-chat, rocketchat, Rocket.Chat and ROCKET_CHAT name the one application rocketchat' ((@($res | Select-Object -Unique) -join ',') -eq 'rocketchat' -and (Get-CatalogApp $catalogDir 'rocket-chat').id -eq 'rocketchat') ($res -join ',')
Test-Condition 'identity: the modular Dispatcharr compose is a variant of Dispatcharr, not a separate application' ((Get-ApplicationId $m.'dispatcharr-modular') -eq 'dispatcharr' -and $m.'dispatcharr-modular'.variant.label) ''
$offeredApps = @($valid | Where-Object { (Get-ManifestAvailability $_.manifest) -eq 'offered' } | ForEach-Object { Get-ApplicationId $_.manifest })
Test-Condition 'identity: one catalog entry per application (no two offered manifests resolve to the same id unless one is a variant)' (@($valid | Where-Object { (Get-ManifestAvailability $_.manifest) -eq 'offered' -and -not $_.manifest.PSObject.Properties['variantOf'] } | ForEach-Object { Get-AppIdentityKey $_.manifest.name } | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) ($offeredApps -join ',')
# Alias collisions and manifest rules (fixture catalog).
$fx = Join-Path ([IO.Path]::GetTempPath()) ('tpm-lcat-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path (Join-Path $fx 'apps') | Out-Null
try {
  $base = Get-Content -Raw (Join-Path $catalogDir 'apps\echo.json') | ConvertFrom-Json
  $one = $base.PSObject.Copy(); $one.id = 'chatone'; $one | Add-Member aliases @('rocket-chat')
  $two = $base.PSObject.Copy(); $two.id = 'chattwo'; $two | Add-Member aliases @('Rocket-Chat')
  [IO.File]::WriteAllText((Join-Path $fx 'apps\chatone.json'), ($one | ConvertTo-Json -Depth 10)); [IO.File]::WriteAllText((Join-Path $fx 'apps\chattwo.json'), ($two | ConvertTo-Json -Depth 10))
  $col = @(Get-CatalogApps -CatalogDir $fx | Where-Object { $_.id -eq 'chattwo' })[0]
  Test-Condition 'identity: two manifests claiming the same alias (ignoring case and dashes) are rejected' ((@($col.errors) -join ' ') -match "already names catalog app 'chatone'") (@($col.errors) -join '; ')
} finally { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
$bad1 = $m.watchtower.PSObject.Copy(); $bad1.installable = $true
$bad2 = (Get-Content -Raw (Join-Path $catalogDir 'apps\rocketchat.json') | ConvertFrom-Json); $bad2.services.nats | Add-Member role 'janitor' -Force; $bad2.services.rocketchat | Add-Member lifecycle 'run-once' -Force
$bad3 = (Get-Content -Raw (Join-Path $catalogDir 'apps\echo.json') | ConvertFrom-Json); $bad3.source.type = 'generated'
Test-Condition 'manifest: a retired entry cannot be installable; unknown roles and a run-once web service are rejected; generated manifests are not installable yet' (((Test-AppManifest $bad1) -join ' ') -match 'retired manifest cannot be installable' -and ((Test-AppManifest $bad2) -join ' ') -match 'role must be one of' -and ((Test-AppManifest $bad2) -join ' ') -match 'web service cannot be a run-once job' -and ((Test-AppManifest $bad3) -join ' ') -match 'only curated manifests are installable') ''

# --- Part 1b: lifecycle (facts shaped like the live Rocket.Chat project) ------------------------------------------------
function New-Fact([string]$Svc, [string]$State = 'running', [int]$Exit = 0, [string]$Health = '', [bool]$Hc = $false, [string]$Restart = 'unless-stopped', $Deps = @(), [string]$Project = 'rc', [string]$Image = 'img:1') {
  return [ordered]@{ id = ('{0:x12}' -f [Math]::Abs($Svc.GetHashCode())); name = "$Project-$Svc"; project = $Project; service = $Svc; workingDir = "C:\apps\$Project"; oneoff = $false; app = ''; managedProject = $Project
    image = $Image; imageId = 'sha256:' + ('a' * 64); state = $State; exitCode = $Exit; health = $Health; hasHealthcheck = $Hc; restartPolicy = $Restart; restartCount = 0
    startedAt = '2026-10-23T09:47:19Z'; finishedAt = $(if ($State -eq 'exited') { '2026-10-23T09:47:27Z' } else { '0001-01-01T00:00:00Z' })
    dependsOn = @($Deps); networks = @([ordered]@{ name = "${Project}_internal"; ip = '172.20.0.2'; dnsNames = @("$Project-$Svc", $Svc) }); ports = @(); mounts = @() }
}
function New-RcFacts([hashtable]$Over = @{}) {
  $f = [ordered]@{
    rocketchat = (New-Fact 'rocketchat' 'running' 0 'healthy' $true 'unless-stopped' @([ordered]@{ service = 'mongodb'; condition = 'service_healthy' }, [ordered]@{ service = 'nats'; condition = 'service_started' }))
    mongodb = (New-Fact 'mongodb' 'running' 0 'healthy' $true)
    nats = (New-Fact 'nats' 'running' 0 '' $false)
    'mongodb-fix-permission' = (New-Fact 'mongodb-fix-permission' 'exited' 0 '' $false 'on-failure')
    'mongodb-init' = (New-Fact 'mongodb-init' 'exited' 0 '' $false 'on-failure')
  }
  foreach ($k in $Over.Keys) { foreach ($p in $Over[$k].Keys) { $f[$k][$p] = $Over[$k][$p] } }
  return @($f.Values)
}
$rcm = $m.rocketchat
$lc = Get-DeploymentLifecycle -Containers (New-RcFacts) -Manifest $rcm
$svc = { param($l, $n) @($l.services | Where-Object { $_.service -eq $n })[0] }
Test-Condition 'lifecycle: Rocket.Chat shows 3/3 running and 2 setup jobs completed (not "running 3/5")' ($lc.headline -eq "3/3 running $dot 2 setup jobs completed" -and $lc.state -eq 'running' -and $lc.counts.longRunning -eq 3 -and $lc.counts.running -eq 3 -and $lc.counts.jobs -eq 2 -and $lc.counts.jobsCompleted -eq 2) $lc.headline
Test-Condition 'lifecycle: the setup jobs are completed successfully with exit code 0, expected to exit (declared by the manifest)' (@($lc.services | Where-Object { $_.lifecycle -eq 'run-once' -and $_.status.key -eq 'completed' -and $_.exitCode -eq 0 -and $_.expectedToExit -eq $true -and $_.roleSource -eq 'manifest' }).Count -eq 2 -and (& $svc $lc 'mongodb-init').label -eq 'MongoDB replica-set initialization') ''
$nats = & $svc $lc 'nats'
Test-Condition 'lifecycle: NATS runs without a health check: "readiness not verified", never "healthy"' ($nats.status.key -eq 'running-unverified' -and $nats.health -eq 'none' -and $nats.status.label -match 'no health check' -and -not $lc.health.verified -and $lc.health.text -match 'No failures detected' -and $lc.health.text -match 'no health check') "$($nats.status.key) / $($lc.health.text)"
Test-Condition 'lifecycle: Rocket.Chat and MongoDB are running and healthy (their health checks pass)' ((& $svc $lc 'rocketchat').status.key -eq 'healthy' -and (& $svc $lc 'mongodb').status.key -eq 'healthy' -and (& $svc $lc 'mongodb').role -eq 'database') ''
Test-Condition 'lifecycle: dependencies are reported both ways (Rocket.Chat waits for MongoDB healthy and NATS started)' ((@((& $svc $lc 'rocketchat').dependsOn | ForEach-Object { "$($_.service):$($_.condition)" }) -join ',') -eq 'mongodb:service_healthy,nats:service_started' -and @((& $svc $lc 'mongodb').dependents | Where-Object { $_.service -eq 'rocketchat' }).Count -eq 1) ''
Test-Condition 'lifecycle: long-running services are listed first, then the setup jobs' ((@($lc.services | ForEach-Object { $_.lifecycle }) -join ',') -eq 'long-running,long-running,long-running,run-once,run-once' -and $lc.services[0].service -eq 'rocketchat') (@($lc.services | ForEach-Object { $_.service }) -join ',')
$lcF = Get-DeploymentLifecycle -Containers (New-RcFacts @{ 'mongodb-init' = @{ exitCode = 1 } }) -Manifest $rcm
Test-Condition 'lifecycle: a failed setup job is a failure ("1 setup job failed"), not a completed job' ($lcF.state -eq 'failed' -and (& $svc $lcF 'mongodb-init').status.key -eq 'job-failed' -and $lcF.headline -match '1 setup job failed' -and $lcF.health.text -match 'MongoDB replica-set initialization') $lcF.headline
$lcS = Get-DeploymentLifecycle -Containers (New-RcFacts @{ rocketchat = @{ state = 'exited'; exitCode = 137; health = 'unhealthy' } }) -Manifest $rcm
Test-Condition 'lifecycle: an application container that stopped while the others run stays visible as stopped unexpectedly' ($lcS.state -eq 'failed' -and (& $svc $lcS 'rocketchat').status.key -eq 'stopped-unexpectedly' -and $lcS.headline -match "^2/3 running") $lcS.headline
$lcA = Get-DeploymentLifecycle -Containers (New-RcFacts @{ rocketchat = @{ state = 'exited'; exitCode = 143 }; mongodb = @{ state = 'exited'; exitCode = 0 }; nats = @{ state = 'exited'; exitCode = 0 } }) -Manifest $rcm
Test-Condition 'lifecycle: a whole app stopped by the user is "Stopped", not a failure' ($lcA.state -eq 'stopped' -and $lcA.headline -eq 'Stopped (0/3 running)' -and (& $svc $lcA 'rocketchat').status.key -eq 'stopped') $lcA.headline
$lcU = Get-DeploymentLifecycle -Containers (New-RcFacts @{ 'mongodb-init' = @{ state = 'running' } }) -Manifest $rcm
Test-Condition 'lifecycle: a setup job still running is "in progress"' ((& $svc $lcU 'mongodb-init').status.key -eq 'job-running' -and $lcU.headline -match '1 setup job running') $lcU.headline
# Without a manifest: roles from Compose facts only.
$lcN = Get-DeploymentLifecycle -Containers (New-RcFacts)
Test-Condition 'roles without a manifest: restart policies give 3 services and 2 jobs; the jobs are marked as inferred' ($lcN.headline -eq "3/3 running $dot 2 setup jobs completed" -and @($lcN.services | Where-Object { $_.lifecycle -eq 'run-once' -and $_.roleSource -eq 'inferred' }).Count -eq 2) $lcN.headline
$dep = @((New-Fact 'web' 'running' 0 '' $false 'unless-stopped' @([ordered]@{ service = 'migrate'; condition = 'service_completed_successfully' })), (New-Fact 'migrate' 'exited' 0 '' $false 'no'))
$lcD = Get-DeploymentLifecycle -Containers $dep
Test-Condition 'roles: a service others wait for with service_completed_successfully is a one-time job (from Compose)' ((& $svc $lcD 'migrate').lifecycle -eq 'run-once' -and (& $svc $lcD 'migrate').roleSource -eq 'compose' -and (& $svc $lcD 'migrate').status.key -eq 'completed') (& $svc $lcD 'migrate').roleReason
$unk = @((New-Fact 'web' 'running'), (New-Fact 'tool' 'exited' 0 '' $false 'no'))
$lcK = Get-DeploymentLifecycle -Containers $unk
Test-Condition 'roles: exit code 0 alone never makes a "completed job": an undeclared service is reported neutrally with its role unknown' ((& $svc $lcK 'tool').lifecycle -eq 'unknown' -and (& $svc $lcK 'tool').status.key -eq 'exited-unknown' -and (& $svc $lcK 'tool').status.tone -eq 'neutral' -and $lcK.headline -match '1 with unknown role' -and $lcK.counts.jobsCompleted -eq 0) $lcK.headline
$lcP = Get-DeploymentLifecycle -Defined @('rocketchat', 'mongodb', 'nats', 'mongodb-fix-permission', 'mongodb-init') -Manifest $rcm -Prepared
Test-Condition 'lifecycle: a prepared installation without containers is "Prepared, not started"' ($lcP.state -eq 'prepared' -and $lcP.headline -eq 'Prepared, not started' -and -not @($lcP.services | Where-Object { $_.status.key -ne 'not-started' }).Count) $lcP.headline
$im = $m.immich
$lcO = Get-DeploymentLifecycle -Containers @((New-Fact 'immich-server' 'running' 0 '' $false 'unless-stopped' @() 'im'), (New-Fact 'immich-redis' 'running' 0 'healthy' $true 'unless-stopped' @() 'im'), (New-Fact 'immich-db' 'running' 0 '' $false 'unless-stopped' @() 'im')) -Manifest $im -Defined @('immich-server', 'immich-redis', 'immich-db') -Inactive @('immich-machine-learning')
Test-Condition 'lifecycle: an optional service turned off is "Optional, not enabled" and not counted' ((& $svc $lcO 'immich-machine-learning').status.key -eq 'optional-inactive' -and $lcO.headline -eq '3/3 running' -and $lcO.counts.optional -eq 1) $lcO.headline
$cand = @(Get-JobCleanupCandidates $lc); $candN = @(Get-JobCleanupCandidates $lcN)
Test-Condition 'tidy up: only completed jobs whose role is declared (manifest or Compose) qualify; inferred jobs and services never do' ((@($cand | ForEach-Object { $_.container }) -join ',') -eq 'rc-mongodb-fix-permission,rc-mongodb-init' -and $candN.Count -eq 0 -and @(Get-JobCleanupCandidates $lcF).Count -eq 1) ''
# docker inspect parsing (no environment or command copied).
$inspect = @'
{"Id":"0123456789abcdef0123","Name":"/rc-rocketchat","Image":"sha256:abc","RestartCount":0,
 "Config":{"Image":"registry.rocket.chat/rocketchat/rocket.chat:8.9.0","Env":["MONGO_URL=mongodb://secret@x","TOKEN=supersecret123"],"Cmd":["node","--password=hunter22"],
   "Labels":{"com.docker.compose.project":"rc","com.docker.compose.service":"rocketchat","com.docker.compose.depends_on":"mongodb:service_healthy:false,nats:service_started:false","org.traefik-proxy.app":"rocket-chat"},
   "Healthcheck":{"Test":["CMD","nc","-zv","rocketchat","3000"]}},
 "State":{"Status":"running","ExitCode":0,"StartedAt":"2026-10-23T09:47:26Z","FinishedAt":"0001-01-01T00:00:00Z","Health":{"Status":"healthy"}},
 "HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},
 "NetworkSettings":{"Ports":{"3000/tcp":[{"HostIp":"127.0.0.1","HostPort":"3100"}]},"Networks":{"proxynet":{"IPAddress":"172.25.0.9","Aliases":["rc-rocketchat","rocketchat"],"DNSNames":["rc-rocketchat","rocketchat","0123456789ab"]}}},
 "Mounts":[{"Type":"volume","Name":"rc_uploads","Destination":"/app/uploads","RW":true}]}
'@ | ConvertFrom-Json
$pf = ConvertFrom-ContainerInspect $inspect
$pfJson = $pf | ConvertTo-Json -Depth 8 -Compress
Test-Condition 'inspect: depends_on, health check, restart policy, networks (DNS names), ports and volumes are read' ($pf.service -eq 'rocketchat' -and $pf.hasHealthcheck -and $pf.health -eq 'healthy' -and $pf.restartPolicy -eq 'unless-stopped' -and (@($pf.dependsOn | ForEach-Object { $_.condition }) -join ',') -eq 'service_healthy,service_started' -and (@($pf.networks[0].dnsNames) -join ',') -eq 'rc-rocketchat,rocketchat' -and $pf.ports[0].hostPort -eq '3100' -and $pf.mounts[0].name -eq 'rc_uploads') $pfJson
Test-Condition 'inspect: environment values and the command line are never copied' ($pfJson -notmatch 'supersecret123|hunter22|secret@x|MONGO_URL') $pfJson

# --- Part 1c: instances and duplicate detection ---------------------------------------------------------------------------
$recA = [pscustomobject]@{ project = 'rocket-chat'; appId = 'rocket-chat'; name = 'Rocket.Chat'; folder = 'C:\apps\rocket-chat'; installedAt = '2026-10-21T21:34:33'; prepared = $true; localPort = 3100 }
$recB = [pscustomobject]@{ project = 'rocketchat'; appId = 'rocket-chat'; name = 'Rocket.Chat'; folder = 'C:\apps\rocketchat'; installedAt = '2026-10-23T02:46:04'; prepared = $true; localPort = 3101 }
$recC = [pscustomobject]@{ instanceId = 'i-0123456789ab'; project = 'chat-test'; appId = 'rocketchat'; name = 'Rocket.Chat'; label = 'Testing'; origin = 'installed'; folder = 'C:\apps\chat-test'; prepared = $false }
$iA = ConvertTo-AppInstance $recA $apps; $iB = ConvertTo-AppInstance $recB $apps; $iC = ConvertTo-AppInstance $recC $apps
Test-Condition 'instances: a record written as rocket-chat resolves to the application rocketchat and keeps a stable instance id' ($iA.appId -eq 'rocketchat' -and $iA.applicationId -eq 'rocketchat' -and $iA.recordedAppId -eq 'rocket-chat' -and $iA.instanceId -eq 'legacy-rocket-chat' -and $iC.instanceId -eq 'i-0123456789ab' -and $iC.label -eq 'Testing') ''
$found = @(Find-AppInstallations 'rocketchat' @($iA, $iB, $iC))
Test-Condition 'instances: one application with several installations lists each of them (rocket-chat, rocketchat, chat-test)' ((@($found | ForEach-Object { $_.project }) -join ',') -eq 'rocket-chat,rocketchat,chat-test' -and $found[0].reason -match 'an alias') ''
$dis = @(Find-AppInstallations 'dispatcharr' @(ConvertTo-AppInstance ([pscustomobject]@{ project = 'disp2'; appId = 'dispatcharr-modular'; name = 'Dispatcharr'; folder = 'C:\x' }) $apps))
Test-Condition 'instances: an installation of a variant counts as an installation of the application' ($dis.Count -eq 1 -and $dis[0].project -eq 'disp2') ''
$facts = @(
  (New-Fact 'app' 'running' 0 '' $false 'unless-stopped' @() 'old-diun' 'crazymax/diun:4.30.0'),
  (New-Fact 'watchtower' 'running' 0 '' $false 'unless-stopped' @() 'wt' 'docker.io/containrrr/watchtower:latest'),
  (New-Fact 'postgres' 'running' 0 '' $false 'unless-stopped' @() 'ccna' 'postgres:16-alpine'),
  (New-Fact 'web' 'running' 0 '' $false 'unless-stopped' @() 'ccna' 'node:20'),
  (New-Fact 'mongodb' 'running' 0 '' $false 'unless-stopped' @() 'mydb' 'docker.io/mongodb/mongodb-community-server:8.2-ubi8'),
  (New-Fact 'rocketchat' 'running' 0 '' $false 'unless-stopped' @() 'chat-elsewhere' 'registry.rocket.chat/rocketchat/rocket.chat:7.0.0'),
  (New-Fact 'server' 'running' 0 '' $false 'unless-stopped' @() 'labelled' 'example/custom:1'))
$facts[6].app = 'rocket-chat'
$facts += (New-Fact 'traefik' 'running' 0 '' $false 'unless-stopped' @() 'other-proxy' 'traefik:v3.6.1'), (New-Fact 'whoami' 'running' 0 '' $false 'unless-stopped' @() 'other-proxy' 'traefik/whoami:v1.12.0')
$un = @(Get-UnregisteredInstallations $facts $apps @('traefik-ext1'))
$byP = @{}; foreach ($u in $un) { $byP[$u.project] = $u }
Test-Condition 'existing installations: Diun and Watchtower containers are still recognized (retired apps stay discoverable)' ($byP.ContainsKey('old-diun') -and $byP['old-diun'].appId -eq 'diun' -and $byP['old-diun'].availability -eq 'offered' -and $byP.ContainsKey('wt') -and $byP['wt'].appId -eq 'watchtower') ((@($un | ForEach-Object { "$($_.project)=$($_.appId)" })) -join ',')
Test-Condition 'existing installations: a database inside another app (PostgreSQL, MongoDB) never makes it an installation of anything' (-not $byP.ContainsKey('ccna') -and -not $byP.ContainsKey('mydb')) ((@($un | ForEach-Object { "$($_.project)=$($_.appId)" })) -join ',')
Test-Condition 'existing installations: a proxy deployment''s own test backend (whoami next to Traefik) is not the HTTP echo app' (-not $byP.ContainsKey('other-proxy')) ''
Test-Condition 'existing installations: the app''s own image or the manager''s label identifies an unregistered Rocket.Chat' ($byP['chat-elsewhere'].appId -eq 'rocketchat' -and $byP['chat-elsewhere'].reason -match 'image of Rocket.Chat' -and $byP['labelled'].appId -eq 'rocketchat' -and $byP['labelled'].reason -match 'label') ''
$all = @(Find-AppInstallations 'rocketchat' @($iA) $un)
Test-Condition 'duplicates: registered and unregistered installations are both reported before a new one' ((@($all | ForEach-Object { "$($_.source):$($_.project)" }) -join ',') -eq 'registry:rocket-chat,docker:chat-elsewhere,docker:labelled') ''
# Removal inventory: shared volumes and networks are never deleted; adopted projects keep their data.
$me = @((New-Fact 'web' 'running' 0 '' $false 'unless-stopped' @() 'shop'), (New-Fact 'db' 'running' 0 '' $false 'unless-stopped' @() 'shop'))
$me[0].networks = @([ordered]@{ name = 'proxynet'; ip = '1'; dnsNames = @() }, [ordered]@{ name = 'shop_internal'; ip = '2'; dnsNames = @() }); $me[1].networks = @([ordered]@{ name = 'shop_internal'; ip = '3'; dnsNames = @() }, [ordered]@{ name = 'legacy-net'; ip = '4'; dnsNames = @() })
$me[0].mounts = @([ordered]@{ type = 'volume'; name = 'shop_uploads'; target = '/up'; source = ''; readOnly = $false }); $me[1].mounts = @([ordered]@{ type = 'volume'; name = 'common-data'; target = '/data'; source = ''; readOnly = $false }, [ordered]@{ type = 'volume'; name = ('f' * 64); target = '/data/configdb'; source = ''; readOnly = $false })
$other = New-Fact 'x' 'running' 0 '' $false 'unless-stopped' @() 'other'
$other.mounts = @([ordered]@{ type = 'volume'; name = 'common-data'; target = '/d'; source = ''; readOnly = $false }); $other.networks = @([ordered]@{ name = 'legacy-net'; ip = '9'; dnsNames = @() }, [ordered]@{ name = 'proxynet'; ip = '8'; dnsNames = @() })
$shop = ConvertTo-AppInstance ([pscustomobject]@{ project = 'shop'; appId = 'echo'; name = 'Shop'; folder = 'C:\apps\shop' }) $apps
$inv = Get-RemovalInventory -Instance $shop -Containers $me -All (@($me) + $other) -ProxyNetwork 'proxynet' -Routes @([pscustomobject]@{ name = 'shop'; hostnames = @('shop.example.com') }) -CloudflareHosts @('shop.example.com') -IdentityApps @('dm-shop')
$v = @{}; foreach ($x in $inv.volumes) { $v[$x.name] = $x }; $n = @{}; foreach ($x in $inv.networks) { $n[$x.name] = $x }
Test-Condition 'removal inventory: a volume shared with another project is protected and data deletion is refused for the app' ($v['common-data'].action -match 'also used by other containers' -and @($v['common-data'].sharedWith) -contains 'other-x' -and -not $inv.dataDeletionAllowed -and $v['shop_uploads'].createdByManager -and $v[('f' * 64)].anonymous -and $v[('f' * 64)].createdByManager) ($inv.volumes | ConvertTo-Json -Compress -Depth 4)
Test-Condition 'removal inventory: the shared proxy network and networks of other projects are kept; only the app''s private network goes' ($n['proxynet'].action -match 'shared proxy network' -and $n['legacy-net'].action -match 'also used' -and $n['shop_internal'].action -match 'removed with the containers') ($inv.networks | ConvertTo-Json -Compress -Depth 4)
Test-Condition 'removal inventory: routes block removal; hostnames, Cloudflare records and authentik apps are listed as left unchanged' (@($inv.blocking).Count -eq 1 -and ($inv.references -join ' ') -match 'shop\.example\.com' -and ($inv.references -join ' ') -match 'dm-shop') ''
$adopted = ConvertTo-AppInstance ([pscustomobject]@{ project = 'shop'; appId = 'echo'; name = 'Shop'; folder = 'C:\apps\shop'; origin = 'adopted' }) $apps
$invA = Get-RemovalInventory -Instance $adopted -Containers @($me[0]) -All @($me[0]) -ProxyNetwork 'proxynet'
Test-Condition 'removal inventory: an adopted project''s volumes and files are never deleted (the manager did not create them)' (-not $invA.createdByManager -and -not $invA.dataDeletionAllowed -and $invA.volumes[0].action -match 'not created by the manager') ''

# --- Part 2: web API on a throwaway instance (never started) -------------------------------------------------------------
$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-alc-$id"
# Earlier runs killed hard (out of memory, closed window) skip `finally`: remove what their dead owners left, then
# register this run's prefix so an interruption of this run is swept the same way (tests\Find-TestOrphans.ps1 lists them).
foreach ($orphanLine in (Invoke-TestOrphanSweep)) { Write-Host "  [orphans] $orphanLine" -ForegroundColor DarkYellow }
Register-TestRun -Prefix "tpm-alc-$id" -Suite 'Test-AppLifecycle'
Register-TestRun -Prefix "tpm-alcfx-$id" -Suite 'Test-AppLifecycle'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$ui = $null; $mock = $null; $fixProject = "tpm-alcfx-$id"; $fixDir = Join-Path $work 'fixture'; $dockerUp = $false
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N')
try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-alc-$id"
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  # Registry: an installed Rocket.Chat (folder present, no containers: prepared) plus a second prepared record written
  # as 'rocket-chat' (the shape of the two production records), each with its own folder.
  $appsRoot = Join-Path $work 'apps'
  foreach ($p in 'rc-one', 'rc-two') { New-Item -ItemType Directory -Force -Path (Join-Path $appsRoot $p) | Out-Null; [IO.File]::WriteAllText((Join-Path $appsRoot "$p\compose.yaml"), "name: $p`nservices:`n  rocketchat:`n    image: x`n    labels:`n      org.traefik-proxy.project: $p`n") }
  $records = @([ordered]@{ project = 'rc-one'; appId = 'rocket-chat'; name = 'Rocket.Chat'; folder = (Join-Path $appsRoot 'rc-one'); installedAt = '2026-10-21T21:34:33'; prepared = $true; localPort = 3100 },
    [ordered]@{ project = 'rc-two'; appId = 'rocket-chat'; name = 'Rocket.Chat'; folder = (Join-Path $appsRoot 'rc-two'); installedAt = '2026-10-23T02:46:04'; prepared = $true; localPort = 3101 })
  [IO.File]::WriteAllText((Join-Path $install 'config\apps.json'), (([ordered]@{ version = 1; apps = $records }) | ConvertTo-Json -Depth 5))
  [IO.File]::WriteAllText((Join-Path $install 'config\services.json'), '{"version":1,"services":[]}')
  $svcHash = (Get-FileHash (Join-Path $install 'config\services.json')).Hash
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $null = Connect-WebUi $ui
  $c = Invoke-WebUi $ui GET '/api/catalog'
  $ids = @($c.Data.apps | ForEach-Object { $_.id })
  Test-Condition 'api catalog: Arcane, Portainer, What''s Up Docker and Diun are offered; Watchtower is not a new-install choice' ($c.Status -eq 200 -and $ids -contains 'arcane' -and $ids -contains 'portainer' -and $ids -contains 'whats-up-docker' -and $ids -contains 'diun' -and $ids -notcontains 'watchtower' -and (@($c.Data.retired | ForEach-Object { $_.id }) -join ',') -eq 'watchtower') ($ids -join ',')
  $cd = @($c.Data.apps | Where-Object { $_.id -eq 'diun' })[0]; $ce = @($c.Data.apps | Where-Object { $_.id -eq 'echo' })[0]
  Test-Condition 'api catalog: entries carry architectures, authentication fit, limitations, components and host compatibility' ($cd.headless -and (@($cd.components) -join ',') -eq 'app,support' -and @($ce.architectures) -contains 'amd64' -and $ce.authentication.forwardAuth -eq 'compatible' -and @($ce.compatibility | Where-Object { $_.label -eq 'CPU architecture' -and $_.state -eq 'ok' }).Count -eq 1 -and $c.Data.host.architecture -eq 'amd64') ''
  $rc = @($c.Data.apps | Where-Object { $_.id -eq 'rocketchat' })[0]
  Test-Condition 'api catalog: one Rocket.Chat entry listing both installations; Dispatcharr''s modular compose is a variant under Dispatcharr' (@($c.Data.apps | Where-Object { $_.name -eq 'Rocket.Chat' }).Count -eq 1 -and (@($rc.instances | ForEach-Object { $_.project }) -join ',') -eq 'rc-one,rc-two' -and $ids -notcontains 'dispatcharr-modular' -and (@((@($c.Data.apps | Where-Object { $_.id -eq 'dispatcharr' })[0]).variants | ForEach-Object { $_.id }) -join ',') -eq 'dispatcharr-modular' -and $ids -notcontains 'postgresql') ''
  $pw = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'watchtower' }
  Test-Condition 'api plan: installing a retired app is refused (410), also through the API' ($pw.Status -eq 410 -and $pw.Body -match 'no longer offered') $pw.Body
  $df = Invoke-WebUi $ui GET '/api/catalog/defaults?id=rocketchat'
  # (On a PC that runs Rocket.Chat itself, its Compose project is also reported, as not registered in this instance.)
  Test-Condition 'api defaults: both registered installations are reported (the alias rocket-chat resolves)' ($df.Status -eq 200 -and (@($df.Data.existing | Where-Object { $_.source -eq 'registry' } | ForEach-Object { $_.project }) -join ',') -eq 'rc-one,rc-two') $df.Body
  $p1 = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'rocketchat'; startNow = $false }
  $dupCheck = @($p1.Data.checks | Where-Object { $_.label -eq 'Not already installed' })[0]
  Test-Condition 'api plan: no silent duplicate: the plan is blocked while Rocket.Chat is installed' ($p1.Status -eq 200 -and -not $p1.Data.canApply -and $dupCheck.state -eq 'failed' -and $dupCheck.message -match 'rc-one, rc-two') ($p1.Data.checks | ConvertTo-Json -Compress -Depth 4)
  $p2 = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'rocketchat'; startNow = $false; anotherInstance = $true; instanceLabel = 'Testing' }
  $another = @($p2.Data.checks | Where-Object { $_.label -eq 'Another instance' })[0]
  Test-Condition 'api plan: an intentional second instance is allowed, labelled, with its own project, folder and port' ($another.state -eq 'warning' -and $another.message -match "labelled 'Testing'" -and $p2.Data.project -eq 'rocketchat' -and $p2.Data.instanceLabel -eq 'Testing' -and -not @($p2.Data.checks | Where-Object { $_.label -eq 'Not already installed' }).Count) ($p2.Data.checks | ConvertTo-Json -Compress -Depth 4)
  $pl = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'rocketchat'; anotherInstance = $true; instanceLabel = '<script>' }
  Test-Condition 'api plan: an instance label with markup is refused' ($pl.Status -eq 400) ''
  $a0 = Invoke-WebUi $ui GET '/api/apps'
  $one = @($a0.Data.apps | Where-Object { $_.project -eq 'rc-one' })[0]
  Test-Condition 'api apps: each installation is its own deployment (prepared, siblings named), resolved to rocketchat' ($a0.Status -eq 200 -and @($a0.Data.apps).Count -eq 2 -and $one.lifecycle.state -eq 'prepared' -and $one.appId -eq 'rocketchat' -and (@($one.siblings) -join ',') -eq 'rc-two') ''
  $before = Get-ChildItem -LiteralPath (Join-Path $appsRoot 'rc-two') -Force | ForEach-Object { "$($_.Name):$($_.Length)" }
  $ar = Invoke-WebUi $ui POST '/api/apps/archive' @{ project = 'rc-two'; confirm = $true }
  $a1 = Invoke-WebUi $ui GET '/api/apps'
  $after = Get-ChildItem -LiteralPath (Join-Path $appsRoot 'rc-two') -Force | ForEach-Object { "$($_.Name):$($_.Length)" }
  Test-Condition 'archive: the record is hidden and listed as archived; its folder, files and routes are untouched' ($ar.Status -eq 200 -and (@($a1.Data.apps | ForEach-Object { $_.project }) -join ',') -eq 'rc-one' -and (@($a1.Data.archived | ForEach-Object { $_.project }) -join ',') -eq 'rc-two' -and (($before -join '|') -eq ($after -join '|')) -and (Get-FileHash (Join-Path $install 'config\services.json')).Hash -eq $svcHash) $ar.Body
  $act = Invoke-WebUi $ui POST '/api/apps/action' @{ project = 'rc-two'; action = 'start'; confirm = $true }
  Test-Condition 'archive: an archived record cannot be started or changed until it is restored' ($act.Status -eq 409) $act.Body
  $df2 = Invoke-WebUi $ui GET '/api/catalog/defaults?id=rocketchat'
  Test-Condition 'archive: the archived record is still shown when installing (as archived)' (@($df2.Data.existing | Where-Object { $_.project -eq 'rc-two' -and $_.archived }).Count -eq 1) ''
  $rs = Invoke-WebUi $ui POST '/api/apps/restore' @{ project = 'rc-two'; confirm = $true }
  $a2 = Invoke-WebUi $ui GET '/api/apps'
  Test-Condition 'archive: restoring brings the record back unchanged' ($rs.Status -eq 200 -and @($a2.Data.apps).Count -eq 2 -and @($a2.Data.archived).Count -eq 0) ''

  # An installation interrupted while its files were written (installState 'writing'): listed as such, not managed,
  # and discarded on request: generated files and the record go; the user's own files and the folder holding them stay.
  $intFolder = Join-Path $appsRoot 'int-one'
  New-Item -ItemType Directory -Force -Path $intFolder | Out-Null
  [IO.File]::WriteAllText((Join-Path $intFolder 'compose.yaml'), "name: int-one`nservices:`n  app:`n    image: x`n    labels:`n      org.traefik-proxy.project: int-one`n")
  [IO.File]::WriteAllText((Join-Path $intFolder 'compose.database.yaml'), "services:`n  db:`n    image: y`n")
  [IO.File]::WriteAllText((Join-Path $intFolder 'my-notes.txt'), 'mine')
  $regPath = Join-Path $install 'config\apps.json'
  $reg = [IO.File]::ReadAllText($regPath) | ConvertFrom-Json
  $reg.apps = @($reg.apps) + [pscustomobject][ordered]@{ instanceId = 'i-int'; project = 'int-one'; appId = 'rocketchat'; name = 'Rocket.Chat'; folder = $intFolder; installedAt = '2026-11-16T10:00:00'; prepared = $true; composeFiles = @('compose.yaml', 'compose.database.yaml'); installState = 'writing' }
  [IO.File]::WriteAllText($regPath, ($reg | ConvertTo-Json -Depth 6))
  $li = Invoke-WebUi $ui GET '/api/apps'
  $intView = @($li.Data.apps | Where-Object { $_.project -eq 'int-one' })[0]
  $intStart = Invoke-WebUi $ui POST '/api/apps/action' @{ project = 'int-one'; action = 'start'; confirm = $true }
  $intNoConfirm = Invoke-WebUi $ui POST '/api/apps/discard' @{ project = 'int-one' }
  $notInt = Invoke-WebUi $ui POST '/api/apps/discard' @{ project = 'rc-one'; confirm = $true }
  Test-Condition 'interrupted installation: listed with its state and Compose files; managing it is refused (409); discarding needs confirmation and only applies to interrupted ones' ($intView.installState -eq 'writing' -and (@($intView.composeFiles) -join ',') -eq 'compose.yaml,compose.database.yaml' -and $intStart.Status -eq 409 -and $intStart.Body -match 'interrupted' -and $intNoConfirm.Status -eq 400 -and $notInt.Status -eq 409) "$($intStart.Status) $($intNoConfirm.Status) $($notInt.Status)"
  $disc = Invoke-WebUi $ui POST '/api/apps/discard' @{ project = 'int-one'; confirm = $true }
  $after = @((Invoke-WebUi $ui GET '/api/apps').Data.apps | ForEach-Object { $_.project })
  Test-Condition 'interrupted installation: discard removes the generated files and the record, keeps the folder with the user''s own file' ($disc.Status -eq 200 -and $disc.Data.folderKept -and -not (Test-Path -LiteralPath (Join-Path $intFolder 'compose.yaml')) -and -not (Test-Path -LiteralPath (Join-Path $intFolder 'compose.database.yaml')) -and (Test-Path -LiteralPath (Join-Path $intFolder 'my-notes.txt')) -and $after -notcontains 'int-one' -and $after -contains 'rc-one') $disc.Body
  $noConf = Invoke-WebUi $ui POST '/api/apps/archive' @{ project = 'rc-two' }
  Test-Condition 'archive: requires an explicit confirmation' ($noConf.Status -eq 400) ''

  # --- Part 3: disposable Compose project (Docker) -----------------------------------------------------------------------
  if ($SkipDocker) { Add-Result 'SKIP' 'docker: disposable Compose project' '-SkipDocker' }
  elseif (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'docker: disposable Compose project' 'Docker engine not running' }
  else {
    $img = ([regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'compose.yaml')), 'image: (traefik:v[0-9.]+@sha256:[0-9a-f]{64})')).Groups[1].Value
    if ((Invoke-Docker image inspect $img).ExitCode -ne 0) { Add-Result 'SKIP' 'docker: disposable Compose project' "image $img not on this PC (nothing is downloaded)" }
    else {
      $snap = { $map = @{}; foreach ($l in (Invoke-Docker ps -a --format '{{.Names}}').Output) { if ($l -and -not $l.StartsWith($fixProject)) { $map[$l] = ((Invoke-Docker inspect $l --format '{{.Id}} {{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim() } }; $map }
      $engineBefore = & $snap
      New-Item -ItemType Directory -Force -Path $fixDir | Out-Null
      $secret = 'fixtureSecret_' + [Guid]::NewGuid().ToString('N')
      $yaml = @"
name: $fixProject
services:
  app:
    image: $img
    entrypoint: ['sh', '-c', 'exec sleep 100000']
    restart: unless-stopped
    environment:
      APP_SECRET: '$secret'
    healthcheck: { test: ['CMD', 'true'], interval: 2s, timeout: 2s, retries: 3 }
    depends_on:
      migrate: { condition: service_completed_successfully }
      bus: { condition: service_started }
    labels: { org.traefik-proxy.project: $fixProject, org.traefik-proxy.app: echo }
  bus:
    image: $img
    entrypoint: ['sh', '-c', 'exec sleep 100000']
    restart: unless-stopped
    labels: { org.traefik-proxy.project: $fixProject }
  migrate:
    image: $img
    entrypoint: ['sh', '-c', 'echo migrated; exit 0']
    restart: 'no'
    labels: { org.traefik-proxy.project: $fixProject }
  perms:
    image: $img
    entrypoint: ['sh', '-c', 'echo fixed; exit 0']
    restart: on-failure
    labels: { org.traefik-proxy.project: $fixProject }
  seed:
    image: $img
    entrypoint: ['sh', '-c', 'echo seed failed; exit 3']
    restart: on-failure:1
    labels: { org.traefik-proxy.project: $fixProject }
"@
      [IO.File]::WriteAllText((Join-Path $fixDir 'docker-compose.yml'), $yaml)
      $up = Invoke-Docker compose --project-directory $fixDir -f (Join-Path $fixDir 'docker-compose.yml') up -d
      $dockerUp = $true
      Test-Condition 'docker: the disposable project starts (images already on this PC)' ($up.ExitCode -eq 0) (@($up.Output) -join ' ')
      $deadline = (Get-Date).AddSeconds(90)
      do {
        $fx = @(Invoke-Docker ps -a --filter "label=com.docker.compose.project=$fixProject" --format '{{.Names}}|{{.State}}|{{.Status}}').Output
        $settled = (@($fx | Where-Object { $_ -match '-seed-1\|exited' }).Count -and @($fx | Where-Object { $_ -match '-app-1\|running\|.*\(healthy\)' }).Count)
        if ($settled) { break }; Start-Sleep -Seconds 2
      } while ((Get-Date) -lt $deadline)
      $ids2 = @((Invoke-Docker ps -a -q --filter "label=com.docker.compose.project=$fixProject").Output | Where-Object { $_ })
      $real = @(foreach ($x in ((@((Invoke-Docker inspect $ids2).Output) -join "`n") | ConvertFrom-Json)) { ConvertFrom-ContainerInspect $x })
      $lr = Get-DeploymentLifecycle -Containers $real
      $st = @{}; foreach ($s in $lr.services) { $st[$s.service] = $s }
      Test-Condition 'docker: real inspect facts: app healthy, bus running without a health check' ($st['app'].status.key -eq 'healthy' -and $st['bus'].status.key -eq 'running-unverified') "app=$($st['app'].status.key) bus=$($st['bus'].status.key)"
      Test-Condition 'docker: migrate is a completed job because app waits for it (Compose), perms is inferred from on-failure' ($st['migrate'].status.key -eq 'completed' -and $st['migrate'].roleSource -eq 'compose' -and $st['perms'].status.key -eq 'completed' -and $st['perms'].roleSource -eq 'inferred') "migrate=$($st['migrate'].roleSource) perms=$($st['perms'].roleSource)"
      Test-Condition 'docker: a setup job that failed (exit 3 after its retry) is reported as failed' ($st['seed'].status.key -eq 'job-failed' -and $st['seed'].exitCode -eq 3 -and $lr.state -eq 'failed' -and $lr.headline -match "2/2 running $dot 2 setup jobs completed $dot 1 setup job failed") $lr.headline
      # Adopt it through the API (review, then adopt): the manager did not generate it, and its file is
      # docker-compose.yml, one of the four standard Compose file names.
      $ap = Invoke-WebUi $ui POST '/api/apps/adopt/plan' @{ project = $fixProject }
      $ad = Invoke-WebUi $ui POST '/api/apps/adopt' @{ project = $fixProject; reviewKey = $(if ($ap.Status -eq 200) { $ap.Data.reviewKey } else { '' }); label = 'Fixture'; confirm = $true }
      $rec = @(([IO.File]::ReadAllText((Join-Path $install 'config\apps.json')) | ConvertFrom-Json).apps | Where-Object { $_.project -eq $fixProject })[0]
      Test-Condition 'adopt: a project whose file is docker-compose.yml is recognized (label), reviewed and adopted; the file name is recorded' ($ap.Status -eq 200 -and $ad.Status -eq 200 -and $ap.Data.canAdopt -and $ap.Data.composeFile -eq 'docker-compose.yml' -and $rec -and $rec.origin -eq 'adopted' -and $rec.composeFile -eq 'docker-compose.yml' -and $rec.label -eq 'Fixture') ("$($ap.Status) $($ap.Body) / $($ad.Status) $($ad.Body)")
      $det = Invoke-WebUi $ui GET "/api/apps/detail?project=$fixProject"
      Test-Condition 'api detail: services, networks with DNS names and dependencies; no environment value or secret anywhere' ($det.Status -eq 200 -and @($det.Data.lifecycle.services).Count -eq 5 -and @($det.Data.networks | Where-Object { $_.name -eq "${fixProject}_default" -and @($_.members | Where-Object { @($_.dnsNames) -contains 'app' }).Count }).Count -eq 1 -and $det.Body -notmatch [regex]::Escape($secret) -and $det.Body -notmatch 'APP_SECRET') ($det.Body.Substring(0, [Math]::Min(400, $det.Body.Length)))
      $lgs = Invoke-WebUi $ui GET "/api/apps/logs?project=$fixProject&service=seed&tail=20"
      Test-Condition 'api logs: the logs of one service (a failed job) can be read' ($lgs.Status -eq 200 -and ($lgs.Data.lines -join ' ') -match 'seed failed') ($lgs.Data.lines -join ' | ')
      $cp = Invoke-WebUi $ui POST '/api/apps/cleanup/plan' @{ project = $fixProject }
      Test-Condition 'tidy up: the preview offers only the completed job with a declared role (migrate), not perms (inferred) or seed (failed)' ($cp.Status -eq 200 -and (@($cp.Data.candidates | ForEach-Object { $_.service }) -join ',') -eq 'migrate') ($cp.Body)
      $keep = @{}; foreach ($n2 in 'app', 'bus', 'perms', 'seed') { $keep[$n2] = ((Invoke-Docker inspect "$fixProject-$n2-1" --format '{{.Id}} {{.State.StartedAt}}').Output -join '').Trim() }
      $composeBefore = (Get-FileHash (Join-Path $fixDir 'docker-compose.yml')).Hash
      $bad = Invoke-WebUi $ui POST '/api/apps/cleanup' @{ project = $fixProject; key = 'wrong'; confirm = $true }
      $go = Invoke-WebUi $ui POST '/api/apps/cleanup' @{ project = $fixProject; key = $cp.Data.key; confirm = $true }
      $gone = (Invoke-Docker inspect "$fixProject-migrate-1").ExitCode -ne 0
      $same = -not @($keep.Keys | Where-Object { ((Invoke-Docker inspect "$fixProject-$_-1" --format '{{.Id}} {{.State.StartedAt}}').Output -join '').Trim() -ne $keep[$_] }).Count
      Test-Condition 'tidy up: a stale preview is refused; applying removes only that container; others not restarted; compose.yaml unchanged' ($bad.Status -eq 409 -and $go.Status -eq 200 -and $go.Data.ok -and $gone -and $same -and (Get-FileHash (Join-Path $fixDir 'docker-compose.yml')).Hash -eq $composeBefore) $go.Body
      $det2 = Invoke-WebUi $ui GET "/api/apps/detail?project=$fixProject"
      $mg = @($det2.Data.lifecycle.services | Where-Object { $_.service -eq 'migrate' })[0]
      Test-Condition 'tidy up: afterwards the job shows "No container" (definition kept), and the app keeps running' ($mg.status.key -eq 'job-not-run' -and @($det2.Data.lifecycle.services | Where-Object { $_.service -eq 'app' -and $_.state -eq 'running' }).Count -eq 1) ''
      $rmv = Invoke-WebUi $ui POST '/api/apps/remove' @{ project = $fixProject; confirm = $true; deleteVolumes = $true; confirmText = $fixProject }
      Test-Condition 'removal: data deletion is refused for an adopted project' ($rmv.Status -eq 400 -and $rmv.Body -match 'adopted') $rmv.Body
    }
  }
} finally {
  if ($ui) { Stop-TestServer $ui }
  if ($mock) { Stop-TestServer $mock }
  if ($dockerUp) {
    $null = Invoke-Docker compose --project-directory $fixDir -f (Join-Path $fixDir 'docker-compose.yml') down -v --remove-orphans
    $left = @((Invoke-Docker ps -a -q --filter "label=com.docker.compose.project=$fixProject").Output | Where-Object { $_ })
    Test-Condition 'cleanup: the disposable project is gone' ($left.Count -eq 0) ''
    $engineAfter = & $snap
    $changed = @($engineBefore.Keys | Where-Object { $engineAfter[$_] -ne $engineBefore[$_] })
    Test-Condition 'isolation: every other container kept its ID, start time and state' ($changed.Count -eq 0) ($changed -join ', ')
  }
  Get-ChildItem $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  $orphaned = @(@(Complete-TestRun "tpm-alc-$id") + @(Complete-TestRun "tpm-alcfx-$id"))
  Test-Condition 'teardown: nothing with this run''s prefix is left (containers, volumes, networks, folder)' ($orphaned.Count -eq 0) ($orphaned -join ', ')
}

$fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host ("`n{0} passed, {1} failed, {2} skipped" -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $fail, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($fail) { exit 1 }
