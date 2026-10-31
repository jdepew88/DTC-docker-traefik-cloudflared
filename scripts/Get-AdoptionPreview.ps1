#requires -version 5.1
<#
.SYNOPSIS
  Read-only migration preview on this PC: what would be adopted, the routes, the network changes, what blocks it and whether
  each backend answers from the proxy's network. Changes nothing: no file, container, network or Cloudflare resource.
  Reachability checks start short-lived probe containers; -NoProbe skips them.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Get-AdoptionPreview.ps1 -InstallPath $env:USERPROFILE\.docker\projects\traefik-proxy -Mode both -ExternalHost voice.example.com -InternalHost voice.local.example.com -AuthEndpoint http://authentik-server:9000
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstallPath,
  [string]$SpecId = 'omnivoice',
  [ValidateSet('none', 'internal', 'external', 'both')][string]$Mode = 'none',
  [string]$ExternalHost = '',
  [string]$InternalHost = '',
  [string]$AuthEndpoint = '',
  [switch]$NoProbe,
  [switch]$Json
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'TraefikProxy', 'DockerDiscovery', 'Dashboard', 'CloudflareApi', 'AppAdoption') { Import-Module (Join-Path $repo "lib\$m.psm1") -Force }

$settings = Get-StackSettings -InstallPath $InstallPath
$facts = Get-AdoptionFacts $settings
$specs = @(Get-AdoptionSpecs (Join-Path $repo 'catalog'))
$spec = @($specs | Where-Object { $_.id -eq $SpecId })
if (-not $spec.Count) { throw "No routing specification '$SpecId' in catalog\adoption." }
$own = @($settings.StackName); if ($facts.targets.internal.mode -eq 'stack') { $own += $facts.targets.internal.name }
$inventory = ConvertTo-AdoptionInventory -Containers $facts.containers -Routers $facts.routers.external -Specs $specs -Networks $facts.networks -ProxyNetwork $settings.ProxyNetwork -OwnStacks $own
$request = [ordered]@{ mode = $Mode; externalHost = $ExternalHost; internalHost = $InternalHost; authEndpoint = $AuthEndpoint }
$plan = Get-AdoptionPlan -Spec $spec[0] -Request $request -Facts $facts -ExistingFiles (Get-ExistingAdoptionFiles $spec[0].id $facts.targets)
$checks = @()
if (-not $NoProbe) { $checks = @(Invoke-AdoptionReachability -Settings $settings -Plan $plan -Facts $facts) }
$retire = Get-AdoptionRetirePlan -Spec $spec[0] -Facts $facts -OwnStacks $own -OwnNetworks @($settings.ProxyNetwork, $settings.TunnelNetwork)

if ($Json) { [ordered]@{ plan = $plan; checks = $checks; redundant = $inventory.redundant; unreachable = $inventory.unreachable; conflicts = $inventory.conflicts; retire = $retire; targets = @{ external = $facts.targets.external.detail; internal = $facts.targets.internal.detail } } | ConvertTo-Json -Depth 10; return }

Write-Output "Application : $($plan.displayName)   routing: $Mode"
Write-Output "External    : $($facts.targets.external.detail)"
Write-Output "Internal    : $($facts.targets.internal.detail)"
Write-Output "`nBackends"
foreach ($b in $plan.backends) { Write-Output ("  {0,-12} {1,-26} {2,-10} {3}" -f $b.id, $(if ($b.container) { $b.container } else { "Windows host :$($b.port)" }), $b.state, $(if ($b.owner) { $b.owner.manager } else { '' })) }
foreach ($t in $plan.targets) {
  Write-Output "`n$($t.role) route on $(if ($t.proxy) { $t.proxy } else { '(no proxy yet)' }): $($t.hostname) (sign-in: $($t.signIn), file $($t.file.name): $($t.file.action))"
  foreach ($r in $t.routers) { Write-Output ("  {0,-14} -> {1,-40} priority {2}" -f $(if ($r.path) { $r.path } else { '/' }), $r.url, $r.priority) }
}
Write-Output "`nNetwork changes"
if ($plan.networkChanges.Count) { foreach ($n in $plan.networkChanges) { Write-Output "  $($n.command)" } } else { Write-Output '  none' }
if ($checks.Count) { Write-Output "`nReachability from the proxies"; foreach ($c in $checks) { Write-Output ("  [{0}] {1}: {2}" -f $c.state, $c.subject, $c.detail) } }
if ($plan.blockers.Count) { Write-Output "`nBLOCKED"; foreach ($x in $plan.blockers) { Write-Output "  - $x" } }
if ($plan.warnings.Count) { Write-Output "`nWarnings"; foreach ($x in $plan.warnings) { Write-Output "  - $x" } }
Write-Output "`nRetirement candidates (nothing is changed here)"
if (@($retire.items).Count) { foreach ($i in $retire.items) { Write-Output ("  {0,-9} {1,-40} {2,-8} {3}" -f $i.type, $i.name, $i.state, $(if ($i.blocked) { "blocked: $($i.blocked)" } else { '' })) } } else { Write-Output '  none' }
