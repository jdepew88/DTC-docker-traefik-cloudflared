#requires -version 5.1
<#
.SYNOPSIS
  Lists (and optionally removes) resources left behind by interrupted disposable test runs.

.DESCRIPTION
  Only resources whose names start with a disposable test prefix (tpx-<suite>-<id> or tpm-<suite>-<id>) are considered:
  containers, Compose volumes, networks and the %TEMP%\<prefix> folder. Each prefix is shown with its owner state:
    running       the registered test process is still alive (never removed)
    orphan        the registered test process is gone (an interrupted run); removed with -Remove
    unregistered  no ownership record (an older run or a suite that does not register); removed only with
                  -Remove -IncludeUnregistered
  Removal re-checks every item (network members and volume users must belong to the same prefix). Production
  containers, volumes and networks never carry these prefixes and are not listed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Find-TestOrphans.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Find-TestOrphans.ps1 -Remove
#>
[CmdletBinding()]
param([switch]$Remove, [switch]$IncludeUnregistered)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'TestResources.psm1') -Force

$found = @(Get-TestOrphans)
if (-not $found.Count) { Write-Host 'No disposable test resources found.'; exit 0 }
foreach ($o in $found) {
  Write-Host ("{0}  [{1}{2}]" -f $o.prefix, $o.state, $(if ($o.suite) { ", $($o.suite)" } else { '' }))
  foreach ($c in $o.containers) { Write-Host "  container $c" }
  foreach ($v in $o.volumes) { Write-Host "  volume    $v" }
  foreach ($n in $o.networks) { Write-Host "  network   $n" }
  if ($o.folder) { Write-Host "  folder    $($o.folder)" }
  foreach ($x in $o.notes) { Write-Host "  note: $x" -ForegroundColor Yellow }
  if ($Remove -and ($o.state -eq 'orphan' -or ($IncludeUnregistered -and $o.state -eq 'unregistered'))) {
    $r = Remove-TestOrphan $o
    Write-Host "  -> removed $($r.removed.Count) item(s)" -ForegroundColor Green
    foreach ($k in $r.kept) { Write-Host "  -> kept $k" -ForegroundColor Yellow }
  }
}
if (-not $Remove) { Write-Host ''; Write-Host 'Nothing removed (use -Remove; add -IncludeUnregistered for prefixes without an ownership record).' }
exit 0
