#requires -version 5.1
# Cloudflare API access for the web UI (and anything else that wants to automate DNS / Tunnel / Access).
#
# - The scoped API token is stored encrypted with Windows DPAPI (CurrentUser scope) in
#   secrets\cloudflare_api.dpapi. Only the Windows account that saved it can decrypt it. It is decrypted per
#   request and never returned by any function in this module.
# - Non-secret selections (account, tunnel, which records/apps this tool created) live in config\cloudflare.json.
# - Changes are always planned first (Get-CloudflareServicePlan). A plan lists every create / update / delete
#   with its reason; existing records that would be overwritten are flagged so the caller can demand explicit
#   confirmation. Invoke-CloudflareServicePlan executes a plan, Access first (so a hostname is protected before
#   it resolves), then the tunnel route, then DNS. Nothing here deletes a resource this tool did not create,
#   except tunnel ingress rules and CNAMEs that point at this instance's own tunnel.
Set-StrictMode -Version 2.0

$script:DefaultApiBase = 'https://api.cloudflare.com/client/v4'
$script:ApiBase = $script:DefaultApiBase
$script:SecretFile = 'secrets\cloudflare_api.dpapi'
$script:ConfigFile = 'config\cloudflare.json'
$script:Entropy = [Text.Encoding]::UTF8.GetBytes('traefik-proxy/cloudflare-api-token/v1')
# What cloudflared forwards every published hostname to (the Traefik service on the instance's tunnel network).
$script:OriginService = 'http://traefik:80'
$script:ManagedComment = 'Managed by traefik-proxy'
Add-Type -AssemblyName System.Security
# Token-file, ACL and atomic-write helpers.
Import-Module (Join-Path $PSScriptRoot 'TraefikProxy.psm1')

# --- API endpoint --------------------------------------------------------------------------------------------

# The API base can only be changed to Cloudflare itself or to a loopback mock (tests). It is never taken from
# browser input, so a token cannot be sent anywhere else.
function Set-CloudflareApiBase([string]$Url) {
  if (-not $Url) { $script:ApiBase = $script:DefaultApiBase; return }
  if ($Url -notmatch '^(https://api\.cloudflare\.com/client/v4|http://127\.0\.0\.1:\d{1,5}(/[A-Za-z0-9/_-]*)?)$') {
    throw "Refusing Cloudflare API base '$Url': only https://api.cloudflare.com/client/v4 or a http://127.0.0.1 test mock are allowed."
  }
  $script:ApiBase = $Url.TrimEnd('/')
}

function Get-CloudflareApiBase { return $script:ApiBase }

# --- Token storage (DPAPI, CurrentUser) ---------------------------------------------------------------------

function Get-CloudflareSecretPath($Settings) { return (Join-Path $Settings.InstallPath $script:SecretFile) }

function Test-CloudflareApiToken([string]$Token) {
  # Cloudflare API tokens are opaque; reject obvious junk (spaces, quotes, very short/long strings).
  return ($Token -match '^[A-Za-z0-9._~+/=-]{30,400}$')
}

function Save-CloudflareApiToken {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Token)
  $Token = $Token.Trim()
  if (-not (Test-CloudflareApiToken $Token)) { throw 'That does not look like a Cloudflare API token.' }
  $path = Get-CloudflareSecretPath $Settings
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  $cipher = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Token), $script:Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  $doc = [ordered]@{ version = 1; scope = 'DPAPI-CurrentUser'; user = "$env:USERDOMAIN\$env:USERNAME"; savedAt = (Get-Date -Format 's'); data = [Convert]::ToBase64String($cipher) }
  $tmp = $path + '.tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Compress))
  Move-Item -LiteralPath $tmp -Destination $path -Force
  Set-SecretFileAcl $path
}

function Remove-CloudflareApiToken {
  param([Parameter(Mandatory = $true)]$Settings)
  $path = Get-CloudflareSecretPath $Settings
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; return $true }
  return $false
}

# Metadata only (never the token).
function Get-CloudflareApiTokenInfo {
  param([Parameter(Mandatory = $true)]$Settings)
  $path = Get-CloudflareSecretPath $Settings
  if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Stored = $false; SavedAt = ''; User = ''; Readable = $false } }
  $readable = $true
  try { $null = Read-CloudflareApiToken $Settings } catch { $readable = $false }
  $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json
  return [pscustomobject]@{ Stored = $true; SavedAt = [string]$doc.savedAt; User = [string]$doc.user; Readable = $readable }
}

# Not exported: the plaintext token never leaves this module.
function Read-CloudflareApiToken($Settings) {
  $path = Get-CloudflareSecretPath $Settings
  if (-not (Test-Path -LiteralPath $path)) { throw 'No Cloudflare API token is stored. Add one on the Cloudflare page.' }
  $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json
  try {
    $plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($doc.data), $script:Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  } catch {
    throw 'The stored Cloudflare API token cannot be decrypted by this Windows account (it was saved by another user or machine). Save it again.'
  }
  return [Text.Encoding]::UTF8.GetString($plain)
}

# --- Non-secret configuration --------------------------------------------------------------------------------

function Read-CloudflareConfig {
  param([Parameter(Mandatory = $true)]$Settings)
  $path = Join-Path $Settings.InstallPath $script:ConfigFile
  $config = [pscustomobject][ordered]@{ version = 1; accountId = ''; accountName = ''; tunnelId = ''; tunnelName = ''; managed = [pscustomobject]@{} }
  if (Test-Path -LiteralPath $path) {
    $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    foreach ($p in @('accountId', 'accountName', 'tunnelId', 'tunnelName')) { if ($json.PSObject.Properties[$p] -and $json.$p) { $config.$p = [string]$json.$p } }
    if ($json.PSObject.Properties['managed'] -and $json.managed) { $config.managed = $json.managed }
  }
  return $config
}

function Save-CloudflareConfig {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Config)
  Write-TextFileAtomic (Join-Path $Settings.InstallPath $script:ConfigFile) ((ConvertTo-Json -InputObject $Config -Depth 6) + "`n")
}

function Set-ManagedResource($Config, [string]$Hostname, [string]$Field, [string]$Value, [string]$Service) {
  $entry = $null
  if ($Config.managed.PSObject.Properties[$Hostname]) { $entry = $Config.managed.$Hostname }
  if (-not $entry) {
    $entry = [pscustomobject][ordered]@{ service = $Service; dnsRecordId = ''; accessAppId = '' }
    $Config.managed | Add-Member -NotePropertyName $Hostname -NotePropertyValue $entry -Force
  }
  if ($Service) { $entry.service = $Service }
  $entry.$Field = $Value
  if (-not $entry.dnsRecordId -and -not $entry.accessAppId) { $Config.managed.PSObject.Properties.Remove($Hostname) }
}

function Get-ManagedResource($Config, [string]$Hostname, [string]$Field) {
  if ($Config.managed.PSObject.Properties[$Hostname]) { return [string]$Config.managed.$Hostname.$Field }
  return ''
}

# --- HTTP client -----------------------------------------------------------------------------------------------

# Calls the Cloudflare v4 API and returns the parsed envelope's result (all pages with -All).
# Throws "Cloudflare API: <METHOD> <path>: <message>" on failure; the token never appears in messages.
function Invoke-CloudflareApi {
  param(
    [Parameter(Mandatory = $true)]$Settings,
    [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
    [Parameter(Mandatory = $true)][string]$Path,
    [hashtable]$Query = @{},
    $Body,
    [switch]$All,
    [string]$Token
  )
  if (-not $Token) { $Token = Read-CloudflareApiToken $Settings }
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $results = New-Object System.Collections.ArrayList
  $page = 1
  while ($true) {
    $q = @{} + $Query
    if ($All) { $q['page'] = $page; if (-not $q.ContainsKey('per_page')) { $q['per_page'] = 50 } }
    $qs = (@($q.Keys | Sort-Object | ForEach-Object { [Uri]::EscapeDataString($_) + '=' + [Uri]::EscapeDataString([string]$q[$_]) })) -join '&'
    $url = $script:ApiBase + $Path + $(if ($qs) { '?' + $qs } else { '' })
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = $Method
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.Accept = 'application/json'
    $request.UserAgent = 'traefik-proxy-webui/1'
    $request.AllowAutoRedirect = $false
    $request.Headers.Add('Authorization', 'Bearer ' + $Token)
    if ($null -ne $Body) {
      $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      $request.ContentType = 'application/json'
      $request.ContentLength = $bytes.Length
      $rs = $request.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
    }
    $response = $null
    try { $response = $request.GetResponse() }
    catch {
      $ex = $_.Exception
      while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
      if ($ex -and $ex.Response) { $response = $ex.Response }
      else { throw "Cloudflare API: $Method ${Path}: cannot reach $($script:ApiBase) ($($_.Exception.Message))" }
    }
    $status = [int]$response.StatusCode
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd(); $reader.Close(); $response.Close()
    $envelope = $null
    try { $envelope = $text | ConvertFrom-Json } catch { }
    if (-not $envelope -or -not $envelope.PSObject.Properties['success'] -or -not $envelope.success) {
      $messages = @()
      if ($envelope -and $envelope.PSObject.Properties['errors']) { $messages = @($envelope.errors | ForEach-Object { "$($_.message) (code $($_.code))" }) }
      if ($messages.Count -eq 0) { $messages = @("HTTP $status") }
      $err = "Cloudflare API: $Method ${Path}: " + ($messages -join '; ')
      if ($status -eq 403 -or $status -eq 401) { $err += ' - check that the API token has the required permissions (see the Cloudflare page).' }
      throw $err
    }
    if (-not $All) { return $envelope.result }
    foreach ($item in @($envelope.result)) { if ($null -ne $item) { $null = $results.Add($item) } }
    $totalPages = 1
    if ($envelope.PSObject.Properties['result_info'] -and $envelope.result_info -and $envelope.result_info.PSObject.Properties['total_pages']) { $totalPages = [int]$envelope.result_info.total_pages }
    if ($page -ge $totalPages -or $page -ge 40) { break }
    $page++
  }
  return $results.ToArray()
}

# --- Read-only lookups ---------------------------------------------------------------------------------------------

# Verifies a token (stored, or a candidate one before saving) and lists what it can see.
function Test-CloudflareToken {
  param([Parameter(Mandatory = $true)]$Settings, [string]$Token)
  $result = [ordered]@{ Valid = $false; Status = ''; Message = ''; Accounts = @(); Zones = @() }
  try {
    $verify = Invoke-CloudflareApi -Settings $Settings -Path '/user/tokens/verify' -Token $Token
    $result.Status = [string]$verify.status
  } catch {
    # Account-owned tokens cannot use /user/tokens/verify; listing accounts still proves the token works.
    $result.Message = $_.Exception.Message
  }
  try {
    $result.Accounts = @(Invoke-CloudflareApi -Settings $Settings -Path '/accounts' -All -Token $Token | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name } })
    $result.Zones = @(Invoke-CloudflareApi -Settings $Settings -Path '/zones' -All -Token $Token | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; status = [string]$_.status; accountId = [string]$_.account.id } })
    $result.Valid = ($result.Status -eq 'active') -or ($result.Accounts.Count -gt 0)
    if ($result.Valid) { $result.Message = '' }
  } catch {
    if (-not $result.Message) { $result.Message = $_.Exception.Message }
    if ($result.Status -eq 'active') { $result.Valid = $true; $result.Message = 'Token is active but cannot list accounts/zones: ' + $_.Exception.Message }
  }
  if (-not $result.Valid -and $result.Status -and $result.Status -ne 'active') { $result.Message = "Token status is '$($result.Status)'." }
  return [pscustomobject]$result
}

function Get-CloudflareZones {
  param([Parameter(Mandatory = $true)]$Settings, [string]$AccountId)
  $query = @{}
  if ($AccountId) { $query['account.id'] = $AccountId }
  return @(Invoke-CloudflareApi -Settings $Settings -Path '/zones' -Query $query -All | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; status = [string]$_.status } })
}

function Get-CloudflareTunnels {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$AccountId)
  return @(Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$AccountId/cfd_tunnel" -Query @{ is_deleted = 'false' } -All | ForEach-Object {
      [pscustomobject]@{
        id = [string]$_.id; name = [string]$_.name; status = [string]$_.status
        remotelyManaged = ($_.PSObject.Properties['remote_config'] -and [bool]$_.remote_config) -or ($_.PSObject.Properties['config_src'] -and $_.config_src -eq 'cloudflare')
        connections = @($(if ($_.PSObject.Properties['connections']) { $_.connections } else { @() })).Count
      }
    })
}

function Test-CloudflareId([string]$Value) { return ($Value -match '^[A-Za-z0-9-]{8,64}$') }

# Finds the zone that a hostname belongs to (longest matching suffix).
function Find-CloudflareZone($Zones, [string]$Hostname) {
  $best = $null
  foreach ($z in $Zones) {
    if ($Hostname -eq $z.name -or $Hostname.EndsWith('.' + $z.name)) { if (-not $best -or $z.name.Length -gt $best.name.Length) { $best = $z } }
  }
  return $best
}

# --- Creating resources (callers must have the user's explicit confirmation) ------------------------------------

function New-CloudflareTunnel {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$AccountId, [Parameter(Mandatory = $true)][string]$Name)
  if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { throw 'Tunnel name: use letters, digits, dot, dash or underscore (max 63).' }
  $existing = @(Get-CloudflareTunnels -Settings $Settings -AccountId $AccountId | Where-Object { $_.name -eq $Name })
  if ($existing.Count -gt 0) { throw "A tunnel named '$Name' already exists; select it instead." }
  # Remotely managed: routes are configured through the API / dashboard, cloudflared only needs the token.
  $t = Invoke-CloudflareApi -Settings $Settings -Method POST -Path "/accounts/$AccountId/cfd_tunnel" -Body @{ name = $Name; config_src = 'cloudflare' }
  return [pscustomobject]@{ id = [string]$t.id; name = [string]$t.name }
}

# Fetches the connector token of a tunnel and writes secrets\cloudflare_tunnel_token. The token is not returned.
function Install-CloudflareTunnelToken {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$AccountId, [Parameter(Mandatory = $true)][string]$TunnelId)
  $token = [string](Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId/token")
  $decoded = ConvertFrom-TunnelToken $token
  if (-not $decoded -or $decoded.TunnelId -ne $TunnelId) { throw 'Cloudflare returned an unexpected tunnel token.' }
  $other = Find-ConnectorForTunnel -Settings $Settings -TunnelId $TunnelId
  if ($other) { throw "Container '$other' already runs a connector for this tunnel. Use a separate tunnel for this instance; '$other' was left untouched." }
  $backup = Save-TunnelTokenFile -Settings $Settings -Token $token
  $token = $null
  return [pscustomobject]@{ TunnelId = $TunnelId; PreviousTokenBackup = $backup }
}

# --- Service plan ---------------------------------------------------------------------------------------------------

function New-CfAction([string]$Step, [string]$Kind, [string]$Hostname, [string]$Summary, [string]$Detail, [bool]$Overwrite, $Data) {
  return [pscustomobject][ordered]@{
    Id = "$Step`:$Hostname"; Step = $Step; Kind = $Kind; Hostname = $Hostname; Summary = $Summary; Detail = $Detail
    Overwrite = $Overwrite; Data = $Data
  }
}

function Get-PublishedHostnames($Service) {
  if ($null -eq $Service -or -not $Service.cloudflare.publish) { return @() }
  return @($Service.hostnames)
}

# Manual instructions, used when Cloudflare automation is not connected or not wanted.
function Get-CloudflareManualSteps($Service, [string]$TunnelId) {
  $steps = @()
  if ($null -eq $Service -or -not $Service.cloudflare.publish) { return $steps }
  foreach ($h in $Service.hostnames) {
    if ($Service.cloudflare.access) {
      $steps += "Zero Trust > Access > Applications > Add > Self-hosted: domain $h, with an Allow policy for the people who may use it. Do this first."
    }
    $steps += "Zero Trust > Networks > Tunnels > (this instance's tunnel) > Published application routes > Add: hostname $h, service type HTTP, URL traefik:80."
    $target = if ($TunnelId) { "$TunnelId.cfargotunnel.com" } else { '<tunnel-id>.cfargotunnel.com' }
    $steps += "The dashboard creates the DNS record automatically (CNAME $h -> $target, proxied)."
  }
  return $steps
}

# Computes the Cloudflare changes for one service change. Reads the live state; never writes.
#   $Service          new definition ($null when the service is removed)
#   $PreviousService  current definition ($null when the service is new)
#   $OtherServices    every other service in the new registry (hostnames they publish are never cleaned up)
#   $AccessEmails     who may log in, when an Access app has to be created
#   $Cleanup          remove DNS / tunnel routes / Access apps for hostnames this change stops publishing
function Get-CloudflareServicePlan {
  param(
    [Parameter(Mandatory = $true)]$Settings,
    $Service,
    $PreviousService,
    $OtherServices = @(),
    [string[]]$AccessEmails = @(),
    [switch]$Cleanup
  )
  $config = Read-CloudflareConfig -Settings $Settings
  $plan = [ordered]@{ Connected = $false; Actions = @(); Notes = @(); Errors = @(); ManualSteps = @(); Fingerprint = ''; TunnelId = $config.tunnelId; AccountId = $config.accountId; Ingress = $null; IngressChanged = $false; Config = $null }
  $tokenInfo = Get-CloudflareApiTokenInfo -Settings $Settings
  if (-not $tokenInfo.Stored -or -not $config.accountId -or -not $config.tunnelId) {
    $plan.Notes += 'Cloudflare automation is not set up (API token, account and tunnel on the Cloudflare page); only Traefik is changed.'
    $plan.ManualSteps = @(Get-CloudflareManualSteps $Service $config.tunnelId)
    return [pscustomobject]$plan
  }
  $plan.Connected = $true
  $acct = $config.accountId
  $tunnelTarget = "$($config.tunnelId).cfargotunnel.com"

  $publish = @(Get-PublishedHostnames $Service)
  $othersPublish = @($OtherServices | ForEach-Object { Get-PublishedHostnames $_ })
  $unpublish = @()
  if ($Cleanup) { $unpublish = @(Get-PublishedHostnames $PreviousService | Where-Object { $publish -notcontains $_ -and $othersPublish -notcontains $_ }) }
  if ($publish.Count -eq 0 -and $unpublish.Count -eq 0) {
    if ($Service -and -not $Service.cloudflare.publish) { $plan.Notes += 'Local only: nothing is published through Cloudflare.' }
    return [pscustomobject]$plan
  }

  $observed = [ordered]@{}
  $zones = @(Get-CloudflareZones -Settings $Settings)
  $tunnelConfig = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$acct/cfd_tunnel/$($config.tunnelId)/configurations"
  $cfg = $null
  if ($tunnelConfig -and $tunnelConfig.PSObject.Properties['config'] -and $tunnelConfig.config) { $cfg = $tunnelConfig.config }
  $ingress = New-Object System.Collections.ArrayList
  if ($cfg -and $cfg.PSObject.Properties['ingress'] -and $cfg.ingress) { foreach ($r in @($cfg.ingress)) { $null = $ingress.Add($r) } }
  $observed['ingress'] = $ingress.ToArray()
  $accessApps = @()
  $needAccess = $Service -and $Service.cloudflare.access -and $publish.Count -gt 0
  if ($needAccess -or $unpublish.Count -gt 0) { $accessApps = @(Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$acct/access/apps" -All) }
  $observed['accessApps'] = @($accessApps | ForEach-Object { "$($_.id)|$($_.domain)" })

  $hostRule = { param($h) @($ingress | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq $h -and -not ($_.PSObject.Properties['path'] -and $_.path) }) }
  $accessFor = { param($h) @($accessApps | Where-Object {
        ($_.PSObject.Properties['domain'] -and ($_.domain -eq $h -or $_.domain -like "$h/*")) -or
        ($_.PSObject.Properties['self_hosted_domains'] -and @($_.self_hosted_domains) -contains $h) }) }
  $actions = @()

  foreach ($h in $publish) {
    $zone = Find-CloudflareZone $zones $h
    if (-not $zone) {
      $actions += New-CfAction 'dns' 'blocked' $h "No Cloudflare zone for $h" "The API token cannot see a zone that $h belongs to. Add the domain to Cloudflare or give the token DNS:Edit on it." $false $null
      continue
    }
    # 1. Access
    if ($Service.cloudflare.access) {
      $apps = @(& $accessFor $h)
      if ($apps.Count -gt 0) {
        $actions += New-CfAction 'access' 'none' $h "Access app '$($apps[0].name)' already protects $h" '' $false $null
      } elseif (@($AccessEmails).Count -eq 0) {
        $actions += New-CfAction 'access' 'blocked' $h "Cloudflare Access for $h needs at least one allowed email" 'Enter the email addresses that may sign in, or turn off "Require Cloudflare Access" if the app has its own login.' $false $null
      } else {
        $body = [ordered]@{
          name = "$h ($($Settings.StackName))"; domain = $h; type = 'self_hosted'; session_duration = '24h'
          app_launcher_visible = $false
          policies = @([ordered]@{ name = 'Allowed users'; decision = 'allow'; include = @(@($AccessEmails) | ForEach-Object { @{ email = @{ email = $_ } } }) })
        }
        $actions += New-CfAction 'access' 'create' $h "Create Access application for $h" ("Allow: " + (@($AccessEmails) -join ', ') + '. Session 24h. Everyone else is blocked by Cloudflare before reaching your network.') $false $body
      }
    }
    # 2. Tunnel route
    $rules = @(& $hostRule $h)
    if ($rules.Count -gt 0 -and $rules[0].service -eq $script:OriginService) {
      $actions += New-CfAction 'tunnel' 'none' $h "Tunnel route $h -> traefik:80 already exists" '' $false $null
    } elseif ($rules.Count -gt 0) {
      $actions += New-CfAction 'tunnel' 'update' $h "Replace tunnel route $h -> $($rules[0].service)" "The existing published route sends $h to $($rules[0].service). It would be changed to $($script:OriginService)." $true $null
    } else {
      $actions += New-CfAction 'tunnel' 'create' $h "Add tunnel route $h -> traefik:80" 'Published application route on this instance''s tunnel.' $false $null
    }
    # 3. DNS
    $records = @(Invoke-CloudflareApi -Settings $Settings -Path "/zones/$($zone.id)/dns_records" -Query @{ name = $h } -All)
    $observed["dns:$h"] = @($records | ForEach-Object { "$($_.id)|$($_.type)|$($_.content)|$($_.proxied)" })
    $desired = [ordered]@{ type = 'CNAME'; name = $h; content = $tunnelTarget; proxied = $true; ttl = 1; comment = "$($script:ManagedComment) ($($Settings.StackName)/$($Service.name))" }
    if ($records.Count -eq 0) {
      $actions += New-CfAction 'dns' 'create' $h "Create DNS record $h CNAME $tunnelTarget (proxied)" "Zone $($zone.name)." $false ([pscustomobject]@{ ZoneId = $zone.id; RecordId = ''; Body = $desired })
    } else {
      $cname = @($records | Where-Object { $_.type -eq 'CNAME' })
      if ($cname.Count -eq 1 -and $records.Count -eq 1) {
        if ($cname[0].content -eq $tunnelTarget -and $cname[0].proxied) {
          $actions += New-CfAction 'dns' 'none' $h "DNS record $h already points at this tunnel" '' $false $null
        } else {
          $actions += New-CfAction 'dns' 'update' $h "Overwrite DNS record $h (currently CNAME $($cname[0].content), proxied=$($cname[0].proxied))" "It would point at $tunnelTarget (proxied). Whatever $h serves today stops working." $true ([pscustomobject]@{ ZoneId = $zone.id; RecordId = $cname[0].id; Body = $desired })
        }
      } else {
        $types = (@($records | ForEach-Object { "$($_.type) $($_.content)" }) -join ', ')
        $actions += New-CfAction 'dns' 'blocked' $h "$h already has DNS records ($types)" 'Records other than a single CNAME are never changed automatically. Remove or rename them in the Cloudflare dashboard, then preview again.' $false $null
      }
    }
  }

  foreach ($h in $unpublish) {
    $zone = Find-CloudflareZone $zones $h
    if ($zone) {
      $records = @(Invoke-CloudflareApi -Settings $Settings -Path "/zones/$($zone.id)/dns_records" -Query @{ name = $h } -All)
      $observed["dns:$h"] = @($records | ForEach-Object { "$($_.id)|$($_.type)|$($_.content)|$($_.proxied)" })
      $ours = @($records | Where-Object { $_.type -eq 'CNAME' -and $_.content -eq $tunnelTarget })
      if ($ours.Count -gt 0) {
        $actions += New-CfAction 'dns' 'delete' $h "Delete DNS record $h CNAME $tunnelTarget" 'The hostname stops resolving.' $false ([pscustomobject]@{ ZoneId = $zone.id; RecordId = $ours[0].id; Body = $null })
      } elseif ($records.Count -gt 0) {
        $plan.Notes += "DNS records for $h do not point at this tunnel and are left alone."
      }
    }
    $rules = @(& $hostRule $h)
    if ($rules.Count -gt 0 -and $rules[0].service -eq $script:OriginService) {
      $actions += New-CfAction 'tunnel' 'delete' $h "Remove tunnel route $h -> traefik:80" '' $false $null
    }
    $appId = Get-ManagedResource $config $h 'accessAppId'
    $apps = @($accessApps | Where-Object { $_.id -eq $appId })
    if ($appId -and $apps.Count -gt 0) {
      $actions += New-CfAction 'access' 'delete' $h "Delete Access application '$($apps[0].name)' (created by this tool)" '' $false ([pscustomobject]@{ AppId = $appId })
    } elseif (@(& $accessFor $h).Count -gt 0) {
      $plan.Notes += "The Access application for $h was not created by this tool and is left alone."
    }
  }

  # New ingress list (tunnel actions are applied together in one configuration update).
  $tunnelActions = @($actions | Where-Object { $_.Step -eq 'tunnel' -and $_.Kind -in @('create', 'update', 'delete') })
  if ($tunnelActions.Count -gt 0) {
    $newIngress = New-Object System.Collections.ArrayList
    $catchAll = @($ingress | Where-Object { -not ($_.PSObject.Properties['hostname'] -and $_.hostname) })
    $changeHosts = @($tunnelActions | ForEach-Object { $_.Hostname })
    foreach ($r in $ingress) {
      if (-not ($r.PSObject.Properties['hostname'] -and $r.hostname)) { continue }
      if ($changeHosts -contains $r.hostname -and -not ($r.PSObject.Properties['path'] -and $r.path)) { continue }
      $null = $newIngress.Add($r)
    }
    foreach ($a in $tunnelActions | Where-Object { $_.Kind -ne 'delete' }) { $null = $newIngress.Add([pscustomobject][ordered]@{ hostname = $a.Hostname; service = $script:OriginService }) }
    if ($catchAll.Count -gt 0) { foreach ($c in $catchAll) { $null = $newIngress.Add($c) } }
    else { $null = $newIngress.Add([pscustomobject]@{ service = 'http_status:404' }) }
    $plan.Ingress = $newIngress.ToArray()
    $plan.IngressChanged = $true
    $plan.Config = $cfg
  }

  $order = @{ access = 0; tunnel = 1; dns = 2 }
  if ($publish.Count -eq 0) { $order = @{ dns = 0; tunnel = 1; access = 2 } }
  $plan.Actions = @($actions | Sort-Object @{ e = { $order[$_.Step] } }, Hostname)
  $plan.Errors = @($actions | Where-Object { $_.Kind -eq 'blocked' } | ForEach-Object { $_.Summary })
  $observed['actions'] = @($plan.Actions | ForEach-Object { "$($_.Id)|$($_.Kind)" })
  $sha = [Security.Cryptography.SHA256]::Create()
  $plan.Fingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $observed -Depth 20 -Compress)))).Replace('-', '')
  return [pscustomobject]$plan
}

# Executes a plan from Get-CloudflareServicePlan. Actions with Overwrite=$true run only when their Id is listed in
# $ConfirmedOverwrites. Stops at the first failure; returns one result per action (Done / Skipped / Failed / Not run).
function Invoke-CloudflareServicePlan {
  param(
    [Parameter(Mandatory = $true)]$Settings,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [string[]]$ConfirmedOverwrites = @()
  )
  $results = New-Object System.Collections.ArrayList
  if (-not $Plan.Connected) { return @() }
  if (@($Plan.Errors).Count -gt 0) { throw 'The Cloudflare plan has blocking problems; nothing was changed in Cloudflare.' }
  $config = Read-CloudflareConfig -Settings $Settings
  $acct = $Plan.AccountId
  $failed = $false
  $tunnelDone = $false
  foreach ($a in $Plan.Actions) {
    $entry = [pscustomobject][ordered]@{ Id = $a.Id; Summary = $a.Summary; Status = 'Done'; Message = '' }
    if ($a.Kind -eq 'none') { $entry.Status = 'Unchanged'; $null = $results.Add($entry); continue }
    if ($failed) { $entry.Status = 'Not run'; $null = $results.Add($entry); continue }
    if ($a.Overwrite -and $ConfirmedOverwrites -notcontains $a.Id) { $entry.Status = 'Skipped'; $entry.Message = 'Overwrite not confirmed.'; $null = $results.Add($entry); continue }
    try {
      switch ($a.Step) {
        'access' {
          if ($a.Kind -eq 'create') {
            $app = Invoke-CloudflareApi -Settings $Settings -Method POST -Path "/accounts/$acct/access/apps" -Body $a.Data
            Set-ManagedResource $config $a.Hostname 'accessAppId' ([string]$app.id) $ServiceName
            $entry.Message = "Access app id $($app.id)"
          } elseif ($a.Kind -eq 'delete') {
            $null = Invoke-CloudflareApi -Settings $Settings -Method DELETE -Path "/accounts/$acct/access/apps/$($a.Data.AppId)"
            Set-ManagedResource $config $a.Hostname 'accessAppId' '' ''
          }
        }
        'tunnel' {
          if (-not $tunnelDone) {
            $newConfig = [ordered]@{}
            if ($Plan.Config) { foreach ($p in $Plan.Config.PSObject.Properties) { if ($p.Name -ne 'ingress') { $newConfig[$p.Name] = $p.Value } } }
            $newConfig['ingress'] = @($Plan.Ingress)
            $null = Invoke-CloudflareApi -Settings $Settings -Method PUT -Path "/accounts/$acct/cfd_tunnel/$($Plan.TunnelId)/configurations" -Body @{ config = $newConfig }
            $tunnelDone = $true
          }
        }
        'dns' {
          $d = $a.Data
          if ($a.Kind -eq 'create') {
            $rec = Invoke-CloudflareApi -Settings $Settings -Method POST -Path "/zones/$($d.ZoneId)/dns_records" -Body $d.Body
            Set-ManagedResource $config $a.Hostname 'dnsRecordId' ([string]$rec.id) $ServiceName
          } elseif ($a.Kind -eq 'update') {
            $rec = Invoke-CloudflareApi -Settings $Settings -Method PUT -Path "/zones/$($d.ZoneId)/dns_records/$($d.RecordId)" -Body $d.Body
            Set-ManagedResource $config $a.Hostname 'dnsRecordId' ([string]$rec.id) $ServiceName
          } elseif ($a.Kind -eq 'delete') {
            $null = Invoke-CloudflareApi -Settings $Settings -Method DELETE -Path "/zones/$($d.ZoneId)/dns_records/$($d.RecordId)"
            Set-ManagedResource $config $a.Hostname 'dnsRecordId' '' ''
          }
        }
      }
    } catch {
      $entry.Status = 'Failed'; $entry.Message = $_.Exception.Message; $failed = $true
    }
    $null = $results.Add($entry)
  }
  Save-CloudflareConfig -Settings $Settings -Config $config
  return $results.ToArray()
}

Export-ModuleMember -Function Set-CloudflareApiBase, Get-CloudflareApiBase, Test-CloudflareApiToken, Save-CloudflareApiToken, Remove-CloudflareApiToken,
  Get-CloudflareApiTokenInfo, Read-CloudflareConfig, Save-CloudflareConfig, Invoke-CloudflareApi, Test-CloudflareToken, Get-CloudflareZones,
  Get-CloudflareTunnels, Test-CloudflareId, Find-CloudflareZone, New-CloudflareTunnel, Install-CloudflareTunnelToken, Get-CloudflareManualSteps,
  Get-CloudflareServicePlan, Invoke-CloudflareServicePlan
