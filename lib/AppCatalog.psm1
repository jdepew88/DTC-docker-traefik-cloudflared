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
$script:Categories = @('monitoring', 'media', 'management', 'authentication', 'networking', 'tools', 'productivity')

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
  foreach ($d in @(Get-Prop $M 'docs' @())) { if ([string](Get-Prop $d 'url' '') -notmatch '^https://') { & $add 'documentation links must be https URLs' } }
  if (-not @(Get-Prop $M 'docs' @()).Count) { & $add 'at least one documentation link is required' }
  $platforms = Get-Prop $M 'platforms' $null
  if (-not $platforms) { & $add 'platforms is required' }
  else { foreach ($p in $platforms.PSObject.Properties) { if ($script:Platforms -notcontains $p.Name) { & $add "unknown platform '$($p.Name)'" } elseif ($p.Value -notin 'supported', 'untested', 'unsupported') { & $add "platform '$($p.Name)' must be supported, untested or unsupported" } } }
  if (-not [bool](Get-Prop $M 'installable' $false)) { if (-not [string](Get-Prop $M 'installNote' '')) { & $add 'a manifest that is not installable needs installNote' }; return $e.ToArray() }
  $services = Get-Prop $M 'services' $null
  if (-not $services -or -not @($services.PSObject.Properties).Count) { & $add 'services is required'; return $e.ToArray() }
  $inputs = @(Get-Prop $M 'inputs' @())
  $inputIds = @($inputs | ForEach-Object { [string]$_.id })
  foreach ($i in $inputs) {
    if ([string]$i.id -notmatch '^[a-zA-Z][a-zA-Z0-9]{0,40}$') { & $add "input id '$($i.id)' is invalid" }
    if ([string](Get-Prop $i 'type' '') -notin 'text', 'secret', 'generated', 'folder', 'timezone') { & $add "input '$($i.id)' has an unknown type" }
    if ((Get-Prop $i 'type' '') -eq 'generated' -and [int](Get-Prop $i 'bytes' 0) -lt 16) { & $add "generated input '$($i.id)' needs bytes >= 16" }
  }
  $primary = 0
  foreach ($sp in $services.PSObject.Properties) {
    $s = $sp.Value
    if ($sp.Name -notmatch $script:IdPattern) { & $add "service name '$($sp.Name)' is invalid" }
    if ([string](Get-Prop $s 'image' '') -notmatch $script:ImagePattern) { & $add "service '$($sp.Name)': image must be pinned by digest (name:tag@sha256:...)" }
    foreach ($p in @(Get-Prop $s 'ports' @())) {
      if ([int](Get-Prop $p 'container' 0) -lt 1 -or [int](Get-Prop $p 'container' 0) -gt 65535) { & $add "service '$($sp.Name)': invalid port" }
      if ([string](Get-Prop $p 'protocol' '') -notin 'http', 'https', 'tcp', 'udp') { & $add "service '$($sp.Name)': port protocol must be http, https, tcp or udp" }
      if ([bool](Get-Prop $p 'primary' $false)) { $primary++ }
    }
    foreach ($v in @(Get-Prop $s 'volumes' @())) {
      if ([string](Get-Prop $v 'name' '') -notmatch $script:IdPattern) { & $add "service '$($sp.Name)': volume name '$($v.name)' is invalid" }
      if ([string](Get-Prop $v 'target' '') -notmatch '^/[A-Za-z0-9._/-]*$') { & $add "service '$($sp.Name)': volume target must be an absolute container path" }
      if ([string](Get-Prop $v 'kind' 'volume') -notin 'volume', 'folder') { & $add "service '$($sp.Name)': volume kind must be volume or folder" }
      if ((Get-Prop $v 'kind' 'volume') -eq 'folder' -and $inputIds -notcontains [string](Get-Prop $v 'input' '')) { & $add "service '$($sp.Name)': folder volume '$($v.name)' needs an input" }
    }
    $envObj = Get-Prop $s 'environment' $null
    if ($envObj) { foreach ($ev in $envObj.PSObject.Properties) {
        if ($ev.Name -notmatch $script:EnvKeyPattern) { & $add "service '$($sp.Name)': environment key '$($ev.Name)' is invalid" }
        foreach ($tm in [regex]::Matches([string]$ev.Value, '\{\{\s*([a-zA-Z]+)(?::([a-zA-Z0-9]+))?\s*\}\}')) {
          $kind = $tm.Groups[1].Value; $ref = $tm.Groups[2].Value
          if ($kind -eq 'input' -and $inputIds -notcontains $ref) { & $add "service '$($sp.Name)': {{input:$ref}} has no input" }
          elseif ($kind -notin 'input', 'project', 'appUrl', 'timezone', 'webPort') { & $add "service '$($sp.Name)': unknown template variable {{$kind}}" }
        }
      } }
    if ((Get-Prop $s 'dockerSocket' $false) -and -not @(Get-Prop $M 'privileges' @() | Where-Object { $_.kind -eq 'docker-socket' }).Count) { & $add "service '$($sp.Name)' mounts the Docker socket but privileges does not declare docker-socket" }
  }
  if ($primary -ne 1) { & $add 'exactly one port must be marked primary (the web interface)' }
  $web = Get-Prop $M 'web' $null
  if (-not $web -or -not $services.PSObject.Properties[[string](Get-Prop $web 'service' '')]) { & $add 'web.service must name a service' }
  if ([string](Get-Prop (Get-Prop $M 'exposure' $null) 'default' '') -notin 'access', 'public', 'local') { & $add 'exposure.default must be access, public or local' }
  return $e.ToArray()
}

function Get-CatalogApps {
  param([Parameter(Mandatory = $true)][string]$CatalogDir)
  $dir = Join-Path $CatalogDir 'apps'
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
      $file = $_; $m = $null
      try { $m = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json } catch { [pscustomobject]@{ id = $file.BaseName; errors = @("invalid JSON: $($_.Exception.Message)"); manifest = $null; file = $file.Name }; return }
      $errs = @(Test-AppManifest $m)
      if ([string]$m.id -ne $file.BaseName) { $errs += "the file name must be <id>.json" }
      [pscustomobject]@{ id = [string]$m.id; errors = $errs; manifest = $m; file = $file.Name }
    })
}

function Get-CatalogApp([string]$CatalogDir, [string]$Id) {
  $a = @(Get-CatalogApps -CatalogDir $CatalogDir | Where-Object { $_.id -eq $Id })
  if (-not $a.Count) { throw "No catalog app '$Id'." }
  if (@($a[0].errors).Count) { throw "Catalog app '$Id' is invalid: $(@($a[0].errors) -join '; ')" }
  return $a[0].manifest
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

# Resolves {{input:x}}, {{project}}, {{appUrl}}, {{timezone}}, {{webPort}} in one string. Unknown variables throw.
function Resolve-TemplateValue([string]$Template, [hashtable]$Values) {
  return [regex]::Replace($Template, '\{\{\s*([a-zA-Z]+)(?::([a-zA-Z0-9]+))?\s*\}\}', {
      param($m)
      $kind = $m.Groups[1].Value; $ref = $m.Groups[2].Value
      $key = $(if ($kind -eq 'input') { "input:$ref" } else { $kind })
      if (-not $Values.ContainsKey($key)) { throw "Template variable {{$($m.Groups[1].Value)$(if ($ref) { ":$ref" })}} has no value." }
      return [string]$Values[$key]
    })
}

# Validates the user's choices and builds every value the templates need. Generated secrets are created here once and
# kept server-side with the plan. Returns Values (template map), Env (KEY -> value per service), Secrets (env keys whose
# values must never be shown), Folders (volume -> host path) and Errors.
function Resolve-AppValues {
  param([Parameter(Mandatory = $true)]$Manifest, [hashtable]$Inputs = @{}, [string]$Project, [string]$AppUrl = '', [string]$TimeZone = 'UTC', [hashtable]$Existing = @{})
  $errors = New-Object System.Collections.ArrayList
  $values = @{ project = $Project; appUrl = $AppUrl; timezone = $TimeZone }
  $secretInputs = @()
  foreach ($i in @(Get-Prop $Manifest 'inputs' @())) {
    $id = [string]$i.id; $type = [string]$i.type
    $v = $(if ($Inputs.ContainsKey($id)) { [string]$Inputs[$id] } else { '' })
    if ($type -eq 'generated') { $v = $(if ($Existing.ContainsKey("input:$id")) { $Existing["input:$id"] } else { New-SecretValue ([int]$i.bytes) }); $secretInputs += $id }
    elseif ($type -eq 'secret') { $secretInputs += $id; if (-not $v -and $Existing.ContainsKey("input:$id")) { $v = $Existing["input:$id"] } }
    elseif ($type -eq 'timezone') { if (-not $v) { $v = $TimeZone }; if ($v -notmatch '^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$') { $null = $errors.Add("$($i.label): not a time zone name (e.g. Europe/Berlin).") } }
    elseif ($type -eq 'folder') {
      if ($v) { try { $v = ConvertTo-HostFolder $v } catch { $null = $errors.Add("$($i.label): $($_.Exception.Message)") } }
    } elseif (-not $v -and (Get-Prop $i 'default' '')) { $v = [string]$i.default }
    if ([bool](Get-Prop $i 'required' $false) -and -not $v) { $null = $errors.Add("$($i.label) is required.") }
    $pattern = [string](Get-Prop $i 'pattern' '')
    if ($v -and $pattern -and $type -in 'text', 'secret' -and $v -notmatch $pattern) { $null = $errors.Add("$($i.label) has an invalid format.") }
    if ($v -match "[\r\n]") { $null = $errors.Add("$($i.label) must be a single line.") }
    $values["input:$id"] = $v
  }
  $envByService = [ordered]@{}; $secretKeys = New-Object System.Collections.ArrayList
  $webPort = 0
  foreach ($sp in (Get-Prop $Manifest 'services').PSObject.Properties) {
    foreach ($p in @(Get-Prop $sp.Value 'ports' @())) { if ([bool](Get-Prop $p 'primary' $false)) { $webPort = [int]$p.container } }
  }
  $values['webPort'] = $webPort
  foreach ($sp in (Get-Prop $Manifest 'services').PSObject.Properties) {
    $env = [ordered]@{}
    $envObj = Get-Prop $sp.Value 'environment' $null
    if ($envObj) { foreach ($ev in $envObj.PSObject.Properties) {
        try { $env[$ev.Name] = Resolve-TemplateValue ([string]$ev.Value) $values } catch { $null = $errors.Add($_.Exception.Message) }
        foreach ($sid in $secretInputs) { if ([string]$ev.Value -match "\{\{\s*input:$sid\s*\}\}") { if (-not $secretKeys.Contains($ev.Name)) { $null = $secretKeys.Add($ev.Name) } } }
      } }
    $envByService[$sp.Name] = $env
  }
  return [pscustomobject]@{ Values = $values; Env = $envByService; Secrets = @($secretKeys); Errors = $errors.ToArray() }
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

# Pure: the Compose project of one app. $Options: ProxyNetwork, LocalPort (0 = none), Folders (volume name -> host path).
function ConvertTo-AppCompose {
  param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$Project, [Parameter(Mandatory = $true)]$Resolved, [Parameter(Mandatory = $true)][string]$ProxyNetwork, [int]$LocalPort = 0)
  $services = @((Get-Prop $Manifest 'services').PSObject.Properties)
  $single = $services.Count -eq 1
  $web = [string](Get-Prop (Get-Prop $Manifest 'web') 'service' '')
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("# Generated by the Deployment Manager from catalog app '$($Manifest.id)' ($($Manifest.name)).")
  $L.Add('# An ordinary Compose project: manage it with docker compose in this folder, with or without the manager.')
  $L.Add('# Settings and secrets are in .env next to this file.')
  $L.Add("name: $Project")
  $L.Add('services:')
  $namedVolumes = New-Object System.Collections.ArrayList
  foreach ($sp in $services) {
    $s = $sp.Value
    $cname = $(if ($single) { $Project } else { "$Project-$($sp.Name)" })
    $L.Add("  $($sp.Name):")
    $L.Add("    image: $($s.image)")
    $L.Add("    container_name: $cname")
    $L.Add('    pull_policy: missing')
    $L.Add("    restart: $(Get-Prop $s 'restart' 'unless-stopped')")
    $cmd = @(Get-Prop $s 'command' @())
    if ($cmd.Count) { $L.Add('    command: [' + (($cmd | ForEach-Object { ConvertTo-YamlScalar ([string]$_) }) -join ', ') + ']') }
    $env = $Resolved.Env[$sp.Name]
    if ($env -and $env.Count) {
      $L.Add('    environment:')
      foreach ($k in $env.Keys) { $L.Add("      ${k}: `${$k}") }
    }
    $vols = @(Get-Prop $s 'volumes' @())
    if ($vols.Count -or (Get-Prop $s 'dockerSocket' $false)) {
      $L.Add('    volumes:')
      foreach ($v in $vols) {
        $ro = [bool](Get-Prop $v 'readOnly' $false)
        if ((Get-Prop $v 'kind' 'volume') -eq 'folder') {
          $src = [string]$Resolved.Values["input:$($v.input)"]
          if (-not $src) { continue }
          $L.Add('      - type: bind'); $L.Add("        source: $(ConvertTo-YamlScalar $src)"); $L.Add("        target: $($v.target)")
          if ($ro) { $L.Add('        read_only: true') }
        } else {
          $L.Add("      - $($v.name):$($v.target)$(if ($ro) { ':ro' })")
          if (-not $namedVolumes.Contains($v.name)) { $null = $namedVolumes.Add($v.name) }
        }
      }
      if (Get-Prop $s 'dockerSocket' $false) { $L.Add('      - /var/run/docker.sock:/var/run/docker.sock') }
    }
    if ($LocalPort -gt 0 -and $sp.Name -eq $web) {
      $wp = [int](@(Get-Prop $s 'ports' @() | Where-Object { Get-Prop $_ 'primary' $false })[0].container)
      $L.Add('    ports:'); $L.Add("      - '127.0.0.1:${LocalPort}:$wp'")
    }
    $nets = @('proxy'); if (-not $single) { $nets += 'internal' }
    if ($sp.Name -ne $web -and -not $single) { $nets = @('internal') }   # only the web front end joins the shared network
    $L.Add('    networks: [' + ($nets -join ', ') + ']')
    $hc = Get-Prop $s 'healthcheck' $null
    if ($hc) {
      $L.Add('    healthcheck:')
      $L.Add('      test: [' + ((@($hc.test) | ForEach-Object { ConvertTo-YamlScalar ([string]$_) }) -join ', ') + ']')
      foreach ($k in @('interval', 'timeout', 'retries', 'start_period')) { $hv = Get-Prop $hc $k $null; if ($null -ne $hv) { $L.Add("      ${k}: $hv") } }
    }
    $L.Add('    security_opt: [no-new-privileges:true]')
    $L.Add('    logging:'); $L.Add('      driver: json-file'); $L.Add("      options: { max-size: '10m', max-file: '3' }")
    $L.Add('    labels:')
    $L.Add("      org.traefik-proxy.app: $($Manifest.id)")
    $L.Add("      org.traefik-proxy.project: $Project")
  }
  $L.Add('networks:')
  $L.Add('  proxy:'); $L.Add("    name: $ProxyNetwork"); $L.Add('    external: true')
  if (-not $single) { $L.Add('  internal: {}') }
  if ($namedVolumes.Count) {
    $L.Add('volumes:')
    foreach ($v in $namedVolumes) { $L.Add("  ${v}:"); $L.Add("    name: ${Project}_$v") }
  }
  return ($L -join "`n") + "`n"
}

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

Export-ModuleMember -Function Test-AppManifest, Get-CatalogApps, Get-CatalogApp, Get-PlatformSupport, New-SecretValue, Resolve-TemplateValue, Resolve-AppValues,
  ConvertTo-HostFolder, ConvertTo-EnvFileText, ConvertTo-AppCompose, New-AppReadme, Hide-SecretValues, Read-AppEnv, Get-AppsRegistryPath, Read-AppsRegistry,
  Save-AppsRegistry, Get-ComposeServiceImages, Get-AppUpdateDiff
