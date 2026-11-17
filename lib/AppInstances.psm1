Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AppCatalog.psm1')

# Installed application instances, kept apart from application definitions (catalog manifests). An application (e.g.
# Rocket.Chat, canonical id 'rocketchat') may have several intentional installations; each instance has its own id,
# Compose project, folder, containers, volumes, networks and hostnames. Pure functions: callers pass the registry
# records (config\apps.json), the catalog entries and container facts (ConvertFrom-ContainerInspect).
#
# Identity is never inferred from names alone: an installation belongs to an application when its registry record says
# so (appId, resolved through aliases), when its containers carry the manager's org.traefik-proxy.app label, or when
# the image of the application's own web service runs in it. An image that is only a dependency (PostgreSQL inside one
# app, MongoDB inside another) never makes two installations the same application.

function Get-InstProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# Pure: the repository part of an image reference, without registry defaults, tag or digest
# ('docker.io/library/postgres:16@sha256:...' -> 'postgres', 'ghcr.io/x/y:1' -> 'ghcr.io/x/y').
function Get-ImageRepository([string]$Image) {
  $i = ($Image -replace '@sha256:[0-9a-f]{64}$', '').ToLowerInvariant()
  $slash = $i.LastIndexOf('/'); $colon = $i.LastIndexOf(':')
  if ($colon -gt $slash) { $i = $i.Substring(0, $colon) }
  $i = $i -replace '^(docker\.io|index\.docker\.io|registry-1\.docker\.io)/', ''
  $i = $i -replace '^library/', ''
  return $i
}

# Pure: one registry record as an instance. Older records (before instance ids) get a stable id derived from the
# project name; nothing is written back.
function ConvertTo-AppInstance($Record, $CatalogApps) {
  $appRef = [string](Get-InstProp $Record 'appId' '')
  $entry = Resolve-CatalogEntry $CatalogApps $appRef
  $project = [string](Get-InstProp $Record 'project' '')
  return [ordered]@{
    instanceId = $(if (Get-InstProp $Record 'instanceId' '') { [string]$Record.instanceId } else { "legacy-$project" })
    project = $project; appId = $(if ($entry) { $entry.id } else { $appRef }); recordedAppId = $appRef
    applicationId = $(if ($entry) { Get-ApplicationId $entry.manifest } else { $appRef }); known = [bool]$entry
    availability = $(if ($entry) { [string](Get-InstProp $entry.manifest 'availability' 'offered') } else { '' })
    name = [string](Get-InstProp $Record 'name' $(if ($entry) { $entry.manifest.name } else { $project })); label = [string](Get-InstProp $Record 'label' '')
    folder = [string](Get-InstProp $Record 'folder' ''); installedAt = [string](Get-InstProp $Record 'installedAt' '')
    origin = [string](Get-InstProp $Record 'origin' 'installed'); prepared = [bool](Get-InstProp $Record 'prepared' $false)
    archived = [bool](Get-InstProp $Record 'archived' $false); archivedAt = [string](Get-InstProp $Record 'archivedAt' '')
    localPort = [int](Get-InstProp $Record 'localPort' 0); localUrl = [string](Get-InstProp $Record 'localUrl' '')
    composeSha256 = [string](Get-InstProp $Record 'composeSha256' ''); composeFile = [string](Get-InstProp $Record 'composeFile' '')
    # Modular stacks: the Compose files of the project (compose.yaml first) and its stack description.
    composeFiles = @(Get-InstProp $Record 'composeFiles' @()); stackFile = [string](Get-InstProp $Record 'stackFile' ''); installState = [string](Get-InstProp $Record 'installState' '')
    # Applications imported by the provisioning engine keep their manifest next to compose.yaml.
    manifestFile = [string](Get-InstProp $Record 'manifestFile' ''); source = [string](Get-InstProp $Record 'source' '')
  }
}

# Pure: the image repository that identifies an application: its web service's image (installable manifests), or the
# reference image of listed-only and retired entries (e.g. Diun, Watchtower). Supporting images are not identifying.
function Get-IdentifyingRepository($Manifest) {
  $web = [string](Get-InstProp (Get-InstProp $Manifest 'web' $null) 'service' '')
  $svc = Get-InstProp (Get-InstProp $Manifest 'services' $null) $web $null
  if ($svc) { return Get-ImageRepository ([string](Get-InstProp $svc 'image' '')) }
  $ref = [string](Get-InstProp $Manifest 'imageReference' '')
  if ($ref) { return Get-ImageRepository $ref }
  return ''
}

# Pure: every image repository that identifies an application: its own (above) plus other well-known builds of the same
# application the manifest lists in identifiedBy (e.g. the LinuxServer.io image of Plex), so an existing installation
# made from another build is still recognized and never installed a second time.
function Get-IdentifyingRepositories($Manifest) {
  return @(@(Get-IdentifyingRepository $Manifest) + @(@(Get-InstProp $Manifest 'identifiedBy' @()) | ForEach-Object { Get-ImageRepository ([string]$_) }) | Where-Object { $_ } | Select-Object -Unique)
}

# Pure: Compose projects running on this PC that the registry does not know, recognized as a catalog application by
# the manager's label or by the application's identifying image. $Containers = container facts of all projects.
# $Exclude = project names that are not candidates (the proxy deployment itself, registered instances).
function Get-UnregisteredInstallations([object[]]$Containers, $CatalogApps, [string[]]$Exclude = @()) {
  $out = @()
  $byProject = @{}
  foreach ($c in @($Containers | Where-Object { $_ -and (Get-InstProp $_ 'project' '') -and -not (Get-InstProp $_ 'oneoff' $false) })) {
    if ($Exclude -contains $c.project) { continue }
    if (-not $byProject.ContainsKey($c.project)) { $byProject[$c.project] = @() }
    $byProject[$c.project] += , $c
  }
  $valid = @($CatalogApps | Where-Object { $_ -and $_.manifest })
  foreach ($p in ($byProject.Keys | Sort-Object)) {
    $cs = @($byProject[$p]); $match = $null; $how = ''
    $labelled = @($cs | Where-Object { Get-InstProp $_ 'app' '' })
    if ($labelled.Count) { $match = Resolve-CatalogEntry $valid ([string]$labelled[0].app); if ($match) { $how = "Its containers carry the manager's label org.traefik-proxy.app=$($labelled[0].app)." } }
    # A project that runs Traefik itself is a proxy deployment (this manager's or another one), whose optional test
    # backend (traefik/whoami) is not an installation of the HTTP echo app.
    $proxyStack = @($cs | Where-Object { (Get-ImageRepository ([string]$_.image)) -eq 'traefik' }).Count -gt 0
    if (-not $match -and -not $proxyStack) {
      # Building blocks listed for reference (PostgreSQL, Redis) run inside many other apps: their image identifies nothing.
      foreach ($e in @($valid | Where-Object { [string](Get-InstProp $_.manifest 'availability' 'offered') -ne 'reference' })) {
        $repos = @(Get-IdentifyingRepositories $e.manifest)
        if (-not $repos.Count) { continue }
        $hit = @($cs | Where-Object { $repos -contains (Get-ImageRepository ([string]$_.image)) })
        if ($hit.Count) { $match = $e; $how = "Container $($hit[0].name) runs $(Get-ImageRepository ([string]$hit[0].image)), an image of $($e.manifest.name) itself."; break }
      }
    }
    if (-not $match) { continue }
    $out += [ordered]@{ project = $p; appId = $match.id; applicationId = (Get-ApplicationId $match.manifest); name = [string]$match.manifest.name
      availability = [string](Get-InstProp $match.manifest 'availability' 'offered'); folder = [string](Get-InstProp $cs[0] 'workingDir' '')
      containers = @($cs | ForEach-Object { [ordered]@{ name = $_.name; service = $_.service; image = $_.image; state = $_.state } }); reason = $how }
  }
  return $out
}

# Pure: containers started without Compose (docker run, other tools) that run a catalog application's identifying
# image. They can be inspected and routed, but not adopted (adoption manages a Compose project). $Containers = facts of
# containers that have no Compose project label.
function Get-StandaloneInstallations([object[]]$Containers, $CatalogApps) {
  $valid = @($CatalogApps | Where-Object { $_ -and $_.manifest -and [string](Get-InstProp $_.manifest 'availability' 'offered') -ne 'reference' })
  return @(foreach ($c in @($Containers | Where-Object { $_ -and -not (Get-InstProp $_ 'project' '') })) {
      $repo = Get-ImageRepository ([string]$c.image)
      $e = @($valid | Where-Object { @(Get-IdentifyingRepositories $_.manifest) -contains $repo })[0]
      if (-not $e) { continue }
      [ordered]@{ project = ''; container = [string]$c.name; appId = $e.id; applicationId = (Get-ApplicationId $e.manifest); name = [string]$e.manifest.name; standalone = $true
        availability = [string](Get-InstProp $e.manifest 'availability' 'offered'); folder = ''
        containers = @([ordered]@{ name = $c.name; service = ''; image = $c.image; state = $c.state })
        reason = "Container $($c.name) runs $repo, the image of $($e.manifest.name) itself. It was not started with Docker Compose, so it can be inspected and routed but not adopted." }
    })
}

# Pure: existing installations of an application (registered instances, archived ones separately, and unregistered
# Compose projects), so a new installation is never created silently next to them.
function Find-AppInstallations([string]$ApplicationId, [object[]]$Instances = @(), [object[]]$Unregistered = @()) {
  $out = @()
  foreach ($i in @($Instances | Where-Object { $_.applicationId -eq $ApplicationId })) {
    $out += [ordered]@{ source = 'registry'; project = $i.project; instanceId = $i.instanceId; label = $i.label; folder = $i.folder; archived = $i.archived; origin = $i.origin
      state = [string](Get-InstProp $i 'state' ''); headline = [string](Get-InstProp $i 'headline' ''); containers = [int](Get-InstProp $i 'containerCount' 0)
      hostnames = @(Get-InstProp $i 'hostnames' @()); reason = "Registered in the manager as $($i.appId)$(if ($i.recordedAppId -ne $i.appId) { " (recorded as '$($i.recordedAppId)', an alias)" })." }
  }
  foreach ($u in @($Unregistered | Where-Object { $_.applicationId -eq $ApplicationId })) {
    $out += [ordered]@{ source = 'docker'; project = $u.project; instanceId = ''; label = ''; folder = $u.folder; archived = $false; origin = 'discovered'; state = ''; headline = ''
      containers = @($u.containers).Count; hostnames = @(); reason = "Not registered in the manager. $($u.reason)" }
  }
  return $out
}

# Pure: everything removing an instance would touch, and what it leaves alone. $All = facts of every container on
# the PC (to find volumes and networks shared with other projects). $Routes = services.json entries pointing at the
# instance's containers; $CloudflareHosts / $IdentityApps = references the removal does not change.
function Get-RemovalInventory {
  param($Instance, [object[]]$Containers = @(), [object[]]$All = @(), [object[]]$Routes = @(), [object[]]$CloudflareHosts = @(), [object[]]$IdentityApps = @(), [string]$ProxyNetwork = '', [string[]]$FolderFiles = @())
  $mine = @($Containers | ForEach-Object { [string]$_.name })
  $others = @($All | Where-Object { $mine -notcontains [string]$_.name })
  $created = ($Instance.origin -ne 'adopted')
  $volumes = @(); $seen = @{}
  foreach ($c in $Containers) { foreach ($m in @(Get-InstProp $c 'mounts' @() | Where-Object { $_.type -eq 'volume' -and $_.name })) {
      if ($seen.ContainsKey($m.name)) { continue }; $seen[$m.name] = $true
      $users = @($others | Where-Object { @(Get-InstProp $_ 'mounts' @() | Where-Object { $_.name -eq $m.name }).Count } | ForEach-Object { $_.name })
      # Anonymous volumes (declared by an image, e.g. MongoDB's /data/configdb) are created by Docker for this app's
      # own containers; named ones belong to the app when they carry its project prefix.
      $anonymous = [bool]($m.name -match '^[0-9a-f]{64}$')
      $ours = $created -and ($anonymous -or $m.name -like "$($Instance.project)_*")
      $volumes += [ordered]@{ name = $m.name; target = $m.target; anonymous = $anonymous; usedBy = [string]$c.name; sharedWith = $users; createdByManager = $ours
        action = $(if ($users.Count) { 'kept: also used by other containers' } elseif (-not $ours) { 'kept: not created by the manager' } else { 'kept unless you choose to delete data' }) }
    } }
  $networks = @(); $nseen = @{}
  foreach ($c in $Containers) { foreach ($n in @(Get-InstProp $c 'networks' @())) {
      if ($nseen.ContainsKey($n.name)) { continue }; $nseen[$n.name] = $true
      $users = @($others | Where-Object { @(Get-InstProp $_ 'networks' @() | Where-Object { $_.name -eq $n.name }).Count } | ForEach-Object { $_.name })
      $projectNet = $n.name -like "$($Instance.project)_*"
      $networks += [ordered]@{ name = $n.name; sharedWith = @($users | Select-Object -First 8); sharedCount = $users.Count
        action = $(if ($n.name -eq $ProxyNetwork) { 'kept: the shared proxy network' } elseif ($users.Count) { 'kept: also used by other containers' } elseif ($projectNet -and $created) { 'removed with the containers (the app''s private network)' } else { 'kept: not created for this app' }) }
    } }
  $blocking = @($Routes | ForEach-Object { "Service route '$($_.name)' ($(@($_.hostnames) -join ', ')) points at this app; remove it on the Services page first." })
  return [ordered]@{
    project = $Instance.project; origin = $Instance.origin; createdByManager = $created
    containers = @($Containers | ForEach-Object { [ordered]@{ name = $_.name; service = $_.service; state = $_.state; action = 'stopped and removed' } })
    volumes = $volumes; networks = $networks
    files = @($FolderFiles | ForEach-Object { [ordered]@{ name = $_; action = $(if ($created) { 'kept unless you choose to delete the generated files' } else { 'kept: not created by the manager' }) } })
    references = @(@($CloudflareHosts | ForEach-Object { "Cloudflare: $($_) (DNS record and tunnel route are removed only by unpublishing the service)" }) + @($IdentityApps | ForEach-Object { "authentik application $($_) (unchanged; remove it in authentik if you no longer need it)" }))
    blocking = $blocking
    dataDeletionAllowed = ($created -and -not @($volumes | Where-Object { @($_.sharedWith).Count }).Count)
  }
}

Export-ModuleMember -Function Get-ImageRepository, ConvertTo-AppInstance, Get-IdentifyingRepository, Get-IdentifyingRepositories, Get-UnregisteredInstallations, Get-StandaloneInstallations, Find-AppInstallations, Get-RemovalInventory
