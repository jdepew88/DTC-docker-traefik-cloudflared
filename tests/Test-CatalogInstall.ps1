#requires -version 5.1
<#
.SYNOPSIS
  Real, isolated installations of shipped App Catalog applications on a disposable proxy deployment: the complete
  lifecycle of each app, one at a time.

.DESCRIPTION
  A throwaway proxy deployment (own stack name, proxy network, ports and folder) is installed and started. For each
  application in -Apps, in order, with a memory check first:
    plan (host compatibility, Compose validation, modular file set) -> install -> health -> an application-specific
    functional check (its own API or log) -> network isolation (dependencies never on the shared proxy network) ->
    the stack description and plain `docker compose` with the complete file set -> stop / start -> an explicit Traefik
    file-provider route through the disposable Traefik (backend by Docker DNS name), the per-app routing view, route
    removal -> backup, data change, restore -> removal with its data.
  Optionally (-Cloudflare) the Cloudflare publication preview for one route against the mock API: DNS, tunnel route and
  Access are planned, the preview writes nothing, and an existing DNS record is reported as a conflict.
  Only images already on this PC are used unless -AllowPull is given. Every other container on the PC must keep its ID,
  start time and state; nothing outside the disposable deployment is touched.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-CatalogInstall.ps1 -Apps echo,uptime-kuma,diun,lldap -Cloudflare
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-CatalogInstall.ps1 -Apps rocketchat
#>
[CmdletBinding()]
param([string[]]$Apps = @('echo', 'uptime-kuma', 'diun', 'lldap', 'authelia'), [switch]$Cloudflare, [switch]$AllowPull, [string]$TunnelSubnet = '172.31.247.0/28', [int]$ReserveMB = 1200, [int]$MinDiskGB = 4)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# -Apps a,b,c arrives as one string through powershell -File.
$Apps = @($Apps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\AppCatalog.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
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
    if (-not $line -or $line.StartsWith($ExcludePrefix) -or $line -match '-validate-') { continue }
    $map[$line] = ((Invoke-Docker inspect $line --format '{{.Id}} {{.State.StartedAt}} {{.State.Status}}').Output -join '').Trim()
  }
  return $map
}
# HTTP on 127.0.0.1 until $Ok accepts the answer (connection errors count as "not yet").
function Wait-Http([int]$Port, [string]$Path, [scriptblock]$Ok, [int]$Seconds = 120, [string]$HostHeader = '', [string]$Method = 'GET', [string]$Body = '', [hashtable]$Headers = @{}) {
  $deadline = (Get-Date).AddSeconds($Seconds); $last = $null
  do {
    try {
      $a = @{ Port = $Port; Path = $Path; Method = $Method; Headers = $Headers; TimeoutMs = 15000 }
      if ($HostHeader) { $a.HostHeader = $HostHeader }
      if ($Body) { $a.Body = $Body }
      $last = Invoke-RawHttp @a
      if (& $Ok $last) { return [pscustomobject]@{ Ok = $true; Response = $last } }
    } catch { $last = [pscustomobject]@{ Status = 0; Body = $_.Exception.Message; Headers = @{} } }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)
  return [pscustomobject]@{ Ok = $false; Response = $last }
}
function Wait-Log([string]$Container, [string]$Pattern, [int]$Seconds = 120) {
  $deadline = (Get-Date).AddSeconds($Seconds); $text = ''
  do { $text = ((Invoke-Docker logs $Container).Output | Out-String); if ($text -match $Pattern) { return [pscustomobject]@{ Ok = $true; Text = $text } }; Start-Sleep -Seconds 4 } while ((Get-Date) -lt $deadline)
  return [pscustomobject]@{ Ok = $false; Text = $text }
}
function Get-ImagePresent([string]$Image) {
  $name, $digest = $Image.Split('@'); $repoName = $name -replace ':[^:/]+$', ''
  return ((Invoke-Docker image inspect "$repoName@$digest").ExitCode -eq 0)
}
function Get-Prop2($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}
function Get-FreeMemoryMB {
  $os = Get-CimInstance Win32_OperatingSystem
  return [int]($os.FreePhysicalMemory / 1024)
}

# Application-specific checks: each app's own API or log, beyond "the container runs".
function Test-AppFunction([string]$App, [string]$Project, [int]$Port, [string]$Folder) {
  switch ($App) {
    'echo' { $w = Wait-Http $Port '/' { param($r) $r.Status -eq 200 -and $r.Body -match 'Hostname:' } 60; return @($w.Ok, "HTTP $($w.Response.Status)") }
    'uptime-kuma' { $w = Wait-Http $Port '/api/entry-page' { param($r) $r.Status -eq 200 -and $r.Body -match '"type"' } 180; return @($w.Ok, "entry page: $($w.Response.Body)") }
    'lldap' {
      $pw = ((Get-Content -LiteralPath (Join-Path $Folder 'credentials.txt')) | Where-Object { $_ -match ':\s*\S+$' -and $_ -match 'password' } | ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() } | Select-Object -First 1)
      $w = Wait-Http $Port '/auth/simple/login' { param($r) $r.Status -eq 200 -and $r.Body -match '"token"' } 120 -Method 'POST' -Body (@{ username = 'admin'; password = $pw } | ConvertTo-Json -Compress) -Headers @{ 'Content-Type' = 'application/json' }
      return @($w.Ok, "administrator sign-in with the generated password: HTTP $($w.Response.Status)")
    }
    'authelia' { $w = Wait-Http $Port '/api/health' { param($r) $r.Status -eq 200 -and $r.Body -match 'OK' } 120; return @($w.Ok, "/api/health: $($w.Response.Body)") }
    'diun' {
      $l = Wait-Log "$Project-app" 'Found \d+ image' 240
      $bad = $l.Text -match '(?i)permission denied|forbidden|cannot connect to the docker daemon'
      return @(($l.Ok -and -not $bad), (($l.Text -split "`n" | Where-Object { $_ -match 'image|Cron|Diun|error' } | Select-Object -Last 4) -join ' | '))
    }
    'dispatcharr' { $w = Wait-Http $Port '/' { param($r) $r.Status -in 200, 302 } 300; return @($w.Ok, "HTTP $($w.Response.Status)") }
    'dispatcharr-modular' { $w = Wait-Http $Port '/' { param($r) $r.Status -in 200, 302 } 300; return @($w.Ok, "HTTP $($w.Response.Status)") }
    'rocketchat' { $w = Wait-Http $Port '/api/info' { param($r) $r.Status -eq 200 -and $r.Body -match '"success":\s*true' } 420; return @($w.Ok, "/api/info: $($w.Response.Body)") }
    'immich' { $w = Wait-Http $Port '/api/server/ping' { param($r) $r.Status -eq 200 -and $r.Body -match 'pong' } 420; return @($w.Ok, "/api/server/ping: $($w.Response.Body)") }
    'homepage' { $w = Wait-Http $Port '/' { param($r) $r.Status -eq 200 } 120 -HostHeader "127.0.0.1:$Port"; return @($w.Ok, "HTTP $($w.Response.Status) (allowed host 127.0.0.1:$Port)") }
    'whats-up-docker' { $w = Wait-Http $Port '/' { param($r) $r.Status -in 200, 302 } 120; return @($w.Ok, "HTTP $($w.Response.Status)") }
    'traefik-manager' { $w = Wait-Http $Port '/' { param($r) $r.Status -in 200, 302 } 120; return @($w.Ok, "HTTP $($w.Response.Status)") }
    'dozzle' {
      # The web interface answers and Dozzle reached Docker through the read-only socket proxy (no connection errors).
      $w = Wait-Http $Port '/' { param($r) $r.Status -eq 200 } 90
      $log = ((Invoke-Docker logs "$Project-app").Output -join "`n")
      return @(($w.Ok -and $log -notmatch '(?i)could not connect|connection refused|permission denied|forbidden'), "HTTP $($w.Response.Status); log: $((($log -split "`n") | Select-Object -Last 3) -join ' | ')")
    }
    'vaultwarden' { $w = Wait-Http $Port '/api/config' { param($r) $r.Status -eq 200 -and $r.Body -match '"version"' } 120; return @($w.Ok, "/api/config: HTTP $($w.Response.Status) $(if ($w.Response.Body -match '"version":"([^"]+)"') { "version $($Matches[1])" })") }
    'gitea' { $w = Wait-Http $Port '/api/healthz' { param($r) $r.Status -eq 200 -and $r.Body -match '"status":\s*"pass"' } 180; return @($w.Ok, "/api/healthz: $($w.Response.Body -replace '\s+', ' ')") }
    'n8n' { $w = Wait-Http $Port '/healthz' { param($r) $r.Status -eq 200 -and $r.Body -match 'ok' } 240; return @($w.Ok, "/healthz: $($w.Response.Body)") }
    'mealie' {
      # The documented default administrator exists until it is changed (the catalog tells the user to change it).
      $w = Wait-Http $Port '/api/app/about' { param($r) $r.Status -eq 200 -and $r.Body -match '"version"' } 240
      $login = Wait-Http $Port '/api/auth/token' { param($r) $r.Status -eq 200 -and $r.Body -match 'access_token' } 30 -Method 'POST' -Body 'username=changeme%40example.com&password=MyPassword' -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
      return @(($w.Ok -and $login.Ok), "/api/app/about: HTTP $($w.Response.Status); default administrator sign-in: HTTP $($login.Response.Status)")
    }
    'filebrowser' { $w = Wait-Http $Port '/health' { param($r) $r.Status -eq 200 -and $r.Body -match 'OK' } 90; return @($w.Ok, "/health: $($w.Response.Body)") }
    'hfs' {
      $pw = [string](Read-AppEnv (Join-Path $Folder '.env'))['HFS_INITIAL_ADMIN_PASSWORD']
      $w = Wait-Http $Port '/~/frontend/index.html' { param($r) $r.Status -eq 200 } 120
      $log = ((Invoke-Docker logs "$Project").Output -join "`n")
      return @(($w.Ok -and $pw.Length -ge 12 -and $log -notmatch '(?i)error'), "front end: HTTP $($w.Response.Status); log: $((($log -split "`n") | Select-Object -Last 2) -join ' | ')")
    }
    'pihole' {
      # Dashboard password from .env: the Pi-hole API accepts it.
      $pw = [string](Read-AppEnv (Join-Path $Folder '.env'))['FTLCONF_webserver_api_password']
      $w = Wait-Http $Port '/api/auth' { param($r) $r.Status -eq 200 -and $r.Body -match '"valid":\s*true' } 180 -Method 'POST' -Body (@{ password = $pw } | ConvertTo-Json -Compress) -Headers @{ 'Content-Type' = 'application/json' }
      return @($w.Ok, "/api/auth with the generated password: HTTP $($w.Response.Status)")
    }
    'openldap' {
      $env2 = Read-AppEnv (Join-Path $Folder '.env')
      $deadline = (Get-Date).AddSeconds(120); $r = $null
      do { $r = Invoke-Docker exec "$Project" ldapwhoami -x -H ldap://localhost -D 'cn=admin,dc=example,dc=com' -w ([string]$env2['LDAP_ADMIN_PASSWORD']); if ($r.ExitCode -eq 0) { break }; Start-Sleep -Seconds 3 } while ((Get-Date) -lt $deadline)
      return @(($r.ExitCode -eq 0 -and (($r.Output -join '') -match 'cn=admin')), "ldapwhoami as cn=admin: $((@($r.Output) -join ' ').Trim())")
    }
    'crowdsec' {
      $deadline = (Get-Date).AddSeconds(240); $r = $null
      do { $r = Invoke-Docker exec "$Project-app" cscli lapi status; if ($r.ExitCode -eq 0) { break }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline)
      $acq = Invoke-Docker exec "$Project-app" cscli metrics show acquisition
      return @(($r.ExitCode -eq 0), "cscli lapi status: exit $($r.ExitCode); acquisition: $((@($acq.Output) | Where-Object { $_ -match 'docker' } | Select-Object -First 2) -join ' | ')")
    }
    'jellyfin' { $w = Wait-Http $Port '/health' { param($r) $r.Status -eq 200 -and $r.Body -match 'Healthy' } 240; return @($w.Ok, "/health: $($w.Response.Body)") }
    'arcane' { $w = Wait-Http $Port '/' { param($r) $r.Status -in 200, 302 } 180; return @($w.Ok, "HTTP $($w.Response.Status)") }
    'channels-dvr' { $w = Wait-Http $Port '/' { param($r) $r.Status -in 200, 302 } 240; return @($w.Ok, "HTTP $($w.Response.Status)") }
    'plex' { $w = Wait-Http $Port '/identity' { param($r) $r.Status -eq 200 -and $r.Body -match 'MediaContainer' } 240; return @($w.Ok, "/identity: HTTP $($w.Response.Status)") }
    'nextcloud' { $w = Wait-Http $Port '/status.php' { param($r) $r.Status -eq 200 -and $r.Body -match '"installed":\s*true' } 600; return @($w.Ok, "/status.php: $($w.Response.Body)") }
    'paperless-ngx' {
      # The administrator from the installation form gets an API token (the web server, database and broker all work).
      $env2 = Read-AppEnv (Join-Path $Folder '.env')
      $body = 'username=' + [uri]::EscapeDataString([string]$env2['PAPERLESS_ADMIN_USER']) + '&password=' + [uri]::EscapeDataString([string]$env2['PAPERLESS_ADMIN_PASSWORD'])
      $w = Wait-Http $Port '/api/token/' { param($r) $r.Status -eq 200 -and $r.Body -match '"token"' } 420 -Method 'POST' -Body $body -Headers @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
      return @($w.Ok, "administrator API token: HTTP $($w.Response.Status)")
    }
    'romm' { $w = Wait-Http $Port '/api/heartbeat' { param($r) $r.Status -eq 200 } 300; return @($w.Ok, "/api/heartbeat: HTTP $($w.Response.Status)") }
    'mediafusion' { $w = Wait-Http $Port '/health' { param($r) $r.Status -eq 200 } 600; return @($w.Ok, "/health: HTTP $($w.Response.Status) $($w.Response.Body)") }
    default { return @($true, 'no app-specific check') }
  }
}

if (-not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'catalog installations' 'Docker engine not running'; exit 0 }
# Resource gate before anything is created: too little memory for the proxy deployment or too little room on the system
# drive (Docker Desktop's disk and %TEMP%) skips the run; it is reported as unverified, never forced.
$freeDiskGB = [math]::Round((Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1)
if ($freeDiskGB -lt $MinDiskGB) { Add-Result 'SKIP' 'catalog installations' "only $freeDiskGB GB free on $env:SystemDrive (needs $MinDiskGB GB)"; exit 0 }
if ((Get-FreeMemoryMB) -lt $ReserveMB + 300) { Add-Result 'SKIP' 'catalog installations' "only $(Get-FreeMemoryMB) MB memory free (needs $($ReserveMB + 300) MB for the proxy deployment and the reserve)"; exit 0 }

$catalog = @(Get-CatalogApps -CatalogDir (Join-Path $repo 'catalog') | Where-Object { -not @($_.errors).Count })
$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$stack = "tpx-ci-$id"; $network = "$stack-proxy"
# Earlier runs killed hard (out of memory, closed window) skip `finally`: remove what their dead owners left, then
# register this run's prefix so an interruption of this run is swept the same way (tests\Find-TestOrphans.ps1 lists them).
foreach ($orphanLine in (Invoke-TestOrphanSweep)) { Write-Host "  [orphans] $orphanLine" -ForegroundColor DarkYellow }
Register-TestRun -Prefix $stack -Suite 'Test-CatalogInstall'
$work = Join-Path ([IO.Path]::GetTempPath()) $stack
$installPath = Join-Path $work 'instance'
$appsRoot = Join-Path $work 'apps'
New-Item -ItemType Directory -Force -Path $appsRoot | Out-Null
$httpPort = Get-FreeTcpPort
$o = $TunnelSubnet.Split('/')[0].Split('.')
$envFile = Join-Path $work 'instance.env'
@("STACK_NAME=$stack", "TRAEFIK_HTTP_PORT=$httpPort", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$network", "TUNNEL_SUBNET=$TunnelSubnet",
  "TUNNEL_IP_RANGE=$($o[0]).$($o[1]).$($o[2]).$($o[3])/29", "CLOUDFLARED_IP=$($o[0]).$($o[1]).$($o[2]).$([int]$o[3] + 10)", 'TRAEFIK_LOG_LEVEL=INFO') | Set-Content -LiteralPath $envFile -Encoding ASCII
$before = Get-EngineSnapshot $stack
$installed = $false; $ui = $null; $mock = $null
$apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N')
$projects = @()
$observations = New-Object System.Collections.ArrayList
try {
  $install = Invoke-Ps (Join-Path $repo 'install.ps1') @('-InstallPath', $installPath, '-EnvFile', $envFile, '-Start')
  $installed = Test-Path -LiteralPath $installPath
  Test-Condition 'instance: disposable proxy deployment installed and started' ($install.ExitCode -eq 0) ($install.Text -split "`n" | Select-Object -Last 8 | Out-String)
  if ($install.ExitCode -ne 0) { throw 'Install failed.' }
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $installPath -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $null = Connect-WebUi $ui
  $traefikImage = (Get-StackSettings -InstallPath $installPath).TraefikImage

  if ($Cloudflare) {
    # Cloudflare publication preview against the mock API: token, one allowed domain, the existing remotely managed tunnel.
    $null = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = $apiToken }
    $null = Invoke-WebUi $ui POST '/api/cloudflare/domains' @{ zoneIds = @('zone00000000000000000000000000001') }
    $tn = Invoke-WebUi $ui GET '/api/cloudflare/tunnels'
    $t = @($tn.Data.tunnels | Where-Object { $_.remotelyManaged })[0]
    $acct = ([IO.File]::ReadAllText((Join-Path $installPath 'config\cloudflare.json')) | ConvertFrom-Json).accountId
    $sel = Invoke-WebUi $ui POST '/api/cloudflare/select' @{ accountId = $acct; tunnelId = $t.id }
    Test-Condition 'cloudflare (mock): token, allowed domain and the existing tunnel are configured' ($sel.Status -eq 200) $sel.Body
  }

  foreach ($app in $Apps) {
    $entry = @($catalog | Where-Object { $_.id -eq $app })[0]
    if (-not $entry -or -not $entry.manifest.installable) { Add-Result 'SKIP' "$app" 'not an installable catalog app'; continue }
    $m = $entry.manifest
    $missing = @($m.services.PSObject.Properties | Where-Object { -not (Get-ImagePresent $_.Value.image) } | ForEach-Object { $_.Name })
    if ($missing.Count -and -not $AllowPull) { Add-Result 'SKIP' "$app" "images not on this PC ($($missing -join ', ')); -AllowPull downloads them"; continue }
    $project = "$stack-$(if ($app.Length -gt 18) { $app.Substring(0, 15).TrimEnd('-') } else { $app })"; $folder = Join-Path $appsRoot $app; $projects += [pscustomobject]@{ project = $project; folder = $folder }
    $headless = [bool](Get-Prop2 $m.web 'headless' $false)
    $port = $(if ($headless) { 0 } else { Get-FreeTcpPort })
    $inputs = @{}
    # A disposable folder for apps that need one (shared files, media); never a real folder of this PC.
    $sample = Join-Path $work "folder-$app"; New-Item -ItemType Directory -Force -Path $sample | Out-Null
    switch ($app) { 'authelia' { $inputs = @{ domain = 'example.test'; adminEmail = 'admin@example.test' } } 'immich' { $inputs = @{ enableMl = 'false' } }
      'filebrowser' { $inputs = @{ rootFolder = $sample } } 'hfs' { $inputs = @{ shareFolder = $sample } } 'plex' { $inputs = @{ mediaFolder = $sample; lanAccess = 'false' } }
      'jellyfin' { $inputs = @{ mediaFolder = $sample } } 'channels-dvr' { $inputs = @{ recordingsFolder = $sample } } }
    # Memory of the services this installation runs (optional services switched off by an input are left out).
    $need = 0; $perService = $false
    foreach ($sp in $m.services.PSObject.Properties) {
      $w = [string](Get-Prop2 $sp.Value 'when' '')
      if ($w) { $def = [string](Get-Prop2 @($m.inputs | Where-Object { $_.id -eq $w })[0] 'default' 'false'); $on = $(if ($inputs.ContainsKey($w)) { $inputs[$w] } else { $def }); if ($on -ne 'true') { continue } }
      $r = Get-Prop2 $sp.Value 'resources' $null; if ($r) { $perService = $true; $need += [int](Get-Prop2 $r 'memoryMB' 0) }
    }
    if (-not $perService) { $need = [int](Get-Prop2 $m.resources 'memoryMB' 0) }
    if ($need + $ReserveMB -gt (Get-FreeMemoryMB)) { Add-Result 'SKIP' "$app" "needs about $need MB plus $ReserveMB MB reserve; $(Get-FreeMemoryMB) MB free"; continue }
    $t0 = Get-Date
    $plan = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = $app; project = $project; folder = $folder; localPort = $port; inputs = $inputs; startNow = $true }
    if ($plan.Status -ne 200) { Add-Result 'FAIL' "${app}: plan request" "HTTP $($plan.Status): $($plan.Body)"; continue }
    # The same application already installed on this PC (e.g. a production installation) blocks a silent duplicate; the
    # test then installs a deliberate, separate instance with its own project, folder, volumes and port.
    $dup = @($plan.Data.checks | Where-Object { $_.label -eq 'Not already installed' -and $_.state -eq 'failed' })[0]
    if ($dup) {
      Test-Condition "${app}: an existing installation on this PC blocks a silent second one" (-not $plan.Data.canApply -and $dup.message -match 'already installed') $dup.message
      $plan = Invoke-WebUi $ui POST '/api/catalog/plan' @{ appId = $app; project = $project; folder = $folder; localPort = $port; inputs = $inputs; startNow = $true; anotherInstance = $true; instanceLabel = 'Isolated test' }
    }
    $files = @($plan.Data.composeFiles | ForEach-Object { $_.file })
    $arch = @($plan.Data.checks | Where-Object { $_.label -eq 'CPU architecture' })[0]
    $cfg = @($plan.Data.checks | Where-Object { $_.label -eq 'docker compose config' })[0]
    Test-Condition "${app}: plan is valid (CPU architecture, docker compose config on $($files.Count) file(s), stack description)" ($plan.Status -eq 200 -and $plan.Data.canApply -and $arch.state -eq 'ok' -and $cfg.state -eq 'ok' -and $plan.Data.stack) (@($plan.Data.checks | Where-Object { $_.state -eq 'failed' } | ForEach-Object { "$($_.label): $($_.message)" }) -join ' | ')
    if (-not $plan.Data.canApply) { continue }
    $ap = Invoke-WebUi $ui POST '/api/catalog/apply' @{ planId = $plan.Data.planId; confirm = $true; confirmPrivileges = $true }
    $installSec = [int]((Get-Date) - $t0).TotalSeconds
    $httpOk = $headless -or ($ap.Data.health -and $ap.Data.health.http -and $ap.Data.health.http.result -in 'http', 'https')
    Test-Condition "${app}: installed and healthy ($installSec s)" ($ap.Status -eq 200 -and $ap.Data.ok -and $ap.Data.health.running -and $httpOk) (@($ap.Data.steps | ForEach-Object { "$($_.name): $($_.status) $($_.message)" }) -join ' | ')
    if (-not $ap.Data.ok) { continue }
    $fn = Test-AppFunction $app $project $port $folder
    Test-Condition "${app}: works (its own API or log)" ([bool]$fn[0]) ([string]$fn[1])
    # Network isolation: databases, caches and brokers only on the private network.
    $deps = @($plan.Data.stack.services | Where-Object { $_.role -in 'database', 'cache', 'messaging', 'support' })
    $leak = @(foreach ($d in $deps) { $nets = ((Invoke-Docker inspect $d.container --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}').Output -join ' '); if ($nets -match [regex]::Escape($network)) { $d.container } })
    $web = $plan.Data.stack.frontend
    $webNets = $(if (-not $headless) { ((Invoke-Docker inspect $web.container --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}').Output -join ' ') } else { '' })
    $webOnProxy = $webNets -match [regex]::Escape($network)
    Test-Condition "${app}: network isolation (dependencies private: $(@($deps | ForEach-Object { $_.name }) -join ', '); web front end on the shared network only when proxied)" ($leak.Count -eq 0 -and ($headless -or ($webOnProxy -eq [bool]$web.proxyNetwork))) "leaks: $($leak -join ', ') web: $webNets"
    # Stack files: the set on disk, COMPOSE_FILE for plain docker compose, dtc-stack.json without secrets.
    $stackJson = [IO.File]::ReadAllText((Join-Path $folder 'dtc-stack.json'))
    # The values of the variables the stack declares secret (generated or typed secrets); addresses such as the app's
    # own URL are configuration, not secrets, and do appear in dtc-stack.json (frontend.localUrl).
    $secretKeys = @($plan.Data.stack.envFile.secrets)
    $secrets = @((Read-AppEnv (Join-Path $folder '.env')).GetEnumerator() | Where-Object { $secretKeys -contains $_.Key -and ([string]$_.Value).Length -ge 6 } | ForEach-Object { [string]$_.Value })
    Push-Location $folder; try { $plain = @((Invoke-Docker compose ps --all --services).Output | Where-Object { $_ }) } finally { Pop-Location }
    $defined = @($plan.Data.stack.services | ForEach-Object { $_.name })
    Test-Condition "${app}: modular stack on disk ($($files -join ', ')); plain docker compose sees every service; dtc-stack.json holds no secret" (@($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $folder $_)) }).Count -eq 0 -and (@($plain | Sort-Object) -join ',') -eq (@($defined | Sort-Object) -join ',') -and -not @($secrets | Where-Object { $stackJson.Contains($_) }).Count) "plain: $($plain -join ',') defined: $($defined -join ',')"
    # Stop / start.
    $stop = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $project; action = 'stop'; confirm = $true }
    $stopped = @((Invoke-Docker ps --filter "label=com.docker.compose.project=$project" -q).Output | Where-Object { $_ }).Count
    $start = Invoke-WebUi $ui POST '/api/apps/action' @{ project = $project; action = 'start'; confirm = $true }
    $h2 = Invoke-WebUi $ui POST '/api/apps/health' @{ project = $project }
    Test-Condition "${app}: stop and start with the complete file set" ($stop.Data.ok -and $stopped -eq 0 -and $start.Data.ok -and $h2.Data.running) "stopped=$stopped $($start.Body)"
    # Traefik: an explicit file-provider route to the web container's Docker DNS name, through the disposable Traefik.
    if (-not $headless -and $web.proxyNetwork) {
      $hostName = "$app.example.test"
      $svc = @{ name = $app; hostnames = @($hostName); target = @{ type = 'docker'; host = $web.container; port = [int]$web.port; protocol = $web.scheme }; cloudflare = @{ publish = $false; access = $false }; middlewares = @('default-headers@file') }
      if ($web.scheme -eq 'https') { $svc.target.tlsSkipVerify = $true }
      $rt = Invoke-WebUiChange $ui @{ op = 'add'; name = $app; service = $svc; cloudflare = @{ automate = $false } }
      $via = Wait-Http $httpPort ([string](Get-Prop2 $m.web 'path' '/')) { param($r) $r.Status -gt 0 -and $r.Status -notin 404, 502, 503, 504 } 60 -HostHeader $hostName
      $sv = Invoke-WebUi $ui GET "/api/apps/stack?project=$project"
      $route = @($sv.Data.routing.routes | Where-Object { $_.name -eq $app })[0]
      $served = $route -and @($route.traefik | Where-Object { $_.served }).Count -ge 1
      Test-Condition "${app}: Traefik route (file provider, backend $($web.backendUrl)) answers through the disposable Traefik; the app's routing view shows router, service and that Traefik serves it" ($rt.Apply -and $rt.Apply.Data.ok -and $via.Ok -and $served -and @($route.routers).Count -ge 1 -and @($route.services).Count -ge 1 -and $route.loadedByFileProvider) "via Traefik: HTTP $($via.Response.Status); $(if ($rt.Apply) { $rt.Apply.Body.Substring(0, [Math]::Min(300, $rt.Apply.Body.Length)) } else { $rt.Plan.Body })"
      if ($Cloudflare -and $app -eq $Apps[0]) {
        # Publication preview: Access, tunnel route and DNS planned; nothing is written by a preview.
        $beforeReq = @(Get-MockRequests $mock).Count
        $pub = Invoke-WebUi $ui POST '/api/services/plan' @{ op = 'update'; name = $app; service = @{ name = $app; hostnames = @($hostName); target = $svc.target; cloudflare = @{ publish = $true; access = $true }; middlewares = @('default-headers@file') }; cloudflare = @{ automate = $true; accessEmails = @('owner@example.test') } }
        $writes = @(Get-MockRequests $mock | Select-Object -Skip $beforeReq | Where-Object { $_.method -ne 'GET' })
        $acts = (@($pub.Data.cloudflare.actions | ForEach-Object { "$($_.step):$($_.kind)" }) -join ',')
        Test-Condition "${app}: Cloudflare publication preview plans Access, the tunnel route and DNS on the existing tunnel; the preview writes nothing" ($pub.Status -eq 200 -and $acts -match 'access:create' -and $acts -match 'tunnel:create' -and $acts -match 'dns:create' -and $writes.Count -eq 0) "$acts writes=$($writes.Count)"
      }
      $null = Invoke-WebUiChange $ui @{ op = 'remove'; name = $app; cloudflare = @{ automate = $false } }
    }
    # Backup, change the data, restore: the data volume is back to the backup.
    $vol = @($plan.Data.stack.volumes | Where-Object { $_.type -eq 'volume' -and $_.backup })[0]
    if ($vol) {
      $null = Invoke-Docker run --rm --pull never --network none -v "$($vol.name):/v" --entrypoint sh $traefikImage -c 'echo before > /v/.dtc-test-marker'
      $bk = Invoke-WebUi $ui POST '/api/apps/backup' @{ project = $project; confirm = $true }
      $null = Invoke-Docker run --rm --pull never --network none -v "$($vol.name):/v" --entrypoint sh $traefikImage -c 'echo after > /v/.dtc-test-marker'
      $bid = $(if ($bk.Data.folder) { Split-Path -Leaf $bk.Data.folder } else { '' })
      $rp = Invoke-WebUi $ui POST '/api/apps/restore-data/plan' @{ project = $project; backup = $bid }
      $rr = Invoke-WebUi $ui POST '/api/apps/restore-data' @{ project = $project; backup = $bid; key = $rp.Data.key; confirm = $true }
      $marker = ((Invoke-Docker run --rm --pull never --network none -v "$($vol.name):/v:ro" --entrypoint cat $traefikImage /v/.dtc-test-marker).Output -join '').Trim()
      $h3 = Invoke-WebUi $ui POST '/api/apps/health' @{ project = $project }
      Test-Condition "${app}: backup, then restore of $($vol.name) (safety backup first); the app runs again" ($bk.Data.ok -and $rr.Status -eq 200 -and $rr.Data.ok -and $marker -eq 'before' -and $h3.Data.running) "marker=$marker $($rr.Body)"
      $fn2 = Test-AppFunction $app $project $port $folder
      Test-Condition "${app}: still works after the restore" ([bool]$fn2[0]) ([string]$fn2[1])
    }
    # Resource use while running.
    $mem = @((Invoke-Docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}').Output | Where-Object { $_ -like "$project*" })
    $null = $observations.Add("${app}: install $installSec s; memory $(@($mem | ForEach-Object { ($_ -split '\|')[0] + ' ' + (($_ -split '\|')[1] -split '/')[0].Trim() }) -join ', ')")
    # Removal with its data.
    $rm = Invoke-WebUi $ui POST '/api/apps/remove' @{ project = $project; confirm = $true; deleteVolumes = $true; deleteFolder = $true; confirmText = $project }
    $leftC = @((Invoke-Docker ps -a -q --filter "label=com.docker.compose.project=$project").Output | Where-Object { $_ })
    $leftV = @((Invoke-Docker volume ls -q --filter "name=${project}_").Output | Where-Object { $_ })
    $leftF = @($files | Where-Object { Test-Path -LiteralPath (Join-Path $folder $_) })
    Test-Condition "${app}: removed with its data (containers, volumes, every Compose file)$(if ($vol) { '; backups stay' })" ($rm.Status -eq 200 -and -not $leftC.Count -and -not $leftV.Count -and -not $leftF.Count -and (-not $vol -or (Test-Path -LiteralPath (Join-Path $folder 'backups')))) "containers=$($leftC.Count) volumes=$($leftV -join ',') files=$($leftF -join ',')"
  }
} catch {
  Add-Result 'FAIL' 'catalog installation run' ($_.Exception.Message + ' ' + $_.ScriptStackTrace)
} finally {
  Stop-TestServer $ui; Stop-TestServer $mock
  foreach ($p in $projects) {
    foreach ($c in @((Invoke-Docker ps -a -q --filter "label=com.docker.compose.project=$($p.project)").Output | Where-Object { $_ })) { $null = Invoke-Docker rm -f $c }
    foreach ($v in @((Invoke-Docker volume ls -q --filter "name=$($p.project)_").Output | Where-Object { $_ })) { $null = Invoke-Docker volume rm $v }
    foreach ($n in @((Invoke-Docker network ls -q --filter "name=$($p.project)_").Output | Where-Object { $_ })) { $null = Invoke-Docker network rm $n }
  }
  if ($installed) { $null = Invoke-Ps (Join-Path $installPath 'install.ps1') @('-InstallPath', $installPath, '-Stop') }
  $null = Invoke-Docker network rm $network
  $left = @((Invoke-Docker ps -a --filter "name=$stack" --format '{{.Names}}').Output | Where-Object { $_ })
  $leftVols = @((Invoke-Docker volume ls -q --filter "name=$stack").Output | Where-Object { $_ })
  $leftNets = @((Invoke-Docker network ls --filter "name=$stack" --format '{{.Name}}').Output | Where-Object { $_ })
  Test-Condition 'teardown: no disposable containers, volumes or networks left' ($left.Count -eq 0 -and $leftVols.Count -eq 0 -and $leftNets.Count -eq 0) (($left + $leftVols + $leftNets) -join ', ')
  $after = Get-EngineSnapshot $stack
  $changed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) -or $after[$_] -ne $before[$_] })
  $added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
  Test-Condition "other containers untouched ($($before.Count) checked: same IDs, start times, states)" ($changed.Count -eq 0 -and $added.Count -eq 0) ("changed: $($changed -join ', ') added: $($added -join ', ')")
  Get-ChildItem -LiteralPath $work -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  $orphaned = @(Complete-TestRun $stack)
  Test-Condition 'teardown: nothing with this run''s prefix is left (containers, volumes, networks, folder)' ($orphaned.Count -eq 0) ($orphaned -join ', ')
}

if ($observations.Count) { Write-Host ''; Write-Host 'Observations:'; $observations | ForEach-Object { Write-Host "  $_" } }
$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
