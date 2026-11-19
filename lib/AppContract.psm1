Set-StrictMode -Version 2.0

# Universal DTC application contract (docs/universal-apps.md): one model for every application, whatever its source.
#
#   Recipe       how an application can be installed: a curated catalog manifest, an imported draft (Docker Hub,
#                GitHub, Compose, Unraid, registry) or a saved local recipe. Reusable for many installations.
#   Instance     one installed or discovered application: its Compose project, containers, management authority and
#                ownership mode (DTC Managed, DTC Integrated or DTC Observed).
#   Integration  a DTC-owned resource attached to an instance (Traefik route, authentik protection, Cloudflare
#                publication). It may exist while another tool (Arcane, Portainer, plain Compose) owns the containers.
#
# Managed instances stay in config\apps.json (written by the App Catalog installer, unchanged by this module);
# integrated and observed instances, with their integrations and the observed baseline used for drift detection, are
# kept in config\applications.json (versioned; see ConvertTo-CurrentContractRegistry). Everything here is pure apart
# from Read-/Save-ContractRegistry.

$script:ContractVersion = 1
$script:OwnershipModes = @('managed', 'integrated', 'observed')
# What each mode allows DTC to change. Recreating containers or editing Compose files is only ever 'managed'.
$script:ModeRights = [ordered]@{
  managed    = [ordered]@{ lifecycle = $true; composeFiles = $true; routes = $true; protection = $true; publication = $true; monitor = $true
    summary = 'DTC owns the stack: it may install, update, restart, back up and remove what it created (each change previewed and approved).' }
  integrated = [ordered]@{ lifecycle = $false; composeFiles = $false; routes = $true; protection = $true; publication = $true; monitor = $true
    summary = 'Another tool owns the stack. DTC manages only the routes, sign-in and publication it created for it, and never recreates its containers or edits its Compose files.' }
  observed   = [ordered]@{ lifecycle = $false; composeFiles = $false; routes = $false; protection = $false; publication = $false; monitor = $true
    summary = 'DTC only lists and monitors it. Nothing is changed until you switch it to Integrated.' }
}
$script:IdPattern = '^[a-z][a-z0-9-]{1,40}$'

function Get-AcProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function New-ContractId([string]$Prefix) {
  $b = New-Object byte[] 6
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return $Prefix + '-' + (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-OwnershipModes { return $script:ModeRights }

# Pure: whether $Mode allows $Right (lifecycle, composeFiles, routes, protection, publication, monitor).
function Test-OwnershipRight([string]$Mode, [string]$Right) {
  if (-not $script:ModeRights.Contains($Mode)) { return $false }
  return [bool]$script:ModeRights[$Mode][$Right]
}

# --- Management authority ---------------------------------------------------------------------------------------------

# Pure: who manages a container's lifecycle, from what Docker reports (labels and the Compose working folder). Returns
# { id: dtc | portainer | arcane | compose | docker-cli | unknown; label; confidence: certain | likely | unknown;
# evidence[] }. A heuristic is always reported as 'likely' with its evidence; nothing is guessed silently.
# $Container: a DockerDiscovery inventory item (compose.project / service / workingDir / configFiles, labels hints).
function Get-ManagementAuthority($Container, [string[]]$DtcProjects = @(), [string]$DtcStack = '') {
  $compose = Get-AcProp $Container 'compose' $null
  $project = [string](Get-AcProp $compose 'project' '')
  $wd = ([string](Get-AcProp $compose 'workingDir' '')).Replace('\', '/')
  $cfgFiles = ([string](Get-AcProp $compose 'configFiles' '')).Replace('\', '/')
  $hints = @(Get-AcProp $Container 'authorityHints' @())
  $ev = New-Object System.Collections.ArrayList
  $r = { param($id, $label, $conf) [ordered]@{ id = $id; label = $label; confidence = $conf; evidence = @($ev) } }
  if ([string](Get-AcProp $Container 'managedBy' '') -or ($project -and ($DtcProjects -contains $project -or ($DtcStack -and $project -eq $DtcStack)))) {
    if ([string](Get-AcProp $Container 'managedBy' '')) { $null = $ev.Add("label org.traefik-proxy.app=$([string]$Container.managedBy)") }
    if ($project -and $DtcProjects -contains $project) { $null = $ev.Add("Compose project '$project' is registered in this deployment's apps.json") }
    if ($DtcStack -and $project -eq $DtcStack) { $null = $ev.Add("Compose project '$project' is this proxy deployment") }
    return (& $r 'dtc' 'DTC (this Deployment Manager)' 'certain')
  }
  foreach ($h in $hints) { if ([string]$h -match '^io\.portainer\.') { $null = $ev.Add("label $h") } }
  if ($ev.Count) { return (& $r 'portainer' 'Portainer' 'certain') }
  # Portainer stores the stacks it deploys under /data/compose/<id> inside its own container; Compose records that path.
  if ($project -and ($wd -match '^/data/compose/\d+(/|$)' -or $cfgFiles -match '(^|,)/data/compose/\d+/')) { $null = $ev.Add("Compose working folder '$wd' is Portainer's stack folder (/data/compose/<id>)"); return (& $r 'portainer' 'Portainer' 'likely') }
  foreach ($h in $hints) { if ([string]$h -match '^(com\.getarcaneapp|arcane)\.') { $null = $ev.Add("label $h") } }
  if ($ev.Count) { return (& $r 'arcane' 'Arcane' 'certain') }
  # Arcane keeps its projects in <data>/projects/<name> (default /app/data/projects inside its container).
  if ($project -and ($wd -match '/(app/)?data/projects/[^/]+/?$' -or $cfgFiles -match '/data/projects/[^/,]+/')) { $null = $ev.Add("Compose working folder '$wd' looks like Arcane's projects folder (data/projects/<name>)"); return (& $r 'arcane' 'Arcane' 'likely') }
  if ($project) {
    $null = $ev.Add("Compose project '$project'$(if ($wd) { " in $wd" })")
    return (& $r 'compose' 'Docker Compose (manual or another tool)' $(if ($wd) { 'certain' } else { 'likely' }))
  }
  if (Get-AcProp $Container 'name' '') { $null = $ev.Add('No Compose labels: started with docker run or a tool that does not use Compose') ; return (& $r 'docker-cli' 'docker run (no Compose project)' 'likely') }
  return (& $r 'unknown' 'Unknown' 'unknown')
}

# --- Recipe trust (separate from installation success) ----------------------------------------------------------------

# Pure: how far a recipe can be trusted, independently of whether an installation of it started. Returns { level:
# curated | verified-local | claimed | untrusted; status: draft | ready | verified; reasons[] }.
function Get-RecipeTrust($Manifest, $Recipe = $null) {
  $src = Get-AcProp $Manifest 'source' $null
  $type = [string](Get-AcProp $src 'type' 'curated')
  $reasons = New-Object System.Collections.ArrayList
  $unresolved = @(Get-AcProp (Get-AcProp $Manifest 'draft' $null) 'unresolved' @())
  $unsupported = @(Get-AcProp (Get-AcProp $Manifest 'draft' $null) 'unsupported' @())
  $verification = [string](Get-AcProp (Get-AcProp $Manifest 'verification' $null) 'status' '')
  $level = 'untrusted'
  if ($type -eq 'curated') { $level = 'curated'; $null = $reasons.Add('Maintained in the DTC App Catalog and reviewed with the project.') }
  elseif ($Recipe -and [string](Get-AcProp (Get-AcProp $Recipe 'trust' $null) 'status' '') -eq 'verified-local') { $level = 'verified-local'; $null = $reasons.Add('A recipe this manager created and verified on this PC.') }
  elseif ($Recipe) { $level = 'claimed'; $null = $reasons.Add('An imported recipe: its claims are not verified here.') }
  else { $null = $reasons.Add("Imported from $([string](Get-AcProp $src 'kind' $type)): treated as untrusted until reviewed. An image that starts is not automatically trustworthy.") }
  if ($unresolved.Count) { $null = $reasons.Add("$($unresolved.Count) open question(s) must be answered first.") }
  if ($unsupported.Count) { $null = $reasons.Add("$($unsupported.Count) setting(s) the manager does not generate.") }
  $status = $(if ($unresolved.Count -or $unsupported.Count -or -not [bool](Get-AcProp $Manifest 'installable' $false)) { 'draft' } elseif ($type -eq 'curated' -and [string](Get-AcProp (Get-AcProp $Manifest 'testStatus' $null) 'live' '') -eq 'passed') { 'verified' } elseif ($verification -eq 'verified') { 'verified' } else { 'ready' })
  return [ordered]@{ level = $level; status = $status; reasons = @($reasons) }
}

# Pure: a stable reference to the recipe an instance came from.
function Get-RecipeRef([string]$Kind, [string]$Id, [string]$Version = '') {
  if ($Kind -notin 'catalog', 'imported', 'recipe', 'none') { throw "Unknown recipe kind '$Kind'." }
  if ($Kind -eq 'none') { return 'none' }
  return "${Kind}:$Id$(if ($Version) { "@$Version" })"
}

# --- Authentication capabilities ---------------------------------------------------------------------------------------

# Images whose own clients (mobile, desktop, TV, sync, API) authenticate natively: a browser-only ForwardAuth breaks
# them. Kept generic: matched against the image repository, never used to change an application.
$script:ClientImages = [ordered]@{
  '(^|/)(plexinc/pms-docker|linuxserver/plex|plex)' = @('mobile', 'tv', 'desktop', 'api')
  '(^|/)(jellyfin|linuxserver/jellyfin|emby)' = @('mobile', 'tv', 'desktop', 'api')
  '(^|/)(nextcloud|linuxserver/nextcloud)' = @('mobile', 'desktop', 'webdav', 'api')
  '(^|/)(immich-app/immich-server|immich)' = @('mobile', 'api')
  '(^|/)(homeassistant/home-assistant|home-assistant)' = @('mobile', 'api', 'websocket')
  '(^|/)(vaultwarden|bitwarden)' = @('mobile', 'desktop', 'browser-extension', 'api')
  '(^|/)(gitea|forgejo|gitlab)' = @('git', 'api')
  '(^|/)(navidrome|audiobookshelf)' = @('mobile', 'api')
}

# Pure: which authentication methods suit an application, with a state per method. $Manifest may be $null (an
# external application known only from its container); $Image is then used. States: not-configured | configured |
# pending-verification | verified | incompatible. $Current: { provider; verified } from the route and identity checks.
function Get-AuthenticationOptions($Manifest = $null, [string]$Image = '', $Current = $null, [bool]$IdentityReady = $false, [bool]$Public = $false) {
  $img = $Image
  if (-not $img) {
    $svcs = Get-AcProp $Manifest 'services' $null
    $vals = @(if ($svcs -is [System.Collections.IDictionary]) { @($svcs.Values) } elseif ($svcs) { @($svcs.PSObject.Properties | ForEach-Object { $_.Value }) })
    $webName = [string](Get-AcProp (Get-AcProp $Manifest 'web' $null) 'service' '')
    $web = $(if ($webName -and $svcs -is [System.Collections.IDictionary] -and $svcs.Contains($webName)) { $svcs[$webName] } elseif ($webName -and $svcs -and $svcs.PSObject.Properties[$webName]) { $svcs.$webName } elseif ($vals.Count) { $vals[0] } else { $null })
    $img = [string](Get-AcProp $web 'image' '')
  }
  $clients = @()
  foreach ($k in $script:ClientImages.Keys) { if ([string]$img -match $k) { $clients = @($script:ClientImages[$k]) } }
  $declared = Get-AcProp $Manifest 'authentication' $null
  $fit = [string](Get-AcProp $declared 'forwardAuth' '')
  $native = @(@(Get-AcProp $declared 'native' @()) | Where-Object { $_ })
  $oidc = [bool](@($native | Where-Object { [string]$_ -match 'oidc|oauth|saml' }).Count)
  $provider = [string](Get-AcProp $Current 'provider' '')
  $verified = [bool](Get-AcProp $Current 'verified' $false)
  $stateOf = { param($id) if ($provider -eq $id) { if ($verified) { 'verified' } else { 'pending-verification' } } else { 'not-configured' } }
  $fa = [ordered]@{ id = 'authentik-forwardauth'; name = 'authentik ForwardAuth (sign in before the app)'; state = (& $stateOf 'authentik'); available = $IdentityReady; notes = @() }
  if ($fit -in 'unsuitable', 'not-applicable') { $fa.state = 'incompatible'; $fa.available = $false; $fa.notes += 'The recipe says ForwardAuth does not suit this application.' }
  elseif ($clients.Count) { $fa.notes += "Its own clients ($($clients -join ', ')) authenticate with the application; ForwardAuth would block them. Verify client behaviour before protecting it this way." }
  if (-not $IdentityReady) { $fa.notes += 'Identity & Access (authentik) is not ready in this deployment.' }
  $list = @(
    [ordered]@{ id = 'native'; name = 'The application''s own login'; state = $(if ($native.Count) { 'configured' } else { 'not-configured' }); available = $true; notes = @('Never disabled by DTC.') }
    [ordered]@{ id = 'native-oidc'; name = 'Native OIDC with authentik'; state = $(if ($oidc) { 'not-configured' } else { 'incompatible' }); available = $oidc; notes = @($(if ($oidc) { 'Configured in authentik and in the application (single sign-on without blocking its clients).' } else { 'No OIDC support recorded for this application.' })) }
    $fa
    [ordered]@{ id = 'cloudflare-access'; name = 'Cloudflare Access'; state = (& $stateOf 'cloudflare-access'); available = $Public; notes = @($(if ($Public) { 'Browsers only; API and app clients need service tokens.' } else { 'Only for public hostnames.' })) }
    [ordered]@{ id = 'local-only'; name = 'Local only (no proxy sign-in)'; state = $(if (-not $provider) { 'configured' } else { 'not-configured' }); available = -not $Public; notes = @('Reachable only from this PC or your network; never offered for public hostnames.') }
  )
  $recommended = $(if ($oidc) { 'native-oidc' } elseif ($clients.Count) { 'native' } elseif ($IdentityReady) { 'authentik-forwardauth' } elseif ($Public) { 'cloudflare-access' } else { 'local-only' })
  return [ordered]@{ clients = $clients; options = $list; recommended = $recommended }
}

# --- Registry (config\applications.json) --------------------------------------------------------------------------------

# Pure: an empty registry of the current version.
function New-ContractRegistry { return [ordered]@{ kind = 'dtc-applications'; contractVersion = $script:ContractVersion; instances = @() } }

# Pure: migrates a registry document to the current contract version. Version 0 (draft format: { apps: [...] } without
# a version) is converted; a newer version is refused, so an older manager never rewrites what a newer one wrote.
# Returns { Registry; Migrated; From }.
function ConvertTo-CurrentContractRegistry($Document) {
  if ($null -eq $Document) { return [pscustomobject]@{ Registry = (New-ContractRegistry); Migrated = $false; From = $script:ContractVersion } }
  $v = [int](Get-AcProp $Document 'contractVersion' 0)
  if ($v -gt $script:ContractVersion) { throw "config\applications.json was written by a newer Deployment Manager (contract version $v; this version understands $($script:ContractVersion)). It was not changed." }
  if ($v -eq $script:ContractVersion) {
    $reg = New-ContractRegistry
    $reg.instances = @(@(Get-AcProp $Document 'instances' @()) | ForEach-Object { ConvertTo-OrderedContract $_ })
    return [pscustomobject]@{ Registry = $reg; Migrated = $false; From = $v }
  }
  # Version 0: { apps: [ { id, container, mode, routes: [names] } ] }.
  $reg = New-ContractRegistry
  $reg.instances = @(foreach ($a in @(Get-AcProp $Document 'apps' @())) {
      $mode = [string](Get-AcProp $a 'mode' 'observed'); if ($mode -notin 'integrated', 'observed') { $mode = 'observed' }
      [ordered]@{ instanceId = $(if ([string](Get-AcProp $a 'id' '') -match '^x-[0-9a-f]{12}$') { [string]$a.id } else { New-ContractId 'x' }); mode = $mode; name = [string](Get-AcProp $a 'name' (Get-AcProp $a 'container' ''))
        target = [ordered]@{ project = [string](Get-AcProp $a 'project' ''); service = [string](Get-AcProp $a 'service' ''); container = [string](Get-AcProp $a 'container' '') }
        authority = [ordered]@{ id = 'unknown'; label = 'Unknown'; confidence = 'unknown'; evidence = @('Migrated from contract version 0') }; baseline = $null
        integrations = @(@(Get-AcProp $a 'routes' @()) | ForEach-Object { [ordered]@{ integrationId = (New-ContractId 'int'); kind = 'traefik-route'; route = [string]$_; createdAt = ''; protection = $null; publication = $null } })
        createdAt = ''; updatedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
    })
  return [pscustomobject]@{ Registry = $reg; Migrated = $true; From = $v }
}

function ConvertTo-OrderedContract($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in $Value.Keys) { $o[$k] = ConvertTo-OrderedContract $Value[$k] }; return $o }
  if ($Value -is [System.Collections.IEnumerable]) { return ,@(foreach ($x in $Value) { ConvertTo-OrderedContract $x }) }
  $o = [ordered]@{}; foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-OrderedContract $p.Value }; return $o
}

# Pure: problems of a registry (empty = valid).
function Test-ContractRegistry($Registry) {
  $e = New-Object System.Collections.ArrayList
  if ([string](Get-AcProp $Registry 'kind' '') -ne 'dtc-applications') { $null = $e.Add('kind must be dtc-applications') }
  if ([int](Get-AcProp $Registry 'contractVersion' 0) -ne $script:ContractVersion) { $null = $e.Add("contractVersion must be $($script:ContractVersion)") }
  $ids = @{}; $routes = @{}
  foreach ($i in @(Get-AcProp $Registry 'instances' @())) {
    $id = [string](Get-AcProp $i 'instanceId' '')
    if ($id -notmatch '^x-[0-9a-f]{12}$') { $null = $e.Add("instance id '$id' is invalid") }
    if ($ids.ContainsKey($id)) { $null = $e.Add("instance id '$id' is duplicated") }; $ids[$id] = $true
    $mode = [string](Get-AcProp $i 'mode' '')
    if ($mode -notin 'integrated', 'observed') { $null = $e.Add("instance '$id': mode must be integrated or observed (managed instances live in apps.json)") }
    $t = Get-AcProp $i 'target' $null
    if (-not [string](Get-AcProp $t 'container' '') -and -not [string](Get-AcProp $t 'project' '')) { $null = $e.Add("instance '$id' names no container or Compose project") }
    foreach ($g in @(Get-AcProp $i 'integrations' @())) {
      if ([string](Get-AcProp $g 'integrationId' '') -notmatch '^int-[0-9a-f]{12}$') { $null = $e.Add("instance '$id': integration id is invalid") }
      if ($mode -eq 'observed') { $null = $e.Add("instance '$id' is observed and cannot own integrations") }
      $rt = [string](Get-AcProp $g 'route' '')
      if ($rt) { if ($routes.ContainsKey($rt)) { $null = $e.Add("route '$rt' is owned twice") }; $routes[$rt] = $id }
    }
  }
  return $e.ToArray()
}

function Get-ContractRegistryPath($Settings) { return (Join-Path ([string]$Settings.InstallPath) 'config\applications.json') }

# Reads the registry (migrating older versions in memory; the file is rewritten only by Save-ContractRegistry).
function Read-ContractRegistry($Settings) {
  $p = Get-ContractRegistryPath $Settings
  $doc = $null
  if (Test-Path -LiteralPath $p) { $doc = [IO.File]::ReadAllText($p) | ConvertFrom-Json }
  return (ConvertTo-CurrentContractRegistry $doc).Registry
}

function Save-ContractRegistry($Settings, $Registry) {
  $errors = @(Test-ContractRegistry $Registry)
  if ($errors.Count) { throw "The applications registry is invalid: $($errors -join '; ')" }
  $p = Get-ContractRegistryPath $Settings
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
  # Keep the previous version next to it: a DTC update or a bad write can never silently lose integrations.
  if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination "$p.bak" -Force }
  $tmp = "$p.tmp"
  [IO.File]::WriteAllText($tmp, (($Registry | ConvertTo-Json -Depth 12) + "`n"), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $p -Force
}

# Pure: what DTC recorded about a container when it started integrating or observing it; drift is measured against it.
function New-ObservedBaseline($Container, [int]$Port = 0, [string]$Protocol = '', [string]$ProxyNetwork = '', $Authority = $null) {
  $net = @(@(Get-AcProp $Container 'networks' @()) | Where-Object { [string]$_.name -eq $ProxyNetwork })
  return [ordered]@{ containerId = [string](Get-AcProp $Container 'id' ''); containerName = [string](Get-AcProp $Container 'name' ''); image = [string](Get-AcProp $Container 'image' '')
    project = [string](Get-AcProp (Get-AcProp $Container 'compose' $null) 'project' ''); service = [string](Get-AcProp (Get-AcProp $Container 'compose' $null) 'service' '')
    networks = @(@(Get-AcProp $Container 'networks' @()) | ForEach-Object { [string]$_.name })
    aliases = @(if ($net.Count) { @(Get-AcProp $net[0] 'aliases' @()) | ForEach-Object { [string]$_ } })
    port = $Port; protocol = $Protocol; authority = $(if ($Authority) { [string]$Authority.id } else { '' }); recordedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
}

# Pure: a new integrated or observed instance for a discovered container.
function New-ContractInstance([string]$Mode, $Container, $Authority, [string]$Name = '', $Baseline = $null) {
  if ($Mode -notin 'integrated', 'observed') { throw "Mode must be integrated or observed." }
  $c = Get-AcProp $Container 'compose' $null
  $now = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
  return [ordered]@{ instanceId = (New-ContractId 'x'); mode = $Mode; name = $(if ($Name) { $Name } else { [string](Get-AcProp $Container 'name' '') })
    target = [ordered]@{ project = [string](Get-AcProp $c 'project' ''); service = [string](Get-AcProp $c 'service' ''); container = [string](Get-AcProp $Container 'name' '') }
    authority = $Authority; baseline = $Baseline; integrations = @(); createdAt = $now; updatedAt = $now }
}

# Pure: finds the container that currently plays an instance's part: same Compose project + service (survives
# recreation and renaming), else the same container name.
function Find-InstanceContainer($Instance, [object[]]$Containers) {
  $t = Get-AcProp $Instance 'target' $null
  $project = [string](Get-AcProp $t 'project' ''); $service = [string](Get-AcProp $t 'service' ''); $name = [string](Get-AcProp $t 'container' '')
  if ($project -and $service) {
    $hit = @($Containers | Where-Object { [string](Get-AcProp (Get-AcProp $_ 'compose' $null) 'project' '') -eq $project -and [string](Get-AcProp (Get-AcProp $_ 'compose' $null) 'service' '') -eq $service } | Sort-Object { [string](Get-AcProp $_ 'state' '') -ne 'running' })
    if ($hit.Count) { return $hit[0] }
  }
  if ($name) { $hit = @($Containers | Where-Object { [string](Get-AcProp $_ 'name' '') -eq $name }); if ($hit.Count) { return $hit[0] } }
  return $null
}

# --- Unified view -------------------------------------------------------------------------------------------------------

# Pure: every application this deployment knows or can see, in one model. Inputs:
#   -Managed       apps.json records (ConvertTo-AppInstance shape) with optional .manifest / .webContainer
#   -Registry      the contract registry (integrated and observed instances)
#   -Services      service registry routes (config\services.json)
#   -Containers    DockerDiscovery inventory
#   -StackName / -OwnContainers   this proxy deployment (never listed as an application)
# Output: { applications[]; unmanaged[] } where unmanaged are discovered projects/containers no registry knows yet.
function Get-ApplicationInventory {
  param([object[]]$Managed = @(), $Registry = $null, [object[]]$Services = @(), [object[]]$Containers = @(), [string]$StackName = '', [string[]]$OwnContainers = @(), [string]$ProxyNetwork = '')
  $routesFor = {
    param([string[]]$Hosts, [string]$OwnerId)
    @($Services | Where-Object {
        $o = Get-AcProp $_ 'owner' $null
        ($OwnerId -and [string](Get-AcProp $o 'instanceId' '') -eq $OwnerId) -or ([string](Get-AcProp (Get-AcProp $_ 'target' $null) 'type' '') -eq 'docker' -and $Hosts -contains [string](Get-AcProp (Get-AcProp $_ 'target' $null) 'host' ''))
      } | ForEach-Object {
        $o = Get-AcProp $_ 'owner' $null
        [ordered]@{ name = [string]$_.name; hostnames = @($_.hostnames); port = [int]$_.target.port; enabled = [bool]$_.enabled
          protection = [string](Get-AcProp (Get-AcProp $_ 'auth' $null) 'provider' ''); publish = [bool](Get-AcProp (Get-AcProp $_ 'cloudflare' $null) 'publish' $false)
          owner = $(if ($o -and [string](Get-AcProp $o 'instanceId' '') -eq $OwnerId) { 'this-instance' } elseif ($o) { 'other' } else { 'unrecorded' }) } })
  }
  $apps = New-Object System.Collections.ArrayList
  $claimedProjects = @{}; $claimedNames = @{}
  foreach ($m in $Managed) {
    $project = [string](Get-AcProp $m 'project' '')
    $claimedProjects[$project] = $true
    $cs = @($Containers | Where-Object { [string](Get-AcProp (Get-AcProp $_ 'compose' $null) 'project' '') -eq $project })
    foreach ($c in $cs) { $claimedNames[[string]$c.name] = $true }
    $manifest = Get-AcProp $m 'manifest' $null
    $src = [string](Get-AcProp (Get-AcProp $manifest 'source' $null) 'type' $(if ([string](Get-AcProp $m 'source' '') -eq 'provision') { 'imported' } else { 'curated' }))
    $hosts = @($cs | ForEach-Object { [string]$_.name }) + @([string](Get-AcProp $m 'webContainer' ''))
    $null = $apps.Add([ordered]@{ instanceId = [string](Get-AcProp $m 'instanceId' "legacy-$project"); name = [string](Get-AcProp $m 'name' $project); mode = 'managed'
        authority = [ordered]@{ id = 'dtc'; label = 'DTC (this Deployment Manager)'; confidence = 'certain'; evidence = @("Registered in apps.json ($([string](Get-AcProp $m 'origin' 'installed')))") }
        recipe = (Get-RecipeRef $(if ($src -eq 'curated') { 'catalog' } else { 'imported' }) ([string](Get-AcProp $m 'appId' $project)) ([string](Get-AcProp $manifest 'manifestVersion' '')))
        trust = $(if ($manifest) { Get-RecipeTrust $manifest } else { [ordered]@{ level = $(if ($src -eq 'curated') { 'curated' } else { 'untrusted' }); status = 'ready'; reasons = @() } })
        project = $project; containers = @($cs | ForEach-Object { [ordered]@{ name = [string]$_.name; state = [string]$_.state; health = [string](Get-AcProp $_ 'health' '') } })
        routes = @(& $routesFor $hosts ''); rights = $script:ModeRights.managed; origin = [string](Get-AcProp $m 'origin' 'installed') })
  }
  foreach ($i in @(Get-AcProp $Registry 'instances' @())) {
    $c = Find-InstanceContainer $i $Containers
    $t = Get-AcProp $i 'target' $null
    if ([string](Get-AcProp $t 'project' '')) { $claimedProjects[[string]$t.project] = $true }
    $members = @(if ([string](Get-AcProp $t 'project' '')) { @($Containers | Where-Object { [string](Get-AcProp (Get-AcProp $_ 'compose' $null) 'project' '') -eq [string]$t.project }) } elseif ($c) { @($c) })
    foreach ($x in $members) { $claimedNames[[string]$x.name] = $true }
    $hosts = @($members | ForEach-Object { [string]$_.name }) + @([string](Get-AcProp $t 'container' ''))
    $mode = [string]$i.mode
    $null = $apps.Add([ordered]@{ instanceId = [string]$i.instanceId; name = [string]$i.name; mode = $mode; authority = (Get-AcProp $i 'authority' $null)
        recipe = 'none'; trust = [ordered]@{ level = 'external'; status = 'not-applicable'; reasons = @('Installed by another tool: DTC did not choose its images or settings.') }
        project = [string](Get-AcProp $t 'project' ''); containers = @($members | ForEach-Object { [ordered]@{ name = [string]$_.name; state = [string]$_.state; health = [string](Get-AcProp $_ 'health' '') } })
        routes = @(& $routesFor $hosts ([string]$i.instanceId)); integrations = @(Get-AcProp $i 'integrations' @()); rights = $script:ModeRights[$mode]; found = [bool]$c })
  }
  # Everything else running on this engine: candidates to integrate or observe (grouped by Compose project).
  $own = @($OwnContainers)
  $rest = @($Containers | Where-Object {
      $p = [string](Get-AcProp (Get-AcProp $_ 'compose' $null) 'project' '')
      -not $claimedNames.ContainsKey([string]$_.name) -and -not ($p -and $claimedProjects.ContainsKey($p)) -and $own -notcontains [string]$_.name -and -not ($StackName -and $p -eq $StackName) -and -not [bool](Get-AcProp $_ 'infrastructure' $false)
    })
  $groups = [ordered]@{}
  foreach ($c in $rest) { $p = [string](Get-AcProp (Get-AcProp $c 'compose' $null) 'project' ''); $k = $(if ($p) { "project:$p" } else { "container:$($c.name)" }); if (-not $groups.Contains($k)) { $groups[$k] = @() }; $groups[$k] += $c }
  $unmanaged = @(foreach ($k in $groups.Keys) {
      $cs = @($groups[$k])
      $front = @($cs | Where-Object { -not [bool](Get-AcProp $_ 'privateService' $false) -and @(@(Get-AcProp $_ 'ports' @()) | Where-Object { $_.guess -in 'http', 'https' }).Count } | Select-Object -First 1)
      $auth = Get-ManagementAuthority $cs[0]
      [ordered]@{ key = $k; name = $(if ($k -like 'project:*') { $k.Substring(8) } else { [string]$cs[0].name }); project = [string](Get-AcProp (Get-AcProp $cs[0] 'compose' $null) 'project' '')
        authority = $auth; suggestedMode = $(if ($front.Count) { 'integrated' } else { 'observed' })
        frontend = $(if ($front.Count) { [ordered]@{ container = [string]$front[0].name; service = [string](Get-AcProp (Get-AcProp $front[0] 'compose' $null) 'service' ''); onProxyNetwork = [bool](Get-AcProp $front[0] 'onProxyNetwork' $false); ports = @(@($front[0].ports) | Where-Object { $_.guess -in 'http', 'https' } | ForEach-Object { [ordered]@{ port = [int]$_.port; guess = [string]$_.guess } }) } } else { $null })
        containers = @($cs | ForEach-Object { [ordered]@{ name = [string]$_.name; image = [string]$_.image; state = [string]$_.state; privateService = [bool](Get-AcProp $_ 'privateService' $false) } })
        routes = @(& $routesFor @($cs | ForEach-Object { [string]$_.name }) '') }
    })
  return [ordered]@{ contractVersion = $script:ContractVersion; applications = $apps.ToArray(); unmanaged = $unmanaged; modes = $script:ModeRights }
}

Export-ModuleMember -Function Get-OwnershipModes, Test-OwnershipRight, Get-ManagementAuthority, Get-RecipeTrust, Get-RecipeRef, Get-AuthenticationOptions, New-ContractRegistry,
  ConvertTo-CurrentContractRegistry, Test-ContractRegistry, Get-ContractRegistryPath, Read-ContractRegistry, Save-ContractRegistry, New-ObservedBaseline, New-ContractInstance,
  Find-InstanceContainer, Get-ApplicationInventory, New-ContractId
