#requires -version 5.1
# Portable configuration backups: export, import, restore and protected recovery points.
#
# - A backup is a versioned JSON manifest (format traefik-proxy-config, schemaVersion 1) of one instance: instance
#   settings, Docker names, Cloudflare account / zone / tunnel / DNS record / Access application ids, public
#   hostnames, routes, middlewares, service definitions and the public dashboard settings. The .zip variant adds the
#   instance's configuration files and an inventory.
# - Only this instance's install folder is read, so other applications, other Traefik instances and other projects
#   are never packaged. Credentials (API token, tunnel connector token, anything under secrets\) are never exported:
#   every exported text is scanned for credential patterns and for the stored tokens themselves, and an import that
#   contains something credential-like is refused. The manifest lists which credentials must be reconnected.
# - A restore is planned first (read-only) and applied in two separately approved parts: local configuration files
#   (plus a Traefik reload), and Cloudflare. Recorded Cloudflare ids are verified (existence, account ownership)
#   before they are adopted; resources are created only when missing, existing DNS records are only replaced after
#   a per-record confirmation, and an existing Access application is reused rather than duplicated.
# - Package files (compose.yaml, security.yml, dashboard.yml, scripts) always come from the installed manager, so a
#   backup made with an older manager can be restored after an upgrade.
# - Before configuration changes, a protected recovery point (a backup .zip, read-only, restricted ACL) is written
#   to backups\recovery\.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'TraefikProxy.psm1')
Import-Module (Join-Path $PSScriptRoot 'CloudflareApi.psm1')
Import-Module (Join-Path $PSScriptRoot 'Dashboard.psm1')
Add-Type -AssemblyName System.IO.Compression

$script:Format = 'traefik-proxy-config'
$script:SchemaVersion = 1
$script:InstanceKeys = @('STACK_NAME', 'TRAEFIK_HTTP_PORT', 'TRAEFIK_DASHBOARD_PORT', 'PROXY_NETWORK', 'TUNNEL_SUBNET', 'TUNNEL_IP_RANGE', 'CLOUDFLARED_IP')
$script:EnvKeys = $script:InstanceKeys + @('TRAEFIK_LOG_LEVEL', 'TRAEFIK_READ_TIMEOUT')
$script:EnvValuePattern = '^[A-Za-z0-9_./:-]{1,64}$'
$script:MaxImportBytes = 2MB
$script:MaxArchiveBytes = 8MB
$script:MaxArchiveEntries = 200
# traefik\dynamic files that come from the manager package (never restored from a backup) or are generated.
$script:PackageDynamicFiles = @('security.yml', 'dashboard.yml')
$script:ConfigFiles = @('config\services.json', 'config\cloudflare.json', 'config\setup.json', 'config\dashboard.json')
$script:CustomFilePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.ya?ml$'
$script:EmailPattern = '^[A-Za-z0-9._%+''-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,63}$'
$script:HostnamePattern = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Credential-shaped text. Exports containing a match are refused; imports containing one are rejected.
$script:CredentialPatterns = [ordered]@{
  'a Cloudflare tunnel token or JWT'   = 'eyJ[A-Za-z0-9_-]{20,}'
  'a bearer token'                     = '(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{20,}'
  'an encrypted (DPAPI) secret'        = '"data"\s*:\s*"[A-Za-z0-9+/=]{200,}"'
  'a token, key, secret or password'   = '(?i)(api[_-]?token|api[_-]?key|tunnel[_-]?token|secret|password|passwd)["'']?\s*[:=]\s*["'']?[A-Za-z0-9._~+/=-]{16,}'
  'a private key'                      = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
}

function Get-Prop($Object, [string]$Name, $Default = $null) { return Get-ServiceProperty $Object $Name $Default }

# The name of the first credential pattern found in $Text, or $null.
function Find-CredentialPattern([string]$Text) {
  if (-not $Text) { return $null }
  foreach ($k in $script:CredentialPatterns.Keys) { if ($Text -match $script:CredentialPatterns[$k]) { return $k } }
  return $null
}

# Throws when $Text contains a credential pattern, the stored API token or the tunnel connector token.
function Assert-CredentialFree($Settings, [string]$Text, [string]$What) {
  $hit = Find-CredentialPattern $Text
  if ($hit) { throw "Export refused: $What contains what looks like $hit. Remove it, then export again." }
  if (Test-TextContainsApiToken -Settings $Settings -Text $Text) { throw "Export refused: $What contains the stored Cloudflare API token." }
  $tunnelFile = Join-Path $Settings.InstallPath 'secrets\cloudflare_tunnel_token'
  if (Test-Path -LiteralPath $tunnelFile) {
    $t = ([IO.File]::ReadAllText($tunnelFile)).Trim()
    $found = $t -and $Text.Contains($t)
    $t = $null
    if ($found) { throw "Export refused: $What contains the tunnel connector token." }
  }
}

# --- Setup draft (config\setup.json) -----------------------------------------------------------------------------

function Read-SetupDraftFile([string]$InstallPath) {
  $draft = [pscustomobject][ordered]@{ version = 1; settings = $null; deployment = [pscustomobject][ordered]@{ mode = ''; tunnelChoice = ''; tunnelId = ''; tunnelName = ''; newTunnelName = '' }; contactEmail = ''; installedAt = '' }
  $path = Join-Path $InstallPath 'config\setup.json'
  if (-not (Test-Path -LiteralPath $path)) { return $draft }
  try {
    $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($json.PSObject.Properties['settings'] -and $json.settings) { $draft.settings = $json.settings }
    if ($json.PSObject.Properties['deployment'] -and $json.deployment) {
      foreach ($p in $draft.deployment.PSObject.Properties.Name) { if ($json.deployment.PSObject.Properties[$p]) { $draft.deployment.$p = [string]$json.deployment.$p } }
    }
    if ($json.PSObject.Properties['installedAt']) { $draft.installedAt = [string]$json.installedAt }
    if ($json.PSObject.Properties['contactEmail']) { $draft.contactEmail = [string]$json.contactEmail }
  } catch { }
  return $draft
}

function ConvertTo-SetupDraftJson($Draft) { return (ConvertTo-Json -InputObject $Draft -Depth 5) + "`n" }

# --- Export ------------------------------------------------------------------------------------------------------

function Get-CredentialInventory($Settings) {
  $token = Get-CloudflareApiTokenInfo -Settings $Settings
  return @(
    [ordered]@{
      id = 'cloudflare-api-token'; label = 'Cloudflare API token'; file = 'secrets\cloudflare_api.dpapi'; present = [bool]$token.Stored; included = $false
      recover = 'Not exported (it is encrypted for one Windows account on one PC anyway). Reconnect it on Setup > Connect Cloudflare: paste the token you saved, or create a new one with the same permissions and revoke the old one.'
    }
    [ordered]@{
      id = 'tunnel-connector-token'; label = 'Tunnel connector token'; file = 'secrets\cloudflare_tunnel_token'; present = [bool](Test-TunnelTokenFile $Settings); included = $false
      recover = 'Not exported. It is downloaded again from Cloudflare for the same tunnel during installation (Setup > Review and install) or on the Cloudflare page, using the API token. Without automation: Zero Trust > Networks > Tunnels > (tunnel) > Configure, then install.ps1 -SetTunnelToken.'
    }
  )
}

# The portable manifest of one instance (no credentials, no file contents).
function Get-ConfigManifest {
  param([Parameter(Mandatory = $true)]$Settings, [string]$SourceRoot)
  $root = $Settings.InstallPath
  $envValues = Read-DotEnv (Join-Path $root '.env')
  $installed = Test-Path -LiteralPath (Join-Path $root 'compose.yaml')
  $instance = [ordered]@{}
  if ($envValues.Count -gt 0) {
    foreach ($k in $script:EnvKeys) { if ($envValues.ContainsKey($k)) { $instance[$k] = [string]$envValues[$k] } }
  }
  $omitted = @($envValues.Keys | Where-Object { $script:EnvKeys -notcontains $_ } | Sort-Object)
  $draft = Read-SetupDraftFile $root
  if ($envValues.Count -eq 0) {
    $v = ConvertTo-InstanceValues $Settings
    foreach ($k in $script:EnvKeys) {
      if ($v.Contains($k)) { $instance[$k] = $v[$k] }
      elseif ($draft.settings -and $draft.settings.PSObject.Properties[$k] -and $draft.settings.$k) { $instance[$k] = [string]$draft.settings.$k }
    }
  }
  $mode = $draft.deployment.mode
  if (-not $mode -and $installed) { $mode = $(if (Test-TunnelTokenFile $Settings) { 'tunnel' } else { 'local' }) }
  $cf = Read-CloudflareConfig -Settings $Settings
  $registry = Read-ServiceRegistry -Settings $Settings
  $dash = Read-DashboardConfig -Settings $Settings
  $hostnames = @(foreach ($p in $cf.managed.PSObject.Properties) {
      [ordered]@{
        hostname = $p.Name; service = [string](Get-Prop $p.Value 'service' ''); dnsRecordId = [string](Get-Prop $p.Value 'dnsRecordId' '')
        accessAppId = [string](Get-Prop $p.Value 'accessAppId' ''); accessEmails = @(Get-ManagedAccessEmails $cf $p.Name)
      }
    })
  $dynamic = @()
  if (Test-Path -LiteralPath $Settings.DynamicDir) { $dynamic = @(Get-ChildItem -LiteralPath $Settings.DynamicDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' } | ForEach-Object { $_.Name } | Sort-Object) }
  $custom = @($dynamic | Where-Object { $script:PackageDynamicFiles -notcontains $_ -and -not $_.StartsWith('svc-') -and $_ -ne (Get-DashboardRouteFile) })
  $compose = Join-Path $root 'compose.yaml'
  if (-not (Test-Path -LiteralPath $compose) -and $SourceRoot) { $compose = Join-Path $SourceRoot 'compose.yaml' }
  return [ordered]@{
    format         = $script:Format
    schemaVersion  = $script:SchemaVersion
    managerVersion = Get-ManagerVersion
    createdAt      = (Get-Date -Format 's')
    source         = [ordered]@{ installPath = $root; installed = $installed; stackName = $Settings.StackName }
    instance       = $instance
    omittedEnvKeys = $omitted
    deployment     = [ordered]@{ mode = $mode; tunnelId = $cf.tunnelId; tunnelName = $cf.tunnelName; installedAt = $draft.installedAt }
    docker         = [ordered]@{
      composeProject = $Settings.StackName
      containers     = [ordered]@{ traefik = $Settings.TraefikContainer; socketProxy = $Settings.SocketProxyContainer; cloudflared = $Settings.CloudflaredContainer }
      networks       = [ordered]@{ proxy = $Settings.ProxyNetwork; tunnel = $Settings.TunnelNetwork; tunnelSubnet = $Settings.TunnelSubnet; cloudflaredIp = $Settings.CloudflaredIp }
      ports          = [ordered]@{ http = "127.0.0.1:$($Settings.HttpPort)"; dashboard = "127.0.0.1:$($Settings.DashboardPort)" }
      images         = Get-ComposeImages $compose
    }
    cloudflare     = [ordered]@{
      accountId = $cf.accountId; accountName = $cf.accountName; tunnelId = $cf.tunnelId; tunnelName = $cf.tunnelName
      domains = @($cf.domains | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; accountId = $_.accountId } })
      hostnames = $hostnames
    }
    services       = @($registry.services)
    routes         = @($registry.services | Where-Object { $_.enabled } | ForEach-Object {
        [ordered]@{ service = $_.name; file = "traefik/dynamic/$(Get-ServiceFileName $_.name)"; rule = (Get-ServiceRule $_); entryPoints = @('web'); backend = (Get-ServiceUrl $_); middlewares = @($_.middlewares) } })
    middlewares    = [ordered]@{ available = @(Get-AvailableMiddlewares $Settings | ForEach-Object { "$_@file" }); customFiles = $custom }
    dashboard      = [ordered]@{
      enabled = [bool]$dash.enabled; subdomain = $dash.subdomain; zoneId = $dash.zoneId; zoneName = $dash.zoneName; hostname = $dash.hostname
      accessEmails = @($dash.accessEmails); localUrl = "http://127.0.0.1:$($Settings.DashboardPort)/dashboard/"
    }
    credentials    = @(Get-CredentialInventory $Settings)
  }
}

function ConvertTo-ManifestJson($Manifest) { return (ConvertTo-StableJson $Manifest) + "`n" }

function Get-BackupBaseName($Settings) { return "traefik-proxy-$($Settings.StackName)-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }

# The JSON manifest export. Refused when anything credential-like would be included.
function Export-ConfigManifest {
  param([Parameter(Mandatory = $true)]$Settings, [string]$SourceRoot)
  $json = ConvertTo-ManifestJson (Get-ConfigManifest -Settings $Settings -SourceRoot $SourceRoot)
  Assert-CredentialFree $Settings $json 'The configuration manifest'
  return [pscustomobject]@{ FileName = (Get-BackupBaseName $Settings) + '.json'; Text = $json }
}

# .env with only the known, non-secret keys (comments kept).
function Get-FilteredEnv([string]$Path) {
  $lines = @(foreach ($line in [IO.File]::ReadAllLines($Path)) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') { if ($script:EnvKeys -contains $Matches[1]) { $line } }
      else { $line }
    })
  return ($lines -join "`n").TrimEnd() + "`n"
}

# The full backup: manifest.json, INVENTORY.txt and files\... (this instance's configuration files only).
function New-ConfigBackupArchive {
  param([Parameter(Mandatory = $true)]$Settings, [string]$SourceRoot, [string]$Reason = 'export')
  $root = $Settings.InstallPath
  $manifest = Get-ConfigManifest -Settings $Settings -SourceRoot $SourceRoot
  $files = New-Object System.Collections.ArrayList
  $excluded = New-Object System.Collections.ArrayList
  $candidates = @()
  if (Test-Path -LiteralPath (Join-Path $root '.env')) { $candidates += '.env' }
  foreach ($rel in $script:ConfigFiles) { if (Test-Path -LiteralPath (Join-Path $root $rel)) { $candidates += $rel } }
  if (Test-Path -LiteralPath $Settings.DynamicDir) {
    foreach ($f in Get-ChildItem -LiteralPath $Settings.DynamicDir -File | Where-Object { $_.Extension -in '.yml', '.yaml' } | Sort-Object Name) { $candidates += "traefik\dynamic\$($f.Name)" }
  }
  foreach ($rel in $candidates) {
    $full = Join-Path $root $rel
    $text = if ($rel -eq '.env') { Get-FilteredEnv $full } else { ([IO.File]::ReadAllText($full)).Replace("`r`n", "`n") }
    $purpose = switch -Wildcard ($rel) {
      '.env' { 'Instance settings (only the known keys; other keys are left out)' }
      'config\services.json' { 'Service registry (proxied applications)' }
      'config\cloudflare.json' { 'Cloudflare selections and the ids of resources this tool created' }
      'config\setup.json' { 'Setup wizard choices' }
      'config\dashboard.json' { 'Public dashboard settings' }
      'traefik\dynamic\svc-*' { 'Generated route (regenerated from the service registry on restore)' }
      'traefik\dynamic\admin-dashboard.yml' { 'Generated public dashboard route (written again only after Access is confirmed)' }
      'traefik\dynamic\security.yml' { 'Package file (comes from the installed manager on restore)' }
      'traefik\dynamic\dashboard.yml' { 'Package file (comes from the installed manager on restore)' }
      default { 'Hand-written Traefik configuration (restored if missing or different)' }
    }
    $hit = Find-CredentialPattern $text
    if (-not $hit -and (Test-TextContainsApiToken -Settings $Settings -Text $text)) { $hit = 'the stored API token' }
    if ($hit) { $null = $excluded.Add([ordered]@{ path = $rel; reason = "Left out: it contains what looks like $hit." }); continue }
    $null = $files.Add([pscustomobject][ordered]@{ path = 'files/' + $rel.Replace('\', '/'); source = $rel; bytes = $script:Utf8NoBom.GetByteCount($text); sha256 = (Get-TextSha256 $text); purpose = $purpose; Text = $text })
  }
  foreach ($dir in @('secrets', 'logs', 'backups')) {
    $d = Join-Path $root $dir
    if (Test-Path -LiteralPath $d) {
      $reason = @{ secrets = 'Credentials are never exported; reconnect them after a restore (see credentials).'; logs = 'Logs are not configuration.'; backups = 'Earlier backups are not included.' }[$dir]
      $null = $excluded.Add([ordered]@{ path = "$dir\"; reason = $reason })
    }
  }
  $manifest['archive'] = [ordered]@{
    reason = $Reason
    files = @($files | ForEach-Object { [ordered]@{ path = $_.path; source = $_.source; bytes = $_.bytes; sha256 = $_.sha256; purpose = $_.purpose } })
    excluded = @($excluded)
  }
  $manifestJson = ConvertTo-ManifestJson $manifest
  Assert-CredentialFree $Settings $manifestJson 'The configuration manifest'
  foreach ($f in $files) { Assert-CredentialFree $Settings $f.Text $f.source }

  $inv = New-Object System.Collections.Generic.List[string]
  $inv.Add("Traefik proxy configuration backup of instance '$($Settings.StackName)'")
  $inv.Add("Created $($manifest.createdAt) by manager $($manifest.managerVersion) from $root (schema $($script:SchemaVersion)).")
  $inv.Add('')
  $inv.Add('manifest.json      Portable manifest: settings, Docker names, Cloudflare ids, hostnames, routes, services.')
  foreach ($f in $files) { $inv.Add(('{0,-44} {1,7} bytes  {2}' -f $f.path, $f.bytes, $f.purpose)) }
  $inv.Add('')
  $inv.Add('Not included:')
  foreach ($e in $excluded) { $inv.Add("  $($e.path)  $($e.reason)") }
  $inv.Add('')
  $inv.Add('Credentials to reconnect after a restore:')
  foreach ($c in $manifest.credentials) { $inv.Add("  $($c.label): $($c.recover)") }
  $inventory = ($inv -join "`n") + "`n"

  $ms = New-Object System.IO.MemoryStream
  $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
  try {
    $entries = @([pscustomobject]@{ Name = 'manifest.json'; Text = $manifestJson }, [pscustomobject]@{ Name = 'INVENTORY.txt'; Text = $inventory }) + @($files | ForEach-Object { [pscustomobject]@{ Name = $_.path; Text = $_.Text } })
    foreach ($e in $entries) {
      $entry = $zip.CreateEntry($e.Name, [System.IO.Compression.CompressionLevel]::Optimal)
      $w = New-Object System.IO.StreamWriter($entry.Open(), $script:Utf8NoBom)
      $w.Write($e.Text); $w.Dispose()
    }
  } finally { $zip.Dispose() }
  return [pscustomobject]@{ FileName = (Get-BackupBaseName $Settings) + '.zip'; Bytes = $ms.ToArray(); Manifest = $manifest; Excluded = @($excluded) }
}

# --- Import ------------------------------------------------------------------------------------------------------

function Get-ManifestStrings($Object, [string]$Name) { return @(@(Get-Prop $Object $Name @()) | ForEach-Object { [string]$_ } | Where-Object { $_ }) }

# Fills in defaults and checks every field of a manifest (any schema-1 manifest, also hand-edited ones).
function ConvertTo-NormalizedManifest($Raw, [System.Collections.ArrayList]$Errors, [System.Collections.ArrayList]$Warnings) {
  $instance = [ordered]@{}
  $rawInstance = Get-Prop $Raw 'instance' $null
  foreach ($k in $script:EnvKeys) {
    $v = [string](Get-Prop $rawInstance $k '')
    if (-not $v) { continue }
    if ($v -notmatch $script:EnvValuePattern) { $null = $Errors.Add("Instance setting $k has characters that are not allowed."); continue }
    $instance[$k] = $v
  }
  $dep = Get-Prop $Raw 'deployment' $null
  $mode = [string](Get-Prop $dep 'mode' '')
  if ($mode -and $mode -notin @('tunnel', 'local')) { $null = $Warnings.Add("Unknown deployment mode '$mode' ignored."); $mode = '' }
  $cfRaw = Get-Prop $Raw 'cloudflare' $null
  $cf = [ordered]@{ accountId = [string](Get-Prop $cfRaw 'accountId' ''); accountName = [string](Get-Prop $cfRaw 'accountName' ''); tunnelId = [string](Get-Prop $cfRaw 'tunnelId' ''); tunnelName = [string](Get-Prop $cfRaw 'tunnelName' ''); domains = @(); hostnames = @() }
  foreach ($k in @('accountId', 'tunnelId')) { if ($cf[$k] -and -not (Test-CloudflareId $cf[$k])) { $null = $Errors.Add("cloudflare.$k is not a valid Cloudflare id."); $cf[$k] = '' } }
  if ($cf.accountName.Length -gt 200) { $cf.accountName = $cf.accountName.Substring(0, 200) }
  if ($cf.tunnelName -and $cf.tunnelName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { $null = $Warnings.Add('cloudflare.tunnelName is not a valid tunnel name and was ignored.'); $cf.tunnelName = '' }
  $cf.domains = @(foreach ($d in @(Get-Prop $cfRaw 'domains' @())) {
      $id = [string](Get-Prop $d 'id' ''); $name = ([string](Get-Prop $d 'name' '')).ToLowerInvariant()
      if (-not (Test-CloudflareId $id) -or $name -notmatch $script:HostnamePattern) { $null = $Errors.Add("Allowed domain '$name' has an invalid id or name."); continue }
      [pscustomobject][ordered]@{ id = $id; name = $name; accountId = [string](Get-Prop $d 'accountId' '') }
    })
  $cf.hostnames = @(foreach ($h in @(Get-Prop $cfRaw 'hostnames' @())) {
      $name = ([string](Get-Prop $h 'hostname' '')).ToLowerInvariant()
      if ($name -notmatch $script:HostnamePattern) { $null = $Errors.Add("Hostname '$name' is not valid."); continue }
      $dns = [string](Get-Prop $h 'dnsRecordId' ''); $app = [string](Get-Prop $h 'accessAppId' '')
      if ($dns -and -not (Test-CloudflareId $dns)) { $null = $Warnings.Add("DNS record id of $name ignored (invalid)."); $dns = '' }
      if ($app -and -not (Test-CloudflareId $app)) { $null = $Warnings.Add("Access application id of $name ignored (invalid)."); $app = '' }
      $emails = @(Get-ManifestStrings $h 'accessEmails' | Where-Object { $_ -match $script:EmailPattern })
      [pscustomobject][ordered]@{ hostname = $name; service = [string](Get-Prop $h 'service' ''); dnsRecordId = $dns; accessAppId = $app; accessEmails = $emails }
    })
  $services = @(foreach ($s in @(Get-Prop $Raw 'services' @())) { ConvertTo-ServiceDefinition $s })
  if ($services.Count -gt 500) { $null = $Errors.Add('Too many services (more than 500).') }
  $dashRaw = Get-Prop $Raw 'dashboard' $null
  $dash = [ordered]@{
    enabled = [bool](Get-Prop $dashRaw 'enabled' $false); subdomain = ([string](Get-Prop $dashRaw 'subdomain' '')).ToLowerInvariant(); zoneId = [string](Get-Prop $dashRaw 'zoneId' '')
    zoneName = ([string](Get-Prop $dashRaw 'zoneName' '')).ToLowerInvariant(); hostname = ([string](Get-Prop $dashRaw 'hostname' '')).ToLowerInvariant()
    accessEmails = @(Get-ManifestStrings $dashRaw 'accessEmails' | Where-Object { $_ -match $script:EmailPattern })
  }
  if ($dash.hostname -and ($dash.hostname -notmatch $script:HostnamePattern -or -not (Test-DashboardSubdomain $dash.subdomain) -or -not (Test-CloudflareId $dash.zoneId) -or $dash.hostname -ne "$($dash.subdomain).$($dash.zoneName)")) {
    $null = $Warnings.Add('The public dashboard settings are inconsistent and were ignored.')
    $dash = [ordered]@{ enabled = $false; subdomain = ''; zoneId = ''; zoneName = ''; hostname = ''; accessEmails = @() }
  }
  return [pscustomobject][ordered]@{
    format = $script:Format; schemaVersion = [int](Get-Prop $Raw 'schemaVersion' $script:SchemaVersion); managerVersion = [string](Get-Prop $Raw 'managerVersion' '')
    createdAt = [string](Get-Prop $Raw 'createdAt' ''); sourceStackName = [string](Get-Prop (Get-Prop $Raw 'source' $null) 'stackName' ([string](Get-Prop $rawInstance 'STACK_NAME' '')))
    instance = $instance; deployment = [ordered]@{ mode = $mode }; cloudflare = $cf; services = $services; dashboard = $dash
    customFiles = @(Get-ManifestStrings (Get-Prop $Raw 'middlewares' $null) 'customFiles')
  }
}

# Reads an uploaded backup (.json manifest, .zip archive, or a plain config\services.json from an older version).
# Returns Kind, Manifest (normalized), Files (custom traefik\dynamic files from a zip), Errors, Warnings, Sha256.
# Errors make the backup unusable; nothing is written here.
function Read-ConfigBackup {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes, [string]$FileName = '')
  $errors = New-Object System.Collections.ArrayList
  $warnings = New-Object System.Collections.ArrayList
  $result = [ordered]@{ Kind = ''; FileName = $FileName; Manifest = $null; Files = @{}; Errors = $errors; Warnings = $warnings; Sha256 = '' }
  $sha = [Security.Cryptography.SHA256]::Create()
  $result.Sha256 = [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '')
  if ($Bytes.Length -eq 0) { $null = $errors.Add('The file is empty.'); return [pscustomobject]$result }
  if ($Bytes.Length -gt $script:MaxImportBytes) { $null = $errors.Add('The file is larger than 2 MB; a configuration backup is much smaller.'); return [pscustomobject]$result }
  $texts = [ordered]@{}
  $manifestText = $null
  if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x50 -and $Bytes[1] -eq 0x4B -and $Bytes[2] -eq 3 -and $Bytes[3] -eq 4) {
    $result.Kind = 'zip'
    try {
      $zip = New-Object System.IO.Compression.ZipArchive((New-Object System.IO.MemoryStream(, $Bytes)), [System.IO.Compression.ZipArchiveMode]::Read)
      try {
        if ($zip.Entries.Count -gt $script:MaxArchiveEntries) { throw 'The archive has too many entries.' }
        $total = 0
        foreach ($e in $zip.Entries) {
          if ($e.FullName.EndsWith('/')) { continue }
          if ($e.FullName -notmatch '^[A-Za-z0-9._/-]{1,200}$' -or $e.FullName -match '(^|/)\.\.(/|$)' -or $e.FullName.StartsWith('/')) { throw "Unexpected file name in the archive: $($e.FullName)" }
          $total += $e.Length
          if ($total -gt $script:MaxArchiveBytes) { throw 'The archive expands to more than 8 MB.' }
          $r = New-Object System.IO.StreamReader($e.Open(), $script:Utf8NoBom)
          $texts[$e.FullName] = $r.ReadToEnd(); $r.Dispose()
        }
      } finally { $zip.Dispose() }
    } catch { $null = $errors.Add('The .zip file cannot be read: ' + $_.Exception.Message); return [pscustomobject]$result }
    if (-not $texts.Contains('manifest.json')) { $null = $errors.Add('The archive has no manifest.json; it is not a backup made by this tool.'); return [pscustomobject]$result }
    $manifestText = $texts['manifest.json']
  } else {
    $manifestText = $script:Utf8NoBom.GetString($Bytes).TrimStart([char]0xFEFF)
    $texts['(file)'] = $manifestText
  }
  foreach ($k in $texts.Keys) {
    $hit = Find-CredentialPattern $texts[$k]
    if ($hit) { $null = $errors.Add("The backup was not imported: $(if ($k -eq '(file)') { 'it' } else { $k }) contains what looks like $hit. Backups made by this tool never contain credentials."); return [pscustomobject]$result }
  }
  $raw = $null
  try { $raw = $manifestText | ConvertFrom-Json } catch { $null = $errors.Add('The file is not valid JSON.'); return [pscustomobject]$result }
  if ($null -eq $raw -or $raw -isnot [System.Management.Automation.PSCustomObject]) { $null = $errors.Add('The file is not a configuration backup.'); return [pscustomobject]$result }
  $format = [string](Get-Prop $raw 'format' '')
  if ($format -eq $script:Format) {
    if (-not $result.Kind) { $result.Kind = 'json' }
    $version = 0
    if (-not [int]::TryParse([string](Get-Prop $raw 'schemaVersion' ''), [ref]$version) -or $version -lt 1) { $null = $errors.Add('The backup has no valid schemaVersion.'); return [pscustomobject]$result }
    if ($version -gt $script:SchemaVersion) {
      $null = $errors.Add("The backup was made by a newer manager (schema $version, manager $([string](Get-Prop $raw 'managerVersion' '?'))). This manager reads schema $($script:SchemaVersion); update it first.")
      return [pscustomobject]$result
    }
  } elseif (-not $format -and $raw.PSObject.Properties['services'] -and -not $raw.PSObject.Properties['instance']) {
    # config\services.json of any earlier version: service definitions only.
    $result.Kind = 'legacy-services'
    $null = $warnings.Add('This is a plain service registry (config\services.json), not a full backup: only the service definitions are restored.')
    $raw = [pscustomobject]@{ format = $script:Format; schemaVersion = 0; services = @($raw.services) }
  } else {
    $null = $errors.Add("This is not a traefik-proxy configuration backup (format '$format').")
    return [pscustomobject]$result
  }
  $result.Manifest = ConvertTo-NormalizedManifest $raw $errors $warnings
  foreach ($k in $texts.Keys) {
    if ($k -notmatch '^files/traefik/dynamic/([^/]+)$') { continue }
    $name = $Matches[1]
    if ($name -notmatch $script:CustomFilePattern -or $script:PackageDynamicFiles -contains $name -or $name.StartsWith('svc-') -or $name -eq (Get-DashboardRouteFile)) { continue }
    $result.Files[$name] = $texts[$k].Replace("`r`n", "`n")
  }
  return [pscustomobject]$result
}

# Middleware names defined in YAML text (same parser as the installed files).
function Get-MiddlewareNamesFromText([string]$Text) {
  $names = @(); $inBlock = $false
  foreach ($line in ($Text -split "`n")) {
    if ($line -match '^  middlewares:\s*$') { $inBlock = $true; continue }
    if ($inBlock -and $line -match '^  \S') { $inBlock = $false }
    if ($inBlock -and $line -match '^    ([A-Za-z0-9-]+):\s*$') { $names += $Matches[1] }
  }
  return $names
}

# --- Restore plan ------------------------------------------------------------------------------------------------

function New-RestoreItem([string]$Area, [string]$Action, [string]$Summary, [string]$Detail = '', $Diff = @()) {
  return [pscustomobject][ordered]@{ area = $Area; action = $Action; summary = $Summary; detail = $Detail; diff = @($Diff) }
}

# Read-only plan for restoring $Backup into the instance $Settings. $AccessEmails are used when an Access application
# has to be created and the backup does not record who may sign in.
function Get-RestorePlan {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Backup, [string]$SourceRoot, [string[]]$AccessEmails = @())
  $m = $Backup.Manifest
  $root = $Settings.InstallPath
  $installed = Test-Path -LiteralPath (Join-Path $root 'compose.yaml')
  $legacy = $Backup.Kind -eq 'legacy-services'
  $items = New-Object System.Collections.ArrayList
  $localErrors = New-Object System.Collections.ArrayList
  $actionsNeeded = New-Object System.Collections.ArrayList
  $writes = [ordered]@{}

  # Verification of the recorded Cloudflare ids (read-only; needs a stored API token).
  $check = $null
  if (-not $legacy -and ($m.cloudflare.accountId -or @($m.cloudflare.domains).Count -gt 0)) {
    $check = Get-CloudflareResourceCheck -Settings $Settings -AccountId $m.cloudflare.accountId -TunnelId $m.cloudflare.tunnelId -Domains $m.cloudflare.domains -Hostnames $m.cloudflare.hostnames
  }
  $stateOf = { param($x) if ($null -eq $x) { 'unverified' } else { $x.state } }
  $acctState = if ($check -and $check.Connected) { & $stateOf $check.Account } else { 'unverified' }
  $tunnelState = if ($check -and $check.Connected) { & $stateOf $check.Tunnel } else { 'unverified' }

  # 1. Instance settings.
  $envPath = Join-Path $root '.env'
  $hasEnv = Test-Path -LiteralPath $envPath
  $mInstance = @{}; foreach ($k in $m.instance.Keys) { $mInstance[$k] = $m.instance[$k] }
  if ($legacy) { }
  elseif ($hasEnv) {
    $cur = Read-DotEnv $envPath
    $diff = @(foreach ($k in $script:InstanceKeys) { if ($mInstance.ContainsKey($k) -and [string]$cur[$k] -ne $mInstance[$k]) { "$k is $($cur[$k]) here, $($mInstance[$k]) in the backup" } })
    if ($diff.Count -eq 0) { $null = $items.Add((New-RestoreItem 'instance' 'unchanged' "Instance settings match ($($Settings.StackName))")) }
    else {
      $null = $items.Add((New-RestoreItem 'instance' 'keep' 'Instance settings differ; the installed .env is kept' (($diff -join '; ') + '. To recreate the backup''s instance as it was, restore into a new install folder.')))
    }
  } else {
    $missing = @($script:InstanceKeys | Where-Object { -not $mInstance.ContainsKey($_) })
    if ($missing.Count -gt 0) { $null = $localErrors.Add('The backup lacks instance settings: ' + ($missing -join ', ')) }
    else {
      try {
        $restored = ConvertTo-StackSettings -InstallPath $root -Values $mInstance
        $errs = @(Test-StackSettings $restored)
        if ($errs.Count -gt 0) { $null = $localErrors.Add('Instance settings in the backup are invalid: ' + ($errs -join ' ')) }
        else {
          $draft = Read-SetupDraftFile $root
          $old = ConvertTo-SetupDraftJson $draft
          $values = ConvertTo-InstanceValues $restored
          foreach ($k in $script:EnvKeys) { if (-not $values.Contains($k) -and $mInstance.ContainsKey($k)) { $values[$k] = $mInstance[$k] } }
          $draft.settings = [pscustomobject]$values
          $d = $draft.deployment
          $d.mode = $m.deployment.mode
          if ($d.mode -eq 'tunnel') {
            if ($m.cloudflare.tunnelId -and $tunnelState -in @('verified', 'unverified', 'unknown')) {
              $d.tunnelChoice = 'existing'; $d.tunnelId = $m.cloudflare.tunnelId; $d.tunnelName = $m.cloudflare.tunnelName; $d.newTunnelName = ''
            } else {
              $d.tunnelChoice = ''; $d.tunnelId = ''; $d.tunnelName = ''
              $null = $actionsNeeded.Add('The backup''s tunnel cannot be reused; choose or create a tunnel in Setup step 4 before installing.')
            }
          }
          $new = ConvertTo-SetupDraftJson $draft
          if ($new -ne $old) {
            $writes['config\setup.json'] = $new
            $null = $items.Add((New-RestoreItem 'instance' $(if (Test-Path -LiteralPath (Join-Path $root 'config\setup.json')) { 'update' } else { 'create' }) "Setup choices: instance '$($restored.StackName)'$(if ($d.mode) { ", $($d.mode) mode" })$(if ($d.tunnelId) { ", tunnel $($d.tunnelName)" })" 'Written as the setup draft. Install it on the Setup page (step 7, Review and install); nothing is started by the restore.' (Get-LineDiff $old $new)))
          } else { $null = $items.Add((New-RestoreItem 'instance' 'unchanged' 'Setup choices already match the backup')) }
          foreach ($c in @(Get-StackConflicts -Settings $restored | Where-Object { $_.Level -eq 'error' })) { $null = $actionsNeeded.Add("Before installing: $($c.Message)") }
        }
      } catch { $null = $localErrors.Add('Instance settings in the backup are invalid: ' + $_.Exception.Message) }
    }
  }

  # 2. Cloudflare selections and verified resource ids.
  $current = Read-CloudflareConfig -Settings $Settings
  $merged = [pscustomobject][ordered]@{ version = 1; accountId = $current.accountId; accountName = $current.accountName; tunnelId = $current.tunnelId; tunnelName = $current.tunnelName; domains = @($current.domains); managed = [pscustomobject]@{} }
  foreach ($p in $current.managed.PSObject.Properties) { $merged.managed | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
  $cfConflict = $false
  if (-not $legacy -and $m.cloudflare.accountId) {
    if (-not $current.accountId) {
      if ($acctState -in @('verified', 'unverified', 'unknown')) { $merged.accountId = $m.cloudflare.accountId; $merged.accountName = $m.cloudflare.accountName }
    } elseif ($current.accountId -ne $m.cloudflare.accountId) {
      $cfConflict = $true
      $null = $items.Add((New-RestoreItem 'cloudflare' 'keep' 'This instance uses another Cloudflare account; its selections are kept' "Here: $($current.accountName). Backup: $($m.cloudflare.accountName). Cloudflare resources are not restored."))
    }
    if (-not $cfConflict -and $m.cloudflare.tunnelId) {
      if (-not $current.tunnelId) {
        if ($tunnelState -in @('verified', 'unverified', 'unknown')) { $merged.tunnelId = $m.cloudflare.tunnelId; $merged.tunnelName = $m.cloudflare.tunnelName }
      } elseif ($current.tunnelId -ne $m.cloudflare.tunnelId) {
        $cfConflict = $true
        $null = $items.Add((New-RestoreItem 'cloudflare' 'keep' 'This instance uses another tunnel; it is kept' "Here: $($current.tunnelName). Backup: $($m.cloudflare.tunnelName). Cloudflare resources are not restored."))
      }
    }
    if (-not $cfConflict) {
      $domainState = @{}
      if ($check -and $check.Connected) { foreach ($d in $check.Domains) { $domainState[$d.id] = $d.state } }
      $ids = @($merged.domains | ForEach-Object { $_.id })
      foreach ($d in $m.cloudflare.domains) {
        $st = if ($domainState.ContainsKey($d.id)) { $domainState[$d.id] } else { 'unverified' }
        if ($ids -notcontains $d.id -and $st -in @('verified', 'unverified', 'unknown')) { $merged.domains = @($merged.domains) + $d; $ids += $d.id }
      }
      $unverified = 0
      foreach ($h in $m.cloudflare.hostnames) {
        if ($merged.managed.PSObject.Properties[$h.hostname]) { continue }
        $hc = $null; if ($check -and $check.Connected) { $hc = @($check.Hostnames | Where-Object { $_.hostname -eq $h.hostname })[0] }
        $dns = ''; $app = ''
        if ($hc -and $hc.dns.state -eq 'verified') { $dns = $h.dnsRecordId }
        if ($hc -and $hc.access.state -eq 'verified') { $app = $h.accessAppId }
        if (-not $hc -and ($h.dnsRecordId -or $h.accessAppId)) { $unverified++ }
        if ($dns -or $app) {
          $merged.managed | Add-Member -NotePropertyName $h.hostname -NotePropertyValue ([pscustomobject][ordered]@{ service = $h.service; dnsRecordId = $dns; accessAppId = $app; accessEmails = @($h.accessEmails) })
        }
      }
      if ($unverified -gt 0) { $null = $actionsNeeded.Add("$unverified recorded Cloudflare resource id(s) were not adopted because Cloudflare is not connected. Connect Cloudflare, then preview this restore again to verify and adopt them.") }
    }
    $oldCf = ConvertTo-StableJson $current
    $newCf = ConvertTo-StableJson $merged
    if ($oldCf -ne $newCf) {
      $writes['config\cloudflare.json'] = $merged
      $null = $items.Add((New-RestoreItem 'cloudflare' $(if (Test-Path -LiteralPath (Join-Path $root 'config\cloudflare.json')) { 'update' } else { 'create' }) 'Cloudflare selections: account, tunnel, allowed domains and verified resource ids' 'Only ids that were verified in Cloudflare are adopted (they allow this tool to clean up those resources later).' (Get-LineDiff $oldCf $newCf)))
    } elseif (-not $cfConflict) { $null = $items.Add((New-RestoreItem 'cloudflare' 'unchanged' 'Cloudflare selections already match the backup')) }
  }

  # 3. Hand-written Traefik files from a .zip (added or updated, never deleted).
  $customWrites = @{}
  foreach ($name in @($Backup.Files.Keys | Sort-Object)) {
    $path = Join-Path $Settings.DynamicDir $name
    $old = if (Test-Path -LiteralPath $path) { ([IO.File]::ReadAllText($path)).Replace("`r`n", "`n") } else { $null }
    $new = $Backup.Files[$name]
    if ($old -eq $new) { $null = $items.Add((New-RestoreItem 'traefik' 'unchanged' "traefik\dynamic\$name")); continue }
    $customWrites[$name] = $new
    $null = $items.Add((New-RestoreItem 'traefik' $(if ($null -eq $old) { 'create' } else { 'update' }) "traefik\dynamic\$name (hand-written)" '' (Get-LineDiff $old $new)))
  }
  foreach ($name in @($m.customFiles | Where-Object { -not $Backup.Files.ContainsKey($_) -and -not (Test-Path -LiteralPath (Join-Path $Settings.DynamicDir $_)) })) {
    $null = $actionsNeeded.Add("The backup's instance had the hand-written file traefik\dynamic\$name, which is not in this backup (use the .zip backup, or copy it by hand).")
  }
  # Package files (security.yml, ...) that the installer copies later count as present, for validation only.
  $packageFiles = @{}
  if ($SourceRoot) {
    foreach ($name in $script:PackageDynamicFiles) {
      $from = Join-Path $SourceRoot "traefik\dynamic\$name"
      if (-not (Test-Path -LiteralPath (Join-Path $Settings.DynamicDir $name)) -and (Test-Path -LiteralPath $from)) { $packageFiles[$name] = ([IO.File]::ReadAllText($from)).Replace("`r`n", "`n") }
    }
  }
  $extraMw = @(@($customWrites.Values) + @($packageFiles.Values) | ForEach-Object { Get-MiddlewareNamesFromText $_ })

  # 4. Service registry and generated routes.
  $servicePlan = Get-ServicePlan -Settings $Settings -Services @($m.services) -ExtraMiddlewares $extraMw
  foreach ($i in @($servicePlan.Issues | Where-Object { $_.Level -eq 'Error' })) { $null = $localErrors.Add("Service $($i.Service): $($i.Message)") }
  if ($servicePlan.RegistryChanged) {
    $oldReg = if (Test-Path -LiteralPath $Settings.RegistryPath) { ([IO.File]::ReadAllText($Settings.RegistryPath)).Replace("`r`n", "`n") } else { $null }
    $null = $items.Add((New-RestoreItem 'services' $(if ($null -eq $oldReg) { 'create' } else { 'update' }) "Service registry: $(@($m.services).Count) service(s)" 'Services that are not in the backup are removed from Traefik; their Cloudflare records are left as they are.' (Get-LineDiff $oldReg $servicePlan.RegistryJson)))
  } else { $null = $items.Add((New-RestoreItem 'services' 'unchanged' "Service registry already matches ($(@($m.services).Count) service(s))")) }
  foreach ($c in @($servicePlan.Changes | Where-Object { $_.Action -ne 'unchanged' })) {
    $null = $items.Add((New-RestoreItem 'traefik' $(@{ add = 'create'; update = 'update'; remove = 'delete' }[$c.Action]) "traefik\dynamic\$($c.File)" "Generated route of service '$($c.Service)'." (Get-LineDiff $c.OldContent $c.NewContent)))
  }

  # 5. Public dashboard settings (the route itself is written in the Cloudflare part, after Access is confirmed).
  $dash = Read-DashboardConfig -Settings $Settings
  $md = $m.dashboard
  if ($md.hostname) {
    if ($dash.enabled -and $dash.hostname -eq $md.hostname) { $null = $items.Add((New-RestoreItem 'dashboard' 'unchanged' "Public dashboard $($md.hostname) is already set up")) }
    elseif ($dash.enabled) { $null = $items.Add((New-RestoreItem 'dashboard' 'keep' "This instance publishes its dashboard as $($dash.hostname); kept" "The backup used $($md.hostname).")) }
    elseif ($dash.hostname -ne $md.hostname -or $dash.subdomain -ne $md.subdomain -or $dash.zoneId -ne $md.zoneId -or (@($dash.accessEmails) -join ',') -ne (@($md.accessEmails) -join ',')) {
      $newDash = [pscustomobject][ordered]@{ version = 1; enabled = $false; subdomain = $md.subdomain; subdomainCustom = $true; zoneId = $md.zoneId; zoneName = $md.zoneName; hostname = $md.hostname; accessEmails = @($md.accessEmails); publish = $true; enabledAt = '' }
      $writes['config\dashboard.json'] = $newDash
      $null = $items.Add((New-RestoreItem 'dashboard' 'create' "Public dashboard settings: $($md.hostname)" 'Saved as settings only. The dashboard is published in the Cloudflare part of the restore (or on the Setup page) after Cloudflare Access is confirmed.'))
    }
  }

  $dynamicChanges = ($customWrites.Count -gt 0) -or $servicePlan.FileChanges -gt 0
  if ($installed -and $dynamicChanges) { $null = $items.Add((New-RestoreItem 'docker' 'update' 'Reload Traefik''s file provider (no container restart)' 'Done only if this instance''s Traefik is running.')) }
  $localWork = @($items | Where-Object { $_.action -in @('create', 'update', 'delete') }).Count -gt 0
  $keyParts = @(@($writes.Keys | ForEach-Object { "$_=$(if ($writes[$_] -is [string]) { $writes[$_] } else { ConvertTo-StableJson $writes[$_] })" }) + @($customWrites.Keys | Sort-Object | ForEach-Object { "$_=$($customWrites[$_])" }) + $servicePlan.RegistryJson + @($servicePlan.Changes | ForEach-Object { "$($_.File):$($_.Action):$($_.OldContent)" }))
  $local = [pscustomobject][ordered]@{
    Items = $items.ToArray(); Errors = $localErrors.ToArray(); Writes = $writes; CustomWrites = $customWrites; ServicePlan = $servicePlan
    HasWork = $localWork; CanApply = ($localWork -and $localErrors.Count -eq 0); Key = (Get-TextSha256 ($keyParts -join "`n"))
    ExtraMiddlewares = $extraMw; PackageFiles = $packageFiles
  }

  # 6. Cloudflare part: what is missing in Cloudflare for the backup's published hostnames and dashboard.
  $cloud = [ordered]@{ Connected = $false; Message = ''; Check = $check; ServicePlans = @(); DashboardPlan = $null; Actions = @(); Errors = @(); Notes = @(); HasWork = $false; CanApply = $false; NeedsLocal = $false; Fingerprint = '' }
  if ($legacy) { $cloud.Message = 'A plain service registry has no Cloudflare information.' }
  elseif (-not $m.cloudflare.accountId) { $cloud.Message = 'The backup has no Cloudflare configuration.' }
  elseif (-not $check -or -not $check.Connected) { $cloud.Message = 'Connect Cloudflare (Setup > Connect Cloudflare) to verify and restore the Cloudflare resources.' }
  elseif ($cfConflict) { $cloud.Message = 'This instance is connected to another Cloudflare account or tunnel, so Cloudflare resources are not restored.' }
  elseif ($acctState -ne 'verified') { $cloud.Message = $check.Account.message }
  elseif ($tunnelState -ne 'verified') { $cloud.Message = $(if ($check.Tunnel) { $check.Tunnel.message } else { 'The backup has no tunnel.' }) + ' Tunnels are never recreated automatically; choose or create one on the Cloudflare page.' }
  else {
    $cloud.Connected = $true
    $cloud.NeedsLocal = ($current.accountId -ne $m.cloudflare.accountId -or $current.tunnelId -ne $m.cloudflare.tunnelId)
    $published = @($m.services | Where-Object { $_.enabled -and $_.cloudflare.publish })
    $pseudo = @(); if ($md.hostname) { $pseudo = @(Get-DashboardPseudoService $Settings $md.hostname) }
    $fingerprints = @()
    foreach ($s in $published) {
      $others = @(@($m.services | Where-Object { $_.name -ne $s.name }) + $pseudo)
      $emails = @(@($m.cloudflare.hostnames | Where-Object { @($s.hostnames) -contains $_.hostname } | ForEach-Object { @($_.accessEmails) }) + @($AccessEmails) | Where-Object { $_ } | Select-Object -Unique)
      try {
        $p = Get-CloudflareServicePlan -Settings $Settings -Service $s -OtherServices $others -AccessEmails $emails -Config $merged
        $cloud.ServicePlans += [pscustomobject]@{ Service = $s.name; Plan = $p }
        $fingerprints += $p.Fingerprint
        $cloud.Errors += @($p.Errors | ForEach-Object { "$($s.name): $_" })
        $cloud.Notes += @($p.Notes)
        $cloud.Actions += @($p.Actions | ForEach-Object { [pscustomobject][ordered]@{ service = $s.name; id = $_.Id; step = $_.Step; kind = $_.Kind; hostname = $_.Hostname; summary = $_.Summary; detail = $_.Detail; overwrite = $_.Overwrite } })
      } catch { $cloud.Errors += "$($s.name): Cloudflare could not be read: $($_.Exception.Message)" }
    }
    if ($md.hostname -and $md.enabled) {
      if (-not $installed) { $null = $actionsNeeded.Add("Public dashboard $($md.hostname): install the instance first, then publish it on the Setup page.") }
      elseif ($dash.enabled -and $dash.hostname -ne $md.hostname) { }
      else {
        $emails = @(@($md.accessEmails) + @($AccessEmails) | Where-Object { $_ } | Select-Object -Unique)
        $dp = Get-DashboardPlan -Settings $Settings -Subdomain $md.subdomain -ZoneId $md.zoneId -AccessEmails $emails -Services @($m.services) -CloudflareConfig $merged
        $cloud.DashboardPlan = $dp
        $fingerprints += $dp.Key
        $cloud.Errors += @($dp.Errors | ForEach-Object { "Public dashboard: $_" })
        if ($dp.FileAction -ne 'unchanged') { $cloud.Actions += [pscustomobject][ordered]@{ service = 'traefik-dashboard'; id = "route:$($dp.Hostname)"; step = 'route'; kind = 'create'; hostname = $dp.Hostname; summary = "Write the public dashboard route for $($dp.Hostname) (after Access is confirmed)"; detail = 'traefik\dynamic\admin-dashboard.yml'; overwrite = $false } }
        if ($dp.Cloudflare) { $cloud.Actions += @($dp.Cloudflare.Actions | ForEach-Object { [pscustomobject][ordered]@{ service = 'traefik-dashboard'; id = $_.Id; step = $_.Step; kind = $_.Kind; hostname = $_.Hostname; summary = $_.Summary; detail = $_.Detail; overwrite = $_.Overwrite } }) }
      }
    }
    $cloud.HasWork = @($cloud.Actions | Where-Object { $_.kind -notin @('none', 'blocked') }).Count -gt 0
    $cloud.CanApply = $cloud.HasWork -and @($cloud.Errors).Count -eq 0
    $cloud.Fingerprint = Get-TextSha256 ($fingerprints -join '|')
  }

  return [pscustomobject][ordered]@{
    Installed = $installed; Legacy = $legacy; Local = $local; Cloudflare = [pscustomobject]$cloud; ActionsNeeded = $actionsNeeded.ToArray()
    Credentials = @(Get-CredentialInventory $Settings)
  }
}

# Writes the local part of a restore plan (configuration files, then a Traefik reload). Docker containers are not
# started or recreated. Returns steps (name, status, message).
function Invoke-RestoreLocal {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Plan)
  $local = $Plan.Local
  if (@($local.Errors).Count -gt 0) { throw 'The restore has errors; nothing was changed.' }
  $steps = New-Object System.Collections.ArrayList
  $add = { param($Name, $Status, $Message) $null = $steps.Add([pscustomobject][ordered]@{ name = $Name; status = $Status; message = $Message }) }
  $sp = $local.ServicePlan
  $dynamic = ($local.CustomWrites.Count -gt 0) -or $sp.FileChanges -gt 0
  if ($dynamic -and (Test-DockerEngine)) {
    $stageFiles = @{} + $local.PackageFiles
    foreach ($k in $local.CustomWrites.Keys) { $stageFiles[$k] = $local.CustomWrites[$k] }
    $deep = Test-TraefikDynamicConfig -Settings $Settings -Plan $sp -ExtraFiles $stageFiles
    if (-not $deep.Ok) {
      & $add 'Validate the restored routes in a throwaway Traefik container' 'Failed' (@($deep.Errors) -join ' | ')
      return [pscustomobject]@{ Ok = $false; Steps = $steps.ToArray() }
    }
    & $add 'Validate the restored routes in a throwaway Traefik container' 'Done' "$(@($deep.Routers).Count) generated router(s) accepted."
  } elseif ($dynamic) { & $add 'Validate the restored routes in a throwaway Traefik container' 'Warning' 'Docker is not running; only the built-in checks were made.' }
  foreach ($rel in $local.Writes.Keys) {
    $value = $local.Writes[$rel]
    $path = Join-Path $Settings.InstallPath $rel
    if ($rel -eq 'config\cloudflare.json') { Save-CloudflareConfig -Settings $Settings -Config $value }
    elseif ($rel -eq 'config\dashboard.json') { Save-DashboardConfig -Settings $Settings -Config $value }
    else { Write-TextFileAtomic $path $value }
    & $add "Write $rel" 'Done' ''
  }
  foreach ($name in @($local.CustomWrites.Keys | Sort-Object)) {
    Write-TextFileAtomic (Join-Path $Settings.DynamicDir $name) $local.CustomWrites[$name]
    & $add "Write traefik\dynamic\$name" 'Done' ''
  }
  if ($sp.FileChanges -gt 0 -or $sp.RegistryChanged) {
    $applied = Invoke-ServicePlan -Settings $Settings -Plan $sp -NoReload
    & $add 'Write the service registry and routes' 'Done' $(if ($applied.Backup) { "Previous state saved as $(Split-Path -Leaf $applied.Backup)." } else { '' })
  }
  if ($dynamic -and (Test-Path -LiteralPath (Join-Path $Settings.InstallPath 'compose.yaml')) -and (Test-ContainerRunning $Settings.TraefikContainer)) {
    $w = Sync-TraefikDynamic $Settings
    if ($w) { & $add 'Reload Traefik' 'Warning' $w } else {
      $wait = Wait-ServiceRouters -Settings $Settings -Services $sp.Services
      if ($wait.Ok) { & $add 'Reload Traefik' 'Done' 'Every enabled service route is loaded.' } else { & $add 'Reload Traefik' 'Warning' ('Not loaded yet: ' + ($wait.Missing -join ', ')) }
    }
  }
  return [pscustomobject]@{ Ok = (@($steps | Where-Object { $_.status -eq 'Failed' }).Count -eq 0); Steps = $steps.ToArray() }
}

# Runs the Cloudflare part of a restore plan. Needs the local part applied first (account and tunnel selected).
# Stops at the first failure. Returns steps.
function Invoke-RestoreCloudflare {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Plan, [string[]]$ConfirmedOverwrites = @())
  $cloud = $Plan.Cloudflare
  if (-not $cloud.Connected) { throw 'Cloudflare is not ready for this restore: ' + $cloud.Message }
  if ($cloud.NeedsLocal) { throw 'Apply the local configuration first (it selects the Cloudflare account and tunnel).' }
  if (@($cloud.Errors).Count -gt 0) { throw 'The Cloudflare part has blocking problems; nothing was changed in Cloudflare.' }
  $steps = New-Object System.Collections.ArrayList
  $ok = $true
  foreach ($sp in $cloud.ServicePlans) {
    foreach ($r in @(Invoke-CloudflareServicePlan -Settings $Settings -Plan $sp.Plan -ServiceName $sp.Service -ConfirmedOverwrites $ConfirmedOverwrites)) {
      if ($r.Status -eq 'Unchanged') { continue }
      $null = $steps.Add([pscustomobject][ordered]@{ name = $r.Summary; status = $r.Status; message = $r.Message })
      if ($r.Status -eq 'Failed') { $ok = $false }
    }
    if (-not $ok) { break }
  }
  $dp = $cloud.DashboardPlan
  if ($ok -and $dp -and ($dp.FileAction -ne 'unchanged' -or @($dp.Cloudflare.Actions | Where-Object { $_.Kind -ne 'none' }).Count -gt 0)) {
    $r = Invoke-DashboardPlan -Settings $Settings -Plan $dp -ConfirmedOverwrites $ConfirmedOverwrites
    foreach ($s in $r.Steps) { $null = $steps.Add($s) }
    if (-not $r.Ok) { $ok = $false }
  }
  return [pscustomobject]@{ Ok = $ok; Steps = $steps.ToArray() }
}

# --- Recovery points -----------------------------------------------------------------------------------------------

function Get-RecoveryDir($Settings) { return (Join-Path $Settings.BackupRoot 'recovery') }

# A protected backup of the current configuration, written before a change: backups\recovery\<time>-<reason>.zip,
# read-only, readable by this user, SYSTEM and Administrators only. Never deleted automatically. Returns its id.
function New-RecoveryPoint {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Reason, [string]$SourceRoot)
  if (-not (Test-Path -LiteralPath $Settings.InstallPath)) { return $null }
  $slug = ($Reason.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
  if (-not $slug) { $slug = 'change' }
  $archive = New-ConfigBackupArchive -Settings $Settings -SourceRoot $SourceRoot -Reason $Reason
  $dir = Get-RecoveryDir $Settings
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $id = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$slug.zip"
  $path = Join-Path $dir $id
  [IO.File]::WriteAllBytes($path, $archive.Bytes)
  Set-SecretFileAcl $path
  (Get-Item -LiteralPath $path).IsReadOnly = $true
  return $id
}

function Get-RecoveryPoints {
  param([Parameter(Mandatory = $true)]$Settings)
  $dir = Get-RecoveryDir $Settings
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -File -Filter '*.zip' | Where-Object { $_.Name -match '^(\d{8})-(\d{6})-\d{3}-([a-z0-9-]+)\.zip$' } | Sort-Object Name -Descending | ForEach-Object {
      $null = $_.Name -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-\d{3}-([a-z0-9-]+)\.zip$'
      [pscustomobject][ordered]@{ id = $_.Name; createdAt = "$($Matches[1])-$($Matches[2])-$($Matches[3])T$($Matches[4]):$($Matches[5]):$($Matches[6])"; reason = $Matches[7].Replace('-', ' '); bytes = $_.Length; protected = $_.IsReadOnly }
    })
}

function Get-RecoveryPointBytes {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Id)
  if ($Id -notmatch '^\d{8}-\d{6}-\d{3}-[a-z0-9-]+\.zip$') { throw "Invalid recovery point id '$Id'." }
  $path = Join-Path (Get-RecoveryDir $Settings) $Id
  if (-not (Test-Path -LiteralPath $path)) { throw "No recovery point '$Id'." }
  # The comma keeps PowerShell from unrolling the byte array into the pipeline.
  return , [IO.File]::ReadAllBytes($path)
}

Export-ModuleMember -Function Find-CredentialPattern, Get-FilteredEnv, Read-SetupDraftFile, ConvertTo-SetupDraftJson, Get-CredentialInventory, Get-ConfigManifest, ConvertTo-ManifestJson,
  Export-ConfigManifest, New-ConfigBackupArchive, Read-ConfigBackup, Get-RestorePlan, Invoke-RestoreLocal, Invoke-RestoreCloudflare, New-RecoveryPoint,
  Get-RecoveryPoints, Get-RecoveryPointBytes
