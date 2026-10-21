#requires -version 5.1
<#
.SYNOPSIS
  Tests for the web UI (webui.ps1) and lib\CloudflareApi.psm1, against a Cloudflare API mock.

.DESCRIPTION
  Copies the package into a temporary folder (its own STACK_NAME; no stack containers are started), starts the
  Cloudflare API mock (tests\CloudflareMock.ps1) and the web UI on free loopback ports, and drives the API the
  way the browser does. Covers:
    - security: loopback-only listener, sign-in link, Host / Origin / CSRF / Content-Type checks, static file
      whitelist, body size limit, security headers, the API token never appearing in any response or file
    - DPAPI token storage, API base restriction, tunnel token install
    - Cloudflare setup: token verify/save/replace, account and tunnel selection, tunnel creation
    - the primary workflow: preview -> confirm -> Traefik + Access + tunnel route + DNS, including overwrite
      confirmation, blocked records, stale previews, hostname changes, disable/enable, removal with cleanup
    - backups / rollback, logs, validation
  Deep validation uses a throwaway Traefik container (no network). Nothing touches real Cloudflare.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-WebUi.ps1
#>
[CmdletBinding()]
param([switch]$KeepFiles)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail }
}
function Short($r) { if ($null -eq $r) { return '(no response)' }; return "HTTP $($r.Status) $($r.Body.Substring(0, [Math]::Min(400, $r.Body.Length)))" }

# --- Fixture ------------------------------------------------------------------------------------------------
$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpx-webui-$id"
$install = Join-Path $work 'install'
New-Item -ItemType Directory -Force -Path $install | Out-Null
foreach ($item in @('compose.yaml', 'install.ps1', 'services.ps1', 'webui.ps1', '.env.example', 'lib', 'webui', 'scripts', 'traefik', 'config', 'examples', 'tests')) {
  Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $install -Recurse -Force
}
Get-ChildItem -LiteralPath (Join-Path $install 'traefik\dynamic') -Filter 'svc-*.yml' -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -LiteralPath (Join-Path $install 'config\services.json'), (Join-Path $install 'config\cloudflare.json') -ErrorAction SilentlyContinue
@("STACK_NAME=tpx-webui-$id", 'TRAEFIK_HTTP_PORT=18480', 'TRAEFIK_DASHBOARD_PORT=18481', "PROXY_NETWORK=tpx-webui-$id-proxy",
  'TUNNEL_SUBNET=172.31.253.0/28', 'TUNNEL_IP_RANGE=172.31.253.0/29', 'CLOUDFLARED_IP=172.31.253.10') | Set-Content -LiteralPath (Join-Path $install '.env') -Encoding ASCII
$settings = Get-StackSettings -InstallPath $install

$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$acct = 'acc0000000000000000000000000001'
$tunnelId = '11111111-2222-3333-4444-555555555555'
$tunnelTarget = "$tunnelId.cfargotunnel.com"
$mock = $null; $ui = $null

function Get-Ingress { return ,@((Get-MockState $mock).configs.$tunnelId.ingress) }
function Get-Dns([string]$Name) { return ,@((Get-MockState $mock).dns | Where-Object { $_.name -eq $Name }) }
function Get-Apps([string]$Domain) { return ,@((Get-MockState $mock).apps | Where-Object { $_.domain -eq $Domain }) }
function New-Body([string]$Op, [string]$Name, [string[]]$Hostnames, [string]$TargetHost = '10.10.0.11', [int]$Port = 8080, [string]$Exposure = 'access', [string[]]$Emails = @(), [bool]$Automate = $true, [bool]$Cleanup = $true) {
  return @{
    op = $Op; name = $Name
    service = @{ name = $Name; hostnames = $Hostnames; target = @{ type = 'auto'; host = $TargetHost; port = $Port; protocol = 'http' }
      cloudflare = @{ publish = ($Exposure -ne 'local'); access = ($Exposure -eq 'access') }; middlewares = @('default-headers@file') }
    cloudflare = @{ automate = $Automate; accessEmails = $Emails; cleanup = $Cleanup }
  }
}
function Find-Action($Plan, [string]$ActionId) { return ,@($Plan.Data.cloudflare.actions | Where-Object { $_.id -eq $ActionId }) }

try {
  # --- Module-level checks ----------------------------------------------------------------------------------
  $refused = $false
  try { Set-CloudflareApiBase 'https://evil.example.com/client/v4' } catch { $refused = $true }
  Test-Condition 'API base: arbitrary hosts are refused' $refused
  $refused = $false
  try { Set-CloudflareApiBase 'http://192.168.1.5:8080' } catch { $refused = $true }
  Test-Condition 'API base: non-loopback http is refused' $refused
  Set-CloudflareApiBase ''
  Test-Condition 'API base defaults to api.cloudflare.com' ((Get-CloudflareApiBase) -eq 'https://api.cloudflare.com/client/v4')
  Test-Condition 'token format check rejects junk' (-not (Test-CloudflareApiToken 'short') -and -not (Test-CloudflareApiToken ('a b' * 20)) -and (Test-CloudflareApiToken $apiToken))
  $redacted = (ConvertTo-RedactedText @('Authorization: Bearer abcdefghijklmnop', 'token=supersecretvalue1', 'TUNNEL_TOKEN=eyJhIjoiYWJjIiwidCI6ImRlZiIsInMiOiJnaGkifQabcdefgh')) -join "`n"
  Test-Condition 'redaction masks bearer, token= and tunnel tokens' ($redacted -notmatch 'abcdefghijklmnop|supersecretvalue1|eyJhIjoi') $redacted

  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $install 'webui.ps1') -InstallPath $install -WorkDir $work -ApiBase $mock.Base
  $port = $ui.Port

  # --- Transport / authentication ------------------------------------------------------------------------------
  $listen = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
  if ($listen.Count -eq 0) { Add-Result 'SKIP' 'listener is bound to 127.0.0.1 only' 'this session cannot see its own listening sockets in Get-NetTCPConnection (the LAN connection test below still applies)' }
  else { Test-Condition 'listener is bound to 127.0.0.1 only' (@($listen | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count -eq 0) (($listen | ForEach-Object { $_.LocalAddress }) -join ',') }
  $lan = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1)
  if ($lan.Count -gt 0) {
    $reachable = $false
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.Connect($lan[0].IPAddress, $port); $reachable = $true } catch { } finally { $c.Close() }
    Test-Condition "not reachable on the LAN address $($lan[0].IPAddress)" (-not $reachable)
  } else { Add-Result 'SKIP' 'not reachable on a LAN address' 'no non-loopback IPv4 address' }

  $r = Invoke-RawHttp -Port $port -Path '/'
  Test-Condition 'index page is served with security headers' ($r.Status -eq 200 -and $r.Body -match 'Traefik Proxy Manager' -and $r.Headers['content-security-policy'] -match "script-src 'self'" -and
    $r.Headers['x-frame-options'] -eq 'DENY' -and $r.Headers['x-content-type-options'] -eq 'nosniff' -and $r.Headers['referrer-policy'] -eq 'no-referrer') (Short $r)
  $r = Invoke-RawHttp -Port $port -Path '/api/status'
  Test-Condition 'API without a session -> 401' ($r.Status -eq 401) (Short $r)
  $r = Invoke-RawHttp -Port $port -Path '/?k=wrong-key'
  Test-Condition 'wrong launch key -> 403, no cookie' ($r.Status -eq 403 -and -not $r.Headers.ContainsKey('set-cookie')) (Short $r)
  $login = Connect-WebUi $ui
  $cookie = $login.Headers['set-cookie']
  Test-Condition 'launch link sets an HttpOnly SameSite=Strict cookie and redirects' ($login.Status -eq 303 -and $cookie -match 'HttpOnly' -and $cookie -match 'SameSite=Strict' -and $login.Headers['location'] -eq '/') $cookie
  Test-Condition 'session endpoint returns a CSRF token' ([string]$ui.Csrf -match '^[A-Za-z0-9_-]{20,}$')
  $r = Invoke-RawHttp -Port $port -Path '/api/status' -HostHeader "evil.example:$port" -Headers @{ Cookie = $ui.Cookie }
  Test-Condition 'foreign Host header (DNS rebinding) -> 421 even with a session' ($r.Status -eq 421) (Short $r)
  $r = Invoke-RawHttp -Port $port -Path '/' -HostHeader "localhost:$port"
  Test-Condition 'localhost Host header is accepted' ($r.Status -eq 200)
  $r = Invoke-WebUi $ui POST '/api/validate' @{} -NoCsrf
  Test-Condition 'POST without CSRF token -> 403' ($r.Status -eq 403) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/validate' @{} -Origin 'https://evil.example'
  Test-Condition 'POST from another Origin -> 403' ($r.Status -eq 403) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/validate' 'x=1' -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
  Test-Condition 'form-encoded POST -> 415' ($r.Status -eq 415) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/validate' '{not json'
  Test-Condition 'invalid JSON -> 400' ($r.Status -eq 400) (Short $r)
  $paths = @('/webui.ps1', '/../webui.ps1', '/%2e%2e/lib/CloudflareApi.psm1', '/..%5Cwebui.ps1', '/secrets/cloudflare_api.dpapi', '/app.js/../../webui.ps1')
  $bad = @($paths | Where-Object { (Invoke-RawHttp -Port $port -Path $_).Status -ne 404 })
  Test-Condition 'only whitelisted static files are served (traversal -> 404)' ($bad.Count -eq 0) ($bad -join ', ')
  $big = Invoke-WebUi $ui POST '/api/validate' $null -Headers @{ 'Content-Length' = '1100000' }
  Test-Condition 'request bodies over 1 MB are refused (413)' ($big.Status -eq 413) "HTTP $($big.Status)"
  $r = Invoke-RawHttp -Port $port -Method 'POST' -Path '/' -Headers @{ Cookie = $ui.Cookie }
  Test-Condition 'non-GET on static paths -> 405' ($r.Status -eq 405) (Short $r)

  # --- Status ------------------------------------------------------------------------------------------------------
  $s = Invoke-WebUi $ui GET '/api/status'
  Test-Condition 'status: Docker checks, instance and not-running stack' ($s.Status -eq 200 -and $s.Data.docker.EngineRunning -and $s.Data.instance.stackName -eq "tpx-webui-$id" -and
    @($s.Data.stack.Containers | Where-Object { $_.State -eq 'missing' }).Count -eq 3) (Short $s)

  # --- Cloudflare token ----------------------------------------------------------------------------------------------
  $r = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = 'not a token' }
  Test-Condition 'malformed API token rejected' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = ('wrongTok_' + [Guid]::NewGuid().ToString('N')) }
  Test-Condition 'token rejected by Cloudflare is not stored' ($r.Status -eq 400 -and -not (Test-Path (Join-Path $install 'secrets\cloudflare_api.dpapi'))) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = $apiToken }
  Test-Condition 'valid token verified and saved; single account auto-selected' ($r.Status -eq 200 -and $r.Data.saved -and @($r.Data.zones).Count -eq 2 -and (Read-CloudflareConfig -Settings $settings).accountId -eq $acct) (Short $r)
  $secretPath = Join-Path $install 'secrets\cloudflare_api.dpapi'
  $secretText = [IO.File]::ReadAllText($secretPath)
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($apiToken))
  Test-Condition 'stored token is DPAPI-encrypted (no plaintext or base64 of it)' ($secretText -notmatch [regex]::Escape($apiToken) -and $secretText -notmatch [regex]::Escape($b64) -and $secretText -match 'DPAPI-CurrentUser')
  $decrypted = & (Get-Module CloudflareApi) { param($s) Read-CloudflareApiToken $s } $settings
  Test-Condition 'stored token decrypts for this Windows user' ($decrypted -eq $apiToken)
  $decrypted = $null
  $acl = (& icacls $secretPath) -join ' '
  Test-Condition 'token file ACL has no inheritance and no Users/Everyone' ($acl -notmatch 'BUILTIN\\Users|Everyone|\(I\)') $acl
  $r = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = $apiToken }
  Test-Condition 'replacing a stored token needs confirmation (409)' ($r.Status -eq 409 -and $r.Data.needsConfirm -eq 'replace') (Short $r)
  $r = Invoke-WebUi $ui GET '/api/cloudflare'
  Test-Condition 'Cloudflare status shows metadata only' ($r.Status -eq 200 -and $r.Data.token.Stored -and $r.Data.token.Readable -and $r.Body -notmatch [regex]::Escape($apiToken)) (Short $r)

  # --- Allowed domains ----------------------------------------------------------------------------------------------
  $r = Invoke-WebUi $ui GET '/api/cloudflare/zones'
  Test-Condition 'two visible domains: none is allowed automatically' ($r.Status -eq 200 -and @($r.Data.zones).Count -eq 0) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/domains' @{ zoneIds = @('zone00000000000000000000000000009') }
  Test-Condition 'a domain the token cannot see is refused' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/domains' @{ zoneIds = @('zone00000000000000000000000000001') }
  Test-Condition 'allowed domains saved (example.test only)' ($r.Status -eq 200 -and @($r.Data.domains).Count -eq 1 -and (Read-CloudflareConfig -Settings $settings).domains[0].name -eq 'example.test') (Short $r)
  $r = Invoke-WebUi $ui GET '/api/cloudflare/zones'
  Test-Condition 'service form lists only the allowed domain' ($r.Status -eq 200 -and (@($r.Data.zones | ForEach-Object { $_.name }) -join ',') -eq 'example.test') (Short $r)

  # --- Account / tunnel -------------------------------------------------------------------------------------------------
  $r = Invoke-WebUi $ui GET '/api/cloudflare/tunnels'
  Test-Condition 'tunnels listed (remote vs. locally managed)' ($r.Status -eq 200 -and @($r.Data.tunnels | Where-Object { $_.name -eq 'existing-tunnel' -and $_.remotelyManaged }).Count -eq 1 -and
    @($r.Data.tunnels | Where-Object { $_.name -eq 'local-tunnel' -and -not $_.remotelyManaged }).Count -eq 1) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/select' @{ accountId = $acct; tunnelId = '99999999-2222-3333-4444-555555555555' }
  Test-Condition 'locally managed tunnel cannot be selected' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/tunnel' @{ name = 'web-ui-test' }
  Test-Condition 'tunnel creation without confirmation -> 400, nothing created' ($r.Status -eq 400 -and @((Get-MockState $mock).tunnels | Where-Object { $_.name -eq 'web-ui-test' }).Count -eq 0) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/tunnel' @{ name = 'web-ui-test'; confirm = $true }
  $created = @((Get-MockState $mock).tunnels | Where-Object { $_.name -eq 'web-ui-test' })
  Test-Condition 'confirmed tunnel creation: remotely managed tunnel created and selected' ($r.Status -eq 200 -and $created.Count -eq 1 -and $created[0].config_src -eq 'cloudflare' -and $r.Data.config.tunnelName -eq 'web-ui-test') (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/tunnel' @{ name = 'web-ui-test'; confirm = $true }
  Test-Condition 'duplicate tunnel name refused' ($r.Status -ne 200) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/select' @{ accountId = $acct; tunnelId = $tunnelId }
  Test-Condition 'existing tunnel selected' ($r.Status -eq 200 -and $r.Data.config.tunnelId -eq $tunnelId) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/connector' @{}
  Test-Condition 'connector install without confirmation -> 400' ($r.Status -eq 400) (Short $r)

  Set-CloudflareApiBase $mock.Base
  $tok = Install-CloudflareTunnelToken -Settings $settings -AccountId $acct -TunnelId $tunnelId
  $tokenFile = Join-Path $install 'secrets\cloudflare_tunnel_token'
  $decoded = ConvertFrom-TunnelToken ([IO.File]::ReadAllText($tokenFile))
  Test-Condition 'connector token fetched into secrets\cloudflare_tunnel_token' ($decoded -and $decoded.TunnelId -eq $tunnelId -and -not $tok.PreviousTokenBackup)
  $tok = Install-CloudflareTunnelToken -Settings $settings -AccountId $acct -TunnelId $tunnelId
  Test-Condition 'replacing the connector token backs up the previous one' ($tok.PreviousTokenBackup -and (Test-Path -LiteralPath $tok.PreviousTokenBackup))
  Set-CloudflareApiBase ''

  # --- Primary workflow: add a service ---------------------------------------------------------------------------------
  $before = @(Get-MockRequests $mock).Count
  $plexBody = New-Body 'add' 'plex' @('plex.example.test') '10.10.0.11' 32800 'access' @('owner@example.com')
  $plan = Invoke-WebUi $ui POST '/api/services/plan' $plexBody
  $writes = @(Get-MockRequests $mock | Select-Object -Skip $before | Where-Object { $_.method -ne 'GET' })
  Test-Condition 'preview: Traefik route diff for plex (LAN 10.10.0.11:32800)' ($plan.Status -eq 200 -and @($plan.Data.traefik.changes | Where-Object { $_.action -eq 'add' -and $_.file -match 'svc-plex.yml' -and ($_.diff -join "`n") -match 'url: http://10\.10\.0\.11:32800' }).Count -eq 1) (Short $plan)
  Test-Condition 'preview: Access, tunnel route and DNS planned (in that order)' (((@($plan.Data.cloudflare.actions | ForEach-Object { "$($_.step):$($_.kind)" })) -join ',') -eq 'access:create,tunnel:create,dns:create') (($plan.Data.cloudflare.actions | ForEach-Object { $_.id }) -join ',')
  Test-Condition 'preview: media streaming warning shown' (@($plan.Data.traefik.issues | Where-Object { $_.Message -match 'media streaming' }).Count -eq 1)
  Test-Condition 'preview changes nothing (no files, no Cloudflare writes)' ($writes.Count -eq 0 -and -not (Test-Path (Join-Path $install 'traefik\dynamic\svc-plex.yml')) -and -not (Test-Path $settings.RegistryPath)) ($writes | ConvertTo-Json -Compress)
  $r = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $plan.Data.planId }
  Test-Condition 'apply without confirm -> 400' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $plan.Data.planId; confirm = $true }
  Test-Condition 'apply: validated, written, Cloudflare configured' ($r.Status -eq 200 -and $r.Data.ok -and @($r.Data.steps | Where-Object { $_.status -eq 'Failed' }).Count -eq 0 -and
    @($r.Data.steps | Where-Object { $_.name -match 'Validate' -and $_.status -eq 'Done' }).Count -eq 1) (Short $r)
  Test-Condition 'Traefik route file and registry written' ((Test-Path (Join-Path $install 'traefik\dynamic\svc-plex.yml')) -and ((Read-ServiceRegistry -Settings $settings).services[0].target.type -eq 'lan'))
  $apps = Get-Apps 'plex.example.test'
  Test-Condition 'Access app created with the allowed email' ($apps.Count -eq 1 -and ($apps[0].policies | ConvertTo-Json -Depth 8 -Compress) -match 'owner@example.com' -and $apps[0].type -eq 'self_hosted')
  $ingress = Get-Ingress
  $hostsIn = @($ingress | ForEach-Object { if ($_.PSObject.Properties['hostname']) { $_.hostname } else { '*' } })
  Test-Condition 'tunnel ingress: existing rule kept, plex -> traefik:80, catch-all last' (($hostsIn -join ',') -eq 'keep.example.test,plex.example.test,*' -and
    @($ingress | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq 'plex.example.test' })[0].service -eq 'http://traefik:80' -and $ingress[-1].service -eq 'http_status:404') ($hostsIn -join ',')
  Test-Condition 'other tunnel settings preserved (warp-routing)' ($null -ne (Get-MockState $mock).configs.$tunnelId.'warp-routing')
  $dns = Get-Dns 'plex.example.test'
  Test-Condition 'DNS: proxied CNAME to the tunnel' ($dns.Count -eq 1 -and $dns[0].type -eq 'CNAME' -and $dns[0].content -eq $tunnelTarget -and $dns[0].proxied)
  $cfg = Read-CloudflareConfig -Settings $settings
  Test-Condition 'created resources recorded in config\cloudflare.json' ($cfg.managed.'plex.example.test'.dnsRecordId -and $cfg.managed.'plex.example.test'.accessAppId)
  $r = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $plan.Data.planId; confirm = $true }
  Test-Condition 'a preview can be applied only once (409)' ($r.Status -eq 409) (Short $r)
  $r = Invoke-WebUi $ui GET '/api/services'
  Test-Condition 'service list shows plex behind Access' ($r.Status -eq 200 -and @($r.Data.services | Where-Object { $_.service.name -eq 'plex' -and $_.exposure -eq 'access' }).Count -eq 1) (Short $r)

  # --- Stale preview -----------------------------------------------------------------------------------------------------
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'grafana' @('grafana.example.test') 'host.docker.internal' 3000 'local')
  $reg = Read-ServiceRegistry -Settings $settings
  $sidePlan = Get-ServicePlan -Settings $settings -Services (@($reg.services) + (New-ServiceDefinition -Name 'side' -Hostname 'side.example.test' -TargetType lan -TargetHost 10.0.0.9 -Port 80 -Publish $false))
  $null = Invoke-ServicePlan -Settings $settings -Plan $sidePlan -NoReload
  $r = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $plan.Data.planId; confirm = $true }
  Test-Condition 'stale preview refused after an outside change (409)' ($r.Status -eq 409 -and -not (Test-Path (Join-Path $install 'traefik\dynamic\svc-grafana.yml'))) (Short $r)
  $c = Invoke-WebUiChange $ui (New-Body 'add' 'grafana' @('grafana.example.test') 'localhost' 3000 'local')
  $g = @((Read-ServiceRegistry -Settings $settings).services | Where-Object { $_.name -eq 'grafana' })
  Test-Condition 'local-only service: no Cloudflare actions; localhost becomes host.docker.internal' ($c.Apply.Status -eq 200 -and @($c.Plan.Data.cloudflare.actions).Count -eq 0 -and
    $g.Count -eq 1 -and $g[0].target.type -eq 'host' -and $g[0].target.host -eq 'host.docker.internal' -and (($c.Plan.Data.notes -join ' ') -match 'host.docker.internal')) (Short $c.Plan)

  # --- Overwrite / blocked / existing resources ------------------------------------------------------------------------
  $tb = New-Body 'add' 'taken' @('taken.example.test') '10.10.0.12' 80 'public'
  $plan = Invoke-WebUi $ui POST '/api/services/plan' $tb
  $ow = Find-Action $plan 'dns:taken.example.test'
  Test-Condition 'existing CNAME elsewhere -> overwrite flagged' ($ow.Count -eq 1 -and $ow[0].kind -eq 'update' -and $ow[0].overwrite) (Short $plan)
  $r = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $plan.Data.planId; confirm = $true }
  Test-Condition 'overwrite without per-resource confirmation -> 400, nothing written' ($r.Status -eq 400 -and (Get-Dns 'taken.example.test')[0].content -eq 'elsewhere.example.net' -and -not (Test-Path (Join-Path $install 'traefik\dynamic\svc-taken.yml'))) (Short $r)
  $c = Invoke-WebUiChange $ui $tb @('dns:taken.example.test')
  Test-Condition 'confirmed overwrite repoints the record to the tunnel' ($c.Apply.Status -eq 200 -and (Get-Dns 'taken.example.test')[0].content -eq $tunnelTarget) (Short $c.Apply)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'arec' @('a-record.example.test') '10.10.0.13' 80 'public')
  Test-Condition 'existing A record -> blocked, cannot apply' ($plan.Status -eq 200 -and -not $plan.Data.canApply -and (Find-Action $plan 'dns:a-record.example.test')[0].kind -eq 'blocked') (Short $plan)
  $r = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $plan.Data.planId; confirm = $true }
  Test-Condition 'blocked plan cannot be applied' ($r.Status -eq 400 -and (Get-Dns 'a-record.example.test')[0].type -eq 'A') (Short $r)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'prot' @('protected.example.test') '10.10.0.14' 80 'access')
  Test-Condition 'existing Access app is reused, not duplicated' ((Find-Action $plan 'access:protected.example.test')[0].kind -eq 'none' -and $plan.Data.canApply) (Short $plan)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'noemail' @('noemail.example.test') '10.10.0.15' 80 'access')
  Test-Condition 'Access without allowed emails -> blocked' ((Find-Action $plan 'access:noemail.example.test')[0].kind -eq 'blocked' -and -not $plan.Data.canApply) (Short $plan)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'nozone' @('app.not-in-account.test') '10.10.0.16' 80 'public')
  Test-Condition 'hostname outside the token''s zones -> blocked' ((Find-Action $plan 'dns:app.not-in-account.test')[0].kind -eq 'blocked' -and -not $plan.Data.canApply) (Short $plan)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'otherzone' @('app.other.test') '10.10.0.16' 80 'public')
  $oz = Find-Action $plan 'dns:app.other.test'
  Test-Condition 'visible but not allowed domain -> blocked, nothing written' ($oz.Count -eq 1 -and $oz[0].kind -eq 'blocked' -and $oz[0].summary -match 'not an allowed domain' -and -not $plan.Data.canApply -and (Get-Dns 'app.other.test').Count -eq 0) ($plan.Data.cloudflare | ConvertTo-Json -Depth 6 -Compress)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'Bad Name' @('bad.example.test') '127.0.0.1' 0 'public')
  Test-Condition 'invalid input -> validation errors, cannot apply' ($plan.Status -eq 200 -and -not $plan.Data.canApply -and @($plan.Data.traefik.issues | Where-Object { $_.Level -eq 'Error' }).Count -ge 2) (Short $plan)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'manual' @('manual.example.test') '10.10.0.17' 80 'access' @() $false)
  Test-Condition 'automation off -> manual Cloudflare steps, no API actions' ($plan.Data.canApply -and @($plan.Data.cloudflare.actions).Count -eq 0 -and @($plan.Data.cloudflare.manualSteps).Count -ge 3) (Short $plan)
  $r = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'badmail' @('m.example.test') '10.10.0.18' 80 'access' @('not-an-email'))
  Test-Condition 'malformed Access email rejected' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'rename'; name = 'plex' }
  Test-Condition 'unknown operation rejected' ($r.Status -eq 400) (Short $r)

  # --- Disable / enable / hostname change / remove -------------------------------------------------------------------------
  $c = Invoke-WebUiChange $ui @{ op = 'disable'; name = 'plex'; cloudflare = @{ automate = $true; cleanup = $false } }
  Test-Condition 'disable: route removed, Cloudflare untouched' ($c.Apply.Status -eq 200 -and @($c.Plan.Data.cloudflare.actions | Where-Object { $_.kind -ne 'none' }).Count -eq 0 -and
    -not (Test-Path (Join-Path $install 'traefik\dynamic\svc-plex.yml')) -and (Get-Dns 'plex.example.test').Count -eq 1) (Short $c.Apply)
  $c = Invoke-WebUiChange $ui @{ op = 'enable'; name = 'plex'; cloudflare = @{ automate = $true; cleanup = $false } }
  Test-Condition 'enable: route back, Cloudflare already in place (no changes)' ($c.Apply.Status -eq 200 -and (Test-Path (Join-Path $install 'traefik\dynamic\svc-plex.yml')) -and
    @($c.Plan.Data.cloudflare.actions | Where-Object { $_.kind -ne 'none' }).Count -eq 0) (Short $c.Plan)
  $upd = New-Body 'update' 'plex' @('media.example.test') '10.10.0.11' 32800 'access' @('owner@example.com')
  $c = Invoke-WebUiChange $ui $upd
  $kinds = (@($c.Plan.Data.cloudflare.actions | ForEach-Object { "$($_.id)=$($_.kind)" }) | Sort-Object) -join ','
  Test-Condition 'hostname change: new hostname published, old one cleaned up' ($c.Apply.Status -eq 200 -and $c.Apply.Data.ok -and
    (Get-Dns 'plex.example.test').Count -eq 0 -and (Get-Dns 'media.example.test').Count -eq 1 -and (Get-Apps 'plex.example.test').Count -eq 0 -and (Get-Apps 'media.example.test').Count -eq 1 -and
    @((Get-Ingress) | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq 'plex.example.test' }).Count -eq 0) $kinds
  $r = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'update' 'missing' @('x.example.test'))
  Test-Condition 'updating an unknown service -> 404' ($r.Status -eq 404) (Short $r)
  $c = Invoke-WebUiChange $ui @{ op = 'remove'; name = 'plex'; cloudflare = @{ automate = $true; cleanup = $true } }
  $state = Get-MockState $mock
  Test-Condition 'remove with cleanup: DNS, tunnel route and Access app (ours) deleted' ($c.Apply.Status -eq 200 -and (Get-Dns 'media.example.test').Count -eq 0 -and (Get-Apps 'media.example.test').Count -eq 0 -and
    @((Get-Ingress) | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq 'media.example.test' }).Count -eq 0) (Short $c.Apply)
  Test-Condition 'cleanup never touches resources it did not create' ((Get-Dns 'keep.example.test').Count -eq 1 -and (Get-Apps 'protected.example.test').Count -eq 1 -and
    @((Get-Ingress) | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq 'keep.example.test' }).Count -eq 1 -and (Get-Dns 'a-record.example.test').Count -eq 1) `
    ("keepDns=$((Get-Dns 'keep.example.test').Count) protectedApp=$((Get-Apps 'protected.example.test').Count) aRecord=$((Get-Dns 'a-record.example.test').Count) ingress=" + (((Get-Ingress) | ConvertTo-Json -Compress -Depth 5)))
  $c = Invoke-WebUiChange $ui @{ op = 'remove'; name = 'taken'; cloudflare = @{ automate = $true; cleanup = $false } }
  Test-Condition 'remove without cleanup leaves Cloudflare as is' ($c.Apply.Status -eq 200 -and @($c.Plan.Data.cloudflare.actions).Count -eq 0 -and (Get-Dns 'taken.example.test').Count -eq 1) (Short $c.Apply)

  # --- Validation, backups, logs ----------------------------------------------------------------------------------------
  $r = Invoke-WebUi $ui POST '/api/validate' @{ deep = $true }
  Test-Condition 'deep validation through the API' ($r.Status -eq 200 -and $r.Data.ok -and $null -ne $r.Data.deep) (Short $r)
  $r = Invoke-WebUi $ui GET '/api/backups'
  $backups = @($r.Data.backups)
  Test-Condition 'backups listed' ($r.Status -eq 200 -and $backups.Count -ge 5) "count $($backups.Count)"
  $target = @($backups | Where-Object { -not $_.restored -and -not $_.preRollback })[0].id
  $r = Invoke-WebUi $ui POST '/api/backups/preview' @{ id = $target }
  Test-Condition 'restore preview shows a diff' ($r.Status -eq 200 -and @($r.Data.changes).Count -ge 1) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/backups/restore' @{ id = $target }
  Test-Condition 'restore without confirm -> 400' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/backups/restore' @{ id = $target; confirm = $true }
  Test-Condition 'restore with confirm; current state saved first' ($r.Status -eq 200 -and $r.Data.savedCurrentAs -match 'pre-rollback') (Short $r)
  $r = Invoke-WebUi $ui POST '/api/backups/restore' @{ id = '..\..\Windows'; confirm = $true }
  Test-Condition 'restore of an unknown backup id -> 404' ($r.Status -eq 404) (Short $r)
  $r = Invoke-WebUi $ui GET '/api/logs?role=bogus'
  Test-Condition 'logs: unknown container rejected' ($r.Status -eq 400) (Short $r)
  $r = Invoke-WebUi $ui GET '/api/logs?role=traefik&tail=5'
  Test-Condition 'logs: instance container only (missing here)' ($r.Status -eq 200 -and $r.Data.Container -eq "tpx-webui-$id-traefik") (Short $r)
  $r = Invoke-WebUi $ui GET '/api/audit'
  Test-Condition 'audit log records applied changes' ($r.Status -eq 200 -and (@($r.Data.lines) -join "`n") -match 'apply ') (Short $r)

  # --- Secrets never leave the server --------------------------------------------------------------------------------------
  $leaks = @($ui.Bodies | Where-Object { $_ -and $_.Contains($apiToken) })
  Test-Condition "API token absent from all $($ui.Bodies.Count) responses" ($leaks.Count -eq 0)
  $tunnelSecret = 'bW9jay1zZWNyZXQtbm90LXJlYWwt'
  Test-Condition 'tunnel token absent from all responses' (@($ui.Bodies | Where-Object { $_ -and ($_.Contains($tunnelSecret) -or $_ -match 'eyJ[A-Za-z0-9_-]{40,}') }).Count -eq 0)
  $plainFiles = @(Get-ChildItem -LiteralPath $install -Recurse -File | Where-Object { $_.FullName -notlike '*\secrets\*' -and $_.Length -lt 5MB } |
      Where-Object { ([IO.File]::ReadAllText($_.FullName)).Contains($apiToken) })
  Test-Condition 'API token not written to any file in plaintext' ($plainFiles.Count -eq 0) (($plainFiles | ForEach-Object { $_.FullName }) -join ', ')
  $authOk = @(Get-MockRequests $mock | Where-Object { -not $_.authOk -and $_.path -ne '/client/v4/user/tokens/verify' -and $_.path -ne '/client/v4/accounts' -and $_.path -ne '/client/v4/zones' })
  Test-Condition 'every Cloudflare call carried the stored token' ($authOk.Count -eq 0) (($authOk | ForEach-Object { $_.path }) -join ', ')

  $r = Invoke-WebUi $ui POST '/api/cloudflare/token/delete' @{}
  Test-Condition 'token removal needs confirmation' ($r.Status -eq 400 -and (Test-Path $secretPath)) (Short $r)
  $r = Invoke-WebUi $ui POST '/api/cloudflare/token/delete' @{ confirm = $true }
  Test-Condition 'token removed on confirmation' ($r.Status -eq 200 -and -not (Test-Path $secretPath)) (Short $r)
  $plan = Invoke-WebUi $ui POST '/api/services/plan' (New-Body 'add' 'after' @('after.example.test') '10.10.0.19' 80 'access' @('a@example.com'))
  Test-Condition 'without a token, plans fall back to manual steps' ($plan.Status -eq 200 -and -not $plan.Data.cloudflare.connected -and @($plan.Data.cloudflare.manualSteps).Count -ge 1) (Short $plan)
} finally {
  Stop-TestServer $ui
  Stop-TestServer $mock
  $leftovers = @((Invoke-Docker ps -a --filter "name=tpx-webui-$id" --format '{{.Names}}').Output | Where-Object { $_ })
  Test-Condition 'no containers left behind' ($leftovers.Count -eq 0) ($leftovers -join ', ')
  if (-not $KeepFiles) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "Files kept in $work" }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
