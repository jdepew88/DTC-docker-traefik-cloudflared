# Identity & Access (authentik, Google sign-in, ForwardAuth)

Optional. The Deployment Manager works without it: basic setup, services and Cloudflare Access are unchanged.
When used, it installs or adopts **authentik**, publishes its sign-in page through the existing Traefik and Cloudflare
Tunnel, connects **Google sign-in**, and puts authentik **ForwardAuth** in front of the applications you choose.

Tested only on Windows 11 with Docker Desktop (WSL 2). The code avoids Windows-only assumptions where it can (see
[Portability](#portability)), but other hosts are not supported yet.

## Division of responsibility

One-time setup in the manager (DTC), then authentik decides:

| The manager (DTC) | authentik |
| --- | --- |
| Install or adopt authentik; connect to its API | Users, passwords, Google sign-in, invitations |
| Publish the sign-in page (`auth.<domain>`, Cloudflare, Traefik) | Group memberships (including `DTC owners`) |
| Guide the Google OAuth client; create the Google source | Sign-in and enrollment flows (including the owner-only enrollment rule after setup) |
| Initial owner, once: owner-only enrollment, `DTC owners` group | Who may open each application (bindings, policies) |
| Per application: provider, application, outpost, ForwardAuth route | |
| Connection health, removing protection | |

The manager keeps no user lists, never asks for emails, groups or domains per application, and never changes authentik's
users, groups, flows, policies or bindings after creating them once. Changes made in authentik take effect immediately:
no manager update and no Traefik change is needed. A future Authelia integration follows the same split.

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
   See [Connection settings](#connection-settings-api-token) below: the token can be replaced at any time.
5. **Initial owner** (asked once): the Google account of the person who owns this authentik, and whether it also becomes
   an authentik administrator. It can be changed until the owner has signed in with Google.
6. **Public sign-in address**: suggests `auth.<your domain>`, records it, then creates the route through the normal
   service preview (hostname claims, Cloudflare DNS/tunnel route checks, validation, backup). Recommended exposure:
   public (authentik is the login); Cloudflare Access in front is possible but means two logins and Google's callback
   has to pass Access. The embedded outpost's `authentik_host` is then pointed at `https://auth.<domain>/`.
7. **Google sign-in** (below), finished by the owner's first Google sign-in.
8. **Protect applications** (below).
9. **Health**: one row per component (server, worker, PostgreSQL, network, administrator setup, API, route, Cloudflare,
   public address, outpost, Google source, OAuth callback, real Google sign-in, ForwardAuth per application).

States: *Not configured*, *Configured*, *Awaiting your action*, *Reachable*, *Authentication required*, *Verified*,
*Failed*, *Skipped*. **Verified only from evidence**: Google and the owner = the owner's account, connected to the Google
source and holding the owner's address, exists (authentik only creates it after Google verified that address); an application = authentik's own `authorize_application` event for it; the public address = an HTTP
answer from authentik through Cloudflare. Saved configuration or an HTTP 200 never counts.

Resumable: `config\identity.json` keeps the choice, hostname, the Google client ID, the owner's address (never the secret),
protected applications and the last step worked on. Every authentik change is computed as a dry run first, applied once
after confirmation, recomputed right before applying (refused if anything changed) and idempotent (re-running creates
nothing twice; leftovers of an interrupted run are updated, not duplicated).

## Connection settings (API token)

*Identity & Access > authentik: Connection settings* shows the connected authentik server and version, the API account,
the validation status, the last successful validation, when the token was saved and replaced, and its expiry date
(read from authentik; a warning appears 14 days before it runs out). Always available:

- **Test connection**: validates the saved token again, without asking for it.
- **Replace API token**: opens a password field. The new token is checked against this authentik first: it must be
  accepted, belong to an administrator (an `ak-outpost-…` token is refused with an explanation: it belongs to authentik's
  own outpost) and be able to read every API area the manager uses. **Only then** does it replace the saved token. A
  refused token changes nothing: the previous token stays saved and working, and you can try again. When the saved token
  stops working (wrong, expired, revoked, missing permissions, saved by another Windows account), the page explains why
  and opens the field right away (*Try a different token*).
- Installations made by the manager can use *Use the token created at installation* instead of pasting one.

Token lifetime: authentik 2026.8 gives every API token created with **Expiring** on its *default token duration*
(System > Settings, 1 day unless changed) and ignores a requested date. For the manager's token, turn **Expiring** off;
otherwise the page warns before it runs out and you replace it here.

Replacing the token changes nothing in authentik (no container, database, account, outpost token or object is touched)
and keeps all Identity & Access settings and progress; the page continues at the next step that needs attention.
Status (no token value) is kept in `config\credentials.json`; the token itself only in `secrets\authentik_api.dpapi`.
Expired and revoked tokens look the same to authentik's API ("rejected"); a token refused after its recorded expiry date
is reported as expired.

The pattern is reusable: `lib\CredentialManager.psm1` (validate-then-replace, status records, throttled re-checks) and
`webui\credentials.js` (the card) take a validator and two endpoints; Authelia, Cloudflare and other API integrations can
use the same pieces.

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
- **Owner-only sign-up**: enrollment flow `dm-google-enrollment` (the default enrollment stages) with the expression policy
  `dm-google-initial-owner`: only the owner's address, and only when Google reports it verified, may create an account.
  After setup this policy is authentik's: edit it there, or use invitations, to let other people in.
- **Owner group**: `DTC owners`, created with akadmin (the local recovery account) as first member. When the owner has
  signed in with Google (*Check owner sign-in*), their account joins it and, if chosen, `authentik Admins`. The manager
  only ever adds these memberships during that one step.
- **Account matching**: `identifier` (never links an existing account by email, so nobody can take over akadmin by
  controlling an email address). Existing users link Google from their authentik user settings while signed in.
- The login page shows the Google button. akadmin keeps its password (Google is never the only way in).
- Re-running the wizard creates nothing twice and changes only the client ID/secret; the flow, policy and group are left
  as authentik has them.

The client secret goes from the password field to the local server to authentik in one request; it is not stored by
the manager, not logged, not returned and not shown again. To rotate it: create a new secret in Google, run the wizard
again with it (only the source changes), then delete the old secret in Google.

## Protecting applications

*Protect applications* lists the services with a checkbox each (compatible: enabled, one hostname, not the sign-in page
itself) and one action, **Protect selected with authentik**. Nothing about people is asked. For each selected application
(preview first, then one after the other, each with its own Traefik backup):

- proxy provider `dm-<service>` (mode `forward_single`, external host `https://<hostname>`) and application
  `dm-<service>`: created, or reused when they exist (only the provider's mode/address and the link are corrected);
- access: when the application has **no** binding in authentik yet, the group `DTC owners` is bound (owner-only, never
  "every signed-in user"); an application that already has bindings keeps exactly those;
- assignment to the embedded outpost;
- the Traefik route with ForwardAuth (diff, validation in a throwaway Traefik, backup, reload). The route switches only
  after the outpost has loaded the provider, and the application counts as protected only after an unauthenticated
  request was sent to sign in (loops are detected);
- Cloudflare Access stays as it is unless you choose *Remove Cloudflare Access* for the selection.

Each protected application shows its status, how many access rules authentik has (read only) and **Open in authentik**.

Removing protection: Traefik first (the route stops asking authentik), then the outpost stops serving the provider. The
authentik application, its provider and its access rules stay in authentik; protecting again reuses them. The preview
says what remains in front of the application.

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
- Configuration backups include `config\identity.json` (choices and the owner's address; no secrets, no "verified" marks, no access rules) and list the authentik
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
| `node tests\ui-logic.test.js` | Browser-side helpers (state vocabulary, redirect URI, client ID, credential status, next step). |

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
