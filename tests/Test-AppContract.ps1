#requires -version 5.1
<#
.SYNOPSIS
  Universal application contract: ownership modes, management authority, recipe trust, authentication options, the
  versioned applications registry and its migration, the unified inventory, drift detection and repair plans, pasted
  Compose / Unraid imports, route ownership and (with a throwaway instance) the applications and integration API.

.DESCRIPTION
  Part 1 (pure, no Docker, no network): lib\AppContract.psm1 and lib\Reconcile.psm1 with fixture containers and
  routes; route ownership in service definitions (lib\TraefikProxy.psm1).
  Part 2 (Docker CLI only, no containers): pasted Compose files (one file and a main file plus an override) and a
  pasted Unraid template become drafts through `docker compose config`; unsafe input is refused.
  Part 3 (throwaway instance, web API, no containers): pasted imports through POST /api/provision/import, repeated
  imports reuse the same draft, GET /api/applications, observe / forget, integration plans refused for this
  deployment's own containers, drift and repair endpoints on unknown instances.
  The live proofs of concept (an imported application and an externally owned application on a disposable
  deployment) are tests\Test-UniversalApps.ps1.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-AppContract.ps1
#>
[CmdletBinding()]
param([switch]$SkipDocker, [switch]$SkipApi)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in @('TraefikProxy', 'AppCatalog', 'SafeFetch', 'AppSources', 'AppContract', 'Reconcile', 'DockerDiscovery', 'ProvisionPolicy')) { Import-Module (Join-Path $repo "lib\$m.psm1") -Force }
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Test-Throws([string]$Name, [scriptblock]$Block, [string]$Pattern) { try { & $Block; Add-Result 'FAIL' $Name 'no error' } catch { Test-Condition $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message } }
$digest = 'sha256:' + ('b' * 64)

# Fixture containers in the DockerDiscovery inventory shape.
function New-FixtureContainer([string]$Name, [string]$Project = '', [string]$Service = '', [string]$WorkingDir = '', [string[]]$Networks = @('proxy'), [int[]]$Ports = @(8080), [string]$Id = '', [string]$Image = 'example/app:1', [string[]]$Hints = @(), [string]$State = 'running', [string]$ConfigFiles = '') {
  [ordered]@{ id = $(if ($Id) { $Id } else { ([Guid]::NewGuid().ToString('N')).Substring(0, 12) }); name = $Name; image = $Image; state = $State; health = ''
    compose = [ordered]@{ project = $Project; service = $Service; workingDir = $WorkingDir; configFiles = $ConfigFiles }
    networks = @($Networks | ForEach-Object { [ordered]@{ name = $_; ipv4 = '172.18.0.5'; aliases = @(@($Service, $Name) | Where-Object { $_ }) } })
    exposed = @($Ports | ForEach-Object { [ordered]@{ port = $_; proto = 'tcp' } }); published = @()
    ports = @($Ports | ForEach-Object { [ordered]@{ port = $_; proto = 'tcp'; guess = 'http'; score = 60; reason = '' } })
    traefik = [ordered]@{ enabled = ''; routers = @(); servicePorts = @() }; managedBy = ''; infrastructure = $false; privateService = $false; onProxyNetwork = ($Networks -contains 'proxy'); authorityHints = @($Hints) }
}

# --- Part 1a: ownership modes and management authority ---------------------------------------------------------------
$modes = Get-OwnershipModes
Test-Condition 'modes: only Managed may recreate containers or edit Compose files; Integrated may manage routes, sign-in and publication; Observed only monitors' (
  (Test-OwnershipRight 'managed' 'lifecycle') -and (Test-OwnershipRight 'managed' 'composeFiles') -and -not (Test-OwnershipRight 'integrated' 'lifecycle') -and -not (Test-OwnershipRight 'integrated' 'composeFiles') -and
  (Test-OwnershipRight 'integrated' 'routes') -and (Test-OwnershipRight 'integrated' 'protection') -and -not (Test-OwnershipRight 'observed' 'routes') -and -not (Test-OwnershipRight 'observed' 'protection') -and (Test-OwnershipRight 'observed' 'monitor') -and -not (Test-OwnershipRight 'bogus' 'monitor')) ''
$pt = Get-ManagementAuthority (New-FixtureContainer 'stack-web-1' 'stack' 'web' '/data/compose/12')
$ptl = Get-ManagementAuthority (New-FixtureContainer 'x' 'x' 'web' '/opt/x' -Hints @('io.portainer.accesscontrol.teams'))
$ar = Get-ManagementAuthority (New-FixtureContainer 'notes-web-1' 'notes' 'web' '/app/data/projects/notes')
$mc = Get-ManagementAuthority (New-FixtureContainer 'blog-web-1' 'blog' 'web' 'C:\Users\me\blog')
$cli = Get-ManagementAuthority (New-FixtureContainer 'lonely')
$dtc = Get-ManagementAuthority (New-FixtureContainer 'kuma-app-1' 'kuma' 'app' 'C:\x') @('kuma')
Test-Condition 'authority: Portainer by its stack folder (likely) or its labels (certain), Arcane by its projects folder, manual Compose, docker run, DTC by apps.json; each with evidence' (
  $pt.id -eq 'portainer' -and $pt.confidence -eq 'likely' -and $ptl.id -eq 'portainer' -and $ptl.confidence -eq 'certain' -and $ar.id -eq 'arcane' -and $mc.id -eq 'compose' -and $mc.confidence -eq 'certain' -and
  $cli.id -eq 'docker-cli' -and $dtc.id -eq 'dtc' -and @($pt.evidence).Count -and @($ar.evidence).Count -and @($cli.evidence).Count) "$($pt.id)/$($pt.confidence) $($ptl.id) $($ar.id) $($mc.id) $($cli.id) $($dtc.id)"

# --- Part 1b: recipe trust and authentication options ----------------------------------------------------------------
$cat = Get-CatalogApps -CatalogDir (Join-Path $repo 'catalog')
$kuma = @($cat | Where-Object { $_.id -eq 'uptime-kuma' })[0].manifest
$imp = [pscustomobject]@{ source = [pscustomobject]@{ type = 'imported'; kind = 'github' }; installable = $true; draft = [pscustomobject]@{ unresolved = @([pscustomobject]@{ field = 'x'; reason = 'y' }); unsupported = @() } }
$tk = Get-RecipeTrust $kuma; $ti = Get-RecipeTrust $imp
$tl = Get-RecipeTrust ([pscustomobject]@{ source = [pscustomobject]@{ type = 'imported' }; installable = $true }) ([pscustomobject]@{ trust = [pscustomobject]@{ status = 'verified-local' } })
Test-Condition 'trust: curated recipes are trusted, imports untrusted drafts while questions are open, a locally verified recipe is verified-local; trust is separate from installation success' (
  $tk.level -eq 'curated' -and $ti.level -eq 'untrusted' -and $ti.status -eq 'draft' -and $tl.level -eq 'verified-local' -and ($ti.reasons -join ' ') -match 'not automatically trustworthy') "$($tk.level) $($ti.level)/$($ti.status) $($tl.level)"
Test-Condition 'recipe refs: catalog, imported and recipe references are stable strings; unknown kinds are refused' ((Get-RecipeRef 'catalog' 'uptime-kuma' '2026.10.21') -eq 'catalog:uptime-kuma@2026.10.21' -and (Get-RecipeRef 'none' '') -eq 'none') ''
Test-Throws 'recipe refs: an unknown recipe kind throws' { Get-RecipeRef 'random' 'x' } 'Unknown recipe kind'
$jf = Get-AuthenticationOptions -Image 'jellyfin/jellyfin:10.10@sha256:abc' -IdentityReady $true
$plain = Get-AuthenticationOptions -Image 'example/notes:1' -IdentityReady $true
$pub = Get-AuthenticationOptions -Image 'example/notes:1' -IdentityReady $false -Public $true
$prot = Get-AuthenticationOptions -Image 'example/notes:1' -IdentityReady $true -Current ([pscustomobject]@{ provider = 'authentik'; verified = $false })
$opt = { param($r, $id) @($r.options | Where-Object { $_.id -eq $id })[0] }
Test-Condition 'auth options: media servers with their own clients are not recommended for ForwardAuth (native login recommended, reason given); browser apps get ForwardAuth when authentik is ready' (
  $jf.recommended -eq 'native' -and @($jf.clients) -contains 'mobile' -and ((& $opt $jf 'authentik-forwardauth').notes -join ' ') -match 'would block them' -and $plain.recommended -eq 'authentik-forwardauth') "$($jf.recommended) $($plain.recommended)"
Test-Condition 'auth options: public hostnames never offer "local only"; protection applied but not checked is pending-verification; native login is never disabled' (
  -not (& $opt $pub 'local-only').available -and $pub.recommended -eq 'cloudflare-access' -and (& $opt $prot 'authentik-forwardauth').state -eq 'pending-verification' -and ((& $opt $plain 'native').notes -join ' ') -match 'Never disabled') ''
$oidcM = [pscustomobject]@{ authentication = [pscustomobject]@{ forwardAuth = 'caution'; native = @('oidc') }; services = [pscustomobject]@{ app = [pscustomobject]@{ image = 'x/y:1' } } }
Test-Condition 'auth options: a recipe with native OIDC recommends OIDC; unsuitable ForwardAuth is incompatible' ((Get-AuthenticationOptions $oidcM).recommended -eq 'native-oidc' -and (& $opt (Get-AuthenticationOptions ([pscustomobject]@{ authentication = [pscustomobject]@{ forwardAuth = 'unsuitable'; native = @() } })) 'authentik-forwardauth').state -eq 'incompatible') ''

# --- Part 1c: registry versioning and migration ----------------------------------------------------------------------
$empty = ConvertTo-CurrentContractRegistry $null
$v0 = ConvertTo-CurrentContractRegistry ([pscustomobject]@{ apps = @([pscustomobject]@{ id = 'old'; container = 'notes-web-1'; project = 'notes'; service = 'web'; mode = 'integrated'; routes = @('notes') }, [pscustomobject]@{ container = 'x'; mode = 'weird' }) })
Test-Condition 'registry: an absent file is an empty current registry; version 0 is migrated (ids, modes, routes kept as integrations)' (
  $empty.Registry.contractVersion -eq 1 -and -not $empty.Migrated -and $v0.Migrated -and $v0.From -eq 0 -and @($v0.Registry.instances).Count -eq 2 -and $v0.Registry.instances[0].integrations[0].route -eq 'notes' -and $v0.Registry.instances[1].mode -eq 'observed' -and -not @(Test-ContractRegistry $v0.Registry).Count) (@(Test-ContractRegistry $v0.Registry) -join '; ')
Test-Throws 'registry: a newer contract version is refused (an older manager never rewrites it)' { ConvertTo-CurrentContractRegistry ([pscustomobject]@{ kind = 'dtc-applications'; contractVersion = 9; instances = @() }) } 'newer Deployment Manager'
$bad = New-ContractRegistry
$i1 = New-ContractInstance 'observed' (New-FixtureContainer 'a') ([ordered]@{ id = 'docker-cli' }); $i1.integrations = @([ordered]@{ integrationId = 'int-0123456789ab'; kind = 'traefik-route'; route = 'a' })
$i2 = New-ContractInstance 'integrated' (New-FixtureContainer 'b') ([ordered]@{ id = 'docker-cli' }); $i2.integrations = @([ordered]@{ integrationId = 'int-0123456789ac'; kind = 'traefik-route'; route = 'a' })
$bad.instances = @($i1, $i2, [ordered]@{ instanceId = 'nope'; mode = 'managed'; target = [ordered]@{} })
$errs = @(Test-ContractRegistry $bad) -join '; '
Test-Condition 'registry: observed instances own no integrations, a route has one owner, managed instances are not stored here, ids are checked' ($errs -match 'observed and cannot own' -and $errs -match "route 'a' is owned twice" -and $errs -match 'mode must be integrated or observed' -and $errs -match "instance id 'nope'") $errs
Test-Throws 'registry: an invalid instance mode is refused when created' { New-ContractInstance 'managed' (New-FixtureContainer 'a') $null } 'integrated or observed'
$settings = [pscustomobject]@{ InstallPath = (Join-Path ([IO.Path]::GetTempPath()) ('tpm-ac-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))) }
try {
  $r1 = New-ContractRegistry; $r1.instances = @($i2)
  Save-ContractRegistry $settings $r1
  $r1b = New-ContractRegistry; $r1b.instances = @($i2, (New-ContractInstance 'observed' (New-FixtureContainer 'c') $null))
  Save-ContractRegistry $settings $r1b
  $back = Read-ContractRegistry $settings
  $bak = Get-Content -Raw -LiteralPath ((Get-ContractRegistryPath $settings) + '.bak') | ConvertFrom-Json
  Test-Condition 'registry: saved atomically with the previous version kept as .bak; read back intact' (@($back.instances).Count -eq 2 -and @($bak.instances).Count -eq 1 -and $back.instances[0].integrations[0].route -eq 'a') ''
  Test-Throws 'registry: an invalid registry is never written' { Save-ContractRegistry $settings $bad } 'invalid'
} finally { Remove-Item -LiteralPath $settings.InstallPath -Recurse -Force -ErrorAction SilentlyContinue }

# --- Part 1d: unified inventory -----------------------------------------------------------------------------------------
$cKuma = New-FixtureContainer 'kuma-app-1' 'kuma' 'app' 'C:\apps\kuma' -Ports 3001
$cNotes = New-FixtureContainer 'notes-web-1' 'notes' 'web' '/data/compose/3'
$cNotesDb = New-FixtureContainer 'notes-db-1' 'notes' 'db' '/data/compose/3' -Networks @('notes_default') -Ports 5432; $cNotesDb.privateService = $true; $cNotesDb.ports = @([ordered]@{ port = 5432; guess = 'not-http' })
$cWiki = New-FixtureContainer 'wiki' -Ports 3000
$cOwn = New-FixtureContainer 'dm-traefik' 'dm' 'traefik' 'C:\dm'; $cOwn.infrastructure = $true
$cObs = New-FixtureContainer 'metrics-1' 'metrics' 'agent' '/opt/metrics' -Networks @('metrics_default') -Ports 9100; $cObs.ports = @()
$reg = New-ContractRegistry
$notesInst = New-ContractInstance 'integrated' $cNotes (Get-ManagementAuthority $cNotes) 'Notes' (New-ObservedBaseline $cNotes 8080 'http' 'proxy' (Get-ManagementAuthority $cNotes))
$notesInst.integrations = @([ordered]@{ integrationId = (New-ContractId 'int'); kind = 'traefik-route'; route = 'notes'; spec = [ordered]@{ hostnames = @('notes.home.example') } })
$reg.instances = @($notesInst, (New-ContractInstance 'observed' $cObs (Get-ManagementAuthority $cObs)))
$routes = @(
  (ConvertTo-ServiceDefinition @{ name = 'kuma'; hostnames = @('kuma.home.example'); target = @{ type = 'docker'; host = 'kuma-app-1'; port = 3001 } }),
  (ConvertTo-ServiceDefinition @{ name = 'notes'; hostnames = @('notes.home.example'); target = @{ type = 'docker'; host = 'notes-web-1'; port = 8080 }; owner = @{ kind = 'integration'; instanceId = $notesInst.instanceId; integrationId = $notesInst.integrations[0].integrationId } }),
  (ConvertTo-ServiceDefinition @{ name = 'wiki'; hostnames = @('wiki.home.example'); target = @{ type = 'docker'; host = 'wiki'; port = 3000 } })
)
$inv = Get-ApplicationInventory -Managed @([pscustomobject]@{ instanceId = 'i-abc'; project = 'kuma'; appId = 'uptime-kuma'; name = 'Uptime Kuma'; origin = 'installed'; manifest = $kuma }) -Registry $reg -Services $routes -Containers @($cKuma, $cNotes, $cNotesDb, $cWiki, $cOwn, $cObs) -StackName 'dm' -OwnContainers @('dm-traefik') -ProxyNetwork 'proxy'
$byName = @{}; foreach ($a in $inv.applications) { $byName[$a.name] = $a }
Test-Condition 'inventory: one model for a catalog app (managed), a Portainer stack (integrated, owns its route) and an observed project; recipes and trust per instance' (
  $byName['Uptime Kuma'].mode -eq 'managed' -and $byName['Uptime Kuma'].recipe -eq 'catalog:uptime-kuma@2026.10.21' -and $byName['Uptime Kuma'].trust.level -eq 'curated' -and @($byName['Uptime Kuma'].routes)[0].name -eq 'kuma' -and
  $byName['Notes'].mode -eq 'integrated' -and $byName['Notes'].authority.id -eq 'portainer' -and @($byName['Notes'].routes)[0].owner -eq 'this-instance' -and @($byName['Notes'].containers).Count -eq 2 -and
  $byName['metrics-1'].mode -eq 'observed' -and -not $byName['metrics-1'].rights.routes) (($inv.applications | ForEach-Object { "$($_.name)=$($_.mode)" }) -join ', ')
Test-Condition 'inventory: unregistered containers are listed as candidates (a routed standalone container with its unrecorded route); this deployment and infrastructure are never listed' (
  @($inv.unmanaged).Count -eq 1 -and $inv.unmanaged[0].name -eq 'wiki' -and $inv.unmanaged[0].suggestedMode -eq 'integrated' -and $inv.unmanaged[0].authority.id -eq 'docker-cli' -and @($inv.unmanaged[0].routes)[0].owner -eq 'unrecorded') (($inv.unmanaged | ForEach-Object { $_.name }) -join ', ')

# --- Part 1e: drift detection and repair plans ------------------------------------------------------------------------
$mw = @('default-headers', 'authentik')  # Get-AvailableMiddlewares: names without @file
$base = $notesInst.baseline
$auth0 = Get-ManagementAuthority $cNotes
$ok = Get-DriftFindings -Instance $notesInst -Container $cNotes -Authority $auth0 -Routes @($routes[1]) -LoadedRouters @('notes@file') -RouteFiles @('notes') -Probes @{ 'notes-web-1:8080' = @{ result = 'http'; status = 200 } } -Middlewares $mw -ProxyNetwork 'proxy'
Test-Condition 'drift: an unchanged integration is in sync' ((Get-DriftSummary $ok).state -eq 'in-sync') (($ok | ForEach-Object { $_.id }) -join ', ')
# Portainer recreated the container without the shared network.
$re = New-FixtureContainer 'notes-web-1' 'notes' 'web' '/data/compose/3' -Networks @('notes_default')
$d1 = Get-DriftFindings -Instance $notesInst -Container $re -Authority $auth0 -Routes @($routes[1]) -Middlewares $mw -ProxyNetwork 'proxy' -Probes @{ 'notes-web-1:8080' = @{ result = 'closed' } }
$f1 = @($d1 | Where-Object { $_.id -eq 'off-proxy-network' })[0]
Test-Condition 'drift: "running, but Traefik cannot reach it: network membership changed after Portainer recreated the container"; the repair is for Portainer (Compose lines), not automatic' (
  $f1 -and $f1.explanation -match 'running, but Traefik cannot reach' -and $f1.explanation -match 'after Portainer recreated' -and $f1.repair.owner -eq 'external' -and -not $f1.repair.automatic -and ($f1.repair.snippet -join "`n") -match 'external: true' -and
  @($d1 | Where-Object { $_.id -eq 'container-replaced' }).Count -and -not @($d1 | Where-Object { $_.id -eq 'backend-unreachable' }).Count) (($d1 | ForEach-Object { "$($_.id): $($_.explanation)" }) -join ' | ')
# The service was renamed (new container name) and its port changed: DTC-owned route repairs.
$ren = New-FixtureContainer 'notes-app-1' 'notes' 'web' '/data/compose/3' -Ports 9090
$ren.networks[0].aliases = @('notes-app-1')
$d2 = Get-DriftFindings -Instance $notesInst -Container $ren -Authority $auth0 -Routes @($routes[1]) -Middlewares $mw -ProxyNetwork 'proxy'
$plan2 = Get-RepairPlan $d2 @($routes[1])
Test-Condition 'drift: a stale backend name and a changed port become one DTC-owned route update (host and port), previewable and automatic' (
  @($d2 | Where-Object { $_.id -eq 'route-target-stale' }).Count -and @($d2 | Where-Object { $_.id -eq 'port-changed' }).Count -and $plan2.canApply -and @($plan2.routeChanges).Count -eq 1 -and
  $plan2.routeChanges[0].after.host -eq 'notes-app-1' -and $plan2.routeChanges[0].after.port -eq 9090 -and $plan2.routeChanges[0].before.port -eq 8080) (($d2 | ForEach-Object { $_.id }) -join ', ')
$pc = New-FixtureContainer 'notes-web-1' 'notes' 'web' '/data/compose/3' -Ports @(80, 9090)
$pcF = Get-DriftFindings -Instance $notesInst -Container $pc -Authority $auth0 -Routes @($routes[1]) -Middlewares $mw -ProxyNetwork 'proxy' -PortProbes @{ '80' = @{ result = 'closed' }; '9090' = @{ result = 'http' } }
$pcN = Get-DriftFindings -Instance $notesInst -Container $pc -Authority $auth0 -Routes @($routes[1]) -Middlewares $mw -ProxyNetwork 'proxy' -PortProbes @{ '80' = @{ result = 'http' }; '9090' = @{ result = 'http' } }
Test-Condition 'drift: a changed port is repaired only to the one exposed port that answers HTTP from Traefik''s network; with several answering ports the user chooses' (
  (Get-RepairPlan $pcF @($routes[1])).routeChanges[0].after.port -eq 9090 -and -not @((Get-RepairPlan $pcN @($routes[1])).routeChanges).Count -and @($pcN | Where-Object { $_.id -eq 'port-changed' -and $_.repair.kind -eq 'advice' }).Count) ''
# A route not owned by this instance is never repaired automatically.
$foreign = ConvertTo-ServiceDefinition @{ name = 'notes2'; hostnames = @('n2.home.example'); target = @{ type = 'docker'; host = 'old-name'; port = 8080 } }
$plan3 = Get-RepairPlan (Get-DriftFindings -Instance $notesInst -Container $cNotes -Routes @($foreign) -Middlewares $mw -ProxyNetwork 'proxy') @($foreign)
Test-Condition 'repair: a route DTC does not own for this instance is explained, never changed' (-not @($plan3.routeChanges).Count -and @($plan3.external | Where-Object { $_.finding -eq 'route-target-stale' }).Count) ''
$gone = Get-DriftFindings -Instance $notesInst -Container $null -Routes @($routes[1]) -ProxyNetwork 'proxy'
$noRoute = Get-DriftFindings -Instance $notesInst -Container $cNotes -Authority $auth0 -Routes @() -ProxyNetwork 'proxy'
Test-Condition 'drift: a missing container is explained (start it with its owner); a route the integration created that disappeared can be recreated from the record' (
  @($gone)[0].id -eq 'container-missing' -and @($gone)[0].repair.owner -eq 'external' -and @($gone)[0].repair.description -match 'Portainer' -and @($noRoute | Where-Object { $_.id -eq 'route-missing' -and $_.repair.kind -eq 'route-recreate' }).Count) (($noRoute | ForEach-Object { $_.id }) -join ', ')
$badMw = ConvertTo-ServiceDefinition @{ name = 'notes'; hostnames = @('notes.home.example'); middlewares = @('default-headers@file', 'gone@file'); target = @{ type = 'docker'; host = 'notes-web-1'; port = 8080 }; owner = @{ kind = 'integration'; instanceId = $notesInst.instanceId; integrationId = 'int-000000000001' } }
$d4 = Get-DriftFindings -Instance $notesInst -Container $cNotes -Authority $auth0 -Routes @($badMw) -Middlewares $mw -ProxyNetwork 'proxy' -Protection @{ notes = @{ provider = 'authentik' } } -Claims @{ 'notes.home.example' = @(@{ level = 'error'; detail = 'Docker labels of container x.' }) } -LoadedRouters @() -RouteFiles @('notes')
$plan4 = Get-RepairPlan $d4 @($badMw)
Test-Condition 'drift: missing middleware (removed from the route only, shared middleware untouched), protection removed outside DTC, a conflicting hostname claim and an unloaded router are all reported' (
  @($d4 | Where-Object { $_.id -eq 'middleware-missing' }).Count -and @($d4 | Where-Object { $_.id -eq 'protection-missing' }).Count -and @($d4 | Where-Object { $_.id -eq 'hostname-conflict' }).Count -and @($d4 | Where-Object { $_.id -eq 'router-not-loaded' }).Count -and
  (@($plan4.routeChanges[0].after.middlewares) -join ',') -eq 'default-headers@file' -and @($plan4.protection).Count -eq 1 -and @($plan4.resync) -contains 'notes') (($d4 | ForEach-Object { $_.id }) -join ', ')
$moved = New-FixtureContainer 'notes-web-1' 'notes' 'web' '/app/data/projects/notes'
$d5 = Get-DriftFindings -Instance $notesInst -Container $moved -Authority (Get-ManagementAuthority $moved) -Routes @($routes[1]) -Middlewares $mw -ProxyNetwork 'proxy'
Test-Condition 'drift: a change of management tool (Portainer -> Arcane) is reported with evidence; DTC keeps only its own integrations' (@($d5 | Where-Object { $_.id -eq 'ownership-changed' -and $_.explanation -match 'arcane' }).Count) (($d5 | ForEach-Object { $_.id }) -join ', ')
$managedInst = [ordered]@{ instanceId = 'i-abc'; mode = 'managed'; target = [ordered]@{ project = 'kuma'; service = 'app'; container = 'kuma-app-1' }; integrations = @() }
$d6 = Get-DriftFindings -Instance $managedInst -Container $cKuma -Routes @($routes[0]) -ProxyNetwork 'proxy' -Volumes @('kuma_other') -ExpectedVolumes @('kuma_data')
Test-Condition 'drift: a managed stack whose data volume disappeared is reported (restore from a backup)' (@($d6 | Where-Object { $_.id -eq 'volume-missing' -and $_.repair.description -match 'backup' }).Count) (($d6 | ForEach-Object { $_.id }) -join ', ')

$mInst = New-ContractInstance 'integrated' $cNotes $auth0 'Notes' (New-ObservedBaseline ([ordered]@{ id = $cNotes.id; name = $cNotes.name; image = $cNotes.image; compose = $cNotes.compose; networks = $cNotes.networks; mounts = @('/app/data', '/app/uploads') }) 8080 'http' 'proxy' $auth0)
$mInst.integrations = $notesInst.integrations
$noMount = New-FixtureContainer 'notes-web-1' 'notes' 'web' '/data/compose/3'; $noMount.mounts = @('/app/data')
$d7 = Get-DriftFindings -Instance $mInst -Container $noMount -Authority $auth0 -Routes @($routes[1]) -Middlewares $mw -ProxyNetwork 'proxy'
Test-Condition 'drift: a storage mount that disappeared (container paths only) is reported for the owner to restore' (@($d7 | Where-Object { $_.id -eq 'mount-lost' -and $_.explanation -match '/app/uploads' -and $_.repair.owner -eq 'external' }).Count -and $mInst.baseline.mounts.Count -eq 2) (($d7 | ForEach-Object { $_.id }) -join ', ')
$protRoute = ConvertTo-ServiceDefinition @{ name = 'notes'; hostnames = @('notes.home.example'); target = @{ type = 'docker'; host = 'notes-web-1'; port = 8080 }; auth = @{ provider = 'authentik'; endpoint = 'http://old-ak-server:9000' }; owner = @{ kind = 'integration'; instanceId = $notesInst.instanceId; integrationId = 'int-000000000001' } }
$d8 = Get-DriftFindings -Instance $notesInst -Container $cNotes -Authority $auth0 -Routes @($protRoute) -Middlewares $mw -ProxyNetwork 'proxy' -IdentityEndpoint 'http://new-ak-server:9000'
$plan8 = Get-RepairPlan $d8 @($protRoute)
$d9 = Get-DriftFindings -Instance $notesInst -Container $cNotes -Authority $auth0 -Routes @($protRoute) -Middlewares $mw -ProxyNetwork 'proxy' -IdentityEndpoint 'http://old-ak-server:9000/'
Test-Condition 'drift: a protected route whose authentik address changed is repaired to the current address (sign-in kept); the same address is not reported' (
  @($d8 | Where-Object { $_.id -eq 'auth-endpoint-stale' }).Count -and $plan8.routeChanges[0].after.authEndpoint -eq 'http://new-ak-server:9000' -and $plan8.routeChanges[0].before.authEndpoint -eq 'http://old-ak-server:9000' -and -not @($d9 | Where-Object { $_.id -eq 'auth-endpoint-stale' }).Count) (($d8 | ForEach-Object { $_.id }) -join ', ')
$pubLan = New-FixtureContainer 'notes-web-1' 'notes' 'web' '/data/compose/3'; $pubLan.published = @([ordered]@{ port = 8080; proto = 'tcp'; hostIp = '0.0.0.0'; hostPort = 18080 })
$pubLoop = New-FixtureContainer 'notes-web-1' 'notes' 'web' '/data/compose/3'; $pubLoop.published = @([ordered]@{ port = 8080; proto = 'tcp'; hostIp = '127.0.0.1'; hostPort = 18080 })
$dB1 = Get-DriftFindings -Instance $notesInst -Container $pubLan -Authority $auth0 -Routes @($protRoute) -Middlewares $mw -ProxyNetwork 'proxy'
$dB2 = Get-DriftFindings -Instance $notesInst -Container $pubLoop -Authority $auth0 -Routes @($protRoute) -Middlewares $mw -ProxyNetwork 'proxy'
$dB3 = Get-DriftFindings -Instance $notesInst -Container $pubLan -Authority $auth0 -Routes @($routes[1]) -Middlewares $mw -ProxyNetwork 'proxy'
$planB = Get-RepairPlan $dB1 @($protRoute)
$bp1 = @($dB1 | Where-Object { $_.id -eq 'auth-bypass-port' }); $bp2 = @($dB2 | Where-Object { $_.id -eq 'auth-bypass-port' })
Test-Condition 'drift: a protected route whose container publishes a host port is a sign-in bypass (LAN binding error, loopback warning), left to the owner (no automatic change); unprotected routes are not flagged' (
  $bp1.Count -eq 1 -and $bp1[0].severity -eq 'error' -and $bp1[0].evidence -match '0\.0\.0\.0:18080->8080' -and $bp1[0].repair.owner -eq 'external' -and $bp1[0].repair.kind -eq 'advice' -and
  $bp2.Count -eq 1 -and $bp2[0].severity -eq 'warning' -and -not @($dB3 | Where-Object { $_.id -eq 'auth-bypass-port' }).Count -and
  -not @($planB.routeChanges).Count -and @($planB.external | Where-Object { $_.finding -eq 'auth-bypass-port' }).Count) (($dB1 | ForEach-Object { "$($_.id)/$($_.severity)" }) -join ', ')

# --- Part 1f: route ownership in service definitions --------------------------------------------------------------------
$owned = $routes[1]
$plainR = $routes[0]
$json = ConvertTo-RegistryJson @($plainR)
$issues = @(Test-ServiceDefinition $owned) + @(Test-ServiceDefinition (ConvertTo-ServiceDefinition @{ name = 'x'; hostnames = @('x.home.example'); target = @{ type = 'docker'; host = 'x'; port = 80 }; owner = @{ kind = 'evil'; instanceId = 'nope' } }))
$yaml = ConvertTo-TraefikRouteYaml $owned
Test-Condition 'routes: an integration route records its owner (kind, instance, integration); routes without an owner are stored exactly as before; invalid owners are refused' (
  $owned.owner.kind -eq 'integration' -and $owned.owner.instanceId -eq $notesInst.instanceId -and $json -notmatch '"owner"' -and @($issues | Where-Object { $_.Field -eq 'owner' }).Count -and $yaml -match "Owner: integration $($notesInst.instanceId)") (($issues | ForEach-Object { $_.Message }) -join ' | ')

# --- Part 1g: updates never replace user data -----------------------------------------------------------------------------
$managed = @([regex]::Matches([regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'install.ps1')), '\$ManagedFiles = @\(([\s\S]*?)\n\)').Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
$userFiles = @($managed | Where-Object { $_ -like 'config\*' -and $_ -notlike '*.example.json' })
Test-Condition 'updates: the installer never replaces user configuration (apps, applications, services, drafts, recipes); the new modules and page are installed' (
  $managed.Count -gt 20 -and -not $userFiles.Count -and $managed -contains 'lib\AppContract.psm1' -and $managed -contains 'lib\Reconcile.psm1' -and $managed -contains 'webui\applications.js') ($userFiles -join ', ')

# --- Part 2: pasted Compose and Unraid templates (docker compose config, no containers) --------------------------------
$dockerOk = $false
if (-not $SkipDocker) { try { $null = & docker version --format '{{.Server.Version}}' 2>$null; $dockerOk = ($LASTEXITCODE -eq 0) } catch { } }
if (-not $dockerOk) { Add-Result 'SKIP' 'pasted Compose and Unraid imports' $(if ($SkipDocker) { '-SkipDocker' } else { 'Docker is not running' }) }
else {
  $main = @"
name: notes
services:
  web:
    image: example/notes:1.4@$digest
    ports: ["8080:8080"]
    environment:
      DATABASE_URL: postgres://notes:`${DB_PASSWORD}@db:5432/notes
      NOTES_SECRET_KEY: change-me
    depends_on:
      db: { condition: service_healthy }
  db:
    image: postgres:16-alpine@$digest
    environment:
      POSTGRES_USER: notes
      POSTGRES_PASSWORD: `${DB_PASSWORD}
    healthcheck: { test: ["CMD", "pg_isready", "-U", "notes"], interval: 5s }
    volumes: [dbdata:/var/lib/postgresql/data]
volumes: { dbdata: {} }
"@
  $override = @"
services:
  web:
    environment:
      NOTES_TITLE: My notes
    volumes: [uploads:/app/uploads]
volumes: { uploads: {} }
"@
  $one = Import-AppSourceText -Format 'compose' -Texts @($main) -SourceUrl 'https://github.com/example/notes'
  $two = Import-AppSourceText -Format 'auto' -Texts @($main, $override) -SourceUrl 'https://github.com/example/notes'
  $m1 = $one.Manifest; $m2 = $two.Manifest
  Test-Condition 'pasted compose: a two-service stack becomes a draft (name from the file, web service, database role, dependency, secrets generated, provenance with a SHA-256 per file)' (
    $one.Kind -eq 'compose' -and $m1.id -eq 'notes' -and $m1.source.kind -eq 'compose' -and $m1.web.service -eq 'web' -and $m1.services['db'].role -eq 'database' -and @($m1.services['web'].dependsOn).Count -and
    @($m1.inputs | Where-Object { $_.type -eq 'generated' }).Count -ge 2 -and @($m1.provenance.documents | Where-Object { $_.kind -eq 'compose' -and $_.sha256 }).Count -eq 1 -and @(Test-AppManifest ($m1 | ConvertTo-Json -Depth 30 | ConvertFrom-Json) -AllowImported).Count -eq 0) ((Test-AppManifest ($m1 | ConvertTo-Json -Depth 30 | ConvertFrom-Json) -AllowImported) -join '; ')
  Test-Condition 'pasted compose: a main file plus an override are merged by Compose (override settings and volumes kept), both files recorded' (
    @($m2.services['web'].volumes | Where-Object { $_.target -eq '/app/uploads' }).Count -and $m2.services['web'].environment.Contains('NOTES_TITLE') -and @($m2.provenance.documents).Count -eq 2) ''
  Test-Condition 'pasted compose: the same text imports to the same import key (repeated imports are recognized); a different text does not' ($one.ImportKey -eq (Import-AppSourceText -Format 'compose' -Texts @($main) -SourceUrl 'https://github.com/example/notes').ImportKey -and $one.ImportKey -ne $two.ImportKey) ''
  Test-Throws 'pasted compose: include: is refused (it reads other files of this PC)' { Import-AppSourceText -Format 'compose' -Texts @("include:`n  - other.yaml`nservices:`n  a:`n    image: x") } 'include'
  Test-Throws 'pasted compose: more than four files are refused' { Import-AppSourceText -Format 'compose' -Texts @($main, $override, $override, $override, $override) } 'at most 4'
  Test-Throws 'pasted compose: a documentation link must be https' { Import-AppSourceText -Format 'compose' -Texts @($main) -SourceUrl 'http://example.com' } 'https'
  $noDocs = (Import-AppSourceText -Format 'compose' -Texts @($main)).Manifest
  Test-Condition 'pasted compose: without a project link the draft says so and cannot be installed (no invented documentation)' (@($noDocs.draft.unresolved | Where-Object { $_.field -eq 'docs' }).Count -and @(Test-AppManifest ($noDocs | ConvertTo-Json -Depth 30 | ConvertFrom-Json) -AllowImported | Where-Object { $_ -match 'documentation' }).Count) ''
  $priv = (Import-AppSourceText -Format 'compose' -Texts @("services:`n  tool:`n    image: example/tool:1@$digest`n    privileged: true`n    volumes: ['/var/run/docker.sock:/var/run/docker.sock']`n    ports: ['8080:8080']") -SourceUrl 'https://github.com/example/tool').Manifest
  Test-Condition 'pasted compose: privileged mode and the Docker socket are surfaced as declared privileges, never silently dropped' (@($priv.privileges | Where-Object { $_.kind -match 'privileged' }).Count -and @($priv.privileges | Where-Object { $_.kind -match 'docker-socket' }).Count) (($priv.privileges | ForEach-Object { $_.kind }) -join ', ')
  $cred = @"
services:
  app:
    image: example/reader:2@$digest
    ports: ["8080:8080"]
    environment:
      - DATABASE_URL=postgres://reader:secret@db/reader?sslmode=disable
      - BACKUP_URL=s3://key:hunter2@backup.example/x
  db:
    image: postgres:17-alpine@$digest
    environment:
      - POSTGRES_USER=reader
      - POSTGRES_PASSWORD=secret
"@
  $cm = (Import-AppSourceText -Format 'compose' -Texts @($cred) -SourceUrl 'https://github.com/example/reader').Manifest
  $dbUrl = [string]$cm.services['app'].environment['DATABASE_URL']
  $pwInput = [string]$cm.services['db'].environment['POSTGRES_PASSWORD']
  $cf = @(Get-ManifestSecurityFindings ($cm | ConvertTo-Json -Depth 30 | ConvertFrom-Json))
  Test-Condition 'embedded credentials: a URL that repeats an example database password uses the same generated secret (app and database keep matching); another fixed credential is reported as a high finding and an open question' (
    $pwInput -match '^\{\{input:[A-Za-z0-9]+\}\}$' -and $dbUrl -eq "postgres://reader:$pwInput@db/reader?sslmode=disable" -and $dbUrl -notmatch 'secret' -and
    @($cm.draft.unresolved | Where-Object { $_.field -eq 'services.app.environment.BACKUP_URL' }).Count -and @($cf | Where-Object { $_.id -eq 'credential:app:BACKUP_URL' -and $_.severity -eq 'high' }).Count -and -not @($cf | Where-Object { $_.id -eq 'credential:app:DATABASE_URL' }).Count) "$dbUrl / $pwInput / $(($cf | ForEach-Object { $_.id }) -join ',')"
  $xml = @"
<?xml version="1.0"?>
<Container version="2">
  <Name>PasteBin</Name>
  <Repository>example/pastebin:2@$digest</Repository>
  <Network>bridge</Network>
  <WebUI>http://[IP]:[PORT:7777]/</WebUI>
  <Overview>A small paste service.</Overview>
  <Project>https://github.com/example/pastebin</Project>
  <Config Name="Web" Target="7777" Default="7777" Mode="tcp" Type="Port" Display="always" Required="true" Mask="false">7777</Config>
  <Config Name="Data" Target="/data" Default="/mnt/user/appdata/pastebin" Mode="rw" Type="Path" Display="always" Required="true" Mask="false">/mnt/user/appdata/pastebin</Config>
</Container>
"@
  $u = Import-AppSourceText -Format 'auto' -Texts @($xml)
  Test-Condition 'pasted Unraid template: recognized automatically, translated (web port, appdata as a named volume), project link used as documentation' ($u.Kind -eq 'unraid' -and $u.Manifest.web.service -and @($u.Manifest.services.Values)[0].volumes[0].kind -ne 'folder' -and @($u.Manifest.docs | Where-Object { $_.url -eq 'https://github.com/example/pastebin' }).Count) ''
  Test-Throws 'pasted Unraid template: plugins are refused' { Import-AppSourceText -Format 'unraid' -Texts @('<?xml version="1.0"?><PLUGIN name="x" pluginURL="https://x/y.plg"></PLUGIN>') } 'plugin|Container'
  Test-Throws 'pasted Unraid template: DTDs / external entities are refused' { Import-AppSourceText -Format 'unraid' -Texts @('<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///c:/windows/win.ini">]><Container version="2"><Name>&e;</Name></Container>') } 'DTD|prohibited|not valid'
}

# --- Part 3: web API on a throwaway instance (no containers) ---------------------------------------------------------
if ($SkipApi) { Add-Result 'SKIP' 'web API' '-SkipApi' }
elseif (-not $dockerOk) { Add-Result 'SKIP' 'web API' 'Docker is not running' }
else {
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
  $work = Join-Path ([IO.Path]::GetTempPath()) "tpm-ac-$id"
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $ui = $null; $mock = $null
  try {
    $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-ac-$id" -Subnet '172.31.242.0/28'
    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token 'cf-test-token'
    $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
    $null = Connect-WebUi $ui
    $p1 = Invoke-WebUi $ui POST '/api/provision/import' @{ text = $main; format = 'compose'; sourceUrl = 'https://github.com/example/notes' }
    $p2 = Invoke-WebUi $ui POST '/api/provision/import' @{ text = $main; format = 'compose'; sourceUrl = 'https://github.com/example/notes' }
    $p3 = Invoke-WebUi $ui POST '/api/provision/import' @{ texts = @($main, $override); format = 'compose'; sourceUrl = 'https://github.com/example/notes' }
    Test-Condition 'api: pasted Compose imports a draft (source, trust, auth options in the view); importing the same text again reuses that draft' (
      $p1.Status -eq 200 -and $p1.Data.kind -eq 'compose' -and $p1.Data.trust.level -eq 'untrusted' -and @($p1.Data.authOptions.options).Count -and $p2.Data.draftId -eq $p1.Data.draftId -and $p2.Data.reused -and $p3.Data.draftId -ne $p1.Data.draftId) "$($p1.Status) $($p1.Body.Substring(0, [Math]::Min(300, $p1.Body.Length)))"
    $p4 = Invoke-WebUi $ui POST '/api/provision/import' @{ text = ('x' * 300KB); format = 'compose' }
    $p5 = Invoke-WebUi $ui POST '/api/provision/import' @{ format = 'compose' }
    Test-Condition 'api: oversized or empty pasted text is refused with a reason' ($p4.Status -eq 422 -and $p5.Status -eq 400) "$($p4.Status) $($p5.Status)"
    $apps = Invoke-WebUi $ui GET '/api/applications'
    Test-Condition 'api: the applications view lists ownership modes and the contract version' ($apps.Status -eq 200 -and $apps.Data.contractVersion -eq 1 -and $apps.Data.modes.integrated -and $null -ne $apps.Data.applications) $apps.Body
    $own = Invoke-WebUi $ui POST '/api/integrations/plan' @{ container = "tpm-ac-$id-traefik"; port = 8080; hostname = 'x.home.example' }
    $nope = Invoke-WebUi $ui POST '/api/integrations/plan' @{ container = 'no-such-container-here'; port = 80; hostname = 'x.home.example' }
    Test-Condition 'api: integration plans refuse unknown containers (404); this deployment''s own containers are never integrated (400 or 404 when not running)' ($nope.Status -eq 404 -and $own.Status -in 400, 404) "$($nope.Status) $($own.Status) $($own.Body)"
    # An interrupted repair (the manager stopped part-way) is listed and rolled back to the routes from before it.
    $st0 = Get-StackSettings -InstallPath $install
    $addR = Invoke-WebUiChange $ui @{ op = 'add'; service = @{ name = 'repairme'; hostnames = @('repairme.home.example'); target = @{ type = 'docker'; host = 'nowhere-x'; port = 8080 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    $regBefore = [IO.File]::ReadAllText($st0.RegistryPath)
    $preId = Split-Path -Leaf (New-ServiceBackup $st0 -Suffix '-pre-repair')
    $chgR = Invoke-WebUiChange $ui @{ op = 'update'; name = 'repairme'; service = @{ name = 'repairme'; hostnames = @('repairme.home.example'); target = @{ type = 'docker'; host = 'nowhere-x'; port = 9999 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    $rid = 'abcdef012345'
    New-Item -ItemType Directory -Force -Path (Join-Path $install 'config\provision\repairs') | Out-Null
    [IO.File]::WriteAllText((Join-Path $install "config\provision\repairs\$rid.json"), (@{ repairId = $rid; instanceId = 'x-0123456789ab'; startedAt = '2026-11-19T10:00:00Z'; preBackup = $preId; state = 'running'; steps = @(@{ summary = "Update route 'repairme'"; ok = $true }) } | ConvertTo-Json -Depth 4))
    $list = Invoke-WebUi $ui GET '/api/applications/repairs'
    $rbNo = Invoke-WebUi $ui POST '/api/applications/repair/rollback' @{ repairId = $rid }
    $rbR = Invoke-WebUi $ui POST '/api/applications/repair/rollback' @{ repairId = $rid; confirm = $true }
    $rbTwice = Invoke-WebUi $ui POST '/api/applications/repair/rollback' @{ repairId = $rid; confirm = $true }
    Test-Condition 'repairs: an interrupted repair is listed and rolled back (with confirmation) to the routes from before it, once' (
      $addR.Apply.Data.ok -and $chgR.Apply.Data.ok -and @($list.Data.interrupted | Where-Object { $_.repairId -eq $rid }).Count -eq 1 -and $rbNo.Status -ge 400 -and $rbR.Status -eq 200 -and [IO.File]::ReadAllText($st0.RegistryPath) -eq $regBefore -and $rbTwice.Status -eq 409) "$($list.Body) $($rbR.Status) $($rbR.Body)"
    $obsBad = Invoke-WebUi $ui POST '/api/applications/observe' @{ container = 'no-such-container-here' }
    $drift = Invoke-WebUi $ui POST '/api/applications/drift' @{ instanceId = 'x-000000000000' }
    $rep = Invoke-WebUi $ui POST '/api/applications/repair/plan' @{ instanceId = 'x-000000000000' }
    $rm = Invoke-WebUi $ui POST '/api/integrations/remove/plan' @{ instanceId = 'bad id' }
    Test-Condition 'api: observe, drift, repair and removal refuse unknown or invalid instances' ($obsBad.Status -eq 404 -and $drift.Status -eq 404 -and $rep.Status -eq 404 -and $rm.Status -eq 400) "$($obsBad.Status) $($drift.Status) $($rep.Status) $($rm.Status)"
  } finally {
    if ($ui) { Stop-TestServer $ui }
    if ($mock) { Stop-TestServer $mock }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count) { exit 1 }
