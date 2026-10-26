Set-StrictMode -Version 2.0

# App Catalog: curated application manifests (catalog\apps\*.json) turned into ordinary, portable Compose projects.
# Each installed app is its own folder (compose.yaml + .env + README.md) and its own Compose project; its data lives in
# named volumes (or folders the user chose). The manager only remembers where it installed what
# (config\apps.json of the deployment); everything keeps working, and stays manageable with plain docker compose, if
# the manager is never opened again. Secrets are generated or entered server-side, written to .env only (restricted
# ACL), referenced from compose.yaml as ${VAR}, and never returned to the browser.

$script:SchemaVersion = 1
$script:IdPattern = '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'
$script:ImagePattern = '^[a-z0-9]+([._/-][a-z0-9]+)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[0-9a-f]{64}$'
$script:EnvKeyPattern = '^[A-Z][A-Z0-9_]{0,63}$'
$script:Platforms = @('windows-docker-desktop', 'linux-docker', 'unraid', 'podman')
$script:Categories = @('monitoring', 'media', 'management', 'authentication', 'networking', 'tools', 'productivity', 'communication', 'photos', 'dashboard', 'updates')
# Paths inside an app's project folder: relative, no '..', no drive letters.
$script:RelPathPattern = '^(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9_.-]+)*$'
# Values computed at installation time from another input (see Resolve-DerivedValue in webui.ps1).
$script:DerivedMethods = @('authelia-argon2')
# Whether a manifest is offered for new installations: 'offered' (default), 'reference' (listed for information, e.g.
# building blocks bundled inside other apps) or 'retired' (no longer offered; kept so existing installations are still
# recognized).
$script:Availability = @('offered', 'reference', 'retired')
# Where a manifest comes from. Only curated manifests are installable in this version; community and generated
# manifests will pass through the same validation before they can be.
$script:SourceTypes = @('curated', 'community', 'generated')
# Service roles in a multi-container app, and the lifecycle each implies unless the manifest says otherwise.
$script:ServiceRoles = [ordered]@{ app = 'long-running'; database = 'long-running'; cache = 'long-running'; messaging = 'long-running'; worker = 'long-running'
  support = 'long-running'; proxy = 'long-running'; init = 'run-once'; migration = 'run-once'; maintenance = 'run-once' }
$script:Lifecycles = @('long-running', 'run-once')

function Get-Prop($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# --- Manifests ------------------------------------------------------------------------------------------------------------

# Every rule a curated manifest must satisfy. Returns error strings (empty = valid).
function Test-AppManifest($M) {
  $e = New-Object System.Collections.ArrayList
  $add = { param($t) $null = $e.Add($t) }
  if ((Get-Prop $M 'schema' 0) -ne $script:SchemaVersion) { & $add "schema must be $($script:SchemaVersion)" }
  $id = [string](Get-Prop $M 'id' '')
  if ($id -notmatch $script:IdPattern) { & $add "id '$id' is invalid" }
  foreach ($f in @('name', 'description', 'license', 'maintainer', 'category')) { if (-not [string](Get-Prop $M $f '')) { & $add "$f is required" } }
  if ($script:Categories -notcontains [string](Get-Prop $M 'category' '')) { & $add "category must be one of $($script:Categories -join ', ')" }
  if ((Get-Prop $M 'group' '') -and [string](Get-Prop $M 'group' '') -notmatch '^[A-E]$') { & $add 'group must be A, B, C, D or E' }
  $res = Get-Prop $M 'resources' $null
  if ($res) { foreach ($k in @('memoryMB', 'diskMB')) { $v = Get-Prop $res $k $null; if ($null -ne $v -and ([int]$v -lt 0 -or [int]$v -gt 1048576)) { & $add "resources.$k is out of range" } } }
  foreach ($d in @(Get-Prop $M 'docs' @())) { if ([string](Get-Prop $d 'url' '') -notmatch '^https://') { & $add 'documentation links must be https URLs' } }
  if (-not @(Get-Prop $M 'docs' @()).Count) { & $add 'at least one documentation link is required' }
  $platforms = Get-Prop $M 'platforms' $null
  if (-not $platforms) { & $add 'platforms is required' }
  else { foreach ($p in $platforms.PSObject.Properties) { if ($script:Platforms -notcontains $p.Name) { & $add "unknown platform '$($p.Name)'" } elseif ($p.Value -notin 'supported', 'untested', 'limited', 'unsupported') { & $add "platform '$($p.Name)' must be supported, limited, untested or unsupported" } } }
  # Identity: the canonical id, earlier ids and other spellings (aliases), and variants grouped under one application.
  if ((Get-Prop $M 'manifestVersion' '') -and [string]$M.manifestVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$') { & $add 'manifestVersion is invalid' }
  foreach ($a in @(Get-Prop $M 'aliases' @())) { if ([string]$a -notmatch $script:IdPattern -or [string]$a -eq $id) { & $add "alias '$a' is invalid" } }
  $variantOf = [string](Get-Prop $M 'variantOf' '')
  if ($variantOf -and ($variantOf -notmatch $script:IdPattern -or $variantOf -eq $id)) { & $add 'variantOf must name another application' }
  if ($variantOf -and -not [string](Get-Prop (Get-Prop $M 'variant' $null) 'label' '')) { & $add 'a variant needs variant.label' }
  $cg = Get-Prop $M 'choiceGroup' $null
  if ($cg -and [string](Get-Prop $cg 'id' '') -notmatch $script:IdPattern) { & $add 'choiceGroup.id is invalid' }
  $availability = [string](Get-Prop $M 'availability' 'offered')
  if ($script:Availability -notcontains $availability) { & $add "availability must be one of $($script:Availability -join ', ')" }
  if ($availability -ne 'offered' -and [bool](Get-Prop $M 'installable' $false)) { & $add "a $availability manifest cannot be installable" }
  if ($availability -eq 'retired' -and -not [string](Get-Prop (Get-Prop $M 'retired' $null) 'note' '')) { & $add 'a retired manifest needs retired.note' }
  $sourceType = [string](Get-Prop (Get-Prop $M 'source' $null) 'type' 'curated')
  if ($script:SourceTypes -notcontains $sourceType) { & $add "source.type must be one of $($script:SourceTypes -join ', ')" }
  elseif ($sourceType -ne 'curated' -and [bool](Get-Prop $M 'installable' $false)) { & $add 'only curated manifests are installable in this version' }
  if (-not [bool](Get-Prop $M 'installable' $false)) { if (-not [string](Get-Prop $M 'installNote' '') -and $availability -ne 'retired') { & $add 'a manifest that is not installable needs installNote' }; return $e.ToArray() }
  $services = Get-Prop $M 'services' $null
  if (-not $services -or -not @($services.PSObject.Properties).Count) { & $add 'services is required'; return $e.ToArray() }
  $serviceNames = @($services.PSObject.Properties | ForEach-Object { $_.Name })
  $inputs = @(Get-Prop $M 'inputs' @())
  $inputIds = @($inputs | ForEach-Object { [string]$_.id })
  foreach ($i in $inputs) {
    if ([string]$i.id -notmatch '^[a-zA-Z][a-zA-Z0-9]{0,40}$') { & $add "input id '$($i.id)' is invalid" }
    $type = [string](Get-Prop $i 'type' '')
    if ($type -notin 'text', 'secret', 'generated', 'password', 'folder', 'timezone', 'boolean', 'derived') { & $add "input '$($i.id)' has an unknown type" }
    if ($type -eq 'generated' -and [int](Get-Prop $i 'bytes' 0) -lt 16) { & $add "generated input '$($i.id)' needs bytes >= 16" }
    if ($type -eq 'derived' -and ([string](Get-Prop $i 'method' '') -notin $script:DerivedMethods -or $inputIds -notcontains [string](Get-Prop $i 'from' ''))) { & $add "derived input '$($i.id)' needs a known method and an existing 'from' input" }
  }
  $declared = @(Get-Prop $M 'privileges' @() | ForEach-Object { [string]$_.kind })
  # traefikContainer / proxyNetwork / domains describe the proxy deployment the app is installed next to.
  $known = @('input', 'project', 'appUrl', 'timezone', 'webPort', 'service', 'localPort', 'traefikContainer', 'proxyNetwork', 'domains')
  $checkTemplates = { param($where, [string]$text, [string[]]$extra)
    foreach ($tm in [regex]::Matches($text, '\{\{\s*([a-zA-Z]+)(?::([a-zA-Z0-9-]+))?\s*\}\}')) {
      $kind = $tm.Groups[1].Value; $ref = $tm.Groups[2].Value
      if ($kind -eq 'input' -and $inputIds -notcontains $ref) { & $add "${where}: {{input:$ref}} has no input" }
      elseif ($kind -eq 'service' -and $serviceNames -notcontains $ref) { & $add "${where}: {{service:$ref}} names no service" }
      elseif (($known + $extra) -notcontains $kind) { & $add "${where}: unknown template variable {{$kind}}" }
    } }
  $primary = 0
  foreach ($sp in $services.PSObject.Properties) {
    $s = $sp.Value; $where = "service '$($sp.Name)'"
    if ($sp.Name -notmatch $script:IdPattern) { & $add "service name '$($sp.Name)' is invalid" }
    if ([string](Get-Prop $s 'image' '') -notmatch $script:ImagePattern) { & $add "${where}: image must be pinned by digest (name:tag@sha256:...)" }
    if ((Get-Prop $s 'role' '') -and -not $script:ServiceRoles.Contains([string]$s.role)) { & $add "${where}: role must be one of $(@($script:ServiceRoles.Keys) -join ', ')" }
    if ((Get-Prop $s 'lifecycle' '') -and $script:Lifecycles -notcontains [string]$s.lifecycle) { & $add "${where}: lifecycle must be long-running or run-once" }
    if ($sp.Name -eq [string](Get-Prop (Get-Prop $M 'web' $null) 'service' '') -and (Get-ServiceDeclaredLifecycle $s).lifecycle -eq 'run-once') { & $add "${where}: the web service cannot be a run-once job" }
    $when = [string](Get-Prop $s 'when' '')
    if ($when -and -not @($inputs | Where-Object { $_.id -eq $when -and $_.type -eq 'boolean' }).Count) { & $add "${where}: when must name a boolean input" }
    foreach ($p in @(Get-Prop $s 'ports' @())) {
      if ([int](Get-Prop $p 'container' 0) -lt 1 -or [int](Get-Prop $p 'container' 0) -gt 65535) { & $add "${where}: invalid port" }
      if ([string](Get-Prop $p 'protocol' '') -notin 'http', 'https', 'tcp', 'udp') { & $add "${where}: port protocol must be http, https, tcp or udp" }
      if ([bool](Get-Prop $p 'primary' $false)) { $primary++ }
    }
    foreach ($v in @(Get-Prop $s 'volumes' @())) {
      $kind = [string](Get-Prop $v 'kind' 'volume')
      if ([string](Get-Prop $v 'name' '') -notmatch $script:IdPattern) { & $add "${where}: volume name '$($v.name)' is invalid" }
      if ([string](Get-Prop $v 'target' '') -notmatch '^/[A-Za-z0-9._/-]*$') { & $add "${where}: volume target must be an absolute container path" }
      if ($kind -notin 'volume', 'folder', 'project', 'tmpfs') { & $add "${where}: volume kind must be volume, folder, project or tmpfs" }
      if ($kind -eq 'folder' -and $inputIds -notcontains [string](Get-Prop $v 'input' '')) { & $add "${where}: folder volume '$($v.name)' needs an input" }
      if ($kind -eq 'volume' -and (Get-Prop $v 'input' '') -and $inputIds -notcontains [string]$v.input) { & $add "${where}: volume '$($v.name)' names an unknown folder input" }
      if ($kind -eq 'project' -and [string](Get-Prop $v 'source' '') -notmatch $script:RelPathPattern) { & $add "${where}: project volume '$($v.name)' needs a relative source inside the project folder" }
    }
    foreach ($d in @(Get-Prop $s 'dependsOn' @())) {
      if ($serviceNames -notcontains [string](Get-Prop $d 'service' '')) { & $add "${where}: dependsOn names no service" }
      if ([string](Get-Prop $d 'condition' 'service_started') -notin 'service_started', 'service_healthy', 'service_completed_successfully') { & $add "${where}: unknown dependsOn condition" }
    }
    $envObj = Get-Prop $s 'environment' $null
    if ($envObj) { foreach ($ev in $envObj.PSObject.Properties) {
        if ($ev.Name -notmatch $script:EnvKeyPattern) { & $add "${where}: environment key '$($ev.Name)' is invalid" }
        & $checkTemplates $where ([string]$ev.Value) @()
      } }
    foreach ($c in @(Get-Prop $s 'command' @())) { & $checkTemplates $where ([string]$c) @() }
    if ((Get-Prop $s 'user' '') -and [string](Get-Prop $s 'user' '') -notmatch '^\d{1,6}(:\d{1,6})?$') { & $add "${where}: user must be uid[:gid]" }
    $needs = @()
    if (Get-Prop $s 'dockerSocket' $false) { $needs += 'docker-socket' }
    if ([string](Get-Prop $s 'networkMode' '') -eq 'host') { $needs += 'host-network' } elseif (Get-Prop $s 'networkMode' '') { & $add "${where}: networkMode may only be host" }
    if (@(Get-Prop $s 'devices' @()).Count) { $needs += 'device'; foreach ($dv in @(Get-Prop $s 'devices' @())) { if ([string]$dv -notmatch '^/dev/[A-Za-z0-9/_-]+$') { & $add "${where}: device '$dv' is invalid" } } }
    $g = Get-Prop $s 'gpus' $false
    if ($g -is [string] -and -not @($inputs | Where-Object { $_.id -eq $g -and $_.type -eq 'boolean' }).Count) { & $add "${where}: gpus must be true or name a boolean input" }
    if ($g) { $needs += 'gpu' }
    if (Get-Prop $s 'privileged' $false) { $needs += 'privileged' }
    foreach ($n in $needs) { if ($declared -notcontains $n) { & $add "${where} needs '$n' but privileges does not declare it" } }
  }
  foreach ($f in @(Get-Prop $M 'files' @())) {
    if ([string](Get-Prop $f 'path' '') -notmatch $script:RelPathPattern) { & $add "file '$($f.path)': path must be relative inside the project folder" }
    if ([string](Get-Prop $f 'path' '') -in 'compose.yaml', '.env', 'README.md') { & $add "file '$($f.path)' is reserved" }
    & $checkTemplates "file '$($f.path)'" ([string](Get-Prop $f 'content' '')) @('installedApps')
  }
  foreach ($h in @(Get-Prop $M 'postInstall' @())) {
    if ($serviceNames -notcontains [string](Get-Prop $h 'service' '')) { & $add 'postInstall names no service' }
    foreach ($c in @(Get-Prop $h 'command' @())) { & $checkTemplates 'postInstall' ([string]$c) @() }
    $hh = Get-Prop $h 'http' $null
    if ($hh) { if ([string](Get-Prop $hh 'path' '') -notmatch '^/[A-Za-z0-9/_.-]*$') { & $add 'postInstall http.path must be a path' }; & $checkTemplates 'postInstall' ([string](Get-Prop $hh 'body' '')) @() }
    elseif (-not @(Get-Prop $h 'command' @()).Count) { & $add 'postInstall needs a command or http' }
  }
  foreach ($p in $declared) { if ($p -notin 'docker-socket', 'host-network', 'device', 'gpu', 'privileged') { & $add "unknown privilege '$p'" } }
  if ($primary -ne 1) { & $add 'exactly one port must be marked primary (the web interface)' }
  $web = Get-Prop $M 'web' $null
  if (-not $web -or -not $services.PSObject.Properties[[string](Get-Prop $web 'service' '')]) { & $add 'web.service must name a service' }
  elseif ((Get-Prop $web 'localPort' $null) -and ([int]$web.localPort -lt 1024 -or [int]$web.localPort -gt 65535)) { & $add 'web.localPort must be between 1024 and 65535' }
  if ([string](Get-Prop (Get-Prop $M 'exposure' $null) 'default' '') -notin 'access', 'public', 'local') { & $add 'exposure.default must be access, public or local' }
  return $e.ToArray()
}

function Get-CatalogApps {
  param([Parameter(Mandatory = $true)][string]$CatalogDir)
  $dir = Join-Path $CatalogDir 'apps'
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $list = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
      $file = $_; $m = $null
      try { $m = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json } catch { [pscustomobject]@{ id = $file.BaseName; errors = @("invalid JSON: $($_.Exception.Message)"); manifest = $null; file = $file.Name }; return }
      $errs = @(Test-AppManifest $m)
      if ([string]$m.id -ne $file.BaseName) { $errs += "the file name must be <id>.json" }
      [pscustomobject]@{ id = [string]$m.id; errors = $errs; manifest = $m; file = $file.Name }
    })
  # Across manifests: every id and alias names exactly one application (also ignoring case, dashes and dots), and a
  # variant belongs to an application that is not itself a variant.
  $owner = @{}
  foreach ($a in $list) {
    if (-not $a.manifest) { continue }
    foreach ($ref in @(@($a.id) + @(Get-Prop $a.manifest 'aliases' @()))) {
      $k = Get-AppIdentityKey $ref
      if (-not $k) { continue }
      if ($owner.ContainsKey($k) -and $owner[$k] -ne $a.id) { $a.errors = @($a.errors) + "'$ref' already names catalog app '$($owner[$k])'" } else { $owner[$k] = $a.id }
    }
  }
  foreach ($a in $list) {
    $v = [string](Get-Prop $a.manifest 'variantOf' '')
    if (-not $v) { continue }
    $base = @($list | Where-Object { $_.id -eq $v -and $_.manifest })
    if (-not $base.Count) { $a.errors = @($a.errors) + "variantOf names no catalog app ('$v')" }
    elseif (Get-Prop $base[0].manifest 'variantOf' '') { $a.errors = @($a.errors) + "variantOf must name an application, not another variant ('$v')" }
  }
  return $list
}

# Pure: the comparison key of an application reference: lowercase letters and digits only, so 'Rocket.Chat',
# 'rocket-chat' and 'rocketchat' are the same application.
function Get-AppIdentityKey([string]$Reference) { return ($Reference.ToLowerInvariant() -replace '[^a-z0-9]', '') }

# Pure: the catalog entry an id, alias or spelling refers to (exact id first, then aliases, then the identity key of
# ids, aliases and display names). $null when nothing matches.
function Resolve-CatalogEntry($Apps, [string]$Reference) {
  if (-not $Reference) { return $null }
  $valid = @($Apps | Where-Object { $_.manifest })
  $hit = @($valid | Where-Object { $_.id -eq $Reference })
  if (-not $hit.Count) { $hit = @($valid | Where-Object { @(Get-Prop $_.manifest 'aliases' @()) -contains $Reference }) }
  if (-not $hit.Count) {
    $k = Get-AppIdentityKey $Reference
    if ($k) { $hit = @($valid | Where-Object { $e = $_; @(@($e.id) + @(Get-Prop $e.manifest 'aliases' @()) + @([string](Get-Prop $e.manifest 'name' ''))) | Where-Object { (Get-AppIdentityKey $_) -eq $k } }) }
  }
  if ($hit.Count) { return $hit[0] }
  return $null
}

# Pure: the application a manifest installs. A variant (e.g. Dispatcharr's modular compose) installs the same
# application as its base manifest, so both count as one application for grouping and duplicate detection.
function Get-ApplicationId($Manifest) {
  $v = [string](Get-Prop $Manifest 'variantOf' '')
  if ($v) { return $v }
  return [string](Get-Prop $Manifest 'id' '')
}

# Pure: whether new installations may use this manifest ('offered'), or it is listed for reference or retired.
function Get-ManifestAvailability($Manifest) { return [string](Get-Prop $Manifest 'availability' 'offered') }

# Pure: the role and lifecycle a manifest declares for one of its services (role defaults to none; lifecycle follows
# the role unless set). Source 'manifest' when anything is declared.
function Get-ServiceDeclaredLifecycle($Service) {
  $role = [string](Get-Prop $Service 'role' '')
  $life = [string](Get-Prop $Service 'lifecycle' '')
  if (-not $life -and $role -and $script:ServiceRoles.Contains($role)) { $life = $script:ServiceRoles[$role] }
  return [ordered]@{ role = $role; lifecycle = $life; label = [string](Get-Prop $Service 'label' ''); purpose = [string](Get-Prop $Service 'purpose' ''); declared = [bool]($role -or $life) }
}

function Get-CatalogApp([string]$CatalogDir, [string]$Id) {
  $a = Resolve-CatalogEntry (Get-CatalogApps -CatalogDir $CatalogDir) $Id
  if (-not $a) { throw "No catalog app '$Id'." }
  if (@($a.errors).Count) { throw "Catalog app '$($a.id)' is invalid: $(@($a.errors) -join '; ')" }
  return $a.manifest
}

# Platform support for the current host (this build: Windows with Docker Desktop).
function Get-PlatformSupport($M, [string]$Platform = 'windows-docker-desktop') {
  $p = Get-Prop $M 'platforms' $null
  $v = [string](Get-Prop $p $Platform 'unsupported')
  return [ordered]@{ platform = $Platform; support = $v; installable = ([bool](Get-Prop $M 'installable' $false) -and $v -ne 'unsupported') }
}

# --- Values, templates and Compose ---------------------------------------------------------------------------------------

function New-SecretValue([int]$Bytes = 32) {
  $b = New-Object byte[] $Bytes
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($b) } finally { $rng.Dispose() }
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Resolves {{input:x}}, {{service:name}}, {{project}}, {{appUrl}}, {{timezone}}, {{webPort}}, {{localPort}} (and any
# extra key in $Values, e.g. installedApps for files) in one string. Unknown variables throw.
function Resolve-TemplateValue([string]$Template, [hashtable]$Values) {
  return [regex]::Replace($Template, '\{\{\s*([a-zA-Z]+)(?::([a-zA-Z0-9-]+))?\s*\}\}', {
      param($m)
      $kind = $m.Groups[1].Value; $ref = $m.Groups[2].Value
      $key = $(if ($ref) { "${kind}:$ref" } else { $kind })
      if (-not $Values.ContainsKey($key)) { throw "Template variable {{$key}} has no value." }
      return [string]$Values[$key]
    })
}

# Validates the user's choices and builds every value the templates need. Generated secrets are created here once and
# kept server-side with the plan. Derived values (e.g. a password hash) are computed at installation time and appear
# here as placeholders. Returns Values (template map), Env (KEY -> value per active service), Secrets (env keys whose
# values must never be shown), Derived (input ids still to compute) and Errors.
function Resolve-AppValues {
  param([Parameter(Mandatory = $true)]$Manifest, [hashtable]$Inputs = @{}, [string]$Project, [string]$AppUrl = '', [string]$TimeZone = 'UTC', [hashtable]$Existing = @{}, [int]$LocalPort = 0, [hashtable]$Context = @{})
  $errors = New-Object System.Collections.ArrayList
  $values = @{ project = $Project; appUrl = $AppUrl; timezone = $TimeZone; localPort = $LocalPort; traefikContainer = 'traefik'; proxyNetwork = 'proxy'; domains = 'localhost' }
  foreach ($k in $Context.Keys) { $values[$k] = $Context[$k] }
  foreach ($sp in (Get-Prop $Manifest 'services').PSObject.Properties) { $values["service:$($sp.Name)"] = Get-AppContainerName $Manifest $Project $sp.Name }
  $secretInputs = @(); $derived = @()
  foreach ($i in @(Get-Prop $Manifest 'inputs' @())) {
    $id = [string]$i.id; $type = [string]$i.type; $label = [string](Get-Prop $i 'label' $id)
    $v = $(if ($Inputs.ContainsKey($id)) { [string]$Inputs[$id] } else { '' })
    switch ($type) {
      'generated' { $v = $(if ($Existing.ContainsKey("input:$id")) { $Existing["input:$id"] } else { New-SecretValue ([int]$i.bytes) }); $secretInputs += $id }
      'password' {
        if (-not $v) { $v = $(if ($Existing.ContainsKey("input:$id")) { $Existing["input:$id"] } else { New-PasswordValue }) }
        elseif ($v.Length -lt 12) { $null = $errors.Add("${label}: use at least 12 characters.") }
        $secretInputs += $id
      }
      'secret' { $secretInputs += $id; if (-not $v -and $Existing.ContainsKey("input:$id")) { $v = $Existing["input:$id"] } }
      'derived' { $v = "__derived:$id"; $derived += $id; $secretInputs += $id }
      'timezone' { if (-not $v) { $v = $TimeZone }; if ($v -notmatch '^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$') { $null = $errors.Add("${label}: not a time zone name (e.g. Europe/Berlin).") } }
      'boolean' { $raw = $(if ($v) { $v } else { [string](Get-Prop $i 'default' 'false') }); $v = $(if ($raw -match '^(true|1|yes|on)$') { 'true' } else { 'false' }) }
      'folder' { if ($v) { try { $v = ConvertTo-HostFolder $v } catch { $null = $errors.Add("${label}: $($_.Exception.Message)") } } }
      default { if (-not $v -and (Get-Prop $i 'default' '')) { $v = [string]$i.default } }
    }
    if ([bool](Get-Prop $i 'required' $false) -and -not $v) { $null = $errors.Add("$label is required.") }
    $pattern = [string](Get-Prop $i 'pattern' '')
    if ($v -and $pattern -and $type -in 'text', 'secret' -and $v -notmatch $pattern) { $null = $errors.Add("$label has an invalid format.") }
    if ($v -match "[\r\n]") { $null = $errors.Add("$label must be a single line.") }
    $values["input:$id"] = $v
  }
  $webPort = 0
  foreach ($sp in (Get-Prop $Manifest 'services').PSObject.Properties) { foreach ($p in @(Get-Prop $sp.Value 'ports' @())) { if ([bool](Get-Prop $p 'primary' $false)) { $webPort = [int]$p.container } } }
  $values['webPort'] = $webPort
  $envByService = [ordered]@{}; $secretKeys = New-Object System.Collections.ArrayList
  foreach ($sp in (Get-ActiveServices $Manifest $values)) {
    $env = [ordered]@{}
    $envObj = Get-Prop $sp.Value 'environment' $null
    if ($envObj) { foreach ($ev in $envObj.PSObject.Properties) {
        try { $env[$ev.Name] = Resolve-TemplateValue ([string]$ev.Value) $values } catch { $null = $errors.Add($_.Exception.Message) }
        foreach ($sid in $secretInputs) { if ([string]$ev.Value -match "\{\{\s*input:$sid\s*\}\}") { if (-not $secretKeys.Contains($ev.Name)) { $null = $secretKeys.Add($ev.Name) } } }
      } }
    $envByService[$sp.Name] = $env
  }
  return [pscustomobject]@{ Values = $values; Env = $envByService; Secrets = @($secretKeys); Derived = $derived; Errors = $errors.ToArray() }
}

# A host folder for a bind mount: an existing local folder, not a drive root, not a network path, no quote characters.
function ConvertTo-HostFolder([string]$Path) {
  $p = $Path.Trim()
  if ($p -match '^(\\\\|//)') { throw 'network (UNC) paths are not supported.' }
  if ($p -notmatch '^[A-Za-z]:[\\/]') { throw 'use a full local path such as D:\Media.' }
  if ($p -match "['""`$<>|?*\r\n]") { throw 'the path contains characters Compose cannot use.' }
  $full = [IO.Path]::GetFullPath($p).TrimEnd('\')
  if ($full -match '^[A-Za-z]:$') { throw 'choose a folder, not a whole drive.' }
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "the folder $full does not exist." }
  return $full
}

# Env file text: one KEY=value per line; values with characters Compose would interpret are single-quoted.
function ConvertTo-EnvFileText($Env) {
  $lines = @('# Settings and secrets of this app. Keep this file private: it is readable by your Windows account only.')
  foreach ($k in $Env.Keys) {
    $v = [string]$Env[$k]
    if ($v -match "'") { throw "The value of $k contains a single quote, which .env cannot hold safely." }
    $lines += $(if ($v -match '^[A-Za-z0-9_./:@+,-]*$') { "$k=$v" } else { "$k='$v'" })
  }
  return ($lines -join "`n") + "`n"
}

function ConvertTo-YamlScalar([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }


# The README written next to compose.yaml: how to live without the manager.
function New-AppReadme($Manifest, [string]$Project, [string]$Folder) {
  $docs = (@($Manifest.docs) | ForEach-Object { "- $($_.title): $($_.url)" }) -join "`n"
  return @"
# $($Manifest.name) ($Project)

Installed by the Traefik + Cloudflare Deployment Manager from its App Catalog. This folder is an ordinary Docker
Compose project; you do not need the manager to run, update or remove it.

    cd "$Folder"
    docker compose ps            # state
    docker compose logs -f       # logs
    docker compose restart       # restart
    docker compose down          # stop and remove the containers (data volumes are kept)
    docker compose up -d         # start again

Data lives in the named volumes listed at the end of compose.yaml (docker volume ls --filter name=${Project}_) or in
the folders you chose. ``docker compose down -v`` deletes the named volumes: only do that when you want the data gone.
Settings and secrets are in .env (private to your Windows account).

Licence of the application: $($Manifest.license). Maintainer: $($Manifest.maintainer).
$docs
"@
}

# Pure: every value in $Text that is a secret of this app replaced by [redacted].
function Hide-SecretValues([string[]]$Lines, [string[]]$Secrets) {
  $list = @($Secrets | Where-Object { $_ -and $_.Length -ge 6 } | Sort-Object Length -Descending)
  return @($Lines | ForEach-Object { $t = [string]$_; foreach ($s in $list) { $t = $t.Replace($s, '[redacted]') }; $t })
}

# Reads KEY=value pairs of an app's .env (to reuse generated secrets on update, and to redact logs).
function Read-AppEnv([string]$Path) {
  $map = [ordered]@{}
  if (-not (Test-Path -LiteralPath $Path)) { return $map }
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    if ($line -match '^\s*#' -or $line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { continue }
    $v = $Matches[2]; if ($v -match "^'(.*)'$") { $v = $Matches[1] }
    $map[$Matches[1]] = $v
  }
  return $map
}

# --- Installed apps -----------------------------------------------------------------------------------------------------

function Get-AppsRegistryPath($Settings) { return (Join-Path $Settings.InstallPath 'config\apps.json') }
function Read-AppsRegistry($Settings) {
  $p = Get-AppsRegistryPath $Settings
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  try { return @(([IO.File]::ReadAllText($p) | ConvertFrom-Json).apps | Where-Object { $_ }) } catch { return @() }
}
function Save-AppsRegistry($Settings, $Apps) {
  $p = Get-AppsRegistryPath $Settings
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
  Write-TextFileAtomic $p ((([ordered]@{ version = 1; apps = @($Apps) }) | ConvertTo-Json -Depth 6) + "`n")
}

# Image references in a compose file (service -> image).
function Get-ComposeServiceImages([string]$Text) {
  $map = [ordered]@{}; $svc = ''
  $inServices = $false
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^services:\s*$') { $inServices = $true; continue }
    if ($line -match '^\S') { $inServices = $false; continue }
    if (-not $inServices) { continue }
    if ($line -match '^  ([a-z0-9][a-z0-9-]*):\s*$') { $svc = $Matches[1]; continue }
    if ($svc -and $line -match '^    image:\s*(\S+)\s*$') { $map[$svc] = $Matches[1] }
  }
  return $map
}

# Pure: what an update would change: per service, the installed and the catalog image.
function Get-AppUpdateDiff($Manifest, [string]$ComposeText) {
  $installed = Get-ComposeServiceImages $ComposeText
  $changes = @()
  foreach ($sp in (Get-Prop $Manifest 'services').PSObject.Properties) {
    $now = [string](Get-Prop $installed $sp.Name '')
    if ($now -ne [string]$sp.Value.image) { $changes += [ordered]@{ service = $sp.Name; from = $now; to = [string]$sp.Value.image } }
  }
  return $changes
}

# The container name of a service of an app project.
function Get-AppContainerName($Manifest, [string]$Project, [string]$Service) {
  if (@((Get-Prop $Manifest 'services').PSObject.Properties).Count -eq 1) { return $Project }
  return "$Project-$Service"
}

# The services an installation actually runs (optional services whose boolean input is off are left out).
function Get-ActiveServices($Manifest, [hashtable]$Values) {
  return @((Get-Prop $Manifest 'services').PSObject.Properties | Where-Object {
      $w = [string](Get-Prop $_.Value 'when' '')
      -not $w -or [string]$Values["input:$w"] -eq 'true'
    })
}

# A readable random password (24 characters from an unambiguous alphabet), for accounts a person signs in with.
function New-PasswordValue([int]$Length = 24) {
  $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  $b = New-Object byte[] $Length
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($b) } finally { $rng.Dispose() }
  return -join ($b | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# Files the app needs in its project folder (e.g. a configuration file), rendered from the manifest. They are written
# once at installation and never overwritten afterwards, so the user's edits are kept.
function Get-AppFiles($Manifest, [hashtable]$Values) {
  return @(foreach ($f in @(Get-Prop $Manifest 'files' @())) {
      [ordered]@{ path = [string]$f.path; content = (Resolve-TemplateValue ([string]$f.content) $Values); secret = [bool](Get-Prop $f 'secret' $false) }
    })
}

# Pure: the Compose project of one app. Only the web service (and services marked proxy) join the shared proxy network;
# other services of multi-service apps share a private network. An app whose web.proxy is false (e.g. a directory
# server) never joins the shared network: it gets a private network of its own and is reached on 127.0.0.1 only. $LocalPort publishes the web port on 127.0.0.1 only.
function ConvertTo-AppCompose {
  param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$Project, [Parameter(Mandatory = $true)]$Resolved, [Parameter(Mandatory = $true)][string]$ProxyNetwork, [int]$LocalPort = 0)
  $services = @(Get-ActiveServices $Manifest $Resolved.Values)
  $multi = @((Get-Prop $Manifest 'services').PSObject.Properties).Count -gt 1
  $web = [string](Get-Prop (Get-Prop $Manifest 'web') 'service' '')
  $webProxy = [bool](Get-Prop (Get-Prop $Manifest 'web') 'proxy' $true)
  $active = @($services | ForEach-Object { $_.Name })
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("# Generated by the Deployment Manager from catalog app '$($Manifest.id)' ($($Manifest.name)).")
  $L.Add('# An ordinary Compose project: manage it with docker compose in this folder, with or without the manager.')
  $L.Add('# Settings and secrets are in .env next to this file.')
  $L.Add("name: $Project")
  $L.Add('services:')
  $namedVolumes = New-Object System.Collections.ArrayList
  $usesProxy = $false; $usesInternal = $false
  foreach ($sp in $services) {
    $s = $sp.Value
    $L.Add("  $($sp.Name):")
    $L.Add("    image: $($s.image)")
    $L.Add("    container_name: $(Get-AppContainerName $Manifest $Project $sp.Name)")
    $L.Add('    pull_policy: missing')
    $L.Add("    restart: $(Get-Prop $s 'restart' 'unless-stopped')")
    if (Get-Prop $s 'user' '') { $L.Add("    user: '$($s.user)'") }
    $ep = @(Get-Prop $s 'entrypoint' @())
    if ($ep.Count) { $L.Add('    entrypoint: [' + (($ep | ForEach-Object { ConvertTo-YamlScalar ([string]$_) }) -join ', ') + ']') }
    $cmd = @(Get-Prop $s 'command' @())
    if ($cmd.Count) { $L.Add('    command: [' + (($cmd | ForEach-Object { ConvertTo-YamlScalar (Resolve-TemplateValue ([string]$_) $Resolved.Values) }) -join ', ') + ']') }
    $deps = @(Get-Prop $s 'dependsOn' @() | Where-Object { $active -contains [string]$_.service })
    if ($deps.Count) {
      $L.Add('    depends_on:')
      foreach ($d in $deps) { $L.Add("      $($d.service):"); $L.Add("        condition: $(Get-Prop $d 'condition' 'service_started')") }
    }
    $env = $Resolved.Env[$sp.Name]
    if ($env -and $env.Count) {
      $L.Add('    environment:')
      foreach ($k in $env.Keys) { $L.Add("      ${k}: `${$k}") }
    }
    $vols = @(Get-Prop $s 'volumes' @() | Where-Object { (Get-Prop $_ 'kind' 'volume') -ne 'tmpfs' })
    $tmpfs = @(Get-Prop $s 'volumes' @() | Where-Object { (Get-Prop $_ 'kind' 'volume') -eq 'tmpfs' })
    if ($vols.Count -or (Get-Prop $s 'dockerSocket' $false)) {
      $L.Add('    volumes:')
      foreach ($v in $vols) {
        $ro = [bool](Get-Prop $v 'readOnly' $false)
        switch ([string](Get-Prop $v 'kind' 'volume')) {
          'folder' {
            $src = [string]$Resolved.Values["input:$($v.input)"]
            if ($src) { $L.Add('      - type: bind'); $L.Add("        source: $(ConvertTo-YamlScalar $src)"); $L.Add("        target: $($v.target)"); if ($ro) { $L.Add('        read_only: true') } }
          }
          'project' { $L.Add("      - ./$($v.source):$($v.target)$(if ($ro) { ':ro' })") }
          default {
            # A named volume, unless the user chose a folder for it (e.g. a photo library on another drive).
            $chosen = $(if (Get-Prop $v 'input' '') { [string]$Resolved.Values["input:$($v.input)"] } else { '' })
            if ($chosen) { $L.Add('      - type: bind'); $L.Add("        source: $(ConvertTo-YamlScalar $chosen)"); $L.Add("        target: $($v.target)"); if ($ro) { $L.Add('        read_only: true') } }
            else { $L.Add("      - $($v.name):$($v.target)$(if ($ro) { ':ro' })"); if (-not $namedVolumes.Contains($v.name)) { $null = $namedVolumes.Add($v.name) } }
          }
        }
      }
      if (Get-Prop $s 'dockerSocket' $false) { $L.Add("      - /var/run/docker.sock:/var/run/docker.sock$(if (Get-Prop $s 'dockerSocketReadOnly' $false) { ':ro' })") }
    }
    if ($tmpfs.Count) { $L.Add('    tmpfs:'); foreach ($t in $tmpfs) { $L.Add("      - $($t.target)") } }
    if (Get-Prop $s 'shmSize' '') { $L.Add("    shm_size: '$($s.shmSize)'") }
    if (@(Get-Prop $s 'devices' @()).Count) { $L.Add('    devices:'); foreach ($d in @($s.devices)) { $L.Add("      - $($d):$($d)") } }
    $g = Get-Prop $s 'gpus' $false
    if (($g -is [bool] -and $g) -or ($g -is [string] -and [string]$Resolved.Values["input:$g"] -eq 'true')) { $L.Add('    gpus: all') }
    if (Get-Prop $s 'privileged' $false) { $L.Add('    privileged: true') }
    if ([string](Get-Prop $s 'networkMode' '') -eq 'host') { $L.Add('    network_mode: host') }
    else {
      if ($LocalPort -gt 0 -and $sp.Name -eq $web) {
        $wp = [int](@(Get-Prop $s 'ports' @() | Where-Object { Get-Prop $_ 'primary' $false })[0].container)
        $L.Add('    ports:'); $L.Add("      - '127.0.0.1:${LocalPort}:$wp'")
      }
      $nets = @()
      if (($sp.Name -eq $web -and $webProxy) -or [bool](Get-Prop $s 'proxy' $false)) { $nets += 'proxy'; $usesProxy = $true }
      if ($multi -or -not $webProxy) { $nets += 'internal'; $usesInternal = $true }
      if ($nets.Count) { $L.Add('    networks: [' + ($nets -join ', ') + ']') }
    }
    $hc = Get-Prop $s 'healthcheck' $null
    if ($hc) {
      $L.Add('    healthcheck:')
      $L.Add('      test: [' + ((@($hc.test) | ForEach-Object { ConvertTo-YamlScalar ([string]$_) }) -join ', ') + ']')
      foreach ($k in @('interval', 'timeout', 'retries', 'start_period')) { $hv = Get-Prop $hc $k $null; if ($null -ne $hv) { $L.Add("      ${k}: $hv") } }
    }
    if (-not (Get-Prop $s 'privileged' $false)) { $L.Add('    security_opt: [no-new-privileges:true]') }
    $L.Add('    logging:'); $L.Add('      driver: json-file'); $L.Add("      options: { max-size: '10m', max-file: '3' }")
    $L.Add('    labels:')
    $L.Add("      org.traefik-proxy.app: $($Manifest.id)")
    $L.Add("      org.traefik-proxy.project: $Project")
    if (Get-Prop $s 'stateful' $false) { $L.Add('      org.traefik-proxy.stateful: "true"') }
  }
  if ($usesProxy -or $usesInternal) {
    $L.Add('networks:')
    if ($usesProxy) { $L.Add('  proxy:'); $L.Add("    name: $ProxyNetwork"); $L.Add('    external: true') }
    if ($usesInternal) { $L.Add('  internal: {}') }
  }
  if ($namedVolumes.Count) {
    $L.Add('volumes:')
    foreach ($v in $namedVolumes) { $L.Add("  ${v}:"); $L.Add("    name: ${Project}_$v") }
  }
  return ($L -join "`n") + "`n"
}

Export-ModuleMember -Function Test-AppManifest, Get-AppContainerName, Get-ActiveServices, New-PasswordValue, Get-AppFiles, Get-CatalogApps, Get-CatalogApp, Get-PlatformSupport, New-SecretValue, Resolve-TemplateValue, Resolve-AppValues,
  Get-AppIdentityKey, Resolve-CatalogEntry, Get-ApplicationId, Get-ManifestAvailability, Get-ServiceDeclaredLifecycle,
  ConvertTo-HostFolder, ConvertTo-EnvFileText, ConvertTo-AppCompose, New-AppReadme, Hide-SecretValues, Read-AppEnv, Get-AppsRegistryPath, Read-AppsRegistry,
  Save-AppsRegistry, Get-ComposeServiceImages, Get-AppUpdateDiff
