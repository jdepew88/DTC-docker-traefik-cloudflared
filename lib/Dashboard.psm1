#requires -version 5.1
# Public Traefik dashboard ("dashboard bootstrap"): lets a new deployment check Traefik itself through the Cloudflare
# Tunnel before any application is published.
#
# - Settings live in config\dashboard.json; the route is generated into traefik\dynamic\admin-dashboard.yml.
# - The public hostname defaults to <instance name>.<allowed domain> and reuses the instance's tunnel.
# - Fail closed: Cloudflare Access is mandatory. The route file is written only after the Access application for the
#   hostname exists (created by this tool or already present), and the tunnel route and DNS record only after that.
#   The router also requires the Cf-Access-Jwt-Assertion header that Cloudflare Access adds to authenticated
#   requests, so a request that did not pass through Access is not routed. (Traefik does not verify the token's
#   signature; Cloudflare Access is the authentication.)
# - The local dashboard (traefik\dynamic\dashboard.yml, 127.0.0.1 only) is independent of all of this.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'TraefikProxy.psm1')
Import-Module (Join-Path $PSScriptRoot 'CloudflareApi.psm1')

$script:ConfigFile = 'config\dashboard.json'
$script:RouteFile = 'admin-dashboard.yml'
$script:RouterName = 'public-dashboard'
$script:PseudoServiceName = 'traefik-dashboard'
$script:AccessHeader = 'Cf-Access-Jwt-Assertion'
$script:LabelPattern = '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'

function Get-DashboardRouteFile { return $script:RouteFile }
function Get-DashboardRouterName { return "$($script:RouterName)@file" }

function Read-DashboardConfig {
  param([Parameter(Mandatory = $true)]$Settings)
  # subdomainCustom: the user edited the subdomain (otherwise it follows the instance name). publish: the user chose to
  # publish the dashboard during setup (a wish, not a state: enabled says whether it is published).
  $config = [pscustomobject][ordered]@{ version = 1; enabled = $false; subdomain = ''; subdomainCustom = $false; zoneId = ''; zoneName = ''; hostname = ''; accessEmails = @(); publish = $false; enabledAt = '' }
  $path = Join-Path $Settings.InstallPath $script:ConfigFile
  if (-not (Test-Path -LiteralPath $path)) { return $config }
  try {
    $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    foreach ($p in @('subdomain', 'zoneId', 'zoneName', 'hostname', 'enabledAt')) { if ($json.PSObject.Properties[$p] -and $json.$p) { $config.$p = [string]$json.$p } }
    foreach ($p in @('enabled', 'subdomainCustom', 'publish')) { if ($json.PSObject.Properties[$p]) { $config.$p = [bool]$json.$p } }
    if ($json.PSObject.Properties['accessEmails'] -and $json.accessEmails) { $config.accessEmails = @($json.accessEmails | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
  } catch { }
  return $config
}

function Save-DashboardConfig {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Config)
  Write-TextFileAtomic (Join-Path $Settings.InstallPath $script:ConfigFile) ((ConvertTo-StableJson $Config) + "`n")
}

# Default subdomain: the instance name, made DNS-safe (traefik-home -> traefik-home).
function Get-DashboardDefaultSubdomain($Settings) {
  # Same rule as suggestLabel in webui\logic.js: runs of other characters become one dash.
  $s = ($Settings.StackName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if (-not $s) { $s = 'traefik' }
  if ($s.Length -gt 63) { $s = $s.Substring(0, 63).Trim('-') }
  return $s
}

function Test-DashboardSubdomain([string]$Subdomain) { return ($Subdomain -match $script:LabelPattern -and $Subdomain.Length -le 200) }

# A service-like object so the Cloudflare planner treats the dashboard hostname like a published, Access-protected app.
function Get-DashboardPseudoService($Settings, [string]$Hostname) {
  return ConvertTo-ServiceDefinition @{
    name = $script:PseudoServiceName; hostnames = @($Hostname); description = 'Traefik dashboard'
    target = @{ type = 'docker'; host = $Settings.TraefikContainer; port = 8080; protocol = 'http' }
    cloudflare = @{ publish = $true; access = $true }
  }
}

# Traefik file-provider YAML for the public dashboard. The hostname was validated against a strict pattern.
function ConvertTo-DashboardRouteYaml([string]$Hostname) {
  $guard = 'HeaderRegexp(`' + $script:AccessHeader + '`, `.+`)'
  $lines = @(
    '# Generated from config/dashboard.json by the web UI. Do not edit by hand: changes here are overwritten.'
    "# Public Traefik dashboard for $Hostname, reached only through this instance's Cloudflare Tunnel."
    '# Cloudflare Access must protect this hostname: this file is written only after the Access application was'
    "# confirmed, and requests without the Cloudflare Access token header ($($script:AccessHeader)) are not routed."
    '# Traefik does not verify that token; Cloudflare Access is the authentication.'
    'http:'
    '  routers:'
    "    $($script:RouterName):"
    "      rule: 'Host(``$Hostname``) && (PathPrefix(``/dashboard``) || PathPrefix(``/api``)) && $guard'"
    '      entryPoints: [web]'
    '      middlewares: [default-headers@file]'
    '      service: api@internal'
    "    $($script:RouterName)-root:"
    "      rule: 'Host(``$Hostname``) && Path(``/``) && $guard'"
    '      entryPoints: [web]'
    "      middlewares: [$($script:RouterName)-redirect]"
    '      service: noop@internal'
    '  middlewares:'
    "    $($script:RouterName)-redirect:"
    '      redirectRegex:'
    "        regex: '^.*`$'"
    "        replacement: '/dashboard/'"
  )
  return ($lines -join "`n") + "`n"
}

function Get-DashboardRoutePath($Settings) { return (Join-Path $Settings.DynamicDir $script:RouteFile) }

function Get-DashboardRouteContent($Settings) {
  $path = Get-DashboardRoutePath $Settings
  if (Test-Path -LiteralPath $path) { return ([IO.File]::ReadAllText($path)).Replace("`r`n", "`n") }
  return $null
}

# Plans enabling (or with -Disable, removing) the public dashboard. Reads Traefik and Cloudflare; never writes.
# Errors make the plan unappliable. Fail closed: without Cloudflare automation, or without a way to make sure
# Access protects the hostname, the plan has errors.
function Get-DashboardPlan {
  param(
    [Parameter(Mandatory = $true)]$Settings,
    [string]$Subdomain,
    [string]$ZoneId,
    [string[]]$AccessEmails = @(),
    [switch]$Disable,
    $Services = @(),
    $CloudflareConfig
  )
  $current = Read-DashboardConfig -Settings $Settings
  $cfConfig = if ($CloudflareConfig) { $CloudflareConfig } else { Read-CloudflareConfig -Settings $Settings }
  $plan = [ordered]@{
    Disable = [bool]$Disable; Hostname = ''; Subdomain = ''; ZoneId = ''; ZoneName = ''; AccessEmails = @()
    FileAction = 'unchanged'; OldContent = (Get-DashboardRouteContent $Settings); NewContent = $null
    Cloudflare = $null; Errors = @(); Notes = @(); Key = ''
  }
  $others = @($Services | Where-Object { $_.name -ne $script:PseudoServiceName })
  if ($Disable) {
    if (-not $current.hostname) { $plan.Errors += 'The public dashboard is not set up.' }
    $plan.Hostname = $current.hostname; $plan.Subdomain = $current.subdomain; $plan.ZoneId = $current.zoneId; $plan.ZoneName = $current.zoneName
    if ($null -ne $plan.OldContent) { $plan.FileAction = 'remove' }
    if ($current.hostname) {
      try { $plan.Cloudflare = Get-CloudflareServicePlan -Settings $Settings -Service $null -PreviousService (Get-DashboardPseudoService $Settings $current.hostname) -OtherServices $others -Cleanup -Config $cfConfig }
      catch { $plan.Errors += 'Cloudflare could not be read: ' + $_.Exception.Message }
    }
  } else {
    $token = Get-CloudflareApiTokenInfo -Settings $Settings
    if (-not ($token.Stored -and $token.Readable -and $cfConfig.accountId -and $cfConfig.tunnelId)) {
      $plan.Errors += 'The public dashboard needs Cloudflare automation (API token, account and tunnel), because Cloudflare Access must be in place before the route is published. The local dashboard keeps working without it.'
    }
    $Subdomain = ([string]$Subdomain).Trim().ToLowerInvariant().TrimEnd('.')
    if (-not $Subdomain) { $Subdomain = Get-DashboardDefaultSubdomain $Settings }
    if (-not (Test-DashboardSubdomain $Subdomain)) { $plan.Errors += "'$Subdomain' is not a valid subdomain (letters, digits and dashes; labels separated by dots)." }
    $zone = @($cfConfig.domains | Where-Object { $_.id -eq $ZoneId })
    if (-not $ZoneId -and @($cfConfig.domains).Count -eq 1) { $zone = @($cfConfig.domains) }
    if ($zone.Count -eq 0) { $plan.Errors += 'Choose one of the allowed Cloudflare domains (Setup > Connect Cloudflare).' }
    $hostname = ''
    if ($zone.Count -gt 0) { $hostname = "$Subdomain.$($zone[0].name)"; $plan.ZoneId = $zone[0].id; $plan.ZoneName = $zone[0].name }
    $plan.Hostname = $hostname; $plan.Subdomain = $Subdomain
    $emails = @(@($AccessEmails) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($emails.Count -eq 0) { $emails = @($current.accessEmails) }
    $plan.AccessEmails = $emails
    if ($hostname -and $hostname.Length -gt 253) { $plan.Errors += 'The hostname is too long.' }
    foreach ($s in $others) { if (@($s.hostnames) -contains $hostname) { $plan.Errors += "$hostname is already used by service '$($s.name)'." } }
    if ($current.enabled -and $current.hostname -and $hostname -and $current.hostname -ne $hostname) {
      $plan.Errors += "The public dashboard already uses $($current.hostname). Remove it first, then set it up with the new name."
    }
    if ($plan.Errors.Count -eq 0) {
      $plan.NewContent = ConvertTo-DashboardRouteYaml $hostname
      $plan.FileAction = if ($null -eq $plan.OldContent) { 'add' } elseif ($plan.OldContent -eq $plan.NewContent) { 'unchanged' } else { 'update' }
      try { $plan.Cloudflare = Get-CloudflareServicePlan -Settings $Settings -Service (Get-DashboardPseudoService $Settings $hostname) -OtherServices $others -AccessEmails $emails -Config $cfConfig }
      catch { $plan.Errors += 'Cloudflare could not be read, so Access protection cannot be ensured: ' + $_.Exception.Message }
      $cf = $plan.Cloudflare
      if ($cf) {
        if (-not $cf.Connected) {
          $plan.Errors += 'The public dashboard needs Cloudflare automation (API token, account and tunnel), because Cloudflare Access must be in place before the route is published. The local dashboard keeps working without it.'
        } else {
          $access = @($cf.Actions | Where-Object { $_.Step -eq 'access' })
          if ($access.Count -eq 0 -or @($access | Where-Object { $_.Kind -notin @('none', 'create') }).Count -gt 0) {
            $plan.Errors += 'Cloudflare Access protection for the dashboard cannot be set up; nothing is published (fail closed).'
          }
          $plan.Errors += @($cf.Errors)
        }
      }
    }
  }
  $observed = @($plan.Hostname, $plan.FileAction, $plan.OldContent, $(if ($plan.Cloudflare) { $plan.Cloudflare.Fingerprint } else { '' }), ($plan.AccessEmails -join ','))
  $plan.Key = Get-TextSha256 (ConvertTo-Json -Compress -InputObject $observed)
  return [pscustomobject]$plan
}

# True when Cloudflare Access currently protects the hostname (read-only).
function Test-DashboardAccess($Settings, [string]$AccountId, [string]$Hostname) {
  try {
    $apps = @(Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$AccountId/access/apps" -All)
    $hit = @($apps | Where-Object {
        ($_.PSObject.Properties['domain'] -and ($_.domain -eq $Hostname -or $_.domain -like "$Hostname/*")) -or
        ($_.PSObject.Properties['self_hosted_domains'] -and @($_.self_hosted_domains) -contains $Hostname) })
    if ($hit.Count -gt 0) { return [pscustomobject]@{ Ok = $true; Message = "Access application '$($hit[0].name)' protects $Hostname." } }
    return [pscustomobject]@{ Ok = $false; Message = "No Cloudflare Access application protects $Hostname." }
  } catch { return [pscustomobject]@{ Ok = $false; Message = 'Access applications could not be read: ' + $_.Exception.Message } }
}

function Wait-TraefikRouter($Settings, [string]$Router, [switch]$Absent, [int]$TimeoutSeconds = 20) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $routers = Get-TraefikApi $Settings '/api/http/routers'
    if ($null -ne $routers) {
      $found = @($routers | Where-Object { $_.name -eq $Router }).Count -gt 0
      if ($found -ne [bool]$Absent) { return $true }
    }
    Start-Sleep -Milliseconds 700
  } while ((Get-Date) -lt $deadline)
  return $false
}

# Executes a dashboard plan. Enabling: Access (create or confirm) -> confirm Access -> validate the route in a
# throwaway Traefik -> write the route + reload -> tunnel route -> DNS. Any failure before the route is written
# leaves nothing published. Disabling: remove the route first, then the Cloudflare resources this tool created.
function Invoke-DashboardPlan {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Plan, [string[]]$ConfirmedOverwrites = @())
  if (@($Plan.Errors).Count -gt 0) { throw 'The dashboard plan has errors; nothing was changed.' }
  $steps = New-Object System.Collections.ArrayList
  $add = { param($Name, $Status, $Message) $null = $steps.Add([pscustomobject][ordered]@{ name = $Name; status = $Status; message = $Message }) }
  $ok = $true
  $routePath = Get-DashboardRoutePath $Settings
  $config = Read-DashboardConfig -Settings $Settings
  $running = Test-ContainerRunning $Settings.TraefikContainer
  $cf = $Plan.Cloudflare

  if ($Plan.Disable) {
    if (Test-Path -LiteralPath $routePath) {
      Remove-Item -LiteralPath $routePath -Force
      $msg = 'admin-dashboard.yml removed.'
      if ($running) { $w = Sync-TraefikDynamic $Settings; if ($w) { $msg += " $w" } elseif (Wait-TraefikRouter $Settings (Get-DashboardRouterName) -Absent) { $msg += ' Traefik no longer serves it.' } }
      & $add 'Remove the public dashboard route' 'Done' $msg
    }
    if ($cf -and $cf.Connected) {
      foreach ($r in @(Invoke-CloudflareServicePlan -Settings $Settings -Plan $cf -ServiceName $script:PseudoServiceName -ConfirmedOverwrites $ConfirmedOverwrites)) {
        if ($r.Status -eq 'Unchanged') { continue }
        & $add $r.Summary $r.Status $r.Message
        if ($r.Status -eq 'Failed') { $ok = $false }
      }
    }
    $config.enabled = $false; $config.enabledAt = ''
    Save-DashboardConfig -Settings $Settings -Config $config
    return [pscustomobject]@{ Ok = $ok; FailClosed = $false; Steps = $steps.ToArray() }
  }

  # 1. Access first.
  foreach ($r in @(Invoke-CloudflareServicePlan -Settings $Settings -Plan $cf -ServiceName $script:PseudoServiceName -ConfirmedOverwrites $ConfirmedOverwrites -Steps @('access'))) {
    if ($r.Status -eq 'Unchanged') { & $add $r.Summary 'Done' 'Already in place.'; continue }
    & $add $r.Summary $r.Status $r.Message
    if ($r.Status -ne 'Done') { $ok = $false }
  }
  $access = Test-DashboardAccess $Settings $cf.AccountId $Plan.Hostname
  if (-not $ok -or -not $access.Ok) {
    & $add 'Confirm Cloudflare Access protection' 'Failed' ($access.Message + ' Nothing was published: no route, tunnel route or DNS record was created (fail closed).')
    return [pscustomobject]@{ Ok = $false; FailClosed = $true; Steps = $steps.ToArray() }
  }
  & $add 'Confirm Cloudflare Access protection' 'Done' $access.Message

  # 2. Traefik route, validated first.
  if ($Plan.FileAction -ne 'unchanged') {
    $deep = Test-TraefikDynamicConfig -Settings $Settings -ExtraFiles @{ $script:RouteFile = $Plan.NewContent } -ExpectRouters @((Get-DashboardRouterName))
    if (-not $deep.Ok) {
      & $add 'Validate the route in a throwaway Traefik container' 'Failed' (@($deep.Errors) -join ' | ')
      return [pscustomobject]@{ Ok = $false; FailClosed = $true; Steps = $steps.ToArray() }
    }
    & $add 'Validate the route in a throwaway Traefik container' 'Done' 'Traefik accepted the dashboard route.'
    Write-TextFileAtomic $routePath $Plan.NewContent
    $msg = "traefik\dynamic\$($script:RouteFile) written."
    $status = 'Done'
    if ($running) {
      $w = Sync-TraefikDynamic $Settings
      if ($w) { $msg += " $w"; $status = 'Warning' }
      elseif (Wait-TraefikRouter $Settings (Get-DashboardRouterName)) { $msg += ' Traefik loaded it.' }
      else { $msg += ' Traefik has not loaded it yet.'; $status = 'Warning' }
    } else { $msg += ' Traefik is not running; it loads the route when it starts.'; $status = 'Warning' }
    & $add 'Write the dashboard route' $status $msg
  }

  # 3. Tunnel route and DNS.
  foreach ($r in @(Invoke-CloudflareServicePlan -Settings $Settings -Plan $cf -ServiceName $script:PseudoServiceName -ConfirmedOverwrites $ConfirmedOverwrites -Steps @('tunnel', 'dns'))) {
    if ($r.Status -eq 'Unchanged') { continue }
    & $add $r.Summary $r.Status $r.Message
    if ($r.Status -in @('Failed', 'Skipped')) { $ok = $false }
  }
  $config.enabled = $true; $config.subdomain = $Plan.Subdomain; $config.zoneId = $Plan.ZoneId; $config.zoneName = $Plan.ZoneName
  $config.hostname = $Plan.Hostname; $config.accessEmails = @($Plan.AccessEmails)
  if (-not $config.enabledAt) { $config.enabledAt = (Get-Date -Format 's') }
  Save-DashboardConfig -Settings $Settings -Config $config
  return [pscustomobject]@{ Ok = $ok; FailClosed = $false; Steps = $steps.ToArray() }
}

# GET with a short timeout, no redirects. Returns Status (0 = unreachable), Location, Body (first 64 KB).
function Invoke-ProbeRequest([string]$Url, [hashtable]$Headers = @{}, [string]$HostHeader) {
  $res = [pscustomobject]@{ Status = 0; Location = ''; Body = ''; Error = '' }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'; $req.Timeout = 10000; $req.ReadWriteTimeout = 10000; $req.AllowAutoRedirect = $false
    $req.UserAgent = 'traefik-proxy-webui/1 (verification)'
    if (([Uri]$Url).IsLoopback) { $req.Proxy = $null }
    if ($HostHeader) { $req.Host = $HostHeader }
    foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
    $response = $null
    try { $response = $req.GetResponse() } catch [System.Net.WebException] { if ($_.Exception.Response) { $response = $_.Exception.Response } else { throw } }
    $res.Status = [int]$response.StatusCode
    $res.Location = [string]$response.Headers['Location']
    $reader = New-Object IO.StreamReader($response.GetResponseStream())
    $buf = New-Object char[] 65536
    $n = $reader.Read($buf, 0, $buf.Length)
    if ($n -gt 0) { $res.Body = New-Object string($buf, 0, $n) }
    $reader.Close(); $response.Close()
  } catch { $res.Error = $_.Exception.Message }
  return $res
}

# Independent checks of the dashboard: local dashboard, route file, local routing through the `web` entry point
# (with and without the Access header), Cloudflare Access, tunnel route, connector, DNS and, with -Public, the
# public URL (expects a redirect to the Cloudflare Access login). Read-only. Each check: id, label, state
# (ok | failed | warning | skipped), message.
function Get-DashboardVerification {
  param([Parameter(Mandatory = $true)]$Settings, [switch]$Public)
  $checks = New-Object System.Collections.ArrayList
  $add = { param($Id, $Label, $State, $Message) $null = $checks.Add([pscustomobject][ordered]@{ id = $Id; label = $Label; state = $State; message = $Message }) }
  $config = Read-DashboardConfig -Settings $Settings
  $running = Test-ContainerRunning $Settings.TraefikContainer
  $localUrl = "http://127.0.0.1:$($Settings.DashboardPort)/dashboard/"
  if (-not $running) { & $add 'local-dashboard' 'Local dashboard (127.0.0.1)' 'failed' "Traefik ($($Settings.TraefikContainer)) is not running." }
  else {
    $r = Invoke-ProbeRequest $localUrl
    if ($r.Status -eq 200) { & $add 'local-dashboard' 'Local dashboard (127.0.0.1)' 'ok' "$localUrl answers." }
    else { & $add 'local-dashboard' 'Local dashboard (127.0.0.1)' 'failed' "$localUrl returned $(if ($r.Status) { "HTTP $($r.Status)" } else { $r.Error })." }
  }
  $h = $config.hostname
  if (-not $config.enabled -or -not $h) {
    & $add 'public' 'Public dashboard' 'skipped' 'The public dashboard is not set up.'
    return [pscustomobject]@{ Hostname = $h; LocalUrl = $localUrl; PublicUrl = ''; Checks = $checks.ToArray() }
  }
  $publicUrl = "https://$h/dashboard/"
  $expected = ConvertTo-DashboardRouteYaml $h
  $content = Get-DashboardRouteContent $Settings
  if ($content -eq $expected) { & $add 'route-file' 'Traefik route file' 'ok' "traefik\dynamic\$($script:RouteFile) is in place." }
  elseif ($null -eq $content) { & $add 'route-file' 'Traefik route file' 'failed' "traefik\dynamic\$($script:RouteFile) is missing." }
  else { & $add 'route-file' 'Traefik route file' 'warning' "traefik\dynamic\$($script:RouteFile) was changed by hand." }

  if ($running) {
    $base = "http://127.0.0.1:$($Settings.HttpPort)"
    $with = Invoke-ProbeRequest "$base/api/version" @{ $script:AccessHeader = 'local-verification' } $h
    $isTraefik = $with.Status -eq 200 -and $with.Body -match '"Version"'
    if ($isTraefik) { & $add 'local-routing' 'Local routing (web entry point)' 'ok' "Traefik routes $h/api to its API." }
    else { & $add 'local-routing' 'Local routing (web entry point)' 'failed' "Host $h on 127.0.0.1:$($Settings.HttpPort) returned $(if ($with.Status) { "HTTP $($with.Status)" } else { $with.Error })." }
    $without = Invoke-ProbeRequest "$base/dashboard/" @{} $h
    if ($without.Status -eq 404) { & $add 'fail-closed' 'Requests without Cloudflare Access are refused' 'ok' 'Without the Access header Traefik answers 404.' }
    else { & $add 'fail-closed' 'Requests without Cloudflare Access are refused' 'failed' "Without the Access header Traefik answered HTTP $($without.Status)." }
  } else {
    & $add 'local-routing' 'Local routing (web entry point)' 'skipped' 'Traefik is not running.'
  }

  $cf = Read-CloudflareConfig -Settings $Settings
  $token = Get-CloudflareApiTokenInfo -Settings $Settings
  if (-not ($token.Stored -and $token.Readable -and $cf.accountId -and $cf.tunnelId)) {
    & $add 'cloudflare' 'Cloudflare checks' 'skipped' 'Cloudflare automation is not connected, so Access, the tunnel route and DNS cannot be checked.'
  } else {
    $access = Test-DashboardAccess $Settings $cf.accountId $h
    & $add 'access' 'Cloudflare Access protection' $(if ($access.Ok) { 'ok' } else { 'failed' }) $access.Message
    try {
      $tc = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($cf.accountId)/cfd_tunnel/$($cf.tunnelId)/configurations"
      $rules = @()
      if ($tc -and $tc.PSObject.Properties['config'] -and $tc.config -and $tc.config.PSObject.Properties['ingress']) { $rules = @($tc.config.ingress | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq $h }) }
      if ($rules.Count -gt 0 -and $rules[0].service -eq 'http://traefik:80') { & $add 'tunnel-route' 'Tunnel route' 'ok' "Tunnel '$($cf.tunnelName)' sends $h to traefik:80." }
      elseif ($rules.Count -gt 0) { & $add 'tunnel-route' 'Tunnel route' 'failed' "The tunnel sends $h to $($rules[0].service)." }
      else { & $add 'tunnel-route' 'Tunnel route' 'failed' "Tunnel '$($cf.tunnelName)' has no route for $h." }
    } catch { & $add 'tunnel-route' 'Tunnel route' 'warning' $_.Exception.Message }
    try {
      $t = Invoke-CloudflareApi -Settings $Settings -Path "/accounts/$($cf.accountId)/cfd_tunnel/$($cf.tunnelId)"
      $conns = @($(if ($t.PSObject.Properties['connections']) { $t.connections } else { @() })).Count
      if ($t.status -eq 'healthy' -or $conns -gt 0) { & $add 'connector' 'Tunnel connector' 'ok' "Tunnel status $($t.status), $conns connection(s)." }
      else { & $add 'connector' 'Tunnel connector' 'warning' "Tunnel status $($t.status): cloudflared is not connected." }
    } catch { & $add 'connector' 'Tunnel connector' 'warning' $_.Exception.Message }
    $zone = @($cf.domains | Where-Object { $_.id -eq $config.zoneId })
    if ($zone.Count -eq 0) { & $add 'dns' 'DNS record' 'failed' "$($config.zoneName) is no longer an allowed domain." }
    else {
      try {
        $records = @(Invoke-CloudflareApi -Settings $Settings -Path "/zones/$($zone[0].id)/dns_records" -Query @{ name = $h } -All)
        $target = "$($cf.tunnelId).cfargotunnel.com"
        $ours = @($records | Where-Object { $_.type -eq 'CNAME' -and $_.content -eq $target })
        if ($ours.Count -gt 0 -and $ours[0].proxied) { & $add 'dns' 'DNS record' 'ok' "$h is a proxied CNAME to the tunnel." }
        elseif ($ours.Count -gt 0) { & $add 'dns' 'DNS record' 'warning' "$h points at the tunnel but is not proxied." }
        else { & $add 'dns' 'DNS record' 'failed' "$h has no CNAME to this tunnel." }
      } catch { & $add 'dns' 'DNS record' 'warning' $_.Exception.Message }
    }
  }
  if ($Public) {
    $r = Invoke-ProbeRequest $publicUrl
    if ($r.Status -ge 300 -and $r.Status -lt 400 -and $r.Location -match '^https://[^/]+\.cloudflareaccess\.com/') { & $add 'public-url' 'Public URL requires a Cloudflare login' 'ok' "$publicUrl redirects to the Cloudflare Access login." }
    elseif ($r.Status -eq 200) { & $add 'public-url' 'Public URL requires a Cloudflare login' 'failed' "$publicUrl answered without a login. Check the Access application now." }
    elseif ($r.Status) { & $add 'public-url' 'Public URL requires a Cloudflare login' 'warning' "$publicUrl returned HTTP $($r.Status)$(if ($r.Location) { " -> $($r.Location)" })." }
    else { & $add 'public-url' 'Public URL requires a Cloudflare login' 'warning' "$publicUrl is not reachable yet ($($r.Error)). New DNS records can take a few minutes." }
  }
  return [pscustomobject]@{ Hostname = $h; LocalUrl = $localUrl; PublicUrl = $publicUrl; Checks = $checks.ToArray() }
}

Export-ModuleMember -Function Get-DashboardRouteFile, Get-DashboardRouterName, Read-DashboardConfig, Save-DashboardConfig, Get-DashboardDefaultSubdomain,
  Test-DashboardSubdomain, Get-DashboardPseudoService, ConvertTo-DashboardRouteYaml, Get-DashboardRoutePath, Get-DashboardRouteContent, Get-DashboardPlan,
  Test-DashboardAccess, Invoke-DashboardPlan, Invoke-ProbeRequest, Get-DashboardVerification
