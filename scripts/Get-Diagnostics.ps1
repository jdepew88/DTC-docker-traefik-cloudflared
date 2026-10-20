#requires -version 5.1
<#
.SYNOPSIS
  Read-only diagnostics for the Traefik + cloudflared stack. Safe to paste into an issue:
  anything that looks like a tunnel token (eyJ...) is redacted.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Get-Diagnostics.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\Get-Diagnostics.ps1 -OutFile diag.txt
#>
[CmdletBinding()]
param(
  [string]$ProjectPath,
  [int]$LogLines = 80,
  [string]$OutFile
)

$ErrorActionPreference = 'Continue'
# Resolved here: $PSScriptRoot/$MyInvocation are not populated in param() defaults on PowerShell 5.1.
if (-not $ProjectPath) { $ProjectPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$dashPort = 8181
$envFile = Join-Path $ProjectPath '.env'
if (Test-Path -LiteralPath $envFile) {
  foreach ($line in Get-Content -LiteralPath $envFile) { if ($line -match '^\s*TRAEFIK_DASHBOARD_PORT\s*=\s*(\d+)') { $dashPort = [int]$Matches[1] } }
}

function Section([string]$Title, [scriptblock]$Body) {
  "`n===== $Title"
  try { & $Body 2>&1 | ForEach-Object { "$_" } } catch { "error: $_" }
}

$report = & {
  Section 'Docker' {
    docker version --format 'client {{.Client.Version}} (API {{.Client.APIVersion}}) / server {{.Server.Version}} (API {{.Server.APIVersion}}, min {{.Server.MinAPIVersion}})'
    docker info --format 'os={{.OSType}} name={{.Name}} root={{.DockerRootDir}} kernel={{.KernelVersion}}'
    docker compose version
    docker context show
  }
  Section 'Stack containers' { docker compose --project-directory $ProjectPath --profile tunnel --profile test ps -a }
  Section 'Images' { docker inspect traefik socket-proxy cloudflared --format '{{.Name}} {{.Config.Image}}' }
  Section 'proxy network members' { docker network inspect proxy --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}' }
  Section 'Networks' { docker network ls }
  Section 'Loopback listeners 8180/8181' { Get-NetTCPConnection -State Listen -LocalPort 8180, 8181 -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table -AutoSize | Out-String }
  Section 'Traefik routers' {
    try {
      (Invoke-RestMethod "http://127.0.0.1:$dashPort/api/http/routers") | ForEach-Object { '{0,-40} {1,-8} {2}' -f $_.name, $_.status, $_.rule }
    } catch { "dashboard API unreachable on 127.0.0.1:${dashPort}: $_" }
  }
  Section 'Traefik services' {
    try {
      (Invoke-RestMethod "http://127.0.0.1:$dashPort/api/http/services") | ForEach-Object {
        $servers = ''
        if ($_.PSObject.Properties['serverStatus']) { $servers = ($_.serverStatus.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' }
        '{0,-40} {1}' -f $_.name, $servers
      }
    } catch { "dashboard API unreachable: $_" }
  }
  Section "traefik logs (last $LogLines)" { docker logs --tail $LogLines traefik }
  Section "cloudflared logs (last $LogLines)" { docker logs --tail $LogLines cloudflared }
  Section 'socket-proxy denials (last 500 lines)' { docker logs --tail 500 socket-proxy | Select-String ' 403 ' }
}

$redacted = $report | ForEach-Object { $_ -replace 'eyJ[A-Za-z0-9_\-=+/.]{20,}', 'eyJ...REDACTED' }
if ($OutFile) { $redacted | Set-Content -LiteralPath $OutFile -Encoding UTF8; "Written to $OutFile" } else { $redacted }
