#requires -version 5.1
# Disposable test resources: ownership records and orphan detection.
#
# Every disposable test run names its resources with a run prefix such as `tpx-ci-09e463` or `tpm-alc-1a2b3c`
# (containers, Compose projects, volumes, networks and the %TEMP% folder all start with it). A run registers itself
# (Register-TestRun) with its process ID and start time; its own `finally` block removes everything and unregisters.
# A hard kill (out of memory, closed terminal, TerminateProcess) skips `finally`, so the next run sweeps first:
# a registered prefix whose owner process is gone is an orphan and is removed. Prefixes without an ownership record
# (runs from before this module, or suites that do not register) are only reported, never removed automatically.
#
# Safety rules for removal, checked per prefix: a container must carry the prefix in its name (and, when it has one, in
# its Compose project label); a network is removed only when every remaining member carries the prefix; a volume only
# when no container outside the prefix uses it; the folder only when it is %TEMP%\<prefix> exactly. Nothing without a
# test prefix is ever listed or touched.
Set-StrictMode -Version 2.0

$script:PrefixPattern = '^(tp[xm]-[a-z]+-[0-9a-f]{6,8})(?=$|[-_])'
$script:RunsDir = Join-Path ([IO.Path]::GetTempPath()) 'dtc-test-runs'

function Invoke-TrDocker {
  # Plain function with $args: every argument (including -a, -q, --format) goes to docker unchanged.
  $Arguments = @($args | ForEach-Object { [string]$_ })
  $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & docker @Arguments 2>$null; return @($out | ForEach-Object { "$_" } | Where-Object { $_ }) }
  catch { return @() }
  finally { $ErrorActionPreference = $previous }
}

function Get-TestRunPrefix([string]$Name) {
  if ($Name -match $script:PrefixPattern) { return $Matches[1] }
  return $null
}

function Get-ProcessStartTicks([int]$ProcessId) {
  try { return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { return $null }
}

function Register-TestRun {
  <# Records that this process owns every resource whose name starts with $Prefix. #>
  param([Parameter(Mandatory)][string]$Prefix, [string]$Suite = '')
  if (-not (Get-TestRunPrefix $Prefix)) { throw "Not a disposable test prefix: $Prefix" }
  New-Item -ItemType Directory -Force -Path $script:RunsDir | Out-Null
  $record = [ordered]@{ prefix = $Prefix; suite = $Suite; pid = $PID; processStart = (Get-ProcessStartTicks $PID); registered = (Get-Date).ToUniversalTime().ToString('o') }
  [IO.File]::WriteAllText((Join-Path $script:RunsDir "$Prefix.json"), ($record | ConvertTo-Json -Compress))
}

function Unregister-TestRun([string]$Prefix) {
  if (-not $Prefix) { return }
  Remove-Item -LiteralPath (Join-Path $script:RunsDir "$Prefix.json") -Force -ErrorAction SilentlyContinue
}

function Complete-TestRun([string]$Prefix) {
  <# End of a run's teardown: drops the ownership record only when nothing with the prefix is left, so leftovers stay
     attributable (the next run's sweep removes them as an orphan once this process has exited). Returns the leftovers. #>
  if (-not $Prefix) { return @() }
  $left = @(Get-TestOrphans | Where-Object { $_.prefix -eq $Prefix } | ForEach-Object { @($_.containers) + @($_.volumes) + @($_.networks) + @($(if ($_.folder) { $_.folder })) })
  if (-not $left.Count) { Unregister-TestRun $Prefix }
  return $left
}

function Get-TestRunOwner([string]$Prefix) {
  $file = Join-Path $script:RunsDir "$Prefix.json"
  if (-not (Test-Path -LiteralPath $file)) { return [pscustomobject]@{ state = 'unregistered'; pid = $null; suite = '' } }
  try { $r = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { return [pscustomobject]@{ state = 'orphan'; pid = $null; suite = '' } }
  $ticks = Get-ProcessStartTicks ([int]$r.pid)
  # Same PID and same process start time: the owner is still running (a reused PID has a different start time).
  $alive = $null -ne $ticks -and ($null -eq $r.processStart -or [long]$r.processStart -eq [long]$ticks)
  return [pscustomobject]@{ state = $(if ($alive) { 'running' } else { 'orphan' }); pid = $r.pid; suite = [string]$r.suite }
}

function Get-TestOrphans {
  <# Lists disposable test resources grouped by run prefix, with the owner state: running, orphan or unregistered. #>
  [CmdletBinding()] param()
  $groups = @{}
  function Add-TrEntry([string]$Kind, [string]$Name, [string]$Extra = '') {
    $p = Get-TestRunPrefix $Name
    if (-not $p) { return }
    if (-not $groups.ContainsKey($p)) { $groups[$p] = [ordered]@{ containers = New-Object System.Collections.ArrayList; volumes = New-Object System.Collections.ArrayList; networks = New-Object System.Collections.ArrayList; folder = $null; notes = New-Object System.Collections.ArrayList } }
    switch ($Kind) {
      'container' { $null = $groups[$p].containers.Add($Name); if ($Extra -and -not (Get-TestRunPrefix $Extra)) { $null = $groups[$p].notes.Add("container $Name has Compose project '$Extra' outside the test prefix") } }
      'volume' { $null = $groups[$p].volumes.Add($Name) }
      'network' { $null = $groups[$p].networks.Add($Name) }
      'folder' { $groups[$p].folder = $Extra }
    }
  }
  # Quote-free Go templates: Windows PowerShell 5.1 mangles embedded double quotes in native arguments.
  foreach ($line in (Invoke-TrDocker ps -a --format '{{.Names}}|{{.Labels}}')) {
    $n, $labels = $line.Split('|', 2); $proj = if ($labels -match '(?:^|,)com\.docker\.compose\.project=([^,]+)') { $Matches[1] } else { '' }
    Add-TrEntry 'container' $n $proj
  }
  foreach ($v in (Invoke-TrDocker volume ls -q)) { Add-TrEntry 'volume' $v }
  foreach ($n in (Invoke-TrDocker network ls --format '{{.Name}}')) { Add-TrEntry 'network' $n }
  foreach ($d in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^tp[xm]-' })) {
    if ((Get-TestRunPrefix $d.Name) -eq $d.Name) { Add-TrEntry 'folder' $d.Name $d.FullName }
  }
  # Ownership records whose resources are all gone are stale records; drop them.
  foreach ($f in @(Get-ChildItem -LiteralPath $script:RunsDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    $p = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (-not $groups.ContainsKey($p) -and (Get-TestRunOwner $p).state -eq 'orphan') { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
  }
  $result = foreach ($p in ($groups.Keys | Sort-Object)) {
    $g = $groups[$p]; $owner = Get-TestRunOwner $p
    [pscustomobject]@{ prefix = $p; state = $owner.state; ownerPid = $owner.pid; suite = $owner.suite; containers = @($g.containers); volumes = @($g.volumes); networks = @($g.networks); folder = $g.folder; notes = @($g.notes) }
  }
  return @($result)
}

function Remove-TestOrphan {
  <# Removes one run prefix's resources after the safety checks. Returns what was removed and what was kept, and why. #>
  [CmdletBinding()] param([Parameter(Mandatory)]$Orphan)
  $p = $Orphan.prefix
  if (-not (Get-TestRunPrefix $p) -or (Get-TestRunPrefix $p) -ne $p) { throw "Not a disposable test prefix: $p" }
  if ($Orphan.state -eq 'running') { throw "Run $p is still running (PID $($Orphan.ownerPid)); not removing it." }
  $removed = New-Object System.Collections.ArrayList; $kept = New-Object System.Collections.ArrayList
  foreach ($c in $Orphan.containers) {
    if ((Get-TestRunPrefix $c) -ne $p) { $null = $kept.Add("container ${c}: name outside the prefix"); continue }
    $proj = ''
    try { $lbl = (@(Invoke-TrDocker inspect $c --format '{{json .Config.Labels}}') -join '') | ConvertFrom-Json; if ($lbl -and $lbl.PSObject.Properties['com.docker.compose.project']) { $proj = [string]$lbl.'com.docker.compose.project' } } catch { }
    if ($proj -and (Get-TestRunPrefix $proj) -ne $p) { $null = $kept.Add("container ${c}: Compose project $proj is not part of the run"); continue }
    $null = Invoke-TrDocker rm -f $c; $null = $removed.Add("container $c")
  }
  foreach ($n in $Orphan.networks) {
    $members = @((@(Invoke-TrDocker network inspect $n --format '{{range .Containers}}{{.Name}} {{end}}') -join ' ').Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    $foreign = @($members | Where-Object { (Get-TestRunPrefix $_) -ne $p })
    if ($foreign.Count) { $null = $kept.Add("network ${n}: still used by $($foreign -join ', ')"); continue }
    $null = Invoke-TrDocker network rm $n; $null = $removed.Add("network $n")
  }
  foreach ($v in $Orphan.volumes) {
    $users = @(Invoke-TrDocker ps -a --filter "volume=$v" --format '{{.Names}}')
    if ($users.Count) { $null = $kept.Add("volume ${v}: still used by $($users -join ', ')"); continue }
    $null = Invoke-TrDocker volume rm $v; $null = $removed.Add("volume $v")
  }
  if ($Orphan.folder) {
    $expected = Join-Path ([IO.Path]::GetTempPath()) $p
    if ([IO.Path]::GetFullPath($Orphan.folder).TrimEnd('\') -ieq [IO.Path]::GetFullPath($expected).TrimEnd('\')) {
      Get-ChildItem -LiteralPath $expected -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
      Remove-Item -LiteralPath $expected -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $expected) { $null = $kept.Add("folder ${expected}: could not be removed (in use?)") } else { $null = $removed.Add("folder $expected") }
    } else { $null = $kept.Add("folder $($Orphan.folder): not %TEMP%\$p") }
  }
  if (-not $kept.Count) { Unregister-TestRun $p }
  return [pscustomobject]@{ prefix = $p; removed = @($removed); kept = @($kept) }
}

function Invoke-TestOrphanSweep {
  <#
    Called at the start of a disposable test run: removes the resources of earlier runs whose owner process is gone and
    returns one line per prefix (removed, or reported because it has no ownership record or is still running).
  #>
  [CmdletBinding()] param([switch]$IncludeUnregistered)
  $lines = New-Object System.Collections.ArrayList
  foreach ($o in (Get-TestOrphans)) {
    $what = "$(@($o.containers).Count) containers, $(@($o.volumes).Count) volumes, $(@($o.networks).Count) networks$(if ($o.folder) { ', folder' })"
    if ($o.state -eq 'orphan' -or ($IncludeUnregistered -and $o.state -eq 'unregistered')) {
      $r = Remove-TestOrphan $o
      $null = $lines.Add("$($o.prefix) ($($o.state)$(if ($o.suite) { ", $($o.suite)" })): removed $($r.removed.Count) item(s)$(if ($r.kept.Count) { "; kept: $($r.kept -join '; ')" })")
    } elseif ($o.state -eq 'unregistered') {
      $null = $lines.Add("$($o.prefix) (no ownership record; left alone, remove with tests\Find-TestOrphans.ps1 -Remove -IncludeUnregistered): $what")
    } else {
      $null = $lines.Add("$($o.prefix) (running, PID $($o.ownerPid)$(if ($o.suite) { ", $($o.suite)" })): $what")
    }
  }
  return @($lines)
}

Export-ModuleMember -Function Get-TestRunPrefix, Register-TestRun, Unregister-TestRun, Complete-TestRun, Get-TestRunOwner, Get-TestOrphans, Remove-TestOrphan, Invoke-TestOrphanSweep
