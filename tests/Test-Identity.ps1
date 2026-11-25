#requires -version 5.1
<#
.SYNOPSIS
  Identity & Access unit tests (no authentik, no Cloudflare, no Google): ForwardAuth route generation and validation,
  Google OAuth values, allow-lists and policy expressions, authentik discovery, the setup model and its states, the
  identity configuration (resume) and the secret store. With Docker running, the generated ForwardAuth routes are also
  loaded into a throwaway Traefik (--network none) to prove Traefik accepts them.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\tests\Test-Identity.ps1
#>
[CmdletBinding()]
param([switch]$SkipDocker)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repo 'lib\TraefikProxy.psm1') -Force
Import-Module (Join-Path $repo 'lib\Authentik.psm1') -Force
Import-Module (Join-Path $repo 'lib\IdentityProvider.psm1') -Force
Import-Module (Join-Path $repo 'lib\SecretStore.psm1') -Force
Import-Module (Join-Path $repo 'lib\CloudflareApi.psm1') -Force
Import-Module (Join-Path $repo 'tests\WebUiTestHelpers.psm1') -Force
$script:Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
  $null = $script:Results.Add([pscustomobject]@{ Status = $Status; Test = $Name; Detail = $Detail })
  $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'DarkYellow' }[$Status]
  Write-Host ('[{0}] {1}  {2}' -f $Status, $Name, $Detail) -ForegroundColor $color
}
function Test-Condition([string]$Name, [bool]$Condition, [string]$Detail = '') { if ($Condition) { Add-Result 'PASS' $Name '' } else { Add-Result 'FAIL' $Name $Detail } }
function Get-Issues($Service, $Others = @()) { return @(Test-ServiceDefinition -Service $Service -OtherServices $Others -AvailableMiddlewares @('default-headers')) }

$work = Join-Path ([IO.Path]::GetTempPath()) ('tpx-idunit-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path (Join-Path $work 'config'), (Join-Path $work 'traefik\dynamic') | Out-Null
try {
  # --- ForwardAuth routes ---------------------------------------------------------------------------------------------------
  $endpoint = 'http://authentik-server:9000'
  $svc = ConvertTo-ServiceDefinition @{ name = 'wiki'; hostnames = @('wiki.example.com'); target = @{ type = 'docker'; host = 'wiki'; port = 3000 }; auth = @{ provider = 'authentik'; endpoint = "$endpoint/" } }
  $yaml = ConvertTo-TraefikRouteYaml $svc
  Test-Condition 'route: ForwardAuth middleware to the embedded outpost, first in the chain' ($yaml -match "address: $endpoint/outpost.goauthentik.io/auth/traefik" -and $yaml -match 'middlewares: \[svc-wiki-authentik, default-headers@file\]' -and $yaml -match 'trustForwardHeader: true') $yaml
  $missingHeaders = @(@('X-authentik-username', 'X-authentik-groups', 'X-authentik-email', 'X-authentik-uid', 'X-authentik-jwt', 'X-authentik-meta-app') | Where-Object { $yaml -notmatch [regex]::Escape("- $_") })
  Test-Condition 'route: all documented authentik response headers are passed to the application' ($missingHeaders.Count -eq 0) ($missingHeaders -join ', ')
  Test-Condition 'route: outpost path router on the same host, without ForwardAuth, to the authentik server by name' ($yaml -match "rule: 'Host\(``wiki.example.com``\) && PathPrefix\(``/outpost.goauthentik.io/``\)'" -and $yaml -match 'service: svc-wiki-outpost' -and $yaml -match "- url: $endpoint`n") $yaml
  $outpostBlock = ([regex]::Match($yaml, '(?s)    svc-wiki-outpost:\n(.*?)\n  middlewares:')).Groups[1].Value
  Test-Condition 'route: the outpost router does not carry the ForwardAuth middleware (no recursion)' ($outpostBlock -match 'service: svc-wiki-outpost' -and $outpostBlock -notmatch 'svc-wiki-authentik') $outpostBlock
  $multi = ConvertTo-TraefikRouteYaml (ConvertTo-ServiceDefinition @{ name = 'm'; hostnames = @('a.example.com', 'b.example.com'); target = @{ type = 'docker'; host = 'm'; port = 80 }; auth = @{ provider = 'authentik'; endpoint = $endpoint } })
  Test-Condition 'route: several hostnames are grouped in the outpost rule' ($multi -match "rule: '\(Host\(``a.example.com``\) \|\| Host\(``b.example.com``\)\) && PathPrefix") $multi
  $strip = ConvertTo-TraefikRouteYaml (ConvertTo-ServiceDefinition @{ name = 's'; hostnames = @('s.example.com'); pathPrefix = '/x'; stripPrefix = $true; target = @{ type = 'docker'; host = 's'; port = 80 }; auth = @{ provider = 'authentik'; endpoint = $endpoint } })
  Test-Condition 'route: prefix stripping and ForwardAuth share one middlewares block' (([regex]::Matches($strip, '(?m)^  middlewares:')).Count -eq 1 -and $strip -match 'svc-s-strip:' -and $strip -match 'svc-s-authentik:') $strip
  $plain = ConvertTo-ServiceDefinition @{ name = 'p'; hostnames = @('p.example.com'); target = @{ type = 'docker'; host = 'p'; port = 80 } }
  $none = ConvertTo-ServiceDefinition @{ name = 'p'; hostnames = @('p.example.com'); target = @{ type = 'docker'; host = 'p'; port = 80 }; auth = @{ provider = 'none' } }
  Test-Condition 'registry: services without sign-in are stored exactly as before (no auth field)' (-not $plain.PSObject.Properties['auth'] -and -not $none.PSObject.Properties['auth'] -and (ConvertTo-RegistryJson @($plain)) -notmatch 'auth') ''
  Test-Condition 'registry: the auth field survives a JSON round trip' ((ConvertTo-ServiceDefinition ((ConvertTo-RegistryJson @($svc)) | ConvertFrom-Json).services[0]).auth.endpoint -eq $endpoint) ''

  $self = ConvertTo-ServiceDefinition @{ name = 'auth'; hostnames = @('auth.example.com'); target = @{ type = 'docker'; host = 'authentik-server'; port = 9000 }; auth = @{ provider = 'authentik'; endpoint = $endpoint }; cloudflare = @{ publish = $false } }
  Test-Condition 'validation: authentik cannot protect itself (redirect loop)' (@(Get-Issues $self | Where-Object { $_.Level -eq 'Error' -and $_.Field -eq 'auth' }).Count -eq 1) ''
  $ip = ConvertTo-ServiceDefinition @{ name = 'x'; hostnames = @('x.example.com'); target = @{ type = 'docker'; host = 'x'; port = 80 }; auth = @{ provider = 'authentik'; endpoint = 'http://172.18.0.5:9000/x' }; cloudflare = @{ publish = $false } }
  Test-Condition 'validation: the sign-in endpoint must be http://<name>:<port> (no paths, no injection)' (@(Get-Issues $ip | Where-Object { $_.Field -eq 'auth.endpoint' }).Count -eq 1) ''
  $two = ConvertTo-ServiceDefinition @{ name = 'y'; hostnames = @('y.example.com'); target = @{ type = 'docker'; host = 'y'; port = 80 }; middlewares = @('default-headers@file', 'authelia@file'); auth = @{ provider = 'authentik'; endpoint = $endpoint }; cloudflare = @{ publish = $false } }
  Test-Condition 'validation: a second sign-in middleware on the same route is refused' (@(Get-Issues $two | Where-Object { $_.Level -eq 'Error' -and $_.Message -match 'Only one sign-in provider' }).Count -eq 1) ''
  $unk = ConvertTo-ServiceDefinition @{ name = 'z'; hostnames = @('z.example.com'); target = @{ type = 'docker'; host = 'z'; port = 80 }; auth = @{ provider = 'authelia'; endpoint = 'http://authelia:9091' }; cloudflare = @{ publish = $false } }
  Test-Condition 'validation: Authelia is not offered as a ForwardAuth provider (not implemented)' (@(Get-Issues $unk | Where-Object { $_.Field -eq 'auth.provider' }).Count -eq 1) ''
  $both = ConvertTo-ServiceDefinition @{ name = 'w'; hostnames = @('w.example.com'); target = @{ type = 'docker'; host = 'w'; port = 80 }; auth = @{ provider = 'authentik'; endpoint = $endpoint }; cloudflare = @{ publish = $true; access = $true } }
  Test-Condition 'validation: Cloudflare Access + authentik without layered is refused (no silent double login)' (@(Get-Issues $both | Where-Object { $_.Level -eq 'Error' -and $_.Field -eq 'auth' -and $_.Message -match 'layered' }).Count -eq 1) ''
  $layered = ConvertTo-ServiceDefinition @{ name = 'w'; hostnames = @('w.example.com'); target = @{ type = 'docker'; host = 'w'; port = 80 }; auth = @{ provider = 'authentik'; endpoint = $endpoint; layered = $true }; cloudflare = @{ publish = $true; access = $true } }
  Test-Condition 'validation: Cloudflare Access + authentik chosen as layered is allowed with a double-login warning' (@(Get-Issues $layered | Where-Object { $_.Level -eq 'Warning' -and $_.Message -match 'sign in twice' }).Count -eq 1 -and -not @(Get-Issues $layered | Where-Object { $_.Level -eq 'Error' }).Count) ''
  $dflt = ConvertTo-ServiceDefinition @{ name = 'd'; hostnames = @('d.example.com'); target = @{ type = 'docker'; host = 'd'; port = 80 }; auth = @{ provider = 'authentik'; endpoint = $endpoint } }
  Test-Condition 'defaults: an authentik service gets Cloudflare Access off unless asked; others keep the old default (on)' (-not $dflt.cloudflare.access -and $plain.cloudflare.access) ''
  $settings = ConvertTo-StackSettings -InstallPath $work -Values @{ STACK_NAME = 'tpx-idunit' }
  Copy-Item (Join-Path $repo 'traefik\dynamic\security.yml') (Join-Path $work 'traefik\dynamic')
  $clash = @(Test-ServiceRegistry -Settings $settings -Services @($svc, (ConvertTo-ServiceDefinition @{ name = 'wiki-outpost'; hostnames = @('wo.example.com'); target = @{ type = 'docker'; host = 'wo'; port = 80 } })))
  Test-Condition 'validation: a service named <protected>-outpost would collide with the sign-in route' (@($clash | Where-Object { $_.Level -eq 'Error' -and $_.Message -match 'collide' }).Count -eq 1) ''
  $plan = Get-ServicePlan -Settings $settings -Services @($svc, $plain)
  Test-Condition 'plan: protected and unprotected services render side by side without errors' (-not $plan.HasErrors -and $plan.FileChanges -eq 2) (($plan.Issues | ForEach-Object { $_.Message }) -join '; ')

  if ($SkipDocker -or -not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'Traefik accepts the generated ForwardAuth routes' 'Docker not available' }
  else {
    $deep = Test-TraefikDynamicConfig -Settings $settings -Plan $plan
    $names = @($deep.Routers | ForEach-Object { $_.Name })
    Test-Condition 'Traefik v3 accepts the generated ForwardAuth routes, middleware and outpost router' ($deep.Ok -and $names -contains 'svc-wiki@file' -and $names -contains 'svc-wiki-outpost@file') (@($deep.Errors) -join ' | ')
  }

  # --- Google values ----------------------------------------------------------------------------------------------------------
  $gv = Get-GoogleOAuthSettings -PublicUrl 'https://auth.jrtechconsult.com/' -Slug 'google' -Domain 'jrtechconsult.com'
  Test-Condition 'google: redirect URI derived from the public URL and slug' ($gv.RedirectUri -eq 'https://auth.jrtechconsult.com/source/oauth/callback/google/') $gv.RedirectUri
  Test-Condition 'google: Web application client, authorized domain, minimal identity scopes only' ($gv.ClientType -eq 'Web application' -and $gv.AuthorizedDomain -eq 'jrtechconsult.com' -and (@($gv.ScopeNames) -join ',') -eq 'openid,email,profile' -and -not @($gv.Scopes | Where-Object { $_ -match 'gmail|drive|calendar|cloud-platform' }).Count) ''
  $gv2 = Get-GoogleOAuthSettings -PublicUrl 'https://login.example.org' -Slug 'gws'
  Test-Condition 'google: nothing is hard-coded to one domain' ($gv2.RedirectUri -eq 'https://login.example.org/source/oauth/callback/gws/' -and $gv2.AppName -match 'login.example.org' -and $gv2.AuthorizedDomain -eq 'example.org') ($gv2 | ConvertTo-Json -Compress)
  Test-Condition 'google: client ID and secret shapes' ((Test-GoogleClientId '123456789012-abcdefgh12345678.apps.googleusercontent.com') -and -not (Test-GoogleClientId 'abc.apps.googleusercontent.com') -and -not (Test-GoogleClientId '1234567-x.apps.googleusercontent.com.evil.com') -and (Test-GoogleClientSecret 'GOCSPX-abcdefghijklmnop_1234') -and -not (Test-GoogleClientSecret 'bad secret with spaces')) ''

  # --- Allow-lists and policy expressions -------------------------------------------------------------------------------------
  # --- Google client JSON import ---------------------------------------------------------------------------------------------
  $redir = 'https://auth.example.com/source/oauth/callback/google/'
  $web = [ordered]@{ client_id = '123456789012-abcdefgh12345678.apps.googleusercontent.com'; project_id = 'dtc-sign-in'; auth_uri = 'https://accounts.google.com/o/oauth2/auth'; token_uri = 'https://oauth2.googleapis.com/token'
    auth_provider_x509_cert_url = 'https://www.googleapis.com/oauth2/v1/certs'; client_secret = 'GOCSPX-unitTestSecretValue_123'; redirect_uris = @($redir) }
  $j = { param($w) ConvertTo-Json -Depth 5 -Compress -InputObject ([ordered]@{ web = $w }) }
  $ok = ConvertFrom-GoogleClientJson -Json (& $j $web) -ExpectedRedirectUri $redir
  Test-Condition 'json import: a Google "web" client file gives client ID and secret' ($ok.Ok -and $ok.ClientId -eq $web.client_id -and $ok.ClientSecret -eq $web.client_secret -and $ok.ProjectId -eq 'dtc-sign-in') (@($ok.Errors) -join ' | ')
  $bad = ConvertFrom-GoogleClientJson -Json '{"web": {' -ExpectedRedirectUri $redir
  Test-Condition 'json import: invalid JSON is refused with instructions' (-not $bad.Ok -and $bad.Errors[0] -match 'not a valid JSON' -and $bad.Errors[0] -match 'Download JSON') ''
  $inst = ConvertFrom-GoogleClientJson -Json '{"installed": {"client_id": "1-x.apps.googleusercontent.com"}}' -ExpectedRedirectUri $redir
  Test-Condition 'json import: a Desktop (installed) client is refused: a Web application client is needed' (-not $inst.Ok -and $inst.Errors[0] -match 'Web application') ''
  $w2 = [ordered]@{} + $web; $w2.Remove('client_secret')
  $nosec = ConvertFrom-GoogleClientJson -Json (& $j $w2) -ExpectedRedirectUri $redir
  Test-Condition 'json import: a file without the secret explains how to get a new one' (-not $nosec.Ok -and (@($nosec.Errors) -join ' ') -match 'Add secret') ''
  $w3 = [ordered]@{} + $web; $w3.redirect_uris = @('https://auth.example.com/source/oauth/callback/google')
  $wrong = ConvertFrom-GoogleClientJson -Json (& $j $w3) -ExpectedRedirectUri $redir
  Test-Condition 'json import: a wrong redirect URI (missing trailing slash) is refused with the exact fix' (-not $wrong.Ok -and (@($wrong.Errors) -join ' ') -match [regex]::Escape($redir) -and (@($wrong.Errors) -join ' ') -match 'trailing slash' -and (@($wrong.Errors) -join ' ') -match 'Authorized redirect URIs') (@($wrong.Errors) -join ' | ')
  $w4 = [ordered]@{} + $web; $w4.token_uri = 'https://evil.example/token'
  $ep = ConvertFrom-GoogleClientJson -Json (& $j $w4) -ExpectedRedirectUri $redir
  Test-Condition 'json import: non-Google endpoints are refused' (-not $ep.Ok -and (@($ep.Errors) -join ' ') -match 'token endpoint') ''
  Test-Condition 'json import: oversized input is refused; the secret is never part of an error message' (-not (ConvertFrom-GoogleClientJson -Json ('x' * 30000)).Ok -and -not (@($wrong.Errors + $nosec.Errors + $ep.Errors) -join ' ' -match 'unitTestSecretValue')) ''
  $gvA = Get-GoogleOAuthSettings -PublicUrl 'https://auth.jrtechconsult.com' -Domain 'jrtechconsult.com'
  Test-Condition 'google: one ASCII application name is used for the app and the client' ($gvA.AppName -eq 'jrtechconsult.com Sign-in' -and $gvA.ClientName -eq $gvA.AppName -and $gvA.AppName -match '^[A-Za-z0-9 ._-]+$') $gvA.AppName

  # --- Initial owner (no user lists in the manager) ---------------------------------------------------------------------------
  Test-Condition 'owner: the address is normalized; quotes and code are rejected (no injection into the policy)' ((ConvertTo-OwnerEmail ' Owner@Example.COM ') -eq 'owner@example.com' -and $(try { $null = ConvertTo-OwnerEmail 'x"; return True #@a.com'; $false } catch { $true }) -and $(try { $null = ConvertTo-OwnerEmail 'not-an-email'; $false } catch { $true })) ''
  $enr = New-OwnerEnrollmentExpression 'owner@example.com'
  Test-Condition 'owner: Google enrollment admits only the owner''s address, and only when Google verified it' ($enr -match 'owner_email = "owner@example.com"' -and $enr -match 'oauth_userinfo' -and $enr -match 'verified_email' -and $enr -match 'email_verified' -and $enr -match 'return False') $enr
  Test-Condition 'owner: the policy text tells admins it now belongs to authentik' ($enr -match 'belongs to authentik') ''
  $mods = @(Get-Command -Module Authentik | ForEach-Object { $_.Name })
  Test-Condition 'no user lists: the allow-list functions are gone from the manager' (-not ($mods -match 'AccessList|AppAccessExpression|EnrollmentExpression$' | Where-Object { $_ -ne 'New-OwnerEnrollmentExpression' })) ($mods -join ', ')

  # --- Discovery ----------------------------------------------------------------------------------------------------------------
  $ct = { param($name, $image, $proj, $svcName, $state, $nets, $pub) [pscustomobject]@{ name = $name; image = $image; tag = ($image -replace '^[^:]+:([^@]+).*$', '$1'); state = $state; health = 'healthy'
      compose = [pscustomobject]@{ project = $proj; service = $svcName }; networks = @($nets | ForEach-Object { [pscustomobject]@{ name = $_ } }); published = @($pub) } }
  $containers = @(
    (& $ct 'authentik-server' 'ghcr.io/goauthentik/server:2026.8.5@sha256:aa' 'authentik' 'server' 'running' @('proxynet', 'authentik_internal') @([pscustomobject]@{ port = 9000; hostPort = 9000; hostIp = '127.0.0.1' })),
    (& $ct 'authentik-worker' 'ghcr.io/goauthentik/server:2026.8.5@sha256:aa' 'authentik' 'worker' 'running' @('authentik_internal') @()),
    (& $ct 'authentik-postgresql' 'postgres:16-alpine@sha256:bb' 'authentik' 'postgresql' 'running' @('authentik_internal') @()),
    (& $ct 'sso-server-1' 'ghcr.io/goauthentik/server:2025.10.1' 'sso' 'server' 'exited' @('sso_default') @()),
    (& $ct 'web' 'nginx:1' 'site' 'web' 'running' @('proxynet') @()))
  $found = @(Find-AuthentikInstallations -Containers $containers -Apps @([pscustomobject]@{ project = 'authentik'; appId = 'authentik'; folder = 'C:\apps\authentik'; localPort = 9000 }, [pscustomobject]@{ project = 'ak2'; appId = 'authentik'; folder = 'C:\apps\ak2'; localPort = 9010 }) -ProxyNetwork 'proxynet')
  $a1 = @($found | Where-Object { $_.project -eq 'authentik' })[0]; $a2 = @($found | Where-Object { $_.project -eq 'sso' })[0]; $a3 = @($found | Where-Object { $_.project -eq 'ak2' })[0]
  Test-Condition 'discovery: manager-installed authentik with server, worker, database, proxy network and local port' ($a1.managed -and $a1.server.name -eq 'authentik-server' -and $a1.worker.name -eq 'authentik-worker' -and $a1.database.name -eq 'authentik-postgresql' -and $a1.onProxyNetwork -and $a1.localUrl -eq 'http://127.0.0.1:9000' -and $a1.version -eq '2026.8.5') ($a1 | ConvertTo-Json -Depth 4 -Compress)
  Test-Condition 'discovery: a hand-made installation is found as not managed (adoptable, never edited)' ($a2 -and -not $a2.managed -and -not $a2.onProxyNetwork -and $a2.server.state -eq 'exited') ''
  Test-Condition 'discovery: a prepared, never started installation is listed without containers' ($a3 -and $a3.managed -and -not $a3.server -and $found.Count -eq 3) ''

  # --- Model ------------------------------------------------------------------------------------------------------------------
  $st = { param($m, $id) @($m.steps | Where-Object { $_.id -eq $id })[0].state }
  $co = { param($m, $id) @($m.components | Where-Object { $_.id -eq $id })[0].state }
  $m0 = Get-IdentityModel -Facts @{ provider = '' }
  Test-Condition 'model: no provider -> choose one (optional for the basic setup)' ((& $st $m0 'provider') -eq 'awaiting-user' -and @($m0.steps).Count -eq 1) ''
  Test-Condition 'model: "Configure later" is skipped; Authelia is shown as not configured (no integration)' ((& $st (Get-IdentityModel -Facts @{ provider = 'none' }) 'provider') -eq 'skipped' -and (& $st (Get-IdentityModel -Facts @{ provider = 'authelia' }) 'provider') -eq 'not-configured') ''
  $m1 = Get-IdentityModel -Facts @{ provider = 'authentik'; install = $null }
  Test-Condition 'model: authentik chosen but nothing installed -> install or adopt' ((& $st $m1 'install') -eq 'awaiting-user' -and (& $st $m1 'api') -eq 'not-configured' -and (& $st $m1 'google') -eq 'not-configured') ''
  $health = [pscustomobject]@{ Live = $true; Ready = $true; Setup = 'pending'; Message = '' }
  $m2 = Get-IdentityModel -Facts @{ provider = 'authentik'; install = $a1; health = $health; token = @{ stored = $false } }
  Test-Condition 'model: an unclaimed instance asks for the initial setup right away' ((& $st $m2 'admin') -eq 'awaiting-user' -and (& $st $m2 'install') -eq 'reachable' -and (& $st $m2 'api') -eq 'awaiting-user') ''
  $health.Setup = 'done'
  $tokBad = @{ stored = $true; readable = $true; ok = $false; message = 'authentik rejected this token' }
  Test-Condition 'model: a rejected token is a failure, not a silent pass' ((& $st (Get-IdentityModel -Facts @{ provider = 'authentik'; install = $a1; health = $health; token = $tokBad }) 'api') -eq 'failed') ''
  $tokUser = @{ stored = $true; readable = $true; ok = $true; username = 'bob'; superuser = $false }
  Test-Condition 'model: a token without administrator rights is reported' ((& $st (Get-IdentityModel -Facts @{ provider = 'authentik'; install = $a1; health = $health; token = $tokUser }) 'api') -eq 'failed') ''
  $tok = @{ stored = $true; readable = $true; ok = $true; username = 'akadmin'; superuser = $true }
  $ov = [pscustomobject]@{ Version = '2026.8.5'; MissingFlows = @(); Outpost = [pscustomobject]@{ AuthentikHost = 'https://auth.example.com/'; Providers = @(3) } }
  $src = [pscustomobject]@{ Slug = 'google'; ConsumerKey = '1-x.apps.googleusercontent.com' }
  $route = @{ exists = $true; enabled = $true; router = 'enabled'; publish = $true; access = $false; service = 'authentik' }
  $base = @{ provider = 'authentik'; install = $a1; health = $health; token = $tok; overview = $ov; hostname = 'auth.example.com'; publicUrl = 'https://auth.example.com'; route = $route; cloudflare = @{ dns = $true; tunnel = $true } }
  $m3 = Get-IdentityModel -Facts ($base + @{ google = @{ clientId = '1-x.apps.googleusercontent.com'; source = $src; redirect = [pscustomobject]@{ ok = $true; message = 'ok' }; verifiedAt = '' }; apps = @() })
  Test-Condition 'model: a configured Google source that redirects correctly is "configured", never "verified" without a real sign-in' ((& $st $m3 'google') -eq 'configured' -and (& $co $m3 'google-login') -eq 'awaiting-user' -and (& $co $m3 'google-callback') -eq 'configured') ''
  Test-Condition 'model: saved route + DNS is "configured" until the public address is checked' ((& $st $m3 'hostname') -eq 'configured' -and (& $co $m3 'outpost') -eq 'configured') ''
  $m4 = Get-IdentityModel -Facts ($base + @{ publicCheck = @{ state = 'ok'; message = 'answers' }; google = @{ source = $src; redirect = [pscustomobject]@{ ok = $true; message = 'ok' }; verifiedAt = '2026-10-25T10:00:00'; verifiedBy = 'joe' }; apps = @() })
  Test-Condition 'model: Google is verified only with sign-in evidence; the public address only after its check' ((& $st $m4 'google') -eq 'verified' -and (& $st $m4 'hostname') -eq 'verified') ''
  $m5 = Get-IdentityModel -Facts ($base + @{ google = @{ source = $src; redirect = [pscustomobject]@{ ok = $false; message = 'redirect URI mismatch' } } })
  Test-Condition 'model: a wrong redirect URI fails the Google step' ((& $st $m5 'google') -eq 'failed') ''
  $chal = { param($s) [pscustomobject]@{ State = $s; Message = $s } }
  $apps = @(@{ service = 'wiki'; hostname = 'wiki.example.com'; protected = $true; authentik = $true; challenge = (& $chal 'auth'); verifiedAt = '' },
    @{ service = 'blog'; hostname = 'blog.example.com'; protected = $true; authentik = $true; challenge = (& $chal 'open'); verifiedAt = '' },
    @{ service = 'git'; hostname = 'git.example.com'; protected = $true; authentik = $true; challenge = (& $chal 'auth'); verifiedAt = '2026-10-25T10:00:00' },
    @{ service = 'old'; hostname = 'old.example.com'; protected = $true; authentik = $false; challenge = $null; verifiedAt = '' })
  $m6 = Get-IdentityModel -Facts ($base + @{ apps = $apps })
  Test-Condition 'model: per application: sign-in required, verified only from access evidence, open/missing are failures' ((& $co $m6 'app:wiki') -eq 'auth-required' -and (& $co $m6 'app:git') -eq 'verified' -and (& $co $m6 'app:blog') -eq 'failed' -and (& $co $m6 'app:old') -eq 'failed' -and (& $st $m6 'apps') -eq 'failed') ''
  Test-Condition 'model: the next step is the first failure or open action' (@($m6.next)[0] -eq 'apps' -and @((Get-IdentityModel -Facts @{ provider = 'authentik'; install = $null }).next)[0] -eq 'install') ''
  $ownerStep = { param($facts) & $st (Get-IdentityModel -Facts ($base + $facts)) 'owner' }
  Test-Condition 'model: owner not entered yet -> awaiting the user (asked once)' ((& $ownerStep @{ owner = @{ email = '' } }) -eq 'awaiting-user') ''
  Test-Condition 'model: owner entered, Google not set up -> configured (does not block the next steps)' ((& $ownerStep @{ owner = @{ email = 'o@example.com' } }) -eq 'configured') ''
  Test-Condition 'model: Google set up, owner has not signed in -> awaiting the owner''s Google sign-in' ((& $ownerStep @{ owner = @{ email = 'o@example.com' }; google = @{ source = $src } }) -eq 'awaiting-user') ''
  $mo = Get-IdentityModel -Facts ($base + @{ owner = @{ email = 'o@example.com'; verifiedAt = '2026-10-25T10:00:00'; username = 'owner' }; google = @{ source = $src; redirect = [pscustomobject]@{ ok = $true; message = 'ok' } } })
  Test-Condition 'model: the owner''s real Google sign-in verifies both the owner and Google sign-in' ((& $st $mo 'owner') -eq 'verified' -and (& $st $mo 'google') -eq 'verified' -and (& $co $mo 'google-login') -eq 'verified') ''
  $ml = Get-IdentityModel -Facts ($base + @{ authMode = 'local'; owner = @{ email = '' } })
  Test-Condition 'model (local path): Google is skipped, the owner is the local administrator signing in once' ((& $st $ml 'google') -eq 'skipped' -and (& $st $ml 'owner') -eq 'awaiting-user') ''
  $mlv = Get-IdentityModel -Facts ($base + @{ authMode = 'local'; owner = @{ verifiedAt = '2026-10-25T10:00:00'; username = 'akadmin' } })
  Test-Condition 'model (local path): a verified local owner does not mark Google sign-in as verified' ((& $st $mlv 'owner') -eq 'verified' -and (& $st $mlv 'google') -eq 'skipped') ''
  $stopped = $a1 | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $stopped.server.state = 'exited'
  Test-Condition 'model: a stopped server fails the installation step and its component' ((& $st (Get-IdentityModel -Facts @{ provider = 'authentik'; install = $stopped; token = @{ stored = $false } }) 'install') -eq 'failed' -and (& $co (Get-IdentityModel -Facts @{ provider = 'authentik'; install = $stopped }) 'server') -eq 'failed') ''

  # --- Configuration and resume -------------------------------------------------------------------------------------------------
  $cfg = Read-IdentityConfig -Settings $settings
  Test-Condition 'config: defaults without a file (no provider, Google slug "google", no owner yet, owner becomes admin unless unticked)' ($cfg.provider -eq '' -and $cfg.authentik.google.slug -eq 'google' -and $cfg.authentik.owner.email -eq '' -and $cfg.authentik.owner.makeAdmin -and -not $cfg.authentik.google.PSObject.Properties['emails']) ''
  $cfg.provider = 'authentik'; $cfg.authentik.hostname = 'auth.example.com'; $cfg.authentik.google.clientId = '1-x.apps.googleusercontent.com'
  Set-IdentityProgress $cfg 'google' 'draft' 'client ID saved'
  Set-IdentityApp $cfg 'wiki' ([pscustomobject]@{ slug = 'dm-wiki'; bindings = @('b1') })
  Save-IdentityConfig -Settings $settings -Config $cfg
  $back = Read-IdentityConfig -Settings $settings
  Test-Condition 'config: round trip keeps choice, hostname, Google draft, progress and protected apps' ($back.provider -eq 'authentik' -and $back.authentik.google.clientId -eq '1-x.apps.googleusercontent.com' -and $back.progress.step -eq 'google' -and (Get-IdentityApp $back 'wiki').slug -eq 'dm-wiki') ''
  Set-IdentityApp $back 'wiki' $null
  Test-Condition 'config: removing a protected app forgets only that app' ($null -eq (Get-IdentityApp $back 'wiki')) ''
  [IO.File]::WriteAllText((Join-Path $work 'config\identity.json'), '{ "provider": "authentik", "authentik": { "hostname": "auth.example.com" } }')
  $partial = Read-IdentityConfig -Settings $settings
  Test-Condition 'config: a partial (older) file is completed with defaults' ($partial.authentik.hostname -eq 'auth.example.com' -and $partial.authentik.google.slug -eq 'google' -and $partial.progress.step -eq '') ''
  Test-Condition 'config: never contains a secret field' ((Get-Content -Raw (Join-Path $work 'config\identity.json')) -notmatch 'secret|token|password') ''

  # --- Credential manager (reusable; fake validators) -----------------------------------------------------------------------
  Import-Module (Join-Path $repo 'lib\CredentialManager.psm1') -Force
  $script:calls = 0
  $good = { param($t) $script:calls++; if ($t -like 'good-*') { @{ Ok = $true; Status = 'valid'; Account = 'akadmin'; Server = 'http://127.0.0.1:9000'; Version = '2026.8.5'; ExpiresAt = $(if ($t -like '*-soon') { (Get-Date).AddDays(5).ToUniversalTime().ToString('o') } elseif ($t -like '*-past') { (Get-Date).AddMinutes(1).ToUniversalTime().ToString('o') } else { '' }); Message = 'ok' } }
    elseif ($t -like 'outpost-*') { @{ Ok = $false; Status = 'insufficient'; Account = 'ak-outpost-123'; Message = 'outpost token' } }
    elseif ($t -like 'down-*') { @{ Ok = $false; Status = 'unreachable'; Message = 'server down' } }
    else { @{ Ok = $false; Status = 'rejected'; Message = 'rejected' } } }
  $ca = @{ Settings = $settings; Id = 'test-api'; SecretName = 'test_api'; Label = 'test token'; Validator = $good }
  $v0 = Get-CredentialView -Settings $settings -Id 'test-api' -SecretName 'test_api'
  Test-Condition 'credentials: nothing saved -> "missing", replacement offered' ($v0.status -eq 'missing' -and -not $v0.stored) ''
  $r1 = Set-CredentialFromCandidate @ca -Candidate 'outpost-token-0000000000000000000000'
  Test-Condition 'credentials: an outpost token (insufficient) is refused and not saved' (-not $r1.Ok -and -not $r1.View.stored -and $r1.Result.Status -eq 'insufficient' -and -not (Test-Path -LiteralPath (Get-ProtectedSecretPath $settings 'test_api'))) ''
  $r2 = Set-CredentialFromCandidate @ca -Candidate 'good-admin-token-1111111111111111111111'
  Test-Condition 'credentials: a valid token is saved with account, server and validation time' ($r2.Ok -and -not $r2.Replaced -and $r2.View.status -eq 'valid' -and $r2.View.account -eq 'akadmin' -and $r2.View.lastSuccessAt) ($r2.View | ConvertTo-Json -Compress)
  $before = [IO.File]::ReadAllBytes((Get-ProtectedSecretPath $settings 'test_api'))
  foreach ($bad in @('rejected-token-22222222222222222222', 'outpost-token-33333333333333333333', 'down-token-444444444444444444444')) {
    $rb = Set-CredentialFromCandidate @ca -Candidate $bad
    Test-Condition "credentials: failed replacement ($($rb.Result.Status)) keeps the stored token byte for byte and its status" (-not $rb.Ok -and (Read-ProtectedSecret -Settings $settings -Name 'test_api') -eq 'good-admin-token-1111111111111111111111' -and [Convert]::ToBase64String($before) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-ProtectedSecretPath $settings 'test_api'))) -and $rb.View.status -eq 'valid' -and $rb.View.lastAttempt.status -eq $rb.Result.Status) ''
  }
  $r3 = Set-CredentialFromCandidate @ca -Candidate 'good-rotated-token-5555555555555555555-soon'
  Test-Condition 'credentials: voluntary rotation of a working token replaces it and records the time' ($r3.Ok -and $r3.Replaced -and $r3.View.rotatedAt -and (Read-ProtectedSecret -Settings $settings -Name 'test_api') -eq 'good-rotated-token-5555555555555555555-soon') ''
  Test-Condition 'credentials: an expiry date within 14 days produces a warning' ($r3.View.expiresAt -and $r3.View.expiresInDays -le 5 -and $r3.View.expiryWarning -match 'expires in') ($r3.View.expiryWarning)
  $script:calls = 0
  $t1 = Test-StoredCredential @ca -IfOlderThanMinutes 5
  Test-Condition 'credentials: page loads reuse a recent validation (no API call)' ($script:calls -eq 0 -and $t1.status -eq 'valid') ''
  $t2 = Test-StoredCredential @ca
  Test-Condition 'credentials: "Test connection" validates again without re-entering the token' ($script:calls -eq 1 -and $t2.ok -and $t2.lastValidatedAt) ''
  $ca2 = $ca.Clone(); $ca2.Validator = { param($t) @{ Ok = $false; Status = 'unreachable'; Message = 'server down' } }
  $t3 = Test-StoredCredential @ca2
  Test-Condition 'credentials: an unreachable server is reported, the token and its last good status are kept' ($t3.status -eq 'unreachable' -and (Get-CredentialRecord $settings 'test-api').status -eq 'valid' -and (Read-ProtectedSecret -Settings $settings -Name 'test_api') -like 'good-rotated*') ''
  $null = Set-CredentialFromCandidate @ca -Candidate 'good-short-lived-666666666666666666-past'
  $rec = Get-CredentialRecord $settings 'test-api'; $rec.expiresAt = (Get-Date).AddMinutes(-5).ToString('s'); Save-CredentialRecord $settings 'test-api' $rec
  $ca3 = $ca.Clone(); $ca3.Validator = { param($t) @{ Ok = $false; Status = 'rejected'; Message = 'rejected' } }
  $t4 = Test-StoredCredential @ca3
  Test-Condition 'credentials: a token refused after its expiry date is reported as expired' ($t4.status -eq 'expired' -and -not $t4.ok -and $t4.expiryWarning -match 'expired') ($t4 | ConvertTo-Json -Compress)
  $r5 = Set-CredentialFromCandidate @ca -Candidate 'good-replacement-777777777777777777777'
  Test-Condition 'credentials: an expired token is replaced; previous errors are cleared' ($r5.Ok -and $r5.View.status -eq 'valid' -and -not $r5.View.expiryWarning -and $r5.View.lastAttempt.status -eq 'valid') ''
  $recText = [IO.File]::ReadAllText((Join-Path $work 'config\credentials.json'))
  Test-Condition 'credentials: the status file holds no token value' ($recText -notmatch 'good-|outpost-token|rejected-token' -and ($r5.View | ConvertTo-Json -Depth 5) -notmatch 'good-replacement') ''
  [IO.File]::WriteAllText((Get-ProtectedSecretPath $settings 'test_api'), '{"version":1,"data":"bm90LWRwYXBp"}')
  Test-Condition 'credentials: a token saved by another Windows account is "unreadable" and can be replaced' ((Get-CredentialView -Settings $settings -Id 'test-api' -SecretName 'test_api').status -eq 'unreadable' -and (Set-CredentialFromCandidate @ca -Candidate 'good-after-unreadable-88888888888888').Ok) ''
  Test-Condition 'credentials: removal forgets the token and its record' ((Remove-StoredCredential -Settings $settings -Id 'test-api' -SecretName 'test_api') -and (Get-CredentialView -Settings $settings -Id 'test-api' -SecretName 'test_api').status -eq 'missing' -and -not (Get-CredentialRecord $settings 'test-api').status) ''

  # --- Configuration backup -------------------------------------------------------------------------------------------------
  Import-Module (Join-Path $repo 'lib\Dashboard.psm1') -Force
  Import-Module (Join-Path $repo 'lib\ConfigBackup.psm1') -Force
  $bk = Read-IdentityConfig -Settings $settings
  $bk.provider = 'authentik'; $bk.authentik.hostname = 'auth.example.com'; $bk.authentik.google.clientId = '123456789012-abcdefgh12345678.apps.googleusercontent.com'
  $bk.authentik.google.verifiedAt = '2026-10-25T10:00:00'; $bk.authentik.google.verifiedBy = 'joe'
  $bk.authentik.owner.email = 'Owner@Example.com'; $bk.authentik.owner.verifiedAt = '2026-10-25T10:00:00'; $bk.authentik.owner.username = 'owner'
  Set-IdentityApp $bk 'wiki' ([pscustomobject]@{ slug = 'dm-wiki'; initialAccess = 'owner-only'; verifiedAt = '2026-10-25T10:00:00'; verifiedBy = 'joe' })
  Save-IdentityConfig -Settings $settings -Config $bk
  $man = Get-ConfigManifest -Settings $settings -SourceRoot $repo
  $mj = ConvertTo-ManifestJson $man
  Test-Condition 'backup: Identity & Access choices are in the backup (provider, sign-in hostname, Google client ID, owner, protected apps by name)' ($man.identity.provider -eq 'authentik' -and $man.identity.authentik.hostname -eq 'auth.example.com' -and $man.identity.authentik.google.clientId -match 'googleusercontent' -and $man.identity.authentik.owner.email -eq 'owner@example.com' -and @($man.identity.authentik.protectedApps) -contains 'wiki') ($mj)
  Test-Condition 'backup: no sign-in evidence and no access rules are backed up (authentik keeps those)' ($mj -notmatch 'verifiedAt' -and $mj -notmatch 'verifiedBy' -and $mj -notmatch 'initialAccess') ''
  Test-Condition 'backup: the authentik API token is listed as a credential that is never exported' (@($man.credentials | Where-Object { $_.id -eq 'authentik-api-token' -and -not $_.included }).Count -eq 1) ''

  # --- Secret store -------------------------------------------------------------------------------------------------------------
  $secret = 'tok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
  Save-ProtectedSecret -Settings $settings -Name 'authentik_api' -Value $secret -Label 'test'
  $path = Get-ProtectedSecretPath $settings 'authentik_api'
  $info = Get-ProtectedSecretInfo -Settings $settings -Name 'authentik_api'
  Test-Condition 'secrets: stored encrypted (DPAPI), readable back, metadata only in the info' ((Read-ProtectedSecret -Settings $settings -Name 'authentik_api') -eq $secret -and [IO.File]::ReadAllText($path) -notmatch $secret -and $info.Stored -and $info.Readable -and ($info | ConvertTo-Json) -notmatch $secret) ''
  $acl = (Get-Acl -LiteralPath $path).Access | ForEach-Object { [string]$_.IdentityReference }
  Test-Condition 'secrets: file readable by this account, SYSTEM and Administrators only' (-not @($acl | Where-Object { $_ -match 'Users$|Everyone|Authenticated' }).Count) ($acl -join ', ')
  Test-Condition 'secrets: names are restricted (no path traversal)' ($(try { $null = Get-ProtectedSecretPath $settings '..\x'; $false } catch { $true })) ''
  Test-Condition 'secrets: removal' ((Remove-ProtectedSecret -Settings $settings -Name 'authentik_api') -and -not (Test-Path -LiteralPath $path) -and $null -eq (Read-ProtectedSecret -Settings $settings -Name 'authentik_api')) ''

  # --- Catalog manifest -----------------------------------------------------------------------------------------------------------
  Import-Module (Join-Path $repo 'lib\AppCatalog.psm1') -Force
  $m = Get-Content -Raw (Join-Path $repo 'catalog\apps\authentik.json') | ConvertFrom-Json
  $errs = @(Test-AppManifest $m)
  $wenv = $m.services.worker.environment
  Test-Condition 'catalog: authentik manifest valid; bootstrap administrator, email and API token on server and worker' (-not $errs.Count -and $wenv.AUTHENTIK_BOOTSTRAP_TOKEN -eq '{{input:apiToken}}' -and $wenv.AUTHENTIK_BOOTSTRAP_PASSWORD -eq '{{input:adminPassword}}' -and $m.services.server.environment.AUTHENTIK_BOOTSTRAP_EMAIL -eq '{{input:adminEmail}}') ($errs -join '; ')
  # --- Address of a protected application (authentik's outpost matches the forwarded Host, port included) -----------------
  Import-Module (Join-Path $repo 'lib\RoutingModel.psm1') -Force
  $a1 = Get-IdentityAppAddress 'https://auth.example.test' 'app.example.test'
  $a2 = Get-IdentityAppAddress 'http://auth.idtest.example:49464/' 'echo.idtest.example'
  $a3 = Get-IdentityAppAddress '' 'app.example.test'
  $a4 = Get-IdentityAppAddress 'https://auth.example.test:443/' 'app.example.test'
  Test-Condition 'protect: the application address follows the public sign-in address (https without port in production; scheme and port of a test entry point)' ($a1.Url -eq 'https://app.example.test' -and $a1.HostPort -eq 0 -and $a1.HostHeader -eq 'app.example.test' -and $a2.Url -eq 'http://echo.idtest.example:49464' -and $a2.HostPort -eq 49464 -and $a2.HostHeader -eq 'echo.idtest.example:49464' -and $a3.Url -eq 'https://app.example.test' -and $a4.Url -eq 'https://app.example.test') "$($a1.Url) $($a2.Url) $($a3.Url) $($a4.Url)"
  # --- The sign-in hostname through Cloudflare (API mock; no authentik, no real Cloudflare) ------------------------------------
  $inst = Join-Path $work 'inst'
  New-Item -ItemType Directory -Force -Path $inst | Out-Null
  foreach ($item in @('compose.yaml', 'install.ps1', 'services.ps1', 'webui.ps1', '.env.example', 'lib', 'webui', 'scripts', 'traefik', 'config', 'examples', 'catalog')) { Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $inst -Recurse -Force }
  Get-ChildItem -LiteralPath (Join-Path $inst 'traefik\dynamic') -Filter 'svc-*.yml' -ErrorAction SilentlyContinue | Remove-Item -Force
  Remove-Item -LiteralPath (Join-Path $inst 'config\services.json'), (Join-Path $inst 'config\cloudflare.json'), (Join-Path $inst 'config\identity.json') -ErrorAction SilentlyContinue
  $sid = 'tpx-idunit-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
  @("STACK_NAME=$sid", "TRAEFIK_HTTP_PORT=$(Get-FreeTcpPort)", "TRAEFIK_DASHBOARD_PORT=$(Get-FreeTcpPort)", "PROXY_NETWORK=$sid-proxy", 'TUNNEL_SUBNET=172.31.243.0/28', 'TUNNEL_IP_RANGE=172.31.243.0/29', 'CLOUDFLARED_IP=172.31.243.10') | Set-Content -LiteralPath (Join-Path $inst '.env') -Encoding ASCII
  $apiToken = 'mockTok_' + [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $acct = 'acc0000000000000000000000000001'; $tunnelId = '11111111-2222-3333-4444-555555555555'
  $mock = $null; $ui = $null
  try {
    $mock = Start-CloudflareMock -Repo $repo -WorkDir $work -Token $apiToken
    $ui = Start-WebUiServer -Script (Join-Path $inst 'webui.ps1') -InstallPath $inst -WorkDir $work -ApiBase $mock.Base
    $null = Connect-WebUi $ui
    $null = Invoke-WebUi $ui POST '/api/cloudflare/token' @{ token = $apiToken }
    $null = Invoke-WebUi $ui POST '/api/cloudflare/domains' @{ zoneIds = @('zone00000000000000000000000000001') }
    $null = Invoke-WebUi $ui POST '/api/cloudflare/select' @{ accountId = $acct; tunnelId = $tunnelId }
    $null = Invoke-WebUi $ui POST '/api/identity/provider' @{ provider = 'authentik' }
    $gi = Invoke-WebUi $ui GET '/api/identity'
    Test-Condition 'cloudflare: the sign-in hostname is suggested from the allowed domain (auth.<domain>)' ($gi.Status -eq 200 -and $gi.Data.suggestedHostname -eq 'auth.example.test' -and $gi.Data.cloudflareReady) ($gi.Body.Substring(0, [Math]::Min(300, $gi.Body.Length)))
    $tunnelsBefore = @((Get-MockState $mock).tunnels).Count
    $route = { param($hn) @{ op = 'add'; service = @{ name = 'authentik'; hostnames = @($hn); target = @{ type = 'docker'; host = "$sid-noak-server"; port = 9000 }; cloudflare = @{ publish = $true; access = $false } }; cloudflare = @{ automate = $true; accessEmails = @(); cleanup = $true } } }
    $pl = Invoke-WebUi $ui POST '/api/services/plan' (& $route 'auth.example.test')
    $acts = @($pl.Data.cloudflare.actions)
    Test-Condition 'cloudflare: preview adds a proxied CNAME to the existing tunnel and a tunnel route, no Access, no new tunnel' ($pl.Status -eq 200 -and @($acts | Where-Object { $_.step -eq 'dns' -and $_.kind -eq 'create' -and $_.summary -match "$tunnelId\.cfargotunnel\.com" }).Count -eq 1 -and @($acts | Where-Object { $_.step -eq 'tunnel' -and $_.kind -eq 'create' }).Count -eq 1 -and -not @($acts | Where-Object { $_.step -eq 'access' -and $_.kind -ne 'none' }).Count) (($acts | ForEach-Object { "$($_.step):$($_.kind)" }) -join ', ')
    Test-Condition 'cloudflare: the preview changes nothing in Cloudflare' (-not @((Get-MockState $mock).dns | Where-Object { $_.name -eq 'auth.example.test' }).Count) ''
    $dup = Invoke-WebUi $ui POST '/api/services/plan' (& $route 'taken.example.test')
    $ow = @($dup.Data.cloudflare.actions | Where-Object { $_.overwrite })
    Test-Condition 'cloudflare: an existing DNS record for the hostname is never overwritten silently' ($dup.Status -eq 200 -and $ow.Count -ge 1 -and @($ow | Where-Object { $_.step -eq 'dns' }).Count -eq 1) (($dup.Data.cloudflare.actions | ForEach-Object { "$($_.step):$($_.kind):$($_.overwrite)" }) -join ', ')
    $dupApply = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $dup.Data.planId; confirm = $true; acceptUnverifiedBackend = $true }
    Test-Condition 'cloudflare: applying without confirming the overwrite is refused' ($dupApply.Status -eq 400 -and (@((Get-MockState $mock).dns | Where-Object { $_.name -eq 'taken.example.test' })[0].content -eq 'elsewhere.example.net')) ($dupApply.Body)
    if ($SkipDocker -or -not (Get-DockerStatus).EngineRunning) { Add-Result 'SKIP' 'cloudflare: apply the sign-in route' 'needs Docker for the Traefik validation' }
    else {
      $pl = Invoke-WebUi $ui POST '/api/services/plan' (& $route 'auth.example.test')
      $ap = Invoke-WebUi $ui POST '/api/services/apply' @{ planId = $pl.Data.planId; confirm = $true; acceptUnverifiedBackend = $true }
      $st = Get-MockState $mock
      $rec = @($st.dns | Where-Object { $_.name -eq 'auth.example.test' })
      $ingress = @($st.configs.$tunnelId.ingress | Where-Object { $_.PSObject.Properties['hostname'] -and $_.hostname -eq 'auth.example.test' })
      Test-Condition 'cloudflare: applied to the mock - CNAME to the existing tunnel, ingress to Traefik, no Access app, no second tunnel' ($ap.Status -eq 200 -and $rec.Count -eq 1 -and $rec[0].content -eq "$tunnelId.cfargotunnel.com" -and $ingress.Count -eq 1 -and $ingress[0].service -match '^http://.+:80$' -and -not @($st.apps | Where-Object { $_.domain -eq 'auth.example.test' }).Count -and @($st.tunnels).Count -eq $tunnelsBefore) ($ap.Body)
      $null = Invoke-WebUi $ui POST '/api/identity/hostname' @{ hostname = 'auth.example.test'; service = 'authentik' }
      $g2 = Invoke-WebUi $ui GET '/api/identity'
      Test-Condition 'cloudflare: Identity & Access sees the DNS record and tunnel route it created; the public address stays unverified' ($g2.Data.cloudflare.dns -and $g2.Data.cloudflare.tunnel -and -not $g2.Data.cloudflare.access -and (@($g2.Data.model.components | Where-Object { $_.id -eq 'public' })[0].state -ne 'verified')) ($g2.Data.cloudflare | ConvertTo-Json -Compress)
    }
    $pp = Invoke-WebUi $ui POST '/api/identity/protect/plan' @{ service = 'authentik'; emails = @('a@example.test') }
    Test-Condition 'protect: refused while no authentik is connected (nothing is changed)' ($pp.Status -eq 409) ($pp.Body)
    Test-Condition 'cloudflare: the API token never reaches the browser' (-not @($ui.Bodies | Where-Object { $_ -match [regex]::Escape($apiToken) }).Count) ''
  } finally { Stop-TestServer $ui; Stop-TestServer $mock }

  Test-Condition 'catalog: no Docker socket, database not on the proxy network, pinned images' (-not @($m.services.PSObject.Properties | Where-Object { [bool](Get-ServiceProperty $_.Value 'dockerSocket' $false) -or (@(Get-ServiceProperty $_.Value 'volumes' @()) | Where-Object { [string](Get-ServiceProperty $_ 'source' '') -match 'docker\.sock' }) }).Count -and -not [bool](Get-ServiceProperty $m.services.postgresql 'proxy' $false) -and $m.services.server.image -match '@sha256:' -and $m.services.postgresql.image -match '@sha256:') ''
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host ('{0} passed, {1} failed' -f @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $failed.Count)
if ($failed.Count -gt 0) { exit 1 }
exit 0
