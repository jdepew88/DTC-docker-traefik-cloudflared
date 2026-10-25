#requires -version 5.1
# Identity & Access: which identity provider a deployment uses, where it runs, and how far its setup has come.
#
# config\identity.json (no secrets) records the choice, the adopted or installed authentik project, the public sign-in
# hostname, the Google settings the user entered (client ID, sign-up rules; never the client secret) and the
# applications protected by ForwardAuth. Secrets live elsewhere: the authentik API token in secrets\authentik_api.dpapi
# (SecretStore.psm1), the Google client secret only inside authentik.
#
# Get-IdentityModel is pure (facts in, steps and component states out) so the web UI, the Infrastructure Explorer and
# the tests share one definition of "configured", "awaiting user action", "reachable", "authentication required" and
# "verified". Nothing is ever marked verified from saved configuration alone.
Set-StrictMode -Version 2.0

$script:ConfigVersion = 1
$script:TokenSecretName = 'authentik_api'

function Get-IdProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Get-IdentityTokenSecretName { return $script:TokenSecretName }

# --- Providers --------------------------------------------------------------------------------------------------------

function Get-IdentityProviders {
  return @(
    [ordered]@{ id = 'authentik'; name = 'authentik'; status = 'integrated'; catalogId = 'authentik'
      summary = 'Self-hosted identity provider. The manager installs or adopts it, publishes its sign-in page, connects Google sign-in and protects selected applications with Traefik ForwardAuth.'
      features = @('install', 'adopt', 'public-hostname', 'admin-bootstrap', 'google-oauth-source', 'embedded-outpost', 'forwardauth', 'per-app-policies', 'health') }
    [ordered]@{ id = 'authelia'; name = 'Authelia'; status = 'install-only'; catalogId = 'authelia'
      summary = 'Can be installed from the App Catalog. Sign-in integration (Google, protected applications, ForwardAuth) is not implemented in this version.'
      features = @('install') }
    [ordered]@{ id = 'none'; name = 'Configure later'; status = 'integrated'; catalogId = ''
      summary = 'No self-hosted identity provider. Cloudflare Access keeps protecting published applications as before.'
      features = @() }
  )
}

# --- Configuration ------------------------------------------------------------------------------------------------------

function Get-IdentityConfigPath($Settings) { return (Join-Path $Settings.InstallPath 'config\identity.json') }

function New-IdentityConfig {
  return [pscustomobject][ordered]@{
    version = $script:ConfigVersion; provider = ''; updatedAt = ''
    authentik = [pscustomobject][ordered]@{
      project = ''; folder = ''; managed = $false; serverContainer = ''; port = 9000; localUrl = ''
      hostname = ''; service = ''; publicUrl = ''
      google = [pscustomobject][ordered]@{ slug = 'google'; clientId = ''; configuredAt = ''; verifiedAt = ''; verifiedBy = '' }
      # The initial owner (asked once): their Google address, used only to set authentik up. Who else may sign in is
      # decided in authentik; the manager keeps no user lists.
      owner = [pscustomobject][ordered]@{ email = ''; makeAdmin = $true; username = ''; verifiedAt = '' }
      apps = [pscustomobject]@{}
    }
    progress = [pscustomobject][ordered]@{ step = ''; status = ''; message = ''; at = '' }
  }
}

# Reads config\identity.json and fills in missing fields (older or partial files stay readable).
function Read-IdentityConfig {
  param([Parameter(Mandatory = $true)]$Settings)
  $cfg = New-IdentityConfig
  $path = Get-IdentityConfigPath $Settings
  if (-not (Test-Path -LiteralPath $path)) { return $cfg }
  try { $raw = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw "config\identity.json is not valid JSON: $($_.Exception.Message)" }
  $cfg.provider = [string](Get-IdProp $raw 'provider' '')
  $cfg.updatedAt = [string](Get-IdProp $raw 'updatedAt' '')
  $ra = Get-IdProp $raw 'authentik' $null
  if ($ra) {
    foreach ($k in @('project', 'folder', 'serverContainer', 'localUrl', 'hostname', 'service', 'publicUrl')) { $cfg.authentik.$k = [string](Get-IdProp $ra $k '') }
    $cfg.authentik.managed = [bool](Get-IdProp $ra 'managed' $false)
    $cfg.authentik.port = [int](Get-IdProp $ra 'port' 9000)
    $rg = Get-IdProp $ra 'google' $null
    if ($rg) {
      foreach ($k in @('slug', 'clientId', 'configuredAt', 'verifiedAt', 'verifiedBy')) { $v = Get-IdProp $rg $k $null; if ($null -ne $v) { $cfg.authentik.google.$k = [string]$v } }
    }
    $ro = Get-IdProp $ra 'owner' $null
    if ($ro) {
      foreach ($k in @('email', 'username', 'verifiedAt')) { $cfg.authentik.owner.$k = [string](Get-IdProp $ro $k '') }
      $cfg.authentik.owner.makeAdmin = [bool](Get-IdProp $ro 'makeAdmin' $true)
    }
    $apps = Get-IdProp $ra 'apps' $null
    if ($apps) { $cfg.authentik.apps = $apps }
  }
  $rp = Get-IdProp $raw 'progress' $null
  if ($rp) { foreach ($k in @('step', 'status', 'message', 'at')) { $cfg.progress.$k = [string](Get-IdProp $rp $k '') } }
  return $cfg
}

function Save-IdentityConfig {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)]$Config)
  $Config.updatedAt = (Get-Date -Format 's')
  $path = Get-IdentityConfigPath $Settings
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  Write-TextFileAtomic $path ((ConvertTo-StableJson $Config) + "`n")
}

# Records the last step the user (or the manager) worked on, so an interrupted setup resumes at the right place.
function Set-IdentityProgress($Config, [string]$Step, [string]$Status, [string]$Message = '') {
  $Config.progress = [pscustomobject][ordered]@{ step = $Step; status = $Status; message = $Message; at = (Get-Date -Format 's') }
}

function Get-IdentityApp($Config, [string]$Service) {
  $p = $Config.authentik.apps.PSObject.Properties[$Service]
  if ($p) { return $p.Value }
  return $null
}

function Set-IdentityApp($Config, [string]$Service, $Value) {
  $apps = [ordered]@{}
  foreach ($p in $Config.authentik.apps.PSObject.Properties) { if ($p.Name -ne $Service) { $apps[$p.Name] = $p.Value } }
  if ($null -ne $Value) { $apps[$Service] = $Value }
  $Config.authentik.apps = [pscustomobject]$apps
}

# --- Discovery ----------------------------------------------------------------------------------------------------------

# authentik installations on this Docker engine, from the container inventory (Get-DockerContainerInventory) and the
# apps this manager installed (config\apps.json). Grouped by Compose project; read-only.
function Find-AuthentikInstallations {
  param($Containers = @(), $Apps = @(), [string]$ProxyNetwork = '')
  $servers = @(@($Containers) | Where-Object { [string]$_.image -match '(^|/)goauthentik/server(:|@|$)' -or [string]$_.image -match '(^|/)authentik/server(:|@|$)' })
  $groups = [ordered]@{}
  foreach ($c in $servers) {
    $proj = [string](Get-IdProp (Get-IdProp $c 'compose' $null) 'project' '')
    $key = $(if ($proj) { $proj } else { "container:$($c.name)" })
    if (-not $groups.Contains($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
    $null = $groups[$key].Add($c)
  }
  $out = @()
  foreach ($key in $groups.Keys) {
    $members = @($groups[$key])
    $proj = $(if ($key.StartsWith('container:')) { '' } else { $key })
    $role = { param($c) $svc = [string](Get-IdProp (Get-IdProp $c 'compose' $null) 'service' ''); if ($svc -match 'worker' -or [string]$c.name -match 'worker') { 'worker' } else { 'server' } }
    $server = @($members | Where-Object { (& $role $_) -eq 'server' })[0]
    $worker = @($members | Where-Object { (& $role $_) -eq 'worker' })[0]
    $db = $null
    if ($proj) { $db = @(@($Containers) | Where-Object { [string](Get-IdProp (Get-IdProp $_ 'compose' $null) 'project' '') -eq $proj -and [string]$_.image -match '(^|/)postgres(:|@)' })[0] }
    $app = @(@($Apps) | Where-Object { $proj -and [string]$_.project -eq $proj })[0]
    $localPort = 0
    if ($server) { foreach ($p in @(Get-IdProp $server 'published' @())) { if ([int]$p.port -eq 9000 -and [string]$p.hostIp -in '127.0.0.1', '0.0.0.0', '') { $localPort = [int]$p.hostPort } } }
    # Version from the image reference (name:tag@sha256:...); the inventory reports pinned images' tag as "digest".
    $tag = ''
    if ($server) {
      $img = [string](Get-IdProp $server 'image' '')
      if ($img -match ':([^:@/]+)(@sha256:[0-9a-f]+)?$') { $tag = $Matches[1] } else { $tag = [string](Get-IdProp $server 'tag' '') }
      if ($tag -eq 'digest') { $tag = '' }
    }
    $state = { param($c) if ($c) { [ordered]@{ name = [string]$c.name; state = [string]$c.state; health = [string](Get-IdProp $c 'health' '') } } else { $null } }
    $out += [pscustomobject][ordered]@{
      project = $proj; managed = [bool]$app; folder = $(if ($app) { [string]$app.folder } else { '' }); appProject = $(if ($app) { [string]$app.project } else { '' })
      server = (& $state $server); worker = (& $state $worker); database = (& $state $db)
      serverContainer = $(if ($server) { [string]$server.name } else { '' })
      onProxyNetwork = [bool]($server -and $ProxyNetwork -and @(@(Get-IdProp $server 'networks' @()) | Where-Object { [string]$_.name -eq $ProxyNetwork }).Count)
      localPort = $localPort; localUrl = $(if ($localPort) { "http://127.0.0.1:$localPort" } else { '' }); version = $tag
    }
  }
  # Prepared but never started (manager-installed, no containers yet).
  foreach ($a in @(@($Apps) | Where-Object { [string]$_.appId -eq 'authentik' })) {
    if (@($out | Where-Object { $_.project -eq [string]$a.project }).Count) { continue }
    $out += [pscustomobject][ordered]@{ project = [string]$a.project; managed = $true; folder = [string]$a.folder; appProject = [string]$a.project; server = $null; worker = $null; database = $null
      serverContainer = ''; onProxyNetwork = $false; localPort = [int](Get-IdProp $a 'localPort' 0); localUrl = [string](Get-IdProp $a 'localUrl' ''); version = '' }
  }
  return $out
}

# Suggested public sign-in hostname for a domain.
function Get-SuggestedAuthHostname([string]$Domain) { if ($Domain) { return "auth.$($Domain.ToLowerInvariant())" }; return '' }

# --- Model (pure) -------------------------------------------------------------------------------------------------------

function New-IdState([string]$Id, [string]$Label, [string]$State, [string]$Message, [string]$Action = '', [bool]$Optional = $false) {
  return [ordered]@{ id = $Id; label = $Label; state = $State; message = $Message; action = $Action; optional = $Optional }
}

# The first failed step, else the first step waiting for the user (same rule as TPMLogic.identityNextStep).
function Get-IdentityNextStep($Steps) {
  $f = @(@($Steps) | Where-Object { $_.state -eq 'failed' })
  if ($f.Count) { return $f[0].id }
  $w = @(@($Steps) | Where-Object { $_.state -eq 'awaiting-user' })
  if ($w.Count) { return $w[0].id }
  return $null
}

# $Facts: provider, install (one of Find-AuthentikInstallations or $null), health (Get-AuthentikHealth), token
# (@{ stored; readable; ok; username; superuser; message }), overview (Get-AuthentikOverview or $null), overviewError,
# hostname, publicUrl, route (@{ exists; enabled; router; publish; access; service }), cloudflare (@{ connected; dns;
# tunnel }), publicCheck (@{ state; message }), google (@{ clientId; source (view or $null); redirect (Test-AuthentikGoogleRedirect);
# logins; verifiedAt }), apps (list of @{ service; hostname; protected; authentik (bool: objects exist); challenge
# (Test-ForwardAuthChallenge); verifiedAt }).
# Returns steps (the guided setup) and components (health rows for the Explorer) with these states:
#   not-configured, configured, awaiting-user, reachable, auth-required, verified, failed, skipped.
function Get-IdentityModel {
  param([Parameter(Mandatory = $true)]$Facts)
  $f = $Facts
  $steps = New-Object System.Collections.ArrayList
  $comp = New-Object System.Collections.ArrayList
  $provider = [string](Get-IdProp $f 'provider' '')
  $add = { param($list, $item) $null = $list.Add($item) }

  if (-not $provider) { & $add $steps (New-IdState 'provider' 'Choose an identity provider' 'awaiting-user' 'authentik, or configure later. Basic Deployment Manager setup does not need one.' 'choose-provider') }
  elseif ($provider -eq 'none') { & $add $steps (New-IdState 'provider' 'Identity provider' 'skipped' 'Configure later: no self-hosted identity provider. Cloudflare Access keeps working as before.' 'choose-provider') }
  elseif ($provider -eq 'authelia') { & $add $steps (New-IdState 'provider' 'Identity provider: Authelia' 'not-configured' 'Authelia can be installed from the App Catalog; its sign-in integration is not implemented in this version.' 'choose-provider') }
  else { & $add $steps (New-IdState 'provider' 'Identity provider: authentik' 'configured' 'authentik is the identity provider of this deployment.' 'choose-provider') }
  if ($provider -ne 'authentik') { return [ordered]@{ steps = $steps.ToArray(); components = $comp.ToArray(); next = @(Get-IdentityNextStep $steps) } }

  # Installation.
  $inst = Get-IdProp $f 'install' $null
  $health = Get-IdProp $f 'health' $null
  $srv = $(if ($inst) { Get-IdProp $inst 'server' $null } else { $null })
  $running = [bool]($srv -and (Get-IdProp $srv 'state' $null) -eq 'running')
  if (-not $inst) { & $add $steps (New-IdState 'install' 'Install or adopt authentik' 'awaiting-user' 'No authentik installation is recorded. Install it from the catalog or adopt one found on this PC.' 'install') }
  elseif (-not $srv) { & $add $steps (New-IdState 'install' 'Install authentik' 'awaiting-user' "The project '$((Get-IdProp $inst 'project' $null))' is prepared but has not been started." 'start') }
  elseif (-not $running) { & $add $steps (New-IdState 'install' 'authentik containers' 'failed' "authentik ($((Get-IdProp $srv 'name' $null))) is $((Get-IdProp $srv 'state' $null))." 'start') }
  elseif ($health -and (Get-IdProp $health 'Ready' $null)) { & $add $steps (New-IdState 'install' 'authentik is running' 'reachable' "Project '$((Get-IdProp $inst 'project' $null))'$(if ((Get-IdProp $inst 'version' $null)) { ", version $((Get-IdProp $inst 'version' $null))" }); database ready.") }
  else { & $add $steps (New-IdState 'install' 'authentik is starting' 'configured' $(if ($health) { [string](Get-IdProp $health 'Message' $null) } else { 'Waiting for authentik to answer.' })) }
  foreach ($role in @('server', 'worker', 'database')) {
    $c = $(if ($inst) { Get-IdProp $inst $role $null } else { $null })
    $label = @{ server = 'authentik server'; worker = 'authentik worker'; database = 'PostgreSQL (authentik)' }[$role]
    if (-not $c) { & $add $comp (New-IdState $role $label 'not-configured' 'No container.'); continue }
    $st = $(if ((Get-IdProp $c 'state' $null) -ne 'running') { 'failed' } elseif ((Get-IdProp $c 'health' $null) -eq 'unhealthy') { 'failed' } elseif ((Get-IdProp $c 'health' $null) -eq 'healthy') { 'verified' } else { 'reachable' })
    & $add $comp (New-IdState $role $label $st "$((Get-IdProp $c 'name' $null)): $((Get-IdProp $c 'state' $null))$(if ((Get-IdProp $c 'health' $null)) { " ($((Get-IdProp $c 'health' $null)))" })")
  }
  if ($inst -and $srv) {
    & $add $comp (New-IdState 'network' 'Shared proxy network' $(if ((Get-IdProp $inst 'onProxyNetwork' $null)) { 'verified' } else { 'failed' }) $(if ((Get-IdProp $inst 'onProxyNetwork' $null)) { "$((Get-IdProp $inst 'serverContainer' $null)) is on the shared network (Traefik reaches it by name)." } else { "$((Get-IdProp $inst 'serverContainer' $null)) is not on the shared network: Traefik cannot reach it." }))
  }

  # Administrator.
  $setup = $(if ($health) { [string](Get-IdProp $health 'Setup' $null) } else { 'unknown' })
  if (-not $running) { & $add $steps (New-IdState 'admin' 'Administrator account' 'not-configured' 'Waits for authentik to run.') }
  elseif ($setup -eq 'pending') { & $add $steps (New-IdState 'admin' 'Administrator account' 'awaiting-user' 'Nobody has claimed this authentik yet: open the initial setup on this PC now and set the akadmin password (anyone who reaches it first could).' 'initial-setup') }
  elseif ($setup -eq 'done') { & $add $steps (New-IdState 'admin' 'Administrator account' 'configured' 'The initial setup is complete (akadmin has a password). The manager never resets it.') }
  else { & $add $steps (New-IdState 'admin' 'Administrator account' 'configured' 'authentik is still starting; the setup state is not known yet.') }
  & $add $comp (New-IdState 'admin' 'Administrator setup' $(if ($setup -eq 'done') { 'configured' } elseif ($setup -eq 'pending') { 'awaiting-user' } else { 'not-configured' }) "Initial setup: $setup.")

  # API connection.
  $token = Get-IdProp $f 'token' $null
  $ov = Get-IdProp $f 'overview' $null
  $tokOk = [bool]($token -and (Get-IdProp $token 'ok' $null))
  if (-not $running) { & $add $steps (New-IdState 'api' 'Connect the manager to authentik' 'not-configured' 'Waits for authentik to run.') }
  elseif (-not ($token -and (Get-IdProp $token 'stored' $null))) { & $add $steps (New-IdState 'api' 'Connect the manager to authentik' 'awaiting-user' 'Save an authentik API token (created automatically for installations made by the manager).' 'token') }
  elseif (-not (Get-IdProp $token 'readable' $null)) { & $add $steps (New-IdState 'api' 'Connect the manager to authentik' 'failed' 'The saved token cannot be decrypted by this Windows account. Save it again.' 'token') }
  elseif (-not $tokOk) { & $add $steps (New-IdState 'api' 'Connect the manager to authentik' 'failed' ([string](Get-IdProp $token 'message' $null)) 'token') }
  elseif (-not (Get-IdProp $token 'superuser' $null)) { & $add $steps (New-IdState 'api' 'Connected to authentik' 'failed' "The token belongs to '$((Get-IdProp $token 'username' $null))', who is not an authentik administrator; the manager cannot create sources and applications with it." 'token') }
  else { & $add $steps (New-IdState 'api' 'Connected to authentik' 'verified' "API token of '$((Get-IdProp $token 'username' $null))' works$(if ($ov) { " (authentik $($ov.Version))" }).") }
  & $add $comp (New-IdState 'api' 'authentik API connection' $(if ($tokOk -and (Get-IdProp $token 'superuser' $null)) { 'verified' } elseif ($token -and (Get-IdProp $token 'stored' $null)) { 'failed' } else { 'not-configured' }) $(if ($tokOk) { "As $((Get-IdProp $token 'username' $null))." } elseif ($token -and (Get-IdProp $token 'stored' $null)) { [string](Get-IdProp $token 'message' $null) } else { 'No token saved.' }))
  if ($ov -and @($ov.MissingFlows).Count) { & $add $comp (New-IdState 'flows' 'authentik default flows' 'configured' "Still being created: $(@($ov.MissingFlows) -join ', ').") }

  # Initial owner (asked once; verified by their first Google sign-in, which authentik checks against this address).
  $own = Get-IdProp $f 'owner' $null
  $ownEmail = [string](Get-IdProp $own 'email' '')
  $ownVerified = [string](Get-IdProp $own 'verifiedAt' '')
  $gfact = Get-IdProp $f 'google' $null
  $hasSource = [bool]($gfact -and (Get-IdProp $gfact 'source' $null))
  if ($ownVerified) { & $add $steps (New-IdState 'owner' 'Initial owner' 'verified' "$ownEmail signed in with Google as '$((Get-IdProp $own 'username' ''))' ($ownVerified) and is in the owner group. From now on users and access are managed in authentik." 'owner') }
  elseif (-not $ownEmail) { & $add $steps (New-IdState 'owner' 'Initial owner' $(if ($tokOk) { 'awaiting-user' } else { 'not-configured' }) 'Enter the Google account of the person who owns this authentik (asked once).' 'owner') }
  elseif (-not $hasSource) { & $add $steps (New-IdState 'owner' 'Initial owner' 'configured' "$ownEmail will be the only Google account that may create an account at first (set up with Google sign-in)." 'owner') }
  else { & $add $steps (New-IdState 'owner' 'Initial owner' 'awaiting-user' "Sign in once with Google as $ownEmail on the sign-in page, then check again here." 'owner') }

  # Public hostname.
  $hostname = [string](Get-IdProp $f 'hostname' '')
  $route = Get-IdProp $f 'route' $null
  $cf = Get-IdProp $f 'cloudflare' $null
  $pub = Get-IdProp $f 'publicCheck' $null
  if (-not $hostname) { & $add $steps (New-IdState 'hostname' 'Public sign-in address' 'awaiting-user' 'Choose the hostname of the sign-in page (for example auth.<your domain>).' 'hostname') }
  elseif (-not ($route -and (Get-IdProp $route 'exists' $null))) { & $add $steps (New-IdState 'hostname' "Route $hostname" 'awaiting-user' "Create the Traefik route for $hostname (preview first)." 'hostname') }
  elseif ((Get-IdProp $route 'router' $null) -ne 'enabled') { & $add $steps (New-IdState 'hostname' "Route $hostname" 'failed' "Traefik has not loaded the route (router: $((Get-IdProp $route 'router' $null)))." 'hostname') }
  elseif ($pub -and (Get-IdProp $pub 'state' $null) -eq 'ok') { & $add $steps (New-IdState 'hostname' "https://$hostname" 'verified' ([string](Get-IdProp $pub 'message' $null))) }
  elseif ((Get-IdProp $route 'publish' $null) -and -not ($cf -and (Get-IdProp $cf 'dns' $null))) { & $add $steps (New-IdState 'hostname' "https://$hostname" 'configured' 'The route exists; the Cloudflare DNS record and tunnel route are not created yet (or Cloudflare is not connected).' 'hostname') }
  else { & $add $steps (New-IdState 'hostname' "Route $hostname" 'configured' "Traefik routes $hostname to authentik$(if ((Get-IdProp $route 'publish' $null)) { '; DNS and tunnel route are recorded' } else { ' (local only, not published)' }). Run the public check to verify it." 'hostname') }
  & $add $comp (New-IdState 'route' 'Traefik route (sign-in page)' $(if ($route -and (Get-IdProp $route 'exists' $null) -and (Get-IdProp $route 'router' $null) -eq 'enabled') { 'configured' } elseif ($route -and (Get-IdProp $route 'exists' $null)) { 'failed' } else { 'not-configured' }) $(if ($route -and (Get-IdProp $route 'exists' $null)) { "svc-$((Get-IdProp $route 'service' $null)): router $((Get-IdProp $route 'router' $null))" } else { 'No route.' }))
  & $add $comp (New-IdState 'cloudflare' 'Cloudflare DNS and tunnel' $(if ($cf -and (Get-IdProp $cf 'dns' $null) -and (Get-IdProp $cf 'tunnel' $null)) { 'configured' } elseif ($route -and (Get-IdProp $route 'exists' $null) -and -not (Get-IdProp $route 'publish' $null)) { 'skipped' } else { 'not-configured' }) $(if ($cf -and (Get-IdProp $cf 'dns' $null)) { "DNS record$(if ((Get-IdProp $cf 'tunnel' $null)) { ' and tunnel route' }) created by the manager." } else { 'Not published through Cloudflare.' }))
  & $add $comp (New-IdState 'public' 'Public sign-in page' $(if ($pub) { @{ ok = 'verified'; failed = 'failed' }[[string](Get-IdProp $pub 'state' $null)] } else { 'not-configured' }) $(if ($pub) { [string](Get-IdProp $pub 'message' $null) } else { 'Not checked.' }))

  # Embedded outpost.
  $publicUrl = [string](Get-IdProp $f 'publicUrl' '')
  if ($ov -and $ov.Outpost) {
    $hostOk = ($ov.Outpost.AuthentikHost.TrimEnd('/') -eq $publicUrl.TrimEnd('/')) -and $publicUrl
    & $add $comp (New-IdState 'outpost' 'Embedded outpost' $(if ($hostOk) { 'configured' } else { 'not-configured' }) $(if ($hostOk) { "Sends browsers to $publicUrl; serves $(@($ov.Outpost.Providers).Count) provider(s)." } else { "authentik_host is '$($ov.Outpost.AuthentikHost)'; it should be the public URL$(if ($publicUrl) { " $publicUrl" })." }))
  }

  # Google.
  $g = Get-IdProp $f 'google' $null
  $src = $(if ($g) { Get-IdProp $g 'source' $null } else { $null })
  $redir = $(if ($g) { Get-IdProp $g 'redirect' $null } else { $null })
  $verifiedAt = $(if ($g) { [string](Get-IdProp $g 'verifiedAt' '') } else { '' })
  if (-not $tokOk) { & $add $steps (New-IdState 'google' 'Google sign-in' 'not-configured' 'Needs the API connection first.' '' $true) }
  elseif (-not $publicUrl) { & $add $steps (New-IdState 'google' 'Google sign-in' 'not-configured' 'Needs the public sign-in address first (Google only accepts https redirect URIs).' '' $true) }
  elseif (-not $src) { & $add $steps (New-IdState 'google' 'Google sign-in' 'awaiting-user' $(if ($g -and (Get-IdProp $g 'clientId' $null)) { 'Client ID saved. Enter the client secret to finish (Google shows it only once).' } else { 'Create a Google OAuth client (guided), then paste its client ID and secret.' }) 'google' $true) }
  elseif ($verifiedAt) { & $add $steps (New-IdState 'google' 'Google sign-in' 'verified' "A real Google sign-in succeeded$(if ((Get-IdProp $g 'verifiedBy' $null)) { " ($((Get-IdProp $g 'verifiedBy' $null)))" }) at $verifiedAt." 'google' $true) }
  elseif ($ownVerified) { & $add $steps (New-IdState 'google' 'Google sign-in' 'verified' "The owner signed in with Google at $ownVerified." 'google' $true) }
  elseif ($redir -and -not (Get-IdProp $redir 'ok' $null)) { & $add $steps (New-IdState 'google' 'Google sign-in' 'failed' ([string](Get-IdProp $redir 'message' $null)) 'google' $true) }
  else { & $add $steps (New-IdState 'google' 'Google sign-in' 'configured' "The Google source is configured$(if ($redir -and (Get-IdProp $redir 'ok' $null)) { ' and redirects correctly' }). Not verified until someone signs in with Google." 'google' $true) }
  & $add $comp (New-IdState 'google-source' 'Google OAuth source' $(if ($src) { 'configured' } else { 'not-configured' }) $(if ($src) { "Source '$((Get-IdProp $src 'Slug' $null))', client $((Get-IdProp $src 'ConsumerKey' $null))" } else { 'No Google source.' }))
  & $add $comp (New-IdState 'google-callback' 'OAuth callback configuration' $(if ($redir) { $(if ((Get-IdProp $redir 'ok' $null)) { 'configured' } else { 'failed' }) } else { 'not-configured' }) $(if ($redir) { [string](Get-IdProp $redir 'message' $null) } else { 'Not checked.' }))
  if ($ownVerified -and -not $verifiedAt) { $verifiedAt = $ownVerified }
  & $add $comp (New-IdState 'google-login' 'Real Google sign-in' $(if ($verifiedAt) { 'verified' } elseif ($src) { 'awaiting-user' } else { 'not-configured' }) $(if ($verifiedAt) { "Last confirmed $verifiedAt." } elseif ($src) { 'Sign in with a Google account to verify.' } else { '' }))

  # Protected applications.
  $apps = @(Get-IdProp $f 'apps' @())
  $protected = @($apps | Where-Object { $_.protected })
  if (-not $tokOk) { & $add $steps (New-IdState 'apps' 'Protect applications' 'not-configured' 'Needs the API connection first.' '' $true) }
  elseif (-not $protected.Count) { & $add $steps (New-IdState 'apps' 'Protect applications' 'awaiting-user' 'Select the applications to put behind authentik sign-in.' 'protect' $true) }
  else {
    $bad = @($protected | Where-Object { $_.challenge -and $_.challenge.State -in 'open', 'loop', 'failed' })
    $ver = @($protected | Where-Object { $_.verifiedAt })
    $st = $(if ($bad.Count) { 'failed' } elseif ($ver.Count -eq $protected.Count) { 'verified' } elseif (@($protected | Where-Object { $_.challenge -and $_.challenge.State -eq 'auth' }).Count) { 'auth-required' } else { 'configured' })
    & $add $steps (New-IdState 'apps' 'Protected applications' $st "$($protected.Count) protected$(if ($bad.Count) { "; problem: $(@($bad | ForEach-Object { "$($_.service): $($_.challenge.Message)" }) -join ' ')" })." 'protect' $true)
  }
  foreach ($a in $protected) {
    $c = Get-IdProp $a 'challenge' $null
    $st = $(if ((Get-IdProp $a 'verifiedAt' $null)) { 'verified' } elseif (-not (Get-IdProp $a 'authentik' $null)) { 'failed' } elseif ($c) { @{ auth = 'auth-required'; open = 'failed'; loop = 'failed'; failed = 'failed' }[[string](Get-IdProp $c 'State' $null)] } else { 'configured' })
    $msg = $(if (-not (Get-IdProp $a 'authentik' $null)) { 'The authentik application or provider is missing.' } elseif ($c) { [string](Get-IdProp $c 'Message' $null) } else { 'ForwardAuth middleware and authentik application are configured.' })
    & $add $comp (New-IdState "app:$((Get-IdProp $a 'service' $null))" "ForwardAuth: $((Get-IdProp $a 'hostname' $null))" $st $msg)
  }
  return [ordered]@{ steps = $steps.ToArray(); components = $comp.ToArray(); next = @(Get-IdentityNextStep $steps) }
}

Export-ModuleMember -Function Get-IdentityTokenSecretName, Get-IdentityProviders, Get-IdentityConfigPath, New-IdentityConfig, Read-IdentityConfig, Save-IdentityConfig, Set-IdentityProgress,
  Get-IdentityApp, Set-IdentityApp, Find-AuthentikInstallations, Get-SuggestedAuthHostname, Get-IdentityModel
