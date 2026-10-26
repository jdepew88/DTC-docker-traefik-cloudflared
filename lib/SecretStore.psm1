#requires -version 5.1
# Named secrets of a deployment (for example the authentik API token), stored in <deployment>\secrets\<name>.dpapi.
#
# Host adapter: on Windows the value is encrypted with DPAPI for the current Windows account and the file gets the
# restricted ACL of the other secret files (Set-SecretFileAcl). Other hosts need their own implementation of the four
# functions below (for example a 0600 file owned by the service user); nothing else in the manager reads these files.
# Values never leave the server: the web UI only sees Get-ProtectedSecretInfo (metadata).
Set-StrictMode -Version 2.0

$script:Entropy = [Text.Encoding]::UTF8.GetBytes('traefik-proxy-webui/secret-store/v1')
$script:NamePattern = '^[a-z0-9][a-z0-9_-]{1,40}$'
Add-Type -AssemblyName System.Security

function Get-ProtectedSecretPath($Settings, [string]$Name) {
  if ($Name -notmatch $script:NamePattern) { throw "Invalid secret name '$Name'." }
  return (Join-Path (Join-Path $Settings.InstallPath 'secrets') "$Name.dpapi")
}

function Save-ProtectedSecret {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Value, [string]$Label = '')
  $path = Get-ProtectedSecretPath $Settings $Name
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  $cipher = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Value), $script:Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  $doc = [ordered]@{ version = 1; scope = 'DPAPI-CurrentUser'; label = $Label; user = "$env:USERDOMAIN\$env:USERNAME"; savedAt = (Get-Date -Format 's'); data = [Convert]::ToBase64String($cipher) }
  $tmp = $path + '.tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Compress))
  Move-Item -LiteralPath $tmp -Destination $path -Force
  Set-SecretFileAcl $path
}

# Plaintext for server-side use only (API calls). Never return it to the browser or write it to a log.
function Read-ProtectedSecret {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Name)
  $path = Get-ProtectedSecretPath $Settings $Name
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json; if (-not $doc.PSObject.Properties['data']) { throw 'no data' } } catch { throw "The stored secret '$Name' is damaged. Save it again." }
  try { $plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($doc.data), $script:Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser) }
  catch { throw "The stored secret '$Name' cannot be decrypted by this Windows account (it was saved by another user or machine). Save it again." }
  return [Text.Encoding]::UTF8.GetString($plain)
}

function Get-ProtectedSecretInfo {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Name)
  $path = Get-ProtectedSecretPath $Settings $Name
  if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Stored = $false; Readable = $false; SavedAt = ''; User = ''; Label = '' } }
  $doc = $null; try { $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { }
  $readable = $true
  try { $null = Read-ProtectedSecret -Settings $Settings -Name $Name } catch { $readable = $false }
  $field = { param($n) if ($doc -and $doc.PSObject.Properties[$n]) { [string]$doc.$n } else { '' } }
  return [pscustomobject]@{ Stored = $true; Readable = $readable; SavedAt = (& $field 'savedAt'); User = (& $field 'user'); Label = (& $field 'label') }
}

function Remove-ProtectedSecret {
  param([Parameter(Mandatory = $true)]$Settings, [Parameter(Mandatory = $true)][string]$Name)
  $path = Get-ProtectedSecretPath $Settings $Name
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; return $true }
  return $false
}

Export-ModuleMember -Function Get-ProtectedSecretPath, Save-ProtectedSecret, Read-ProtectedSecret, Get-ProtectedSecretInfo, Remove-ProtectedSecret
