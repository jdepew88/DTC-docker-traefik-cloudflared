# Cloudflare Tunnel onboarding wizard. Dot-sourced by install.ps1 (-Wizard / -AddApp); relies on its
# helpers: Invoke-Docker, Invoke-Change, Write-Step/Note/Warn, Get-ComposeArgs, $InstallPath, $ports.
#
# Never prints or logs the tunnel token. Non-secret answers are kept in tunnel.json so -AddApp can reuse
# them; the token lives only in secrets\cloudflare_tunnel_token.

$HostnamePattern = '^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
$LabelPattern = '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
$TokenPattern = 'eyJ[A-Za-z0-9_\-=+/]{40,}'
$ZeroTrustUrl = 'https://one.dash.cloudflare.com/'
$StackContainers = @('traefik', 'socket-proxy', 'cloudflared', 'whoami-test')

# --- Prompts --------------------------------------------------------------------------------------
function Read-Answer([string]$Prompt, [string]$Default, [string]$Pattern, [string]$Hint) {
  while ($true) {
    $label = '    ' + $Prompt
    if ($Default) { $label += " [$Default]" }
    $answer = ([string](Read-Host $label)).Trim()
    if (-not $answer) { $answer = $Default }
    if ($answer -and (-not $Pattern -or $answer -match $Pattern)) { return $answer }
    Write-Warn ('Invalid value. ' + $Hint)
  }
}

function Read-YesNo([string]$Prompt, [bool]$Default) {
  $suffix = '[y/N]'
  if ($Default) { $suffix = '[Y/n]' }
  while ($true) {
    $answer = ([string](Read-Host ("    $Prompt $suffix"))).Trim().ToLowerInvariant()
    if (-not $answer) { return $Default }
    if ($answer -in @('y', 'yes')) { return $true }
    if ($answer -in @('n', 'no')) { return $false }
  }
}

function Read-Choice([string]$Prompt, [string[]]$Options, [int]$Default) {
  for ($i = 0; $i -lt $Options.Count; $i++) { Write-Note ('  {0}) {1}' -f ($i + 1), $Options[$i]) }
  $answer = Read-Answer $Prompt ([string]$Default) ('^[1-' + $Options.Count + ']$') "Enter 1-$($Options.Count)."
  return [int]$answer
}

function Wait-Enter([string]$Prompt) { $null = Read-Host ('    ' + $Prompt + ' - press Enter when done') }

function Write-Instructions([string]$Title, [string[]]$Lines) {
  Write-Host ''
  Write-Host "    --- $Title ---" -ForegroundColor Green
  foreach ($line in $Lines) { Write-Host "    $line" }
  Write-Host ''
}

# --- State (no secrets) -------------------------------------------------------------------------------
function Get-WizardState {
  $path = Join-Path $InstallPath 'tunnel.json'
  if (Test-Path -LiteralPath $path) {
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if (-not $state.PSObject.Properties['apps'] -or $null -eq $state.apps) { $state | Add-Member -NotePropertyName apps -NotePropertyValue @() -Force }
    return $state
  }
  return [pscustomobject]@{ domain = ''; tunnelName = ''; tunnelId = ''; configuredAt = ''; apps = @() }
}

function Save-WizardState($State) {
  $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $InstallPath 'tunnel.json') -Encoding ASCII
}

# --- Token --------------------------------------------------------------------------------------------
# A tunnel token is base64(JSON {"a": account tag, "t": tunnel id, "s": secret}). Only a and t are returned.
function ConvertFrom-TunnelToken([string]$Token) {
  try {
    $b64 = $Token.Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    if ($json.PSObject.Properties['t'] -and $json.PSObject.Properties['s']) {
      return [pscustomobject]@{ AccountTag = [string]$json.a; TunnelId = [string]$json.t }
    }
  } catch { }
  return $null
}

# Returns the name of another container already running a connector for this tunnel, if any.
# Tokens of other containers are compared in memory only and never printed.
function Find-ConnectorForTunnel([string]$TunnelId) {
  foreach ($line in (Invoke-Docker ps -a --format '{{.Names}}|{{.Image}}').Output) {
    $parts = $line.Split('|')
    if ($parts.Count -lt 2 -or $parts[1] -notmatch 'cloudflared' -or $parts[0] -eq 'cloudflared') { continue }
    $config = (Invoke-Docker inspect $parts[0] --format '{{json .Config.Cmd}} {{json .Config.Env}}').Output -join ' '
    foreach ($match in [regex]::Matches($config, $TokenPattern)) {
      $decoded = ConvertFrom-TunnelToken $match.Value
      if ($decoded -and $decoded.TunnelId -eq $TunnelId) { return $parts[0] }
    }
  }
  return $null
}

function Read-TunnelToken {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $secure = Read-Host -AsSecureString -Prompt '    Paste the token or the whole docker command (input hidden)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $match = [regex]::Match([string]$plain, $TokenPattern)
    $plain = $null
    if ($match.Success) {
      $decoded = ConvertFrom-TunnelToken $match.Value
      if ($decoded) { return [pscustomobject]@{ Token = $match.Value; TunnelId = $decoded.TunnelId } }
    }
    Write-Warn 'That is not a valid tunnel token (a long string starting with eyJ). Try again.'
  }
  throw 'No valid tunnel token entered.'
}

function Save-TunnelToken([string]$Token) {
  $tokenPath = Join-Path $InstallPath 'secrets\cloudflare_tunnel_token'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tokenPath) | Out-Null
  if (Test-Path -LiteralPath $tokenPath) {
    $saveTo = Join-Path $InstallPath ('backups\' + $Timestamp + '\secrets\cloudflare_tunnel_token')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saveTo) | Out-Null
    Copy-Item -LiteralPath $tokenPath -Destination $saveTo
  }
  [IO.File]::WriteAllText($tokenPath, $Token)
  $null = & icacls $tokenPath /inheritance:r /grant:r "${env:USERNAME}:(R,W)" '*S-1-5-18:(R)' '*S-1-5-32-544:(R)'
  Write-Note 'Saved to secrets\cloudflare_tunnel_token (readable by you, SYSTEM and Administrators only).'
}

# --- Stack ----------------------------------------------------------------------------------------------
function Start-TunnelStack([switch]$Recreate) {
  $upArgs = (Get-ComposeArgs) + @('--profile', 'tunnel', 'up', '-d', '--wait', '--wait-timeout', '120')
  if ($Recreate) { $upArgs += @('--force-recreate', 'cloudflared') }
  $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $up = Invoke-Docker @upArgs
  if ($up.ExitCode -ne 0) {
    $up.Output | Select-Object -Last 10 | ForEach-Object { Write-Note $_ }
    $logs = (Invoke-Docker logs --tail 30 cloudflared).Output -join "`n"
    if ($logs -match 'Unauthorized|invalid token|tunnel credentials') { throw 'cloudflared rejected the token. Copy it again from the Cloudflare dashboard and re-run the wizard.' }
    throw 'Starting cloudflared failed. See: docker compose logs --tail=100 cloudflared'
  }
  $deadline = (Get-Date).AddSeconds(60)
  do {
    $logs = (Invoke-Docker logs --since $since cloudflared).Output -join "`n"
    $connections = [regex]::Matches($logs, 'Registered tunnel connection').Count
    if ($connections -ge 1) { break }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  if ($connections -lt 1) { throw 'cloudflared started but registered no tunnel connections within 60 s. Check: docker logs cloudflared' }
  $locations = ([regex]::Matches($logs, 'location=(\S+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ', '
  Write-Note "cloudflared connected: $connections connection(s) to Cloudflare ($locations)."
}

# --- Routes ---------------------------------------------------------------------------------------------
# Docker Desktop does not forward file-change events from Windows paths into the Linux VM, so Traefik's
# file provider never notices edits made on Windows. Touching a file from a container inside the VM does
# raise the event, and Traefik reloads traefik\dynamic\ without a restart.
function Sync-TraefikDynamic {
  $dir = Join-Path $InstallPath 'traefik\dynamic'
  $r = Invoke-Docker run --rm --network none -v "${dir}:/d" --entrypoint sh $TraefikImage -c 'touch /d/.reload'
  if ($r.ExitCode -ne 0) { Write-Warn ('Could not trigger a Traefik reload: ' + ($r.Output -join ' ') + ' - run: docker restart traefik') }
}

function Get-HostSlug([string]$Hostname) { return ($Hostname.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }

function Get-TraefikRouters {
  # PS 5.1 Invoke-RestMethod emits a JSON array as ONE object; returning the variable unrolls it.
  try { $routers = Invoke-RestMethod -TimeoutSec 5 ("http://127.0.0.1:{0}/api/http/routers" -f $ports['TRAEFIK_DASHBOARD_PORT']) } catch { return }
  return $routers
}

function Get-RoutersForHost([string]$Hostname) {
  $needle = 'Host(`' + $Hostname + '`)'
  return @(Get-TraefikRouters | Where-Object { $_.rule -and $_.rule.Contains($needle) })
}

function Connect-ProxyNetwork([string]$Container) {
  $c = Invoke-Docker inspect $Container --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
  if ($c.ExitCode -ne 0) { throw "Container '$Container' not found." }
  if (($c.Output[-1] -split '\s+') -contains $ProxyNetwork) { Write-Note "$Container is already on '$ProxyNetwork'."; return }
  $r = Invoke-Docker network connect $ProxyNetwork $Container
  if ($r.ExitCode -ne 0) { throw ('docker network connect failed: ' + ($r.Output -join ' ')) }
  Write-Note "Attached $Container to '$ProxyNetwork' (live, no restart). Add the network to its Compose file too so it persists on recreate (see README)."
}

function Select-Container {
  $rows = @()
  foreach ($line in (Invoke-Docker ps --format '{{.Names}}|{{.Ports}}').Output) {
    $parts = $line.Split('|')
    if ($StackContainers -contains $parts[0]) { continue }
    $internal = @([regex]::Matches($parts[1], '(?:->)?(\d+)/tcp') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $rows += [pscustomobject]@{ Name = $parts[0]; Ports = $internal }
  }
  if ($rows.Count -eq 0) { throw 'No running containers found. Start the app first.' }
  $labels = @($rows | ForEach-Object { '{0}  (container ports: {1})' -f $_.Name, (($_.Ports | Where-Object { $_ }) -join ', ') })
  $index = Read-Choice 'Container' $labels 1
  return $rows[$index - 1]
}

function Write-AppRoute([string]$Hostname, [string]$Url, [string]$Description) {
  $slug = Get-HostSlug $Hostname
  $file = Join-Path $InstallPath ("traefik\dynamic\app-$slug.yml")
  if (Test-Path -LiteralPath $file) { Write-Note "traefik\dynamic\app-$slug.yml already exists; keeping it."; return "app-$slug.yml" }
  $content = @"
# Generated by install.ps1 (tunnel wizard) on $(Get-Date -Format 'yyyy-MM-dd'). $Description
# Edit freely; the installer never overwrites this file. Delete it to remove the route.
http:
  routers:
    app-${slug}:
      rule: Host(``$Hostname``)
      entryPoints: [web]
      middlewares: [default-headers@file]
      service: app-${slug}
  services:
    app-${slug}:
      loadBalancer:
        servers:
          - url: $Url
"@
  [IO.File]::WriteAllText($file, $content.Replace("`r`n", "`n") + "`n")
  Sync-TraefikDynamic
  Write-Note "Wrote traefik\dynamic\app-$slug.yml -> $Url"
  return "app-$slug.yml"
}

# Asks what serves the hostname, writes the route and returns a description of the target.
function Set-AppRoute([string]$Hostname, [string]$AppTarget) {
  $existing = @(Get-RoutersForHost $Hostname)
  if (-not $AppTarget -and $existing.Count -gt 0) {
    Write-Note ('Traefik already routes this hostname: ' + (($existing | ForEach-Object { $_.name }) -join ', '))
    if (Read-YesNo 'Keep the existing route?' $true) { return 'existing:' + (($existing | ForEach-Object { $_.name }) -join ',') }
  }
  if (-not $AppTarget) {
    Write-Note 'What serves this hostname?'
    $choice = Read-Choice 'Backend' @(
      'A Docker container on this PC (reached by container name over the proxy network)',
      'An app running directly on Windows (reached via host.docker.internal)',
      'Preset: OmniVoice Studio (UI on Windows :8010 + omnivoice-triton-api + omnivoice-perform-api)'
    ) 1
    switch ($choice) {
      1 {
        $picked = Select-Container
        $defaultPort = ''
        if (@($picked.Ports).Count -ge 1) { $defaultPort = [string]@($picked.Ports)[0] }
        $port = Read-Answer 'Port the app listens on INSIDE the container' $defaultPort '^\d{1,5}$' 'Enter a port number.'
        $AppTarget = "container:$($picked.Name):$port"
      }
      2 {
        $port = Read-Answer 'Windows port the app listens on (must listen on 0.0.0.0, firewall must allow it)' '' '^\d{1,5}$' 'Enter a port number.'
        $AppTarget = "windows:$port"
      }
      3 { $AppTarget = 'preset:omnivoice' }
    }
  }
  if ($AppTarget -match '^container:([A-Za-z0-9_.-]+):(\d{1,5})$') {
    $name = $Matches[1]; $port = $Matches[2]
    Connect-ProxyNetwork $name
    $null = Write-AppRoute $Hostname "http://${name}:$port" "Container $name, port $port."
  } elseif ($AppTarget -match '^windows:(\d{1,5})$') {
    $null = Write-AppRoute $Hostname "http://host.docker.internal:$($Matches[1])" "Windows app on port $($Matches[1])."
  } elseif ($AppTarget -eq 'preset:omnivoice') {
    $file = Join-Path $InstallPath 'traefik\dynamic\omnivoice.yml'
    if (Test-Path -LiteralPath $file) {
      if ((Get-Content -LiteralPath $file -Raw) -notmatch [regex]::Escape('Host(`' + $Hostname + '`)')) {
        throw "traefik\dynamic\omnivoice.yml exists for a different hostname. Edit or remove it first."
      }
      Write-Note 'traefik\dynamic\omnivoice.yml already routes this hostname; keeping it.'
    } else {
      $template = Get-Content -LiteralPath (Join-Path $InstallPath 'examples\omnivoice.dynamic.yml.example') -Raw
      [IO.File]::WriteAllText($file, $template.Replace('voice.example.com', $Hostname))
      Sync-TraefikDynamic
      Write-Note 'Wrote traefik\dynamic\omnivoice.yml'
    }
    foreach ($name in @('omnivoice-triton-api', 'omnivoice-perform-api')) {
      try { Connect-ProxyNetwork $name } catch { Write-Warn $_.Exception.Message }
    }
  } elseif ($AppTarget -notmatch '^existing') {
    throw "Unknown -AppTarget '$AppTarget'. Use container:<name>:<port>, windows:<port>, preset:omnivoice or existing."
  }
  return $AppTarget
}

function Test-LocalRoute([string]$Hostname) {
  $deadline = (Get-Date).AddSeconds(15)
  do {
    Start-Sleep -Seconds 1
    $routers = @(Get-RoutersForHost $Hostname)
  } while ($routers.Count -eq 0 -and (Get-Date) -lt $deadline)
  if ($routers.Count -eq 0) { throw "Traefik has no router for $Hostname. Check traefik\dynamic\ and docker logs traefik." }
  $code = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -H "Host: $Hostname" ("http://127.0.0.1:{0}/" -f $ports['TRAEFIK_HTTP_PORT'])) | Out-String
  $code = $code.Trim()
  if ($code -eq '502' -or $code -eq '504' -or $code -eq '000') {
    Write-Warn "Traefik matched the route but the backend did not answer (HTTP $code). Is the app running and listening on that port?"
    return $false
  }
  Write-Note "Local check: http://127.0.0.1:$($ports['TRAEFIK_HTTP_PORT'])/ with Host: $Hostname -> HTTP $code via $(($routers | ForEach-Object { $_.name }) -join ', ')"
  return $true
}

# --- Public check -------------------------------------------------------------------------------------
function Test-PublicHostname([string]$Hostname) {
  $routerNames = @(Get-RoutersForHost $Hostname | ForEach-Object { ($_.name -split '@')[0] })
  $resolveArgs = @()
  try {
    # Ask Cloudflare's resolver directly so a stale negative answer in the Windows DNS cache does not interfere.
    $record = Resolve-DnsName -Name $Hostname -Server 1.1.1.1 -DnsOnly -Type A -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if ($record) { $resolveArgs = @('--resolve', ("{0}:443:{1}" -f $Hostname, $record.IPAddress)) }
  } catch { }
  if ($resolveArgs.Count -eq 0) { Write-Warn "$Hostname does not resolve yet; DNS can take a minute after adding the route." }

  for ($attempt = 1; $attempt -le 12; $attempt++) {
    $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
    $headerFile = [IO.Path]::GetTempFileName()
    try {
      $code = ((& curl.exe -s -o NUL -D $headerFile -w '%{http_code}' --max-time 20 @resolveArgs "https://$Hostname/") | Out-String).Trim()
      $headers = Get-Content -LiteralPath $headerFile -Raw -ErrorAction SilentlyContinue
    } finally { Remove-Item -LiteralPath $headerFile -ErrorAction SilentlyContinue }
    if (-not $headers) { $headers = '' }
    if ($code -match '^30[1237]$' -and $headers -match '(?im)^location:.*cloudflareaccess\.com') {
      Write-Note "https://$Hostname -> HTTP $code redirect to the Cloudflare Access login: Access is protecting the app."
      return 'access'
    }
    Start-Sleep -Seconds 1
    $traefikLog = (Invoke-Docker logs --since $since traefik).Output -join "`n"
    $reached = $false
    foreach ($router in $routerNames) { if ($traefikLog.Contains('"' + $router + '@')) { $reached = $true } }
    if ($reached) {
      Write-Note "https://$Hostname -> HTTP $code, served through the tunnel by Traefik router $($routerNames -join '/')."
      if ($code -eq '502' -or $code -eq '504') { Write-Warn 'Traefik was reached but the backend did not answer. Start the app and test again.' }
      return 'ok'
    }
    $why = switch -regex ($code) {
      '^530$' { 'Cloudflare cannot reach a connector for this hostname (route missing or on another tunnel)' }
      '^404$' { 'request did not match a Traefik router (check the hostname in the route)' }
      '^000$' { 'no response (DNS not ready or connection timed out)' }
      default { "HTTP $code, but the request did not reach this Traefik" }
    }
    Write-Note ("Attempt {0}/12: {1}; retrying in 5 s..." -f $attempt, $why)
    Start-Sleep -Seconds 5
  }
  return 'fail'
}

# Watches the Traefik access log for a request on one of the hostname's routers whose client address is
# public. Only cloudflared is trusted to set X-Forwarded-For (traefik.yml), so a public client IP proves the
# request came through the tunnel; local tests show up as private Docker gateway addresses.
function Wait-TunnelRequest([string]$Hostname, [int]$Seconds) {
  $routerNames = @(Get-RoutersForHost $Hostname | ForEach-Object { ($_.name -split '@')[0] })
  $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    foreach ($line in (Invoke-Docker logs --since $since traefik).Output) {
      if ($line -notmatch '^(\S+) .*"(GET|POST|HEAD|PUT|PATCH|DELETE|OPTIONS) [^"]*" (\d{3}) .*"([^"@]+)@') { continue }
      $client = $Matches[1]; $status = $Matches[3]; $router = $Matches[4]
      if ($routerNames -notcontains $router) { continue }
      if ($client -match '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1$|fd|fe80)') { continue }
      Write-Note "Seen in Traefik: request from $client via router $router -> HTTP $status. Tunnel -> Traefik -> app works."
      return $true
    }
  }
  return $false
}

# --- Wizard -------------------------------------------------------------------------------------------
function Invoke-TunnelWizard([switch]$AddAppOnly, [string]$Domain, [string]$TunnelName, [string]$AppHostname, [string]$AppTarget, [switch]$LocalOnly) {
  $state = Get-WizardState
  $tokenPath = Join-Path $InstallPath 'secrets\cloudflare_tunnel_token'
  $haveTunnel = (Test-Path -LiteralPath $tokenPath) -and $state.tunnelId
  if ($AddAppOnly -and -not $haveTunnel) { throw 'No tunnel configured yet. Run .\install.ps1 -Wizard first.' }

  Write-Step 'Cloudflare Tunnel wizard'
  Write-Note 'Public HTTPS ends at Cloudflare; cloudflared carries requests to Traefik (http://traefik:80),'
  Write-Note 'and Traefik routes each hostname to its app. No router port forwarding is needed.'

  # 1. Questions
  Write-Step 'Step 1 - Questions'
  if (-not $Domain) { $Domain = Read-Answer 'Your Cloudflare domain (zone), e.g. example.com' $state.domain $HostnamePattern 'Enter a domain like example.com.' }
  $Domain = $Domain.ToLowerInvariant()
  $replaceTunnel = $false
  if ($haveTunnel -and -not $AddAppOnly) {
    Write-Note "A tunnel is already configured: '$($state.tunnelName)' ($($state.tunnelId))."
    $replaceTunnel = Read-YesNo 'Replace it with a different tunnel token? (No = keep it and just add an app)' $false
  }
  $newTunnel = (-not $haveTunnel) -or $replaceTunnel
  if ($newTunnel -and -not $TunnelName) {
    $TunnelName = Read-Answer 'Name for the new tunnel' ('traefik-' + $env:COMPUTERNAME.ToLowerInvariant()) $LabelPattern 'Letters, digits and dashes.'
  }
  if (-not $AppHostname) {
    $sub = Read-Answer "Application hostname: subdomain of $Domain (or a full hostname)" 'app' '^[A-Za-z0-9.-]+$' 'Letters, digits, dots and dashes.'
    if ($sub.ToLowerInvariant().EndsWith('.' + $Domain) -or $sub.ToLowerInvariant() -eq $Domain) { $AppHostname = $sub } else { $AppHostname = "$sub.$Domain" }
  }
  $AppHostname = $AppHostname.ToLowerInvariant()
  if ($AppHostname -notmatch $HostnamePattern -or -not ($AppHostname.EndsWith('.' + $Domain) -or $AppHostname -eq $Domain)) { throw "$AppHostname is not a hostname in $Domain." }
  $subdomain = ''
  if ($AppHostname -ne $Domain) { $subdomain = $AppHostname.Substring(0, $AppHostname.Length - $Domain.Length - 1) }
  $useAccess = $false
  if (-not $LocalOnly) { $useAccess = Read-YesNo "Protect $AppHostname with a Cloudflare Access login? (strongly recommended unless the app has its own login)" $true }

  # 2-4. Tunnel
  if ($newTunnel) {
    Write-Step 'Step 2 - Create the tunnel in Cloudflare'
    Write-Instructions 'In your browser' @(
      "1. Open the Cloudflare Zero Trust dashboard: $ZeroTrustUrl",
      '   (pick your account; the first visit may ask you to choose a free Zero Trust plan/team name).',
      '2. Go to Networks > Tunnels (newer layouts: Networks > Connectors > Cloudflare Tunnels).',
      '3. Click "Create a tunnel", choose "Cloudflared", then Next.',
      "4. Tunnel name: $TunnelName   then click Save tunnel.",
      '5. On "Install and run a connector", choose the Docker environment.',
      '   Do NOT run the docker command it shows; this installer runs cloudflared for you',
      '   (pinned version, token kept in a protected file instead of the command line).',
      '6. Click the copy button next to the command: it contains the token (starts with eyJ...).',
      '   Keep the browser tab open - you will come back to it.'
    )
    if (Read-YesNo 'Open the Zero Trust dashboard in your browser now?' $true) { Start-Process $ZeroTrustUrl }
    Wait-Enter 'Create the tunnel and copy the docker command'

    Write-Step 'Step 3 - Tunnel token'
    Write-Note 'Where to find it later: Networks > Tunnels > (your tunnel) > Configure, Docker tab.'
    Write-Note 'Anyone with this token can run your tunnel: never share it or commit it.'
    $entered = Read-TunnelToken
    Write-Note "Token is valid for tunnel ID $($entered.TunnelId)."
    $other = Find-ConnectorForTunnel $entered.TunnelId
    if ($other) {
      throw "Container '$other' already runs a connector for this same tunnel. Create a NEW tunnel for this stack so the two are not load-balanced together; '$other' was left untouched."
    }
    Save-TunnelToken $entered.Token
    $state.domain = $Domain
    $state.tunnelName = $TunnelName
    $state.tunnelId = $entered.TunnelId
    $state.configuredAt = (Get-Date -Format 's')
    $entered = $null
    Save-WizardState $state

    Write-Step 'Step 4 - Start cloudflared'
    Start-TunnelStack -Recreate
    Write-Note 'In the dashboard the tunnel status should now show HEALTHY. Click Next to reach the routing step.'
  } else {
    Write-Step "Using existing tunnel '$($state.tunnelName)'"
    $running = ((Invoke-Docker inspect cloudflared --format '{{.State.Running}}').Output -join '').Trim()
    if ($running -ne 'true') { Start-TunnelStack } else { Write-Note 'cloudflared is running.' }
    if (-not $state.domain) { $state.domain = $Domain; Save-WizardState $state }
  }

  # 5. Traefik route
  Write-Step "Step 5 - Route $AppHostname in Traefik"
  $target = Set-AppRoute $AppHostname $AppTarget
  $localOk = Test-LocalRoute $AppHostname

  $result = 'local-only'
  if (-not $LocalOnly) {
    # 6. Access
    if ($useAccess) {
      Write-Step 'Step 6 - Cloudflare Access (do this BEFORE publishing the hostname)'
      Write-Instructions 'In the Zero Trust dashboard' @(
        '1. Access > Applications (newer layouts: Access controls > Applications) > Add an application > Self-hosted.',
        "2. Application name: $AppHostname   Session duration: e.g. 24 hours.",
        "3. Add public hostname: subdomain '$subdomain', domain '$Domain' (path empty).",
        '4. Add a policy: Action Allow, Include > Emails > your e-mail address (or an e-mail domain/group).',
        '5. Login method: One-time PIN works out of the box. Save the application.'
      )
      Wait-Enter 'Create the Access application'
    } else {
      Write-Warn "$AppHostname will be reachable by anyone on the Internet. Make sure the app has its own login."
    }

    # 7. Public hostname
    Write-Step 'Step 7 - Publish the hostname on the tunnel'
    $tunnelLabel = $state.tunnelName
    $existingDns = $false
    try { $existingDns = [bool](Resolve-DnsName -Name $AppHostname -Server 1.1.1.1 -DnsOnly -ErrorAction Stop) } catch { }
    $lines = @(
      "1. Networks > Tunnels > '$tunnelLabel' > Configure (or the Next/Route tunnel step if you are still in the wizard).",
      '2. Tab "Published application routes" (older layouts: "Public Hostname") > Add a published application route.',
      "3. Subdomain: $subdomain    Domain: $Domain    Path: (empty)",
      '4. Service Type: HTTP    URL: traefik:80',
      '5. Save. Cloudflare creates the DNS record for you.'
    )
    if ($existingDns) {
      $lines += @(
        '',
        "NOTE: $AppHostname already exists in DNS. If Cloudflare refuses the route because a record exists,",
        '      check in DNS > Records what it is used for; only if it is not needed elsewhere, delete it and save the route again.',
        '      Hostnames of other tunnels are not affected.'
      )
    }
    Write-Instructions 'In the Zero Trust dashboard' $lines
    Wait-Enter 'Add the published application route'

    # 8. Test
    Write-Step "Step 8 - Testing https://$AppHostname"
    $result = Test-PublicHostname $AppHostname
    if ($result -eq 'access' -and (Read-YesNo 'Confirm end to end? Sign in at the URL in your browser while I watch Traefik' $true)) {
      Write-Note "Open https://$AppHostname in your browser and sign in (waiting up to 3 minutes)..."
      if (Wait-TunnelRequest $AppHostname 180) { $result = 'access+ok' }
      else { Write-Warn 'No request arrived through the tunnel. Check the published route (Service HTTP, URL traefik:80).' }
    }
    if ($result -eq 'fail') {
      Write-Warn 'Could not confirm the public route yet. Check the route values above, wait a minute, then run:'
      Write-Warn "  .\install.ps1 -AddApp -AppHostname $AppHostname -AppTarget existing"
    }
  }

  # 9. Save + summary
  $apps = @($state.apps | Where-Object { $_.hostname -ne $AppHostname })
  $apps += [pscustomobject]@{ hostname = $AppHostname; target = $target; access = $useAccess; publicCheck = $result; checkedAt = (Get-Date -Format 's') }
  $state.apps = $apps
  Save-WizardState $state

  Write-Step 'Wizard summary'
  Write-Note "Tunnel:      $($state.tunnelName) ($($state.tunnelId))"
  Write-Note "Hostname:    https://$AppHostname -> http://traefik:80 -> $target"
  Write-Note ("Local route: {0}" -f $(if ($localOk) { 'ok' } else { 'backend not answering' }))
  Write-Note "Public test: $result"
  Write-Note 'Add another app later (same tunnel, nothing is recreated):  .\install.ps1 -AddApp'
  if ($result -eq 'fail') { return $false }
  return $true
}
