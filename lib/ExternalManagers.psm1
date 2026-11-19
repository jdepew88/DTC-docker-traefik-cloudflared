Set-StrictMode -Version 2.0

# Optional, read-only connectors to the tools that own applications DTC integrates or observes (docs/universal-apps.md,
# "Portainer and Arcane"). They only add evidence: stack identity, managed containers, Compose project, services,
# deployment status, networks and source references. Discovery from the Docker API keeps working without them, and
# nothing here can change a stack: only GET requests are ever sent.
#
#   Portainer CE 2.x (catalog: 2.45): header X-API-Key; GET /api/endpoints, GET /api/stacks,
#     GET /api/endpoints/{id}/docker/containers/json?all=1 (Docker proxy, read). An access token carries ALL the rights
#     of the user who created it; Portainer CE has no read-only role, so the token cannot be restricted. Use a
#     dedicated non-admin user that only sees the environments DTC should read. DTC still sends GET requests only.
#   Arcane 2.x (catalog: 2.16): header X-Api-Key; GET /api/environments, GET /api/agents/{id}/projects (documented
#     example; /api/environments/{id}/projects as fallback) and .../containers. API keys take permissions; read-only scopes exist: environments:list,
#     environments:read, projects:list, projects:read, containers:list, containers:read, networks:list, networks:read.
#
# Endpoint rules: https anywhere; plain http only to this PC or a private network address. Credentials are DPAPI
# secrets (lib\SecretStore.psm1), never returned or logged. $Transport (tests) replaces the HTTP call.

$script:Kinds = [ordered]@{
  portainer = [ordered]@{ label = 'Portainer'; header = 'X-API-Key'; readOnlyScopes = $false
    scopeNote = 'Portainer CE access tokens carry every right of the user who created them (no read-only role in CE). Create the token as a dedicated non-administrator user with access to the environments DTC should read. DTC only sends GET requests.'
    tokenHelp = 'Portainer: My account > Access tokens > Add access token.' }
  arcane = [ordered]@{ label = 'Arcane'; header = 'X-Api-Key'; readOnlyScopes = $true
    scopeNote = 'Give the key only read permissions: environments:list, environments:read, projects:list, projects:read, containers:list, containers:read, networks:list, networks:read.'
    tokenHelp = 'Arcane: System > API Keys > Create API Key (choose the read permissions only, and an expiry date).' }
}
$script:IdPattern = '^[a-z][a-z0-9-]{1,30}$'

function Get-EmProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Get-ExternalManagerKinds { return $script:Kinds }
function Get-ManagerSecretName([string]$Id) { if ($Id -notmatch $script:IdPattern) { throw "Invalid connector id '$Id'." }; return "manager-$Id-api" }

# Pure: whether a connector endpoint is acceptable. Returns { Ok; Reason; BaseUrl }.
function Test-ManagerConnectorUrl([string]$Url) {
  $u = $null
  if (-not [Uri]::TryCreate(([string]$Url).Trim().TrimEnd('/'), [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin 'http', 'https') { return [pscustomobject]@{ Ok = $false; Reason = 'Enter the address as http(s)://host:port.'; BaseUrl = '' } }
  if ($u.UserInfo) { return [pscustomobject]@{ Ok = $false; Reason = 'Do not put a user name or password in the address; the API key is stored separately.'; BaseUrl = '' } }
  if ($u.Query -or $u.Fragment) { return [pscustomobject]@{ Ok = $false; Reason = 'The address must not contain ? or #.'; BaseUrl = '' } }
  $h = $u.Host.ToLowerInvariant()
  $private = $h -in 'localhost', 'host.docker.internal' -or $h -match '^127\.' -or $h -match '^10\.' -or $h -match '^192\.168\.' -or $h -match '^172\.(1[6-9]|2[0-9]|3[01])\.' -or $h -match '\.(lan|local|home\.arpa|internal)$'
  if ($u.Scheme -eq 'http' -and -not $private) { return [pscustomobject]@{ Ok = $false; Reason = 'Plain http is accepted only for this PC or a private network address; use https otherwise (the API key would travel unencrypted).'; BaseUrl = '' } }
  return [pscustomobject]@{ Ok = $true; Reason = ''; BaseUrl = ($u.GetLeftPart([UriPartial]::Path)).TrimEnd('/') }
}

# One GET request. Returns { Status; Data; Error } where Error is unreachable | unauthorized | not-found | error | ''.
function Invoke-ManagerGet {
  param([Parameter(Mandatory = $true)][string]$Kind, [Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Path, [bool]$TlsSkipVerify = $false, $Transport = $null, [int]$TimeoutSec = 8)
  if (-not $script:Kinds.Contains($Kind)) { throw "Unknown manager '$Kind'." }
  if ($Path -notmatch '^/api/[A-Za-z0-9/_?=&.-]*$') { throw "Refused path '$Path'." }
  $url = $BaseUrl + $Path
  $headers = @{ $script:Kinds[$Kind].header = $Key; Accept = 'application/json' }
  $r = $null
  if ($Transport) { $r = & $Transport 'GET' $url $headers }
  else {
    $saved = $null
    try {
      if ($TlsSkipVerify) { $saved = [Net.ServicePointManager]::ServerCertificateValidationCallback; [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $url -Headers $headers -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
      $r = [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = [string]$resp.Content }
    } catch {
      $st = 0; try { $st = [int]$_.Exception.Response.StatusCode } catch { }
      $r = [pscustomobject]@{ Status = $st; Body = '' }
    } finally { if ($TlsSkipVerify) { [Net.ServicePointManager]::ServerCertificateValidationCallback = $saved } }
  }
  $status = [int](Get-EmProp $r 'Status' 0)
  $err = $(if ($status -eq 0) { 'unreachable' } elseif ($status -in 401, 403) { 'unauthorized' } elseif ($status -eq 404) { 'not-found' } elseif ($status -ge 300) { 'error' } else { '' })
  $data = $null
  if (-not $err) { try { $data = ([string](Get-EmProp $r 'Body' '')) | ConvertFrom-Json } catch { $err = 'error' } }
  return [pscustomobject]@{ Status = $status; Data = $data; Error = $err }
}

function Get-EmItems($Data) {
  if ($null -eq $Data) { return @() }
  foreach ($k in @('data', 'items', 'projects', 'environments', 'containers')) { $v = Get-EmProp $Data $k $null; if ($null -ne $v -and -not ($v -is [string])) { return @($v) } }
  return @($Data)
}

function Get-EmLabel($Container, [string]$Name) {
  $l = Get-EmProp $Container 'Labels' (Get-EmProp $Container 'labels' $null)
  return [string](Get-EmProp $l $Name '')
}

# Pure: Docker-proxy container objects -> { name; project; service; state; networks[] }.
function ConvertFrom-ManagerContainers([object[]]$Items) {
  return @(foreach ($c in $Items) {
      $names = @(Get-EmProp $c 'Names' @()); $n = $(if ($names.Count) { ([string]$names[0]).TrimStart('/') } else { [string](Get-EmProp $c 'name' '') })
      $nets = Get-EmProp (Get-EmProp $c 'NetworkSettings' $null) 'Networks' $null
      [ordered]@{ name = $n; project = (Get-EmLabel $c 'com.docker.compose.project'); service = (Get-EmLabel $c 'com.docker.compose.service')
        state = [string](Get-EmProp $c 'State' (Get-EmProp $c 'state' '')); networks = @(if ($nets) { $nets.PSObject.Properties.Name }) }
    })
}

# A snapshot of one connector: { id; kind; ok; error; message; stacks[]: { manager; stackId; name; project; status;
# environment; path; source; containers[] } }. Never throws for API problems.
function Get-ManagerSnapshot {
  param([Parameter(Mandatory = $true)]$Connector, [Parameter(Mandatory = $true)][string]$Key, $Transport = $null)
  $kind = [string]$Connector.kind; $base = [string]$Connector.url; $skip = [bool](Get-EmProp $Connector 'tlsSkipVerify' $false)
  $out = [ordered]@{ id = [string]$Connector.id; kind = $kind; ok = $false; error = ''; message = ''; checkedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z'; stacks = @() }
  $get = { param($path) Invoke-ManagerGet -Kind $kind -BaseUrl $base -Key $Key -Path $path -TlsSkipVerify $skip -Transport $Transport }
  $fail = { param($r) $out.error = $r.Error; $out.message = $(switch ($r.Error) { 'unauthorized' { 'The API key was refused (wrong, revoked or expired). Create a new one and save it again.' } 'unreachable' { "$base did not answer." } 'not-found' { 'This API path does not exist on that server (another product or version?).' } default { "Unexpected answer (HTTP $($r.Status))." } }); return [pscustomobject]$out }
  if ($kind -eq 'portainer') {
    $st = & $get '/api/stacks'
    if ($st.Error) { return (& $fail $st) }
    $envIds = @{}
    $stacks = @(foreach ($s in (Get-EmItems $st.Data)) {
        $eid = [int](Get-EmProp $s 'EndpointId' 0); $envIds[$eid] = $true
        $git = Get-EmProp $s 'GitConfig' $null
        [ordered]@{ manager = 'portainer'; stackId = [string](Get-EmProp $s 'Id' ''); name = [string](Get-EmProp $s 'Name' ''); project = ([string](Get-EmProp $s 'Name' '')).ToLowerInvariant()
          status = $(switch ([int](Get-EmProp $s 'Status' 0)) { 1 { 'active' } 2 { 'inactive' } default { 'unknown' } }); environment = [string]$eid
          path = [string](Get-EmProp $s 'ProjectPath' ''); source = $(if ($git) { [string](Get-EmProp $git 'URL' '') } else { '' }); containers = @() }
      })
    foreach ($eid in @($envIds.Keys)) {
      $cr = & $get "/api/endpoints/$eid/docker/containers/json?all=1"
      if ($cr.Error) { continue }
      $cs = @(ConvertFrom-ManagerContainers (Get-EmItems $cr.Data))
      foreach ($s in $stacks) { if ($s.environment -eq [string]$eid) { $s.containers = @($cs | Where-Object { $_.project -eq $s.project }) } }
    }
    $out.stacks = $stacks
  } else {
    $er = & $get '/api/environments'
    if ($er.Error) { return (& $fail $er) }
    $envs = @(Get-EmItems $er.Data | ForEach-Object { [string](Get-EmProp $_ 'id' '') } | Where-Object { $_ })
    if (-not $envs.Count) { $envs = @('0') }
    $stacks = @()
    foreach ($e in $envs) {
      # Documented example: GET /api/agents/{id}/projects; some versions serve /api/environments/{id}/projects.
      $prefix = "/api/agents/$e"
      $pr = & $get "$prefix/projects"
      if ($pr.Error -eq 'not-found') { $prefix = "/api/environments/$e"; $pr = & $get "$prefix/projects" }
      if ($pr.Error) { if ($pr.Error -eq 'unauthorized') { return (& $fail $pr) }; continue }
      $cr = & $get "$prefix/containers"
      $cs = @(if (-not $cr.Error) { ConvertFrom-ManagerContainers (Get-EmItems $cr.Data) })
      foreach ($p in (Get-EmItems $pr.Data)) {
        $name = [string](Get-EmProp $p 'name' '')
        $stacks += [ordered]@{ manager = 'arcane'; stackId = [string](Get-EmProp $p 'id' $name); name = $name; project = $name.ToLowerInvariant()
          status = ([string](Get-EmProp $p 'status' 'unknown')).ToLowerInvariant(); environment = $e; path = [string](Get-EmProp $p 'path' (Get-EmProp $p 'dirName' ''))
          source = [string](Get-EmProp $p 'gitUrl' ''); containers = @($cs | Where-Object { $_.project -eq $name.ToLowerInvariant() }) }
      }
    }
    $out.stacks = $stacks
  }
  $out.ok = $true
  return [pscustomobject]$out
}

# Pure: the management authority of a Compose project with API evidence. $Docker: the authority from Docker labels
# (lib\AppContract.psm1). $Snapshots: connector snapshots. Returns the authority to show, with confidence 'confirmed'
# when a manager's API lists the project, 'conflict' when two sources disagree; Docker evidence is always kept.
function Resolve-ManagerAuthority($Docker, [string]$Project, [object[]]$Snapshots = @()) {
  if (-not $Project) { return $Docker }
  $claims = @(foreach ($s in $Snapshots) { if ($s -and $s.ok) { foreach ($st in @($s.stacks)) { if ($st.project -eq $Project.ToLowerInvariant()) { [ordered]@{ snapshot = $s; stack = $st } } } } })
  if (-not $claims.Count) { return $Docker }
  $kinds = @($claims | ForEach-Object { $_.stack.manager } | Select-Object -Unique)
  $ev = @(@($Docker.evidence) + @($claims | ForEach-Object { "$($script:Kinds[$_.stack.manager].label) API: stack '$($_.stack.name)' (id $($_.stack.stackId), environment $($_.stack.environment), status $($_.stack.status))" }))
  $dockerId = [string](Get-EmProp $Docker 'id' '')
  if ($kinds.Count -gt 1 -or ($dockerId -in 'portainer', 'arcane', 'dtc' -and $kinds -notcontains $dockerId)) {
    return [ordered]@{ id = 'conflict'; label = "Conflicting owners ($((@($kinds) + @($dockerId) | Select-Object -Unique) -join ', '))"; confidence = 'conflict'; evidence = $ev; stacks = @($claims | ForEach-Object { $_.stack }) }
  }
  $k = $kinds[0]
  return [ordered]@{ id = $k; label = $script:Kinds[$k].label; confidence = 'confirmed'; evidence = $ev; stacks = @($claims | ForEach-Object { $_.stack }) }
}

# Pure: drift findings only an owner's API can show, for one Compose project. Uses the same finding shape as
# lib\Reconcile.psm1 (id, severity, title, explanation, evidence, repair).
function Get-ManagerDriftFindings([string]$Project, $Authority, [object[]]$Snapshots = @(), $Container = $null) {
  $f = @()
  $stacks = @(Get-EmProp $Authority 'stacks' @())
  $label = [string](Get-EmProp $Authority 'label' 'its manager')
  foreach ($st in $stacks) {
    if ($st.status -eq 'inactive' -and $Container -and [string](Get-EmProp $Container 'state' '') -eq 'running') {
      $f += [ordered]@{ id = 'manager-status-mismatch'; severity = 'warning'; title = "$label reports the stack as stopped"; explanation = "$label lists stack '$($st.name)' as inactive, but its container is running: it was started outside $label."; evidence = "stack $($st.stackId): $($st.status)"; repair = [ordered]@{ kind = 'advice'; owner = 'external'; automatic = $false; description = "Start or stop it from $label so both agree."; change = $null; snippet = @() } }
    }
    if ($Container -and @($st.containers).Count -and -not @($st.containers | Where-Object { $_.name -eq [string](Get-EmProp $Container 'name' '') }).Count) {
      $f += [ordered]@{ id = 'manager-container-unknown'; severity = 'warning'; title = "$label does not list this container"; explanation = "$label manages stack '$($st.name)' but does not report $([string](Get-EmProp $Container 'name' '')) among its containers."; evidence = "stack containers: $(@($st.containers | ForEach-Object { $_.name }) -join ', ')"; repair = [ordered]@{ kind = 'advice'; owner = 'external'; automatic = $false; description = "Redeploy the stack from $label."; change = $null; snippet = @() } }
    }
  }
  if ([string](Get-EmProp $Authority 'id' '') -eq 'conflict') {
    $f += [ordered]@{ id = 'ownership-conflict'; severity = 'warning'; title = 'Two tools claim this application'; explanation = "$label. DTC changes neither; decide which tool owns it."; evidence = (@(Get-EmProp $Authority 'evidence' @()) -join '; '); repair = [ordered]@{ kind = 'advice'; owner = 'external'; automatic = $false; description = 'Remove the stack from the tool that should not manage it.'; change = $null; snippet = @() } }
  }
  foreach ($s in $Snapshots) { if ($s -and -not $s.ok) { $f += [ordered]@{ id = 'manager-unavailable'; severity = 'info'; title = "$($script:Kinds[[string]$s.kind].label) API not available"; explanation = "$($s.message) Ownership comes from Docker labels only until it answers."; evidence = "connector $($s.id): $($s.error)"; repair = $null } } }
  return $f
}

Export-ModuleMember -Function Get-ExternalManagerKinds, Get-ManagerSecretName, Test-ManagerConnectorUrl, Invoke-ManagerGet, ConvertFrom-ManagerContainers, Get-ManagerSnapshot, Resolve-ManagerAuthority, Get-ManagerDriftFindings
