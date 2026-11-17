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
Import-Module (Join-Path $repo 'tests\TestResources.psm1') -Force
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
# Leftovers of earlier runs killed hard are swept first; this run is registered so its own are swept the same way.
foreach ($orphanLine in (Invoke-TestOrphanSweep)) { Write-Host "  [orphans] $orphanLine" -ForegroundColor DarkYellow }
Register-TestRun -Prefix $stack -Suite 'Test-IdentityLive'
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
  # authentik already installed on this PC (production) blocks a silent second installation; the test then installs a
  # deliberate, separate instance with its own project, folder, volumes and port (the existing one is never touched).
  $dup = @($plan.Data.checks | Where-Object { $_.label -eq 'Not already installed' -and $_.state -eq 'failed' })[0]
  if ($dup) { $plan = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = 'authentik'; project = $akProject; folder = $akFolder; localPort = $akPort; timezone = 'UTC'; inputs = @{ adminEmail = 'admin@idtest.example' }; startNow = $false; anotherInstance = $true; instanceLabel = 'Identity test' } }
  $cc = @($plan.Data.checks | Where-Object { $_.label -eq 'docker compose config' })[0]
  Test-Condition 'install: Compose project validated by docker compose config' ($plan.Status -eq 200 -and $cc -and $cc.state -eq 'ok') ($plan.Body)
  # Modular stack: the server and worker in compose.yaml, PostgreSQL in compose.database.yaml; check the whole set.
  $compose = (@($plan.Data.composeFiles | ForEach-Object { [string]$_.content }) -join "`n")
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

  # --- API token management: replace, rotate, refuse, preserve -------------------------------------------------------------
  # Real tokens of this authentik: the embedded outpost's own token (what a user can pick by mistake), admin tokens that
  # expire, get deleted or rotate. Nothing in authentik is changed by the manager; the test itself creates/deletes tokens.
  Import-Module (Join-Path $repo 'lib\SecretStore.psm1') -Force
  $adm = New-AuthentikConnection -BaseUrl "http://127.0.0.1:$akPort" -Token $bootToken
  $akadminPk = [int]@(Get-AuthentikList $adm '/core/users/?username=akadmin')[0].pk
  $outTok = @(Get-AuthentikList $adm '/core/tokens/?intent=api' | Where-Object { [string]$_.identifier -like 'ak-outpost-*' })[0]
  $outpostKey = [string](Invoke-AuthentikApi $adm GET "/core/tokens/$($outTok.identifier)/view_key/").key
  $newTok = { param([string]$Ident, [int]$Seconds = 0)
    $b = @{ identifier = $Ident; intent = 'api'; user = $akadminPk; description = 'tpx identity test'; expiring = [bool]$Seconds }
    if ($Seconds) { $b.expires = (Get-Date).ToUniversalTime().AddSeconds($Seconds).ToString('o') }
    $null = Invoke-AuthentikApi $adm POST '/core/tokens/' $b
    [string](Invoke-AuthentikApi $adm GET "/core/tokens/$Ident/view_key/").key }
  $settingsI = Get-StackSettings -InstallPath $installPath
  $secretBytes = { [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $installPath 'secrets\authentik_api.dpapi'))) }
  # The situation from the field: an earlier version saved the outpost's token. (Written the way the old version did.)
  Save-ProtectedSecret -Settings $settingsI -Name 'authentik_api' -Value $outpostKey -Label 'old version'
  $c0 = Invoke-WebUi $ui GET '/api/identity?deep=1'
  Test-Condition 'token mgmt: a saved outpost token is reported as not usable, with the reason (outpost) and the API step failed' ($c0.Data.credential.status -eq 'insufficient' -and $c0.Data.credential.message -match 'outpost' -and $c0.Data.credential.account -like 'ak-outpost-*' -and (Get-Step $c0.Data 'api').state -eq 'failed') ($c0.Data.credential | ConvertTo-Json -Compress)
  $bad1 = Invoke-WebUi $ui POST '/api/identity/token' @{ token = 'wrongwrongwrongwrongwrongwrong0123456789' }
  Test-Condition 'token mgmt: a wrong replacement is refused; the saved token is preserved and another attempt is possible' ($bad1.Status -eq 400 -and $bad1.Data.preserved -and $bad1.Data.candidate.status -eq 'rejected' -and (Invoke-WebUi $ui GET '/api/identity').Data.credential.account -like 'ak-outpost-*') ($bad1.Body)
  $before1 = & $secretBytes
  $rep1 = Invoke-WebUi $ui POST '/api/identity/token' @{ token = $bootToken }
  Test-Condition 'token mgmt: outpost token -> admin token: validated, replaced, errors cleared' ($rep1.Status -eq 200 -and $rep1.Data.replaced -and $rep1.Data.credential.status -eq 'valid' -and $rep1.Data.credential.account -eq 'akadmin' -and (& $secretBytes) -ne $before1) ($rep1.Body)
  Test-Condition 'token mgmt: after the replacement onboarding resumes at the next step (initial owner)' ($rep1.Data.next -eq 'owner' -and (Get-Step (Invoke-WebUi $ui GET '/api/identity').Data 'api').state -eq 'verified') "next=$($rep1.Data.next)"
  Test-Condition 'token mgmt: the outpost''s own token is untouched in authentik' (@(Get-AuthentikList $adm "/core/tokens/?identifier=$($outTok.identifier)").Count -eq 1 -and (Test-AuthentikCredential -BaseUrl "http://127.0.0.1:$akPort" -Token $outpostKey).Account -like 'ak-outpost-*') ''
  $bad2 = Invoke-WebUi $ui POST '/api/identity/token' @{ token = $outpostKey }
  $before2 = & $secretBytes
  Test-Condition 'token mgmt: replacing a working token with the outpost token is refused; the working token keeps working' ($bad2.Status -eq 400 -and $bad2.Data.candidate.status -eq 'insufficient' -and (Invoke-WebUi $ui POST '/api/identity/token/test' @{}).Data.ok -and (& $secretBytes) -eq $before2) ($bad2.Body)
  # Voluntary rotation of a healthy connection.
  $rotKey = & $newTok 'tpx-rotation' 0
  $rot = Invoke-WebUi $ui POST '/api/identity/token' @{ token = $rotKey }
  Test-Condition 'token mgmt: voluntary rotation of a healthy token' ($rot.Status -eq 200 -and $rot.Data.replaced -and $rot.Data.credential.rotatedAt -and $rot.Data.credential.status -eq 'valid' -and -not $rot.Data.credential.expiresAt) ($rot.Body)
  # Expiring token: the expiry date is read from authentik, a warning is shown, then it expires.
  # authentik gives every expiring API token the system's default token duration (it ignores a requested date), so
  # the disposable instance's default is shortened to 25 seconds for this token and restored right after.
  $prevDuration = [string](Invoke-AuthentikApi $adm GET '/admin/settings/').default_token_duration
  $null = Invoke-AuthentikApi $adm PATCH '/admin/settings/' @{ default_token_duration = 'seconds=25' }
  $expKey = & $newTok 'tpx-expiring' 25
  $null = Invoke-AuthentikApi $adm PATCH '/admin/settings/' @{ default_token_duration = $prevDuration }
  $exp = Invoke-WebUi $ui POST '/api/identity/token' @{ token = $expKey }
  Test-Condition 'token mgmt: an expiring token shows its expiry date and a warning' ($exp.Status -eq 200 -and $exp.Data.credential.expiresAt -and $exp.Data.credential.expiryWarning -match 'expires') ($exp.Data.credential | ConvertTo-Json -Compress)
  Start-Sleep -Seconds 35
  $t1 = Invoke-WebUi $ui POST '/api/identity/token/test' @{}
  Test-Condition 'token mgmt: Test connection reports the expired token (without asking for it)' ($t1.Status -eq 200 -and -not $t1.Data.ok -and $t1.Data.credential.status -eq 'expired') ($t1.Data.credential | ConvertTo-Json -Compress)
  $g1x = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'token mgmt: with an expired token the API step fails and nothing is attempted with it' ((Get-Step $g1x.Data 'api').state -eq 'failed' -and (Invoke-WebUi $ui POST '/api/identity/outpost/plan' @{}).Status -eq 409) ''
  $rep2 = Invoke-WebUi $ui POST '/api/identity/token' @{ token = $rotKey }
  Test-Condition 'token mgmt: expired token -> replacement' ($rep2.Status -eq 200 -and $rep2.Data.credential.status -eq 'valid' -and -not $rep2.Data.credential.expiryWarning) ($rep2.Body)
  # Revoked (deleted in authentik).
  $null = Invoke-AuthentikApi $adm DELETE '/core/tokens/tpx-rotation/'
  $t2 = Invoke-WebUi $ui POST '/api/identity/token/test' @{}
  Test-Condition 'token mgmt: a revoked token is reported as rejected (wrong, expired or revoked)' (-not $t2.Data.ok -and $t2.Data.credential.status -eq 'rejected' -and $t2.Data.credential.message -match 'revoked') ($t2.Data.credential | ConvertTo-Json -Compress)
  # The manager restarts (or the browser reloads): the failed state and the way out are still there.
  Stop-TestServer $ui
  $ui = Start-WebUiServer -Script (Join-Path $installPath 'webui.ps1') -InstallPath $installPath -WorkDir $uiDir
  $null = Connect-WebUi $ui
  $g2x = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'token mgmt: after a manager restart the revoked token is still reported and replaceable' ($g2x.Data.credential.status -eq 'rejected' -and $g2x.Data.credential.stored -and $g2x.Data.config.provider -eq 'authentik') ($g2x.Data.credential | ConvertTo-Json -Compress)
  $rep3 = Invoke-WebUi $ui POST '/api/identity/token' @{ fromBootstrap = $true }
  Test-Condition 'token mgmt: revoked token -> replacement (installation token); setup progress kept' ($rep3.Status -eq 200 -and $rep3.Data.credential.status -eq 'valid' -and (Invoke-WebUi $ui GET '/api/identity').Data.config.authentik.project -eq $akProject) ($rep3.Body)
  $logText = ''
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $installPath 'logs') -File -Recurse -ErrorAction SilentlyContinue) + @(Get-Item (Join-Path $installPath 'config\credentials.json'))) { $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); try { $logText += (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Close() } }
  Test-Condition 'token mgmt: no token value in any response, status file or log' (-not @(@($ui.Bodies) + $logText | Where-Object { $_ -match [regex]::Escape($outpostKey) -or $_ -match [regex]::Escape($rotKey) -or $_ -match [regex]::Escape($expKey) -or $_ -match [regex]::Escape($bootToken) }).Count) ''

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

  # --- Path A: local accounts only ----------------------------------------------------------------------------------------------
  $md = Invoke-WebUi $ui POST '/api/identity/mode' @{ mode = 'local' }
  Test-Condition 'local path: chosen without any Google step' ($md.Status -eq 200 -and (Get-Step (Invoke-WebUi $ui GET '/api/identity').Data 'google').state -eq 'skipped') ($md.Body)
  $lv0 = Invoke-WebUi $ui POST '/api/identity/owner/verify' @{}
  Test-Condition 'local path: verification needs a real sign-in started from the wizard (no manual completion)' ($lv0.Status -eq 409) ($lv0.Body)
  $null = Invoke-WebUi $ui POST '/api/identity/owner/local-start' @{}
  $lv1 = Invoke-WebUi $ui POST '/api/identity/owner/verify' @{}
  Test-Condition 'local path: not verified until the administrator actually signs in' ($lv1.Status -eq 200 -and -not $lv1.Data.ok -and @($lv1.Data.items | Where-Object { $_.id -eq 'login' -and -not $_.ok }).Count -eq 1) ($lv1.Body)
  $localSignIn = { param($user, $pw) $b = Join-Path $work 'ls.json'; $j = Join-Path $work 'ls.jar'
    $ex = "http://127.0.0.1:$akPort/api/v3/flows/executor/default-authentication-flow/?query=next%3D%252F"
    $null = & curl.exe -s -c $j -b $j -o NUL $ex
    [IO.File]::WriteAllText($b, (ConvertTo-Json -Compress @{ component = 'ak-stage-identification'; uid_field = $user })); $null = & curl.exe -s -L -c $j -b $j $ex -H 'Content-Type: application/json' --data-binary "@$b"
    [IO.File]::WriteAllText($b, (ConvertTo-Json -Compress @{ component = 'ak-stage-password'; password = $pw })); $r = (& curl.exe -s -L -c $j -b $j $ex -H 'Content-Type: application/json' --data-binary "@$b") -join ''
    Remove-Item $b, $j -Force -ErrorAction SilentlyContinue; return [string]($r | ConvertFrom-Json).component }
  Start-Sleep -Seconds 6
  $null = & $localSignIn 'akadmin' $adminPass
  $lv2 = Invoke-WebUi $ui POST '/api/identity/owner/verify' @{}
  Test-Condition 'local path: after signing in, the administrator is verified (Internal, in DTC owners, signed in)' ($lv2.Data.ok -and @($lv2.Data.items | Where-Object { -not $_.ok }).Count -eq 0 -and (Get-AuthentikGroup $conn 'DTC owners')) ($lv2.Body)
  $wz = Invoke-WebUi $ui POST '/api/identity/wizard' @{ step = 'apps' }
  Stop-TestServer $ui
  $ui = Start-WebUiServer -Script (Join-Path $installPath 'webui.ps1') -InstallPath $installPath -WorkDir $uiDir
  $null = Connect-WebUi $ui
  $gL = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'resume: after a manager restart the wizard position, path and verified owner are kept' ($wz.Status -eq 200 -and $gL.Data.config.wizardStep -eq 'apps' -and $gL.Data.config.authMode -eq 'local' -and (Get-Step $gL.Data 'owner').state -eq 'verified') ($gL.Data.config | ConvertTo-Json -Depth 4 -Compress)
  $bindsLocal = @(Get-AuthentikList $conn '/policies/bindings/').Count; $usersLocal = @(Get-AuthentikList $conn '/core/users/').Count

  # --- Path B added later: Google (synthetic client file) -----------------------------------------------------------------------
  $null = Invoke-WebUi $ui POST '/api/identity/mode' @{ mode = 'google' }
  $gG = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'add Google later: the local verification is kept; the owner still has to sign in with Google' ($gG.Data.config.authentik.owner.verifiedAt -and (Get-Step $gG.Data 'owner').state -ne 'verified' -and (Get-Step $gG.Data 'google').state -eq 'awaiting-user') (($gG.Data.model.steps | ForEach-Object { "$($_.id)=$($_.state)" }) -join ', ')
  $redir = "https://$authHost/source/oauth/callback/google/"
  $clientFile = { param($id, $secret, $uris) ConvertTo-Json -Depth 5 -Compress @{ web = [ordered]@{ client_id = $id; project_id = 'dtc-test'; auth_uri = 'https://accounts.google.com/o/oauth2/auth'; token_uri = 'https://oauth2.googleapis.com/token'; client_secret = $secret; redirect_uris = @($uris) } } }

  $ownerEmail = 'owner@idtest.example'
  $gp0 = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientId = $googleId; clientSecret = $googleSecret }
  Test-Condition 'owner: Google sign-in is not set up before the initial owner is known' ($gp0.Status -eq 409 -and $gp0.Data.error -match 'owner') ($gp0.Body)
  $o1 = Invoke-WebUi $ui POST '/api/identity/owner' @{ email = 'Owner@IDTest.example'; makeAdmin = $true }
  Test-Condition 'owner: asked once, stored normalized (no other people are entered in the manager)' ($o1.Status -eq 200 -and $o1.Data.owner.email -eq $ownerEmail) ($o1.Body)
  $sv = Invoke-WebUi $ui POST '/api/identity/google/save' @{ clientId = $googleId }
  Test-Condition 'google: draft saved without any secret (resumable)' ($sv.Status -eq 200 -and [IO.File]::ReadAllText((Join-Path $installPath 'config\identity.json')) -match [regex]::Escape($googleId)) ($sv.Body)
  # Restart the manager (browser refresh / reboot): the draft and progress survive.
  Stop-TestServer $ui
  $ui = Start-WebUiServer -Script (Join-Path $installPath 'webui.ps1') -InstallPath $installPath -WorkDir $uiDir
  $null = Connect-WebUi $ui
  $g3 = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'resume: after a manager restart the owner, Google draft, hostname and progress are still there' ($g3.Data.config.authentik.google.clientId -eq $googleId -and $g3.Data.config.authentik.owner.email -eq $ownerEmail -and $g3.Data.config.authentik.hostname -eq $authHost -and $g3.Data.progress.step -eq 'google' -and (Get-Step $g3.Data 'google').state -eq 'awaiting-user' -and (Get-Step $g3.Data 'owner').state -eq 'configured') ($g3.Data.progress | ConvertTo-Json -Compress)
  Test-Condition 'google: wizard values (redirect URI, Web application, minimal scopes)' ($g3.Data.googleValues.RedirectUri -eq "https://$authHost/source/oauth/callback/google/" -and $g3.Data.googleValues.ClientType -eq 'Web application' -and (@($g3.Data.googleValues.ScopeNames) -join ',') -eq 'openid,email,profile') ($g3.Data.googleValues | ConvertTo-Json -Compress)
  $badId = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientId = 'not-a-client-id'; clientSecret = $googleSecret }
  Test-Condition 'google: an invalid client ID is refused before authentik is touched' ($badId.Status -eq 400) ($badId.Body)
  $insp = Invoke-WebUi $ui POST '/api/identity/google/inspect' @{ clientJson = (& $clientFile $googleId $googleSecret "https://$authHost/source/oauth/callback/google") }
  Test-Condition 'json import: a wrong redirect URI in the downloaded file is explained (exact URI to add in Google Cloud)' ($insp.Status -eq 200 -and -not $insp.Data.ok -and (@($insp.Data.errors) -join ' ') -match [regex]::Escape($redir) -and $insp.Data.secretPresent -and $insp.Body -notmatch [regex]::Escape($googleSecret)) ($insp.Body)
  $badJson = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientJson = '{ not json' }
  Test-Condition 'json import: an invalid file is refused before authentik is touched' ($badJson.Status -eq 400 -and @(Get-AuthentikList $conn '/sources/oauth/?slug=google').Count -eq 0) ($badJson.Body)
  $insp2 = Invoke-WebUi $ui POST '/api/identity/google/inspect' @{ clientJson = (& $clientFile $googleId $googleSecret $redir) }
  Test-Condition 'json import: the correct file is accepted (client ID shown, secret never returned)' ($insp2.Data.ok -and $insp2.Data.clientId -eq $googleId -and $insp2.Body -notmatch [regex]::Escape($googleSecret)) ($insp2.Body)
  $gp = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientJson = (& $clientFile $googleId $googleSecret $redir) }
  $created = @($gp.Data.actions | Where-Object { $_.kind -eq 'create' } | ForEach-Object { $_.object })
  Test-Condition 'google: preview lists owner-only enrollment (Internal write stage), source and login button; the owner group from the local path is reused' ($gp.Status -eq 200 -and $created -notcontains 'group' -and $created -contains 'stage' -and $created -contains 'flow' -and $created -contains 'policy' -and $created -contains 'Google source' -and @(Get-AuthentikList $conn '/sources/oauth/?slug=google').Count -eq 0) (($gp.Data.actions | ForEach-Object { "$($_.kind):$($_.object)" }) -join ', ')
  $ga = Invoke-WebUi $ui POST '/api/identity/google/apply' @{ planId = $gp.Data.planId; confirm = $true }
  $src = @(Get-AuthentikList $conn '/sources/oauth/?slug=google')[0]
  Test-Condition 'google: source created through the API (type google, client ID, identifier matching, owner-only enrollment flow)' ($ga.Status -eq 200 -and $ga.Data.ok -and $src -and $src.provider_type -eq 'google' -and $src.consumer_key -eq $googleId -and $src.user_matching_mode -eq 'identifier' -and $src.enrollment_flow) ($ga.Body)
  Test-Condition 'google: authentik redirects to Google with the right client ID and redirect URI' ($ga.Data.redirect.ok -and $ga.Data.redirect.redirectUri -eq "https://$authHost/source/oauth/callback/google/") ($ga.Data.redirect | ConvertTo-Json -Compress)
  $ov = Get-AuthentikOverview $conn
  Test-Condition 'google: the login page shows the Google button' ($ov.LoginStage.Sources -contains [string]$src.pk) ''
  $owners = Get-AuthentikGroup $conn 'DTC owners'
  $flowB = @(Get-AuthentikList $conn "/flows/bindings/?target=$((Invoke-AuthentikApi $conn GET '/flows/instances/dm-google-enrollment/').pk)&ordering=order")
  $writeB = @($flowB | Where-Object { [string]$_.stage_obj.component -like '*user-write*' })[0]
  $writeStage = Invoke-AuthentikApi $conn GET "/stages/user_write/$($writeB.stage)/"
  Test-Condition 'internal owner: Google enrollment writes Internal users (fixes "Interface can only be accessed by internal users")' ($writeStage.name -eq 'dm-google-owner-write' -and $writeStage.user_type -eq 'internal' -and -not $writeStage.create_users_group) ($writeStage | ConvertTo-Json -Compress)
  Test-Condition 'add Google later: no local account, binding or rule was changed' (@(Get-AuthentikList $conn '/policies/bindings/').Count -eq $bindsLocal + 1 -and @(Get-AuthentikList $conn '/core/users/').Count -eq $usersLocal) "bindings $bindsLocal -> $(@(Get-AuthentikList $conn '/policies/bindings/').Count)"
  # Replacing an existing Google connection needs an explicit choice.
  $otherId = '210987654321-tpxreplacementclient.apps.googleusercontent.com'
  $rp1 = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientJson = (& $clientFile $otherId $googleSecret $redir) }
  $rp2 = Invoke-WebUi $ui POST '/api/identity/google/plan' @{ clientJson = (& $clientFile $otherId $googleSecret $redir); replace = $true }
  Test-Condition 'replace guard: an existing Google client is not overwritten without "Replace"' ($rp1.Status -eq 409 -and $rp1.Data.needsReplace -and $rp2.Status -eq 200 -and @($rp2.Data.actions | Where-Object { $_.object -eq 'Google source' -and $_.kind -eq 'update' }).Count -eq 1 -and (@(Get-AuthentikList $conn '/sources/oauth/?slug=google')[0]).consumer_key -eq $googleId) ($rp1.Body)
  # Repair of a flow made by an earlier version (shared default write stage = External users).
  $defWriteB = @(Get-AuthentikList $conn "/flows/bindings/?target=$((Invoke-AuthentikApi $conn GET '/flows/instances/default-source-enrollment/').pk)" | Where-Object { [string]$_.stage_obj.component -like '*user-write*' })[0]
  $null = Invoke-AuthentikApi $conn PATCH "/flows/bindings/$($writeB.pk)/" @{ stage = $defWriteB.stage }
  $rpr = Invoke-WebUi $ui POST '/api/identity/google/plan' @{}
  $rpa = Invoke-WebUi $ui POST '/api/identity/google/apply' @{ planId = $rpr.Data.planId; confirm = $true }
  Test-Condition 'repair: a flow from an earlier version (External users) is repaired during setup' (@($rpr.Data.actions | Where-Object { $_.summary -match 'Repair' }).Count -eq 1 -and $rpa.Data.ok -and [string](Invoke-AuthentikApi $conn GET "/flows/bindings/$($writeB.pk)/").stage -eq [string]$writeStage.pk) (($rpr.Data.actions | ForEach-Object { "$($_.kind):$($_.summary)" }) -join '; ')
  Test-Condition 'owner-only rule: group "DTC owners" exists with akadmin (local recovery account) as member' ($owners -and @($owners.users | ForEach-Object { [int]$_ }) -contains $akadminPk) ''
  # The enrollment policy, asked through authentik's own policy test with the context a Google sign-in provides.
  $pol = @(Get-AuthentikList $conn '/policies/expression/?name=dm-google-initial-owner')[0]
  $ptest = { param($email, $verified) [bool](Invoke-AuthentikApi $conn POST "/policies/all/$($pol.pk)/test/" @{ user = $akadminPk; context = @{ oauth_userinfo = @{ email = $email; verified_email = $verified } } }).passing }
  Test-Condition 'owner-only enrollment: authentik admits the owner''s verified Google address' (& $ptest 'Owner@idtest.example' $true) ''
  Test-Condition 'owner-only enrollment: another Google account, or the owner''s address unverified, is refused' (-not (& $ptest 'alice@idtest.example' $true) -and -not (& $ptest $ownerEmail $false)) ''
  $gp2 = Invoke-WebUi $ui POST '/api/identity/google/plan' @{}
  Test-Condition 'google: running the wizard again changes nothing (no duplicate source, group, flow or policy; secret kept)' (@($gp2.Data.actions | Where-Object { $_.kind -ne 'none' }).Count -eq 0 -and @(Get-AuthentikList $conn '/sources/oauth/').Count -eq 1) (($gp2.Data.actions | ForEach-Object { "$($_.kind):$($_.summary)" }) -join '; ')
  $g4 = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'google: configured, NOT verified; the owner''s sign-in is awaited' ((Get-Step $g4.Data 'google').state -eq 'configured' -and -not $g4.Data.google.verifiedAt -and (Get-Step $g4.Data 'owner').state -eq 'awaiting-user') (($g4.Data.model.steps | ForEach-Object { "$($_.id)=$($_.state)" }) -join ', ')
  $ov0 = Invoke-WebUi $ui POST '/api/identity/owner/verify' @{}
  Test-Condition 'owner: nothing is verified before the owner has signed in with Google' ($ov0.Status -eq 200 -and -not $ov0.Data.ok -and $ov0.Data.message -match 'Nobody has signed in') ($ov0.Body)
  # SIMULATED owner sign-in: a real one needs Google. The account and its Google connection are created the way authentik's
  # callback would (ak shell, inside the disposable worker); nothing here talks to Google.
  $mk = { param($u, $e, $p) $x = Invoke-AuthentikApi $conn POST '/core/users/' @{ username = $u; name = $u; email = $e; is_active = $true; path = 'users' }; $null = Invoke-AuthentikApi $conn POST "/core/users/$($x.pk)/set_password/" @{ password = $p }; $x }
  $ownerUser = & $mk 'owner' $ownerEmail 'Owner-Live-Test-55q'
  $null = Invoke-AuthentikApi $conn PATCH "/core/users/$($ownerUser.pk)/" @{ type = 'external' }
  $sim = Invoke-Docker exec "$akProject-worker" ak shell -c "from authentik.sources.oauth.models import OAuthSource, UserOAuthSourceConnection; from authentik.core.models import User; UserOAuthSourceConnection.objects.create(user=User.objects.get(username='owner'), source=OAuthSource.objects.get(slug='google'), identifier='109876543210')"
  Test-Condition 'owner (simulated Google sign-in): fixture created inside the disposable authentik' ($sim.ExitCode -eq 0) (($sim.Output | Select-Object -Last 3) -join ' ')
  Start-Sleep -Seconds 2
  $null = & $localSignIn 'owner' 'Owner-Live-Test-55q'
  $ovx = Invoke-WebUi $ui POST '/api/identity/owner/verify' @{}
  Test-Condition 'internal owner: an External owner account is detected and NOT changed without an explicit repair' ($ovx.Status -eq 200 -and -not $ovx.Data.ok -and $ovx.Data.needsRepair -and @($ovx.Data.items | Where-Object { $_.id -eq 'internal' -and -not $_.ok }).Count -eq 1 -and (Invoke-AuthentikApi $conn GET "/core/users/$($ownerUser.pk)/").type -eq 'external') ($ovx.Body)
  $ov1 = Invoke-WebUi $ui POST '/api/identity/owner/verify' @{ repair = $true }
  $ownerNow = Invoke-AuthentikApi $conn GET "/core/users/$($ownerUser.pk)/"
  Test-Condition 'owner: repaired and verified: Internal, in "DTC owners" and the authentik administrators (as chosen), signed in' ($ov1.Data.ok -and $ov1.Data.username -eq 'owner' -and $ownerNow.type -eq 'internal' -and @($ownerNow.groups_obj | ForEach-Object { $_.name }) -contains 'DTC owners' -and @($ownerNow.groups_obj | ForEach-Object { $_.name }) -contains 'authentik Admins' -and @($ov1.Data.items | Where-Object { -not $_.ok }).Count -eq 0) ($ov1.Body)
  Test-Condition 'recovery: akadmin keeps working with its password after Google was added' ((& $localSignIn 'akadmin' $adminPass) -eq 'xak-flow-redirect' -and (Invoke-AuthentikApi $conn GET "/core/users/$akadminPk/").is_active) ''
  $null = Invoke-Docker exec "$akProject-worker" ak shell -c "from authentik.sources.oauth.models import UserOAuthSourceConnection; UserOAuthSourceConnection.objects.filter(identifier='109876543210').update(identifier='555000111222')"
  $ovs = Invoke-WebUi $ui POST '/api/identity/owner/verify' @{}
  Test-Condition 'subject pinning: a different Google identity with the owner''s address is refused' ($ovs.Status -eq 409 -and $ovs.Data.error -match 'different Google identity') ($ovs.Body)
  $null = Invoke-Docker exec "$akProject-worker" ak shell -c "from authentik.sources.oauth.models import UserOAuthSourceConnection; UserOAuthSourceConnection.objects.filter(identifier='555000111222').update(identifier='109876543210')"

  # --- Google-first sign-in page (separate flow; the default flow stays the recovery route) ------------------------------------
  $defFlowBefore = @(Get-AuthentikList $conn "/flows/bindings/?target=$((Invoke-AuthentikApi $conn GET '/flows/instances/default-authentication-flow/').pk)" | ForEach-Object { "$($_.stage):$($_.order)" } | Sort-Object) -join ','
  $brandBefore = @(Get-AuthentikList $conn '/core/brands/' | Where-Object { $_.default })[0]
  $lpp = Invoke-WebUi $ui POST '/api/identity/loginpage/plan' @{}
  $lpa = Invoke-WebUi $ui POST '/api/identity/loginpage/apply' @{ planId = $lpp.Data.planId; confirm = $true }
  $brandNow = @(Get-AuthentikList $conn '/core/brands/' | Where-Object { $_.default })[0]
  $dmFlow = Invoke-AuthentikApi $conn GET '/flows/instances/dm-authentication/'
  $dmIdent = @(Get-AuthentikList $conn '/stages/identification/?name=dm-identification')[0]
  Test-Condition 'sign-in page: Google first (promoted source with label), email/password below, domain title, used by the brand' ($lpa.Data.ok -and [string]$brandNow.flow_authentication -eq [string]$dmFlow.pk -and $brandNow.branding_title -eq 'Sign in to idtest.example' -and @($dmIdent.sources) -contains [string]$src.pk -and $dmIdent.show_source_labels -and @($dmIdent.user_fields).Count -ge 1) ($lpp.Body)
  $defFlowAfter = @(Get-AuthentikList $conn "/flows/bindings/?target=$((Invoke-AuthentikApi $conn GET '/flows/instances/default-authentication-flow/').pk)" | ForEach-Object { "$($_.stage):$($_.order)" } | Sort-Object) -join ','
  Test-Condition 'sign-in page: the default flow is untouched and still signs akadmin in (local recovery route)' ($defFlowAfter -eq $defFlowBefore -and (& $localSignIn 'akadmin' $adminPass) -eq 'xak-flow-redirect') "$defFlowBefore -> $defFlowAfter"
  $lpr = Invoke-WebUi $ui POST '/api/identity/loginpage/restore' @{ confirm = $true }
  $brandRest = @(Get-AuthentikList $conn '/core/brands/' | Where-Object { $_.default })[0]
  Test-Condition 'sign-in page: Restore brings back the previous flow and title' ($lpr.Data.ok -and [string]$brandRest.flow_authentication -eq [string]$brandBefore.flow_authentication -and $brandRest.branding_title -eq $brandBefore.branding_title) ''
  $lpp2 = Invoke-WebUi $ui POST '/api/identity/loginpage/plan' @{}
  $null = Invoke-WebUi $ui POST '/api/identity/loginpage/apply' @{ planId = $lpp2.Data.planId; confirm = $true }
  Test-Condition 'sign-in page: applying again reuses the flow and stage (no duplicates)' (@($lpp2.Data.actions | Where-Object { $_.kind -eq 'create' }).Count -eq 0 -and @(Get-AuthentikList $conn '/flows/instances/?slug=dm-authentication').Count -eq 1) ''
  $o2 = Invoke-WebUi $ui POST '/api/identity/owner' @{ email = 'someone@else.example' }
  Test-Condition 'owner: cannot be changed in the manager once verified with Google (people are managed in authentik)' ($o2.Status -eq 409) ($o2.Body)
  $g4b = Invoke-WebUi $ui GET '/api/identity'
  Test-Condition 'model: owner and Google verified from the owner''s sign-in; next step: protect applications' ((Get-Step $g4b.Data 'owner').state -eq 'verified' -and (Get-Step $g4b.Data 'google').state -eq 'verified' -and @($g4b.Data.model.next)[0] -eq 'apps') (($g4b.Data.model.steps | ForEach-Object { "$($_.id)=$($_.state)" }) -join ', ')
  Test-Condition 'manager keeps no user lists: identity.json has the owner address only' (([IO.File]::ReadAllText((Join-Path $installPath 'config\identity.json'))) -notmatch 'alice|emails|domains|groups') ''

  # --- Protect selected applications ---------------------------------------------------------------------------------------
  $app2 = "$stack-echo2"; $appHost2 = 'echo2.idtest.example'
  $r0 = Invoke-Docker run -d --name $app --network $network --pull missing $whoami
  $r0b = Invoke-Docker run -d --name $app2 --network $network --pull missing $whoami
  $add = Invoke-WebUiChange $ui @{ op = 'add'; service = @{ name = 'echo'; displayName = 'Echo test'; hostnames = @($appHost); target = @{ type = 'docker'; host = $app; port = 80 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
  $add2 = Invoke-WebUiChange $ui @{ op = 'add'; service = @{ name = 'echo2'; displayName = 'Echo two'; hostnames = @($appHost2); target = @{ type = 'docker'; host = $app2; port = 80 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
  Test-Condition 'apps: two disposable whoami applications published through Traefik (no sign-in yet)' ($r0.ExitCode -eq 0 -and $r0b.ExitCode -eq 0 -and $add.Apply.Data.ok -and $add2.Apply.Data.ok -and (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost).State -eq 'open') ($add.Apply.Body)
  $self = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('authentik') }
  Test-Condition 'protect: the authentik sign-in page itself cannot be protected (loop guard)' ($self.Status -eq 400) ($self.Body)
  $withEmails = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('echo'); emails = @('alice@idtest.example') }
  Test-Condition 'protect: emails, groups or domains are not accepted (access is managed in authentik)' ($withEmails.Status -eq 400 -and $withEmails.Data.error -match 'managed in authentik') ($withEmails.Body)
  # echo2 already exists in authentik with its own rule (alice): that rule must be kept, not replaced by owner-only.
  $alice = & $mk 'alice' 'alice@idtest.example' 'Alice-Live-Test-91x'
  $mallory = & $mk 'mallory' 'mallory@other.example' 'Mallory-Live-Test-77y'
  $pre = Invoke-AuthentikApi $conn POST '/core/applications/' @{ name = 'Echo two (made in authentik)'; slug = 'dm-echo2' }
  $null = Invoke-AuthentikApi $conn POST '/policies/bindings/' @{ user = [int]$alice.pk; target = [string]$pre.pbm_uuid; order = 0; enabled = $true; negate = $false; timeout = 30 }
  $pp = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('echo', 'echo2') }
  $i1 = @($pp.Data.items | Where-Object { $_.service -eq 'echo' })[0]; $i2 = @($pp.Data.items | Where-Object { $_.service -eq 'echo2' })[0]
  $diff = (@($i1.traefik.traefik.changes | ForEach-Object { $_.diff }) | ForEach-Object { $_ }) -join "`n"
  Test-Condition 'protect: one preview for the selected applications, with the ForwardAuth route diff' ($pp.Status -eq 200 -and $pp.Data.canApply -and @($pp.Data.items).Count -eq 2 -and $diff -match 'forwardAuth' -and $diff -match 'svc-echo-outpost' -and $diff -match "address: http://$akProject-server:9000/outpost.goauthentik.io/auth/traefik") ($pp.Body.Substring(0, [Math]::Min(600, $pp.Body.Length)))
  Test-Condition 'protect: a new application gets the owner-only rule; one with its own authentik rule keeps it' (@($i1.authentik | Where-Object { $_.object -eq 'access' -and $_.kind -eq 'create' }).Count -eq 1 -and @($i2.authentik | Where-Object { $_.object -eq 'access' -and $_.kind -eq 'none' }).Count -eq 1 -and @($i2.authentik | Where-Object { $_.object -eq 'application' -and $_.kind -eq 'create' }).Count -eq 0) (($i2.authentik | ForEach-Object { "$($_.kind):$($_.object)" }) -join ', ')
  $pa = Invoke-WebUi $ui POST '/api/identity/protect/apply' @{ planId = $pp.Data.planId; confirm = $true }
  Test-Condition 'protect: both applied and declared protected only after ForwardAuth was verified' ($pa.Status -eq 200 -and $pa.Data.ok -and @($pa.Data.results | Where-Object { $_.ok -and $_.challenge.State -eq 'auth' }).Count -eq 2) ($pa.Body)
  Test-Condition 'protect: after protecting several at once every selected route still has its ForwardAuth (no later plan undoes an earlier one)' ([IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo.yml')) -match 'svc-echo-authentik' -and [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo2.yml')) -match 'svc-echo2-authentik' -and (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost).State -eq 'auth') ''
  $protectBackup = [string](@($pa.Data.results | Where-Object { $_.service -eq 'echo' })[0].traefik.backup)
  $edit = Invoke-WebUiChange $ui @{ op = 'update'; name = 'echo'; service = @{ name = 'echo'; displayName = 'Echo (renamed)'; hostnames = @($appHost); target = @{ type = 'docker'; host = $app; port = 80 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
  Test-Condition 'services: editing a protected service without the sign-in field keeps its protection' ($edit.Apply.Data.ok -and [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo.yml')) -match 'svc-echo-authentik') ($edit.Apply.Body)

  # Sign-ins through the real outpost. The test reaches Traefik on a local port over http, so the provider and outpost
  # addresses are switched to that address for this part (production uses https://<host> without a port).
  $prov = @(Get-AuthentikList $conn '/providers/proxy/?name=dm-echo' | Where-Object { $_.name -eq 'dm-echo' })[0]; $prov2 = @(Get-AuthentikList $conn '/providers/proxy/?name=dm-echo2' | Where-Object { $_.name -eq 'dm-echo2' })[0]
  $null = Invoke-AuthentikApi $conn PATCH "/providers/proxy/$($prov.pk)/" @{ mode = 'forward_single'; external_host = "http://${appHost}:$httpPort" }
  $null = Invoke-AuthentikApi $conn PATCH "/providers/proxy/$($prov2.pk)/" @{ mode = 'forward_single'; external_host = "http://${appHost2}:$httpPort" }
  $null = Sync-AuthentikOutpost -Conn $conn -PublicUrl "http://${authHost}:$httpPort"
  # This test publishes the sign-in page as http://<auth host>:<port>; record that as the public address, so protecting
  # an application keeps (and, if needed, restores) the outpost on it.
  $idPath = Join-Path $installPath 'config\identity.json'
  $idj = [IO.File]::ReadAllText($idPath) | ConvertFrom-Json; $idj.authentik.publicUrl = "http://${authHost}:$httpPort"
  [IO.File]::WriteAllText($idPath, (ConvertTo-Json -InputObject $idj -Depth 10))
  # Wait until the outpost has reloaded the test addresses (it refreshes a few seconds after a change).
  $null = Wait-Until { @($appHost, $appHost2 | Where-Object { $x = Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $_ -HostPort $httpPort -AuthHostname $authHost; $x.State -eq 'auth' -and $x.Location -match "^http://${authHost}:$httpPort/" }).Count -eq 2 } 90 2000
  $anon = Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -HostPort $httpPort -AuthHostname $authHost
  Test-Condition 'forwardauth: anonymous visitors are sent to the authentik sign-in (no loop)' ($anon.State -eq 'auth' -and $anon.Location -match "^http://${authHost}:$httpPort/") ($anon | ConvertTo-Json -Compress)

  # --- Regression (Notflix): the outpost sends browsers to a local address ---------------------------------------------------
  # ForwardAuth keeps working (Traefik reaches authentik internally), but the sign-in redirect only works on this PC. The
  # probe, the routing view and the next protection must catch it; protecting again restores the public address.
  $bindsBefore = @(Get-AuthentikList $conn '/policies/bindings/').Count
  $ovm = Get-AuthentikOverview $conn; $cfgm = $ovm.Outpost.Config; $cfgm.authentik_host = "http://127.0.0.1:$akPort/"
  $null = Invoke-AuthentikApi $conn PATCH "/outposts/instances/$($ovm.Outpost.Pk)/" @{ config = $cfgm }
  $null = Wait-Until { (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -HostPort $httpPort -AuthHostname $authHost).State -eq 'misrouted' } 90 2000
  $mis = Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -HostPort $httpPort -AuthHostname $authHost
  Test-Condition 'misroute: a sign-in redirect to 127.0.0.1 is reported as misrouted, never as protected' ($mis.State -eq 'misrouted' -and $mis.Location -match '^http://127\.0\.0\.1:' -and $mis.Location -notmatch 'state=ey') ($mis | ConvertTo-Json -Compress)
  $rv = Invoke-WebUi $ui GET '/api/routing?service=echo&probe=1'
  $rvStage = { param($id) @($rv.Data.model.stages | Where-Object { $_.id -eq $id })[0] }
  Test-Condition 'routing view: the browser redirect is the first problem, ForwardAuth itself verified, internal address kept internal' ($rv.Status -eq 200 -and $rv.Data.model.firstProblem.id -eq 'redirect' -and (& $rvStage 'forwardauth').state -eq 'verified' -and (& $rvStage 'redirect').detail.fix -match [regex]::Escape("http://${authHost}:$httpPort/") -and @((& $rvStage 'forwardauth').endpoints | Where-Object { $_.audience -eq 'internal' -and $_.value -match "$akProject-server:9000" }).Count -eq 1) ($rv.Body.Substring(0, [Math]::Min(600, $rv.Body.Length)))
  Test-Condition 'routing view: no state token, cookie or API token in the response' ($rv.Body -notmatch 'state=ey' -and $rv.Body -notmatch '(?i)set-cookie|authentik_proxy' -and $rv.Body -notmatch [regex]::Escape($bootToken)) ''
  $fx = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('echo') }
  Test-Condition 'protect: the preview includes sending browsers to the public sign-in address again' ($fx.Status -eq 200 -and @($fx.Data.items[0].authentik | Where-Object { $_.object -eq 'outpost' -and $_.kind -eq 'update' -and $_.summary -match 'send browsers to' }).Count -eq 1) (($fx.Data.items[0].authentik | ForEach-Object { "$($_.kind):$($_.summary)" }) -join '; ')
  $fa = Invoke-WebUi $ui POST '/api/identity/protect/apply' @{ planId = $fx.Data.planId; confirm = $true }
  $null = Wait-Until { (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -HostPort $httpPort -AuthHostname $authHost).State -eq 'auth' } 90 2000
  $fixed = Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -HostPort $httpPort -AuthHostname $authHost
  Test-Condition 'protect: applying restores the public sign-in redirect, the return address and every access rule' ($fa.Data.ok -and $fixed.State -eq 'auth' -and $fixed.Location -match "^http://${authHost}:$httpPort/" -and $fixed.Location -match [regex]::Escape("redirect_uri=http://${appHost}:$httpPort/outpost.goauthentik.io/callback") -and @(Get-AuthentikList $conn '/policies/bindings/').Count -eq $bindsBefore) ($fixed | ConvertTo-Json -Compress)
  $so = Invoke-SignIn $httpPort $authHost $appHost 'owner' 'Owner-Live-Test-55q' $work
  Test-Condition 'owner-only: the owner reaches the newly protected application (identity headers passed)' ($so.Login -eq 'xak-flow-redirect' -and $so.ReachedApp -and $so.Body -match 'X-Authentik-Username: owner') "$($so.Status) $($so.Url)"
  $sa = Invoke-SignIn $httpPort $authHost $appHost 'alice' 'Alice-Live-Test-91x' $work
  Test-Condition 'owner-only: any other signed-in user is refused and never reaches it' ($sa.Login -eq 'xak-flow-redirect' -and -not $sa.ReachedApp -and $sa.Body -match 'Permission denied') "$($sa.Status) $($sa.Url)"
  $sa2 = Invoke-SignIn $httpPort $authHost $appHost2 'alice' 'Alice-Live-Test-91x' $work
  $sm2 = Invoke-SignIn $httpPort $authHost $appHost2 'mallory' 'Mallory-Live-Test-77y' $work
  $why = ([regex]::Match([string]$sa2.Body, '(?s)<title>[^<]*</title>|"error_message": *"[^"]*"|Permission denied[^<]{0,200}')).Value
  $b2 = @(Get-AuthentikList $conn "/policies/bindings/?target=$((Invoke-AuthentikApi $conn GET '/core/applications/dm-echo2/').pbm_uuid)" | ForEach-Object { "user=$($_.user) group=$($_.group) policy=$($_.policy) enabled=$($_.enabled)" }) -join '; '
  Test-Condition 'existing authentik rule respected: alice reaches echo2 (her rule), mallory does not' ($sa2.ReachedApp -and -not $sm2.ReachedApp) "alice $($sa2.Status) $why / bindings: $b2 / alice pk $($alice.pk) / mallory $($sm2.Status)"
  $sw = Invoke-SignIn $httpPort $authHost $appHost 'owner' 'wrong-password-123' $work
  Test-Condition 'authorization: a wrong password never reaches the application' (-not $sw.ReachedApp) "$($sw.Status) $($sw.Url)"
  # Access changes made in authentik work immediately, without the manager and without touching Traefik files.
  $filesBefore = @(Get-ChildItem -LiteralPath (Join-Path $installPath 'traefik\dynamic') -File | ForEach-Object { "$($_.Name)=$(Get-FileSha256 $_.FullName)" }) -join ';'
  $regBefore = Get-FileSha256 (Join-Path $installPath 'config\services.json')
  $null = Invoke-AuthentikApi $conn POST "/core/groups/$($owners.pk)/add_user/" @{ pk = [int]$mallory.pk }
  $sg = Invoke-SignIn $httpPort $authHost $appHost 'mallory' 'Mallory-Live-Test-77y' $work
  $filesAfter = @(Get-ChildItem -LiteralPath (Join-Path $installPath 'traefik\dynamic') -File | ForEach-Object { "$($_.Name)=$(Get-FileSha256 $_.FullName)" }) -join ';'
  Test-Condition 'authentik is the authority: adding a user to "DTC owners" in authentik grants access, no manager or Traefik change' ($sg.ReachedApp -and $filesAfter -eq $filesBefore -and (Get-FileSha256 (Join-Path $installPath 'config\services.json')) -eq $regBefore) "$($sg.Status) $($sg.Url)"
  # The manager never overwrites authentik-side access during refreshes, re-runs or unrelated routing changes.
  $echoApp = Invoke-AuthentikApi $conn GET '/core/applications/dm-echo/'
  $null = Invoke-AuthentikApi $conn POST '/policies/bindings/' @{ user = [int]$alice.pk; target = [string]$echoApp.pbm_uuid; order = 5; enabled = $true; negate = $false; timeout = 30 }
  $bindsBefore = @(Get-AuthentikList $conn "/policies/bindings/?target=$($echoApp.pbm_uuid)" | ForEach-Object { [string]$_.pk } | Sort-Object) -join ','
  $null = Invoke-WebUi $ui GET '/api/identity?deep=1'
  $null = Invoke-WebUiChange $ui @{ op = 'update'; name = 'echo2'; service = @{ name = 'echo2'; displayName = 'Echo two (renamed)'; hostnames = @($appHost2); target = @{ type = 'docker'; host = $app2; port = 80 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
  $again = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('echo') }
  $bindsAfter = @(Get-AuthentikList $conn "/policies/bindings/?target=$($echoApp.pbm_uuid)" | ForEach-Object { [string]$_.pk } | Sort-Object) -join ','
  Test-Condition 'no overwrite: refresh, an unrelated route change and protecting again leave authentik''s access rules alone' ($bindsAfter -eq $bindsBefore -and -not @($again.Data.items[0].authentik | Where-Object { $_.object -eq 'access' -and $_.kind -ne 'none' }).Count -and (Invoke-SignIn $httpPort $authHost $appHost 'alice' 'Alice-Live-Test-91x' $work).ReachedApp) "$bindsBefore -> $bindsAfter"
  $g5 = Invoke-WebUi $ui GET '/api/identity?deep=1'
  $ea = @($g5.Data.apps | Where-Object { $_.service -eq 'echo' })[0]
  Test-Condition 'verification: the application is marked verified only from authentik''s own access event' ($ea.verifiedAt -and (Get-Comp $g5.Data 'app:echo').state -eq 'verified') ($ea | ConvertTo-Json -Compress -Depth 4)
  Test-Condition 'status: the page shows how many access rules authentik has (read only), and an Open in authentik address' ($ea.rules -eq 2 -and -not $ea.ownerOnly -and $g5.Data.adminLinks.applications -match '/if/admin/') ($ea | ConvertTo-Json -Compress -Depth 4)
  $null = Invoke-AuthentikApi $conn PATCH "/providers/proxy/$($prov.pk)/" @{ mode = 'forward_single'; external_host = "https://$appHost" }
  $null = Invoke-AuthentikApi $conn PATCH "/providers/proxy/$($prov2.pk)/" @{ mode = 'forward_single'; external_host = "https://$appHost2" }
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
  $gp3 = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('echo') }
  Test-Condition 'interrupted: with authentik unreachable no change is previewed or applied' ($gp3.Status -eq 409) ($gp3.Body)
  $null = Invoke-Docker start "$akProject-server"
  $back = Wait-Until { (Get-AuthentikHealth -BaseUrl "http://127.0.0.1:$akPort").Ready } 180 3000
  $null = Wait-Until { (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -AuthHostname $authHost).State -eq 'auth' } 90 3000
  Test-Condition 'recovery: authentik restarted, the application asks for sign-in again' ($back -and (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname $appHost -AuthHostname $authHost).State -eq 'auth') ''

  # --- Rollback through the service backups ---------------------------------------------------------------------------------
  $rs = Invoke-WebUi $ui POST '/api/backups/restore' @{ id = $protectBackup; confirm = $true }
  $echoYaml = [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo.yml'))
  Test-Condition 'rollback: restoring the backup made before protection restores the previous route (no ForwardAuth)' ($rs.Status -eq 200 -and $echoYaml -notmatch 'forwardAuth') ($rs.Body)
  # The backup holds the whole registry from before the batch: echo2 lost its protection too, so both are protected again.
  $pp2 = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('echo', 'echo2') }
  Test-Condition 'rollback: protecting again reuses the authentik objects and their rules (only the routes change)' ($pp2.Status -eq 200 -and @($pp2.Data.items | ForEach-Object { $_.authentik } | Where-Object { $_.kind -ne 'none' }).Count -eq 0 -and @($pp2.Data.items | Where-Object { @($_.traefik.traefik.changes).Count -eq 1 }).Count -eq 2) (($pp2.Data.items | ForEach-Object { $_.authentik } | ForEach-Object { "$($_.kind):$($_.object)" }) -join ', ')
  $pa2 = Invoke-WebUi $ui POST '/api/identity/protect/apply' @{ planId = $pp2.Data.planId; confirm = $true }
  Test-Condition 'rollback: protection re-applied and verified for both' ($pa2.Data.ok -and @($pa2.Data.results | Where-Object { $_.ok -and $_.challenge.State -eq 'auth' }).Count -eq 2) ($pa2.Body)

  # --- Remove protection ----------------------------------------------------------------------------------------------------
  $up = Invoke-WebUi $ui POST '/api/identity/unprotect/plan' @{ service = 'echo' }
  Test-Condition 'unprotect: preview warns what stays in front of the application and that authentik keeps its rules' ($up.Status -eq 200 -and (@($up.Data.notes) -join ' ') -match 'without sign-in' -and (@($up.Data.notes) -join ' ') -match 'stay in authentik') ($up.Body)
  $ua = Invoke-WebUi $ui POST '/api/identity/unprotect/apply' @{ planId = $up.Data.planId; confirm = $true }
  $provNow = @(Get-AuthentikList $conn '/providers/proxy/?name=dm-echo' | Where-Object { $_.name -eq 'dm-echo' })[0]
  $bindsKept = @(Get-AuthentikList $conn "/policies/bindings/?target=$($echoApp.pbm_uuid)" | ForEach-Object { [string]$_.pk } | Sort-Object) -join ','
  Test-Condition 'unprotect: route without ForwardAuth; outpost no longer serves it; authentik application and its rules kept' ($ua.Data.ok -and [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo.yml')) -notmatch 'forwardAuth' -and (Get-AuthentikOverview $conn).Outpost.Providers -notcontains [int]$provNow.pk -and @(Get-AuthentikList $conn '/core/applications/?slug=dm-echo').Count -eq 1 -and $bindsKept -eq $bindsBefore) ($ua.Body)
  $pp3 = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ services = @('echo') }
  Test-Condition 'unprotect: protecting again restores the same rules (only outpost assignment and route)' (@($pp3.Data.items[0].authentik | Where-Object { $_.kind -ne 'none' } | ForEach-Object { $_.object }) -join ',' -eq 'outpost') (($pp3.Data.items[0].authentik | ForEach-Object { "$($_.kind):$($_.object)" }) -join ', ')

  # --- Persistence and bootstrap semantics ----------------------------------------------------------------------------------
  $akadmin = @(Get-AuthentikList $conn '/core/users/?username=akadmin')[0]
  $null = Invoke-AuthentikApi $conn POST "/core/users/$($akadmin.pk)/set_password/" @{ password = 'Changed-Admin-Pass-55z' }
  # All Compose files of the modular stack (server in compose.yaml, worker and database in their own files).
  $rargs = @('compose', '--project-directory', $akFolder); foreach ($f in @(Get-ChildItem -LiteralPath $akFolder -Filter 'compose*.yaml' -File | Sort-Object { $_.Name -ne 'compose.yaml' }, Name)) { $rargs += @('-f', $f.FullName) }
  $rr = Invoke-Docker @($rargs + 'restart')
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
    # Seven more applications; with echo (unprotected again above) that makes eight selectable ones.
    $batch = @(1..7 | ForEach-Object { "b$_" })
    foreach ($n in $batch) {
      $null = Invoke-Docker run -d --name "$stack-$n" --network $network --pull missing $whoami
      $null = Invoke-WebUiChange $ui @{ op = 'add'; service = @{ name = $n; displayName = "Batch $n"; hostnames = @("$n.idtest.example"); target = @{ type = 'docker'; host = "$stack-$n"; port = 80 }; cloudflare = @{ publish = $false; access = $false } }; cloudflare = @{ automate = $false } }
    }
    foreach ($lv in @('beginner', 'expert')) {
      Open-Page $cdp "$base/#identity?level=$lv"
      $ok = Wait-PageCondition $cdp "!!document.querySelector('.wizard-steps') && !!document.querySelector('#wizard-panel h2')" 60
      $text = [string](Invoke-PageScript $cdp 'document.body.innerText')
      Test-Condition "browser ($lv): a numbered wizard with Back/Continue opens at the saved step" ($ok -and $text -match 'Step \d+ of 9' -and $text -match 'Choose how people sign in' -and $text -match 'Verify the owner with Google' -and $text -match 'Protect applications' -and $text -match 'Back') ''
      Test-Condition "browser ($lv): no secret is shown" ($text -notmatch [regex]::Escape($googleSecret) -and $text -notmatch [regex]::Escape($bootToken) -and $text -notmatch [regex]::Escape($adminPass)) ''
    }
    # Screenshots are deliverables, not checks: a capture that times out is retried once as a viewport image and noted.
    $shot = { param($name) if (-not $ScreenshotDir) { return }
      try { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir $name) }
      catch {
        try { $img = Invoke-Cdp $cdp 'Page.captureScreenshot' @{ format = 'png' } 60000; [IO.File]::WriteAllBytes((Join-Path $ScreenshotDir $name), [Convert]::FromBase64String($img.data)); Write-Host "screenshot ${name}: viewport only ($($_.Exception.Message))" -ForegroundColor DarkYellow }
        catch { Write-Host "screenshot ${name} not saved: $($_.Exception.Message)" -ForegroundColor DarkYellow }
      } }
    Open-Page $cdp "$base/#identity/mode?level=beginner"; $null = Wait-PageCondition $cdp "!!document.querySelector('#identity-mode')" 60; & $shot 'wizard-1-mode.png'
    Open-Page $cdp "$base/#identity/google?level=beginner"; $okG = Wait-PageCondition $cdp "!!document.querySelector('#identity-google')" 60
    $gtext = [string](Invoke-PageScript $cdp "document.querySelector('#wizard-panel').innerText")
    Test-Condition 'browser google: four guided Google Cloud steps, External for Gmail, JSON import, exact redirect URI, one app name' ($okG -and $gtext -match 'Branding' -and $gtext -match 'Audience' -and $gtext -match 'External' -and $gtext -match 'Download JSON' -and $gtext -match [regex]::Escape($redir) -and ([regex]::Matches($gtext, [regex]::Escape('idtest.example Sign-in'))).Count -ge 2 -and $gtext -match 'optional') ''
    $helpCount = [int](Invoke-PageScript $cdp "document.querySelectorAll('#wizard-panel .help-btn').length")
    Test-Condition 'browser google: question-mark help beside the unfamiliar settings' ($helpCount -ge 5) "help buttons: $helpCount"
    & $shot 'wizard-5-google.png'
    Open-Page $cdp "$base/#identity/signin?level=beginner"; $null = Wait-PageCondition $cdp "!!document.querySelector('.login-preview')" 60; & $shot 'wizard-6-signin.png'
    Open-Page $cdp "$base/#identity/owner?level=beginner"; $okO = Wait-PageCondition $cdp "!!document.querySelector('.verified-banner')" 60
    Test-Condition 'browser owner: the owner step shows an obvious verified state' ($okO -and [string](Invoke-PageScript $cdp "document.querySelector('.verified-banner').innerText") -match 'Owner verified') ''
    & $shot 'wizard-7-owner-verified.png'
    # Application selection: select all, deselect one, the page never jumps.
    Open-Page $cdp "$base/#identity/apps?level=beginner"
    $okA = Wait-PageCondition $cdp "!!document.querySelector('#id-sel-all') && document.querySelectorAll('.protect-table tbody input[type=checkbox]').length >= 8" 60
    $null = Invoke-PageScript $cdp "document.querySelector('.protect-table').scrollIntoView({ block: 'center' }); true"
    $y0 = [int](Invoke-PageScript $cdp 'Math.round(window.scrollY)')
    $null = Invoke-PageScript $cdp "document.querySelector('#id-sel-all').click(); true"
    $cnt = [string](Invoke-PageScript $cdp "document.querySelector('.sel-count').textContent")
    $null = Invoke-PageScript $cdp "document.querySelector('#sel-b3').click(); true"
    $null = Invoke-PageScript $cdp "document.querySelector('#sel-b5').click(); document.querySelector('#sel-b5').click(); true"
    $y1 = [int](Invoke-PageScript $cdp 'Math.round(window.scrollY)')
    $states = [string](Invoke-PageScript $cdp "[...document.querySelectorAll('.protect-table tbody input[type=checkbox]')].map((b) => b.dataset.name + '=' + b.checked).join(',')")
    $cnt2 = [string](Invoke-PageScript $cdp "document.querySelector('.sel-count').textContent")
    Test-Condition 'browser apps: Select all selects the 8 new applications; already protected ones are labelled, not selectable' ($okA -and $cnt -match '^8 of 8' -and [string](Invoke-PageScript $cdp "document.querySelector('.protect-table').innerText") -match 'Already protected') "$cnt"
    Test-Condition 'browser apps: ticking and unticking never moves the page; selections stay as set' ($y1 -eq $y0 -and $cnt2 -match '^7 of 8' -and $states -match 'b3=false' -and $states -match 'b5=true' -and $states -match 'b1=true') "y $y0 -> $y1; $cnt2; $states"
    & $shot 'wizard-8-apps-selection.png'
    $null = Invoke-PageScript $cdp "document.querySelector('#id-protect-btn').click(); true"
    $okP = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-review') && [...document.querySelectorAll('#id-protect-review button')].some((b) => b.textContent.includes('Protect 7'))" 240
    $null = Invoke-PageScript $cdp "(() => { document.querySelector('#id-protect-review input[type=checkbox]').click(); [...document.querySelectorAll('#id-protect-review button')].find((b) => b.textContent.includes('Protect 7')).click(); return true; })()"
    $okR = Wait-PageCondition $cdp "!!document.querySelector('#id-protect-result')" 900
    $resText = [string](Invoke-PageScript $cdp "(document.querySelector('#id-protect-result') || {}).innerText || ''")
    $prot = @(@('echo') + $batch | Where-Object { [IO.File]::ReadAllText((Join-Path $installPath "traefik\dynamic\svc-$_.yml")) -match "svc-$_-authentik" })
    Test-Condition 'browser apps: the batch of 7 is protected, each route verified; the unticked one is untouched' ($okP -and $okR -and $prot.Count -eq 7 -and $prot -notcontains 'b3' -and ([regex]::Matches($resText, 'ForwardAuth enforced')).Count -eq 7) "$($prot -join ',') / $($resText.Substring(0, [Math]::Min(300, $resText.Length)))"
    $stillEcho2 = [IO.File]::ReadAllText((Join-Path $installPath 'traefik\dynamic\svc-echo2.yml')) -match 'svc-echo2-authentik'
    Test-Condition 'bulk protection keeps every earlier protection (echo2 still protected; nothing removed by deselecting)' ($stillEcho2 -and @($batch | Where-Object { (Test-ForwardAuthChallenge -TraefikPort $httpPort -Hostname "$_.idtest.example").State -eq 'auth' }).Count -eq 6) ''
    & $shot 'wizard-8-apps-result.png'
    # Authentik's real sign-in page, through Traefik (Edge maps the test hostnames to this PC).
    $cdp2 = Start-EdgeSession -WorkDir $work -ExtraArgs @("--host-resolver-rules=MAP *.idtest.example 127.0.0.1")
    try {
      Set-Viewport $cdp2 1366 900
      Open-Page $cdp2 "http://${authHost}:$httpPort/"
      $okL = Wait-PageCondition $cdp2 "(() => { const deep = (n) => { let t = ''; if (n.shadowRoot) t += deep(n.shadowRoot); for (const c of n.childNodes) t += c.nodeType === 3 ? c.textContent : deep(c); return t; }; return /Google/.test(deep(document.body)); })()" 90
      Start-Sleep -Seconds 2
      if ($ScreenshotDir) { Save-PageScreenshot $cdp2 (Join-Path $ScreenshotDir 'authentik-signin-page.png') }
      Test-Condition 'login page: authentik''s sign-in page renders with the Google button (screenshot)' $okL ''
    } finally { Stop-EdgeSession $cdp2 }
    # Token management in the browser: an unusable token opens the replacement form; replacing works from the page.
    Save-ProtectedSecret -Settings (Get-StackSettings -InstallPath $installPath) -Name 'authentik_api' -Value $outpostKey -Label 'old version'
    $null = Invoke-WebUi $ui POST '/api/identity/token/test' @{}
    Open-Page $cdp "$base/#identity/connect?level=beginner"
    $ok1 = Wait-PageCondition $cdp "!!document.querySelector('#cred-card-authentik-api') && !!document.querySelector('#cred-authentik-api')" 60
    $cardText = [string](Invoke-PageScript $cdp "document.querySelector('#cred-card-authentik-api').innerText")
    Test-Condition 'browser token: a failed token shows the reason, Replace API token and the replacement field right away' ($ok1 -and $cardText -match 'Replace API token' -and $cardText -match 'outpost' -and $cardText -match 'Try a different token' -and $cardText -match 'Test connection') $cardText
    if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'identity-token-failed-1366.png') }
    Open-Page $cdp "$base/#identity/connect?level=beginner"
    $ok2 = Wait-PageCondition $cdp "!!document.querySelector('#cred-authentik-api')" 60
    Test-Condition 'browser token: after a page refresh the replacement form is still offered' $ok2 ''
    $null = Invoke-PageScript $cdp "(() => { const i = document.querySelector('#cred-authentik-api'); i.value = 'wrongwrongwrongwrongwrongwrong0123456789'; [...document.querySelectorAll('#cred-card-authentik-api button')].find((b) => b.textContent.includes('Validate and save')).click(); return true; })()"
    $ok3 = Wait-PageCondition $cdp "(document.querySelector('#cred-card-authentik-api .form-error') || {}).textContent.includes('not saved')" 60
    Test-Condition 'browser token: a refused token shows why and keeps the form for another attempt' ($ok3 -and [bool](Invoke-PageScript $cdp "!!document.querySelector('#cred-authentik-api') && document.querySelector('#cred-authentik-api').value === ''")) ''
    $null = Invoke-PageScript $cdp "(() => { const i = document.querySelector('#cred-authentik-api'); i.value = '$bootToken'; [...document.querySelectorAll('#cred-card-authentik-api button')].find((b) => b.textContent.includes('Validate and save')).click(); return true; })()"
    $ok4 = Wait-PageCondition $cdp "(() => { const c = document.querySelector('#cred-card-authentik-api'); return c && c.innerText.includes('Connected') && !document.querySelector('#cred-authentik-api'); })()" 60
    $card2 = [string](Invoke-PageScript $cdp "document.querySelector('#cred-card-authentik-api').innerText")
    Test-Condition 'browser token: replacing from the page connects; Replace API token stays available on a healthy connection' ($ok4 -and $card2 -match 'akadmin' -and $card2 -match 'Replace API token' -and $card2 -notmatch [regex]::Escape($bootToken)) $card2
    if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'identity-token-connected-1366.png') }
    Open-Page $cdp "$base/#identity?level=expert"
    $null = Wait-PageCondition $cdp "!!document.querySelector('.wizard-steps')" 60
    $raw = [string](Invoke-PageScript $cdp "(document.querySelector('details.tech pre') || {}).textContent || ''")
    Test-Condition 'browser (expert): raw state is shown without secrets' ($raw -match 'clientId' -and $raw -notmatch [regex]::Escape($googleSecret)) ''
    Set-Viewport $cdp 390 844 -Mobile
    Open-Page $cdp "$base/#identity?level=beginner"
    $null = Wait-PageCondition $cdp "!!document.querySelector('.wizard-steps')" 60
    $overflow = [bool](Invoke-PageScript $cdp 'document.documentElement.scrollWidth > window.innerWidth + 1')
    Test-Condition 'browser (390 px): no horizontal scrolling' (-not $overflow) ''
    if ($ScreenshotDir) { Save-PageScreenshot $cdp (Join-Path $ScreenshotDir 'wizard-390.png') }
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
    $null = Invoke-Docker rm -f $app "$stack-echo2"
    foreach ($n in 1..7) { $null = Invoke-Docker rm -f "$stack-b$n" }
    # authentik is a modular stack: down needs the complete file set (compose.yaml alone does not parse: its depends_on
    # names services of the other files). Anything still labelled with the project is removed afterwards.
    $akFiles = @(Get-ChildItem -LiteralPath $akFolder -Filter 'compose*.yaml' -File -ErrorAction SilentlyContinue | Sort-Object { $_.Name -ne 'compose.yaml' }, Name)
    if ($akFiles.Count) { $dargs = @('compose', '--project-directory', $akFolder); foreach ($f in $akFiles) { $dargs += @('-f', $f.FullName) }; $null = Invoke-Docker @($dargs + @('down', '-v', '--remove-orphans')) }
    foreach ($c in @((Invoke-Docker ps -a -q --filter "label=com.docker.compose.project=$akProject").Output | Where-Object { $_ })) { $null = Invoke-Docker rm -f $c }
    foreach ($n in @((Invoke-Docker network ls -q --filter "name=${akProject}_").Output | Where-Object { $_ })) { $null = Invoke-Docker network rm $n }
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
    $orphaned = @(Complete-TestRun $stack)
    Test-Condition 'teardown: nothing with this run''s prefix is left (containers, volumes, networks, folder)' ($orphaned.Count -eq 0) ($orphaned -join ', ')
  }
}

$failedTests = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failedTests.Count)
if ($failedTests.Count -gt 0) { exit 1 }
exit 0
