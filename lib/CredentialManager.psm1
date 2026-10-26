#requires -version 5.1
# Reusable credential management for API integrations (authentik today; Authelia, Cloudflare and others later).
#
# A credential is one secret in the SecretStore (secrets\<name>.dpapi) plus a non-secret status record in
# config\credentials.json: who it belongs to, which server it was checked against, when it last validated, its expiry
# date and the last failed attempt. Each integration supplies only a validator scriptblock:
#
#   param([string]$Secret) -> @{ Ok; Status; Message; Account; Server; Version; ExpiresAt; Details }
#   Status: valid | rejected | expired | revoked | insufficient | unreachable
#
# Rules: a candidate replaces the stored secret only after it validated successfully; a failed candidate leaves the
# stored secret and its record untouched (only "last attempt" is noted); "unreachable" says nothing about the secret.
# Secret values never appear in a returned object, a record or an error message.
Set-StrictMode -Version 2.0

$script:RecordFile = 'config\credentials.json'
$script:ExpiryWarningDays = 14

function Get-CmProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Read-CredentialRecords($Settings) {
  $path = Join-Path $Settings.InstallPath $script:RecordFile
  if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{} }
  try { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return [pscustomobject]@{} }
}

function Get-CredentialRecord($Settings, [string]$Id) {
  $all = Read-CredentialRecords $Settings
  $p = $all.PSObject.Properties[$Id]
  $r = [ordered]@{ status = ''; message = ''; account = ''; server = ''; version = ''; expiresAt = ''; lastValidatedAt = ''; lastSuccessAt = ''; rotatedAt = ''; lastAttempt = $null }
  if ($p) { foreach ($k in @($r.Keys)) { $v = Get-CmProp $p.Value $k $null; if ($null -ne $v) { $r[$k] = $v } } }
  return $r
}

function Save-CredentialRecord($Settings, [string]$Id, $Record) {
  $all = Read-CredentialRecords $Settings
  $o = [ordered]@{}
  foreach ($p in $all.PSObject.Properties) { if ($p.Name -ne $Id) { $o[$p.Name] = $p.Value } }
  if ($null -ne $Record) { $o[$Id] = $Record }
  $path = Join-Path $Settings.InstallPath $script:RecordFile
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  Write-TextFileAtomic $path ((ConvertTo-StableJson ([pscustomobject]$o)) + "`n")
}

function ConvertTo-IsoTime($Value) {
  if (-not $Value) { return '' }
  try { return ([datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString('s') } catch { return [string]$Value }
}

# Runs the validator and normalizes its result. A validator that throws is "unreachable" (with the message).
function Invoke-CredentialValidator([scriptblock]$Validator, [string]$Secret) {
  $r = $null
  try { $r = & $Validator $Secret } catch { $r = @{ Ok = $false; Status = 'unreachable'; Message = $_.Exception.Message } }
  $status = [string](Get-CmProp $r 'Status' $(if (Get-CmProp $r 'Ok' $false) { 'valid' } else { 'rejected' }))
  return [pscustomobject][ordered]@{
    Ok = [bool](Get-CmProp $r 'Ok' $false) -and $status -eq 'valid'; Status = $status; Message = [string](Get-CmProp $r 'Message' '')
    Account = [string](Get-CmProp $r 'Account' ''); Server = [string](Get-CmProp $r 'Server' ''); Version = [string](Get-CmProp $r 'Version' '')
    ExpiresAt = (ConvertTo-IsoTime (Get-CmProp $r 'ExpiresAt' '')); Details = (Get-CmProp $r 'Details' $null)
  }
}

# The view the web UI shows: metadata only, never the secret.
function Get-CredentialView {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$SecretName, [string]$Label = '')
  $info = Get-ProtectedSecretInfo -Settings $Settings -Name $SecretName
  $rec = Get-CredentialRecord $Settings $Id
  $status = $(if (-not $info.Stored) { 'missing' } elseif (-not $info.Readable) { 'unreadable' } elseif ($rec.status) { [string]$rec.status } else { 'unknown' })
  $expires = [string]$rec.expiresAt
  $days = $null
  if ($expires -and $info.Stored) { try { $days = [Math]::Floor(([datetime]$expires - (Get-Date)).TotalDays) } catch { } }
  if ($null -ne $days -and $days -lt 0 -and $status -in 'valid', 'unknown', 'rejected') { $status = 'expired' }
  $warning = ''
  if ($status -eq 'expired') { $warning = "The token expired on $expires. Replace it." }
  elseif ($null -ne $days -and $days -le $script:ExpiryWarningDays) {
    $left = $(if ($days -lt 1) { $h = [Math]::Max(0, [Math]::Floor(([datetime]$expires - (Get-Date)).TotalHours)); "in $h hour(s)" } else { "in $days day(s)" })
    $warning = "The token expires $left ($expires). Replace it with a non-expiring token (or a new one) before then."
  }
  return [ordered]@{
    id = $Id; label = $Label; stored = [bool]$info.Stored; readable = [bool]$info.Readable; savedAt = [string]$info.SavedAt; savedBy = [string]$info.User
    status = $status; ok = ($status -eq 'valid'); message = $(if ($status -eq 'missing') { 'No credential is saved yet.' } elseif ($status -eq 'unreadable') { 'The saved credential cannot be decrypted by this Windows account (saved by another user or PC). Replace it.' } else { [string]$rec.message })
    account = [string]$rec.account; server = [string]$rec.server; version = [string]$rec.version; expiresAt = $expires; expiresInDays = $days; expiryWarning = $warning
    lastValidatedAt = [string]$rec.lastValidatedAt; lastSuccessAt = [string]$rec.lastSuccessAt; rotatedAt = [string]$rec.rotatedAt; lastAttempt = $rec.lastAttempt
  }
}

# Validates the stored secret and records the outcome. -IfOlderThanMinutes skips the check (returns the recorded view)
# when the last validation is recent, so pages can show live status without calling the API on every request.
function Test-StoredCredential {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$SecretName,
    [Parameter(Mandatory = $true)][scriptblock]$Validator, [string]$Label = '', [int]$IfOlderThanMinutes = 0)
  $info = Get-ProtectedSecretInfo -Settings $Settings -Name $SecretName
  if (-not ($info.Stored -and $info.Readable)) { return Get-CredentialView -Settings $Settings -Id $Id -SecretName $SecretName -Label $Label }
  $rec = Get-CredentialRecord $Settings $Id
  if ($IfOlderThanMinutes -gt 0 -and $rec.lastValidatedAt -and $rec.status -and $rec.status -ne 'unreachable') {
    try { if (((Get-Date) - [datetime]$rec.lastValidatedAt).TotalMinutes -lt $IfOlderThanMinutes) { return Get-CredentialView -Settings $Settings -Id $Id -SecretName $SecretName -Label $Label } } catch { }
  }
  $secret = Read-ProtectedSecret -Settings $Settings -Name $SecretName
  $v = Invoke-CredentialValidator $Validator $secret
  $secret = $null
  $now = Get-Date -Format 's'
  if ($v.Status -eq 'unreachable') {
    # Says nothing about the credential: keep its last known state, note the attempt.
    $rec.lastAttempt = [ordered]@{ at = $now; status = 'unreachable'; message = $v.Message; candidate = $false }
    if (-not $rec.status) { $rec.status = 'unreachable'; $rec.message = $v.Message }
  } else {
    # A token that disappeared after its recorded expiry date is reported as expired.
    $status = $v.Status
    if (-not $v.Ok -and $status -eq 'rejected' -and $rec.expiresAt) { try { if ([datetime]$rec.expiresAt -lt (Get-Date)) { $status = 'expired' } } catch { } }
    $rec.status = $status; $rec.message = $v.Message; $rec.lastValidatedAt = $now
    if ($v.Account) { $rec.account = $v.Account }; if ($v.Server) { $rec.server = $v.Server }; if ($v.Version) { $rec.version = $v.Version }
    if ($v.Ok) { $rec.lastSuccessAt = $now; $rec.expiresAt = $v.ExpiresAt }
  }
  Save-CredentialRecord $Settings $Id $rec
  $view = Get-CredentialView -Settings $Settings -Id $Id -SecretName $SecretName -Label $Label
  if ($v.Status -eq 'unreachable') { $view.status = 'unreachable'; $view.ok = $false; $view.message = $v.Message }
  return $view
}

# Validates a candidate and, only if it is valid, makes it the stored credential. Returns Ok, Replaced, Result (the
# candidate's validation, no secret) and View (the stored credential afterwards: unchanged when the candidate failed).
function Set-CredentialFromCandidate {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$SecretName,
    [Parameter(Mandatory = $true)][string]$Candidate, [Parameter(Mandatory = $true)][scriptblock]$Validator, [string]$Label = '')
  $v = Invoke-CredentialValidator $Validator $Candidate
  $now = Get-Date -Format 's'
  $rec = Get-CredentialRecord $Settings $Id
  if (-not $v.Ok) {
    $rec.lastAttempt = [ordered]@{ at = $now; status = $v.Status; message = $v.Message; candidate = $true; account = $v.Account }
    Save-CredentialRecord $Settings $Id $rec
    $Candidate = $null
    return [pscustomobject]@{ Ok = $false; Replaced = $false; Result = $v; View = (Get-CredentialView -Settings $Settings -Id $Id -SecretName $SecretName -Label $Label) }
  }
  $hadOne = (Get-ProtectedSecretInfo -Settings $Settings -Name $SecretName).Stored
  Save-ProtectedSecret -Settings $Settings -Name $SecretName -Value $Candidate -Label $(if ($v.Account) { "$Label ($($v.Account))" } else { $Label })
  $Candidate = $null
  $new = [ordered]@{ status = 'valid'; message = $v.Message; account = $v.Account; server = $v.Server; version = $v.Version; expiresAt = $v.ExpiresAt
    lastValidatedAt = $now; lastSuccessAt = $now; rotatedAt = $(if ($hadOne) { $now } else { [string]$rec.rotatedAt }); lastAttempt = [ordered]@{ at = $now; status = 'valid'; message = 'Saved.'; candidate = $true; account = $v.Account } }
  Save-CredentialRecord $Settings $Id $new
  return [pscustomobject]@{ Ok = $true; Replaced = [bool]$hadOne; Result = $v; View = (Get-CredentialView -Settings $Settings -Id $Id -SecretName $SecretName -Label $Label) }
}

function Remove-StoredCredential {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$SecretName)
  $removed = Remove-ProtectedSecret -Settings $Settings -Name $SecretName
  Save-CredentialRecord $Settings $Id $null
  return $removed
}

Export-ModuleMember -Function Get-CredentialRecord, Save-CredentialRecord, Get-CredentialView, Test-StoredCredential, Set-CredentialFromCandidate, Remove-StoredCredential, Invoke-CredentialValidator
