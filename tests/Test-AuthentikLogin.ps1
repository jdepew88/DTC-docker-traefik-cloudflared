#requires -version 5.1
<#
.SYNOPSIS
  Offline tests of lib\AuthentikLogin.psm1 (DTC sign-in experience): configuration, CSS, the login_hint expression and
  the template files. No authentik, Docker or network needed. The page script itself: node tests\authentik-login.test.js;
  in a browser: tests\Test-AuthentikLoginBrowser.ps1.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'lib\AuthentikLogin.psm1') -Force -DisableNameChecking
$script:pass = 0; $script:fail = 0
function Test-Condition([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { $script:pass++; Write-Host "[PASS] $Name" -ForegroundColor Green } else { $script:fail++; Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('dtc-login-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp 'config') -Force | Out-Null
try {
  # Configuration.
  $cfg = Get-AuthentikLoginConfig -OwnerEmail 'owner@example.com'
  Test-Condition 'defaults: valid, owner filled in, three points in order' ((Test-AuthentikLoginConfig $cfg).Count -eq 0 -and $cfg.ownerEmail -eq 'owner@example.com' -and @($cfg.pictureShortcut.points).Count -eq 3 -and $cfg.pictureShortcut.points[0].name -eq 'Left snowfield')
  $f = Initialize-AuthentikLoginConfigFile -InstallPath $tmp -OwnerEmail 'owner@example.com'
  $doc = [IO.File]::ReadAllText($f) | ConvertFrom-Json
  Test-Condition 'config file: created from the defaults with the owner' ($doc.ownerEmail -eq 'owner@example.com' -and @($doc.pictureShortcut.points).Count -eq 3)
  $doc.pictureShortcut.points = @($doc.pictureShortcut.points) + [pscustomobject]@{ name = 'Fourth'; x = 0.1; y = 0.4; r = 0.03 }
  $doc.pictureShortcut.tapTimeoutMs = 8000
  [IO.File]::WriteAllText($f, (ConvertTo-Json $doc -Depth 6))
  $four = Get-AuthentikLoginConfig -InstallPath $tmp -OwnerEmail 'other@example.com'
  Test-Condition 'config file: four points and a new timeout are read; the file''s owner wins' (@($four.pictureShortcut.points).Count -eq 4 -and $four.pictureShortcut.tapTimeoutMs -eq 8000 -and $four.ownerEmail -eq 'owner@example.com' -and (Test-AuthentikLoginConfig $four).Count -eq 0)
  $null = Initialize-AuthentikLoginConfigFile -InstallPath $tmp -OwnerEmail 'x@example.com'
  Test-Condition 'config file: never overwritten once it exists' (([IO.File]::ReadAllText($f) | ConvertFrom-Json).pictureShortcut.tapTimeoutMs -eq 8000)
  $bad = Get-AuthentikLoginConfig -OwnerEmail 'nope'
  $bad.pictureShortcut.points = @([pscustomobject]@{ x = 1.5; y = 0.2 }); $bad.pictureShortcut.tapTimeoutMs = 10
  $errs = Test-AuthentikLoginConfig $bad
  Test-Condition 'validation: bad owner, coordinate, point count and timeout are all reported' ($errs.Count -ge 4) ($errs -join ' | ')
  $attr = ConvertTo-AuthentikLoginAttribute $four
  Test-Condition 'brand attribute: flow, owner and points, nothing else' ($attr.flowSlug -eq 'dm-login' -and $attr.ownerEmail -eq 'owner@example.com' -and @($attr.pictureShortcut.points).Count -eq 4 -and -not ((ConvertTo-Json $attr -Depth 6) -match 'secret|token|password'))

  # CSS: upstream theme unmodified, DTC additions after it, picture from authentik.
  $css = Get-AuthentikLoginCss
  $theme = [IO.File]::ReadAllText((Join-Path (Get-AuthentikLoginAssetDir) 'upstream\theme.css'))
  $iTheme = $css.IndexOf($theme.TrimEnd()); $iAdd = $css.IndexOf('DTC ADDITIONS')
  Test-Condition 'css: upstream theme included unmodified, DTC additions after it' ($iTheme -ge 0 -and $iAdd -gt $iTheme)
  Test-Condition 'css: the picture comes from authentik (--ak-global--background-image), not imgur' ($css.LastIndexOf('--ak-flow-background: var(--ak-global--background-image)') -gt $css.IndexOf('i.imgur.com'))
  Test-Condition 'css: brand CSS stays within a sensible size' ($css.Length -lt 200KB)

  # login_hint expression.
  $e = New-AuthentikLoginHintExpression 'owner@example.com'
  Test-Condition 'hint: sets pending_user_identifier only when empty, always passes' ($e -match 'if plan is not None and not plan\.context\.get\("pending_user_identifier"\):' -and $e -match '"owner@example.com"' -and $e.TrimEnd().EndsWith('return True'))
  $threw = $false; try { $null = New-AuthentikLoginHintExpression 'x"; import os; "' } catch { $threw = $true }
  Test-Condition 'hint: refuses anything that is not an email address (no code injection)' $threw

  # Template files.
  $ak = Join-Path $tmp 'authentik'; New-Item -ItemType Directory -Path (Join-Path $ak 'custom-templates') -Force | Out-Null
  $r1 = Install-AuthentikLoginTemplates -AuthentikFolder $ak
  $r2 = Install-AuthentikLoginTemplates -AuthentikFolder $ak
  Test-Condition 'templates: first install changes (restart needed), second does not' ($r1.Changed -and -not $r2.Changed -and @($r2.Files | Where-Object { $_.Status -ne 'unchanged' }).Count -eq 0)
  $removed = Remove-AuthentikLoginTemplates -AuthentikFolder $ak
  Test-Condition 'templates: removal deletes only our files' ($removed.Count -eq 2 -and -not (Test-Path (Join-Path $ak 'custom-templates\if')) -and (Test-Path (Join-Path $ak 'custom-templates')))
  New-Item -ItemType Directory -Path (Join-Path $ak 'custom-templates\if') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $ak 'custom-templates\if\flow.html'), '{% extends "if/flow.html" %}{# someone else''s #}')
  $refused = $false; try { $null = Install-AuthentikLoginTemplates -AuthentikFolder $ak } catch { $refused = $_.Exception.Message -match 'not written by the Deployment Manager' }
  Test-Condition 'templates: a foreign if\flow.html is never replaced' ($refused -and ([IO.File]::ReadAllText((Join-Path $ak 'custom-templates\if\flow.html'))).Contains('someone else'))
  $what = Install-AuthentikLoginTemplates -AuthentikFolder (Join-Path $tmp 'empty') -WhatIf -ErrorAction SilentlyContinue 2>$null
} catch {
  if ($_.Exception.Message -match 'custom-templates folder') { Test-Condition 'templates: a project without custom-templates is reported' $true } else { Test-Condition 'unexpected error' $false $_.Exception.Message }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
