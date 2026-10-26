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

# True when $Text contains the stored API token. Lets export code prove that a backup is free of the token without
# the token ever leaving this module.
function Test-TextContainsApiToken {
  param([Parameter(Mandatory = $true)]$Settings, [string]$Text)
  if (-not $Text) { return $false }
  $token = $null
  try { $token = Read-CloudflareApiToken $Settings } catch { return $false }
  $found = [bool]($token -and $Text.Contains($token))
  $token = $null
  return $found
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
  # domains: the application-level allowlist. Services can only be published under these zones, even when the
  # API token can see more.
  $config = [pscustomobject][ordered]@{ version = 1; accountId = ''; accountName = ''; tunnelId = ''; tunnelName = ''; domains = @(); managed = [pscustomobject]@{} }
  if (Test-Path -LiteralPath $path) {
    $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    foreach ($p in @('accountId', 'accountName', 'tunnelId', 'tunnelName')) { if ($json.PSObject.Properties[$p] -and $json.$p) { $config.$p = [string]$json.$p } }
    if ($json.PSObject.Properties['domains'] -and $json.domains) {
      $config.domains = @($json.domains | Where-Object { $_ -and $_.PSObject.Properties['id'] -and $_.PSObject.Properties['name'] } | ForEach-Object {
          [pscustomobject][ordered]@{ id = [string]$_.id; name = [string]$_.name; accountId = $(if ($_.PSObject.Properties['accountId']) { [string]$_.accountId } else { '' }) } })
    }
    if ($json.PSObject.Properties['managed'] -and $json.managed) { $config.managed = $json.managed }
  }
  return $config
}

# The zones (from a zone list) that are on the allowlist in config\cloudflare.json.
function Select-AllowedZones($Config, $Zones) {
  $ids = @($Config.domains | ForEach-Object { $_.id })
  return @($Zones | Where-Object { $ids -contains $_.id })
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
  if ($Config.managed.PSObject.Properties[$Hostname] -and $Config.managed.$Hostname.PSObject.Properties[$Field]) { return [string]$Config.managed.$Hostname.$Field }
  return ''
}

# Who may sign in through an Access application this tool created (kept so a restore can recreate it).
function Get-ManagedAccessEmails($Config, [string]$Hostname) {
  if ($Config.managed.PSObject.Properties[$Hostname] -and $Config.managed.$Hostname.PSObject.Properties['accessEmails']) { return @($Config.managed.$Hostname.accessEmails | Where-Object { $_ }) }
  return @()
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
      # The HTTP status travels with the error so callers can tell "missing permission" from other failures.
      $ex = New-Object System.Exception $err
      $ex.Data['cfStatus'] = $status
      throw $ex
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

# --- Token creation link and permission discovery -------------------------------------------------------------------

# Cloudflare's pre-filled "Create API token" page (a user-owned token), per
# https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/ :
# permissionGroupKeys is a URL-encoded JSON array of {key, type}; accountId=* and zoneId=all are the documented
# scope values, and the user narrows accounts and zones on Cloudflare's page before creating the token.
# 'zone', 'dns' and 'access' are keys from Cloudflare's published key table. 'argotunnel' (Cloudflare Tunnel) is
# not in that table; it is the permission's internal name used by other tools' template links. If Cloudflare's page
# does not show it, the user adds "Account > Cloudflare Tunnel > Edit" by hand, and discovery below reports it.
$script:TokenPermissions = @(
  [pscustomobject]@{ Id = 'zone'; Key = 'zone'; Type = 'read'; Label = 'Zone > Zone > Read'; Optional = $false; Purpose = 'list the domains you allow' }
  [pscustomobject]@{ Id = 'dns'; Key = 'dns'; Type = 'edit'; Label = 'Zone > DNS > Edit'; Optional = $false; Purpose = 'create the CNAME record of each published hostname' }
  [pscustomobject]@{ Id = 'tunnel'; Key = 'argotunnel'; Type = 'edit'; Label = 'Account > Cloudflare Tunnel > Edit'; Optional = $false; Purpose = 'create or select the tunnel and add published routes' }
  [pscustomobject]@{ Id = 'access'; Key = 'access'; Type = 'edit'; Label = 'Account > Access: Apps and Policies > Edit'; Optional = $true; Purpose = 'protect hostnames with a Cloudflare Access login (optional)' }
)

function Get-CloudflareTokenPermissions { return $script:TokenPermissions }

function Get-CloudflareTokenTemplateUrl {
  param([switch]$IncludeAccess, [string]$Name = 'Traefik proxy for Windows')
  $perms = @($script:TokenPermissions | Where-Object { $IncludeAccess -or -not $_.Optional } | ForEach-Object { '{"key":"' + $_.Key + '","type":"' + $_.Type + '"}' })
  $json = '[' + ($perms -join ',') + ']'
  return 'https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=' + [Uri]::EscapeDataString($json) +
    '&accountId=*&zoneId=all&name=' + [Uri]::EscapeDataString($Name)
}

function Get-CfErrorStatus($ErrorRecord) {
  $ex = $ErrorRecord.Exception
  if ($ex.Data.Contains('cfStatus')) { return [int]$ex.Data['cfStatus'] }
  return 0
}

# Verifies a token (a candidate, or the stored one) and finds out what it can do, using read-only calls only:
# accounts, zones, DNS records per zone, tunnels and Access apps per account. Never throws: every failure becomes
# a message. Editing rights cannot be proven without making a change, so DNS shows "readable".
function Get-CloudflareDiscovery {
  param([Parameter(Mandatory = $true)]$Settings, [string]$Token, [string]$AccountId, [string[]]$ZoneIds = @())
  $d = [ordered]@{ Valid = $false; Status = ''; Message = ''; Accounts = @(); Zones = @(); AccountId = ''; AccountName = ''; Tunnels = @(); Permissions = @(); ProfileEmail = '' }
  $call = { param($Path, $Query, [switch]$All)
    $p = @{ Settings = $Settings; Path = $Path; Query = $(if ($Query) { $Query } else { @{} }); All = [bool]$All }
    if ($Token) { $p['Token'] = $Token }
    Invoke-CloudflareApi @p
  }
  $errors = @()
  # Account-owned tokens cannot use /user/tokens/verify; for those, listing accounts or zones proves the token works.
  try { $v = & $call '/user/tokens/verify'; $d.Status = [string]$v.status } catch { $errors += $_.Exception.Message }
  if ($d.Status -and $d.Status -ne 'active') { $d.Message = "Cloudflare reports this token as '$($d.Status)'. Create a new token."; return [pscustomobject]$d }
  try { $d.Accounts = @(& $call '/accounts' -All | ForEach-Object { [pscustomobject][ordered]@{ id = [string]$_.id; name = [string]$_.name } }) } catch { $errors += $_.Exception.Message }
  try {
    $d.Zones = @(& $call '/zones' -All | ForEach-Object {
        $acct = ''; $acctName = ''
        if ($_.PSObject.Properties['account'] -and $_.account) { $acct = [string]$_.account.id; if ($_.account.PSObject.Properties['name']) { $acctName = [string]$_.account.name } }
        [pscustomobject][ordered]@{ id = [string]$_.id; name = [string]$_.name; status = [string]$_.status; accountId = $acct; accountName = $acctName; dns = 'unknown' } })
  } catch { $errors += $_.Exception.Message }
  $d.Valid = ($d.Status -eq 'active') -or $d.Accounts.Count -gt 0 -or $d.Zones.Count -gt 0
  if (-not $d.Valid) { $d.Message = 'Cloudflare rejected this token (invalid, expired or revoked), or it has no permissions at all. ' + ($errors -join ' '); return [pscustomobject]$d }
  # The profile email is only readable with "User Details Read", which the template does not ask for. When the token
  # happens to have it, the email is offered as a prefill (the user confirms or edits it); otherwise nothing.
  try { $u = & $call '/user'; if ($u -and $u.PSObject.Properties['email'] -and [string]$u.email -match '^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$') { $d.ProfileEmail = [string]$u.email } } catch { }

  # Account: the requested one, else the only one visible (from /accounts or from the zones' owners).
  $candidates = @($d.Accounts)
  foreach ($z in $d.Zones) { if ($z.accountId -and -not (@($candidates | Where-Object { $_.id -eq $z.accountId }))) { $candidates += [pscustomobject][ordered]@{ id = $z.accountId; name = $z.accountName } } }
  if ($d.Accounts.Count -eq 0 -and $candidates.Count -gt 0) { $d.Accounts = $candidates }
  if ($AccountId -and @($candidates | Where-Object { $_.id -eq $AccountId })) { $d.AccountId = $AccountId }
  elseif ($candidates.Count -eq 1) { $d.AccountId = $candidates[0].id }
  if ($d.AccountId) { $d.AccountName = [string](@($candidates | Where-Object { $_.id -eq $d.AccountId })[0].name) }

  $perm = { param($Id, $State, $Message)
    $def = @($script:TokenPermissions | Where-Object { $_.Id -eq $Id })[0]
    [pscustomobject][ordered]@{ id = $Id; label = $def.Label; optional = $def.Optional; purpose = $def.Purpose; state = $State; message = $Message }
  }
  $perms = @()
  if ($d.Zones.Count -gt 0) { $perms += & $perm 'zone' 'ok' "$($d.Zones.Count) domain(s) visible." }
  else { $perms += & $perm 'zone' 'missing' 'Cloudflare returned no domains. Add "Zone > Zone > Read" and include your domain under "Zone Resources" when creating the token.' }

  $checkZones = @($d.Zones)
  if (@($ZoneIds).Count -gt 0) { $checkZones = @($d.Zones | Where-Object { $ZoneIds -contains $_.id }) }
  $ok = 0; $missing = @()
  foreach ($z in @($checkZones | Select-Object -First 25)) {
    try { $null = & $call "/zones/$($z.id)/dns_records" @{ per_page = 1 }; $z.dns = 'ok'; $ok++ }
    catch { $z.dns = 'missing'; $missing += $z.name }
  }
  if ($checkZones.Count -eq 0) { $perms += & $perm 'dns' 'unknown' 'No domain to check yet.' }
  elseif ($missing.Count -eq 0) { $perms += & $perm 'dns' 'ok' 'DNS records are readable. Edit rights are confirmed the first time a record is created.' }
  elseif ($ok -gt 0) { $perms += & $perm 'dns' 'partial' ("No DNS access for: " + ($missing -join ', ') + '. Add "Zone > DNS > Edit" for those zones.') }
  else { $perms += & $perm 'dns' 'missing' 'The token cannot read DNS records. Add "Zone > DNS > Edit".' }

  if (-not $d.AccountId) {
    $why = if ($candidates.Count -gt 1) { 'Choose an account to check tunnel and Access permissions.' } else { 'No Cloudflare account is visible to this token. Add "Account > Cloudflare Tunnel > Edit" and include the account under "Account Resources".' }
    $perms += & $perm 'tunnel' 'unknown' $why
    $perms += & $perm 'access' 'unknown' $why
  } else {
    try {
      $d.Tunnels = @(Get-CloudflareTunnels -Settings $Settings -AccountId $d.AccountId -Token $Token)
      $perms += & $perm 'tunnel' 'ok' "$($d.Tunnels.Count) tunnel(s) in $($d.AccountName)."
    } catch {
      $msg = if ((Get-CfErrorStatus $_) -eq 403) { 'The token cannot read tunnels. Add "Account > Cloudflare Tunnel > Edit". Without it, use local-only mode or set the tunnel up by hand.' } else { 'Tunnels could not be listed: ' + $_.Exception.Message }
      $perms += & $perm 'tunnel' 'missing' $msg
    }
    try { $null = & $call "/accounts/$($d.AccountId)/access/apps" @{ per_page = 1 }; $perms += & $perm 'access' 'ok' 'Access applications are readable.' }
    catch { $perms += & $perm 'access' 'missing' 'Optional: without "Account > Access: Apps and Policies > Edit" this tool cannot create Access logins; you would add them in the Cloudflare dashboard.' }
  }
  $d.Permissions = $perms
  return [pscustomobject]$d
}

function Get-CloudflareZones {
  param([Parameter(Mandatory = $true)]$Settings, [string]$AccountId)
  $query = @{}
  if ($AccountId) { $query['account.id'] = $AccountId }
  return @(Invoke-CloudflareApi -Settings $Settings -Path '/zones' -Query $query -All | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; status = [string]$_.status } })
}

# Read-only check that Cloudflare resources recorded in a backup still exist and belong to the expected account:
# the account, the tunnel, the allowed zones, and per hostname the DNS record and Access application ids.
# $Hostnames: objects with hostname, dnsRecordId, accessAppId. Never throws. Every item has
# state = verified | missing | mismatch | unknown | none, and a message.
function Get-CloudflareResourceCheck {
  param([Parameter(Mandatory = $true)]$Settings, [string]$AccountId, [string]$TunnelId, $Domains = @(), $Hostnames = @())
  $item = { param($Id, $Name, $State, $Message) [pscustomobject][ordered]@{ id = $Id; name = $Name; state = $State; message = $Message } }
  $out = [ordered]@{ Connected = $false; Message = ''; Account = $null; Tunnel = $null; Domains = @(); Hostnames = @() }
  $token = Get-CloudflareApiTokenInfo -Settings $Settings
  if (-not ($token.Stored -and $token.Readable)) {
    $out.Message = 'No usable Cloudflare API token is stored, so the Cloudflare resources in the backup were not verified.'
    return [pscustomobject]$out
  }
  $out.Connected = $true
  $accountOk = $false
  if (-not $AccountId) { $out.Account = & $item '' '' 'none' 'The backup has no Cloudflare account.' }
  else {
    $acct = @()
    try { $acct = @(Invoke-CloudflareApi -Settings $Settings -Path '/accounts' -All | Where-Object { $_.id -eq $AccountId }) } catch { }
    if ($acct.Count -gt 0) { $accountOk = $true; $out.Account = & $item $AccountId ([string]$acct[0].name) 'verified' "The API token can see account '$($acct[0].name)'." }
    else {
      # Tokens limited to account resources often cannot list /accounts (that needs Account Settings Read) although they
      # work on the account. Reading the account's tunnels proves access; only a refusal there means "missing".
      $probe = if ($TunnelId) { "/accounts/$AccountId/cfd_tunnel/$TunnelId" } else { "/accounts/$AccountId/cfd_tunnel" }
      try {
        $null = Invoke-CloudflareApi -Settings $Settings -Path $probe -Query @{ per_page = 1 }
        $accountOk = $true; $out.Account = & $item $AccountId '' 'verified' 'The API token can work on this account (it cannot list accounts, which is normal for tokens limited to account resources).'
      } catch {
        $code = Get-CfErrorStatus $_
        if ($code -eq 404 -and $TunnelId) {
          try { $null = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$AccountId/cfd_tunnel" -Query @{ per_page = 1 }; $accountOk = $true; $out.Account = & $item $AccountId '' 'verified' 'The API token can work on this account.' }
          catch { $out.Account = & $item $AccountId '' 'missing' 'The stored API token cannot see this account. Connect a token for the account this deployment uses.' }
        } elseif ($code -in @(401, 403, 404)) { $out.Account = & $item $AccountId '' 'missing' 'The stored API token cannot see this account. Connect a token for the account this deployment uses.' }
        else { $out.Account = & $item $AccountId '' 'unknown' $_.Exception.Message }
      }
    }
  }
  if (-not $TunnelId) { $out.Tunnel = & $item '' '' 'none' 'The backup has no tunnel.' }
  elseif (-not $accountOk) { $out.Tunnel = & $item $TunnelId '' 'unknown' 'The tunnel cannot be checked without access to its account.' }
  else {
    try {
      $t = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$AccountId/cfd_tunnel/$TunnelId"
      $remote = ($t.PSObject.Properties['remote_config'] -and [bool]$t.remote_config) -or ($t.PSObject.Properties['config_src'] -and $t.config_src -eq 'cloudflare')
      if ($t.PSObject.Properties['deleted_at'] -and $t.deleted_at) { $out.Tunnel = & $item $TunnelId ([string]$t.name) 'missing' "Tunnel '$($t.name)' was deleted in Cloudflare." }
      elseif (-not $remote) { $out.Tunnel = & $item $TunnelId ([string]$t.name) 'mismatch' "Tunnel '$($t.name)' is locally managed; only dashboard/API-managed tunnels can be automated." }
      else { $out.Tunnel = & $item $TunnelId ([string]$t.name) 'verified' "Tunnel '$($t.name)' exists in this account (status $($t.status))." }
    } catch {
      $code = Get-CfErrorStatus $_
      if ($code -eq 404) { $out.Tunnel = & $item $TunnelId '' 'missing' 'The tunnel does not exist in this account any more.' }
      else { $out.Tunnel = & $item $TunnelId '' 'unknown' $_.Exception.Message }
    }
  }
  $zones = $null
  try { $zones = @(Invoke-CloudflareApi -Settings $Settings -Path '/zones' -All) } catch { $out.Message = 'Zones could not be listed: ' + $_.Exception.Message }
  $out.Domains = @(foreach ($d in @($Domains)) {
      if ($null -eq $zones) { & $item $d.id $d.name 'unknown' 'Zones could not be listed.'; continue }
      $z = @($zones | Where-Object { $_.id -eq $d.id })
      if ($z.Count -eq 0) { & $item $d.id $d.name 'missing' "The API token cannot see the zone $($d.name)."; continue }
      $owner = ''; if ($z[0].PSObject.Properties['account'] -and $z[0].account) { $owner = [string]$z[0].account.id }
      if ($AccountId -and $owner -and $owner -ne $AccountId) { & $item $d.id $d.name 'mismatch' "The zone $($d.name) belongs to another account."; continue }
      & $item $d.id $d.name 'verified' "Zone $($d.name) is visible."
    })
  $target = "$TunnelId.cfargotunnel.com"
  $out.Hostnames = @(foreach ($h in @($Hostnames)) {
      $name = [string]$h.hostname
      $dns = & $item ([string]$h.dnsRecordId) $name 'none' 'No DNS record id recorded.'
      if ($h.dnsRecordId) {
        $zone = $null
        if ($null -ne $zones) { $zone = Find-CloudflareZone @($zones | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name } }) $name }
        if (-not $zone) { $dns = & $item $h.dnsRecordId $name 'unknown' "No visible zone for $name." }
        else {
          try {
            $rec = Invoke-CloudflareApi -Settings $Settings -Path "/zones/$($zone.id)/dns_records/$($h.dnsRecordId)"
            if ($rec.name -eq $name -and $rec.type -eq 'CNAME' -and $rec.content -eq $target) { $dns = & $item $h.dnsRecordId $name 'verified' "DNS record $name points at this tunnel." }
            else { $dns = & $item $h.dnsRecordId $name 'mismatch' "DNS record $($h.dnsRecordId) now is $($rec.type) $($rec.name) -> $($rec.content); it is not adopted." }
          } catch {
            if ((Get-CfErrorStatus $_) -eq 404) { $dns = & $item $h.dnsRecordId $name 'missing' "The DNS record of $name no longer exists." }
            else { $dns = & $item $h.dnsRecordId $name 'unknown' $_.Exception.Message }
          }
        }
      }
      $access = & $item ([string]$h.accessAppId) $name 'none' 'No Access application id recorded.'
      if ($h.accessAppId) {
        if (-not $accountOk) { $access = & $item $h.accessAppId $name 'unknown' 'The Access application cannot be checked without access to its account.' }
        else {
          try {
            $app = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$AccountId/access/apps/$($h.accessAppId)"
            $domains = @(); if ($app.PSObject.Properties['domain']) { $domains += [string]$app.domain }
            if ($app.PSObject.Properties['self_hosted_domains']) { $domains += @($app.self_hosted_domains | ForEach-Object { [string]$_ }) }
            if ($domains -contains $name) { $access = & $item $h.accessAppId $name 'verified' "Access application '$($app.name)' protects $name." }
            else { $access = & $item $h.accessAppId $name 'mismatch' "Access application $($h.accessAppId) no longer protects $name; it is not adopted." }
          } catch {
            if ((Get-CfErrorStatus $_) -eq 404) { $access = & $item $h.accessAppId $name 'missing' "The Access application of $name no longer exists." }
            else { $access = & $item $h.accessAppId $name 'unknown' $_.Exception.Message }
          }
        }
      }
      [pscustomobject][ordered]@{ hostname = $name; dns = $dns; access = $access }
    })
  return [pscustomobject]$out
}

function Get-CloudflareTunnels {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$AccountId, [string]$Token)
  $p = @{ Settings = $Settings; Path = "/accounts/$AccountId/cfd_tunnel"; Query = @{ is_deleted = 'false' }; All = $true }
  if ($Token) { $p['Token'] = $Token }
  return @(Invoke-CloudflareApi @p | ForEach-Object {
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
#   $Config           use these selections (account, tunnel, allowed domains) instead of config\cloudflare.json
function Get-CloudflareServicePlan {
  param(
    [Parameter(Mandatory = $true)]$Settings,
    $Service,
    $PreviousService,
    $OtherServices = @(),
    [string[]]$AccessEmails = @(),
    [switch]$Cleanup,
    $Config
  )
  $config = if ($Config) { $Config } else { Read-CloudflareConfig -Settings $Settings }
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
  $visibleZones = @(Get-CloudflareZones -Settings $Settings)
  $zones = @(Select-AllowedZones $config $visibleZones)
  $tunnelConfig = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$acct/cfd_tunnel/$($config.tunnelId)/configurations"
  $cfg = $null
  if ($tunnelConfig -and $tunnelConfig.PSObject.Properties['config'] -and $tunnelConfig.config) { $cfg = $tunnelConfig.config }
  $ingress = New-Object System.Collections.ArrayList
  if ($cfg -and $cfg.PSObject.Properties['ingress'] -and $cfg.ingress) { foreach ($r in @($cfg.ingress)) { $null = $ingress.Add($r) } }
  $observed['ingress'] = $ingress.ToArray()
  $accessApps = @()
  $needAccess = $Service -and $Service.cloudflare.access -and $publish.Count -gt 0
  # Access off on a published hostname: an Access application this tool created for it would still show Cloudflare's
  # login in front, so it is looked up too.
  $managedAccess = @($publish | Where-Object { -not ($Service -and $Service.cloudflare.access) -and (Get-ManagedResource $config $_ 'accessAppId') })
  if ($needAccess -or $unpublish.Count -gt 0 -or $managedAccess.Count -gt 0) { $accessApps = @(Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$acct/access/apps" -All) }
  $observed['accessApps'] = @($accessApps | ForEach-Object { "$($_.id)|$($_.domain)" })

  $hostRule = { param($h) @($ingress | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq $h -and -not ($_.PSObject.Properties['path'] -and $_.path) }) }
  $accessFor = { param($h) @($accessApps | Where-Object {
        ($_.PSObject.Properties['domain'] -and ($_.domain -eq $h -or $_.domain -like "$h/*")) -or
        ($_.PSObject.Properties['self_hosted_domains'] -and @($_.self_hosted_domains) -contains $h) }) }
  $actions = @()

  foreach ($h in $publish) {
    $zone = Find-CloudflareZone $zones $h
    if (-not $zone) {
      $visible = Find-CloudflareZone $visibleZones $h
      if ($visible) {
        $actions += New-CfAction 'dns' 'blocked' $h "$($visible.name) is not an allowed domain for this instance" "Add $($visible.name) to the allowed domains (Setup > Connect Cloudflare) to publish $h." $false $null
      } else {
        $actions += New-CfAction 'dns' 'blocked' $h "No Cloudflare zone for $h" "The API token cannot see a zone that $h belongs to. Add the domain to Cloudflare or give the token DNS:Edit on it." $false $null
      }
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
    } else {
      # Access is off. Turning it off in this change removes the Access application this tool created for it (shown in
      # the preview). One left over from before is only reported: it is never removed without an explicit change.
      $appId = Get-ManagedResource $config $h 'accessAppId'
      $apps = @($accessApps | Where-Object { $appId -and $_.id -eq $appId })
      $wasOn = [bool]($PreviousService -and $PreviousService.PSObject.Properties['cloudflare'] -and $PreviousService.cloudflare.access -and (@(Get-PublishedHostnames $PreviousService) -contains $h))
      if ($apps.Count -gt 0 -and $wasOn) {
        $actions += New-CfAction 'access' 'delete' $h "Delete Access application '$($apps[0].name)' (created by this tool)" "Cloudflare Access is turned off for $h, so Cloudflare no longer asks for its own login first." $false ([pscustomobject]@{ AppId = $appId })
      } elseif ($apps.Count -gt 0) {
        $plan.Notes += "Cloudflare Access application '$($apps[0].name)' (created by this tool) still asks visitors of $h for a Cloudflare login, although Access is off for this service. Delete it in Cloudflare Zero Trust (Access > Applications) if authentik alone should protect $h."
      } elseif (@(& $accessFor $h).Count -gt 0) {
        $plan.Notes += "An Access application not created by this tool covers $h; Cloudflare asks for its login first. It is left alone."
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
# $Steps limits the run to some steps (access, tunnel, dns), so a caller can do work between them.
function Invoke-CloudflareServicePlan {
  param(
    [Parameter(Mandatory = $true)]$Settings,
    [Parameter(Mandatory = $true)]$Plan,
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [string[]]$ConfirmedOverwrites = @(),
    [string[]]$Steps = @('access', 'tunnel', 'dns')
  )
  $results = New-Object System.Collections.ArrayList
  if (-not $Plan.Connected) { return @() }
  if (@($Plan.Errors).Count -gt 0) { throw 'The Cloudflare plan has blocking problems; nothing was changed in Cloudflare.' }
  $config = Read-CloudflareConfig -Settings $Settings
  $acct = $Plan.AccountId
  $failed = $false
  $tunnelDone = $false
  foreach ($a in @($Plan.Actions | Where-Object { $Steps -contains $_.Step })) {
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
            $emails = @(@($a.Data.policies) | ForEach-Object { @($_.include) } | ForEach-Object { $_.email.email } | Where-Object { $_ })
            $config.managed.($a.Hostname) | Add-Member -NotePropertyName accessEmails -NotePropertyValue $emails -Force
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
  Get-CloudflareApiTokenInfo, Test-TextContainsApiToken, Read-CloudflareConfig, Save-CloudflareConfig, Get-ManagedResource, Get-ManagedAccessEmails,
  Get-CloudflareResourceCheck, Get-CfErrorStatus, Invoke-CloudflareApi, Test-CloudflareToken, Get-CloudflareZones,
  Get-CloudflareTunnels, Test-CloudflareId, Select-AllowedZones, Get-CloudflareTokenPermissions, Get-CloudflareTokenTemplateUrl, Get-CloudflareDiscovery, Find-CloudflareZone, New-CloudflareTunnel, Install-CloudflareTunnelToken, Get-CloudflareManualSteps,
  Get-CloudflareServicePlan, Invoke-CloudflareServicePlan
