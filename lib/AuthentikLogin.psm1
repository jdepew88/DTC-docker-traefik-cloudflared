#requires -version 5.1
# DTC sign-in experience for authentik: the Glassmorphism theme, a personalized Google button ("Continue as <owner>")
# and a picture shortcut (tap landmarks of the background picture in order to press that same button).
#
# What lives where (all of it survives a normal redeploy of the authentik project):
#   - authentik database (backed up with authentik): the brand's custom CSS (upstream theme + DTC additions), its default
#     flow background (a file uploaded through authentik's file API), the attribute "dtc_login" (button and picture
#     configuration), the sign-in flow dm-login with its own identification stage, and the expression policy
#     dm-login-google-hint that suggests the owner's Google account to Google (login_hint).
#   - <authentik project>\custom-templates (mounted at /templates, backed up with authentik): if\flow.html, which extends
#     authentik's own template, and dtc\login-experience.js. Inert unless the brand opts in for exactly that flow.
#   - <deployment>\config\login-experience.json: your configuration (points, timeout, label). Defaults:
#     assets\authentik-login\login-experience.default.json.
#
# Security model: the button and the picture only START authentik's Google sign-in (GET /source/oauth/login/<slug>/).
# Google authenticates; authentik decides who may have an account (owner-only enrollment) and who may open which
# application (policies). login_hint is a suggestion to Google, not a credential: another Google account can still be
# chosen at Google and is then refused by authentik exactly as before.
#
# The previous brand is untouched until "default" is applied; dm-authentication (DTC's earlier Google-first flow) and
# default-authentication-flow (local recovery) are never modified.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Authentik.psm1') -DisableNameChecking

$script:AssetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\authentik-login'
$script:FlowSlug = 'dm-login'
$script:StageName = 'dm-login-identification'
$script:PolicyName = 'dm-login-google-hint'
$script:PreviewDomain = 'localhost:9000'
$script:TemplateMarker = 'Deployment Manager (DTC) sign-in experience'
$script:EmailPattern = '^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$'

function Get-LkProp($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $Default }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $Default
}

function Get-AuthentikLoginAssetDir { return $script:AssetDir }
function Get-AuthentikLoginFlowSlug { return $script:FlowSlug }

# --- Configuration ------------------------------------------------------------------------------------------------------

# Validates a configuration (the same rules as normalizeConfig in login-experience.js). Returns a list of problems.
function Test-AuthentikLoginConfig {
  param([Parameter(Mandatory = $true)]$Config)
  $errors = @()
  $email = [string](Get-LkProp $Config 'ownerEmail' '')
  if ($email -notmatch $script:EmailPattern) { $errors += "ownerEmail '$email' is not an email address." }
  $slug = [string](Get-LkProp $Config 'sourceSlug' 'google')
  if ($slug -notmatch '^[a-z0-9][a-z0-9_-]{0,49}$') { $errors += "sourceSlug '$slug' is not a valid source slug." }
  $label = [string](Get-LkProp $Config 'buttonLabel' 'Continue as {email}')
  if (-not $label.Trim() -or $label.Length -gt 80) { $errors += 'buttonLabel must be 1 to 80 characters.' }
  $ps = Get-LkProp $Config 'pictureShortcut' $null
  if ($ps) {
    $t = Get-LkProp $ps 'tapTimeoutMs' 6000
    if (-not ($t -is [int] -or $t -is [long] -or $t -is [double]) -or $t -lt 1500 -or $t -gt 30000) { $errors += 'pictureShortcut.tapTimeoutMs must be a number from 1500 to 30000 (milliseconds).' }
    $m = Get-LkProp $ps 'minTargetRadiusPx' 28
    if (-not ($m -is [int] -or $m -is [long] -or $m -is [double]) -or $m -lt 22 -or $m -gt 80) { $errors += 'pictureShortcut.minTargetRadiusPx must be a number from 22 to 80.' }
    $points = @(Get-LkProp $ps 'points' @())
    if ([bool](Get-LkProp $ps 'enabled' $true) -and ($points.Count -lt 2 -or $points.Count -gt 6)) { $errors += "pictureShortcut.points must hold 2 to 6 points (it holds $($points.Count))." }
    $i = 0
    foreach ($p in $points) {
      $i++
      foreach ($k in 'x', 'y') {
        $v = Get-LkProp $p $k $null
        if (-not ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) -or $v -lt 0 -or $v -gt 1) { $errors += "Point ${i}: $k must be a number from 0 to 1 (a fraction of the picture)." }
      }
      $r = Get-LkProp $p 'r' 0.035
      if (-not ($r -is [int] -or $r -is [long] -or $r -is [double] -or $r -is [decimal]) -or $r -le 0 -or $r -gt 0.25) { $errors += "Point ${i}: r must be above 0 and at most 0.25 (a fraction of the picture width)." }
    }
  }
  return , $errors
}

# The effective configuration: the shipped defaults, overlaid with <deployment>\config\login-experience.json (if any)
# and the owner's address from Identity & Access when the file names none.
function Get-AuthentikLoginConfig {
  param([string]$InstallPath = '', [string]$OwnerEmail = '')
  $cfg = [IO.File]::ReadAllText((Join-Path $script:AssetDir 'login-experience.default.json')) | ConvertFrom-Json
  $userPath = $(if ($InstallPath) { Join-Path $InstallPath 'config\login-experience.json' } else { '' })
  if ($userPath -and (Test-Path -LiteralPath $userPath)) {
    try { $u = [IO.File]::ReadAllText($userPath) | ConvertFrom-Json } catch { throw "$userPath is not valid JSON: $($_.Exception.Message)" }
    foreach ($p in $u.PSObject.Properties) {
      if ($p.Name -eq 'pictureShortcut' -and $p.Value) {
        foreach ($q in $p.Value.PSObject.Properties) { $cfg.pictureShortcut | Add-Member -NotePropertyName $q.Name -NotePropertyValue $q.Value -Force }
      } else { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }
  }
  if (-not [string]$cfg.ownerEmail -and $OwnerEmail) { $cfg.ownerEmail = $OwnerEmail }
  return $cfg
}

# Writes <deployment>\config\login-experience.json from the defaults (owner filled in) if it does not exist yet.
function Initialize-AuthentikLoginConfigFile {
  param([Parameter(Mandatory = $true)][string]$InstallPath, [Parameter(Mandatory = $true)][string]$OwnerEmail)
  $path = Join-Path $InstallPath 'config\login-experience.json'
  if (Test-Path -LiteralPath $path) { return $path }
  $text = [IO.File]::ReadAllText((Join-Path $script:AssetDir 'login-experience.default.json'))
  $text = $text.Replace('"ownerEmail": ""', '"ownerEmail": "' + $OwnerEmail + '"')
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
  return $path
}

# The brand attribute "dtc_login" (what the page script receives). Only display settings, no secrets.
function ConvertTo-AuthentikLoginAttribute($Config) {
  $ps = $Config.pictureShortcut
  return [ordered]@{
    flowSlug = $script:FlowSlug; ownerEmail = [string]$Config.ownerEmail; sourceSlug = [string]$Config.sourceSlug; buttonLabel = [string]$Config.buttonLabel
    pictureShortcut = [ordered]@{ enabled = [bool](Get-LkProp $ps 'enabled' $true); tapTimeoutMs = [int]$ps.tapTimeoutMs; minTargetRadiusPx = [int]$ps.minTargetRadiusPx
      points = @(@($ps.points) | ForEach-Object { [ordered]@{ name = [string](Get-LkProp $_ 'name' ''); x = [double]$_.x; y = [double]$_.y; r = [double](Get-LkProp $_ 'r' 0.035) } }) }
  }
}

# The brand CSS: the upstream theme unmodified, then the DTC additions (which win where they overlap).
function Get-AuthentikLoginCss {
  $theme = [IO.File]::ReadAllText((Join-Path $script:AssetDir 'upstream\theme.css'))
  $add = [IO.File]::ReadAllText((Join-Path $script:AssetDir 'dtc-additions.css'))
  return ("/* Glassmorphism theme by VULGA (MIT), https://github.com/VULGA01/Authentik-Login-theme-Glassmorphism */`n" + $theme.TrimEnd() + "`n`n" + $add.TrimEnd() + "`n")
}

# The expression policy that suggests the owner's Google account to Google. authentik's OAuth redirect copies the flow
# plan's pending_user_identifier into login_hint; this policy (bound to the identification stage of dm-login and
# re-evaluated on each visit) sets it unless something else (for example an application's own login_hint) already did.
function New-AuthentikLoginHintExpression([string]$OwnerEmail) {
  if ($OwnerEmail -notmatch $script:EmailPattern) { throw "'$OwnerEmail' is not an email address." }
  return (@(
      '# Created by the Deployment Manager (DTC): suggest the owner''s Google account to Google (login_hint).',
      '# Only a hint: Google still authenticates and authentik still decides who may sign in and what they may open.',
      'plan = request.context.get("flow_plan")',
      'if plan is not None and not plan.context.get("pending_user_identifier"):',
      "    plan.context[`"pending_user_identifier`"] = `"$OwnerEmail`"",
      'return True'
    ) -join "`n")
}

# --- Template files -----------------------------------------------------------------------------------------------------

# Copies the template override and the page script into <authentik project>\custom-templates. A foreign if\flow.html
# (one that is not ours) is never replaced. Returns Changed (authentik caches templates: a change needs a restart of
# the server container) and the files.
function Install-AuthentikLoginTemplates {
  param([Parameter(Mandatory = $true)][string]$AuthentikFolder, [switch]$WhatIf)
  $root = Join-Path $AuthentikFolder 'custom-templates'
  if (-not (Test-Path -LiteralPath $root)) { throw "$root does not exist: the authentik project has no custom-templates folder (mounted at /templates)." }
  $files = @(
    @{ Src = Join-Path $script:AssetDir 'flow.html'; Dst = Join-Path $root 'if\flow.html' },
    @{ Src = Join-Path $script:AssetDir 'login-experience.js'; Dst = Join-Path $root 'dtc\login-experience.js' }
  )
  $changed = $false; $out = @()
  foreach ($f in $files) {
    $new = [IO.File]::ReadAllText($f.Src)
    $old = $(if (Test-Path -LiteralPath $f.Dst) { [IO.File]::ReadAllText($f.Dst) } else { $null })
    if ($null -ne $old -and $f.Dst -like '*\if\flow.html' -and -not $old.Contains($script:TemplateMarker)) { throw "$($f.Dst) exists and was not written by the Deployment Manager; it is left as it is. Move it away to use the DTC sign-in experience." }
    $same = ($null -ne $old -and $old -eq $new)
    if (-not $same) {
      $changed = $true
      if (-not $WhatIf) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f.Dst) | Out-Null; [IO.File]::WriteAllText($f.Dst, $new, (New-Object Text.UTF8Encoding($false))) }
    }
    $out += [pscustomobject]@{ Path = $f.Dst; Status = $(if ($same) { 'unchanged' } elseif ($null -eq $old) { 'new' } else { 'updated' }) }
  }
  return [pscustomobject]@{ Changed = $changed; Files = $out }
}

function Remove-AuthentikLoginTemplates {
  param([Parameter(Mandatory = $true)][string]$AuthentikFolder)
  $root = Join-Path $AuthentikFolder 'custom-templates'
  $removed = @()
  $flow = Join-Path $root 'if\flow.html'
  if ((Test-Path -LiteralPath $flow) -and ([IO.File]::ReadAllText($flow)).Contains($script:TemplateMarker)) { Remove-Item -LiteralPath $flow -Force; $removed += $flow }
  $js = Join-Path $root 'dtc\login-experience.js'
  if (Test-Path -LiteralPath $js) { Remove-Item -LiteralPath $js -Force; $removed += $js }
  foreach ($d in (Join-Path $root 'if'), (Join-Path $root 'dtc')) { if ((Test-Path -LiteralPath $d) -and -not @(Get-ChildItem -LiteralPath $d -Force).Count) { Remove-Item -LiteralPath $d -Force } }
  return $removed
}

# --- authentik objects --------------------------------------------------------------------------------------------------

# Uploads a file through authentik's file API (media) unless a file of that name exists. Names carry a content hash, so
# a changed picture gets a new name and an unchanged one is never uploaded twice.
function Send-AuthentikMediaFile {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
  $existing = @(Invoke-AuthentikApi $Conn GET "/admin/file/?usage=media&search=$([Uri]::EscapeDataString($Name))" | Where-Object { [string]$_.name -eq $Name })
  if ($existing.Count) { return [pscustomobject]@{ Name = $Name; Uploaded = $false } }
  $boundary = '----dtc' + [Guid]::NewGuid().ToString('N')
  $enc = [Text.Encoding]::UTF8
  $ms = New-Object IO.MemoryStream
  $w = { param($s) $b = $enc.GetBytes($s); $ms.Write($b, 0, $b.Length) }
  & $w "--$boundary`r`nContent-Disposition: form-data; name=`"name`"`r`n`r`n$Name`r`n"
  & $w "--$boundary`r`nContent-Disposition: form-data; name=`"usage`"`r`n`r`nmedia`r`n"
  & $w "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$Name`"`r`nContent-Type: image/jpeg`r`n`r`n"
  $bytes = [IO.File]::ReadAllBytes($Path); $ms.Write($bytes, 0, $bytes.Length)
  & $w "`r`n--$boundary--`r`n"
  $body = $ms.ToArray()
  $req = [Net.HttpWebRequest]::Create("$($Conn.BaseUrl)/api/v3/admin/file/")
  $req.Method = 'POST'; $req.Proxy = $null; $req.Timeout = 60000; $req.AllowAutoRedirect = $false
  $req.Headers.Add('Authorization', "Bearer $($Conn.Token)"); $req.Accept = 'application/json'
  $req.ContentType = "multipart/form-data; boundary=$boundary"; $req.ContentLength = $body.Length
  $st = $req.GetRequestStream(); $st.Write($body, 0, $body.Length); $st.Close()
  try { $r = $req.GetResponse(); $status = [int]$r.StatusCode; $r.Close() }
  catch [Net.WebException] {
    $status = 0; $detail = $_.Exception.Message
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode; $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $detail = $sr.ReadToEnd(); $sr.Close() }
    throw "authentik API POST /admin/file/: HTTP $status $detail"
  }
  $null = $Conn.Calls.Add("POST /admin/file/ $status")
  return [pscustomobject]@{ Name = $Name; Uploaded = $true }
}

function Get-AuthentikDefaultBrand($Conn) {
  $brands = @(Get-AuthentikList $Conn '/core/brands/')
  $b = @($brands | Where-Object { [bool]$_.default })[0]
  if (-not $b) { $b = $brands[0] }
  return $b
}

# Creates or updates everything the sign-in experience needs, then points one brand at it:
#   -Target preview : a separate brand for http://localhost:9000 only (the public sign-in page is not changed);
#   -Target default : the default brand (the public sign-in page).
# Returns Actions (what was or would be done), Previous (the brand's earlier values, for Restore) and Brand.
function Sync-AuthentikLoginExperience {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Config, [ValidateSet('preview', 'default')][string]$Target = 'preview',
    [string]$PreviewDomain = $script:PreviewDomain, [switch]$WhatIf)
  $problems = Test-AuthentikLoginConfig $Config
  if ($problems.Count) { throw ('The sign-in configuration has problems: ' + ($problems -join ' ')) }
  $actions = New-Object System.Collections.ArrayList
  $act = { param($kind, $object, $summary) $null = $actions.Add([pscustomobject]@{ Kind = $kind; Object = $object; Summary = $summary; Status = $(if ($kind -eq 'none') { 'OK' } elseif ($WhatIf) { 'Planned' } else { 'Done' }) }) }
  $slug = [string]$Config.sourceSlug
  $src = @(Get-AuthentikList $Conn "/sources/oauth/?slug=$slug")[0]
  if (-not $src) { throw "authentik has no OAuth source '$slug': set up Google sign-in first (Identity & Access)." }
  $def = Get-AuthentikDefaultBrand $Conn

  # 1. Background picture (authentik file API), named by content hash.
  $bgPath = Join-Path $script:AssetDir ([string](Get-LkProp $Config 'background' 'background.jpg'))
  $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($bgPath))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
  $bgName = "dtc-login-$sha.jpg"
  $have = @(Invoke-AuthentikApi $Conn GET "/admin/file/?usage=media&search=$bgName" | Where-Object { [string]$_.name -eq $bgName }).Count
  if ($have) { & $act 'none' 'file' "Background picture $bgName is in authentik" }
  else { & $act 'create' 'file' "Upload the background picture as $bgName (authentik media)"; if (-not $WhatIf) { $null = Send-AuthentikMediaFile $Conn $bgPath $bgName } }

  # 2. Identification stage: Google button plus email / username form, never showing a suggested address as the
  #    matched account (show_matched_user off), password stage as in the default sign-in.
  $flows = @{}; foreach ($f in @(Get-AuthentikList $Conn '/flows/instances/')) { $flows[[string]$f.slug] = $f }
  $baseSlug = $(if ($flows.ContainsKey('dm-authentication')) { 'dm-authentication' } else { 'default-authentication-flow' })
  $baseBindings = @(Get-AuthentikList $Conn "/flows/bindings/?target=$($flows[$baseSlug].pk)&ordering=order")
  $baseIdentBinding = @($baseBindings | Where-Object { [string](Get-LkProp $_.stage_obj 'component' '') -eq 'ak-stage-identification-form' })[0]
  if (-not $baseIdentBinding) { throw "The flow '$baseSlug' has no identification stage to start from." }
  $baseIdent = Invoke-AuthentikApi $Conn GET "/stages/identification/$($baseIdentBinding.stage)/"
  $stage = @(Get-AuthentikList $Conn "/stages/identification/?name=$([Uri]::EscapeDataString($script:StageName))" | Where-Object { [string]$_.name -eq $script:StageName })[0]
  $stageBody = @{ name = $script:StageName; user_fields = @($baseIdent.user_fields); password_stage = (Get-LkProp $baseIdent 'password_stage' $null); captcha_stage = $null
    case_insensitive_matching = $true; show_matched_user = $false; enrollment_flow = $null; recovery_flow = (Get-LkProp $baseIdent 'recovery_flow' $null)
    passwordless_flow = (Get-LkProp $baseIdent 'passwordless_flow' $null); sources = @([string]$src.pk); show_source_labels = $true; pretend_user_exists = $true
    enable_remember_me = [bool](Get-LkProp $baseIdent 'enable_remember_me' $false) }
  if ($stage) {
    $fix = @{}
    if ([bool]$stage.show_matched_user) { $fix.show_matched_user = $false }
    if (@($stage.sources) -notcontains [string]$src.pk) { $fix.sources = @(@($stage.sources) + [string]$src.pk) }
    if ($fix.Count) { & $act 'update' 'stage' "Update '$($script:StageName)' ($($fix.Keys -join ', '))"; if (-not $WhatIf) { $stage = Invoke-AuthentikApi $Conn PATCH "/stages/identification/$($stage.pk)/" $fix } }
    else { & $act 'none' 'stage' "Identification stage '$($script:StageName)' exists" }
  } else {
    & $act 'create' 'stage' "Create identification stage '$($script:StageName)' (Google button, email or username with password)"
    $stage = $(if ($WhatIf) { [pscustomobject]@{ pk = '<new stage>' } } else { Invoke-AuthentikApi $Conn POST '/stages/identification/' $stageBody })
  }

  # 3. Flow dm-login: the stages of dm-authentication (or the default sign-in), with the stage above.
  $title = [string](Get-LkProp $flows[$baseSlug] 'title' 'Sign in')
  $flow = $(if ($flows.ContainsKey($script:FlowSlug)) { $flows[$script:FlowSlug] } else { $null })
  $identBinding = $null
  if ($flow) {
    & $act 'none' 'flow' "Sign-in flow '$($script:FlowSlug)' exists"
    $identBinding = @(Get-AuthentikList $Conn "/flows/bindings/?target=$($flow.pk)&ordering=order" | Where-Object { [string]$_.stage -eq [string]$stage.pk })[0]
    if (-not $identBinding) { throw "The flow '$($script:FlowSlug)' exists but does not use '$($script:StageName)'. It was changed in authentik; rename or delete it to let the manager recreate it." }
  } else {
    & $act 'create' 'flow' "Create sign-in flow '$($script:FlowSlug)' (stages of '$baseSlug', titled '$title')"
    if (-not $WhatIf) {
      $base = Invoke-AuthentikApi $Conn GET "/flows/instances/$baseSlug/"
      $flow = Invoke-AuthentikApi $Conn POST '/flows/instances/' @{ name = 'Sign in (DTC: Google button and picture shortcut)'; slug = $script:FlowSlug; title = $title; designation = 'authentication'
        authentication = [string](Get-LkProp $base 'authentication' 'none'); denied_action = [string](Get-LkProp $base 'denied_action' 'message_continue'); policy_engine_mode = [string](Get-LkProp $base 'policy_engine_mode' 'any'); layout = 'stacked' }
      foreach ($b in $baseBindings) {
        $isIdent = [string]$b.stage -eq [string]$baseIdentBinding.stage
        $nb = Invoke-AuthentikApi $Conn POST '/flows/bindings/' @{ target = $flow.pk; stage = $(if ($isIdent) { $stage.pk } else { $b.stage }); order = [int]$b.order
          evaluate_on_plan = $(if ($isIdent) { $false } else { [bool]$b.evaluate_on_plan }); re_evaluate_policies = $(if ($isIdent) { $true } else { [bool]$b.re_evaluate_policies })
          policy_engine_mode = [string](Get-LkProp $b 'policy_engine_mode' 'any'); invalid_response_action = [string](Get-LkProp $b 'invalid_response_action' 'retry') }
        if ($isIdent) { $identBinding = $nb }
      }
    }
  }
  if ($identBinding -and -not ([bool]$identBinding.re_evaluate_policies -and -not [bool]$identBinding.evaluate_on_plan)) {
    & $act 'update' 'flow stage' "Evaluate the hint on each visit (binding of '$($script:StageName)')"
    if (-not $WhatIf) { $identBinding = Invoke-AuthentikApi $Conn PATCH "/flows/bindings/$($identBinding.pk)/" @{ re_evaluate_policies = $true; evaluate_on_plan = $false } }
  }

  # 4. The login_hint policy, bound to the identification stage of dm-login.
  $expr = New-AuthentikLoginHintExpression ([string]$Config.ownerEmail)
  $pol = @(Get-AuthentikList $Conn "/policies/expression/?name=$([Uri]::EscapeDataString($script:PolicyName))" | Where-Object { [string]$_.name -eq $script:PolicyName })[0]
  if (-not $pol) {
    & $act 'create' 'policy' "Create policy '$($script:PolicyName)': suggest $($Config.ownerEmail) to Google (login_hint)"
    $pol = $(if ($WhatIf) { [pscustomobject]@{ pk = '<new policy>' } } else { Invoke-AuthentikApi $Conn POST '/policies/expression/' @{ name = $script:PolicyName; expression = $expr; execution_logging = $false } })
  } elseif ([string]$pol.expression -ne $expr) {
    & $act 'update' 'policy' "Update policy '$($script:PolicyName)' (suggest $($Config.ownerEmail))"
    if (-not $WhatIf) { $pol = Invoke-AuthentikApi $Conn PATCH "/policies/expression/$($pol.pk)/" @{ expression = $expr } }
  } else { & $act 'none' 'policy' "Policy '$($script:PolicyName)' suggests $($Config.ownerEmail)" }
  if ($identBinding) {
    # Policies attach to a stage binding through its policy-binding model (policybindingmodel_ptr_id), not its pk.
    $pbm = [string](Get-LkProp $identBinding 'policybindingmodel_ptr_id' $identBinding.pk)
    $bound = @(Get-AuthentikList $Conn "/policies/bindings/?target=$pbm" | Where-Object { [string](Get-LkProp $_ 'policy' '') -eq [string]$pol.pk })
    if ($bound.Count) { & $act 'none' 'policy binding' "The hint policy is bound to '$($script:StageName)'" }
    else { & $act 'create' 'policy binding' "Bind the hint policy to '$($script:StageName)' in '$($script:FlowSlug)'"; if (-not $WhatIf) { $null = Invoke-AuthentikApi $Conn POST '/policies/bindings/' @{ target = $pbm; policy = $pol.pk; order = 0; enabled = $true; timeout = 30; failure_result = $true } } }
  } else { & $act 'create' 'policy binding' "Bind the hint policy to '$($script:StageName)' in '$($script:FlowSlug)'" }

  # 5. The brand.
  $css = Get-AuthentikLoginCss
  $attr = ConvertTo-AuthentikLoginAttribute $Config
  $flowPk = $(if ($flow) { [string]$flow.pk } else { '<new flow>' })
  if ($Target -eq 'preview') {
    $brand = @(Get-AuthentikList $Conn '/core/brands/' | Where-Object { [string]$_.domain -eq $PreviewDomain })[0]
    $body = [ordered]@{ domain = $PreviewDomain; default = $false; branding_title = [string]$def.branding_title; branding_logo = [string]$def.branding_logo; branding_favicon = [string]$def.branding_favicon
      branding_custom_css = $css; branding_default_flow_background = $bgName; flow_authentication = $flowPk; attributes = @{ dtc_login = $attr; dtc_preview = $true } }
    foreach ($k in 'flow_invalidation', 'flow_recovery', 'flow_unenrollment', 'flow_user_settings', 'flow_device_code') { $body[$k] = Get-LkProp $def $k $null }
    if ($brand) {
      & $act 'update' 'brand' "Update the preview brand for http://$PreviewDomain"
      if (-not $WhatIf) { $brand = Invoke-AuthentikApi $Conn PATCH "/core/brands/$($brand.brand_uuid)/" $body }
      # A preview brand carries dtc_preview: it is ours entirely, so a restore deletes it whichever backup is used.
      $ours = [bool](Get-LkProp (Get-LkProp $brand 'attributes' $null) 'dtc_preview' $false)
      $prev = [ordered]@{ target = 'preview'; brand = [string]$brand.brand_uuid; created = $ours }
    } else {
      & $act 'create' 'brand' "Create a preview brand for http://$PreviewDomain only (the public sign-in page is unchanged)"
      if (-not $WhatIf) { $brand = Invoke-AuthentikApi $Conn POST '/core/brands/' $body }
      $prev = [ordered]@{ target = 'preview'; brand = $(if ($brand) { [string]$brand.brand_uuid } else { '' }); created = $true }
    }
  } else {
    $brand = $def
    $attrs = @{}; $old = Get-LkProp $def 'attributes' $null
    if ($old) { foreach ($p in $old.PSObject.Properties) { $attrs[$p.Name] = $p.Value } }
    $attrs['dtc_login'] = $attr
    $prev = [ordered]@{ target = 'default'; brand = [string]$def.brand_uuid; created = $false; flow_authentication = [string](Get-LkProp $def 'flow_authentication' '')
      branding_custom_css = [string](Get-LkProp $def 'branding_custom_css' ''); branding_default_flow_background = [string](Get-LkProp $def 'branding_default_flow_background' '')
      attributes = (Get-LkProp $def 'attributes' $null) }
    $patch = @{}
    if ([string]$def.flow_authentication -ne $flowPk) { $patch.flow_authentication = $flowPk }
    if ([string]$def.branding_custom_css -ne $css) { $patch.branding_custom_css = $css }
    if ([string]$def.branding_default_flow_background -ne $bgName) { $patch.branding_default_flow_background = $bgName }
    $oldAttr = $(if ($old -and $old.PSObject.Properties['dtc_login']) { ConvertTo-Json -InputObject $old.dtc_login -Depth 8 -Compress } else { '' })
    if ($oldAttr -ne (ConvertTo-Json -InputObject $attr -Depth 8 -Compress)) { $patch.attributes = $attrs }
    if ($patch.Count) {
      & $act 'update' 'brand' "Default brand '$($def.domain)': $(@($patch.Keys | Sort-Object | ForEach-Object { @{ flow_authentication = "sign-in flow -> $($script:FlowSlug)"; branding_custom_css = 'Glassmorphism CSS'; branding_default_flow_background = 'background picture'; attributes = 'button and picture settings' }[$_] }) -join ', ')"
      if (-not $WhatIf) { $brand = Invoke-AuthentikApi $Conn PATCH "/core/brands/$($def.brand_uuid)/" $patch }
    } else { & $act 'none' 'brand' "Default brand '$($def.domain)' already uses the DTC sign-in experience" }
  }
  return [pscustomobject]@{ Actions = $actions.ToArray(); Previous = $prev; Brand = $brand; Background = $bgName; FlowSlug = $script:FlowSlug }
}

# Undoes Sync-AuthentikLoginExperience for one brand: a created preview brand is deleted; the default brand gets its
# earlier sign-in flow, CSS, background and attributes back. The flow, stage, policy and picture stay in authentik
# (unused) so a later apply is quick; Remove-AuthentikLoginObjects deletes them.
function Restore-AuthentikLoginExperience {
  param([Parameter(Mandatory = $true)]$Conn, [Parameter(Mandatory = $true)]$Previous)
  $p = $Previous
  if ([string](Get-LkProp $p 'target' '') -eq 'preview') {
    if ([bool](Get-LkProp $p 'created' $false) -and [string]$p.brand) { try { $null = Invoke-AuthentikApi $Conn DELETE "/core/brands/$($p.brand)/" } catch { if ($_.Exception.Data['Status'] -ne 404) { throw } } }
    return 'The preview brand was removed.'
  }
  $attrs = @{}
  $a = Get-LkProp $p 'attributes' $null
  if ($a) { foreach ($q in $a.PSObject.Properties) { $attrs[$q.Name] = $q.Value } }
  $patch = @{ flow_authentication = $(if ([string]$p.flow_authentication) { [string]$p.flow_authentication } else { $null }); branding_custom_css = [string]$p.branding_custom_css
    branding_default_flow_background = [string]$p.branding_default_flow_background; attributes = $attrs }
  $null = Invoke-AuthentikApi $Conn PATCH "/core/brands/$($p.brand)/" $patch
  return 'The default brand has its previous sign-in flow, CSS, background and attributes again.'
}

# Deletes the objects this feature created (only when no brand uses dm-login any more).
function Remove-AuthentikLoginObjects {
  param([Parameter(Mandatory = $true)]$Conn)
  $flow = $null; try { $flow = Invoke-AuthentikApi $Conn GET "/flows/instances/$($script:FlowSlug)/" } catch { }
  if ($flow -and @(Get-AuthentikList $Conn '/core/brands/' | Where-Object { [string]$_.flow_authentication -eq [string]$flow.pk }).Count) { throw "A brand still uses '$($script:FlowSlug)'. Restore the brand first." }
  $done = @()
  if ($flow) { $null = Invoke-AuthentikApi $Conn DELETE "/flows/instances/$($script:FlowSlug)/"; $done += "flow $($script:FlowSlug)" }
  foreach ($x in @(Get-AuthentikList $Conn "/policies/expression/?name=$($script:PolicyName)" | Where-Object { [string]$_.name -eq $script:PolicyName })) { $null = Invoke-AuthentikApi $Conn DELETE "/policies/expression/$($x.pk)/"; $done += "policy $($script:PolicyName)" }
  foreach ($x in @(Get-AuthentikList $Conn "/stages/identification/?name=$($script:StageName)" | Where-Object { [string]$_.name -eq $script:StageName })) { $null = Invoke-AuthentikApi $Conn DELETE "/stages/identification/$($x.pk)/"; $done += "stage $($script:StageName)" }
  return $done
}

# --- Verification (no browser, nothing sent to Google) -----------------------------------------------------------------

# Walks the sign-in as a browser would, against authentik directly (BaseUrl, with the Host header of the page): opens
# the flow with a deep link (next), lets authentik plan it (flow executor API), then asks authentik's Google source for
# its redirect and reads the Google authorization address without following it. Reports login_hint, scopes, state,
# prompt, redirect_uri and whether the page carries the DTC script. (The deep link itself is authentik's session state
# and is checked end to end in tests\Test-AuthentikLoginBrowser.ps1 -ProtectedUrl.)
function Test-AuthentikLoginHint {
  param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$HostHeader, [string]$Scheme = 'https', [string]$FlowSlug = $script:FlowSlug,
    [string]$Slug = 'google', [string]$Next = '/application/o/authorize/?client_id=dtc-test&state=keep%20me&redirect_uri=https%3A%2F%2Fapp.example%2Fpath%3Fq%3D1')
  $b = $BaseUrl.TrimEnd('/')
  # Cookies are carried by hand: for an https page authentik marks its session cookie Secure, which a cookie container
  # would not send back over the direct http connection to authentik.
  $jar = @{}
  $call = {
    param([string]$path, [string]$accept)
    $req = [Net.HttpWebRequest]::Create("$b$path")
    $req.Method = 'GET'; $req.AllowAutoRedirect = $false; $req.Proxy = $null; $req.Timeout = 20000; $req.Host = $HostHeader
    $req.Headers.Add('X-Forwarded-Proto', $Scheme); $req.Accept = $accept; $req.UserAgent = 'Mozilla/5.0 (DTC sign-in check)'
    if ($jar.Count) { $req.Headers.Add('Cookie', (@($jar.Keys | ForEach-Object { "$_=$($jar[$_])" }) -join '; ')) }
    try { $r = $req.GetResponse() } catch [Net.WebException] { if ($_.Exception.Response) { $r = $_.Exception.Response } else { throw } }
    foreach ($sc in @($r.Headers.GetValues('Set-Cookie'))) { if ($sc -and $sc -match '^\s*([^=;\s]+)=([^;]*)') { $jar[$Matches[1]] = $Matches[2] } }
    $sr = New-Object IO.StreamReader($r.GetResponseStream()); $body = $sr.ReadToEnd(); $sr.Close()
    $o = [pscustomobject]@{ Status = [int]$r.StatusCode; Location = [string]$r.Headers['Location']; Body = $body }; $r.Close(); return $o
  }
  $query = 'next=' + [Uri]::EscapeDataString($Next)
  $out = [ordered]@{ ok = $false; page = 0; scriptOnPage = $false; config = $null; prefill = ''; googleStatus = 0; loginHint = ''; scopes = @(); prompt = $null; state = $false; redirectUri = ''; message = '' }
  $page = & $call "/if/flow/$FlowSlug/?$query" 'text/html'
  $out.page = $page.Status
  $out.scriptOnPage = $page.Body.Contains('data-id="dtc-login"')
  $m = [regex]::Match($page.Body, '<script id="dtc-login-config" type="application/json">(.*?)</script>', 'Singleline')
  if ($m.Success) { try { $out.config = $m.Groups[1].Value | ConvertFrom-Json } catch { } }
  $exec = & $call "/api/v3/flows/executor/$FlowSlug/?query=$([Uri]::EscapeDataString($query))" 'application/json'
  try { $ch = $exec.Body | ConvertFrom-Json; $out.prefill = [string](Get-LkProp $ch 'pending_user_identifier' '') } catch { }
  $g = & $call "/source/oauth/login/$Slug/" 'text/html'
  $out.googleStatus = $g.Status
  if ($g.Status -in 301, 302 -and $g.Location -match '^https://accounts\.google\.com/') {
    $q = @{}
    foreach ($pair in ([Uri]$g.Location).Query.TrimStart('?').Split('&')) { $kv = $pair.Split('=', 2); if ($kv.Count -eq 2) { $q[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } }
    $out.loginHint = [string]$q['login_hint']; $out.scopes = @(([string]$q['scope']).Split(' ') | Where-Object { $_ }); $out.prompt = $q['prompt']
    $out.state = ([string]$q['state']).Length -ge 16; $out.redirectUri = [string]$q['redirect_uri']
  }
  $out.ok = ($out.page -eq 200 -and $out.googleStatus -in 301, 302 -and $out.loginHint -and $out.state -and $null -eq $out.prompt)
  $out.message = $(if ($out.ok) { "authentik sends Google login_hint=$($out.loginHint) with scopes '$($out.scopes -join ' ')' and redirect_uri $($out.redirectUri)." } elseif ($out.googleStatus -notin 301, 302) { "authentik's Google source answered HTTP $($out.googleStatus) instead of redirecting." } else { 'The Google request lacks login_hint, state or has a prompt.' })
  return [pscustomobject]$out
}

Export-ModuleMember -Function Get-AuthentikLoginAssetDir, Get-AuthentikLoginFlowSlug, Test-AuthentikLoginConfig, Get-AuthentikLoginConfig, Initialize-AuthentikLoginConfigFile,
  ConvertTo-AuthentikLoginAttribute, Get-AuthentikLoginCss, New-AuthentikLoginHintExpression, Install-AuthentikLoginTemplates, Remove-AuthentikLoginTemplates,
  Send-AuthentikMediaFile, Get-AuthentikDefaultBrand, Sync-AuthentikLoginExperience, Restore-AuthentikLoginExperience, Remove-AuthentikLoginObjects, Test-AuthentikLoginHint
