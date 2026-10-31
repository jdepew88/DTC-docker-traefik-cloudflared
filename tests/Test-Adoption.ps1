#requires -version 5.1
<#
.SYNOPSIS
  Application adoption tests: specifications, generated routes and plans (unit), then two disposable proxy stacks standing in for
  traefik-ext1 and traefik-int1, throwaway echo containers standing in for OmniVoice, a fake authentik and the Cloudflare API
  mock, driven through the web UI's API and a browser.

.DESCRIPTION
  Nothing outside the disposable instance is changed: every container, network and volume it creates has the instance's unique
  prefix and is removed at the end. Every other container on the engine must keep its ID, start time and state, and the live
  route files must keep their hashes. No real Cloudflare call is made.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Adoption.ps1 -ScreenshotDir $env:TEMP\dtc-adoption-shots
#>
[CmdletBinding()]
param([string]$ScreenshotDir, [switch]$SkipBrowser, [switch]$SkipInstance, [string]$ExtSubnet = '172.31.243.0/28', [string]$IntSubnet = '172.31.244.0/28', [string]$LiveInstall = "$env:USERPROFILE\.docker\projects\traefik-proxy")

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'TraefikProxy', 'Dashboard', 'DockerDiscovery', 'CloudflareApi', 'AppAdoption') { Import-Module (Join-Path $repo "lib\$m.psm1") -Force }
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\EdgeCdp.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, $Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Invoke-Ps([string]$Script, [string[]]$Arguments) {
  $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Text = (@($out) -join "`n") }
}
function Get-EngineSnapshot([string]$ExcludePrefix) {
  $map = @{}
  foreach ($line in (Invoke-Docker ps -a --format '{{.Names}}').Output) {
    # dtcnet* and net-*: disposable containers of the Networking v2 test suite, which may run at the same time.
    if (-not $line -or $line.StartsWith($ExcludePrefix) -or $line -match '-validate-' -or $line -match '^(dtcnet[0-9a-f]{6}|net-[0-9a-f]{6})-') { continue }
    $map[$line] = ((Invoke-Docker inspect $line --format '{{.Id}} {{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim()
  }
  return $map
}
function Get-LiveRouteHashes([string]$Dir) {
  $map = @{}
  if (Test-Path -LiteralPath $Dir) { foreach ($f in Get-ChildItem -LiteralPath $Dir -File) { $map[$f.Name] = Get-FileSha256 $f.FullName } }
  return $map
}
function New-WhoamiFacts([string]$Name, [string]$State = 'running', [string[]]$Nets = @('apps'), [string]$Image = 'x/y:1') {
  return [ordered]@{ name = $Name; image = $Image; state = $State; infrastructure = $false; privateService = $false; managedBy = ''; compose = [ordered]@{ project = ''; service = ''; workingDir = '' }; networks = @($Nets | ForEach-Object { [ordered]@{ name = $_; ipv4 = '10.0.0.2'; aliases = @() } }); exposed = @([ordered]@{ port = 80; proto = 'tcp' }); published = @(); traefik = [ordered]@{ enabled = ''; routers = @(); servicePorts = @() } }
}
function Copy-Map($Map, $Override = @{}) { $c = @{}; foreach ($k in $Map.Keys) { $c[$k] = $Map[$k] }; foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }; return $c }
function Get-CloudflareTestRecord($Mock, [string]$Name) { return [bool]@(@((Get-MockState $Mock).dns) | Where-Object { $_.name -eq $Name }).Count }
function Get-CheckStates($Checks, [string]$Kind) { return @(@($Checks) | Where-Object { $_.kind -eq $Kind } | ForEach-Object { [string]$_.state } | Select-Object -Unique) }

# --- Unit: specification ------------------------------------------------------------------------------------------------------
$omni = @(Get-AdoptionSpecs (Join-Path $repo 'catalog') | Where-Object { $_.id -eq 'omnivoice' })[0]
Test-Condition 'spec: the OmniVoice manifest is valid (3 backends, 3 routes, no real hostname in it)' ($null -ne $omni -and @($omni.backends).Count -eq 3 -and @($omni.routes).Count -eq 3 -and ((Get-Content -Raw (Join-Path $repo 'catalog\adoption\omnivoice.json')) -notmatch 'jrtechconsult')) ''
$bad = { param($mut) $c = $omni | ConvertTo-Json -Depth 8 | ConvertFrom-Json; & $mut $c; @(Test-AdoptionSpec $c) }
Test-Condition 'spec: a route to an unknown backend is rejected' (@(& $bad { param($c) $c.routes[0].backend = 'nope' }).Count -gt 0) ''
Test-Condition 'spec: a catch-all that outranks a path route is rejected' (@(& $bad { param($c) @($c.routes | Where-Object { $_.id -eq 'ui' })[0].priority = 999 }) -match 'higher priority') ''
Test-Condition 'spec: sign-in middleware cannot be hardcoded (it belongs to the external route only)' (@(& $bad { param($c) $c.routes[0] | Add-Member -NotePropertyName middlewares -NotePropertyValue @('authentik-fwd') }) -match 'sign-in') ''
Test-Condition 'spec: an upload limit together with WebSocket is rejected (buffering breaks it)' (@(& $bad { param($c) $u = @($c.routes | Where-Object { $_.id -eq 'ui' })[0]; $u | Add-Member -NotePropertyName maxRequestBodyBytes -NotePropertyValue 1000 }) -match 'buffering') ''
Test-Condition 'spec: a path that could break out of a YAML rule is rejected' (@(& $bad { param($c) $c.routes[0].pathPrefix = '/x`) || Host(`evil' }).Count -gt 0) ''
$dbc = New-WhoamiFacts 'db'; $dbc.privateService = $true
$threw = $false; try { $null = New-SingleServiceSpec $dbc 5432 } catch { $threw = $true }
Test-Condition 'spec: a database is never turned into an application' $threw ''

$secretLine = '[{"Id":"abc","Config":{"Env":["PASSWORD=hunter2"]}}]'
Test-Condition 'inspect: a vanished container does not lose the others' (@(ConvertFrom-InspectOutput @($secretLine, 'Error: No such object: gone')).Count -eq 1) ''
$msg = ''; try { $null = ConvertFrom-InspectOutput @('[{"Env":["PASSWORD=hunter2"]') } catch { $msg = $_.Exception.Message }
Test-Condition 'inspect: unreadable output never reaches an error message (it holds container environment variables)' ($msg -and $msg -notmatch 'hunter2') $msg

# --- Unit: owner classification and inventory -----------------------------------------------------------------------------------
$owner = { param($p, $wd) $c = New-WhoamiFacts 'a'; $c.compose.project = $p; $c.compose.workingDir = $wd; (Get-ContainerOwner $c).manager }
Test-Condition 'discovery: manual, Compose, Portainer and Arcane ownership are told apart' ((& $owner '' '') -eq 'manual' -and (& $owner 'p' 'C:\x\y') -eq 'compose' -and (& $owner 'p' '/data/compose/12') -eq 'portainer' -and (& $owner 'p' '/app/data/projects/foo') -eq 'arcane') ''

$targets = @{
  external = [ordered]@{ role = 'external'; mode = 'stack'; name = 'traefik-ext1'; settings = $null; entryPoint = 'web'; network = 'proxynet'; running = $true; detail = '' }
  internal = [ordered]@{ role = 'internal'; mode = 'stack'; name = 'traefik-int1'; settings = $null; entryPoint = 'web'; network = 'intnet'; running = $true; detail = '' }
}
$containers = @((New-WhoamiFacts 'omnivoice-triton-api' 'exited' @('proxy')), (New-WhoamiFacts 'omnivoice-perform-api' 'running' @('proxy', 'proxynet')))
$facts = [ordered]@{ containers = $containers; networks = @(@{ name = 'proxynet' }, @{ name = 'intnet' }, @{ name = 'proxy' }); targets = $targets; routers = @{ external = @(); internal = @() }; services = @() }
$req = @{ mode = 'both'; externalHost = 'voice.example.com'; internalHost = 'voice.lan.example.com'; authEndpoint = 'http://authentik-server:9000' }
$plan = Get-AdoptionPlan -Spec $omni -Request $req -Facts $facts
$extYaml = @($plan.targets | Where-Object { $_.role -eq 'external' })[0].file.content
$intYaml = @($plan.targets | Where-Object { $_.role -eq 'internal' })[0].file.content
Test-Condition 'plan: dual routing to the same backends, with separate files and router names' ($plan.ok -and $extYaml -match 'adopt-omnivoice-ext-api:' -and $intYaml -match 'adopt-omnivoice-int-api:' -and $intYaml -notmatch 'adopt-omnivoice-ext' -and $extYaml -match 'url: http://omnivoice-perform-api:18090' -and $intYaml -match 'url: http://omnivoice-perform-api:18090') (@($plan.blockers) -join ' ')
Test-Condition 'plan: authentik only on the external route' ($extYaml -match 'forwardAuth' -and $extYaml -match 'X-authentik-username' -and $extYaml -match 'outpost' -and (($intYaml -split "`n" | Where-Object { $_ -notmatch '^#' }) -join "`n") -notmatch '(?i)authentik|forwardAuth|outpost') ''
Test-Condition 'plan: path priorities, prefix stripping and timeouts are explicit' ($extYaml -match 'priority: 1300' -and $extYaml -match 'priority: 1200' -and $extYaml -match 'priority: 1100' -and $extYaml -match 'stripPrefix' -and $extYaml -match 'responseHeaderTimeout: 600s') ''
Test-Condition 'plan: the external file uses only the tunnel entry point' ($extYaml -match 'entryPoints: \[web\]' -and $extYaml -notmatch 'lan-') ''
Test-Condition 'plan: no sign-in header or HSTS chain leaks into internal' ($intYaml -notmatch 'default-headers@file') ''
$cmds = @($plan.networkChanges | ForEach-Object { $_.command })
Test-Condition 'plan: network changes are per proxy and only what is missing' (($cmds -contains 'docker network connect proxynet omnivoice-triton-api') -and ($cmds -contains 'docker network connect intnet omnivoice-perform-api') -and ($cmds -notcontains 'docker network connect proxynet omnivoice-perform-api')) ($cmds -join '; ')
Test-Condition 'plan: a stopped backend is reported, and not started' (@($plan.warnings) -match 'Adoption does not start it') ''
foreach ($mode in 'none', 'internal', 'external') {
  $p = Get-AdoptionPlan -Spec $omni -Request (Copy-Map $req @{ mode = $mode }) -Facts $facts
  $roles = @($p.targets | ForEach-Object { $_.role })
  $want = @{ none = @(); internal = @('internal'); external = @('external') }[$mode]
  Test-Condition "plan: routing '$mode' generates only that route" ($p.ok -and (($roles -join ',') -eq ($want -join ','))) (@($p.blockers) -join ' ')
}
$p = Get-AdoptionPlan -Spec $omni -Request (Copy-Map $req @{ internalHost = 'voice.example.com' }) -Facts $facts
Test-Condition 'plan: the same name for internal and external is refused' (-not $p.ok -and @($p.blockers) -match 'must differ') ''
$p = Get-AdoptionPlan -Spec $omni -Request @{ mode = 'external'; externalHost = 'voice.example.com' } -Facts $facts
Test-Condition 'plan: external without authentik is refused unless explicitly accepted' (-not $p.ok -and @($p.blockers) -match 'needs authentik') ''
$p = Get-AdoptionPlan -Spec $omni -Request @{ mode = 'external'; externalHost = 'voice.example.com'; noAuth = $true } -Facts $facts
$y = @($p.targets)[0].file.content
Test-Condition 'plan: explicitly accepted no sign-in generates valid structure and a warning' ($p.ok -and @($p.warnings) -match 'no sign-in' -and $y -notmatch 'forwardAuth' -and $y -match 'adopt-omnivoice-ext-api-strip') ''
$p = Get-AdoptionPlan -Spec $omni -Request (Copy-Map $req @{ externalHost = 'evil`) || Host(`x.example.com' }) -Facts $facts
Test-Condition 'plan: a hostname that could inject a rule is refused and generates nothing' (-not $p.ok -and -not @(@($p.targets) | Where-Object { $_.role -eq 'external' })[0].file.content) ''
$claimFacts = Copy-Map $facts; $claimFacts.routers = @{ external = @([pscustomobject]@{ name = 'other@file'; rule = 'Host(`voice.example.com`)'; provider = 'file' }); internal = @() }
$p = Get-AdoptionPlan -Spec $omni -Request $req -Facts $claimFacts
Test-Condition 'conflict: a hostname another router claims blocks the plan' (-not $p.ok -and @($p.blockers) -match 'voice.example.com') ''
$ownFacts = Copy-Map $facts; $ownFacts.routers = @{ external = @([pscustomobject]@{ name = 'adopt-omnivoice-ext-api@file'; rule = 'Host(`voice.example.com`)'; provider = 'file' }); internal = @() }
Test-Condition 'repeat: its own routers are not a conflict' ((Get-AdoptionPlan -Spec $omni -Request $req -Facts $ownFacts).ok) ''
$svcFacts = Copy-Map $facts; $svcFacts.services = @([pscustomobject]@{ name = 'voice'; hostnames = @('voice.example.com') })
Test-Condition 'conflict: a hostname in the service registry blocks the plan' (-not (Get-AdoptionPlan -Spec $omni -Request $req -Facts $svcFacts).ok) ''
$dup = Copy-Map $facts; $dup.containers = @($containers) + @(New-WhoamiFacts 'x' 'running' @('proxy') 'ghcr.io/a/omnivoice-triton-api:latest')
Test-Condition 'conflict: a backend matching two containers blocks the plan' (@((Get-AdoptionPlan -Spec $omni -Request $req -Facts $dup).blockers) -match 'several containers') ''
$noNet = Copy-Map $facts; $noNet.networks = @(@{ name = 'intnet' })
Test-Condition "conflict: a proxy network that does not exist blocks the plan" (@((Get-AdoptionPlan -Spec $omni -Request $req -Facts $noNet).blockers) -match "network 'proxynet'") ''
$miss = Copy-Map $facts; $miss.containers = @()
Test-Condition 'unreachable: a required backend without a container blocks the plan' (@((Get-AdoptionPlan -Spec $omni -Request $req -Facts $miss).blockers) -match 'no matching container') ''
$absent = Copy-Map $facts; $absent.targets = @{ external = $targets.external; internal = [ordered]@{ role = 'internal'; mode = 'absent'; name = ''; settings = $null; entryPoint = ''; network = ''; running = $false; detail = 'No internal proxy found.' } }
Test-Condition 'internal proxy missing: internal routing is blocked, external is not' (-not (Get-AdoptionPlan -Spec $omni -Request $req -Facts $absent).ok -and (Get-AdoptionPlan -Spec $omni -Request (Copy-Map $req @{ mode = 'external' }) -Facts $absent).ok) ''
$first = Get-AdoptionPlan -Spec $omni -Request $req -Facts $facts
$files = @{}; foreach ($t in $first.targets) { $files["$($t.role)/$($t.file.name)"] = $t.file.content }
$again = Get-AdoptionPlan -Spec $omni -Request $req -Facts $facts -ExistingFiles $files
Test-Condition 'repeat: the same adoption again is unchanged, with the same fingerprint' (@($again.targets | Where-Object { $_.file.action -ne 'unchanged' }).Count -eq 0 -and $again.fingerprint -eq $first.fingerprint) ''
$files2 = @{ 'external/adopt-omnivoice-external.yml' = "http:`n" }
Test-Condition 'safety: a file with that name written by someone else is never overwritten' (@((Get-AdoptionPlan -Spec $omni -Request $req -Facts $facts -ExistingFiles $files2).blockers) -match 'never overwritten') ''

# --- Unit: separate verdicts ----------------------------------------------------------------------------------------------------
$v = ConvertTo-RouteVerdict 200 '' $true
Test-Condition 'auth: an anonymous 200 on a protected route is a failure of sign-in, not of the route' ($v.route -eq 'ok' -and $v.auth -eq 'failed') ''
$v = ConvertTo-RouteVerdict 302 'https://auth.example.com/' $true
Test-Condition 'auth: a redirect to sign-in counts as enforced' ($v.route -eq 'ok' -and $v.auth -eq 'ok') ''
$v = ConvertTo-RouteVerdict 500 '' $true
Test-Condition 'auth: authentik down means refused, reported as a sign-in failure' ($v.auth -eq 'failed') ''
Test-Condition 'route: 502, 503 and 504 are unreachable backends, 404 is a missing route' ((ConvertTo-RouteVerdict 502 '' $false).route -eq 'failed' -and (ConvertTo-RouteVerdict 404 '' $false).route -eq 'failed' -and (ConvertTo-RouteVerdict 403 '' $false).route -eq 'ok') ''
$pc = @(ConvertTo-PublicChecks -Hostname 'v.example.com' -DnsAnswers @('104.21.0.1') -Status 530)
Test-Condition 'public: HTTP 530 means DNS and TLS are fine and the tunnel path is not' ((Get-CheckStates $pc 'dns') -contains 'ok' -and (Get-CheckStates $pc 'tls') -contains 'ok' -and (Get-CheckStates $pc 'public') -contains 'failed' -and -not @(Get-CheckStates $pc 'auth').Count) ''
$pc = @(ConvertTo-PublicChecks -Hostname 'v.example.com')
Test-Condition 'public: no DNS answer stops there: TLS and sign-in are not claimed' (@($pc).Count -eq 1 -and @($pc)[0].state -eq 'failed') ''
$pc = @(ConvertTo-PublicChecks -Hostname 'v.example.com' -DnsAnswers @('1.1.1.1') -Status 302 -Location 'https://auth.example.com/x')
Test-Condition 'public: everything verified, each as its own check' (Test-ChecksPassed $pc) ''
$pc = @(ConvertTo-PublicChecks -Hostname 'v.example.com' -DnsAnswers @('1.1.1.1') -Status 200)
Test-Condition 'public: an anonymous 200 fails sign-in although DNS, TLS and routing work' (-not (Test-ChecksPassed $pc) -and (Get-CheckStates $pc 'auth') -contains 'failed' -and (Get-CheckStates $pc 'public') -contains 'ok') ''
Test-Condition 'checks: failed and pending stop the migration; unverified is shown, not hidden as ok' (-not (Test-ChecksPassed @(@{ state = 'pending' })) -and (Test-ChecksPassed @(@{ state = 'unverified' }, @{ state = 'ok' }))) ''
$cfp = [pscustomobject]@{ Actions = @([pscustomobject]@{ Id = 'dns:h'; Step = 'dns'; Kind = 'update'; Hostname = 'h'; Summary = 'Overwrite DNS record h' }, [pscustomobject]@{ Id = 'tunnel:h'; Step = 'tunnel'; Kind = 'create'; Hostname = 'h'; Summary = 'Add' }, [pscustomobject]@{ Id = 'access:h'; Step = 'access'; Kind = 'create'; Hostname = 'h'; Summary = 'x' }) }
$rev = Get-CloudflareReversal $cfp @([pscustomobject]@{ Id = 'dns:h'; Status = 'Done' }, [pscustomobject]@{ Id = 'tunnel:h'; Status = 'Done' }, [pscustomobject]@{ Id = 'access:h'; Status = 'Failed' })
Test-Condition 'rollback: what was created is undone, what was replaced needs a person, what failed is left' (@($rev.created).Count -eq 1 -and @($rev.created)[0].step -eq 'tunnel' -and @($rev.manual).Count -eq 1 -and @($rev.manual)[0] -match 'Overwrite DNS') ''

# --- Unit: retirement guards ------------------------------------------------------------------------------------------------------
$legacy = New-WhoamiFacts 'old-traefik' 'running' @('old_tunnel') 'traefik:v3'; $legacy.infrastructure = $true; $legacy.compose.project = 'traefik-cloudflared'
$stray = New-WhoamiFacts 'old-app' 'running' @('x'); $stray.compose.project = 'traefik-cloudflared'
$retireFacts = [ordered]@{ containers = @($legacy, $stray) + @($containers); networks = @(@{ name = 'traefik-cloudflared_tunnel'; project = 'traefik-cloudflared'; containers = @() }, @{ name = 'traefik-cloudflared_shared'; project = 'traefik-cloudflared'; containers = @('omnivoice-perform-api') }, @{ name = 'proxy'; project = ''; containers = @('omnivoice-perform-api') }) }
$rp = Get-AdoptionRetirePlan -Spec $omni -Facts $retireFacts -OwnStacks @('traefik-ext1')
$byName = @{}; foreach ($i in $rp.items) { $byName[$i.name] = $i }
Test-Condition 'retire: only the legacy proxy is a candidate; the shared proxy network and apps are not' ($byName.ContainsKey('old-traefik') -and -not $byName['old-traefik'].blocked -and -not $byName.ContainsKey('proxy') -and -not $byName.ContainsKey('omnivoice-perform-api')) ''
Test-Condition 'retire: a non-proxy container in the old project and a network still in use are blocked' ($byName['old-app'].blocked -and $byName['traefik-cloudflared_shared'].blocked -match 'Still used' -and -not $byName['traefik-cloudflared_tunnel'].blocked) ''
$r = @(Invoke-AdoptionRetire -RetirePlan $rp -Action delete -Names @('old-traefik', 'omnivoice-perform-api', 'old-app', 'some-volume'))
Test-Condition 'retire: a running proxy cannot be deleted before it is stopped; apps, volumes and blocked items are refused' (@($r | Where-Object { $_.status -ne 'Refused' }).Count -eq 0) ''
$drift = @(Get-AdoptionDrift ([pscustomobject]@{ attachedNetworks = @([pscustomobject]@{ container = 'omnivoice-perform-api'; network = 'gone' }, [pscustomobject]@{ container = 'nope'; network = 'x' }); files = @() }) $containers)
Test-Condition 'drift: a lost network and a missing container are told apart' (@($drift | ForEach-Object { $_.kind }) -contains 'network-lost' -and @($drift | ForEach-Object { $_.kind }) -contains 'container-missing') ''

# --- Disposable proxies --------------------------------------------------------------------------------------------------------
if ($SkipInstance) { Add-Result 'SKIP' 'disposable instance' '-SkipInstance' }
elseif (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'disposable instance' 'Docker engine not running' }
else {
  $unique = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $prefix = "dtcadopt$unique"
  $work = Join-Path ([IO.Path]::GetTempPath()) $prefix
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
  $ext = "$prefix-ext1"; $int = "$prefix-int1"
  $extPath = Join-Path $work 'ext'; $intPath = Join-Path $work 'int'
  $extPort = Get-FreeTcpPort; $intPort = Get-FreeTcpPort
  $writeEnv = {
    param($file, $stack, $http, $subnet)
    $o = $subnet.Split('/')[0].Split('.')
    @("STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$http", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$stack-proxy", "TUNNEL_SUBNET=$subnet", "TUNNEL_IP_RANGE=$($o[0]).$($o[1]).$($o[2]).$($o[3])/29", "CLOUDFLARED_IP=$($o[0]).$($o[1]).$($o[2]).$([int]$o[3] + 10)", 'TRAEFIK_LOG_LEVEL=INFO') | Set-Content -LiteralPath $file -Encoding ASCII
  }
  $whoami = 'traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44'
  $traefikImage = (Get-StackSettings -InstallPath $repo).TraefikImage
  $apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N')
  $before = Get-EngineSnapshot $prefix
  $liveBefore = Get-LiveRouteHashes (Join-Path $LiveInstall 'traefik\dynamic')
  $ui = $null; $mock = $null; $cdp = $null; $extUp = $false; $intUp = $false
  $appsNet = "$prefix-apps"; $tritonC = "$prefix-triton"; $performC = "$prefix-perform"; $uiC = "$prefix-ui"; $singleC = "$prefix-single"; $authC = "$prefix-authentik"
  $legacyProject = "$prefix-legacy"; $legacyProxy = "$prefix-oldtraefik"; $legacyNet = "$legacyProject-tunnel"; $legacyUsed = "$legacyProject-shared"; $volume = "$prefix-models"
  $uiPort = Get-FreeTcpPort
  $request = @{ mode = 'both'; externalHost = 'voice.example.test'; internalHost = 'voice.lan.example.test'; authEndpoint = "http://${authC}:9000" }
  try {
    # Fixture catalog: the shape of OmniVoice with this run's container names.
    $catalog = Join-Path $work 'catalog'
    New-Item -ItemType Directory -Force -Path (Join-Path $catalog 'adoption'), (Join-Path $catalog 'apps') | Out-Null
    $fixture = [ordered]@{
      schemaVersion = 1; id = 'fakevoice'; displayName = 'Fake Voice'; defaultSubdomain = 'voice'
      backends = @(
        [ordered]@{ id = 'ui'; kind = 'host'; port = $uiPort; protocol = 'http'; healthPath = '/'; required = $true },
        [ordered]@{ id = 'triton-api'; kind = 'container'; containerNames = @($tritonC); port = 80; protocol = 'http'; healthPath = '/health'; required = $true; timeouts = [ordered]@{ dial = '5s'; responseHeader = '20s'; idleConn = '30s' } },
        [ordered]@{ id = 'perform-api'; kind = 'container'; containerNames = @($performC); port = 80; protocol = 'http'; healthPath = '/health'; required = $true; timeouts = [ordered]@{ dial = '5s'; responseHeader = '20s' } })
      routes = @(
        [ordered]@{ id = 'perform-api'; backend = 'perform-api'; pathPrefix = '/perform-api'; stripPrefix = $true; priority = 300; maxRequestBodyBytes = 50000 },
        [ordered]@{ id = 'api'; backend = 'triton-api'; pathPrefix = '/api'; stripPrefix = $true; priority = 200 },
        [ordered]@{ id = 'ui'; backend = 'ui'; priority = 100; websocket = $true; websocketTestPath = '/echo' })
      legacy = [ordered]@{ composeProjects = @($legacyProject) }
    }
    [IO.File]::WriteAllText((Join-Path $catalog 'adoption\fakevoice.json'), (ConvertTo-Json -InputObject $fixture -Depth 8), (New-Object Text.UTF8Encoding($false)))

    & $writeEnv (Join-Path $work 'ext.env') $ext $extPort $ExtSubnet
    & $writeEnv (Join-Path $work 'int.env') $int $intPort $IntSubnet
    $i1 = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $extPath, '-EnvFile', (Join-Path $work 'ext.env'), '-Start'); $extUp = Test-Path -LiteralPath $extPath
    $i2 = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $intPath, '-EnvFile', (Join-Path $work 'int.env'), '-Start'); $intUp = Test-Path -LiteralPath $intPath
    Test-Condition 'instance: two disposable proxies, standing in for traefik-ext1 and traefik-int1' ($i1.ExitCode -eq 0 -and $i2.ExitCode -eq 0) (($i1.Text + $i2.Text) -split "`n" | Select-Object -Last 12 | Out-String)
    if ($i1.ExitCode -ne 0 -or $i2.ExitCode -ne 0) { throw 'Install failed.' }
    [IO.File]::WriteAllText((Join-Path $extPath 'config\adoption.json'), (ConvertTo-Json -InputObject @{ internalInstallPath = $intPath }))
    $extSettings = Get-StackSettings -InstallPath $extPath
    $intSettings = Get-StackSettings -InstallPath $intPath

    $null = Invoke-Docker network create $appsNet
    $null = Invoke-Docker volume create $volume
    $fixtureRuns = @(
      (Invoke-Docker run -d --name $tritonC --network $appsNet -v "${volume}:/models" -e WHOAMI_NAME=triton --pull missing $whoami),
      (Invoke-Docker run -d --name $performC --network $appsNet -e WHOAMI_NAME=perform $whoami),
      (Invoke-Docker run -d --name $uiC --network $appsNet -p "127.0.0.1:${uiPort}:80" -e WHOAMI_NAME=vite-ui $whoami),
      (Invoke-Docker run -d --name $singleC --network $appsNet --expose 80 -e WHOAMI_NAME=single $whoami),
      # authentik stand-in: refuses anonymous requests with a redirect to sign-in. On the external proxy's network only.
      (Invoke-Docker run -d --name $authC --network $extSettings.ProxyNetwork --entrypoint sh $traefikImage -c "while true; do printf 'HTTP/1.1 302 Found\r\nLocation: https://auth.example.test/signin\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' | nc -l -p 9000; done"),
      (Invoke-Docker run -d --name $legacyProxy --network none --label "com.docker.compose.project=$legacyProject" --entrypoint sleep $traefikImage 600),
      (Invoke-Docker network create --label "com.docker.compose.project=$legacyProject" $legacyNet),
      (Invoke-Docker network create --label "com.docker.compose.project=$legacyProject" $legacyUsed))
    $null = Invoke-Docker network connect $legacyUsed $performC
    Test-Condition 'fixtures: throwaway backends, fake authentik, an old proxy and a model volume' (@($fixtureRuns | Where-Object { $_.ExitCode -ne 0 }).Count -eq 0) (@($fixtureRuns | ForEach-Object { $_.Output }) -join ' ')

    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
    $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $extPath -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base -ExtraArgs @('-CatalogDir', "`"$catalog`"")
    $null = Connect-WebUi $ui
    $call = { param($path, $extra = @{}) Invoke-WebUi $ui POST "/api/adoption/$path" (@{ specId = 'fakevoice'; request = $request } + $extra) }
    $get = { param($hostName, $path) Invoke-ProbeRequest -Url "http://127.0.0.1:$extPort$path" -HostHeader $hostName }
    $getInt = { param($hostName, $path) Invoke-ProbeRequest -Url "http://127.0.0.1:$intPort$path" -HostHeader $hostName }
    $hashDir = { (Get-ChildItem -LiteralPath (Join-Path $extPath 'traefik\dynamic') -File | ForEach-Object { "$($_.Name)=$(Get-FileSha256 $_.FullName)" }) -join ';' }

    # Phase A: discovery changes nothing.
    $beforeFiles = & $hashDir
    $disc = Invoke-WebUi $ui GET '/api/adoption/discover'
    $apps = @($disc.Data.inventory.apps)
    $fv = @($apps | Where-Object { $_.id -eq 'fakevoice' })
    Test-Condition 'discover: the multi-backend application is recognized from its specification' ($disc.Status -eq 200 -and $fv.Count -eq 1 -and $fv[0].multiBackend -and $fv[0].backendCount -eq 3) $disc.Body
    Test-Condition 'discover: other containers are listed for adoption and nothing is published' (@($apps | Where-Object { $_.id -eq $singleC }).Count -eq 1 -and (& $hashDir) -eq $beforeFiles) ''
    Test-Condition 'discover: the old proxy and its unused network are reported as redundant' (@($disc.Data.inventory.redundant | Where-Object { $_.name -eq $legacyProxy }).Count -eq 1 -and @($disc.Data.inventory.redundant | Where-Object { $_.name -eq $legacyNet }).Count -eq 1) ''
    Test-Condition 'discover: backends the proxy cannot reach are reported' (@($disc.Data.inventory.unreachable) -contains $singleC) (@($disc.Data.inventory.unreachable) -join ',')
    Test-Condition 'discover: the internal proxy is found as a separate stack' ($disc.Data.targets.internal.mode -eq 'stack' -and $disc.Data.targets.internal.name -eq $int) ''

    # Single-service adoption, internal only, without a catalog entry.
    $singleReq = @{ mode = 'internal'; internalHost = 'single.lan.example.test' }
    $singleBody = @{ container = $singleC; port = 80; request = $singleReq }
    $sp = Invoke-WebUi $ui POST '/api/adoption/preview' $singleBody
    Test-Condition 'single: a preview with its network change' ($sp.Status -eq 200 -and $sp.Data.ok -and @($sp.Data.networkChanges).Count -eq 1) $sp.Body
    $noConfirm = Invoke-WebUi $ui POST '/api/adoption/activate' $singleBody
    Test-Condition 'single: activate without confirmation is refused' ($noConfirm.Status -eq 400) $noConfirm.Body
    $early = Invoke-WebUi $ui POST '/api/adoption/activate' ($singleBody + @{ confirm = $true })
    Test-Condition 'single: activate before prepare is refused' ($early.Status -eq 409) $early.Body
    $prep = Invoke-WebUi $ui POST '/api/adoption/prepare' $singleBody
    Test-Condition 'single: prepare validates in a throwaway Traefik and loads nothing' ($prep.Status -eq 200 -and $prep.Data.phase -eq 'prepared' -and -not (Test-Path -LiteralPath (Join-Path $intSettings.DynamicDir "adopt-$singleC-internal.yml"))) $prep.Body
    $act = Invoke-WebUi $ui POST '/api/adoption/activate' ($singleBody + @{ confirm = $true })
    Test-Condition 'single: activated and tested on the internal proxy' ($act.Status -eq 200 -and $act.Data.phase -eq 'tested') $act.Body
    $res = & $getInt 'single.lan.example.test' '/'
    Test-Condition 'single: traffic reaches the container through the internal proxy' ($res.Status -eq 200 -and $res.Body -match 'Name: single') "$($res.Status) $($res.Body)"
    Test-Condition 'single: the internal name does not answer on the external proxy' ((& $get 'single.lan.example.test' '/').Status -eq 404) ''
    $rb = Invoke-WebUi $ui POST '/api/adoption/rollback' ($singleBody + @{ confirm = $true })
    $stillOn = ((Invoke-Docker inspect $singleC --format '{{json .NetworkSettings.Networks}}').Output -join '') -match [regex]::Escape($intSettings.ProxyNetwork)
    Test-Condition 'single: rollback removes the route and detaches the network' ($rb.Status -eq 200 -and -not (Test-Path -LiteralPath (Join-Path $intSettings.DynamicDir "adopt-$singleC-internal.yml")) -and -not $stillOn) $rb.Body

    # Multi-backend: unreachable backend first.
    $null = Invoke-Docker stop $tritonC
    $val = & $call 'validate'
    Test-Condition 'unreachable: a stopped backend fails the check from the proxy, and is not started' ($val.Status -eq 200 -and @($val.Data.checks | Where-Object { $_.subject -like 'triton-api*' -and $_.state -eq 'failed' }).Count -ge 1 -and ((Invoke-Docker inspect $tritonC --format '{{.State.Status}}').Output -join '') -eq 'exited') $val.Body
    $null = Invoke-Docker start $tritonC

    # Dual routing.
    $pv = & $call 'preview'
    Test-Condition 'dual: preview with routes, network changes and no blockers' ($pv.Status -eq 200 -and $pv.Data.ok -and @($pv.Data.targets).Count -eq 2 -and @($pv.Data.networkChanges).Count -ge 4) $pv.Body
    $val = & $call 'validate'
    Test-Condition 'dual: backends that answer but are not attached yet are pending, not ok' (@($val.Data.checks | Where-Object { $_.state -eq 'pending' }).Count -ge 4 -and @($val.Data.checks | Where-Object { $_.subject -like 'perform-api*' -and $_.state -eq 'ok' }).Count -eq 0) $val.Body
    $prep = & $call 'prepare'
    Test-Condition 'dual: both files accepted by throwaway proxies' ($prep.Status -eq 200 -and $prep.Data.phase -eq 'prepared' -and @($prep.Data.checks | Where-Object { $_.state -eq 'ok' }).Count -eq 2) $prep.Body
    $cutEarly = & $call 'cutover' @{ confirm = $true; approveCloudflare = $true }
    Test-Condition 'order: cutover before the tests is refused' ($cutEarly.Status -eq 409) $cutEarly.Body
    $act = & $call 'activate' @{ confirm = $true }
    Test-Condition 'dual: activated and every local check passes' ($act.Status -eq 200 -and $act.Data.phase -eq 'tested') $act.Body
    Test-Condition 'dual: sign-in, separation, routers and WebSocket are separate results' (@(Get-CheckStates $act.Data.checks 'auth') -join ',' -eq 'ok' -and @(Get-CheckStates $act.Data.checks 'separation') -join ',' -eq 'ok' -and @(Get-CheckStates $act.Data.checks 'router') -join ',' -eq 'ok' -and @(Get-CheckStates $act.Data.checks 'websocket') -contains 'ok') $act.Body

    $i = 'voice.lan.example.test'
    $r1 = & $getInt $i '/perform-api/x'; $r2 = & $getInt $i '/api/y'; $r3 = & $getInt $i '/z'
    Test-Condition 'internal: path routes reach the right backend with the prefix removed' ($r1.Body -match 'Name: perform' -and $r1.Body -match 'GET /x ' -and $r2.Body -match 'Name: triton' -and $r2.Body -match 'GET /y ' -and $r3.Body -match 'Name: vite-ui' -and $r3.Body -match 'GET /z ') "$($r1.Body) | $($r2.Body) | $($r3.Body)"
    Test-Condition 'internal: no sign-in on the internal route' ($r3.Status -eq 200 -and $r3.Location -eq '') ''
    Test-Condition 'internal: the WebSocket upgrade passes on the same host' ((Test-WebSocketUpgrade $intPort $i '/echo') -eq 101) ''
    $e = 'voice.example.test'
    $r4 = & $get $e '/z'; $r5 = & $get $e '/api/y'
    Test-Condition 'external: every path is behind authentik, including the APIs' ($r4.Status -eq 302 -and $r5.Status -eq 302 -and $r4.Location -match 'auth\.example\.test') "$($r4.Status) $($r5.Status)"
    Test-Condition 'separation: the internal hostname gets a 404 from the external proxy and the reverse' ((& $get $i '/').Status -eq 404 -and (& $getInt $e '/').Status -eq 404) ''
    Test-Condition 'preserved: the same backend container serves both routes; no container was recreated' (((Invoke-Docker inspect $performC --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}').Output -join '') -match [regex]::Escape($extSettings.ProxyNetwork) -and ((Invoke-Docker inspect $performC --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}').Output -join '') -match [regex]::Escape($intSettings.ProxyNetwork)) ''
    Test-Condition 'traffic: activating touched no DNS or tunnel' (-not @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' }).Count) ''

    # Repeat adoption.
    $prep2 = & $call 'prepare'
    $act2 = & $call 'activate' @{ confirm = $true }
    $count = @(Get-ChildItem -LiteralPath $extSettings.DynamicDir -Filter 'adopt-fakevoice*').Count
    $state = Read-AdoptionState $extSettings 'fakevoice'
    Test-Condition 'repeat: adopting again creates no second file, router or network record' ($act2.Status -eq 200 -and $count -eq 1 -and @($state.attachedNetworks).Count -eq @($pv.Data.networkChanges).Count -and @((& $call 'preview').Data.targets | Where-Object { $_.file.action -ne 'unchanged' }).Count -eq 0) $act2.Body

    # Authentication failure.
    $null = Invoke-Docker stop -t 1 $authC
    $down = & $call 'test'
    Test-Condition 'auth failure: authentik down is reported, the phase steps back and requests are refused' (@(Get-CheckStates $down.Data.checks 'auth') -contains 'failed' -and $down.Data.phase -eq 'activated' -and (& $get $e '/z').Status -ge 500) $down.Body
    $cutDown = & $call 'cutover' @{ confirm = $true; approveCloudflare = $true }
    Test-Condition 'auth failure: the cutover is refused while sign-in fails' ($cutDown.Status -eq 409) $cutDown.Body
    $null = Invoke-Docker start $authC
    Start-Sleep -Seconds 2

    # Backend recreated from its own definition.
    $null = Invoke-Docker rm -f $performC
    $null = Invoke-Docker run -d --name $performC --network $appsNet -e WHOAMI_NAME=perform $whoami
    $null = Invoke-Docker network connect $legacyUsed $performC
    $st = Invoke-WebUi $ui GET '/api/adoption/status?specId=fakevoice'
    Test-Condition 'recreate: a recreated backend shows as drift, with the lost networks' (@($st.Data.drift | Where-Object { $_.kind -eq 'network-lost' -and $_.container -eq $performC }).Count -eq 2) $st.Body
    $broken = & $getInt $i '/perform-api/x'
    Test-Condition 'recreate: its route fails visibly until repaired' ($broken.Status -in 502, 503, 504) "$($broken.Status)"
    $fix = & $call 'repair' @{ confirm = $true }
    $fixed = & $getInt $i '/perform-api/x'
    Test-Condition 'recreate: repair attaches it again without restarting anything' ($fix.Status -eq 200 -and $fixed.Status -eq 200 -and $fixed.Body -match 'Name: perform') "$($fixed.Status) $($fix.Body)"
    $retest = & $call 'test'
    Test-Condition 'recreate: all local checks pass again' ($retest.Data.phase -eq 'tested') $retest.Body

    # Cloudflare: without a token only manual steps; with one a plan.
    $null = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = $apiToken }
    $null = Invoke-WebUi $ui POST '/api/cloudflare/select' @{ accountId = 'acc0000000000000000000000000001'; tunnelId = '11111111-2222-3333-4444-555555555555' }
    $null = Invoke-WebUi $ui POST '/api/cloudflare/domains' @{ zoneIds = @('zone00000000000000000000000000001') }
    $writesBefore = @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' }).Count
    $cf = & $call 'cutover-plan'
    Test-Condition 'cutover plan: shows the DNS and tunnel changes and makes no write' ($cf.Status -eq 200 -and $cf.Data.connected -and @($cf.Data.actions | Where-Object { $_.kind -eq 'create' }).Count -eq 2 -and @(Get-MockRequests $mock | Where-Object { $_.method -ne 'GET' }).Count -eq $writesBefore) $cf.Body
    $noApproval = & $call 'cutover' @{ confirm = $true; fingerprint = $cf.Data.fingerprint }
    Test-Condition 'cutover: refused without the Cloudflare approval' ($noApproval.Status -eq 400) $noApproval.Body
    $stale = & $call 'cutover' @{ confirm = $true; approveCloudflare = $true; fingerprint = 'stale' }
    Test-Condition 'cutover: refused if Cloudflare changed since the review' ($stale.Status -eq 409) $stale.Body

    # Failed cutover: every write fails. Nothing stays half done and the local routes keep working.
    $null = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = 'mockReadOnly_' + [Guid]::NewGuid().ToString('N'); confirmReplace = $true }
    $cfRo = & $call 'cutover-plan'
    $failedCut = & $call 'cutover' @{ confirm = $true; approveCloudflare = $true; fingerprint = $cfRo.Data.fingerprint }
    Test-Condition 'failed cutover: reported as failed, never as done' ($failedCut.Status -eq 200 -and $failedCut.Data.phase -eq 'cutover-failed' -and @($failedCut.Data.steps | Where-Object { $_.status -eq 'Failed' }).Count -ge 1) $failedCut.Body
    Test-Condition 'failed cutover: the local routes still work and no record was created' ((& $getInt $i '/z').Status -eq 200 -and -not (Get-CloudflareTestRecord $mock 'voice.example.test')) ''
    $null = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = $apiToken; confirmReplace = $true }

    # Successful cutover.
    $cf = & $call 'cutover-plan'
    $cut = & $call 'cutover' @{ confirm = $true; approveCloudflare = $true; fingerprint = $cf.Data.fingerprint }
    Test-Condition 'cutover: approved changes are applied' ($cut.Status -eq 200 -and $cut.Data.phase -eq 'cutover' -and (Get-CloudflareTestRecord $mock 'voice.example.test')) $cut.Body
    $log = (Get-MockRequests $mock | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 6 -Compress }) -join "`n"
    Test-Condition 'cutover: the internal hostname never reached Cloudflare' ($log -notmatch 'lan\.example\.test') ''
    $ver = & $call 'verify'
    Test-Condition 'verify: an unresolvable public name is not claimed as working' ($ver.Status -eq 200 -and $ver.Data.phase -eq 'cutover' -and @(Get-CheckStates $ver.Data.checks 'dns') -contains 'failed') $ver.Body

    # Retirement.
    $tooEarly = & $call 'retire' @{ confirm = $true; action = 'stop'; names = @($legacyProxy) }
    Test-Condition 'retire: refused before a successful verification' ($tooEarly.Status -eq 409) $tooEarly.Body
    # .test names cannot resolve publicly, so this run marks verification done. ConvertTo-PublicChecks has its own tests above.
    $s = Read-AdoptionState $extSettings 'fakevoice'; $s.phase = 'verified'; Save-AdoptionState $extSettings 'fakevoice' $s
    $rp = & $call 'retire-plan'
    $names = @($rp.Data.items | ForEach-Object { $_.name })
    Test-Condition 'retire: candidates are the old proxy and its networks only' (($names -contains $legacyProxy) -and ($names -contains $legacyNet) -and ($names -notcontains $performC) -and ($names -notcontains $extSettings.ProxyNetwork) -and @($rp.Data.items | Where-Object { $_.name -eq $legacyUsed })[0].blocked -match 'Still used') $rp.Body
    $del1 = & $call 'retire' @{ confirm = $true; action = 'delete'; names = @($legacyProxy); confirmText = $legacyProxy }
    Test-Condition 'retire: a running proxy must be stopped before it is deleted' (@($del1.Data.results)[0].status -eq 'Refused') $del1.Body
    $stop = & $call 'retire' @{ confirm = $true; action = 'stop'; names = @($legacyProxy) }
    Test-Condition 'retire: stopping is its own step and keeps the container' (@($stop.Data.results)[0].status -eq 'Done' -and (Invoke-Docker inspect $legacyProxy).ExitCode -eq 0) $stop.Body
    $noType = & $call 'retire' @{ confirm = $true; action = 'delete'; names = @($legacyProxy) }
    Test-Condition 'retire: deleting needs the name typed' ($noType.Status -eq 400) $noType.Body
    $del2 = & $call 'retire' @{ confirm = $true; action = 'delete'; names = @($legacyProxy); confirmText = $legacyProxy }
    $del3 = & $call 'retire' @{ confirm = $true; action = 'delete'; names = @($legacyNet); confirmText = $legacyNet }
    $del4 = & $call 'retire' @{ confirm = $true; action = 'delete'; names = @($performC); confirmText = $performC }
    $del5 = & $call 'retire' @{ confirm = $true; action = 'delete'; names = @($volume); confirmText = $volume }
    Test-Condition 'retire: old container and unused network deleted; application and volume refused' (@($del2.Data.results)[0].status -eq 'Done' -and @($del3.Data.results)[0].status -eq 'Done' -and @($del4.Data.results)[0].status -eq 'Refused' -and @($del5.Data.results)[0].status -eq 'Refused' -and (Invoke-Docker volume inspect $volume).ExitCode -eq 0 -and (Invoke-Docker inspect $performC).ExitCode -eq 0) "$($del2.Body) $($del3.Body) $($del4.Body) $($del5.Body)"

    # Browser.
    if ($SkipBrowser) { Add-Result 'SKIP' 'browser' '-SkipBrowser' }
    elseif (-not (Get-EdgePath)) { Add-Result 'SKIP' 'browser' 'Microsoft Edge not found' }
    else {
      $base = "http://127.0.0.1:$($ui.Port)"
      $cdp = Start-EdgeSession -WorkDir $work
      Set-Viewport $cdp 1366 900
      Open-Page $cdp $ui.LaunchUrl
      $null = Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && document.querySelector('main h1')" 30
      Open-Page $cdp "$base/#adopt"
      $null = Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && [...document.querySelectorAll('a.btn.primary')].some((a) => a.textContent === 'Adopt')" 40
      Test-Condition 'browser: the Adopt page lists the application' ([string](Invoke-PageScript $cdp "document.querySelector('main').innerText") -match 'Fake Voice') ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'adopt-list.png') }
      $null = Invoke-PageScript $cdp "[...document.querySelectorAll('a.btn.primary')].find((a) => a.textContent === 'Adopt').click()"
      $null = Wait-PageCondition $cdp "!!document.querySelector('#adopt-preview')" 30
      $null = Invoke-PageScript $cdp "document.querySelector('#adopt-preview').click()"
      $null = Wait-PageCondition $cdp "document.querySelector('main').innerText.includes('Network changes') || document.querySelector('main').innerText.includes('No network changes')" 40
      $txt = [string](Invoke-PageScript $cdp "document.querySelector('main').innerText")
      Test-Condition 'browser: the wizard previews both routes with their paths' ($txt -match 'voice\.example\.test' -and $txt -match 'voice\.lan\.example\.test' -and $txt -match '/perform-api') $txt
      Test-Condition 'browser: no drift banner while nothing has drifted' ($txt -notmatch 'has drifted') ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'adopt-preview.png') }
      Set-Viewport $cdp 390 800 -Mobile
      $over = Invoke-PageScript $cdp 'document.documentElement.scrollWidth > window.innerWidth + 1'
      Test-Condition 'browser: no sideways scrolling at phone width' (-not $over) ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'adopt-preview-phone.png') }
      Test-Condition 'browser: no JavaScript errors' ($cdp.Errors.Count -eq 0) ($cdp.Errors -join ' | ')
    }

    # Rollback after a cutover.
    $hadVolume = (Invoke-Docker volume inspect $volume).ExitCode -eq 0
    $tritonId = ((Invoke-Docker inspect $tritonC --format '{{.Id}}').Output -join '')
    $roll = & $call 'rollback' @{ confirm = $true }
    Test-Condition 'rollback: route files removed from both proxies' ($roll.Status -eq 200 -and -not (Test-Path -LiteralPath (Join-Path $extSettings.DynamicDir 'adopt-fakevoice-external.yml')) -and -not (Test-Path -LiteralPath (Join-Path $intSettings.DynamicDir 'adopt-fakevoice-internal.yml'))) $roll.Body
    Test-Condition 'rollback: what the cutover created in Cloudflare is gone; the existing record stays' (-not (Get-CloudflareTestRecord $mock 'voice.example.test') -and (Get-CloudflareTestRecord $mock 'keep.example.test')) $roll.Body
    Test-Condition 'rollback: application container, its data and unrelated attachments are untouched' ($hadVolume -and (Invoke-Docker volume inspect $volume).ExitCode -eq 0 -and ((Invoke-Docker inspect $tritonC --format '{{.Id}}').Output -join '') -eq $tritonId -and ((Invoke-Docker inspect $tritonC --format '{{.State.Status}}').Output -join '') -eq 'running' -and ((Invoke-Docker inspect $performC --format '{{json .NetworkSettings.Networks}}').Output -join '') -match [regex]::Escape($legacyUsed)) ''
    Test-Condition 'rollback: routes stop answering' ((& $getInt $i '/z').Status -eq 404) ''

    $leak = @($ui.Bodies | Where-Object { $_ -and ($_ -match [regex]::Escape($apiToken) -or $_ -match 'mockReadOnly_') })
    Test-Condition 'credentials: no API token in any response' ($leak.Count -eq 0) ''
    $inFiles = @(Get-ChildItem -LiteralPath (Join-Path $extPath 'config\adoptions') -Recurse -File | Where-Object { [IO.File]::ReadAllText($_.FullName) -match [regex]::Escape($apiToken) })
    Test-Condition 'credentials: no API token in adoption state' ($inFiles.Count -eq 0) ''
  } catch {
    Add-Result 'FAIL' 'adoption test run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
  } finally {
    if ($cdp) { Stop-EdgeSession $cdp }
    Stop-TestServer $ui; Stop-TestServer $mock
    foreach ($n in @($tritonC, $performC, $uiC, $singleC, $authC, $legacyProxy)) { $null = Invoke-Docker rm -f $n }
    foreach ($item in @(@($extPath, $extUp), @($intPath, $intUp))) { if ($item[1] -and (Test-Path -LiteralPath (Join-Path $item[0] 'install.ps1'))) { $null = Invoke-Ps (Join-Path $item[0] 'install.ps1') @('-InstallPath', $item[0], '-Stop') } }
    foreach ($n in @("$ext-proxy", "$int-proxy", $appsNet, $legacyNet, $legacyUsed)) { $null = Invoke-Docker network rm $n }
    $null = Invoke-Docker volume rm $volume
    $left = @((Invoke-Docker ps -a --filter "name=$prefix" --format '{{.Names}}').Output | Where-Object { $_ })
    $leftNets = @((Invoke-Docker network ls --filter "name=$prefix" --format '{{.Name}}').Output | Where-Object { $_ })
    $leftVol = @((Invoke-Docker volume ls --filter "name=$prefix" --format '{{.Name}}').Output | Where-Object { $_ })
    Test-Condition 'teardown: no disposable container, network or volume left' ($left.Count -eq 0 -and $leftNets.Count -eq 0 -and $leftVol.Count -eq 0) (($left + $leftNets + $leftVol) -join ', ')
    $after = Get-EngineSnapshot $prefix
    $changed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) -or $after[$_] -ne $before[$_] })
    Test-Condition "other containers untouched ($($before.Count) checked: same IDs, start times, states)" ($changed.Count -eq 0) ("changed: $($changed -join ', ')")
    $liveAfter = Get-LiveRouteHashes (Join-Path $LiveInstall 'traefik\dynamic')
    $liveChanged = @($liveBefore.Keys | Where-Object { $_ -ne '.reload' -and $liveBefore[$_] -ne $liveAfter[$_] }) + @($liveAfter.Keys | Where-Object { -not $liveBefore.ContainsKey($_) })
    Test-Condition "live route files unchanged ($($liveBefore.Count) checked)" ($liveChanged.Count -eq 0) ($liveChanged -join ', ')
    Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
