#requires -version 5.1
# Installation recipes: how an application was installed successfully on a kind of host. A recipe is the application
# manifest (no values, no secrets) plus the host fingerprint (no host name, user name, paths or addresses), the image
# digests and the verification evidence. Local first: recipes live in the deployment's config\recipes\ folder and can
# be exported and imported as files. Sharing is opt-in and always previewed (ConvertTo-SanitizedRecipe); the manager
# never uploads anything by itself, and nothing depends on a community server (docs/community-recipes.md describes the
# future registry protocol and trust model).
#
# Trust: a recipe's own claims ('claimed') are kept apart from what this manager verified itself ('verified-local').
# Ranking (Get-RecipeRanking) explains every score; it never picks the most popular recipe blindly, and conflicting
# recipes for different hosts or versions coexist.
Set-StrictMode -Version 2.0

$script:RecipeVersion = 1
$script:Origins = @('curated', 'upstream', 'local', 'community')

function Get-RcProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Get-RcSha256([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant()) } finally { $sha.Dispose() }
}

function Get-RcEntries($Map) {
  if ($null -eq $Map) { return @() }
  if ($Map -is [System.Collections.IDictionary]) { return @($Map.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $Map[$_] } }) }
  return @($Map.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
}

# The manifest as it goes into a recipe: structure only. Draft notes, provenance documents (URLs of what was fetched)
# and folder hints are kept; input defaults are kept only when they are not secret-like.
function ConvertTo-RecipeManifest($Manifest) {
  $copy = ($Manifest | ConvertTo-Json -Depth 20) | ConvertFrom-Json
  foreach ($i in @(Get-RcProp $copy 'inputs' @())) {
    if ([string](Get-RcProp $i 'type' '') -in 'secret', 'password', 'generated', 'derived', 'folder' -and $i.PSObject.Properties['default']) { $i.PSObject.Properties.Remove('default') }
  }
  if ($copy.PSObject.Properties['draft']) { $copy.draft.PSObject.Properties.Remove('evidence') }
  return $copy
}

# A recipe from one verified (or attempted) deployment. $Verification: stages { stage; status } from the provisioner.
function New-Recipe {
  param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)]$HostFingerprint, [object[]]$Verification = @(), [string]$Origin = 'local', [string[]]$KnownIssues = @())
  if ($script:Origins -notcontains $Origin) { throw "Unknown recipe origin '$Origin'." }
  $m = ConvertTo-RecipeManifest $Manifest
  $mjson = $m | ConvertTo-Json -Depth 20 -Compress
  $images = @(Get-RcEntries (Get-RcProp $m 'services' $null) | ForEach-Object { [ordered]@{ service = $_.Name; image = [string](Get-RcProp $_.Value 'image' '') } })
  $passed = @($Verification | Where-Object { [string](Get-RcProp $_ 'status' '') -eq 'passed' } | ForEach-Object { [string](Get-RcProp $_ 'stage' '') })
  $failed = @($Verification | Where-Object { [string](Get-RcProp $_ 'status' '') -eq 'failed' } | ForEach-Object { [string](Get-RcProp $_ 'stage' '') })
  $healthy = $passed -contains 'backend' -or $passed -contains 'dependencies'
  return [ordered]@{
    recipeVersion = $script:RecipeVersion
    id = "$([string](Get-RcProp $m 'id' 'app'))-$((Get-RcSha256 ($mjson + ($HostFingerprint | ConvertTo-Json -Compress))).Substring(0, 12))"
    application = [ordered]@{ id = [string](Get-RcProp $m 'id' ''); name = [string](Get-RcProp $m 'name' ''); upstream = [string](Get-RcProp (Get-RcProp $m 'source' $null) 'upstream' ''); version = [string](Get-RcProp $m 'manifestVersion' '') }
    manifest = $m; manifestSha256 = (Get-RcSha256 $mjson); images = $images
    host = [ordered]@{ platform = [string](Get-RcProp $HostFingerprint 'platform' ''); os = [string](Get-RcProp $HostFingerprint 'os' ''); osVersion = [string](Get-RcProp $HostFingerprint 'osVersion' ''); architecture = [string](Get-RcProp $HostFingerprint 'architecture' '')
      kernel = [string](Get-RcProp $HostFingerprint 'kernel' ''); dockerEngine = [string](Get-RcProp $HostFingerprint 'dockerEngine' ''); dockerCompose = [string](Get-RcProp $HostFingerprint 'dockerCompose' ''); runtime = [string](Get-RcProp $HostFingerprint 'runtime' '') }
    validation = [ordered]@{ stages = @($Verification | ForEach-Object { [ordered]@{ stage = [string](Get-RcProp $_ 'stage' ''); status = [string](Get-RcProp $_ 'status' '') } }); passed = $passed; failed = $failed; healthCheck = $healthy; verifiedAt = $(if (-not $failed.Count -and $passed.Count) { (Get-Date).ToUniversalTime().ToString('s') + 'Z' } else { '' }) }
    knownIssues = @($KnownIssues)
    provenance = [ordered]@{ origin = $Origin; source = [string](Get-RcProp (Get-RcProp $m 'source' $null) 'url' ''); sourceKind = [string](Get-RcProp (Get-RcProp $m 'source' $null) 'kind' ''); createdAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
    trust = [ordered]@{ status = $(if ($Origin -eq 'local' -and -not $failed.Count -and $passed.Count) { 'verified-local' } else { 'claimed' }); deployments = 1; failureReports = $failed.Count; securityReview = '' }
    privacy = [ordered]@{ sanitized = $false }
  }
}

# Pure: rules every recipe must satisfy before it is stored, imported or shared. Returns error strings.
function Test-Recipe($Recipe) {
  $e = New-Object System.Collections.ArrayList
  $add = { param($t) $null = $e.Add($t) }
  if ([int](Get-RcProp $Recipe 'recipeVersion' 0) -ne $script:RecipeVersion) { & $add "recipeVersion must be $($script:RecipeVersion)" }
  if ([string](Get-RcProp $Recipe 'id' '') -notmatch '^[a-z0-9][a-z0-9-]{0,60}$') { & $add 'id is invalid' }
  $m = Get-RcProp $Recipe 'manifest' $null
  if (-not $m) { & $add 'manifest is required'; return $e.ToArray() }
  $mjson = $m | ConvertTo-Json -Depth 20 -Compress
  if ((Get-RcSha256 $mjson) -ne [string](Get-RcProp $Recipe 'manifestSha256' '')) { & $add 'manifestSha256 does not match the manifest (changed after it was created)' }
  foreach ($i in @(Get-RcProp $Recipe 'images' @())) { if ([string](Get-RcProp $i 'image' '') -notmatch '@sha256:[0-9a-f]{64}$') { & $add "image of '$(Get-RcProp $i 'service' '')' is not pinned by digest" } }
  if ([string](Get-RcProp (Get-RcProp $Recipe 'provenance' $null) 'origin' '') -notin $script:Origins) { & $add 'provenance.origin is invalid' }
  if (@(Get-RcProp $m 'postInstall' @()).Count) { & $add 'recipes may not contain first-start commands (postInstall)' }
  $text = $Recipe | ConvertTo-Json -Depth 25 -Compress
  if ($text -match '(?i)"(password|secret|token|apikey|api_key)"\s*:\s*"[^"]{6,}"') { & $add 'the recipe appears to contain a secret value' }
  if ($text -match '[A-Za-z]:\\\\(Users|Documents and Settings)\\\\') { & $add 'the recipe contains a Windows user path' }
  if ($text -match '/(home|Users)/[a-z0-9_.-]+/' -and $text -notmatch '/home/<user>/') { & $add 'the recipe contains a home folder path' }
  return $e.ToArray()
}

# Pure: what sharing would publish, with everything private removed: host names and domains of this deployment, user
# and machine names, private and public IP addresses, local paths, e-mail addresses, and any value that looks secret.
# Returns { Recipe; Removed[] (what was replaced, for the preview) }.
function ConvertTo-SanitizedRecipe($Recipe, [string[]]$PrivateNames = @()) {
  $text = $Recipe | ConvertTo-Json -Depth 25
  $removed = New-Object System.Collections.ArrayList
  $rules = New-Object System.Collections.ArrayList
  $null = $rules.Add(@('e-mail address', '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>'))
  $null = $rules.Add(@('IP address', '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b', '<ip>'))
  $null = $rules.Add(@('Windows path', '(?i)\b[A-Z]:\\\\[^"\s]*', '<path>'))
  $null = $rules.Add(@('home path', '(?i)/(home|Users)/[^/"\s]+', '/$1/<user>'))
  $null = $rules.Add(@('secret-looking value', '(?i)("[A-Za-z0-9_]*(password|secret|token|apikey|api_key)[A-Za-z0-9_]*"\s*:\s*)"[^"]+"', '$1"<removed>"'))
  foreach ($n in @($PrivateNames | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending)) { $null = $rules.Add(@('private name', [regex]::Escape($n), '<private>')) }
  foreach ($r in $rules) {
    $c = [regex]::Matches($text, $r[1]).Count
    if ($c) { $null = $removed.Add([ordered]@{ kind = $r[0]; count = $c }); $text = [regex]::Replace($text, $r[1], $r[2]) }
  }
  $clean = $text | ConvertFrom-Json
  $clean.privacy.sanitized = $true
  # Paths and names may have been part of the manifest: its fingerprint is recomputed for the sanitized copy.
  $clean.manifestSha256 = Get-RcSha256 ($clean.manifest | ConvertTo-Json -Depth 20 -Compress)
  return [pscustomobject]@{ Recipe = $clean; Removed = @($removed) }
}

# Pure: recipes for one application ordered for this host, with the reasons for each score. Incompatible ones stay
# listed (score below zero) so conflicts are visible.
function Get-RecipeRanking([object[]]$Recipes, $HostFingerprint, [datetime]$Now = (Get-Date).ToUniversalTime()) {
  $ranked = foreach ($r in @($Recipes | Where-Object { $_ })) {
    $score = 0; $why = New-Object System.Collections.ArrayList; $archMismatch = $false
    $origin = [string](Get-RcProp (Get-RcProp $r 'provenance' $null) 'origin' '')
    switch ($origin) { 'curated' { $score += 50; $null = $why.Add('+50 curated by the manager') } 'upstream' { $score += 30; $null = $why.Add('+30 official upstream configuration') } 'local' { $score += 20; $null = $why.Add('+20 created on this deployment') } 'community' { $score += 10; $null = $why.Add('+10 community contribution') } }
    $h = Get-RcProp $r 'host' $null
    if ([string](Get-RcProp $h 'architecture' '') -and [string](Get-RcProp $HostFingerprint 'architecture' '') -and [string]$h.architecture -ne [string]$HostFingerprint.architecture) { $score -= 100; $archMismatch = $true; $null = $why.Add("-100 built for $($h.architecture), this host is $($HostFingerprint.architecture)") }
    if ([string](Get-RcProp $h 'platform' '') -eq [string](Get-RcProp $HostFingerprint 'platform' '')) { $score += 20; $null = $why.Add('+20 same host platform') } elseif ([string](Get-RcProp $h 'platform' '')) { $null = $why.Add("+0 recorded on $($h.platform)") }
    $trust = Get-RcProp $r 'trust' $null
    if ([string](Get-RcProp $trust 'status' '') -eq 'verified-local') { $score += 15; $null = $why.Add('+15 verified by this manager (not only claimed)') } else { $null = $why.Add('+0 claimed, not verified here') }
    $dep = [int](Get-RcProp $trust 'deployments' 1)
    if ($dep -gt 1) { $b = [Math]::Min(15, ($dep - 1) * 3); $score += $b; $null = $why.Add("+$b $dep independent successful deployments (capped)") }
    $va = Get-RcProp $r 'validation' $null
    if ([bool](Get-RcProp $va 'healthCheck' $false)) { $score += 10; $null = $why.Add('+10 health-check evidence') }
    $at = [string](Get-RcProp $va 'verifiedAt' '')
    if ($at) { $age = ($Now - [datetime]::Parse($at.TrimEnd('Z'))).TotalDays; if ($age -le 90) { $score += 10; $null = $why.Add('+10 verified in the last 90 days') } elseif ($age -gt 365) { $score -= 10; $null = $why.Add('-10 last verified more than a year ago') } }
    $fails = [int](Get-RcProp $trust 'failureReports' 0)
    if ($fails) { $score -= 15 * $fails; $null = $why.Add("-$(15 * $fails) $fails failure report(s)") }
    if ([string](Get-RcProp $trust 'securityReview' '') -eq 'rejected') { $score -= 50; $null = $why.Add('-50 rejected by security review') }
    [pscustomobject]@{ Recipe = $r; Score = $score; Reasons = @($why); Compatible = (-not $archMismatch -and $score -ge 0) }
  }
  return @($ranked | Sort-Object Score -Descending)
}

# --- Local store and files ---------------------------------------------------------------------------------------------

function Get-RecipeDir($Settings) { return (Join-Path $Settings.InstallPath 'config\recipes') }

function Save-Recipe($Settings, $Recipe) {
  $errors = @(Test-Recipe $Recipe)
  if ($errors.Count) { throw ('The recipe is not valid: ' + ($errors -join '; ')) }
  $dir = Get-RecipeDir $Settings
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $path = Join-Path $dir ("$([string]$Recipe.id).json")
  [IO.File]::WriteAllText($path, (($Recipe | ConvertTo-Json -Depth 25) + "`n"), (New-Object Text.UTF8Encoding($false)))
  return $path
}

function Get-LocalRecipes($Settings, [string]$ApplicationId = '') {
  $dir = Get-RecipeDir $Settings
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | ForEach-Object { try { [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and (-not $ApplicationId -or [string]$_.application.id -eq $ApplicationId) })
}

# Imports a recipe file someone shared: parsed as data, validated, marked 'community' and 'claimed' (its own
# verification claims are kept but never count as verified here). Nothing is installed.
function Import-RecipeText($Settings, [string]$Text) {
  if ($Text.Length -gt 1MB) { throw 'The recipe file is larger than 1 MB.' }
  $r = $null
  try { $r = $Text | ConvertFrom-Json } catch { throw 'The recipe file is not valid JSON.' }
  $errors = @(Test-Recipe $r)
  if ($errors.Count) { throw ('The recipe is not valid: ' + ($errors -join '; ')) }
  if ([string]$r.provenance.origin -ne 'curated') { $r.provenance.origin = 'community' }
  $r.trust.status = 'claimed'
  return (Save-Recipe $Settings $r)
}

# Future community registry: not configured in this version (docs/community-recipes.md).
function Get-RecipeRegistryInfo { return [ordered]@{ configured = $false; url = ''; protocol = 'dtc-recipes/1 (draft)'; note = 'No community registry is configured. Recipes work locally and can be exported and imported as files.' } }

Export-ModuleMember -Function ConvertTo-RecipeManifest, New-Recipe, Test-Recipe, ConvertTo-SanitizedRecipe, Get-RecipeRanking, Get-RecipeDir, Save-Recipe, Get-LocalRecipes, Import-RecipeText, Get-RecipeRegistryInfo
