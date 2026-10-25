#requires -version 5.1
<#
.SYNOPSIS
  Identity & Access end to end on a disposable instance: authentik installed through the App Catalog (fresh install with
  bootstrap administrator and API token), adopted on the Identity & Access page, its sign-in route, the embedded
  outpost, a Google source with SYNTHETIC credentials, a protected test application (ForwardAuth), real sign-ins with
  local test users (allowed / denied / group), fail-closed behaviour, rollback, interrupted setup, persistence and the
  browser page.

.DESCRIPTION
  Everything it creates carries the instance's unique prefix (containers, networks, the authentik project and its
  volume) and is removed at the end; every other container on the engine must keep its ID, start time and state.
  Nothing reaches Cloudflare or Google: the instance is local only, the Google client ID/secret are synthetic and the
  Google sign-in itself is not exercised (that needs a real Google account; see docs\identity.md). Sign-ins use local
  authentik users through the real embedded outpost and Traefik.

  Needs about 1.6 GB of free memory inside Docker Desktop. The authentik and Traefik images are used from the local
  image store when present (pinned digests), otherwise downloaded.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-IdentityLive.ps1 -ScreenshotDir $env:TEMP\tpm-identity-shots
#>
[CmdletBinding()]
param([string]$ScreenshotDir, [switch]$SkipBrowser, [string]$TunnelSubnet = '172.31.244.0/28', [switch]$KeepOnFailure)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\Authentik.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
Import-Module (Join-Path $repo 'tests\EdgeCdp.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Invoke-Ps([string]$Script, [string[]]$Arguments) {
  $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $previous }
  return [pscustomobject]@{ ExitCode = $code; Text = (@($out) -join "`n") }
}
function Get-EngineSnapshot([string]$ExcludePrefix) {
  $map = @{}
  foreach ($line in (Invoke-Docker ps -a --format '{{.Names}}').Output) {
    if (-not $line -or $line.StartsWith($ExcludePrefix) -or $line -match '-validate-' -or $line -match '-probe-') { continue }
    $map[$line] = ((Invoke-Docker inspect $line --format '{{.Id}} {{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim()
  }
  return $map
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 120, [int]$StepMs = 3000) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do { try { if (& $Condition) { return $true } } catch { }; Start-Sleep -Milliseconds $StepMs } while ((Get-Date) -lt $deadline)
  return $false
}
function Get-Step($Data, [string]$Id) { return @($Data.model.steps | Where-Object { $_.id -eq $Id })[0] }
function Get-Comp($Data, [string]$Id) { return @($Data.model.components | Where-Object { $_.id -eq $Id })[0] }

# A browser-like sign-in with curl.exe: log in through authentik's flow executor on the sign-in hostname, then open the
# protected application and follow every redirect (outpost start -> authorize -> callback -> application).
function Invoke-SignIn([int]$Port, [string]$AuthHost, [string]$AppHost, [string]$User, [string]$Password, [string]$Work) {
  $jar = Join-Path $Work ("jar-" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
  $out = Join-Path $Work 'signin.out'
  $r = @('--resolve', "${AuthHost}:${Port}:127.0.0.1", '--resolve', "${AppHost}:${Port}:127.0.0.1", '-s', '-c', $jar, '-b', $jar)
  $ex = "http://${AuthHost}:$Port/api/v3/flows/executor/default-authentication-flow/?query=next%3D%252F"
  $b1 = Join-Path $Work 'b1.json'; $b2 = Join-Path $Work 'b2.json'
  [IO.File]::WriteAllText($b1, (ConvertTo-Json -Compress @{ component = 'ak-stage-identification'; uid_field = $User }))
  [IO.File]::WriteAllText($b2, (ConvertTo-Json -Compress @{ component = 'ak-stage-password'; password = $Password }))
  $null = & curl.exe @r -o NUL $ex
  $s1 = (& curl.exe @r -L $ex -H 'Content-Type: application/json' --data-binary "@$b1") -join ''
  $s2 = (& curl.exe @r -L $ex -H 'Content-Type: application/json' --data-binary "@$b2") -join ''
  $w = (& curl.exe @r -L --max-redirs 12 -o $out -w '%{http_code} %{url_effective}' "http://${AppHost}:$Port/") -join ''
  $body = $(if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) } else { '' })
  Remove-Item -LiteralPath $jar, $out, $b1, $b2 -Force -ErrorAction SilentlyContinue
  $login = $(try { [string]($s2 | ConvertFrom-Json).component } catch { '' })
  $parts = $w.Split(' ', 2)
  return [pscustomobject]@{ Login = $login; Status = [int]$parts[0]; Url = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }); Body = $body
    ReachedApp = ($parts.Count -gt 1 -and $parts[1] -like "http://${AppHost}:$Port/*" -and $parts[1] -notmatch 'outpost\.goauthentik\.io' -and [int]$parts[0] -eq 200) }
}

if (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'identity live test' 'Docker engine not running'; exit 0 }

$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$stack = "tpx-id-$id"; $network = "$stack-proxy"
$work = Join-Path ([IO.Path]::GetTempPath()) $stack
$installPath = Join-Path $work 'instance'
$akProject = "$stack-ak"; $akFolder = Join-Path $work 'authentik'
$authHost = 'auth.idtest.example'; $appHost = 'echo.idtest.example'
$app = "$stack-echo"
$whoami = 'traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44'
# Synthetic Google credentials (shape only). They must never appear in a response, file or log of the manager.
$googleId = '123456789012-tpxidentitytest0001.apps.googleusercontent.com'
$googleSecret = 'GOCSPX-' + [Guid]::NewGuid().ToString('N')
New-Item -ItemType Directory -Force -Path $work | Out-Null
if ($ScreenshotDir) { New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null; $ScreenshotDir = (Resolve-Path $ScreenshotDir).Path }
$o = $TunnelSubnet.Split('/')[0].Split('.')
$envFile = Join-Path $work 'instance.env'
$httpPort = Get-FreeTcpPort; $akPort = Get-FreeTcpPort
@("STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$httpPort", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$network", "TUNNEL_SUBNET=$TunnelSubnet",
  "TUNNEL_IP_RANGE=$($o[0]).$($o[1]).$($o[2]).$($o[3])/29", "CLOUDFLARED_IP=$($o[0]).$($o[1]).$($o[2]).$([int]$o[3] + 10)", 'TRAEFIK_LOG_LEVEL=INFO') | Set-Content -LiteralPath $envFile -Encoding ASCII
$before = Get-EngineSnapshot $stack
$installed = $false; $ui = $null; $cdp = $null; $failed = $false
try {
  # --- Instance ------------------------------------------------------------------------------------------------------------
  $install = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-Start')
  $installed = Test-Path -LiteralPath $installPath
  Test-Condition 'instance: install -Start (local only, disposable)' ($install.ExitCode -eq 0) ($install.Text -split "`n" | Select-Object -Last 12 | Out-String)
  if ($install.ExitCode -ne 0) { throw 'Install failed.' }
  $uiDir = (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName
  $ui = Start-WebUiServer -Script (Join-Path $installPath 'webui.ps1') -InstallPath $installPath -WorkDir $uiDir
  $null = Connect-WebUi $ui

  # --- Fresh installation through the App Catalog ---------------------------------------------------------------------------
  $plan = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'authentik'; project = $akProject; folder = $akFolder; localPort = $akPort; timezone = 'UTC'; inputs = @{ adminEmail = 'admin@idtest.example' }; startNow = $false }
  $cc = @($plan.Data.checks | Where-Object { $_.label -eq 'docker compose config' })[0]
  Test-Condition 'install: Compose project validated by docker compose config' ($plan.Status -eq 200 -and $cc -and $cc.state -eq 'ok') ($plan.Body)
  $compose = [string]$plan.Data.compose
  Test-Condition 'install: images pinned by digest; no Docker socket; PostgreSQL only on the private network' ($compose -match 'goauthentik/server:2026\.8\.5@sha256:' -and $compose -match 'postgres:16-alpine@sha256:' -and $compose -notmatch 'docker\.sock' -and ($compose -split "`n" | Select-String -Pattern '^\s+networks: \[internal\]$').Count -eq 2) ''
  Test-Condition 'install: bootstrap administrator and API token come from .env, masked in the preview' ($compose -match 'AUTHENTIK_BOOTSTRAP_TOKEN: \$\{AUTHENTIK_BOOTSTRAP_TOKEN\}' -and $plan.Data.envPreview -match 'AUTHENTIK_BOOTSTRAP_TOKEN=<secret' -and $plan.Data.envPreview -match 'AUTHENTIK_BOOTSTRAP_PASSWORD=<secret') ($plan.Data.envPreview)
  $apply = Invoke-WebUi $ui POST '/api/catalog/apply' @{ planId = $plan.Data.planId; confirm = $true }
  Test-Condition 'install: project prepared (files written, nothing started yet)' ($apply.Status -eq 200 -and $apply.Data.ok -and $apply.Data.prepared) ($apply.Body)
  $envText = [IO.File]::ReadAllText((Join-Path $akFolder '.env'))
  $bootToken = ([regex]::Match($envText, 'AUTHENTIK_BOOTSTRAP_TOKEN=(\S+)')).Groups[1].Value
  $adminPass = ([regex]::Match([IO.File]::ReadAllText((Join-Path $akFolder 'credentials.txt')), 'password: (\S+)')).Groups[1].Value
  $acl = (Get-Acl -LiteralPath (Join-Path $akFolder '.env')).Access | ForEach-Object { [string]$_.IdentityReference }
  Test-Condition 'install: .env and credentials.txt hold the generated secrets, readable by this account, SYSTEM and Administrators only' ($bootToken.Length -ge 40 -and $adminPass.Length -ge 12 -and -not @($acl | Where-Object { $_ -match 'Users$|Everyone|Authenticated' }).Count) ($acl -join ', ')

  # Identity page before authentik runs: a prepared installation is found but not running.
  $null = Invoke-WebUi $ui POST '/api/identity/provider' @{ provider = 'authentik' }
  $g0 = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'discovery: the prepared project is listed (managed, not started)' (@($g0.Data.installs | Where-Object { $_.project -eq $akProject -and $_.managed -and -not $_.server }).Count -eq 1) ($g0.Body)

  $start = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $akProject; action = 'start'; force = $true; confirm = $true }
  Test-Condition 'install: start (docker compose up) succeeds' ($start.Status -eq 200 -and $start.Data.ok) ($start.Body)
  $ready = Wait-Until { $hh = Get-AuthentikHealth -BaseUrl "http://127.0.0.1:$akPort"; $hh.Ready -and $hh.Setup -eq 'done' } 300 5000
  Test-Condition 'readiness: server answers, database ready, initial setup already complete (bootstrap)' $ready ''
  $flowsReady = Wait-Until { $c = New-AuthentikConnection -BaseUrl "http://127.0.0.1:$akPort" -Token $bootToken; @((Get-AuthentikOverview $c).MissingFlows).Count -eq 0 } 240 5000
  Test-Condition 'readiness: default flows created by the worker (blueprints applied)' $flowsReady ''
  $nets = { param($c) @(((Invoke-Docker inspect $c --format '{{json .NetworkSettings.Networks}}').Output -join '' | ConvertFrom-Json).PSObject.Properties.Name) }
  $srvNets = & $nets "$akProject-server"; $wrkNets = & $nets "$akProject-worker"; $dbNets = & $nets "$akProject-postgresql"
  Test-Condition 'networks: only the server joins the shared proxy network; worker and database stay private' ($srvNets -contains $network -and $wrkNets -notcontains $network -and $dbNets -notcontains $network -and @($dbNets).Count -eq 1) "server: $($srvNets -join ','); worker: $($wrkNets -join ','); db: $($dbNets -join ',')"
  $dbPorts = ((Invoke-Docker inspect "$akProject-postgresql" --format '{{json .NetworkSettings.Ports}}').Output -join '')
  Test-Condition 'networks: PostgreSQL publishes no port' ($dbPorts -notmatch 'HostPort') $dbPorts

  # --- Identity & Access: adopt, connect ------------------------------------------------------------------------------------
  $bad = Invoke-WebUi $ui POST '/api/identity/provider' @{ provider = 'authelia' }
  Test-Condition 'provider: Authelia is listed but refused (integration not implemented)' ($bad.Status -eq 409 -and $bad.Data.error -match 'not implemented') ($bad.Body)
  $ad = Invoke-WebUi $ui POST '/api/identity/adopt' @{ project = $akProject }
  Test-Condition 'adopt: the catalog installation is recorded (nothing in authentik changes)' ($ad.Status -eq 200 -and $ad.Data.install.serverContainer -eq "$akProject-server" -and $ad.Data.install.onProxyNetwork) ($ad.Body)
  $tk = Invoke-WebUi $ui POST '/api/identity/token' @{ token = 'not-a-real-token-value-0000000000' }
  Test-Condition 'token: a wrong token is rejected and not saved' ($tk.Status -eq 400 -and -not (Test-Path -LiteralPath (Join-Path $installPath 'secrets\authentik_api.dpapi'))) ($tk.Body)
  $tk = Invoke-WebUi $ui POST '/api/identity/token' @{ fromBootstrap = $true }
  $dp = Join-Path $installPath 'secrets\authentik_api.dpapi'
  Test-Condition 'token: the installation''s bootstrap token is taken from its .env and stored with DPAPI' ($tk.Status -eq 200 -and $tk.Data.superuser -and (Test-Path -LiteralPath $dp) -and ([IO.File]::ReadAllText($dp) -notmatch [regex]::Escape($bootToken))) ($tk.Body)
  $g1 = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'model: install reachable, administrator configured, API verified' ((Get-Step $g1.Data 'install').state -eq 'reachable' -and (Get-Step $g1.Data 'admin').state -eq 'configured' -and (Get-Step $g1.Data 'api').state -eq 'verified') (($g1.Data.model.steps | ForEach-Object { "$($_.id)=$($_.state)" }) -join ', ')
  Test-Condition 'model: Google and applications await the public address / user (never verified yet)' ((Get-Step $g1.Data 'google').state -eq 'not-configured' -and (Get-Step $g1.Data 'apps').state -eq 'awaiting-user' -and (Get-Step $g1.Data 'hostname').state -eq 'awaiting-user') ''

  # --- Sign-in hostname ---------------------------------------------------------------------------------------------------
  $hn = Invoke-WebUi $ui POST '/api/identity/hostname' @{ hostname = $authHost; service = 'authentik' }
  Test-Condition 'hostname: saved; redirect URI derived from it (no hard-coded domain)' ($hn.Status -eq 200 -and $hn.Data.redirectUri -eq "https://$authHost/source/oauth/callback/google/") ($hn.Body)
  $g2 = Invoke-WebUi $ui GET '/api/identity'
  $rb = $g2.Data.routeBody
  Test-Condition 'hostname: suggested route targets the real container name and internal port (Docker DNS, no IP)' ($rb.op -eq 'add' -and $rb.service.target.host -eq "$akProject-server" -and $rb.service.target.port -eq 9000 -and $rb.service.target.type -eq 'docker') ($rb | ConvertTo-Json -Depth 6 -Compress)
  $rb.service.cloudflare.publish = $false; $rb.service.cloudflare.access = $false
  $ch = Invoke-WebUiChange $ui @{ op = $rb.op; name = $rb.name; service = $rb.service; cloudflare = @{ automate = $false } }
  $authYaml = [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-authentik.yml'))
  Test-Condition 'hostname: route applied through the normal preview/validation/backup path; no ForwardAuth on authentik itself' ($ch.Apply -and $ch.Apply.Data.ok -and $authYaml -match "url: http://$akProject-server:9000" -and $authYaml -notmatch 'forwardAuth') ($ch.Apply.Body)
  $op = Invoke-WebUi $ui POST '/api/identity/outpost/plan' @{}
  $opA = Invoke-WebUi $ui POST '/api/identity/outpost/apply' @{ planId = $op.Data.planId; confirm = $true }
  $conn = New-AuthentikConnection -BaseUrl "http://127.0.0.1:$akPort" -Token $bootToken
  Test-Condition 'outpost: embedded outpost previewed, then pointed at the public sign-in URL' ($op.Data.canApply -and $opA.Status -eq 200 -and (Get-AuthentikOverview $conn).Outpost.AuthentikHost -eq "https://$authHost/") ($opA.Body)

  # --- Google (synthetic credentials) ---------------------------------------------------------------------------------------
  $sv = Invoke-WebUi $ui POST '/api/identity/google/save' @{ clientId = $googleId; signup = 'allowlist'; emails = @('alice@idtest.example'); domains = @('partner.idtest.example') }
  Test-Condition 'google: draft saved without any secret (resumable)' ($sv.Status -eq 200 -and [IO.File]::ReadAllText((Join-Path $installPath 'config\identity.json')) -match [regex]::Escape($googleId)) ($sv.Body)
  # Restart the manager (browser refresh / reboot): the draft and progress survive.
  Stop-TestServer $ui
  $ui = Start-WebUiServer -Script (Join-Path $installPath 'webui.ps1') -InstallPath $installPath -WorkDir $uiDir
  $null = Connect-WebUi $ui
  $g3 = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'resume: after a manager restart the Google draft, hostname and progress are still there' ($g3.Data.config.authentik.google.clientId -eq $googleId -and $g3.Data.config.authentik.hostname -eq $authHost -and $g3.Data.progress.step -eq 'google' -and (Get-Step $g3.Data 'google').state -eq 'awaiting-user') ($g3.Data.progress | ConvertTo-Json -Compress)
  Test-Condition 'google: wizard values (redirect URI, Web application, minimal scopes)' ($g3.Data.googleValues.RedirectUri -eq "https://$authHost/source/oauth/callback/google/" -and $g3.Data.googleValues.ClientType -eq 'Web application' -and (@($g3.Data.googleValues.ScopeNames) -join ',') -eq 'openid,email,profile') ($g3.Data.googleValues | ConvertTo-Json -Compress)
  $badId = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientId = 'not-a-client-id'; clientSecret = $googleSecret; signup = 'allowlist'; emails = @('alice@idtest.example') }
  Test-Condition 'google: an invalid client ID is refused before authentik is touched' ($badId.Status -eq 400) ($badId.Body)
  $gp = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientId = $googleId; clientSecret = $googleSecret; signup = 'allowlist'; emails = @('alice@idtest.example'); domains = @('partner.idtest.example'); matching = 'identifier'; showOnLogin = $true }
  Test-Condition 'google: preview lists the enrollment flow, allow-list policy, source and login button (nothing applied)' ($gp.Status -eq 200 -and @($gp.Data.actions | Where-Object { $_.kind -eq 'create' }).Count -ge 4 -and @(Get-AuthentikList $conn '/sources/oauth/?slug=google').Count -eq 0) ($gp.Body)
  $ga = Invoke-WebUi $ui POST '/api/identity/google/apply' @{ planId = $gp.Data.planId; confirm = $true }
  $src = @(Get-AuthentikList $conn '/sources/oauth/?slug=google')[0]
  Test-Condition 'google: source created through the API (type google, client ID, identifier matching, restricted enrollment flow)' ($ga.Status -eq 200 -and $ga.Data.ok -and $src -and $src.provider_type -eq 'google' -and $src.consumer_key -eq $googleId -and $src.user_matching_mode -eq 'identifier') ($ga.Body)
  Test-Condition 'google: authentik redirects to Google with the right client ID and redirect URI' ($ga.Data.redirect.ok -and $ga.Data.redirect.redirectUri -eq "https://$authHost/source/oauth/callback/google/") ($ga.Data.redirect | ConvertTo-Json -Compress)
  $ov = Get-AuthentikOverview $conn
  Test-Condition 'google: the login page shows the Google button' ($ov.LoginStage.Sources -contains [string]$src.pk) ''
  $gp2 = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientId = $googleId; signup = 'allowlist'; emails = @('alice@idtest.example'); domains = @('partner.idtest.example') }
  Test-Condition 'google: running the wizard again changes nothing (no duplicate source, secret kept)' (@($gp2.Data.actions | Where-Object { $_.kind -ne 'none' }).Count -eq 0 -and @(Get-AuthentikList $conn '/sources/oauth/').Count -eq 1) (($gp2.Data.actions | ForEach-Object { "$($_.kind):$($_.summary)" }) -join '; ')
  $g4 = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'google: configured, NOT verified (synthetic credentials, nobody signed in with Google)' ((Get-Step $g4.Data 'google').state -eq 'configured' -and -not $g4.Data.google.verifiedAt -and (Get-Comp $g4.Data 'google-login').state -eq 'awaiting-user') (Get-Step $g4.Data 'google' | ConvertTo-Json -Compress)

  # --- Protect a disposable application -------------------------------------------------------------------------------------
  $r0 = Invoke-Docker run -d --name $app --network $network --pull missing $whoami
  $add = Invoke-WebUiChange $ui @{ op = 'add'; service = @{ name = 'echo'; displayName = 'Echo test'; hostnames = @($appHost); target = @{ type = 'docker'; host = $app; port = 80 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
  Test-Condition 'app: disposable whoami published through Traefik (no sign-in yet)' ($r0.ExitCode -eq 0 -and $add.Apply.Data.ok -and (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost).State -eq 'open') ($add.Apply.Body)
  $self = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ service = 'authentik'; emails = @('alice@idtest.example') }
  Test-Condition 'protect: the authentik sign-in page itself cannot be protected (loop guard)' ($self.Status -eq 400) ($self.Body)
  $none = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ service = 'echo' }
  Test-Condition 'protect: refused without anyone allowed (an unbound application would admit every user)' ($none.Status -eq 400 -and $none.Data.error -match 'Choose who may open') ($none.Body)
  # A leftover from an interrupted earlier attempt: the manager reuses it instead of creating a duplicate.
  $null = Invoke-AuthentikApi $conn POST '/policies/expression/' @{ name = 'dm-echo-access'; expression = 'return False' }
  $pp = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ service = 'echo'; emails = @('alice@idtest.example'); createGroup = $true }
  $diff = (@($pp.Data.traefik.traefik.changes | ForEach-Object { $_.diff }) | ForEach-Object { $_ }) -join "`n"
  Test-Condition 'protect: preview shows authentik objects and the ForwardAuth route diff' ($pp.Status -eq 200 -and $pp.Data.canApply -and $diff -match 'forwardAuth' -and $diff -match 'svc-echo-outpost' -and $diff -match "address: http://$akProject-server:9000/outpost.goauthentik.io/auth/traefik") ($pp.Body)
  Test-Condition 'protect: the leftover policy from an interrupted attempt is updated, not duplicated' (@($pp.Data.authentik | Where-Object { $_.object -eq 'policy' -and $_.kind -eq 'update' }).Count -eq 1) (($pp.Data.authentik | ForEach-Object { "$($_.kind):$($_.object)" }) -join ', ')
  $pa = Invoke-WebUi $ui POST '/api/identity/protect/apply' @{ planId = $pp.Data.planId; confirm = $true }
  Test-Condition 'protect: applied; an unauthenticated request now has to sign in' ($pa.Status -eq 200 -and $pa.Data.ok -and $pa.Data.challenge.State -eq 'auth') ($pa.Body)
  $protectBackup = [string]$pa.Data.traefik.backup
  $edit = Invoke-WebUiChange $ui @{ op = 'update'; name = 'echo'; service = @{ name = 'echo'; displayName = 'Echo (renamed)'; hostnames = @($appHost); target = @{ type = 'docker'; host = $app; port = 80 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
  Test-Condition 'services: editing a protected service without the sign-in field keeps its protection' ($edit.Apply.Data.ok -and [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo.yml')) -match 'svc-echo-authentik') ($edit.Apply.Body)

  # Sign-ins through the real outpost. The test reaches Traefik on a local port over http, so the provider and outpost
  # addresses are switched to that address for this part (production uses https://<host> without a port).
  $prov = @(Get-AuthentikList $conn '/providers/proxy/?name=dm-echo')[0]
  $null = Invoke-AuthentikApi $conn PATCH "/providers/proxy/$($prov.pk)/" @{ mode = 'forward_single'; external_host = "http://${appHost}:$httpPort" }
  $null = Sync-AuthentikOutpost -Conn $conn -PublicUrl "http://${authHost}:$httpPort"
  $mk = { param($u, $e, $p) $x = Invoke-AuthentikApi $conn POST '/core/users/' @{ username = $u; name = $u; email = $e; is_active = $true; path = 'users' }; $null = Invoke-AuthentikApi $conn POST "/core/users/$($x.pk)/set_password/" @{ password = $p }; $x }
  $alice = & $mk 'alice' 'alice@idtest.example' 'Alice-Live-Test-91x'
  $mallory = & $mk 'mallory' 'mallory@other.example' 'Mallory-Live-Test-77y'
  # Wait until the outpost has reloaded the test addresses (it refreshes a few seconds after a change).
  $null = Wait-Until { $x = Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -HostPort $httpPort -AuthHostname $authHost; $x.State -eq 'auth' -and $x.Location -match "^http://${authHost}:$httpPort/" } 90 2000
  $anon = Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -HostPort $httpPort -AuthHostname $authHost
  Test-Condition 'forwardauth: anonymous visitors are sent to the authentik sign-in (no loop)' ($anon.State -eq 'auth' -and $anon.Location -match "^http://${authHost}:$httpPort/") ($anon | ConvertTo-Json -Compress)
  $sa = Invoke-SignIn $httpPort $authHost $appHost 'alice' 'Alice-Live-Test-91x' $work
  Test-Condition 'authorization: an allowed user signs in and reaches the application (identity headers passed)' ($sa.Login -eq 'xak-flow-redirect' -and $sa.ReachedApp -and $sa.Body -match 'X-Authentik-Username: alice') "$($sa.Status) $($sa.Url)"
  $sm = Invoke-SignIn $httpPort $authHost $appHost 'mallory' 'Mallory-Live-Test-77y' $work
  Test-Condition 'authorization: a signed-in user who is not allowed is refused and never reaches the application' ($sm.Login -eq 'xak-flow-redirect' -and -not $sm.ReachedApp -and $sm.Body -notmatch 'X-Authentik-Username' -and $sm.Body -match 'Permission denied') "$($sm.Status) $($sm.Url)"
  $sw = Invoke-SignIn $httpPort $authHost $appHost 'alice' 'wrong-password-123' $work
  Test-Condition 'authorization: a wrong password never reaches the application' (-not $sw.ReachedApp) "$($sw.Status) $($sw.Url)"
  $grp = @(Get-AuthentikList $conn '/core/groups/?name=echo%20users')[0]
  $null = Invoke-AuthentikApi $conn POST "/core/groups/$($grp.pk)/add_user/" @{ pk = [int]$mallory.pk }
  $sg = Invoke-SignIn $httpPort $authHost $appHost 'mallory' 'Mallory-Live-Test-77y' $work
  Test-Condition 'authorization: adding the user to the application''s group grants access' ($sg.ReachedApp) "$($sg.Status) $($sg.Url)"
  $g5 = Invoke-WebUi $ui GET '/api/identity?deep=1'
  $ea = @($g5.Data.apps | Where-Object { $_.service -eq 'echo' })[0]
  Test-Condition 'verification: the application is marked verified only from authentik''s own access event' ($ea.verifiedAt -and $ea.verifiedBy -in 'alice', 'mallory' -and (Get-Comp $g5.Data 'app:echo').state -eq 'verified') ($ea | ConvertTo-Json -Compress -Depth 4)
  $null = Invoke-AuthentikApi $conn PATCH "/providers/proxy/$($prov.pk)/" @{ mode = 'forward_single'; external_host = "https://$appHost" }
  $null = Sync-AuthentikOutpost -Conn $conn -PublicUrl "https://$authHost"

  # Loop detection: a hand-written route that redirects to itself.
  $loopFile = Join-Path $installPath 'traefik\dynamic\zz-loop-test.yml'
  # Two routes that redirect to each other (/ -> /b -> /a -> /b ...): Traefik itself never redirects a URL to itself.
  $loopYaml = @(
    'http:', '  routers:',
    '    loop-a:', "      rule: 'Host(``loop.idtest.example``) && (Path(``/``) || Path(``/a``))'", '      entryPoints: [web]', '      middlewares: [loop-to-b]', '      service: noop@internal',
    '    loop-b:', "      rule: 'Host(``loop.idtest.example``) && Path(``/b``)'", '      entryPoints: [web]', '      middlewares: [loop-to-a]', '      service: noop@internal',
    '  middlewares:',
    '    loop-to-b:', '      redirectRegex:', "        regex: '.*'", "        replacement: 'http://loop.idtest.example/b'",
    '    loop-to-a:', '      redirectRegex:', "        regex: '.*'", "        replacement: 'http://loop.idtest.example/a'") -join "`n"
  [IO.File]::WriteAllText($loopFile, $loopYaml + "`n")
  $null = Sync-TraefikDynamic (Get-StackSettings -InstallPath $installPath)
  $null = Wait-Until { (Invoke-AkHttp -Url "http://127.0.0.1:$httpPort/" -Headers @{ Host = 'loop.idtest.example' }).Status -eq 302 } 30 1000
  $lp = Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname 'loop.idtest.example' -AuthHostname $authHost
  Test-Condition 'loop detection: a redirect loop is reported as a loop' ($lp.State -eq 'loop') ($lp | ConvertTo-Json -Compress)
  Remove-Item -LiteralPath $loopFile -Force

  # --- Fail closed ----------------------------------------------------------------------------------------------------------
  $null = Invoke-Docker stop "$akProject-server"
  $down = Invoke-AkHttp -Url "http://127.0.0.1:$httpPort/" -Headers @{ Host = $appHost }
  Test-Condition 'fail closed: with authentik stopped the application is not served' ($down.Status -ge 500 -and $down.Body -notmatch 'Hostname:') "HTTP $($down.Status)"
  $gp3 = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ service = 'echo'; emails = @('alice@idtest.example') }
  Test-Condition 'interrupted: with authentik unreachable no change is previewed or applied' ($gp3.Status -eq 409) ($gp3.Body)
  $null = Invoke-Docker start "$akProject-server"
  $back = Wait-Until { (Get-AuthentikHealth -BaseUrl "http://127.0.0.1:$akPort").Ready } 180 3000
  $null = Wait-Until { (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -AuthHostname $authHost).State -eq 'auth' } 90 3000
  Test-Condition 'recovery: authentik restarted, the application asks for sign-in again' ($back -and (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -AuthHostname $authHost).State -eq 'auth') ''

  # --- Rollback through the service backups ---------------------------------------------------------------------------------
  $rs = Invoke-WebUi $ui POST '/api/backups/restore' @{ id = $protectBackup; confirm = $true }
  $echoYaml = [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo.yml'))
  Test-Condition 'rollback: restoring the backup made before protection restores the previous route (no ForwardAuth)' ($rs.Status -eq 200 -and $echoYaml -notmatch 'forwardAuth') ($rs.Body)
  $pp2 = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ service = 'echo'; emails = @('alice@idtest.example'); createGroup = $true }
  Test-Condition 'rollback: protecting again reuses the authentik objects (only the route changes)' ($pp2.Status -eq 200 -and @($pp2.Data.authentik | Where-Object { $_.kind -eq 'create' }).Count -eq 0 -and @($pp2.Data.traefik.traefik.changes).Count -eq 1) (($pp2.Data.authentik | ForEach-Object { "$($_.kind):$($_.object)" }) -join ', ')
  $pa2 = Invoke-WebUi $ui POST '/api/identity/protect/apply' @{ planId = $pp2.Data.planId; confirm = $true }
  Test-Condition 'rollback: protection re-applied' ($pa2.Data.ok -and $pa2.Data.challenge.State -eq 'auth') ($pa2.Body)

  # --- Unprotect ------------------------------------------------------------------------------------------------------------
  $up = Invoke-WebUi $ui POST '/api/identity/unprotect/plan' @{ service = 'echo' }
  Test-Condition 'unprotect: preview warns what stays in front of the application' ($up.Status -eq 200 -and (@($up.Data.notes) -join ' ') -match 'without sign-in') ($up.Body)
  $ua = Invoke-WebUi $ui POST '/api/identity/unprotect/apply' @{ planId = $up.Data.planId; confirm = $true }
  $apps = @(Get-AuthentikList $conn '/core/applications/?slug=dm-echo')
  Test-Condition 'unprotect: route without ForwardAuth, authentik application and provider removed, group kept' ($ua.Data.ok -and [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo.yml')) -notmatch 'forwardAuth' -and $apps.Count -eq 0 -and @(Get-AuthentikList $conn '/core/groups/?name=echo%20users').Count -eq 1) ($ua.Body)

  # --- Persistence and bootstrap semantics ----------------------------------------------------------------------------------
  $akadmin = @(Get-AuthentikList $conn '/core/users/?username=akadmin')[0]
  $null = Invoke-AuthentikApi $conn POST "/core/users/$($akadmin.pk)/set_password/" @{ password = 'Changed-Admin-Pass-55z' }
  $rr = Invoke-Docker compose --project-directory $akFolder -f (Join-Path $akFolder 'compose.yaml') restart
  $null = Wait-Until { (Get-AuthentikHealth -BaseUrl "http://127.0.0.1:$akPort").Ready } 240 5000
  $null = Wait-Until { @(Get-AuthentikList $conn '/sources/oauth/?slug=google').Count -eq 1 } 120 5000
  Test-Condition 'persistence: after restarting server, worker and database the configuration is still there' ($rr.ExitCode -eq 0 -and @(Get-AuthentikList $conn '/sources/oauth/?slug=google').Count -eq 1 -and @(Get-AuthentikList $conn '/core/users/?username=alice').Count -eq 1) ''
  $pwCheck = { param($pw) $b = Join-Path $work 'pw.json'; $j = Join-Path $work 'pw.jar'
    $ex = "http://127.0.0.1:$akPort/api/v3/flows/executor/default-authentication-flow/?query=next%3D%252F"
    $null = & curl.exe -s -c $j -b $j -o NUL $ex
    [IO.File]::WriteAllText($b, '{"component":"ak-stage-identification","uid_field":"akadmin"}'); $null = & curl.exe -s -L -c $j -b $j $ex -H 'Content-Type: application/json' --data-binary "@$b"
    [IO.File]::WriteAllText($b, (ConvertTo-Json -Compress @{ component = 'ak-stage-password'; password = $pw })); $r = (& curl.exe -s -L -c $j -b $j $ex -H 'Content-Type: application/json' --data-binary "@$b") -join ''
    Remove-Item $b, $j -Force -ErrorAction SilentlyContinue; return [string]($r | ConvertFrom-Json).component }
  Test-Condition 'bootstrap: the changed administrator password survives a restart (bootstrap values are first-start only)' ((& $pwCheck 'Changed-Admin-Pass-55z') -eq 'xak-flow-redirect' -and (& $pwCheck $adminPass) -ne 'xak-flow-redirect') ''

  # --- Secrets never leak ---------------------------------------------------------------------------------------------------
  $haystack = (@($ui.Bodies) -join "`n") + [IO.File]::ReadAllText((Join-Path $installPath 'config\identity.json'))
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $installPath 'logs') -File -Recurse -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $uiDir -File -ErrorAction SilentlyContinue)) {
    # The running manager keeps its output files open: read them with shared access.
    $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $haystack += (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Close() }
  }
  Test-Condition 'secrets: the Google client secret, the API token and the admin password appear in no response, state file or log' ($haystack -notmatch [regex]::Escape($googleSecret) -and $haystack -notmatch [regex]::Escape($bootToken) -and $haystack -notmatch [regex]::Escape($adminPass)) ''

  # --- Browser --------------------------------------------------------------------------------------------------------------
  if ($SkipBrowser) { Add-Result 'SKIP' 'browser' '-SkipBrowser' }
  elseif (-not (Get-EdgePath)) { Add-Result 'SKIP' 'browser' 'Microsoft Edge not found' }
  else {
    $cdp = Start-EdgeSession -WorkDir $work
    $base = "http://127.0.0.1:$($ui.Port)"
    Set-Viewport $cdp 1366 900
    Open-Page $cdp $ui.LaunchUrl
    $null = Wait-PageCondition $cdp "document.readyState === 'complete' && window.TPMApp && document.querySelector('main h1')" 30
    foreach ($lv in @('beginner', 'expert')) {
      Open-Page $cdp "$base/#identity?level=$lv"
      $ok = Wait-PageCondition $cdp "!!document.querySelector('#identity-google') && !!document.querySelector('.id-steps')" 60
      $text = [string](Invoke-PageScript $cdp 'document.body.innerText')
      Test-Condition "browser ($lv): Identity & Access page with progress, Google wizard and protected applications" ($ok -and $text -match 'Setup progress' -and $text -match [regex]::Escape("https://$authHost/source/oauth/callback/google/") -and $text -match 'Protected applications') ''
      Test-Condition "browser ($lv): no secret is shown" ($text -notmatch [regex]::Escape($googleSecret) -and $text -notmatch [regex]::Escape($bootToken) -and $text -notmatch [regex]::Escape($adminPass)) ''
      if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir "identity-$lv-1366.png") }
    }
    $raw = [string](Invoke-PageScript $cdp "(document.querySelector('details.tech pre') || {}).textContent || ''")
    Test-Condition 'browser (expert): raw state is shown without secrets' ($raw -match 'clientId' -and $raw -notmatch [regex]::Escape($googleSecret)) ''
    Set-Viewport $cdp 390 844 -Mobile
    Open-Page $cdp "$base/#identity?level=beginner"
    $null = Wait-PageCondition $cdp "!!document.querySelector('#identity-google')" 60
    $overflow = [bool](Invoke-PageScript $cdp 'document.documentElement.scrollWidth > window.innerWidth + 1')
    Test-Condition 'browser (390 px): no horizontal scrolling' (-not $overflow) ''
    if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'identity-beginner-390.png') }
    $errs = @($cdp.Errors | Where-Object { $_ -notmatch 'favicon' })
    Test-Condition 'browser: no script errors' ($errs.Count -eq 0) ($errs -join ' | ')
  }
} catch {
  $failed = $true
  Add-Result 'FAIL' 'identity live run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
} finally {
  if ($cdp) { Stop-EdgeSession $cdp }
  Stop-TestServer $ui
  if ($KeepOnFailure -and ($failed -or @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count)) {
    Write-Host "Kept for inspection: $work (stack $stack). Remove with: docker compose -p $akProject down -v; install.ps1 -Stop" -ForegroundColor Yellow
  } else {
    $null = Invoke-Docker rm -f $app
    if (Test-Path -LiteralPath (Join-Path $akFolder 'compose.yaml')) { $null = Invoke-Docker compose --project-directory $akFolder -f (Join-Path $akFolder 'compose.yaml') down -v --remove-orphans }
    $null = Invoke-Docker volume rm "${akProject}_database"
    if ($installed) { $null = Invoke-Ps (Join-Path $installPath 'install.ps1') @('-InstallPath', $installPath, '-Stop'); $null = Invoke-Docker rm -f "$stack-whoami" }
    $null = Invoke-Docker network rm $network
    $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
    $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
    $leftVols = @((Invoke-Docker volume ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
    Test-Condition 'teardown: no disposable containers, networks or volumes left' ($left.Count -eq 0 -and $leftNets.Count -eq 0 -and $leftVols.Count -eq 0) (($left + $leftNets + $leftVols) -join ', ')
    $after = Get-EngineSnapshot $stack
    $changed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) -or $after[$_] -ne $before[$_] })
    $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
    Test-Condition "other containers untouched ($($before.Count) checked: same IDs, start times, states)" ($changed.Count -eq 0 -and $added.Count -eq 0) ("changed: $($changed -join ', ') added: $($added -join ', ')")
    Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$failedTests = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failedTests.Count)
if ($failedTests.Count -gt 0) { exit 1 }
exit 0
