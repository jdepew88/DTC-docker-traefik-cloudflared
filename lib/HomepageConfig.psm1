#requires -version 5.1
Set-StrictMode -Version 2.0

# Homepage (gethomepage.dev) configuration generated from what this machine actually runs. Pure functions: the caller
# collects the facts (installed apps, container states, catalog, published hostnames and their verification) and
# writes the files. Generated text lives between marker comments; everything outside the markers is the user's and is
# kept byte for byte. A card is never generated twice: names the user already has outside the block are skipped.

$script:Begin = '# BEGIN Deployment Manager (generated: this block is replaced on every update; edit outside it)'
$script:End = '# END Deployment Manager'
$script:LegacyHeader = '# Apps installed by the Deployment Manager when Homepage was installed.'

# Homepage group for each catalog category, in display order.
$script:GroupOrder = @('Infrastructure', 'Monitoring', 'Identity', 'Media', 'Communication', 'Other services')
$script:CategoryGroup = @{ management = 'Infrastructure'; proxy = 'Infrastructure'; monitoring = 'Monitoring'; dashboard = 'Monitoring'; updates = 'Monitoring'
  authentication = 'Identity'; media = 'Media'; photos = 'Media'; communication = 'Communication' }
# Icons from the dashboard-icons set Homepage resolves by file name (checked to exist), or Material Design Icons.
$script:Icons = @{ 'traefik-manager' = 'mdi-routes'; 'uptime-kuma' = 'uptime-kuma.png'; portainer = 'portainer.png'; homepage = 'homepage.png'; arcane = 'arcane.png'
  echo = 'mdi-swap-horizontal'; authentik = 'authentik.png'; authelia = 'authelia.png'; lldap = 'lldap.png'; jellyfin = 'jellyfin.png'; dispatcharr = 'dispatcharr.png'
  'dispatcharr-modular' = 'dispatcharr.png'; 'channels-dvr' = 'channels-dvr.png'; immich = 'immich.png'; 'rocket-chat' = 'rocket-chat.png'; rocketchat = 'rocket-chat.png'; 'whats-up-docker' = 'whats-up-docker.png' }

function Get-Prop3($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object) { return $Default }
  if ($Object -is [hashtable]) { if ($Object.ContainsKey($Name)) { return $Object[$Name] } else { return $Default } }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value } else { return $Default }
}

function ConvertTo-HpString([string]$Value) { return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"' }

# Pure: the cards. $Apps = registry entries (project, appId, name, localUrl, prepared); $States = project ->
# @{ running; total } of its long-running services (completed setup jobs are not counted); $Manifests = appId (and
# alias) -> manifest; $Published = services.json entries, each with .verified
# (hostname -> $true when the Cloudflare edge answered and Traefik routed it to a working backend); $Infra =
# @{ traefikContainer; dashboardUrl; managerUrl; tunnelName }; $NotInstalled = catalog ids to show as not installed.
function New-HomepageCards {
  param([object[]]$Apps = @(), [hashtable]$States = @{}, [hashtable]$Manifests = @{}, [object[]]$Published = @(), [hashtable]$Infra = @{}, [string[]]$NotInstalled = @())
  $cards = New-Object System.Collections.ArrayList
  $add = { param($c) $null = $cards.Add($c) }
  $tc = [string](Get-Prop3 $Infra 'traefikContainer' '')
  if ($tc) {
    & $add ([ordered]@{ group = 'Infrastructure'; name = 'Traefik Dashboard'; href = [string](Get-Prop3 $Infra 'dashboardUrl' ''); icon = 'traefik.png'
      description = 'Routers and services (local only)'; siteMonitor = "http://${tc}:8080/ping"; widget = [ordered]@{ type = 'traefik'; url = "http://${tc}:8080" } })
  }
  if (Get-Prop3 $Infra 'managerUrl' '') {
    & $add ([ordered]@{ group = 'Infrastructure'; name = 'Deployment Manager'; href = [string]$Infra.managerUrl; icon = 'docker.png'
      description = 'Opens while the manager runs (START-HERE); status not monitored' })
  }
  if (Get-Prop3 $Infra 'tunnelName' '') {
    & $add ([ordered]@{ group = 'Infrastructure'; name = 'Cloudflare Tunnel'; href = 'https://one.dash.cloudflare.com/'; icon = 'cloudflare-zero-trust.png'
      description = "$($Infra.tunnelName): status in Cloudflare Zero Trust (not checkable from Homepage without an API token)" })
  }
  $installedIds = @()
  foreach ($a in $Apps) {
    $id = [string](Get-Prop3 $a 'appId' '')
    if ($id -eq 'homepage') { $installedIds += $id; continue }
    $m = $Manifests[$id]
    # Records written before an app's id changed (e.g. 'rocket-chat', now an alias of 'rocketchat').
    if (-not $m) { $m = @($Manifests.Values | Where-Object { @(Get-Prop3 $_ 'aliases' @()) -contains $id })[0] }
    if (-not $m) { continue }
    $installedIds += $id; $installedIds += [string]$m.id
    $project = [string]$a.project
    $st = $States[$project]
    $running = [int](Get-Prop3 $st 'running' 0); $total = [int](Get-Prop3 $st 'total' 0)
    $prepared = [bool](Get-Prop3 $a 'prepared' $false)
    $group = $script:CategoryGroup[[string]$m.category]; if (-not $group) { $group = 'Other services' }
    $card = [ordered]@{ group = $group; name = [string]$a.name; icon = $(if ($script:Icons.ContainsKey($id)) { $script:Icons[$id] } else { 'mdi-application' }) }
    if ($prepared -and $total -eq 0) { $card.description = 'Prepared, not started (start it in the Deployment Manager)' }
    elseif ($total -gt 0 -and $running -eq 0) { $card.description = 'Stopped' }
    else {
      $card.href = [string](Get-Prop3 $a 'localUrl' '')
      $card.description = $(if ($running -lt $total) { "Partly running ($running of $total)" } else { [string]$m.category })
      # The status check goes to the container over the shared network (the declared status port, else the web port).
      $web = [string]$m.web.service
      $svc = $m.services.$web
      $primary = @(@($svc.ports) | Where-Object { Get-Prop3 $_ 'primary' $false })[0]
      $port = [int]$primary.container; $scheme = $(if ([string](Get-Prop3 $primary 'protocol' 'http') -eq 'https') { 'https' } else { 'http' })
      $status = Get-Prop3 $m.web 'status' $null
      if ($status) { $port = [int]$status.port; $scheme = [string]$status.scheme }
      $single = @($m.services.PSObject.Properties).Count -eq 1
      $cname = $(if ($single) { $project } else { "$project-$web" })
      $onProxy = [bool](Get-Prop3 $m.web 'proxy' $true)
      if ($onProxy) { $card.siteMonitor = "${scheme}://${cname}:$port" }
      else { $card.description += ' (local only; no status check)' }
    }
    & $add $card
  }
  foreach ($id in $NotInstalled) {
    if ($installedIds -contains $id) { continue }
    $m = $Manifests[$id]
    if (-not $m) { continue }
    $group = $script:CategoryGroup[[string]$m.category]; if (-not $group) { $group = 'Other services' }
    & $add ([ordered]@{ group = $group; name = [string]$m.name; icon = $(if ($script:Icons.ContainsKey($id)) { $script:Icons[$id] } else { 'mdi-application' })
      description = 'Not installed (needs configuration in the App Catalog)' })
  }
  # Services published through Traefik that no installed app covers (LAN devices, containers of other projects).
  $appNames = @($Apps | ForEach-Object { [string](Get-Prop3 $_ 'project' '') })
  foreach ($p in $Published) {
    $t = Get-Prop3 $p 'target' $null
    if (-not $t -or -not (Get-Prop3 $p 'enabled' $true)) { continue }
    $type = [string](Get-Prop3 $t 'type' ''); $h = [string]$t.host; $port = [int]$t.port; $proto = [string](Get-Prop3 $t 'protocol' 'http')
    if ($type -eq 'docker' -and $appNames -contains $h) { continue }
    $name = [string](Get-Prop3 $p 'displayName' (Get-Prop3 $p 'name' ''))
    if ($name -cmatch '^[a-z]') { $name = $name.Substring(0, 1).ToUpper() + $name.Substring(1) }
    $card = [ordered]@{ group = $(if ([string]$p.name -match 'notflix|jellyfin|plex|emby') { 'Media' } else { 'Other services' }); name = $name; icon = $(if ([string]$p.name -match 'prowlarr') { 'prowlarr.png' } else { 'mdi-web' }) }
    switch ($type) {
      'lan' { $card.href = "${proto}://${h}:$port/"; $card.siteMonitor = "${proto}://${h}:$port"; $card.description = "LAN device $h" }
      'host' { $card.href = "${proto}://127.0.0.1:$port/"; $card.siteMonitor = "${proto}://${h}:$port"; $card.description = 'Not installed by the App Catalog' }
      default { $card.siteMonitor = "${proto}://${h}:$port"; $card.description = 'Container of another project' }
    }
    $card.publicHosts = @(@(Get-Prop3 $p 'hostnames' @()) | Where-Object { $v = Get-Prop3 $p 'verified' @{}; $v[$_] })
    & $add $card
  }
  return , $cards
}

# Pure: names of groups and cards already present in a services.yaml text (outside any generated block).
function Get-HomepageNames([string]$Text) {
  $names = @()
  foreach ($l in ($Text -split "`r?`n")) {
    if ($l -match '^\s{2,}-\s+"?([^":#]+?)"?\s*:\s*$') { $names += $Matches[1].Trim() }
  }
  return $names
}

# Pure: splits a file into the user's text and the generated block. A services.yaml written by the first Homepage
# installation (legacy header, one 'Apps' group of manager cards only) counts as generated as a whole.
function Split-HomepageFile([string]$Text, [string[]]$ManagedNames = @()) {
  $Text = $Text -replace "`r`n", "`n"
  $user = $Text; $hadBlock = $false
  $b = $Text.IndexOf($script:Begin); $e = $Text.IndexOf($script:End)
  if ($b -ge 0 -and $e -gt $b) {
    $after = $Text.Substring($e + $script:End.Length).TrimStart("`n")
    $user = $Text.Substring(0, $b) + $after; $hadBlock = $true
  }
  if ($user.StartsWith($script:LegacyHeader)) {
    $body = @($user -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() })
    $groups = @($body | Where-Object { $_ -match '^-\s' })
    $cards = @(Get-HomepageNames ($body -join "`n"))
    if ($groups.Count -eq 1 -and $groups[0] -match '^- "?Apps"?:' -and -not @($cards | Where-Object { $ManagedNames -notcontains $_ }).Count) {
      return @{ user = ''; hadBlock = $hadBlock; adopted = $true }
    }
  }
  return @{ user = $user; hadBlock = $hadBlock; adopted = $false }
}

function Join-HomepageFile([string]$User, [string]$Block) {
  $u = $User.TrimEnd("`n")
  $parts = @()
  if ($u) { $parts += $u; $parts += '' }
  $parts += $script:Begin
  if ($Block) { $parts += $Block.TrimEnd("`n") }
  $parts += $script:End
  return ($parts -join "`n") + "`n"
}

# Pure: new services.yaml text. Cards whose names the user already has outside the block are left out.
function Merge-HomepageServices([string]$Existing, $Cards) {
  $managed = @($Cards | ForEach-Object { $_.name })
  $split = Split-HomepageFile $Existing $managed
  $userNames = @(Get-HomepageNames $split.user)
  $L = @()
  $skipped = @()
  foreach ($g in $script:GroupOrder) {
    $gc = @($Cards | Where-Object { $_.group -eq $g })
    $keep = @($gc | Where-Object { $userNames -notcontains $_.name })
    $skipped += @($gc | Where-Object { $userNames -contains $_.name } | ForEach-Object { $_.name })
    if (-not $keep.Count) { continue }
    $L += "- ${g}:"
    foreach ($c in $keep) {
      $L += "    - $(ConvertTo-HpString $c.name):"
      foreach ($k in @('icon', 'href', 'description', 'siteMonitor')) { if ($c.Contains($k) -and $c[$k]) { $L += "        ${k}: $(ConvertTo-HpString ([string]$c[$k]))" } }
      if ($c.Contains('widget') -and $c.widget) {
        $L += '        widget:'
        foreach ($wk in $c.widget.Keys) { $L += "          ${wk}: $(ConvertTo-HpString ([string]$c.widget[$wk]))" }
      }
    }
  }
  # Homepage reads the file as one YAML list: an empty user part must not leave a stray '[]' behind.
  $user = $split.user
  if (($user -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() }) -join '' -match '^\s*\[\]\s*$') { $user = '' }
  return @{ text = (Join-HomepageFile $user ($L -join "`n")); skipped = $skipped; adopted = $split.adopted }
}

# Pure: bookmarks.yaml with the verified public addresses (Cloudflare Access) of the cards.
function Merge-HomepageBookmarks([string]$Existing, $Cards, [hashtable]$PublicByName = @{}) {
  $split = Split-HomepageFile $Existing
  $user = $split.user
  if ((($user -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() }) -join '').Trim() -eq '[]') { $user = '' }
  $userNames = @(Get-HomepageNames $user)
  $L = @()
  $items = @()
  foreach ($name in @($PublicByName.Keys | Sort-Object)) {
    foreach ($h in @($PublicByName[$name])) {
      $label = "$name ($h)"
      if ($userNames -contains $label) { continue }
      $items += "    - $(ConvertTo-HpString $label):"
      $items += "        - href: $(ConvertTo-HpString "https://$h/")"
      $items += "          abbr: $(ConvertTo-HpString ($name.Substring(0, [Math]::Min(2, $name.Length)).ToUpper()))"
    }
  }
  if ($items.Count) { $L += '- "Public (Cloudflare Access)":'; $L += $items }
  return @{ text = (Join-HomepageFile $user ($L -join "`n")) }
}

# Pure: widgets.yaml with a resources widget (the Docker VM's CPU, memory and disk) unless the user has one.
function Merge-HomepageWidgets([string]$Existing) {
  $split = Split-HomepageFile $Existing
  $L = @()
  if ($split.user -notmatch '(?m)^-\s+resources:') {
    $L += '- resources:', '    label: Docker VM', '    cpu: true', '    memory: true', '    disk: /', '    expanded: false'
  }
  return @{ text = (Join-HomepageFile $split.user ($L -join "`n")) }
}

# Pure: settings.yaml with a compact layout for the generated groups; keys the user set themselves win.
function Merge-HomepageSettings([string]$Existing, $Cards) {
  $split = Split-HomepageFile $Existing
  $keys = @([regex]::Matches($split.user, '(?m)^([A-Za-z]\w*):') | ForEach-Object { $_.Groups[1].Value })
  $L = @()
  if ($keys -notcontains 'statusStyle') { $L += 'statusStyle: dot' }
  if ($keys -notcontains 'useEqualHeights') { $L += 'useEqualHeights: true' }
  if ($keys -notcontains 'layout') {
    $groups = @($script:GroupOrder | Where-Object { $g = $_; @($Cards | Where-Object { $_.group -eq $g }).Count })
    if ($groups.Count) {
      $L += 'layout:'
      foreach ($g in $groups) { $L += "  ${g}:"; $L += '    style: row'; $L += "    columns: $([Math]::Min(4, [Math]::Max(2, @($Cards | Where-Object { $_.group -eq $g }).Count)))" }
    }
  }
  return @{ text = (Join-HomepageFile $split.user ($L -join "`n")) }
}

Export-ModuleMember -Function New-HomepageCards, Get-HomepageNames, Split-HomepageFile, Merge-HomepageServices, Merge-HomepageBookmarks, Merge-HomepageWidgets, Merge-HomepageSettings
