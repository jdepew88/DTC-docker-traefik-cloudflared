# Identity & Access (authentik, Google sign-in, ForwardAuth)

Optional. The Deployment Manager works without it: basic setup, services and Cloudflare Access are unchanged.
When used, it installs or adopts **authentik**, publishes its sign-in page through the existing Traefik and Cloudflare
Tunnel, connects **Google sign-in**, and puts authentik **ForwardAuth** in front of the applications you choose.

Tested only on Windows 11 with Docker Desktop (WSL 2). The code avoids Windows-only assumptions where it can (see
[Portability](#portability)), but other hosts are not supported yet.

## The path of a request

```
Browser --HTTPS--> Cloudflare (+ Access, optional) ==tunnel==> cloudflared --> Traefik :80
   Traefik router svc-<app>  --ForwardAuth--> authentik embedded outpost (http://<authentik-server>:9000)
        allowed  -> application                not signed in -> https://auth.<domain>/ (local account or Google)
   Traefik router svc-<app>-outpost (/outpost.goauthentik.io/) --> authentik (sign-in start, callback, sign-out)
   Traefik router svc-authentik (auth.<domain>) --> authentik (never protected by itself)
```

Everything Traefik does stays in explicit file-provider YAML generated from `config\services.json`; no Docker labels,
no Docker provider. A protected service gets three additions in its own `traefik\dynamic\svc-<name>.yml`:

| Generated | Purpose |
| --- | --- |
| middleware `svc-<name>-authentik` (`forwardAuth`) | `address: http://<authentik-server>:9000/outpost.goauthentik.io/auth/traefik`, `trustForwardHeader: true` (safe: the `web` entry point only trusts X-Forwarded-* from cloudflared), `maxResponseBodySize`, and the documented `X-authentik-*` response headers. First in the router's middleware chain. |
| router `svc-<name>-outpost` | `Host(...) && PathPrefix(/outpost.goauthentik.io/)` to authentik, without ForwardAuth (the longer rule wins). |
| service `svc-<name>-outpost` | `http://<authentik-server>:9000`, `passHostHeader: true` (the outpost finds the provider by the Host header). |

The backend address is the container's Docker DNS name and internal port, never an IP. If authentik is stopped or not on
the shared network, Traefik answers 5xx for protected applications: **fail closed**.

Guards (validation, `lib\TraefikProxy.psm1`): authentik cannot protect its own route (redirect loop); one sign-in
provider per route (a hand-added `authelia`/`forward-auth` middleware next to authentik is refused); the endpoint must be
`http://<name>:<port>`; a service called `<protected>-outpost` would collide and is refused; Cloudflare Access + authentik
is allowed with a "two logins" warning. A service form that does not send the `auth` field keeps the service's current
protection (editing never silently removes it).

## authentik deployment

Installed by the App Catalog (`catalog\apps\authentik.json`) through the normal Compose lifecycle (preview, validation by
`docker compose config`, prepare/start, backups, updates, removal with data retention):

| Service | Image (pinned) | Networks | Notes |
| --- | --- | --- | --- |
| server | `ghcr.io/goauthentik/server:2026.8.5@sha256:6022…` | shared proxy network + private `<project>_internal` | web, API, embedded outpost; 127.0.0.1:<port> for the manager |
| worker | same image | private only | runs as root like upstream (file permissions); **no Docker socket** |
| postgresql | `postgres:16-alpine@sha256:deb2…` | private only | named volume `<project>_database`, no published port; major upgrades only with authentik's dump/restore procedure |

No Redis (removed in authentik 2025.10). The image's own health check is used for server and worker; PostgreSQL has
`pg_isready`; server and worker wait for a healthy database. The Docker socket mount of the official compose file is
left out: it only serves automatically deployed outposts, and the **embedded outpost** (part of the server) is enough
for Traefik ForwardAuth.

First start without an open setup page: the catalog generates `AUTHENTIK_BOOTSTRAP_PASSWORD` (also written to
`credentials.txt`), `AUTHENTIK_BOOTSTRAP_EMAIL` (you enter it) and `AUTHENTIK_BOOTSTRAP_TOKEN` (an API token for akadmin
that the manager uses). authentik reads them **only on the first start** (verified: a changed password survives restarts).
`.env` and `credentials.txt` are readable by your Windows account, SYSTEM and Administrators only.

Existing installations are **adopted**, not changed: the manager finds authentik containers on the engine (by image,
grouped by Compose project), records the chosen one in `config\identity.json` and never edits a project it did not
create. Requirements for adoption: the server publishes port 9000 on 127.0.0.1 (for the API) and is on the shared proxy
network (for Traefik).

## Identity & Access page (`#identity`)

Steps, each with its own state (`lib\IdentityProvider.psm1`, `Get-IdentityModel`):

1. **Identity provider**: authentik, Authelia (listed, *install only* — no sign-in integration in this version) or
   *Configure later*.
2. **Installation**: adopt one found on this PC, or install from the App Catalog (it links back here).
3. **Administrator and recovery**: detects first setup via authentik's `/setup` endpoint (pending = anyone could claim
   it: shown as urgent). The manager never resets the akadmin password or the secret key.
4. **Manager connection**: the installation's bootstrap token (one click) or a pasted API token; stored with DPAPI in
   `secrets\authentik_api.dpapi`; must belong to an administrator.
5. **Public sign-in address**: suggests `auth.<your domain>`, records it, then creates the route through the normal
   service preview (hostname claims, Cloudflare DNS/tunnel route checks, validation, backup). Recommended exposure:
   public (authentik is the login); Cloudflare Access in front is possible but means two logins and Google's callback
   has to pass Access. The embedded outpost's `authentik_host` is then pointed at `https://auth.<domain>/`.
6. **Google sign-in** (below).
7. **Protected applications** (below).
8. **Health**: one row per component (server, worker, PostgreSQL, network, administrator setup, API, route, Cloudflare,
   public address, outpost, Google source, OAuth callback, real Google sign-in, ForwardAuth per application).

States: *Not configured*, *Configured*, *Awaiting your action*, *Reachable*, *Authentication required*, *Verified*,
*Failed*, *Skipped*. **Verified only from evidence**: Google = a user connected to the Google source signed in after it
was configured; an application = authentik's own `authorize_application` event for it; the public address = an HTTP
answer from authentik through Cloudflare. Saved configuration or an HTTP 200 never counts.

Resumable: `config\identity.json` keeps the choice, hostname, the Google client ID and sign-up rules (never the secret),
protected applications and the last step worked on. Every authentik change is computed as a dry run first, applied once
after confirmation, recomputed right before applying (refused if anything changed) and idempotent (re-running creates
nothing twice; leftovers of an interrupted run are updated, not duplicated).

## Google sign-in

**What Google allows to automate:** nothing for this client type. A standard OAuth 2.0 "Web application" client (used
by authentik as a social login) can only be created in the Google Cloud console. `gcloud iam oauth-clients` is for
Workforce Identity Federation, and the IAP OAuth Admin API (brands/identityAwareProxyClients) was deprecated on
2025-01-22 and shut down on 2026-03-19 (Google Cloud IAP docs). The manager therefore does not ask for Google
credentials, uses no Google API and no browser automation: it guides the console steps and automates authentik.

What the wizard shows (values computed from your hostname, copy buttons):

| Value | Example (auth.jrtechconsult.com) |
| --- | --- |
| App name | `authentik - jrtechconsult.com` |
| Application type | Web application |
| Authorized redirect URI | `https://auth.jrtechconsult.com/source/oauth/callback/google/` (authentik's `/source/oauth/callback/<slug>/`, verified against 2026.8.5) |
| Authorized domain | `jrtechconsult.com` |
| Scopes | `openid`, `email`, `profile` (non-sensitive; authentik itself requests `email profile`) |

Your part (about five minutes, Google Auth Platform): create/choose a project
(`console.cloud.google.com/projectcreate`) → Branding (`/auth/branding`: app name, support email, authorized domain; no
logo, a logo triggers brand verification) → Audience (`/auth/audience`: *Internal* only with a Google Workspace
organization; *External* starts in *Testing*, limited to listed test users (max. 100), or *Publish app*) → optionally Data
access (`/auth/scopes`) → Clients (`/auth/clients`: Create client, Web application, add the redirect URI exactly) → copy
the client ID and the secret **immediately** (Google shows the secret only once). No Google API has to be enabled for
sign-in; no JavaScript origins are needed.

Then the manager configures authentik through its API (dry run first):

- OAuth source `google` (type Google, client ID/secret, *promoted* login button, authentication flow
  `default-source-authentication`).
- **Sign-up**: *Only the people I list* (default) creates `dm-google-enrollment` (the default enrollment stages, plus the
  expression policy `dm-google-enrollment-allowlist`: Google's address must be verified and on the email/domain list);
  *Any Google account* (default enrollment flow; new users get no application access); *No new accounts* (only users who
  connected Google in their own settings).
- **Account matching**: `identifier` (default; never links to an existing account by email, so nobody can take over
  akadmin by controlling an email address) or `email_deny`. `email_link` is not offered. Existing users link Google
  explicitly from their authentik user settings while signed in.
- The login page's identification stage shows the Google button.
- Never grants administrator rights; akadmin keeps its password (Google is never the only way in).

The client secret goes from the password field to the local server to authentik in one request; it is not stored by
the manager, not logged, not returned and not shown again. To rotate it: create a new secret in Google, run the wizard
again with it (only the source changes), then delete the old secret in Google.

## Protecting an application

Per application (single-application ForwardAuth, so each one has its own rules):

- proxy provider `dm-<service>` (mode `forward_single`, external host `https://<hostname>`, implicit-consent authorization
  flow), application `dm-<service>`, assigned to the embedded outpost;
- who may open it: email addresses and/or domains (expression policy `dm-<service>-access`, refused while users may change
  their own email in authentik), existing groups, and/or a new group `<service> users` (administrator groups are never
  offered). At least one rule is required: an authentik application without bindings admits every user.
- then the Traefik route (preview with diff, validation in a throwaway Traefik, backup, reload). The route switches only
  after the outpost has loaded the provider, and the result is checked with an unauthenticated request (must redirect to
  sign in; loops are detected).
- Cloudflare Access is kept unless you choose to remove it (or to add it).

Removing protection: Traefik first (the route stops asking authentik), then the authentik application, provider and
policy; groups are kept. The preview says what remains in front of the application.

ForwardAuth vs. native OpenID Connect: ForwardAuth works for any web application without changing it (the app sees
`X-authentik-*` headers and keeps its own login if it has one). Applications with OIDC support (Portainer, Immich, …) can
sign users in natively through an authentik OAuth2 provider; the manager does not configure native OIDC yet.

## Recovery

- akadmin keeps signing in with its password on the local address (`http://127.0.0.1:<port>/`), independent of Google
  and Cloudflare. Lost password: `docker compose exec worker ak create_recovery_key 10 akadmin` in the authentik folder
  and open the printed path on the local address.
- authentik down: protected applications refuse requests (fail closed). Remove protection on Identity & Access, or restore
  the service backup made before protecting (Backups > rollback), to open them without authentik.
- Rollback of routes: every protect/unprotect writes a service backup; restoring it restores the previous routes.
- Configuration backups include `config\identity.json` (choices, no secrets, no "verified" marks) and list the authentik
  token as an excluded credential. authentik's own data (users, sources, the Google secret) is in its database: back it up
  with *Installed apps > Back up* (volume copy).

## Portability

Windows-specific today: DPAPI (`lib\SecretStore.psm1`, one adapter with four functions), ACLs (`Set-SecretFileAcl`),
`curl.exe` in tests. Portable: route generation, the authentik API client and sync logic, the model, the catalog
manifest (plain Linux containers). Debian, Arch and Unraid need a secret-store adapter and testing; not done here.

## Tests

| Test | What it covers |
| --- | --- |
| `tests\Test-Identity.ps1` | No authentik: ForwardAuth YAML (and, with Docker, acceptance by a throwaway Traefik), validation guards, Google values, allow-lists and policy expressions (injection), discovery, every model state, config resume, secret store, catalog manifest. |
| `tests\Test-IdentityLive.ps1` | Disposable instance + authentik installed through the catalog API: bootstrap, readiness, network isolation, adopt, token, sign-in route, outpost, Google source with **synthetic** credentials (redirect check, idempotency, secret never leaks), protect/unprotect, sign-ins through the real outpost (allowed, denied, wrong password, group), access evidence, loop detection, fail closed, interrupted setup, rollback, persistence, bootstrap-only-once, browser (screenshots). Removes everything it created and checks that no other container changed. |
| `node tests\ui-logic.test.js` | Browser-side helpers (state vocabulary, redirect URI, client ID, allow-list parsing, next step). |

## Limitations

- Creating the Google OAuth client is manual (Google provides no API for it).
- Authelia is listed but install-only; its sign-in integration is not implemented.
- Native OpenID Connect for applications is not configured by the manager (ForwardAuth only).
- The manager uses an authentik administrator's API token; a dedicated service account with a narrower RBAC role is
  possible in authentik but not set up automatically yet.
- Domain-level ForwardAuth (one sign-in for a whole domain, `forward_domain`) is not offered; every application gets
  its own provider and rules.
- Services with more than one hostname cannot be protected yet (authentik identifies an application by one address).
- The App Catalog's memory check uses Windows' *free* physical memory; on PCs where WSL already reserves most memory it
  can refuse to start authentik (about 1.5 GB) even when Docker has room. The API accepts an explicit override
  (`force`), the website does not offer it yet; this check is existing App Catalog behaviour, unchanged here.

Not tested here: a real Google sign-in (needs your Google account and consent), real Cloudflare DNS/tunnel changes for
the sign-in hostname, the production installation.
