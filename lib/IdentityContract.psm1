#requires -version 5.1
# The contract between the provisioning engine and Identity & Access (docs/provisioning.md, "Identity contract").
#
# The provisioner never talks to authentik itself. It asks Identity & Access, through the functions in webui.ps1's
# "Identity contract" section, which are thin wrappers over the existing implementation (Authentik.psm1,
# IdentityProvider.psm1, the protect/unprotect pipeline). This module holds the pure decisions both sides share:
#   1. providers and their readiness            Get-ContractProviders, Get-IdentityReadiness
#   2. can this application be protected?       Get-ProtectionCompatibility
#   3. which access choices make sense          Get-ProvisionAuthOptions
#   4. what an approved operation owns          New-ProvisionJournal, Add-JournalResource
#   5. what a rollback may undo                 Get-ProvisionRollbackPlan (only what the operation created or changed)
Set-StrictMode -Version 2.0

function Get-IcProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

# Pure: readiness of the configured authentik for protecting new applications, from Identity & Access facts:
# { provider; installFound; running; onProxyNetwork; tokenOk; outpost; outpostBrowserHostOk; publicUrl; ownersGroup }.
function Get-IdentityReadiness($Facts) {
  $missing = New-Object System.Collections.ArrayList
  $m = { param($id, $msg) $null = $missing.Add([ordered]@{ id = $id; message = $msg }) }
  if ([string](Get-IcProp $Facts 'provider' '') -ne 'authentik') { & $m 'provider' 'authentik is not the chosen identity provider (Identity & Access).' }
  else {
    if (-not (Get-IcProp $Facts 'installFound' $false)) { & $m 'install' 'No authentik installation is adopted or installed.' }
    elseif (-not (Get-IcProp $Facts 'running' $false)) { & $m 'running' 'authentik is not running.' }
    if ((Get-IcProp $Facts 'installFound' $false) -and -not (Get-IcProp $Facts 'onProxyNetwork' $false)) { & $m 'network' 'authentik is not on the shared proxy network, so Traefik cannot ask it.' }
    if (-not (Get-IcProp $Facts 'tokenOk' $false)) { & $m 'token' 'The authentik API token is missing or not accepted.' }
    if ((Get-IcProp $Facts 'tokenOk' $false) -and -not (Get-IcProp $Facts 'outpost' $false)) { & $m 'outpost' 'authentik has no embedded outpost.' }
    if (-not [string](Get-IcProp $Facts 'publicUrl' '') -and -not (Get-IcProp $Facts 'outpostBrowserHostOk' $false)) { & $m 'public-url' 'The public sign-in address is not set, so sign-in redirects would only work on this PC.' }
    if ((Get-IcProp $Facts 'tokenOk' $false) -and -not (Get-IcProp $Facts 'ownersGroup' $false)) { & $m 'owners' 'The owner group does not exist yet (finish the owner step of Identity & Access); new applications start as owner-only.' }
  }
  $ready = -not $missing.Count
  return [ordered]@{ ready = $ready; state = $(if ($ready) { 'ready' } elseif ([string](Get-IcProp $Facts 'provider' '') -ne 'authentik') { 'not-configured' } else { 'not-ready' }); missing = @($missing) }
}

# Pure: providers as the provisioner sees them (from Get-IdentityProviders plus readiness).
function Get-ContractProviders([object[]]$Providers, $Readiness) {
  return @($Providers | ForEach-Object {
      $id = [string](Get-IcProp $_ 'id' '')
      $canProtect = $id -eq 'authentik' -and [string](Get-IcProp $_ 'status' '') -eq 'integrated'
      [ordered]@{ id = $id; name = [string](Get-IcProp $_ 'name' $id); status = [string](Get-IcProp $_ 'status' ''); canProtectApplications = $canProtect
        ready = $(if ($canProtect) { [bool]$Readiness.ready } else { $false })
        detail = $(if ($canProtect) { $(if ($Readiness.ready) { 'Ready to protect applications.' } else { (@($Readiness.missing) | ForEach-Object { $_.message }) -join ' ' }) } elseif ($id -eq 'authelia') { 'Install only: application protection with Authelia is not implemented in this version.' } else { [string](Get-IcProp $_ 'summary' '') }) }
    } | Where-Object { $_.id -ne 'none' })
}

# Applications whose own clients (mobile, desktop, sync, API) sign in with the application's own login and cannot pass
# a browser sign-in page. Generic ForwardAuth breaks them unless those paths bypass it or native OIDC is used.
$script:ClientApps = [ordered]@{
  'jellyfin|emby|plex' = 'Media apps on TVs and phones sign in with the server''s own accounts; ForwardAuth blocks them.'
  'immich' = 'The Immich mobile app uses the API with its own login; ForwardAuth blocks it. Immich supports OAuth/OIDC natively.'
  'nextcloud|owncloud' = 'Sync clients and WebDAV use their own credentials; ForwardAuth blocks them. Nextcloud supports OIDC natively.'
  'vaultwarden|bitwarden' = 'Bitwarden clients use the API; ForwardAuth blocks them.'
  'home-?assistant' = 'The companion apps use their own login; ForwardAuth blocks them.'
  'navidrome|subsonic|audiobookshelf' = 'Players use the app''s own API login; ForwardAuth blocks them.'
  'gitea|forgejo|gitlab' = 'git over HTTPS uses the app''s own credentials; ForwardAuth blocks it. OIDC is supported natively.'
  'rocket-?chat|mattermost|synapse|matrix' = 'Chat clients and federation use their own authentication; ForwardAuth blocks them.'
  'paperless' = 'The mobile apps use the API token; ForwardAuth blocks them. OIDC is supported natively.'
}

# Pure: whether generic ForwardAuth suits this application. Returns { forwardAuth: compatible | caution;
# nativeOidc: bool; reasons[]; recommendation }.
function Get-ProtectionCompatibility($Manifest) {
  $reasons = New-Object System.Collections.ArrayList
  $key = (@([string](Get-IcProp $Manifest 'id' ''), [string](Get-IcProp $Manifest 'name' ''), [string](Get-IcProp (Get-IcProp $Manifest 'source' $null) 'upstream' '')) -join ' ').ToLowerInvariant()
  $caution = $false
  foreach ($p in $script:ClientApps.Keys) { if ($key -match $p) { $null = $reasons.Add($script:ClientApps[$p]); $caution = $true } }
  $envNames = @()
  $svcs = Get-IcProp $Manifest 'services' $null
  $entries = $(if ($svcs -is [System.Collections.IDictionary]) { @($svcs.Values) } elseif ($svcs) { @($svcs.PSObject.Properties | ForEach-Object { $_.Value }) } else { @() })
  foreach ($s in $entries) { $e = Get-IcProp $s 'environment' $null; if ($e -is [System.Collections.IDictionary]) { $envNames += @($e.Keys) } elseif ($e) { $envNames += @($e.PSObject.Properties | ForEach-Object { $_.Name }) } }
  $oidc = [bool](@($envNames | Where-Object { [string]$_ -match '^(OIDC|OAUTH|OPENID|SSO|AUTH_OIDC|GENERIC_OAUTH)' }).Count) -or [string](Get-IcProp (Get-IcProp $Manifest 'authentication' $null) 'native' '') -match 'oidc|saml'
  if ($oidc) { $null = $reasons.Add('The application has its own OIDC/OAuth settings: connecting it to authentik as an OIDC client gives single sign-on without blocking its clients (configured in authentik and the app, not by ForwardAuth).') }
  $null = $reasons.Add('ForwardAuth asks authentik before every request: browsers are sent to sign in; WebSockets keep working after sign-in; webhooks, APIs and callbacks from other services are refused unless they carry a session.')
  return [ordered]@{ forwardAuth = $(if ($caution) { 'caution' } else { 'compatible' }); nativeOidc = $oidc; reasons = @($reasons)
    recommendation = $(if ($caution -and $oidc) { 'Prefer the application''s own OIDC sign-in with authentik, or Cloudflare Access for browsers only.' } elseif ($caution) { 'ForwardAuth protects the browser interface but blocks the application''s own clients.' } else { 'ForwardAuth with authentik suits this application.' }) }
}

# Pure: the "who should have access" choices for a deployment, given where it is reachable ('local', 'lan',
# 'public'), Identity & Access readiness and whether Cloudflare can publish. Each: { id; available; recommended;
# reason; requiresAck }.
function Get-ProvisionAuthOptions([string]$Access, $Readiness, [bool]$CloudflareReady, $Compatibility) {
  $opts = @()
  $akReady = [bool](Get-IcProp $Readiness 'ready' $false)
  $routed = $Access -in 'lan', 'public'
  $opts += [ordered]@{ id = 'authentik'; name = 'authentik (sign in with your accounts)'; available = ($akReady -and $routed)
    recommended = ($akReady -and $routed -and [string](Get-IcProp $Compatibility 'forwardAuth' '') -eq 'compatible')
    reason = $(if (-not $routed) { 'Needs a Traefik route (LAN or public access).' } elseif (-not $akReady) { 'Identity & Access is not ready: ' + ((@(Get-IcProp $Readiness 'missing' @()) | ForEach-Object { $_.message }) -join ' ') } elseif ([string](Get-IcProp $Compatibility 'forwardAuth' '') -eq 'caution') { [string](Get-IcProp $Compatibility 'recommendation' '') } else { 'Visitors sign in with authentik (owner-only until you add access rules in authentik).' })
    requiresAck = $false }
  $opts += [ordered]@{ id = 'cloudflare-access'; name = 'Cloudflare Access'; available = ($Access -eq 'public' -and $CloudflareReady); recommended = ($Access -eq 'public' -and $CloudflareReady -and -not $akReady)
    reason = $(if ($Access -ne 'public') { 'Only for public hostnames.' } elseif (-not $CloudflareReady) { 'Cloudflare is not connected (token and tunnel).' } else { 'Cloudflare asks for an email code or your identity provider before the request reaches this PC.' }); requiresAck = $false }
  $opts += [ordered]@{ id = 'native'; name = 'The application''s own login'; available = $true; recommended = $false
    reason = $(if ($Access -eq 'public') { 'Only the application''s own login protects it on the Internet.' } else { 'The application''s own login.' }); requiresAck = ($Access -eq 'public') }
  $opts += [ordered]@{ id = 'none'; name = 'No additional sign-in'; available = ($Access -ne 'public'); recommended = ($Access -eq 'local')
    reason = $(if ($Access -eq 'public') { 'Not offered for public hostnames: choose a sign-in, or the application''s own login with an explicit acknowledgement.' } elseif ($Access -eq 'lan') { 'Anyone on your network can open it.' } else { 'Only this PC can open it.' }); requiresAck = ($Access -eq 'lan') }
  $opts += [ordered]@{ id = 'authelia'; name = 'Authelia'; available = $false; recommended = $false; reason = 'Not implemented in this version (Authelia can be installed from the catalog, but not connected yet).'; requiresAck = $false }
  return $opts
}

# --- Ownership journal ------------------------------------------------------------------------------------------------

# A journal records, for one approved operation, every resource it touched: kind, name, ownership ('created',
# 'reused', 'modified', 'shared') and how to undo it. Rollback acts only on 'created' and 'modified' entries.
function New-ProvisionJournal([string]$OperationId, [string]$Summary) {
  return [ordered]@{ operationId = $OperationId; summary = $Summary; startedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; state = 'running'; resources = @(); stages = @() }
}

function Add-JournalResource($Journal, [string]$Kind, [string]$Name, [string]$Ownership, [string]$Detail = '', $Undo = $null) {
  if ($Ownership -notin 'created', 'reused', 'modified', 'shared') { throw "Unknown ownership '$Ownership'." }
  $Journal.resources = @($Journal.resources) + [ordered]@{ kind = $Kind; name = $Name; ownership = $Ownership; detail = $Detail; undo = $Undo; at = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
}

function Add-JournalStage($Journal, [string]$Stage, [string]$Status, [string]$Message = '') {
  $Journal.stages = @($Journal.stages) + [ordered]@{ stage = $Stage; status = $Status; message = $Message; at = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
}

# Resource kinds that are shared infrastructure: never removed by a rollback, whatever the journal says.
$script:SharedKinds = @('proxy-network', 'cloudflare-tunnel', 'authentik-install', 'authentik-outpost', 'authentik-owners-group', 'authentik-google-source', 'authentik-flow', 'traefik-middleware-shared')

# Pure: the steps a rollback performs, newest first: created resources are removed, modified ones restored, reused and
# shared ones are listed as kept. Data volumes are kept unless $DeleteData (separate, explicit choice).
function Get-ProvisionRollbackPlan($Journal, [switch]$DeleteData) {
  $steps = @(); $kept = @()
  $res = @(Get-IcProp $Journal 'resources' @())
  for ($i = $res.Count - 1; $i -ge 0; $i--) {
    $r = $res[$i]
    $kind = [string](Get-IcProp $r 'kind' ''); $own = [string](Get-IcProp $r 'ownership' '')
    if ($script:SharedKinds -contains $kind -or $own -in 'reused', 'shared') { $kept += [ordered]@{ kind = $kind; name = [string](Get-IcProp $r 'name' ''); why = $(if ($script:SharedKinds -contains $kind -or $own -eq 'shared') { 'shared with other applications' } else { 'existed before this operation' }) }; continue }
    if ($kind -eq 'data-volume' -and -not $DeleteData) { $kept += [ordered]@{ kind = $kind; name = [string](Get-IcProp $r 'name' ''); why = 'data is kept unless you choose to delete it' }; continue }
    $steps += [ordered]@{ kind = $kind; name = [string](Get-IcProp $r 'name' ''); action = $(if ($own -eq 'created') { 'remove' } else { 'restore' }); undo = (Get-IcProp $r 'undo' $null); detail = [string](Get-IcProp $r 'detail' '') }
  }
  return [ordered]@{ steps = $steps; kept = $kept }
}

Export-ModuleMember -Function Get-IdentityReadiness, Get-ContractProviders, Get-ProtectionCompatibility, Get-ProvisionAuthOptions, New-ProvisionJournal, Add-JournalResource, Add-JournalStage, Get-ProvisionRollbackPlan
