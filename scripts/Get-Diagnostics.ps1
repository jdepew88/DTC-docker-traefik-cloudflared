#requires -version 5.1
<#
.SYNOPSIS
  Read-only diagnostics for one Traefik + cloudflared instance. Safe to paste into an issue:
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
Import-Module (Join-Path $ProjectPath 'lib\TraefikProxy.psm1') -Force
$s = Get-StackSettings -InstallPath $ProjectPath
$dashPort = $s.DashboardPort

function Section([string]$Title, [scriptblock]$Body) {
  "`n===== $Title"
  try { & $Body 2>&1 | ForEach-Object { "$_" } } catch { "error: $_" }
}

$report = & {
  Section 'Instance' {
    "stack=$($s.StackName) path=$ProjectPath http=127.0.0.1:$($s.HttpPort) dashboard=127.0.0.1:$($s.DashboardPort)"
    "proxyNetwork=$($s.ProxyNetwork) tunnelSubnet=$($s.TunnelSubnet) cloudflaredIp=$($s.CloudflaredIp)"
  }
  Section 'Docker' {
    docker version --format 'client {{.Client.Version}} (API {{.Client.APIVersion}}) / server {{.Server.Version}} (API {{.Server.APIVersion}}, min {{.Server.MinAPIVersion}})'
    docker info --format 'os={{.OSType}} name={{.Name}} root={{.DockerRootDir}} kernel={{.KernelVersion}}'
    docker compose version
    docker context show
  }
  Section 'Stack containers' { docker compose --project-directory $ProjectPath --profile tunnel --profile test ps -a }
  Section 'Images' { docker inspect $s.TraefikContainer $s.SocketProxyContainer $s.CloudflaredContainer --format '{{.Name}} {{.Config.Image}}' }
  Section "$($s.ProxyNetwork) network members" { docker network inspect $s.ProxyNetwork --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}' }
  Section 'Networks' { docker network ls }
  Section "Loopback listeners $($s.HttpPort)/$($s.DashboardPort)" { Get-NetTCPConnection -State Listen -LocalPort $s.HttpPort, $s.DashboardPort -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table -AutoSize | Out-String }
  Section 'Service registry (config\services.json)' {
    $registry = Read-ServiceRegistry -Settings $s
    foreach ($svc in $registry.services) { '{0,-24} {1,-8} {2,-40} -> {3}' -f $svc.name, $(if ($svc.enabled) { 'enabled' } else { 'disabled' }), ($svc.hostnames -join ','), (Get-ServiceUrl $svc) }
    $plan = Get-ServicePlan -Settings $s -Services $registry.services
    Format-ServicePlan $plan
  }
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
  Section "traefik logs (last $LogLines)" { docker logs --tail $LogLines $s.TraefikContainer }
  Section "cloudflared logs (last $LogLines)" { docker logs --tail $LogLines $s.CloudflaredContainer }
  Section 'socket-proxy denials (last 500 lines)' { docker logs --tail 500 $s.SocketProxyContainer | Select-String ' 403 ' }
}

$redacted = ConvertTo-RedactedText $report
if ($OutFile) { $redacted | Set-Content -LiteralPath $OutFile -Encoding UTF8; "Written to $OutFile" } else { $redacted }
