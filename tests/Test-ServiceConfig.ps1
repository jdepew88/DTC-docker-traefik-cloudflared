#requires -version 5.1
<#
.SYNOPSIS
  Tests for the service registry backend (lib\TraefikProxy.psm1): validation, YAML rendering, registry JSON,
  plan/apply, backup/rollback and instance settings. Works in a temporary folder; touches no running stack.

.DESCRIPTION
  With -Deep (default when Docker is reachable) the generated configuration is also loaded into throwaway
  Traefik containers (no network, removed afterwards) to prove Traefik accepts it and rejects broken input.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-ServiceConfig.ps1
  powershell -ExecutionPolicy Bypass -File .\tests\Test-ServiceConfig.ps1 -NoDocker
#>
[CmdletBinding()]
param([switch]$NoDocker)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail }
}
function Get-Issues($Service, $Others = @(), $Middlewares = @('default-headers', 'compress', 'no-index')) {
  return @(Test-ServiceDefinition -Service $Service -OtherServices $Others -AvailableMiddlewares $Middlewares)
}
function Test-HasError([string]$Name, $Issues, [string]$Field) {
  $hit = @($Issues | Where-Object { $_.Level -eq 'Error' -and $_.Field -eq $Field })
  Test-Condition $Name ($hit.Count -gt 0) ('issues: ' + (($Issues | ForEach-Object { "$($_.Level)/$($_.Field)" }) -join ', '))
}

# --- Rendering ---------------------------------------------------------------------------------------
$plex = New-ServiceDefinition -Name plex -Hostname plex.jrtechconsult.com -TargetType lan -TargetHost 10.10.0.11 -Port 32800
$expected = @"
# Generated from config/services.json (service 'plex'). Do not edit by hand:
# changes here are overwritten. Use services.ps1 or the web UI instead.
http:
  routers:
    svc-plex:
      rule: 'Host(``plex.jrtechconsult.com``)'
      entryPoints: [web]
      middlewares: [default-headers@file]
      service: svc-plex
  services:
    svc-plex:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: http://10.10.0.11:32800

"@
$expected = $expected.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
Test-Condition 'render: Plex LAN example (router + load balancer)' ((ConvertTo-TraefikRouteYaml $plex) -eq $expected) (ConvertTo-TraefikRouteYaml $plex)

$multi = New-ServiceDefinition -Name nas -Hostname nas.example.com, files.example.com -TargetType lan -TargetHost 192.168.1.20 -Port 5001 -Protocol https -TlsSkipVerify -PathPrefix /ui -StripPrefix
$y = ConvertTo-TraefikRouteYaml $multi
Test-Condition 'render: several hostnames + path prefix rule' ($y -match [regex]::Escape("rule: '(Host(``nas.example.com``) || Host(``files.example.com``)) && PathPrefix(``/ui``)'")) $y
Test-Condition 'render: strip-prefix middleware first' ($y -match 'middlewares: \[svc-nas-strip, default-headers@file\]' -and $y -match "prefixes: \['/ui'\]") $y
Test-Condition 'render: https + skip-verify serversTransport' ($y -match 'url: https://192\.168\.1\.20:5001' -and $y -match 'serversTransport: svc-nas-transport' -and $y -match 'insecureSkipVerify: true') $y

$win = New-ServiceDefinition -Name grafana -Hostname grafana.example.com -TargetType host -Port 3000
Test-Condition 'render: Windows host target uses host.docker.internal' ((ConvertTo-TraefikRouteYaml $win) -match 'url: http://host\.docker\.internal:3000')
$ctr = New-ServiceDefinition -Name grpc -Hostname grpc.example.com -TargetType docker -TargetHost My_Container.1 -Port 50051 -Protocol h2c -Middleware @()
$yc = ConvertTo-TraefikRouteYaml $ctr
Test-Condition 'render: docker target keeps container-name case, h2c scheme' ($yc -match 'url: h2c://My_Container\.1:50051') $yc
Test-Condition 'render: no middleware line when none selected' ($yc -notmatch 'middlewares:') $yc

# --- Validation ----------------------------------------------------------------------------------------
Test-Condition 'valid: Plex example has no errors' (@(Get-Issues $plex | Where-Object { $_.Level -eq 'Error' }).Count -eq 0)
$plexWarnings = @(Get-Issues $plex | Where-Object { $_.Level -eq 'Warning' })
Test-Condition 'warn: Plex flagged for Cloudflare media streaming restrictions' (@($plexWarnings | Where-Object { $_.Field -eq 'cloudflare' -and $_.Message -match 'streaming' }).Count -eq 1)
$open = New-ServiceDefinition -Name wiki -Hostname wiki.example.com -TargetType docker -TargetHost wikijs -Port 3000 -Access $false
Test-Condition 'warn: published without Cloudflare Access' (@(Get-Issues $open | Where-Object { $_.Field -eq 'cloudflare.access' }).Count -eq 1)
$local = New-ServiceDefinition -Name wiki -Hostname wiki.example.com -TargetType docker -TargetHost wikijs -Port 3000 -Publish $false -Access $false
Test-Condition 'no Access warning for local-only services' (@(Get-Issues $local | Where-Object { $_.Field -eq 'cloudflare.access' }).Count -eq 0)
$public = New-ServiceDefinition -Name pub -Hostname pub.example.com -TargetType lan -TargetHost 8.8.8.8 -Port 80
Test-Condition 'warn: LAN target with a public IP' (@(Get-Issues $public | Where-Object { $_.Field -eq 'target.host' -and $_.Level -eq 'Warning' }).Count -eq 1)

$cases = @(
  @{ n = 'error: invalid service name'; f = 'name'; s = @{ name = 'Bad Name!'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: hostname not fully qualified'; f = 'hostnames'; s = @{ name = 'a'; hostnames = @('localhost'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: hostname with injection characters'; f = 'hostnames'; s = @{ name = 'a'; hostnames = @('a.example.com`) || Host(`evil.com'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: no hostname'; f = 'hostnames'; s = @{ name = 'a'; hostnames = @(); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: port out of range'; f = 'target.port'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 70000 } } },
  @{ n = 'error: port not a number'; f = 'target.port'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 'abc' } } },
  @{ n = 'error: unknown protocol'; f = 'target.protocol'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80; protocol = 'ftp' } } },
  @{ n = 'error: unknown target type'; f = 'target.type'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'vm'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: loopback LAN target'; f = 'target.host'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = '127.0.0.1'; port = 80 } } },
  @{ n = 'error: IPv6 LAN target'; f = 'target.host'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = 'fd00::1'; port = 80 } } },
  @{ n = 'error: LAN host with URL characters'; f = 'target.host'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = 'evil.com/x?'; port = 80 } } },
  @{ n = 'error: docker target with invalid name'; f = 'target.host'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'docker'; host = 'bad name'; port = 80 } } },
  @{ n = 'error: host target pointing elsewhere'; f = 'target.host'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'host'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: skip-verify on plain http'; f = 'target.tlsSkipVerify'; s = @{ name = 'a'; hostnames = @('a.example.com'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80; tlsSkipVerify = $true } } },
  @{ n = 'error: strip prefix without path prefix'; f = 'stripPrefix'; s = @{ name = 'a'; hostnames = @('a.example.com'); stripPrefix = $true; target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: invalid path prefix'; f = 'pathPrefix'; s = @{ name = 'a'; hostnames = @('a.example.com'); pathPrefix = 'api'; target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: undefined file middleware'; f = 'middlewares'; s = @{ name = 'a'; hostnames = @('a.example.com'); middlewares = @('missing@file'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } },
  @{ n = 'error: malformed middleware reference'; f = 'middlewares'; s = @{ name = 'a'; hostnames = @('a.example.com'); middlewares = @('x@y@z'); target = @{ type = 'lan'; host = '10.0.0.1'; port = 80 } } }
)
foreach ($c in $cases) { Test-HasError $c.n (Get-Issues (ConvertTo-ServiceDefinition $c.s)) $c.f }

$dupName = New-ServiceDefinition -Name plex -Hostname other.example.com -TargetType lan -TargetHost 10.0.0.2 -Port 80
Test-HasError 'error: duplicate service name' (Get-Issues $dupName @($plex)) 'name'
$dupHost = New-ServiceDefinition -Name plex2 -Hostname plex.jrtechconsult.com -TargetType lan -TargetHost 10.0.0.2 -Port 80
Test-HasError 'error: hostname already routed by another service' (Get-Issues $dupHost @($plex)) 'hostnames'
$pathed = New-ServiceDefinition -Name plex-api -Hostname plex.jrtechconsult.com -PathPrefix /api -TargetType lan -TargetHost 10.0.0.2 -Port 80
Test-Condition 'ok: same hostname with a distinct path prefix' (@(Get-Issues $pathed @($plex) | Where-Object { $_.Level -eq 'Error' }).Count -eq 0)
$disabledDup = New-ServiceDefinition -Name plex2 -Hostname plex.jrtechconsult.com -TargetType lan -TargetHost 10.0.0.2 -Port 80 -Disabled
Test-Condition 'ok: disabled service may share a hostname' (@(Get-Issues $disabledDup @($plex) | Where-Object { $_.Level -eq 'Error' }).Count -eq 0)

# --- Registry JSON ---------------------------------------------------------------------------------------
$json = ConvertTo-RegistryJson @($plex, $multi)
$back = $json | ConvertFrom-Json
Test-Condition 'registry JSON: valid and sorted by name' ($back.services.Count -eq 2 -and $back.services[0].name -eq 'nas') $json
Test-Condition 'registry JSON: one-element arrays stay arrays' ($json -match '"hostnames": \["plex\.jrtechconsult\.com"\]' -and $json -match '"middlewares": \["default-headers@file"\]') $json
$round = @($back.services | ForEach-Object { ConvertTo-ServiceDefinition $_ })
Test-Condition 'registry JSON: round trip renders identical YAML' ((ConvertTo-TraefikRouteYaml $round[1]) -eq (ConvertTo-TraefikRouteYaml $plex) -and (ConvertTo-TraefikRouteYaml $round[0]) -eq $y)
$escaped = New-ServiceDefinition -Name q -Hostname q.example.com -TargetType lan -TargetHost 10.0.0.3 -Port 80 -Description 'He said "hi" \ bye'
Test-Condition 'registry JSON: strings are escaped' ((ConvertTo-RegistryJson @($escaped) | ConvertFrom-Json).services[0].description -eq 'He said "hi" \ bye')

# --- Settings ----------------------------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tpx-unit-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp 'traefik\dynamic') | Out-Null
try {
  Copy-Item (Join-Path $repo 'traefik\dynamic\security.yml'), (Join-Path $repo 'traefik\dynamic\dashboard.yml') (Join-Path $tmp 'traefik\dynamic')
  Set-Content -LiteralPath (Join-Path $tmp '.env') -Value "STACK_NAME=tpx-unit`nTUNNEL_SUBNET=172.31.252.0/28`nTUNNEL_IP_RANGE=172.31.252.0/29`nCLOUDFLARED_IP=172.31.252.10"
  $s = Get-StackSettings -InstallPath $tmp
  Test-Condition 'settings: read from .env with defaults' ($s.StackName -eq 'tpx-unit' -and $s.TraefikContainer -eq 'tpx-unit-traefik' -and $s.HttpPort -eq 8180 -and $s.TunnelNetwork -eq 'tpx-unit_tunnel')
  Test-Condition 'settings: consistent values pass' (@(Test-StackSettings $s).Count -eq 0) (@(Test-StackSettings $s) -join '; ')
  $bad = $s.PSObject.Copy(); $bad.CloudflaredIp = '172.31.252.3'
  Test-Condition 'settings: cloudflared IP inside the dynamic range rejected' (@(Test-StackSettings $bad).Count -gt 0)
  $bad = $s.PSObject.Copy(); $bad.CloudflaredIp = '172.31.250.10'
  Test-Condition 'settings: cloudflared IP outside the subnet rejected' (@(Test-StackSettings $bad).Count -gt 0)
  $bad = $s.PSObject.Copy(); $bad.DashboardPort = $bad.HttpPort
  Test-Condition 'settings: identical ports rejected' (@(Test-StackSettings $bad).Count -gt 0)
  Test-Condition 'middlewares discovered from traefik\dynamic' ((@(Get-AvailableMiddlewares $s) -join ',') -eq 'default-headers,compress,no-index') (@(Get-AvailableMiddlewares $s) -join ',')

  # --- Example registry ------------------------------------------------------------------------------------
  Copy-Item (Join-Path $repo 'config\services.example.json') (Join-Path $tmp 'config-example.json')
  $exampleServices = @(([IO.File]::ReadAllText((Join-Path $tmp 'config-example.json')) | ConvertFrom-Json).services | ForEach-Object { ConvertTo-ServiceDefinition $_ })
  $exampleErrors = @(Test-ServiceRegistry -Settings $s -Services $exampleServices | Where-Object { $_.Level -eq 'Error' })
  Test-Condition 'config\services.example.json is valid' ($exampleServices.Count -eq 4 -and $exampleErrors.Count -eq 0) (($exampleErrors | ForEach-Object { $_.Message }) -join '; ')

  # --- Plan / apply / rollback -------------------------------------------------------------------------------
  $plan = Get-ServicePlan -Settings $s -Services @($plex)
  Test-Condition 'plan: new service -> add' ($plan.FileChanges -eq 1 -and $plan.Changes[0].Action -eq 'add' -and $plan.RegistryChanged)
  Test-Condition 'plan: preview writes nothing' (-not (Test-Path -LiteralPath $s.RegistryPath) -and -not (Test-Path (Join-Path $s.DynamicDir 'svc-plex.yml')))
  $r1 = Invoke-ServicePlan -Settings $s -Plan $plan -NoReload
  Test-Condition 'apply: route file and registry written' ((Test-Path (Join-Path $s.DynamicDir 'svc-plex.yml')) -and (Test-Path -LiteralPath $s.RegistryPath) -and $r1.Changed)
  Test-Condition 'apply: generated file is LF-only UTF-8 without BOM' ((-not ([IO.File]::ReadAllText((Join-Path $s.DynamicDir 'svc-plex.yml'))).Contains("`r")) -and ([IO.File]::ReadAllBytes((Join-Path $s.DynamicDir 'svc-plex.yml'))[0] -eq [byte][char]'#'))
  $again = Get-ServicePlan -Settings $s -Services (Read-ServiceRegistry -Settings $s).services
  Test-Condition 'apply: idempotent (second plan has no changes)' ($again.FileChanges -eq 0 -and -not $again.RegistryChanged)
  $noop = Invoke-ServicePlan -Settings $s -Plan $again -NoReload
  Test-Condition 'apply: no-op creates no backup' (-not $noop.Changed -and @(Get-ServiceBackups $s).Count -eq 1)

  $edited = (Read-ServiceRegistry -Settings $s).services
  $edited[0].target.port = 32400
  $planEdit = Get-ServicePlan -Settings $s -Services (@($edited) + $win)
  $update = @($planEdit.Changes | Where-Object { $_.File -eq 'svc-plex.yml' })[0]
  Test-Condition 'plan: edit -> update with diff' ($update.Action -eq 'update' -and @(Format-ServicePlan $planEdit) -contains '    -           - url: http://10.10.0.11:32800' -and @(Format-ServicePlan $planEdit) -contains '    +           - url: http://10.10.0.11:32400') ((Format-ServicePlan $planEdit) -join "`n")
  $null = Invoke-ServicePlan -Settings $s -Plan $planEdit -NoReload
  $current = (Read-ServiceRegistry -Settings $s).services
  @($current | Where-Object { $_.name -eq 'plex' })[0].enabled = $false
  $planDisable = Get-ServicePlan -Settings $s -Services $current
  Test-Condition 'plan: disable -> remove route, keep definition' (@($planDisable.Changes | Where-Object { $_.File -eq 'svc-plex.yml' })[0].Action -eq 'remove' -and $planDisable.RegistryJson -match '"name": "plex"')
  $null = Invoke-ServicePlan -Settings $s -Plan $planDisable -NoReload
  Test-Condition 'apply: disabled route file removed' (-not (Test-Path (Join-Path $s.DynamicDir 'svc-plex.yml')) -and (Test-Path (Join-Path $s.DynamicDir 'svc-grafana.yml')))

  $badPlan = Get-ServicePlan -Settings $s -Services @($plex, $dupHost)
  $threw = $false
  try { $null = Invoke-ServicePlan -Settings $s -Plan $badPlan -NoReload } catch { $threw = $true }
  Test-Condition 'apply: refuses a plan with errors and changes nothing' ($threw -and $badPlan.HasErrors -and -not (Test-Path (Join-Path $s.DynamicDir 'svc-plex.yml')))

  $restore = Restore-ServiceBackup -Settings $s -NoReload
  Test-Condition 'rollback: previous state restored (plex enabled at 32400, grafana present)' (
    ([IO.File]::ReadAllText((Join-Path $s.DynamicDir 'svc-plex.yml'))) -match ':32400' -and (Test-Path (Join-Path $s.DynamicDir 'svc-grafana.yml')))
  $restore2 = Restore-ServiceBackup -Settings $s -NoReload
  Test-Condition 'rollback: second rollback goes one step further back (grafana gone)' (
    -not (Test-Path (Join-Path $s.DynamicDir 'svc-grafana.yml')) -and ([IO.File]::ReadAllText((Join-Path $s.DynamicDir 'svc-plex.yml'))) -match ':32800')
  Test-Condition 'rollback: state before each rollback kept' (@(Get-ServiceBackups $s | Where-Object { $_.PreRollback }).Count -eq 2)
  $restore3 = Restore-ServiceBackup -Settings $s -NoReload
  Test-Condition 'rollback: back to the empty start (no registry, no routes)' (-not (Test-Path -LiteralPath $s.RegistryPath) -and @(Get-ChildItem $s.DynamicDir -Filter 'svc-*.yml').Count -eq 0)

  # --- Deep validation (throwaway Traefik container) ----------------------------------------------------------
  $docker = -not $NoDocker -and ((Invoke-Docker version --format '{{.Server.Version}}').ExitCode -eq 0)
  if (-not $docker) {
    Add-Result 'SKIP' 'deep validation' 'Docker not reachable (or -NoDocker)'
  } else {
    $wiki = $exampleServices[2]; $wiki.enabled = $true   # uses compress@file
    $okPlan = Get-ServicePlan -Settings $s -Services @($plex, $multi, $win, $ctr, $wiki)
    $deep = Test-TraefikDynamicConfig -Settings $s -Plan $okPlan
    Test-Condition 'deep: Traefik accepts all generated variants' ($deep.Ok -and @($deep.Routers).Count -eq 5 -and @($deep.Routers | Where-Object { $_.Status -ne 'enabled' }).Count -eq 0) (($deep.Errors + ($deep.Routers | ForEach-Object { "$($_.Name)=$($_.Status)" })) -join '; ')
    # Bypass the shallow checks to prove Traefik itself catches a broken reference.
    $broken = [pscustomobject]@{ Changes = @([pscustomobject]@{ File = 'svc-broken.yml'; Service = 'broken'; NewContent = (ConvertTo-TraefikRouteYaml $plex).Replace('svc-plex', 'svc-broken').Replace('default-headers@file', 'does-not-exist@file') }) }
    $deepBad = Test-TraefikDynamicConfig -Settings $s -Plan $broken
    Test-Condition 'deep: Traefik rejects an undefined middleware' (-not $deepBad.Ok -and ($deepBad.Errors -join ' ') -match 'does-not-exist') ($deepBad.Errors -join '; ')
    $garbage = [pscustomobject]@{ Changes = @([pscustomobject]@{ File = 'svc-garbage.yml'; Service = 'garbage'; NewContent = "http:`n  routers:`n    svc-garbage: [unclosed`n" }) }
    $deepGarbage = Test-TraefikDynamicConfig -Settings $s -Plan $garbage
    Test-Condition 'deep: Traefik rejects malformed YAML' (-not $deepGarbage.Ok) ''
    $leftover = (Invoke-Docker ps -a --filter "name=tpx-unit-validate" --format '{{.Names}}').Output -join ''
    Test-Condition 'deep: validation containers removed' ($leftover.Trim() -eq '') $leftover
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
