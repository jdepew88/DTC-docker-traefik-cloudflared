#requires -version 5.1
# Universal application sources: a pasted link (Docker Hub, GitHub, a Compose file, an Unraid XML template, an
# awesome-selfhosted entry or a plain image reference) becomes one normalized application manifest: the same DTC
# manifest (schema 1) the curated catalog uses, with source.type 'imported' plus provenance, evidence, unresolved
# questions and verification status. Nothing here runs a container or changes Docker: discovery and interpretation
# only. Compose files are parsed by `docker compose config` (no interpolation, no env files, no path resolution) in an
# empty temporary folder, which validates them without creating anything.
#
# Every fetched document is untrusted (lib\SafeFetch.psm1 fetches it). Values from it are data: they are never run,
# and anything security-relevant becomes a finding in lib\ProvisionPolicy.psm1 that the user must review.
Set-StrictMode -Version 2.0

$script:IdPattern = '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$'
$script:ComposeNames = @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml')
$script:SecretName = '(PASSWORD|PASSWD|PASS$|SECRET|TOKEN|API_?KEY|PRIVATE_?KEY|_KEY$|SALT|JWT)'
$script:RoleByImage = @(
  @{ Pattern = '(^|/)(postgres|postgis|timescaledb|mysql|mariadb|mongo|mongodb-community-server|cockroach|percona|pgvecto-rs)([:@]|$)|immich-app/postgres'; Role = 'database' }
  @{ Pattern = '(^|/)(redis|valkey|keydb|memcached|dragonfly)([:@]|$)'; Role = 'cache' }
  @{ Pattern = '(^|/)(rabbitmq|nats|eclipse-mosquitto|mosquitto|kafka)([:@]|$)'; Role = 'messaging' }
)
# Rough planning estimates per role (MB), shown as estimates, never as measurements.
$script:RoleMemory = @{ app = 512; database = 512; cache = 128; messaging = 128; worker = 384; support = 128; init = 64; migration = 128; maintenance = 64 }
$script:Categories = @('monitoring', 'media', 'management', 'authentication', 'networking', 'tools', 'productivity', 'communication', 'photos', 'dashboard', 'updates')

function Get-AsProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# Like Get-AsProp, but a one-element array stays an array (function output would otherwise unroll it to a scalar).
function Get-AsRaw($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return ,$p.Value }
  return $null
}

function Get-AsSha256([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant()) } finally { $sha.Dispose() }
}

# Pure: a valid manifest id from any name ('Uptime Kuma' -> 'uptime-kuma').
function ConvertTo-AppId([string]$Name) {
  $s = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($s.Length -gt 32) { $s = $s.Substring(0, 32).Trim('-') }
  if (-not $s) { $s = 'app' }
  return $s
}

# Pure: an input id from an environment variable name ('DB_PASSWORD' -> 'dbPassword').
function ConvertTo-InputId([string]$Name) {
  $parts = @(($Name -replace '[^A-Za-z0-9]+', ' ').Trim().ToLowerInvariant() -split '\s+' | Where-Object { $_ })
  if (-not $parts.Count) { return 'value' }
  $id = $parts[0] + (-join ($parts | Select-Object -Skip 1 | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }))
  if ($id -notmatch '^[a-z]') { $id = 'v' + $id }
  if ($id.Length -gt 40) { $id = $id.Substring(0, 40) }
  return $id
}

# --- Link classification ------------------------------------------------------------------------------------------------

# Pure: what a pasted text refers to. Kinds: dockerhub, image, github-repo, github-file, unraid-xml, unraid-ca,
# directory (awesome-selfhosted-data), unknown. Returns { Kind; Owner; Repo; Ref; Path; Image; Url; Note }.
function Get-AppSourceKind([string]$Text) {
  $t = ([string]$Text).Trim()
  $r = [ordered]@{ Kind = 'unknown'; Owner = ''; Repo = ''; Ref = ''; Path = ''; Image = ''; Url = $t; Note = '' }
  if ($t -match '^https://hub\.docker\.com/(?:r/|repository/docker/)([a-z0-9][a-z0-9._-]*)/([a-z0-9][a-z0-9._-]*)/?(?:[?#].*|/tags.*|/general.*)?$') { $r.Kind = 'dockerhub'; $r.Owner = $Matches[1]; $r.Repo = $Matches[2]; return [pscustomobject]$r }
  if ($t -match '^https://hub\.docker\.com/_/([a-z0-9][a-z0-9._-]*)/?(?:[?#].*|/tags.*)?$') { $r.Kind = 'dockerhub'; $r.Owner = 'library'; $r.Repo = $Matches[1]; return [pscustomobject]$r }
  if ($t -match '^https://github\.com/awesome-selfhosted/awesome-selfhosted-data/blob/([^/]+)/(software/[A-Za-z0-9._-]+\.ya?ml)$') { $r.Kind = 'directory'; $r.Owner = 'awesome-selfhosted'; $r.Repo = 'awesome-selfhosted-data'; $r.Ref = $Matches[1]; $r.Path = $Matches[2]; return [pscustomobject]$r }
  if ($t -match '^https://raw\.githubusercontent\.com/awesome-selfhosted/awesome-selfhosted-data/([^/]+)/(software/[A-Za-z0-9._-]+\.ya?ml)$') { $r.Kind = 'directory'; $r.Owner = 'awesome-selfhosted'; $r.Repo = 'awesome-selfhosted-data'; $r.Ref = $Matches[1]; $r.Path = $Matches[2]; return [pscustomobject]$r }
  if ($t -match '^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+?)(?:\.git)?/blob/([^/]+)/(.+)$') { $r.Owner = $Matches[1]; $r.Repo = $Matches[2]; $r.Ref = $Matches[3]; $r.Path = $Matches[4]; $r.Kind = $(if ($r.Path -match '\.xml$') { 'unraid-xml' } else { 'github-file' }); return [pscustomobject]$r }
  if ($t -match '^https://raw\.githubusercontent\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/([^/]+)/(.+)$') { $r.Owner = $Matches[1]; $r.Repo = $Matches[2]; $r.Ref = $Matches[3]; $r.Path = $Matches[4]; $r.Kind = $(if ($r.Path -match '\.xml$') { 'unraid-xml' } else { 'github-file' }); return [pscustomobject]$r }
  if ($t -match '^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+?)(?:\.git)?/?(?:tree/([^/]+)(?:/(.*))?)?(?:[?#].*)?$') { $r.Kind = 'github-repo'; $r.Owner = $Matches[1]; $r.Repo = $Matches[2]; if ($Matches.Count -gt 3 -and $Matches[3]) { $r.Ref = $Matches[3] }; if ($Matches.Count -gt 4 -and $Matches[4]) { $r.Path = $Matches[4].Trim('/') }; return [pscustomobject]$r }
  if ($t -match '^https://ca\.unraid\.net/') { $r.Kind = 'unraid-ca'; $r.Note = 'Community Applications pages are not parsed. Open the app in Community Applications, copy its template link (TemplateURL, a raw .xml file on GitHub) and paste that.'; return [pscustomobject]$r }
  if ($t -match '^https?://') { return [pscustomobject]$r }
  # A plain image reference: [registry/]namespace/name[:tag][@sha256:digest]
  if ($t -match '^(?:(?:[a-z0-9][a-z0-9.-]*\.[a-z]{2,}|localhost)(?::\d+)?/)?[a-z0-9]+(?:[._/-][a-z0-9]+)*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?(?:@sha256:[0-9a-f]{64})?$') { $r.Kind = 'image'; $r.Image = $t; return [pscustomobject]$r }
  return [pscustomobject]$r
}

# --- Image references and registries --------------------------------------------------------------------------------

# Pure: { Registry; Repository; Tag; Digest; Short } of an image reference (docker.io and library/ are made explicit).
function ConvertTo-ImageReference([string]$Image) {
  $s = $Image.Trim()
  $digest = ''
  if ($s -match '^(.*)@(sha256:[0-9a-f]{64})$') { $s = $Matches[1]; $digest = $Matches[2] }
  $tag = ''
  $lastSlash = $s.LastIndexOf('/')
  $colon = $s.LastIndexOf(':')
  if ($colon -gt $lastSlash) { $tag = $s.Substring($colon + 1); $s = $s.Substring(0, $colon) }
  $registry = 'docker.io'
  $first = ($s -split '/')[0]
  if ($s.Contains('/') -and ($first.Contains('.') -or $first.Contains(':') -or $first -eq 'localhost')) { $registry = $first; $s = $s.Substring($first.Length + 1) }
  if ($registry -eq 'docker.io' -and -not $s.Contains('/')) { $s = "library/$s" }
  if (-not $tag -and -not $digest) { $tag = 'latest' }
  $short = $(if ($registry -eq 'docker.io') { $s -replace '^library/', '' } else { "$registry/$s" })
  return [pscustomobject]@{ Registry = $registry.ToLowerInvariant(); Repository = $s.ToLowerInvariant(); Tag = $tag; Digest = $digest; Short = $short.ToLowerInvariant() }
}

function Get-RegistryApiHost([string]$Registry) { if ($Registry -eq 'docker.io') { return 'registry-1.docker.io' }; return $Registry }

# Anonymous pull token for one repository (Docker Hub, GHCR, Quay, lscr.io and other registries using the standard
# bearer challenge). Returns '' when the registry needs no token.
function Get-RegistryToken([string]$Registry, [string]$Repository) {
  if ($Registry -eq 'docker.io') { $realm = 'https://auth.docker.io/token'; $service = 'registry.docker.io' }
  else {
    $probe = Invoke-SafeFetch -Url "https://$(Get-RegistryApiHost $Registry)/v2/" -MaxBytes 64KB
    if ($probe.Status -ne 401) { return '' }
    $wa = [string](Get-AsProp $probe.Headers 'WWW-Authenticate' (Get-AsProp $probe.Headers 'Www-Authenticate' ''))
    if ($wa -notmatch 'realm="([^"]+)"') { throw "$Registry did not say how to authenticate." }
    $realm = $Matches[1]
    $service = $(if ($wa -match 'service="([^"]+)"') { $Matches[1] } else { '' })
  }
  $u = "$realm`?scope=repository:$($Repository):pull$(if ($service) { "&service=$([Uri]::EscapeDataString($service))" })"
  $t = Invoke-SafeJson -Url $u -MaxBytes 64KB
  $tok = [string](Get-AsProp $t 'token' (Get-AsProp $t 'access_token' ''))
  if (-not $tok) { throw "$Registry returned no pull token (the image may be private)." }
  return $tok
}

$script:ManifestAccept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# The digest a tag points to now, the platforms it is published for and (for linux/amd64, or the only platform) the
# image configuration: exposed ports, declared volumes, user, labels and whether it has a health check. Read-only.
function Get-RegistryImageFacts([string]$Image) {
  $ref = ConvertTo-ImageReference $Image
  $apiHost = Get-RegistryApiHost $ref.Registry
  $tok = Get-RegistryToken $ref.Registry $ref.Repository
  $h = @{ Accept = $script:ManifestAccept }
  if ($tok) { $h['Authorization'] = "Bearer $tok" }
  $sel = $(if ($ref.Digest) { $ref.Digest } else { $ref.Tag })
  $r = Invoke-SafeFetch -Url "https://$apiHost/v2/$($ref.Repository)/manifests/$sel" -Headers $h -MaxBytes 1MB
  if ($r.Status -eq 404) { throw "$($ref.Short):$($ref.Tag) does not exist in $($ref.Registry)." }
  if ($r.Status -in 401, 403) { throw "$($ref.Short) is private or needs a login; only public images can be imported." }
  if ($r.Status -ge 400) { throw "$($ref.Registry) answered HTTP $($r.Status) for $($ref.Short)." }
  $digest = [string](Get-AsProp $r.Headers 'Docker-Content-Digest' '')
  if (-not $digest) { $digest = 'sha256:' + (Get-AsSha256 $r.Text) }
  $doc = $r.Text | ConvertFrom-Json
  $platforms = @(); $manifest = $doc
  $mediaType = [string](Get-AsProp $doc 'mediaType' '')
  $list = @(Get-AsProp $doc 'manifests' @())
  if ($list.Count -and $mediaType -notmatch 'manifest\.v') {
    $platforms = @($list | Where-Object { (Get-AsProp $_ 'platform' $null) -and [string]$_.platform.os -ne 'unknown' } | ForEach-Object { "$($_.platform.os)/$($_.platform.architecture)$(if (Get-AsProp $_.platform 'variant' '') { "/$($_.platform.variant)" })" } | Select-Object -Unique)
    $pick = @($list | Where-Object { (Get-AsProp $_ 'platform' $null) -and $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' })
    if (-not $pick.Count) { $pick = @($list | Where-Object { (Get-AsProp $_ 'platform' $null) -and $_.platform.os -ne 'unknown' }) }
    $manifest = $null
    if ($pick.Count) {
      $m2 = Invoke-SafeFetch -Url "https://$apiHost/v2/$($ref.Repository)/manifests/$($pick[0].digest)" -Headers $h -MaxBytes 1MB
      if ($m2.Status -lt 400) { $manifest = $m2.Text | ConvertFrom-Json }
    }
  }
  $config = $null
  $cd = [string](Get-AsProp (Get-AsProp $manifest 'config' $null) 'digest' '')
  if ($cd) {
    # The configuration is optional facts (ports, volumes, labels); the digest above is what pins the image.
    try { $c = Invoke-SafeFetch -Url "https://$apiHost/v2/$($ref.Repository)/blobs/$cd" -Headers $h -MaxBytes 1MB; if ($c.Status -lt 400) { $config = $c.Text | ConvertFrom-Json } } catch { $config = $null }
    if ($config -and -not $platforms.Count) { $platforms = @("$(Get-AsProp $config 'os' 'linux')/$(Get-AsProp $config 'architecture' 'amd64')") }
  }
  $cc = Get-AsProp $config 'config' $null
  $exposed = @(); $volumes = @(); $labels = [ordered]@{}
  $ep = Get-AsProp $cc 'ExposedPorts' $null
  if ($ep) { $exposed = @($ep.PSObject.Properties | ForEach-Object { $_.Name }) }
  $vo = Get-AsProp $cc 'Volumes' $null
  if ($vo) { $volumes = @($vo.PSObject.Properties | ForEach-Object { $_.Name }) }
  $lb = Get-AsProp $cc 'Labels' $null
  if ($lb) { foreach ($p in $lb.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value } }
  return [pscustomobject]@{ Image = $ref.Short; Tag = $ref.Tag; Digest = $digest; Pinned = "$($ref.Short):$($ref.Tag)@$digest"; Platforms = $platforms; ExposedPorts = $exposed; Volumes = $volumes
    User = [string](Get-AsProp $cc 'User' ''); Labels = $labels; HasHealthcheck = [bool](Get-AsProp $cc 'Healthcheck' $null); Registry = $ref.Registry }
}

# --- Compose -------------------------------------------------------------------------------------------------------------

# Parses Compose text with `docker compose config` in an empty temporary folder: no interpolation, no env files, no
# path resolution, nothing created. Directives that would read other files on this PC are refused first.
# $DockerInvoker (tests) is a scriptblock that receives the docker arguments and returns { ExitCode; Output }.
function ConvertFrom-ComposeText {
  param([Parameter(Mandatory = $true)][string]$Text, $DockerInvoker = $null)
  if ($Text.Length -gt 256KB) { throw 'The Compose file is larger than 256 KB.' }
  if ($Text -match '(?m)^include\s*:') { throw 'This Compose file includes other files (include:), which are not imported. Paste the main file of a self-contained stack.' }
  if ($Text -match '(?m)^\s+extends\s*:') { throw 'This Compose file extends other definitions (extends:), which are not imported.' }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dm-import-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    $f = Join-Path $tmp 'compose.yaml'
    [IO.File]::WriteAllText($f, $Text, (New-Object Text.UTF8Encoding($false)))
    $args2 = @('compose', '--project-directory', $tmp, '-f', $f, '-p', 'import-preview', 'config', '--format', 'json', '--no-interpolate', '--no-path-resolution', '--no-env-resolution')
    $r = $(if ($DockerInvoker) { & $DockerInvoker $args2 } else { $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $o = & docker @args2 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($o) } } finally { $ErrorActionPreference = $saved } })
    if ($r.ExitCode -ne 0) { throw ('The Compose file is not valid: ' + ((@($r.Output) | Select-Object -First 3) -join ' ').Replace($tmp, '.')) }
    $json = (@($r.Output) | Where-Object { $_ -notmatch '^\s*(time=|level=|WARN)' }) -join "`n"
    return ($json | ConvertFrom-Json)
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Pure: KEY=value pairs of an .env example file (comments ignored).
function ConvertFrom-EnvExample([string]$Text) {
  $map = [ordered]@{}
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
      $v = $Matches[2]
      if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { $v = $Matches[1] } elseif ($v -match '^(.*?)\s+#') { $v = $Matches[1] }
      $map[$Matches[1]] = $v
    }
  }
  return $map
}

# Pure: the variables ${A}, ${A:-x}, ${A-x}, ${A:?msg}, $A referenced in a string, with their inline defaults.
function Get-ComposeVariables([string]$Value) {
  $out = @()
  foreach ($m in [regex]::Matches($Value, '(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?])([^}]*))?\}|(?<!\$)\$([A-Za-z_][A-Za-z0-9_]*)')) {
    if ($m.Groups[1].Success) { $out += [pscustomobject]@{ Text = $m.Value; Name = $m.Groups[1].Value; Default = $(if ($m.Groups[2].Success -and $m.Groups[2].Value -like '*-') { $m.Groups[3].Value } else { $null }) } }
    else { $out += [pscustomobject]@{ Text = $m.Value; Name = $m.Groups[4].Value; Default = $null } }
  }
  return $out
}

# Pure: a value with every variable replaced by its default (or the .env example value); $null when one has neither.
function Resolve-ComposeDefaults([string]$Value, $EnvDefaults) {
  $v = $Value
  foreach ($x in (Get-ComposeVariables $Value)) {
    $d = $(if ($EnvDefaults -and $EnvDefaults.Contains($x.Name) -and [string]$EnvDefaults[$x.Name]) { [string]$EnvDefaults[$x.Name] } elseif ($null -ne $x.Default) { $x.Default } else { $null })
    if ($null -eq $d) { return $null }
    $v = $v.Replace($x.Text, $d)
  }
  return $v.Replace('$$', '$')
}

function Get-ImageRole([string]$Image) {
  foreach ($r in $script:RoleByImage) { if ($Image.ToLowerInvariant() -match $r.Pattern) { return $r.Role } }
  return ''
}

# Pure: a shell-like split of a Compose string command (quotes kept together; no shell is involved).
function Split-CommandLine([string]$Text) {
  $out = @(); $cur = ''; $q = ''; $has = $false
  foreach ($ch in $Text.ToCharArray()) {
    if ($q) { if ($ch -eq $q) { $q = '' } else { $cur += $ch } }
    elseif ($ch -eq '"' -or $ch -eq "'") { $q = $ch; $has = $true }
    elseif ([char]::IsWhiteSpace($ch)) { if ($cur -or $has) { $out += $cur; $cur = ''; $has = $false } }
    else { $cur += $ch }
  }
  if ($cur -or $has) { $out += $cur }
  return ,$out
}

# Pure: one normalized draft from a parsed Compose model (ConvertFrom-ComposeText) and the .env example defaults.
# Returns { Services; Inputs; Privileges; Web; Unresolved; Evidence; Unsupported; Notes; Hardware }. Images are not
# pinned yet (Complete-ImportedImages does that against the registries).
function ConvertFrom-ComposeModel {
  param([Parameter(Mandatory = $true)]$Model, $EnvDefaults = $null, [string]$Origin = 'Compose file')
  if (-not $EnvDefaults) { $EnvDefaults = [ordered]@{} }
  $services = [ordered]@{}; $inputs = New-Object System.Collections.ArrayList; $inputIds = @{}
  $privileges = New-Object System.Collections.ArrayList; $unresolved = New-Object System.Collections.ArrayList
  $evidence = New-Object System.Collections.ArrayList; $unsupported = New-Object System.Collections.ArrayList; $notes = New-Object System.Collections.ArrayList
  $hardware = [ordered]@{ gpu = $false; devices = @(); hostNetwork = $false }
  $addPriv = { param($kind, $why) if (-not @($privileges | Where-Object { $_.kind -eq $kind }).Count) { $null = $privileges.Add([ordered]@{ kind = $kind; reason = $why }) } }
  $ev = { param($field, $value, $how) $null = $evidence.Add([ordered]@{ field = $field; value = [string]$value; source = $Origin; how = $how }) }
  $unres = { param($field, $why) $null = $unresolved.Add([ordered]@{ field = $field; reason = $why }) }
  $usedVolumeNames = @{}
  $msvc = Get-AsProp $Model 'services' $null
  if (-not $msvc -or -not @($msvc.PSObject.Properties).Count) { throw 'The Compose file defines no services.' }
  # Variables and literal secrets become inputs shared by every service that uses them (one database password for
  # the database and the application).
  $toInput = {
    param([string]$Var, $Default, [string]$Svc)
    $id = ConvertTo-InputId $Var
    if (-not $inputIds.ContainsKey($id)) {
      $secret = $Var.ToUpperInvariant() -match $script:SecretName
      $d = $(if ($EnvDefaults.Contains($Var) -and [string]$EnvDefaults[$Var]) { [string]$EnvDefaults[$Var] } elseif ($null -ne $Default) { [string]$Default } else { '' })
      if ($secret) { $i = [ordered]@{ id = $id; type = 'generated'; bytes = 24; label = $Var; env = $Var } ; & $ev "inputs.$id" '(generated)' "secret variable ${Var}: a new random value is generated for this installation; example values are never used" }
      elseif ($d) { $i = [ordered]@{ id = $id; type = 'text'; label = $Var; default = $d; env = $Var }; & $ev "inputs.$id" $d "default of $Var" }
      else { $i = [ordered]@{ id = $id; type = 'text'; label = $Var; required = $true; env = $Var }; & $unres "inputs.$id" "$Var has no default; the installation asks for it." }
      $null = $inputs.Add($i); $inputIds[$id] = $i
    }
    return $id
  }
  foreach ($sp in $msvc.PSObject.Properties) {
    $n = ConvertTo-AppId $sp.Name; $cs = $sp.Value
    $s = [ordered]@{}
    $img = [string](Get-AsProp $cs 'image' '')
    if (Get-AsProp $cs 'build' $null) {
      if (-not $img) { $null = $unsupported.Add([ordered]@{ field = "services.$n"; reason = "Service '$($sp.Name)' is built from source code (build:), which this importer does not do. Use a published image instead." }); continue }
      & $ev "services.$n.image" $img 'build: ignored, the published image is used'
    }
    if (-not $img) { $null = $unsupported.Add([ordered]@{ field = "services.$n"; reason = "Service '$($sp.Name)' has no image." }); continue }
    $resolvedImg = Resolve-ComposeDefaults $img $EnvDefaults
    if ($null -eq $resolvedImg) { & $unres "services.$n.image" "The image '$img' depends on a variable without a default."; $resolvedImg = $img }
    elseif ($resolvedImg -ne $img) { & $ev "services.$n.image" $resolvedImg "variables in '$img' resolved from their defaults" }
    $s.image = $resolvedImg
    $role = Get-ImageRole $resolvedImg
    $restart = [string](Get-AsProp $cs 'restart' '')
    if ($restart) { $s.restart = $restart }
    if ($role) { $s.role = $role; & $ev "services.$n.role" $role 'recognized from the image' }
    # Environment: list or map; variables become inputs; hard-coded secret-looking values become generated inputs.
    $envIn = Get-AsRaw $cs 'environment'
    $pairs = [ordered]@{}
    if ($envIn -is [string] -or $envIn -is [System.Array] -or $envIn -is [System.Collections.IList]) { foreach ($e in @($envIn)) { $kv = [string]$e; $i = $kv.IndexOf('='); if ($i -gt 0) { $pairs[$kv.Substring(0, $i)] = $kv.Substring($i + 1) } else { $pairs[$kv] = $null } } }
    elseif ($envIn) { foreach ($p in $envIn.PSObject.Properties) { $pairs[$p.Name] = $(if ($null -eq $p.Value) { $null } else { [string]$p.Value }) } }
    $env = [ordered]@{}
    foreach ($k in $pairs.Keys) {
      if ($k -notmatch '^[A-Z][A-Z0-9_]{0,63}$') { & $unres "services.$n.environment.$k" "The variable name '$k' is not supported (use upper-case names); it was left out."; continue }
      $v = $pairs[$k]
      if ($null -eq $v) { $v = '${' + $k + '}' }
      if ($v.Contains('{{')) { & $unres "services.$n.environment.$k" 'The value contains {{ }}, which the manager reserves for its own templates; it was left out.'; continue }
      foreach ($x in (Get-ComposeVariables $v)) { $id = & $toInput $x.Name $x.Default $n; $v = $v.Replace($x.Text, "{{input:$id}}") }
      $v = $v.Replace('$$', '$')
      if ($k -match $script:SecretName -and $v -notmatch '\{\{input:' -and $v.Length -ge 3 -and $v -notmatch '^(true|false|0|1|none|null)$' -and $v -notmatch '^/run/secrets/' -and $k -notmatch '_FILE$') {
        # A literal password in the example: replaced by a generated secret everywhere the same literal appears.
        $id = ConvertTo-InputId ("$k")
        if (-not $inputIds.ContainsKey($id)) { $i = [ordered]@{ id = $id; type = 'generated'; bytes = 24; label = $k; env = $k; replaces = $v }; $null = $inputs.Add($i); $inputIds[$id] = $i; & $ev "inputs.$id" '(generated)' "the example value of $k is replaced by a random secret" }
        $v = "{{input:$id}}"
      }
      $env[$k] = $v
    }
    if ($env.Count) { $s.environment = $env }
    # Ports: container side only; nothing but the web port is ever published (on 127.0.0.1).
    $ports = @()
    foreach ($p in @(Get-AsProp $cs 'ports' @())) {
      $target = [int](Get-AsProp $p 'target' 0)
      if ($target -lt 1) { continue }
      $proto = [string](Get-AsProp $p 'protocol' 'tcp')
      $ports += [ordered]@{ container = $target; protocol = $(if ($proto -eq 'udp') { 'udp' } else { 'tcp' }); published = [string](Get-AsProp $p 'published' '') }
    }
    foreach ($x in @(Get-AsProp $cs 'expose' @())) { $t = 0; if ([int]::TryParse(([string]$x -replace '/.*$', ''), [ref]$t) -and $t -gt 0 -and -not @($ports | Where-Object { $_.container -eq $t }).Count) { $ports += [ordered]@{ container = $t; protocol = 'tcp'; published = '' } } }
    $s.ports = $ports
    # Storage: named volumes stay named volumes; project-relative bind mounts become named volumes (portable, owned by
    # the project); other host folders become a named volume the user may replace with a folder of their choice.
    $vols = @()
    foreach ($v in @(Get-AsProp $cs 'volumes' @())) {
      $type = [string](Get-AsProp $v 'type' 'volume'); $src = [string](Get-AsProp $v 'source' ''); $tgt = [string](Get-AsProp $v 'target' '')
      if ($tgt -notmatch '^/[A-Za-z0-9._/-]*$') { & $unres "services.$n.volumes" "The container path '$tgt' is not supported."; continue }
      $ro = [bool](Get-AsProp $v 'read_only' $false)
      if ($type -eq 'tmpfs') { $vols += [ordered]@{ name = (ConvertTo-AppId ("tmp-" + ($tgt -replace '[^a-z0-9]+', '-'))); kind = 'tmpfs'; target = $tgt }; continue }
      if ($type -eq 'bind' -and $src -match '^/var/run/docker\.sock$|^/run/docker\.sock$|docker\.sock$') { $s.dockerSocket = $true; if ($ro) { $s.dockerSocketReadOnly = $true }; & $addPriv 'docker-socket' "Service '$n' mounts the Docker socket ($(if ($ro) { 'read-only' } else { 'read-write' }))."; continue }
      $base = $(if ($type -eq 'volume' -and $src) { $src } elseif ($src) { ($src -replace '^[./\\]+', '' -replace '[\\/]+$', '') } else { "$n-$(($tgt -replace '[^A-Za-z0-9]+', '-').Trim('-'))" })
      $name = ConvertTo-AppId $base
      if ($name -eq 'app' -and $base -ne 'app') { $name = ConvertTo-AppId "$n-data" }
      $k = 2; $orig = $name
      while ($usedVolumeNames.ContainsKey($name) -and $usedVolumeNames[$name] -ne "$type|$src") { $name = ConvertTo-AppId "$orig-$k"; $k++ }
      $usedVolumeNames[$name] = "$type|$src"
      $vol = [ordered]@{ name = $name; kind = 'volume'; target = $tgt }
      if ($ro) { $vol.readOnly = $true }
      if ($type -eq 'bind') {
        if ($src -match '^(\.|\.\.)?[/\\]?[A-Za-z0-9._-]' -and $src -notmatch '^/' -and $src -notmatch '^[A-Za-z]:') { & $ev "services.$n.volumes.$name" $src "project folder '$src' kept as the named volume '$name'" }
        elseif ($src -match '^/(dev|proc|sys|etc|boot|root|var/lib/docker)(/|$)' -or $src -eq '/') { $null = $unsupported.Add([ordered]@{ field = "services.$n.volumes"; reason = "Service '$n' mounts the host system path '$src', which is not allowed." }); continue }
        else {
          $fid = ConvertTo-InputId ("$n folder $name")
          if (-not $inputIds.ContainsKey($fid)) { $i = [ordered]@{ id = $fid; type = 'folder'; label = "Folder on this PC for $tgt ($n), optional"; hostPathHint = $src }; $null = $inputs.Add($i); $inputIds[$fid] = $i }
          $vol.input = $fid
          & $ev "services.$n.volumes.$name" $src "host folder '$src' becomes the named volume '$name' unless you choose a folder"
        }
      }
      $vols += $vol
    }
    if ($vols.Count) { $s.volumes = $vols }
    $deps = @()
    $dep = Get-AsProp $cs 'depends_on' $null
    if ($dep) { foreach ($d in $dep.PSObject.Properties) { $deps += [ordered]@{ service = (ConvertTo-AppId $d.Name); condition = [string](Get-AsProp $d.Value 'condition' 'service_started') } } }
    if ($deps.Count) { $s.dependsOn = $deps }
    $hc = Get-AsProp $cs 'healthcheck' $null
    if ($hc -and -not [bool](Get-AsProp $hc 'disable' $false) -and (Get-AsProp $hc 'test' $null)) {
      $test = Get-AsRaw $hc 'test'
      $arr = @(if ($test -is [string]) { @('CMD-SHELL', $test) } else { @($test | ForEach-Object { [string]$_ }) })
      if ($arr.Count -and $arr[0] -ne 'NONE') {
        $h = [ordered]@{ test = $arr }
        foreach ($key in @('interval', 'timeout', 'retries', 'start_period')) { $hv = Get-AsProp $hc $key $null; if ($null -ne $hv) { $h[$key] = $hv } }
        $s.healthcheck = $h
      }
    }
    foreach ($key in @('command', 'entrypoint')) {
      $c = Get-AsRaw $cs $key
      if ($null -eq $c) { continue }
      $arr = @(if ($c -is [string]) { Split-CommandLine $c } else { @($c | ForEach-Object { [string]$_ }) })
      if (@($arr | Where-Object { $_.Contains('{{') }).Count) { & $unres "services.$n.$key" "The $key contains {{ }}; it was left out."; continue }
      if ($arr.Count) { $s[$key] = $arr }
    }
    $user = [string](Get-AsProp $cs 'user' '')
    if ($user) { if ($user -match '^\d{1,6}(:\d{1,6})?$' -or $user -match '^[a-z_][a-z0-9_-]{0,31}(:[a-z_][a-z0-9_-]{0,31})?$') { $s.user = $user } else { & $unres "services.$n.user" "The user '$user' depends on a variable or is not supported; the image's default user is used." } }
    if ([bool](Get-AsProp $cs 'privileged' $false)) { $s.privileged = $true; & $addPriv 'privileged' "Service '$n' asks to run privileged (full access to this PC's Docker VM)." }
    $nm = [string](Get-AsProp $cs 'network_mode' '')
    if ($nm -eq 'host') { $s.networkMode = 'host'; $hardware.hostNetwork = $true; & $addPriv 'host-network' "Service '$n' uses the host network." }
    elseif ($nm -and $nm -ne 'bridge') { $null = $unsupported.Add([ordered]@{ field = "services.$n.network_mode"; reason = "Service '$n' shares the network of '$nm' (network_mode), which is not supported." }) }
    $devs = @(@(Get-AsProp $cs 'devices' @()) | ForEach-Object { $dv = $(if ($_ -is [string]) { $_ } else { [string](Get-AsProp $_ 'source' '') }); ($dv -split ':')[0] } | Where-Object { $_ })
    if ($devs.Count) { $s.devices = $devs; $hardware.devices = @($hardware.devices) + $devs; & $addPriv 'device' "Service '$n' needs host devices: $($devs -join ', ')." }
    $gpu = $false
    foreach ($rd in @(Get-AsProp (Get-AsProp (Get-AsProp (Get-AsProp $cs 'deploy' $null) 'resources' $null) 'reservations' $null) 'devices' @())) { if (@(Get-AsProp $rd 'capabilities' @()) -contains 'gpu') { $gpu = $true } }
    if ([string](Get-AsProp $cs 'runtime' '') -eq 'nvidia' -or (Get-AsProp $cs 'gpus' $null)) { $gpu = $true }
    if ($gpu) { $s.gpus = $true; $hardware.gpu = $true; & $addPriv 'gpu' "Service '$n' uses a GPU." }
    foreach ($key in @('cap_add', 'security_opt', 'sysctls', 'pid', 'ipc', 'cgroup', 'userns_mode', 'secrets', 'configs', 'volumes_from')) {
      $val = Get-AsProp $cs $key $null
      if ($null -eq $val) { continue }
      if ($key -eq 'security_opt' -and @(@($val) | Where-Object { [string]$_ -notmatch '^no-new-privileges' }).Count -eq 0) { continue }
      $null = $unsupported.Add([ordered]@{ field = "services.$n.$key"; reason = "Service '$n' uses $key ($(@($val | ForEach-Object { if ($_ -is [string]) { $_ } else { ($_ | ConvertTo-Json -Compress -Depth 3) } }) -join ', ')), which the manager does not generate. Review the upstream documentation; a curated recipe is needed." })
    }
    if ((Get-AsProp $cs 'labels' $null) -and @((Get-AsProp $cs 'labels' $null).PSObject.Properties | Where-Object { $_.Name -like 'traefik.*' }).Count) { $null = $notes.Add("Service '$n' has Traefik labels; they are ignored. The route is generated as an explicit Traefik file-provider definition.") }
    if (Get-AsProp $cs 'container_name' '') { & $ev "services.$n.container_name" (Get-AsProp $cs 'container_name' '') 'not kept: container names follow the project name' }
    $services[$n] = $s
  }
  if (-not $services.Count) { throw 'No service of this Compose file can be imported.' }
  # Roles from the dependency graph: a service others wait for with service_completed_successfully is a one-time job.
  foreach ($k in @($services.Keys)) {
    foreach ($d in @(Get-AsProp $services[$k] 'dependsOn' @())) {
      if ($d.condition -eq 'service_completed_successfully' -and $services.Contains($d.service) -and -not (Get-AsProp $services[$d.service] 'role' '')) { $services[$d.service].role = 'init'; $services[$d.service].lifecycle = 'run-once'; & $ev "services.$($d.service).role" 'init' "'$k' waits for it to complete" }
    }
  }
  # The web service: the one with a published port, else exposed ports, never a database, cache, broker or job.
  $cands = @($services.Keys | Where-Object { -not ((Get-AsProp $services[$_] 'role' '') -in 'database', 'cache', 'messaging', 'init', 'migration', 'maintenance') -and @($services[$_].ports).Count })
  $published = @($cands | Where-Object { @($services[$_].ports | Where-Object { $_.published }).Count })
  $pool = @(if ($published.Count) { $published } else { $cands })
  $web = ''
  if ($pool.Count -eq 1) { $web = $pool[0]; & $ev 'web.service' $web $(if ($published.Count) { 'the only application service with a published port' } else { 'the only application service with a port' }) }
  elseif ($pool.Count -gt 1) {
    $named = @($pool | Where-Object { $_ -match '^(web|app|server|frontend|ui|front)$' })
    $web = $(if ($named.Count) { $named[0] } else { $pool[0] })
    & $ev 'web.service' $web "chosen among $($pool -join ', ') by name"
    & $unres 'web.service' "Several services publish ports ($($pool -join ', ')); '$web' was chosen as the web interface. Check it."
  } else { & $unres 'web.service' 'No service publishes a web port.' }
  $webDef = $null
  if ($web) {
    $wp = @($services[$web].ports | Where-Object { $_.protocol -eq 'tcp' })
    $pick = @($wp | Where-Object { $_.published }) + @($wp | Where-Object { -not $_.published })
    if ($pick.Count) {
      $pp = $pick[0]
      $pp.primary = $true
      $pp.protocol = $(if ($pp.container -in 443, 8443, 9443) { 'https' } else { 'http' })
      & $ev 'web.port' $pp.container "container port of '$web'"
      if ($wp.Count -gt 1) { & $unres 'web.port' "'$web' has several ports ($(@($wp | ForEach-Object { $_.container }) -join ', ')); $($pp.container) was chosen as the web interface." }
      $webDef = [ordered]@{ service = $web }
      $lp = 0; if ([int]::TryParse([string]$pp.published, [ref]$lp) -and $lp -ge 1024) { $webDef.localPort = $lp }
      if (-not $services[$web].Contains('role')) { $services[$web].role = 'app' }
    } else { & $unres 'web.port' "'$web' has no TCP port." }
  }
  foreach ($k in @($services.Keys)) {
    $s = $services[$k]
    foreach ($p in @($s.ports)) { $p.Remove('published') }
    if (-not $s.Contains('role')) {
      if ($k -match 'worker|celery|queue|cron|scheduler|jobs?$') { $s.role = 'worker' } elseif ($k -ne $web) { $s.role = 'support' }
    }
    $s.resources = [ordered]@{ memoryMB = $script:RoleMemory[[string]$s.role]; diskMB = 512 }
    if ((Get-AsProp $s 'role' '') -in 'database', 'cache' -and @(Get-AsProp $s 'volumes' @()).Count) { $s.stateful = $true }
    $nonWebPorts = @($s.ports | Where-Object { -not $_.Contains('primary') })
    if ($nonWebPorts.Count -and ($k -ne $web -or $nonWebPorts.Count)) {
      if (@($nonWebPorts | Where-Object { $_.protocol -eq 'udp' }).Count -and $k -eq $web) { $null = $notes.Add("'$k' also listens on UDP $(@($nonWebPorts | Where-Object { $_.protocol -eq 'udp' } | ForEach-Object { $_.container }) -join ', '); only the web interface is published, so clients that need those ports directly will not reach them.") }
    }
  }
  # Keep only dependencies that name imported services.
  foreach ($k in @($services.Keys)) { if ($services[$k].Contains('dependsOn')) { $services[$k].dependsOn = @($services[$k].dependsOn | Where-Object { $services.Contains($_.service) }) } }
  return [pscustomobject]@{ Services = $services; Inputs = @($inputs); Privileges = @($privileges); Web = $webDef; Unresolved = @($unresolved); Evidence = @($evidence); Unsupported = @($unsupported); Notes = @($notes); Hardware = $hardware }
}

# --- Unraid templates ---------------------------------------------------------------------------------------------------

# Pure: an XML document parsed without DTDs, external entities or resolvers (XXE-safe), at most 1 MB.
function ConvertFrom-SafeXml([string]$Text) {
  $settings = New-Object Xml.XmlReaderSettings
  $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
  $settings.XmlResolver = $null
  $settings.MaxCharactersInDocument = 1048576
  $settings.MaxCharactersFromEntities = 1024
  $sr = New-Object IO.StringReader($Text)
  $reader = [Xml.XmlReader]::Create($sr, $settings)
  try {
    $doc = New-Object Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.Load($reader)
    return $doc
  } catch { throw "The template is not valid or safe XML: $($_.Exception.Message)" } finally { $reader.Close() }
}

function Get-XmlText($Node, [string]$Name) {
  $n = $Node.SelectSingleNode($Name)
  if ($n) { return ([string]$n.InnerText).Trim() }
  return ''
}

# Pure: an Unraid Docker template (Container version 2) as a Compose-like model plus facts. Unraid OS plugins
# (PluginURL) are refused: they are not Docker applications.
function ConvertFrom-UnraidTemplate([string]$Xml) {
  $doc = ConvertFrom-SafeXml $Xml
  $root = $doc.DocumentElement
  if ($root.get_LocalName() -eq 'PLUGIN' -or $root.SelectSingleNode('PluginURL')) { throw 'This is an Unraid OS plugin (.plg), not a Docker application. Plugins extend Unraid itself and cannot be installed with Docker.' }
  if ($root.get_LocalName() -ne 'Container') { throw 'This XML is not an Unraid Docker template (<Container> is missing).' }
  $repo = Get-XmlText $root 'Repository'
  if (-not $repo) { throw 'The template has no <Repository> (Docker image).' }
  $name = Get-XmlText $root 'Name'
  $notes = New-Object System.Collections.ArrayList; $evidence = New-Object System.Collections.ArrayList
  $svc = [ordered]@{ image = $repo; restart = 'unless-stopped' }
  $net = (Get-XmlText $root 'Network').ToLowerInvariant()
  if ($net -eq 'host') { $svc.network_mode = 'host' }
  elseif ($net -and $net -notin 'bridge', '') { $null = $notes.Add("The template uses Unraid's custom network '$net' (its own LAN address). On Docker Desktop the app runs on the normal bridge network and is reached through Traefik instead.") }
  if ((Get-XmlText $root 'Privileged') -eq 'true') { $svc.privileged = $true }
  $webui = Get-XmlText $root 'WebUI'
  $webPort = 0; $webScheme = 'http'
  if ($webui -match '\[PORT:(\d+)\]') { $webPort = [int]$Matches[1] }
  if ($webui -match '^https://') { $webScheme = 'https' }
  $ports = @(); $volumes = @(); $env = [ordered]@{}; $devices = @(); $secrets = @()
  foreach ($c in @($root.SelectNodes('Config'))) {
    $type = [string]$c.GetAttribute('Type'); $target = [string]$c.GetAttribute('Target'); $value = ([string]$c.InnerText).Trim()
    if (-not $value) { $value = [string]$c.GetAttribute('Default') }
    $label = [string]$c.GetAttribute('Name')
    switch ($type) {
      'Port' { $t = 0; if ([int]::TryParse($target, [ref]$t) -and $t -gt 0) { $ports += [ordered]@{ target = $t; published = $value; protocol = $(if ([string]$c.GetAttribute('Mode') -eq 'udp') { 'udp' } else { 'tcp' }) } } }
      'Path' {
        if (-not $target.StartsWith('/')) { continue }
        $ro = ([string]$c.GetAttribute('Mode')) -match '^ro'
        if ($value -match 'docker\.sock$') { $volumes += [ordered]@{ type = 'bind'; source = '/var/run/docker.sock'; target = $target; read_only = $ro }; continue }
        if ($value -match '^/mnt/user/appdata/' -or -not $value) { $volumes += [ordered]@{ type = 'volume'; source = (ConvertTo-AppId ((Split-Path -Leaf $target.TrimEnd('/')) -replace '^$', 'data')); target = $target; read_only = $ro }; $null = $evidence.Add([ordered]@{ field = "volumes.$target"; value = $value; how = "Unraid appdata path '$value' becomes a named volume" }) }
        else { $volumes += [ordered]@{ type = 'bind'; source = $value; target = $target; read_only = $ro }; $null = $evidence.Add([ordered]@{ field = "volumes.$target"; value = $value; how = "Unraid share '$value' ($label) becomes a named volume unless you choose a folder on this PC" }) }
      }
      'Variable' {
        if ($target -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        $v = $value
        if ($target -in 'PUID', 'PGID' -and $v -in '99', '100') { $null = $evidence.Add([ordered]@{ field = "environment.$target"; value = '1000'; how = "Unraid's nobody:users ($v) is mapped to 1000 for Docker Desktop" }); $v = '1000' }
        if ($target -eq 'UMASK' -and -not $v) { $v = '022' }
        if ([string]$c.GetAttribute('Mask') -eq 'true') { $secrets += $target; $v = '${' + $target.ToUpperInvariant() + '}' }
        $env[$target.ToUpperInvariant()] = $v
      }
      'Device' { if ($value -match '^/dev/') { $devices += $value } }
    }
  }
  if ($ports.Count) { $svc.ports = $ports }
  if ($volumes.Count) { $svc.volumes = $volumes }
  if ($env.Count) { $svc.environment = $env }
  if ($devices.Count) { $svc.devices = $devices }
  $extra = Get-XmlText $root 'ExtraParams'
  if ($extra -match '--runtime[= ]nvidia|--gpus') { $svc.runtime = 'nvidia' }
  $other = @(([regex]::Matches($extra, '--[a-z-]+(?:[= ][^ ]+)?') | ForEach-Object { $_.Value }) | Where-Object { $_ -notmatch '^--(runtime|gpus|restart|log-opt|log-driver|memory|cpus|name|hostname)' })
  if ($other.Count) { $svc.cap_add = @($other) }
  if (Get-XmlText $root 'PostArgs') { $null = $notes.Add("The template adds arguments after the image ($((Get-XmlText $root 'PostArgs'))); they are not imported.") }
  # WebUI port with nothing mapped: the container port named in the WebUI template.
  if ($webPort -and -not @($ports | Where-Object { $_.target -eq $webPort }).Count) { $svc.ports = @(@(Get-AsProp $svc 'ports' @()) + [ordered]@{ target = $webPort; published = ''; protocol = 'tcp' }) }
  # The WebUI port first, so it becomes the web interface.
  if ($webPort) { $svc.ports = @(@($svc.ports | Where-Object { $_.target -eq $webPort }) + @($svc.ports | Where-Object { $_.target -ne $webPort })) }
  $svcName = ConvertTo-AppId $(if ($name) { $name } else { 'app' })
  $model = [pscustomobject]@{ services = [pscustomobject]@{ $svcName = [pscustomobject]$svc } }
  $model.services.$svcName.PSObject.Properties | Out-Null
  $categories = @((Get-XmlText $root 'Category') -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -split ':')[0].ToLowerInvariant() })
  return [pscustomobject]@{ Model = (ConvertTo-PlainObject $model); Name = $(if ($name) { $name } else { $svcName }); Description = (Get-XmlText $root 'Overview'); Project = (Get-XmlText $root 'Project'); Support = (Get-XmlText $root 'Support')
    License = $(if (Get-XmlText $root 'License') { Get-XmlText $root 'License' } else { Get-XmlText $root 'Licence' }); Icon = (Get-XmlText $root 'Icon'); TemplateUrl = (Get-XmlText $root 'TemplateURL'); Categories = $categories
    WebScheme = $webScheme; WebPort = $webPort; Secrets = $secrets; Notes = @($notes); Evidence = @($evidence); Requires = (Get-XmlText $root 'Requires') }
}

# Pure: an ordered/hashtable tree as the same shape ConvertFrom-Json produces (so model readers see one shape).
function ConvertTo-PlainObject($Value) { return (($Value | ConvertTo-Json -Depth 12) | ConvertFrom-Json) }

# --- Directories (awesome-selfhosted) ---------------------------------------------------------------------------------

# Pure: the top-level scalars and simple lists of one awesome-selfhosted-data software entry.
function ConvertFrom-DirectoryYaml([string]$Text) {
  $map = [ordered]@{}; $key = ''
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^([a-z_]+):\s*(.*?)\s*$') {
      $key = $Matches[1]; $v = $Matches[2]
      if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { $v = $Matches[1] }
      if ($v -eq '') { $map[$key] = @() } else { $map[$key] = $v }
    } elseif ($key -and $line -match '^\s*-\s+(.+?)\s*$') { $map[$key] = @(@($map[$key]) + $Matches[1].Trim('"', "'")) }
  }
  return $map
}

# --- Normalized manifest ----------------------------------------------------------------------------------------------

function Get-CategoryFromHints([string[]]$Hints) {
  $map = [ordered]@{ media = 'media|video|music|stream|plex|jellyfin|tv|dvr|audio|podcast'; photos = 'photo|image|gallery'; monitoring = 'monitor|uptime|status|metrics|observab|log'
    authentication = 'auth|identity|sso|ldap|oauth|password'; communication = 'chat|messag|mail|communication|forum|social'; dashboard = 'dashboard|homepage|startpage|bookmark'
    networking = 'network|dns|vpn|proxy|tunnel'; management = 'docker|container|management|admin|backup'; productivity = 'productiv|note|wiki|document|office|task|calendar|file'; updates = 'update' }
  $text = (@($Hints) -join ' ').ToLowerInvariant()
  foreach ($k in $map.Keys) { if ($text -match $map[$k]) { return $k } }
  return 'tools'
}

# Builds the DTC manifest (schema 1, source.type 'imported') from a Compose-model conversion and source facts.
function New-NormalizedManifest {
  param([Parameter(Mandatory = $true)]$Conversion, [Parameter(Mandatory = $true)][hashtable]$Facts)
  foreach ($k in @('Name', 'Description', 'Publisher', 'License', 'Docs', 'SourceUrl', 'SourceKind', 'SourceKindLabel', 'Upstream', 'Documents', 'Evidence', 'Notes', 'Hints', 'Category', 'Attribution', 'NativeAuth', 'Architectures')) { if (-not $Facts.ContainsKey($k)) { $Facts[$k] = $null } }
  $id = ConvertTo-AppId ([string]$Facts.Name)
  $docs = @(@($Facts.Docs) | Where-Object { $_ -and [string]$_.url -match '^https://' })
  if (-not $docs.Count) { $docs = @([ordered]@{ title = 'Source'; url = [string]$Facts.SourceUrl }) }
  $nonUnsupported = -not @($Conversion.Unsupported).Count
  $limited = [bool]($Conversion.Hardware.hostNetwork -or @($Conversion.Hardware.devices).Count)
  $m = [ordered]@{
    schema = 1; id = $id; name = [string]$Facts.Name; manifestVersion = '0.1.0-import'
    description = $(if ($Facts.Description) { ([string]$Facts.Description).Substring(0, [Math]::Min(400, ([string]$Facts.Description).Length)) } else { "$($Facts.Name) (imported from $($Facts.SourceKindLabel))." })
    category = $(if ($Facts.Category) { $Facts.Category } else { Get-CategoryFromHints @($Facts.Name, $Facts.Description, (@($Facts.Hints) -join ' ')) })
    maintainer = $(if ($Facts.Publisher) { [string]$Facts.Publisher } else { 'unknown (imported)' })
    license = $(if ($Facts.License) { [string]$Facts.License } else { 'NOASSERTION' })
    docs = $docs
    source = [ordered]@{ type = 'imported'; kind = [string]$Facts.SourceKind; url = [string]$Facts.SourceUrl; upstream = [string]$Facts.Upstream }
    platforms = [ordered]@{ 'windows-docker-desktop' = $(if ($limited) { 'limited' } else { 'untested' }); 'linux-docker' = 'untested'; unraid = 'untested'; podman = 'untested' }
    installable = $nonUnsupported
    services = $Conversion.Services
    inputs = @($Conversion.Inputs | ForEach-Object { $i = [ordered]@{}; foreach ($k in $_.Keys) { if ($k -notin 'env', 'replaces', 'hostPathHint') { $i[$k] = $_[$k] } }; $i })
    privileges = @($Conversion.Privileges)
    security = @()
    exposure = [ordered]@{ default = 'local'; allowPublic = $true }
    provenance = [ordered]@{ sourceType = [string]$Facts.SourceKind; url = [string]$Facts.SourceUrl; retrievedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; documents = @(@($Facts.Documents) | Where-Object { $_ }); attribution = [string]$Facts.Attribution; license = $(if ($Facts.License) { [string]$Facts.License } else { 'NOASSERTION' }) }
    verification = [ordered]@{ status = 'unverified'; checks = @() }
    authentication = [ordered]@{ forwardAuth = 'unknown'; native = [string]$Facts.NativeAuth; notes = @() }
    architectures = @(@($Facts.Architectures) | Where-Object { $_ })
    hardware = $Conversion.Hardware
    knownIssues = @(@($Conversion.Notes) + @($Facts.Notes) | Where-Object { $_ })
    recipes = @()
    draft = [ordered]@{ unresolved = @($Conversion.Unresolved); evidence = @(@($Conversion.Evidence) + @($Facts.Evidence) | Where-Object { $_ }); unsupported = @($Conversion.Unsupported); assumptions = @() }
  }
  if (-not $nonUnsupported) { $m.installNote = 'Imported with unsupported settings: ' + ((@($Conversion.Unsupported) | ForEach-Object { $_.reason }) -join ' ') }
  if ($Conversion.Web) { $m.web = $Conversion.Web } else { $m.installable = $false; $m.installNote = 'No web interface was found; the manager installs applications that have one.' }
  return $m
}

# Pins every image by digest (read-only registry requests) and records the platforms it is published for. An image
# that cannot be resolved stays unpinned with an unresolved entry: the draft cannot be installed until it is fixed.
function Complete-ImportedImages($Manifest) {
  $archs = @()
  foreach ($k in @($Manifest.services.Keys)) {
    $s = $Manifest.services[$k]
    $img = [string]$s.image
    if ($img -match '@sha256:[0-9a-f]{64}$' -and $img -match ':[^/@]+@') { continue }
    try {
      $f = Get-RegistryImageFacts $img
      $s.image = $f.Pinned
      $Manifest.draft.evidence = @($Manifest.draft.evidence) + [ordered]@{ field = "services.$k.image"; value = $f.Pinned; source = $f.Registry; how = "tag $($f.Tag) resolved to its current digest" }
      if ($k -eq [string](Get-AsProp (Get-AsProp $Manifest 'web' $null) 'service' '')) { $archs = @($f.Platforms) }
      if ($f.Platforms.Count -and -not @($f.Platforms | Where-Object { $_ -like 'linux/amd64*' }).Count) { $Manifest.draft.unsupported = @($Manifest.draft.unsupported) + [ordered]@{ field = "services.$k.image"; reason = "$($f.Image) is not published for linux/amd64 (only $($f.Platforms -join ', ')); Docker Desktop on this PC cannot run it natively." } ; $Manifest.installable = $false }
    } catch {
      $Manifest.draft.unresolved = @($Manifest.draft.unresolved) + [ordered]@{ field = "services.$k.image"; reason = "The image '$img' could not be pinned: $($_.Exception.Message)" }
    }
  }
  if ($archs.Count) { $Manifest.architectures = $archs }
  return $Manifest
}

# Pure: a JSON-shaped tree (PSCustomObject from ConvertFrom-Json) as ordered dictionaries and arrays, the shape the
# draft editors (Set-DraftWebPort, Merge-AiProposal) work on.
function ConvertTo-OrderedTree($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in @($Value.Keys)) { $o[[string]$k] = ConvertTo-OrderedTree $Value[$k] }; return $o }
  if ($Value -is [System.Collections.IEnumerable]) { $list = New-Object System.Collections.ArrayList; foreach ($x in $Value) { $null = $list.Add((ConvertTo-OrderedTree $x)) }; return ,($list.ToArray()) }
  $o = [ordered]@{}
  foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-OrderedTree $p.Value }
  return $o
}

# Pure: the user's (or a reviewer's) answer to "which port is the web interface": one service and port become the
# web interface; the related open questions are closed and the answer is recorded as evidence.
function Set-DraftWebPort($Manifest, [string]$Service, [int]$Port, [string]$Protocol, [string]$Source = 'you') {
  if (-not $Manifest.services.Contains($Service)) { throw "The draft has no service '$Service'." }
  if ($Port -lt 1 -or $Port -gt 65535) { throw 'The port must be between 1 and 65535.' }
  if ($Protocol -notin 'http', 'https') { throw 'The protocol must be http or https.' }
  $s = $Manifest.services[$Service]
  if ((Get-AsProp $s 'role' '') -in 'database', 'cache', 'messaging', 'init', 'migration', 'maintenance') { throw "'$Service' is a $($s.role), not a web interface." }
  foreach ($k in @($Manifest.services.Keys)) { foreach ($p in @(Get-AsProp $Manifest.services[$k] 'ports' @())) { if ($p.Contains('primary')) { $p.Remove('primary') } } }
  $hit = @(@(Get-AsProp $s 'ports' @()) | Where-Object { [int]$_.container -eq $Port })
  if ($hit.Count) { $hit[0].primary = $true; $hit[0].protocol = $Protocol } else { $s.ports = @(@(Get-AsProp $s 'ports' @()) + [ordered]@{ container = $Port; protocol = $Protocol; primary = $true }) }
  $s.role = 'app'
  $Manifest.web = [ordered]@{ service = $Service }
  $Manifest.draft.unresolved = @(@($Manifest.draft.unresolved) | Where-Object { [string]$_.field -notin 'web.port', 'web.service' })
  $Manifest.draft.evidence = @(@($Manifest.draft.evidence) + [ordered]@{ field = 'web'; value = "${Service}:$Port ($Protocol)"; source = $Source; how = 'answered in the review' })
  if (-not @($Manifest.draft.unsupported).Count) { $Manifest.installable = $true; if ($Manifest.Contains('installNote')) { $Manifest.Remove('installNote') } }
  return $Manifest
}

# --- Importers (network) ---------------------------------------------------------------------------------------------

function Get-GitHubRaw([string]$Owner, [string]$Repo, [string]$Ref, [string]$Path, [int]$MaxBytes = 512KB) {
  $u = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref/$(($Path -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')"
  $r = Invoke-SafeFetch -Url $u -MaxBytes $MaxBytes
  if ($r.Status -ge 400) { throw "HTTP $($r.Status) for $Path" }
  return [pscustomobject]@{ Url = $u; Text = $r.Text; Sha256 = (Get-AsSha256 $r.Text) }
}

# A compose block inside README/Markdown text that runs the given image (documentation examples are untrusted too).
function Find-MarkdownCompose([string]$Markdown, [string]$ImageRepo) {
  foreach ($m in [regex]::Matches($Markdown, '```(?:ya?ml|docker-compose|compose)?\s*\r?\n([\s\S]*?)```')) {
    $block = $m.Groups[1].Value
    if ($block -match '(?m)^services\s*:' -and (-not $ImageRepo -or $block.ToLowerInvariant().Contains($ImageRepo.ToLowerInvariant()))) { return $block }
  }
  return ''
}

function Import-ComposeSource([string]$Text, [hashtable]$Facts, $EnvDefaults, [string]$Origin, $DockerInvoker = $null) {
  $model = ConvertFrom-ComposeText -Text $Text -DockerInvoker $DockerInvoker
  $conv = ConvertFrom-ComposeModel -Model $model -EnvDefaults $EnvDefaults -Origin $Origin
  return (New-NormalizedManifest -Conversion $conv -Facts $Facts)
}

# Docker Hub: repository metadata, the tag to use, image configuration; the README's Compose example when the image
# alone does not say how to run it. Single-image drafts get one web service from the image's exposed port.
function Import-DockerHubSource([string]$Namespace, [string]$Repo, [string]$SourceUrl, $DockerInvoker = $null) {
  $docs = @(); $documents = @(); $evidence = @(); $notes = @()
  $api = "https://hub.docker.com/v2/repositories/$Namespace/$Repo/"
  $meta = $null
  try { $meta = Invoke-SafeJson -Url $api } catch { if ($_.Exception.Data['Status'] -eq 404) { throw "Docker Hub has no repository $Namespace/$Repo." }; throw }
  $documents += [ordered]@{ url = $api; kind = 'docker-hub-metadata' }
  $tags = @()
  try { $tags = @((Invoke-SafeJson -Url "${api}tags/?page_size=50&ordering=last_updated").results) } catch { }
  $image = $(if ($Namespace -eq 'library') { $Repo } else { "$Namespace/$Repo" })
  $tag = Select-ImageTag $tags
  if ($tag.Note) { $evidence += [ordered]@{ field = 'tag'; value = $tag.Name; source = 'Docker Hub tags'; how = $tag.Note } }
  $full = [string](Get-AsProp $meta 'full_description' '')
  $facts = @{ Name = $(if ($Namespace -eq 'library') { $Repo } else { $Repo }); Description = [string](Get-AsProp $meta 'description' ''); Publisher = $Namespace; SourceUrl = $SourceUrl; SourceKind = 'dockerhub'; SourceKindLabel = 'Docker Hub'
    Upstream = "docker.io/$image"; Docs = @([ordered]@{ title = 'Docker Hub'; url = "https://hub.docker.com/$(if ($Namespace -eq 'library') { "_/$Repo" } else { "r/$Namespace/$Repo" })" }); Documents = $documents; Evidence = $evidence; Notes = $notes; Hints = @(@(Get-AsProp $meta 'categories' @()) | ForEach-Object { [string](Get-AsProp $_ 'name' '') }) }
  $cfg = $null
  try { $cfg = Get-RegistryImageFacts "$image`:$($tag.Name)" } catch { $facts.Notes = @($facts.Notes) + "The image configuration could not be read: $($_.Exception.Message)" }
  if ($cfg) {
    $src = [string](Get-AsProp $cfg.Labels 'org.opencontainers.image.source' '')
    if ($src -match '^https://github\.com/[^/]+/[^/]+') { $facts.Docs = @($facts.Docs) + [ordered]@{ title = 'Source code'; url = $Matches[0] }; $facts.Upstream = $Matches[0] }
    $lic = [string](Get-AsProp $cfg.Labels 'org.opencontainers.image.licenses' '')
    if ($lic) { $facts.License = $lic }
    $facts.Architectures = $cfg.Platforms
  }
  # 1. A Compose example in the repository's documentation (preferred: it names the dependencies).
  $readmeCompose = Find-MarkdownCompose $full $image
  if ($readmeCompose) {
    $facts.Documents = @($facts.Documents) + [ordered]@{ url = "$SourceUrl#readme"; kind = 'readme-compose'; sha256 = (Get-AsSha256 $readmeCompose) }
    try { return (Complete-ImportedImages (Import-ComposeSource $readmeCompose $facts $null 'Docker Hub README (Compose example)' $DockerInvoker)) } catch { $facts.Notes = @($facts.Notes) + "The Compose example in the README could not be used: $($_.Exception.Message)" }
  }
  # 2. The image alone: one service, its exposed TCP port as the web interface, its declared volumes as named volumes.
  $ports = @(); $vols = @()
  if ($cfg) {
    foreach ($p in $cfg.ExposedPorts) { if ($p -match '^(\d+)/(tcp|udp)$') { $ports += [pscustomobject]@{ target = [int]$Matches[1]; protocol = $Matches[2]; published = '' } } }
    foreach ($v in $cfg.Volumes) { $vols += [pscustomobject]@{ type = 'volume'; source = (ConvertTo-AppId ((Split-Path -Leaf $v.TrimEnd('/')) -replace '^$', 'data')); target = $v } }
  }
  $tcp = @($ports | Where-Object { $_.protocol -eq 'tcp' })
  if ($tcp.Count -eq 1) { $tcp[0].published = [string]([Math]::Max(1024, $tcp[0].target)) }
  $svc = [ordered]@{ image = "$image`:$($tag.Name)"; restart = 'unless-stopped'; ports = $ports }
  if ($vols.Count) { $svc.volumes = $vols }
  $model = ConvertTo-PlainObject ([ordered]@{ services = [ordered]@{ (ConvertTo-AppId $Repo) = $svc } })
  $conv = ConvertFrom-ComposeModel -Model $model -Origin 'image configuration'
  if (-not $tcp.Count) { $conv.Unresolved = @($conv.Unresolved) + [ordered]@{ field = 'web.port'; reason = 'The image declares no TCP port; its documentation must say which port the web interface uses.' } }
  if (-not $cfg) { $conv.Unresolved = @($conv.Unresolved) + [ordered]@{ field = 'services'; reason = 'The image configuration was not available; ports and storage are unknown.' } }
  $conv.Unresolved = @($conv.Unresolved) + [ordered]@{ field = 'environment'; reason = 'Docker Hub metadata does not list required settings; check the documentation for environment variables the application needs.' }
  return (Complete-ImportedImages (New-NormalizedManifest -Conversion $conv -Facts $facts))
}

# Pure: the tag to install: a stable version tag (the one 'latest' points to when known), else the newest stable
# version, else 'latest'.
function Select-ImageTag($Tags) {
  $list = @($Tags | Where-Object { $_ })
  $stable = @($list | Where-Object { [string]$_.name -match '^v?\d+(\.\d+){1,3}$' })
  $latest = @($list | Where-Object { $_.name -eq 'latest' })
  if ($latest.Count -and [string](Get-AsProp $latest[0] 'digest' '')) {
    $same = @($stable | Where-Object { [string](Get-AsProp $_ 'digest' '') -eq [string]$latest[0].digest })
    if ($same.Count) { return [pscustomobject]@{ Name = [string]$same[0].name; Note = "the stable version 'latest' points to" } }
  }
  if ($stable.Count) {
    $best = @($stable | Sort-Object { [version](([string]$_.name -replace '^v', '') + $(if (([string]$_.name -split '\.').Count -lt 3) { '.0' } else { '' })) } -Descending)[0]
    return [pscustomobject]@{ Name = [string]$best.name; Note = 'the newest stable version tag' }
  }
  return [pscustomobject]@{ Name = 'latest'; Note = $(if ($latest.Count) { "no version tags; 'latest' is pinned by digest" } else { "no tags were listed; 'latest' is assumed" }) }
}

# GitHub: repository metadata and licence, an official Compose file (root, then docker/ and deploy/ folders), its
# .env example, the latest release; or a direct link to a Compose file.
function Import-GitHubSource($Kind, [string]$SourceUrl, $DockerInvoker = $null) {
  $o = $Kind.Owner; $r = $Kind.Repo
  $meta = $null
  try { $meta = Invoke-SafeJson -Url "https://api.github.com/repos/$o/$r" } catch { if ($_.Exception.Data['Status'] -eq 404) { throw "GitHub has no public repository $o/$r." }; throw }
  $ref = $(if ($Kind.Ref) { $Kind.Ref } else { [string](Get-AsProp $meta 'default_branch' 'main') })
  $lic = [string](Get-AsProp (Get-AsProp $meta 'license' $null) 'spdx_id' '')
  $facts = @{ Name = [string](Get-AsProp $meta 'name' $r); Description = [string](Get-AsProp $meta 'description' ''); Publisher = $o; License = $(if ($lic -and $lic -ne 'NOASSERTION') { $lic } else { '' }); SourceUrl = $SourceUrl; SourceKind = 'github'; SourceKindLabel = 'GitHub'
    Upstream = "https://github.com/$o/$r"; Docs = @([ordered]@{ title = 'GitHub repository'; url = "https://github.com/$o/$r" }); Documents = @([ordered]@{ url = "https://api.github.com/repos/$o/$r"; kind = 'github-metadata' }); Evidence = @(); Notes = @(); Hints = @(@(Get-AsProp $meta 'topics' @())) }
  if ([string](Get-AsProp $meta 'homepage' '') -match '^https://') { $facts.Docs = @($facts.Docs) + [ordered]@{ title = 'Website'; url = [string]$meta.homepage } }
  if ([bool](Get-AsProp $meta 'archived' $false)) { $facts.Notes = @($facts.Notes) + 'The repository is archived (no longer maintained).' }
  try { $rel = Invoke-SafeJson -Url "https://api.github.com/repos/$o/$r/releases/latest"; $facts.Evidence = @($facts.Evidence) + [ordered]@{ field = 'release'; value = [string]$rel.tag_name; source = 'GitHub releases'; how = 'latest release' } } catch { }
  $path = ''
  if ($Kind.Kind -eq 'github-file') { $path = $Kind.Path }
  else {
    $dirs = @($(if ($Kind.Path) { $Kind.Path } else { '' }), 'docker', 'deploy', 'docker-compose', 'compose', 'contrib/docker')
    foreach ($d in $dirs) {
      $list = $null
      try { $list = @(Invoke-SafeJson -Url "https://api.github.com/repos/$o/$r/contents/$d`?ref=$([Uri]::EscapeDataString($ref))") } catch { continue }
      $names = @($list | ForEach-Object { [string]$_.name })
      $hit = @($script:ComposeNames | Where-Object { $names -contains $_ })
      if ($hit.Count) { $path = $(if ($d) { "$d/$($hit[0])" } else { $hit[0] }); break }
    }
  }
  if (-not $path) { throw "No Compose file was found in $o/$r (looked in the root, docker/, deploy/, docker-compose/, compose/ and contrib/docker/). Paste a link to the Compose file itself, or a Docker Hub link." }
  $f = Get-GitHubRaw $o $r $ref $path
  $facts.Documents = @($facts.Documents) + [ordered]@{ url = $f.Url; kind = 'compose'; sha256 = $f.Sha256 }
  $facts.Docs = @($facts.Docs) + [ordered]@{ title = 'Compose file'; url = "https://github.com/$o/$r/blob/$ref/$path" }
  $envDefaults = [ordered]@{}
  $folder = $(if ($path.Contains('/')) { $path.Substring(0, $path.LastIndexOf('/') + 1) } else { '' })
  foreach ($e in @('.env.example', 'example.env', '.env.sample', 'env.example', '.env.dist')) {
    try { $x = Get-GitHubRaw $o $r $ref "$folder$e" 64KB; $envDefaults = ConvertFrom-EnvExample $x.Text; $facts.Documents = @($facts.Documents) + [ordered]@{ url = $x.Url; kind = 'env-example'; sha256 = $x.Sha256 }; break } catch { }
  }
  $facts.Name = $(if ($facts.Name) { $facts.Name } else { $r })
  return (Complete-ImportedImages (Import-ComposeSource $f.Text $facts $envDefaults "GitHub $o/$r/$path" $DockerInvoker))
}

function Import-UnraidSource($Kind, [string]$SourceUrl, $DockerInvoker = $null, [string]$XmlText = '') {
  $sha = ''
  if (-not $XmlText) {
    $u = $(if ($Kind.Owner) { "https://raw.githubusercontent.com/$($Kind.Owner)/$($Kind.Repo)/$($Kind.Ref)/$($Kind.Path)" } else { $SourceUrl })
    $res = Invoke-SafeFetch -Url $u -MaxBytes 512KB
    if ($res.Status -ge 400) { throw "HTTP $($res.Status) for the template." }
    $XmlText = $res.Text; $sha = Get-AsSha256 $XmlText
  }
  $t = ConvertFrom-UnraidTemplate $XmlText
  $facts = @{ Name = $t.Name; Description = ($t.Description -replace '\[/?[a-z]+[^\]]*\]', '' -replace '\s+', ' ').Trim(); Publisher = $(if ($Kind.Owner) { $Kind.Owner } else { 'Unraid template' }); License = $t.License; SourceUrl = $SourceUrl
    SourceKind = 'unraid'; SourceKindLabel = 'an Unraid template'; Upstream = $t.Project; Docs = @(@($t.Project, $t.Support) | Where-Object { $_ -match '^https://' } | ForEach-Object { [ordered]@{ title = $(if ($_ -eq $t.Project) { 'Project' } else { 'Support' }); url = $_ } })
    Documents = @([ordered]@{ url = $SourceUrl; kind = 'unraid-template'; sha256 = $sha }); Evidence = @($t.Evidence | ForEach-Object { [ordered]@{ field = $_.field; value = $_.value; source = 'Unraid template'; how = $_.how } }); Notes = @($t.Notes); Hints = $t.Categories
    Attribution = 'Unraid Community Applications template' }
  if ($t.Requires) { $facts.Notes = @($facts.Notes) + "The template says: $($t.Requires)" }
  $conv = ConvertFrom-ComposeModel -Model $t.Model -Origin 'Unraid template'
  if ($t.WebScheme -eq 'https' -and $conv.Web) { foreach ($p in @($conv.Services[$conv.Web.service].ports)) { if ($p.Contains('primary')) { $p.protocol = 'https' } } }
  return (Complete-ImportedImages (New-NormalizedManifest -Conversion $conv -Facts $facts))
}

# awesome-selfhosted (and similar directories) are discovery indexes: the entry's metadata is kept for attribution,
# then the application's own source repository is imported.
function Import-DirectorySource($Kind, [string]$SourceUrl, $DockerInvoker = $null) {
  $f = Get-GitHubRaw $Kind.Owner $Kind.Repo $Kind.Ref $Kind.Path 64KB
  $e = ConvertFrom-DirectoryYaml $f.Text
  $src = [string](Get-AsProp $e 'source_code_url' '')
  $next = Get-AppSourceKind $src
  if ($next.Kind -notin 'github-repo') { throw "The directory entry '$(Get-AsProp $e 'name' '')' points to $src, which is not a GitHub repository; open its website ($(Get-AsProp $e 'website_url' '')) and paste a Docker Hub or Compose link instead." }
  $m = Import-GitHubSource $next $src $DockerInvoker
  $m.provenance.attribution = "Listed in awesome-selfhosted ($SourceUrl), data licensed CC BY-SA 3.0."
  $m.provenance.documents = @($m.provenance.documents) + [ordered]@{ url = $f.Url; kind = 'directory-entry'; sha256 = $f.Sha256 }
  $lic = @(Get-AsProp $e 'licenses' @())
  if ($m.license -eq 'NOASSERTION' -and $lic.Count) { $m.license = ($lic -join ' OR '); $m.provenance.license = $m.license }
  if ([string](Get-AsProp $e 'website_url' '') -match '^https://') { $m.docs = @($m.docs) + [ordered]@{ title = 'Website'; url = [string]$e.website_url } }
  return $m
}

# Entry point: a pasted link or image reference -> { Manifest; Kind; CatalogMatch }. Throws readable errors.
function Import-AppSource {
  param([Parameter(Mandatory = $true)][string]$Text, $CatalogApps = @(), $DockerInvoker = $null)
  $k = Get-AppSourceKind $Text
  $m = $null
  switch ($k.Kind) {
    'dockerhub' { $m = Import-DockerHubSource $k.Owner $k.Repo $k.Url $DockerInvoker }
    'image' {
      $ref = ConvertTo-ImageReference $k.Image
      if ($ref.Registry -eq 'docker.io') { $parts = $ref.Repository -split '/', 2; $m = Import-DockerHubSource $parts[0] $parts[1] "https://hub.docker.com/$(if ($parts[0] -eq 'library') { "_/$($parts[1])" } else { "r/$($ref.Repository)" })" $DockerInvoker }
      else {
        $cfg = Get-RegistryImageFacts $k.Image
        $ports = @($cfg.ExposedPorts | Where-Object { $_ -match '^\d+/(tcp|udp)$' } | ForEach-Object { [pscustomobject]@{ target = [int]($_ -replace '/.*$', ''); protocol = ($_ -replace '^\d+/', ''); published = '' } })
        $tcp = @($ports | Where-Object { $_.protocol -eq 'tcp' }); if ($tcp.Count -eq 1) { $tcp[0].published = [string]([Math]::Max(1024, $tcp[0].target)) }
        $svc = [ordered]@{ image = $cfg.Pinned; restart = 'unless-stopped'; ports = $ports; volumes = @($cfg.Volumes | ForEach-Object { [pscustomobject]@{ type = 'volume'; source = (ConvertTo-AppId (Split-Path -Leaf $_.TrimEnd('/'))); target = $_ } }) }
        $name = ($ref.Repository -split '/')[-1]
        $conv = ConvertFrom-ComposeModel -Model (ConvertTo-PlainObject ([ordered]@{ services = [ordered]@{ (ConvertTo-AppId $name) = $svc } })) -Origin 'image configuration'
        $conv.Unresolved = @($conv.Unresolved) + [ordered]@{ field = 'environment'; reason = 'Registry metadata does not list required settings; check the documentation.' }
        $src = [string](Get-AsProp $cfg.Labels 'org.opencontainers.image.source' '')
        $m = New-NormalizedManifest -Conversion $conv -Facts @{ Name = $name; Publisher = (($ref.Repository -split '/')[0]); SourceUrl = $(if ($src -match '^https://') { $src } else { "https://$($ref.Registry)/$($ref.Repository)" }); SourceKind = 'registry'; SourceKindLabel = $ref.Registry; Upstream = $src
          License = [string](Get-AsProp $cfg.Labels 'org.opencontainers.image.licenses' ''); Description = [string](Get-AsProp $cfg.Labels 'org.opencontainers.image.description' ''); Architectures = $cfg.Platforms; Documents = @(); Evidence = @(); Notes = @() }
      }
    }
    { $_ -in 'github-repo', 'github-file' } { $m = Import-GitHubSource $k $k.Url $DockerInvoker }
    'unraid-xml' { $m = Import-UnraidSource $k $k.Url $DockerInvoker }
    'directory' { $m = Import-DirectorySource $k $k.Url $DockerInvoker }
    'unraid-ca' { throw $k.Note }
    default {
      # A web address that is not a supported source: say exactly why (unsupported host, plain http, private address).
      if ($k.Url -match '^[a-z]+:') { $chk = Test-ImportUrl -Url $k.Url -SkipDns; if (-not $chk.Ok) { throw $chk.Reason } }
      throw 'Paste a Docker Hub, GitHub, Compose-file, Unraid template (.xml) or awesome-selfhosted link, or an image name such as ghcr.io/owner/app:1.0.'
    }
  }
  # A curated recipe for the same application wins (highest trust); the user may still keep the import.
  $match = $null
  if (@($CatalogApps).Count) {
    foreach ($ref in @($m.name, $m.id, ([string]$m.source.upstream -replace '^.*/', ''))) {
      if (-not $ref) { continue }
      $key = ($ref.ToLowerInvariant() -replace '[^a-z0-9]', '')
      $hit = @($CatalogApps | Where-Object { $_.manifest -and (([string]$_.id -replace '[^a-z0-9]', '') -eq $key -or @(@(Get-AsProp $_.manifest 'aliases' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() -replace '[^a-z0-9]', '' }) -contains $key -or (([string]$_.manifest.name).ToLowerInvariant() -replace '[^a-z0-9]', '') -eq $key) })
      if ($hit.Count) { $match = [ordered]@{ id = $hit[0].id; name = [string]$hit[0].manifest.name; installable = [bool](Get-AsProp $hit[0].manifest 'installable' $false) }; break }
    }
  }
  return [pscustomobject]@{ Manifest = $m; Kind = $k.Kind; CatalogMatch = $match }
}

Export-ModuleMember -Function ConvertTo-AppId, ConvertTo-InputId, Get-AppSourceKind, ConvertTo-ImageReference, Get-RegistryToken, Get-RegistryImageFacts, ConvertFrom-ComposeText, ConvertFrom-EnvExample,
  Get-ComposeVariables, Resolve-ComposeDefaults, Get-ImageRole, Split-CommandLine, ConvertFrom-ComposeModel, ConvertFrom-SafeXml, ConvertFrom-UnraidTemplate, ConvertTo-PlainObject, ConvertFrom-DirectoryYaml,
  Get-CategoryFromHints, New-NormalizedManifest, ConvertTo-OrderedTree, Set-DraftWebPort, Complete-ImportedImages, Find-MarkdownCompose, Select-ImageTag, Import-DockerHubSource, Import-GitHubSource, Import-UnraidSource, Import-DirectorySource, Import-AppSource
