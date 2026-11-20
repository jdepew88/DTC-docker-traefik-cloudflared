#requires -version 5.1
# Security review and host compatibility of an imported (or AI-completed, or community) application manifest, before
# anything is installed. Pure: manifest and host adapter in, findings out.
#
# Severity: 'block' (cannot be installed as imported: unsupported or unsafe), 'high' (needs an explicit
# acknowledgement naming the risk), 'review' (shown, acknowledged once with the review), 'info'. Nothing here weakens
# existing infrastructure: the generated Compose never publishes more than the web port on 127.0.0.1, keeps every
# non-web service off the shared proxy network, and never mounts host paths the user did not choose.
Set-StrictMode -Version 2.0

$script:TrustedRegistries = @('docker.io', 'ghcr.io', 'lscr.io', 'quay.io', 'registry.gitlab.com', 'mcr.microsoft.com', 'public.ecr.aws', 'gcr.io', 'registry.k8s.io', 'codeberg.org', 'docker.n8n.io', 'registry.rocket.chat')

function Get-PpProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Get-PpEntries($Map) {
  if ($null -eq $Map) { return @() }
  if ($Map -is [System.Collections.IDictionary]) { return @($Map.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $Map[$_] } }) }
  return @($Map.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
}

function Get-TrustedRegistries { return $script:TrustedRegistries }

function New-Finding([string]$Id, [string]$Severity, [string]$Area, [string]$Message) {
  return [ordered]@{ id = $Id; severity = $Severity; area = $Area; message = $Message }
}

# Pure: every security-relevant property of the manifest, most severe first.
function Get-ManifestSecurityFindings($Manifest) {
  $f = New-Object System.Collections.ArrayList
  $add = { param($id, $sev, $area, $msg) $null = $f.Add((New-Finding $id $sev $area $msg)) }
  $draft = Get-PpProp $Manifest 'draft' $null
  foreach ($u in @(Get-PpProp $draft 'unsupported' @())) { & $add "unsupported:$(Get-PpProp $u 'field' '')" 'block' 'compatibility' ([string](Get-PpProp $u 'reason' '')) }
  $web = [string](Get-PpProp (Get-PpProp $Manifest 'web' $null) 'service' '')
  foreach ($sp in (Get-PpEntries (Get-PpProp $Manifest 'services' $null))) {
    $n = $sp.Name; $s = $sp.Value
    $img = [string](Get-PpProp $s 'image' '')
    if ($img -notmatch '@sha256:[0-9a-f]{64}$') { & $add "unpinned:$n" 'block' 'supply-chain' "The image of '$n' ($img) is not pinned by digest; it cannot be installed until the digest is resolved." }
    $reg = $(if ($img -match '^([a-z0-9.-]+\.[a-z]{2,}(?::\d+)?)/') { $Matches[1] } else { 'docker.io' })
    if ($script:TrustedRegistries -notcontains $reg) { & $add "registry:$n" 'review' 'supply-chain' "The image of '$n' comes from $reg, which is not one of the well-known public registries." }
    if ($img -match ':latest@') { & $add "latest:$n" 'info' 'supply-chain' "'$n' uses the tag 'latest', pinned to today's digest; updates are never automatic." }
    $role = [string](Get-PpProp $s 'role' '')
    if ($n -eq $web -and $role -in 'database', 'cache', 'messaging') { & $add "web-db:$n" 'block' 'network' "The web interface '$n' is a $role; databases and caches are never published." }
    if ($role -in 'database', 'cache', 'messaging' -and [bool](Get-PpProp $s 'proxy' $false)) { & $add "proxy-db:$n" 'block' 'network' "'$n' is a $role and may not join the shared proxy network." }
    if ([bool](Get-PpProp $s 'privileged' $false)) { & $add "privileged:$n" 'high' 'privileges' "'$n' runs privileged: it has full control of the Docker VM, including other containers' data." }
    if ([bool](Get-PpProp $s 'dockerSocket' $false)) {
      if ([bool](Get-PpProp $s 'dockerSocketReadOnly' $false)) { & $add "socket:$n" 'high' 'privileges' "'$n' mounts the Docker socket read-only: it can see every container and its settings (including other apps' environment variables)." }
      else { & $add "socket:$n" 'high' 'privileges' "'$n' mounts the Docker socket read-write: it can start, stop and create any container (equivalent to administrator access to Docker)." }
    }
    if ([string](Get-PpProp $s 'networkMode' '') -eq 'host') { & $add "hostnet:$n" 'high' 'network' "'$n' uses the host network: it is not isolated and can open any port on the Docker VM." }
    foreach ($d in @(Get-PpProp $s 'devices' @())) { & $add "device:${n}:$d" 'high' 'privileges' "'$n' needs the host device $d." }
    if (Get-PpProp $s 'gpus' $false) { & $add "gpu:$n" 'review' 'hardware' "'$n' uses a GPU." }
    $cmd = @(@(Get-PpProp $s 'entrypoint' @()) + @(Get-PpProp $s 'command' @()) | ForEach-Object { [string]$_ })
    if ($cmd.Count) {
      $joined = $cmd -join ' '
      if ($joined -match '(^|\s)(sh|bash|ash|/bin/sh|/bin/bash)\s+-c\b' -or $joined -match '(curl|wget)[^|]*\|\s*(sh|bash)') { & $add "shell:$n" 'review' 'commands' "'$n' starts a shell command inside its container: $(if ($joined.Length -gt 160) { $joined.Substring(0, 160) + '...' } else { $joined })" }
      else { & $add "command:$n" 'info' 'commands' "'$n' runs: $(if ($joined.Length -gt 160) { $joined.Substring(0, 160) + '...' } else { $joined })" }
    }
    # Credentials written into settings (a password inside a URL that is not a generated secret).
    foreach ($e in (Get-PpEntries (Get-PpProp $s 'environment' $null))) {
      if ([string]$e.Value -match '^[A-Za-z][A-Za-z0-9+.-]*://[^:/@\s]*:([^@\s]+)@' -and $Matches[1] -notmatch '^\{\{input:[A-Za-z0-9]+\}\}$') { & $add "credential:${n}:$($e.Name)" 'high' 'secrets' "'$n' has a fixed password inside $($e.Name). Example credentials are public; replace it with a secret before installing." }
    }
    $hc = Get-PpProp $s 'healthcheck' $null
    if ($hc -and @(Get-PpProp $hc 'test' @())[0] -eq 'CMD-SHELL') { & $add "hcshell:$n" 'info' 'commands' "'$n' has a shell health check (runs inside the container)." }
    foreach ($v in @(Get-PpProp $s 'volumes' @())) { if ([string](Get-PpProp $v 'kind' 'volume') -eq 'folder' -or (Get-PpProp $v 'input' '')) { & $add "folder:${n}:$(Get-PpProp $v 'name' '')" 'info' 'storage' "'$n' can use a folder of this PC for $(Get-PpProp $v 'target' '') (only a folder you choose; otherwise a Docker volume)." } }
  }
  foreach ($p in @(Get-PpProp $Manifest 'postInstall' @())) { & $add 'postinstall' 'block' 'commands' 'Imported applications may not run first-start commands (postInstall); only curated recipes can.' ; break }
  foreach ($x in @(Get-PpProp $Manifest 'files' @())) { & $add "file:$(Get-PpProp $x 'path' '')" 'review' 'storage' "A configuration file '$(Get-PpProp $x 'path' '')' is written into the project folder." }
  foreach ($u in @(Get-PpProp $draft 'unresolved' @())) { & $add "unresolved:$(Get-PpProp $u 'field' '')" 'review' 'completeness' ([string](Get-PpProp $u 'reason' '')) }
  if ([string](Get-PpProp $Manifest 'license' '') -eq 'NOASSERTION') { & $add 'license' 'info' 'provenance' 'No licence was found in the source; check the project before relying on it.' }
  $status = [string](Get-PpProp (Get-PpProp $Manifest 'verification' $null) 'status' 'unverified')
  if ($status -ne 'verified') { & $add 'unverified' 'info' 'provenance' 'This installation recipe has not been verified on this kind of host yet.' }
  $order = @{ block = 0; high = 1; review = 2; info = 3 }
  return @($f | Sort-Object { $order[[string]$_.severity] })
}

# Pure: whether the manifest can run on the host described by an adapter (lib\HostPlatform.psm1).
# Returns { status: compatible | limited | incompatible; items: [{ level, message }] }.
function Get-HostCompatibility($Manifest, $Adapter) {
  $items = New-Object System.Collections.ArrayList
  $add = { param($level, $msg) $null = $items.Add([ordered]@{ level = $level; message = $msg }) }
  if ([string](Get-PpProp $Adapter 'status' '') -ne 'implemented') { & $add 'incompatible' "$(Get-PpProp $Adapter 'name' 'This host') is not supported by this version." }
  $support = [string](Get-PpProp (Get-PpProp $Manifest 'platforms' $null) ([string](Get-PpProp $Adapter 'id' '')) 'untested')
  if ($support -eq 'unsupported') { & $add 'incompatible' "The application is marked unsupported on $(Get-PpProp $Adapter 'name' '')." }
  elseif ($support -eq 'limited') { & $add 'limited' "The application is marked limited on $(Get-PpProp $Adapter 'name' '')." }
  # Curated manifests name architectures as Docker does (amd64), imported drafts and host adapters as platforms
  # (linux/amd64): compare without the OS part.
  $archs = @(@(Get-PpProp $Manifest 'architectures' @()) | ForEach-Object { ([string]$_) -replace '^linux/', '' })
  $hostArchs = @(@(Get-PpProp $Adapter 'architectures' @()) | ForEach-Object { ([string]$_) -replace '^linux/', '' })
  if ($archs.Count -and $hostArchs.Count -and -not @($archs | Where-Object { $a = $_; @($hostArchs | Where-Object { $a -like "$_*" }).Count }).Count) { & $add 'incompatible' "The image is published for $($archs -join ', '), not for this host ($($hostArchs -join ', '))." }
  $hw = Get-PpProp $Manifest 'hardware' $null
  $gpuNeeded = [bool](Get-PpProp $hw 'gpu' $false)
  foreach ($sp in (Get-PpEntries (Get-PpProp $Manifest 'services' $null))) { if ((Get-PpProp $sp.Value 'gpus' $false) -eq $true) { $gpuNeeded = $true } }
  if ($gpuNeeded) {
    switch ([string](Get-PpProp $Adapter 'gpu' 'none')) {
      'none' { & $add 'incompatible' 'The application needs a GPU, which this host does not provide to containers.' }
      'nvidia-experimental' { & $add 'limited' 'GPU access on Docker Desktop is experimental and works only with NVIDIA drivers that support WSL2.' }
    }
  }
  $devs = @(Get-PpProp $hw 'devices' @()); foreach ($sp in (Get-PpEntries (Get-PpProp $Manifest 'services' $null))) { $devs += @(Get-PpProp $sp.Value 'devices' @()) }
  $devs = @($devs | Where-Object { $_ } | Select-Object -Unique)
  if ($devs.Count -and [string](Get-PpProp $Adapter 'devices' 'none') -eq 'none') { & $add 'incompatible' "The application needs host devices ($($devs -join ', ')); Docker Desktop containers cannot use devices of this PC." }
  $hostNet = [bool](Get-PpProp $hw 'hostNetwork' $false)
  foreach ($sp in (Get-PpEntries (Get-PpProp $Manifest 'services' $null))) { if ([string](Get-PpProp $sp.Value 'networkMode' '') -eq 'host') { $hostNet = $true } }
  if ($hostNet -and [string](Get-PpProp $Adapter 'hostNetwork' '') -eq 'limited') { & $add 'limited' 'Host networking is limited on Docker Desktop: discovery protocols (DLNA, mDNS) and ports outside the web interface may not work.' }
  $web = [string](Get-PpProp (Get-PpProp $Manifest 'web' $null) 'service' '')
  if ($web) {
    $ws = Get-PpProp (Get-PpProp $Manifest 'services' $null) $web $null
    $extra = @(@(Get-PpProp $ws 'ports' @()) | Where-Object { -not (Get-PpProp $_ 'primary' $false) })
    if ($extra.Count) { & $add 'limited' "Only the web interface is published; other ports ($(@($extra | ForEach-Object { "$($_.container)/$($_.protocol)" }) -join ', ')) are reachable only from other containers." }
  }
  foreach ($k in @(Get-PpProp $Manifest 'knownIssues' @())) { if ([string]$k -match 'Unraid') { & $add 'info' ([string]$k) } }
  $status = $(if (@($items | Where-Object { $_.level -eq 'incompatible' }).Count) { 'incompatible' } elseif (@($items | Where-Object { $_.level -eq 'limited' }).Count) { 'limited' } else { 'compatible' })
  return [ordered]@{ status = $status; host = [string](Get-PpProp $Adapter 'name' ''); items = @($items) }
}

# Pure: whether the findings allow an installation, given the acknowledgements the user sent (finding ids).
function Test-FindingsAcknowledged([object[]]$Findings, [string[]]$Acknowledged = @()) {
  $blocked = @($Findings | Where-Object { $_.severity -eq 'block' })
  $missing = @($Findings | Where-Object { $_.severity -in 'high', 'review' -and $Acknowledged -notcontains [string]$_.id })
  return [ordered]@{ ok = (-not $blocked.Count -and -not $missing.Count); blocked = @($blocked | ForEach-Object { $_.id }); missing = @($missing | ForEach-Object { $_.id }) }
}

Export-ModuleMember -Function Get-TrustedRegistries, Get-ManifestSecurityFindings, Get-HostCompatibility, Test-FindingsAcknowledged
