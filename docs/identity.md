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

## Identity & Access wizard (`#identity`)

A linear wizard: a numbered step list on the left (steps that cannot be opened yet say which step comes first), one
step at a time on the right with *why* the step exists, whether it succeeded, the instructions, and **Back** /
**Continue** (Continue is available once the step is done, or as *Skip for now* for optional steps). A step is complete
only from what the manager observed, never from a click. The position is kept in the address (`#identity/<step>`) and
in `config\identity.json`, so a refresh, a restart or coming back from Google Cloud resumes at the same step; re-entering
detects existing infrastructure and creates nothing twice. Which step is open (the framed one) and which steps are
complete (green check) or skipped (dash) are separate: opening a completed step never makes it look unfinished.

Every load of the page verifies protection (`GET /api/identity?probe=apps`): one anonymous request per protected
application through Traefik, plus whether its route file attaches the authentik ForwardAuth middleware and Traefik has
loaded it. Applications protected before the wizard was opened count the same way. A stored flag alone never completes
step 8: an application whose check fails (or whose route lost the middleware) keeps steps 8 and 9 open and is named.
*Skip for now* on step 8, while nothing is protected, records the skip (`protectSkippedAt` in `config\identity.json`);
step 8 then shows *skipped*, not a green check, and protecting an application later clears it.

| # | Step | Complete when |
| --- | --- | --- |
| 1 | **Choose how people sign in**: A. local accounts (username and password) or B. Google sign-in. Authelia is listed as install-only; *Configure later* keeps Cloudflare Access only. | A path is chosen |
| 2 | **Install or connect authentik**: adopt an installation found on this PC or install one from the App Catalog; administrator and recovery status. | authentik runs, its database is ready, the administrator exists |
| 3 | **Connect the manager to authentik**: the [connection settings](#connection-settings-api-token) card. | The saved token works for an administrator |
| 4 | **Public sign-in address**: `auth.<domain>` suggested, route through the normal preview, embedded outpost pointed at it. | Route loaded and outpost uses the public URL |
| 5 | **Register with Google** (path B): owner's Google account, values to copy, the four Google Cloud steps, client JSON import, preview and *Turn on Google sign-in*. | The Google source exists |
| 6 | **Sign-in page** (path B, optional): Google-first sign-in page. | Applied (or skipped) |
| 7 | **Verify the owner**: real sign-in, checked item by item. | Verified by the manager |
| 8 | **Protect applications** (optional): checkboxes, one action; afterwards the place to protect more or remove protection. The step list shows the count (e.g. *8/8 protected*). | Every protected application verified just now (or deliberately skipped while none is protected) |
| 9 | **Finished**: protection summary, *Manage protection*, links to manage everything in authentik. | Every required step complete and step 8 complete or skipped, with no failing protection |

Starting with A and adding Google later only adds steps 5-6 and a Google sign-in for the owner: local accounts, the
`DTC owners` group, application rules and existing sessions are not touched. akadmin always keeps its password.

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

What the wizard shows (values computed from your hostname, copy buttons, a **?** beside each unfamiliar setting):

| Value | Example (auth.example.com) |
| --- | --- |
| App name (used for both the Google app and the client; ASCII only) | `example.com Sign-in` |
| Application type | Web application |
| Authorized redirect URI | `https://auth.example.com/source/oauth/callback/google/` (authentik's `/source/oauth/callback/<slug>/`, verified against 2026.8.5) |
| Authorized domain | `example.com` |
| Scopes | `openid`, `email`, `profile` (non-sensitive; authentik itself requests `email profile`) |

Your part (about five minutes, Google Auth Platform, direct links in the wizard):

1. **Branding** (`/auth/branding`): app name, user support email, developer contact email, authorized domain. Logo, home
   page, privacy policy and terms are **optional**: leave them empty (a logo starts Google's brand verification). No
   homepage has to be created for this.
2. **Audience** (`/auth/audience`): **External** for ordinary Gmail accounts. *Internal* is only for Google Workspace
   organizations (sign-in limited to that organization). External starts in **Testing**: add the owner as a test user
   (up to 100 test users), or press *Publish app*. Publishing only lets any Google account reach Google's sign-in screen;
   it never lets anyone into your applications: authentik's enrollment rule and application rules still decide.
3. **Client** (`/auth/clients`): Create client, *Web application*, the app name, and the redirect URI exactly.
4. **Download JSON** in the dialog that follows (Google shows the secret only then; otherwise *Add secret* and download again).

Then import the file (preferred) or type the client ID and secret. The file is read on this PC and checked before anything
changes: a `web` client (a Desktop/`installed` client is refused), client ID and secret present, the expected redirect URI
(a missing trailing slash or another host is explained with the exact URI to add in Google Cloud), Google's `auth_uri` and
`token_uri`. The secret goes to authentik once; it is not stored by the manager, not logged and never returned. An existing
Google connection is only changed with an explicit **Replace the Google client**.

Then the manager configures authentik through its API (dry run first):

- OAuth source `google` (type Google, client ID/secret, *promoted* login button, authentication flow
  `default-source-authentication`).
- **Owner-only sign-up**: enrollment flow `dm-google-enrollment` (the default prompt and login stages, and its own write
  stage `dm-google-owner-write` that creates **Internal** users) with the expression policy
  `dm-google-initial-owner`: only the owner's address, and only when Google reports it verified, may create an account.
  After setup this policy is authentik's: edit it there, or use invitations, to let other people in.
- **Owner group**: `DTC owners`, created with akadmin (the local recovery account) as first member. When the owner has
  signed in with Google (*Check owner sign-in*), their account joins it and, if chosen, `authentik Admins`. The manager
  only ever adds these memberships during that one step.
- **Why Internal**: authentik's default source enrollment stage creates *External* users, and authentik's own dashboard
  refuses them ("Interface can only be accessed by internal users"). This is unrelated to Google's *External* audience.
  A flow created by an earlier version is repaired during setup (shown in the preview); an owner account created External
  is only changed to Internal with the explicit *Repair* in the verification step.
- **Account matching**: `identifier` (never links an existing account by email, so nobody can take over akadmin by
  controlling an email address). Existing users link Google from their authentik user settings while signed in.
- The login page shows the Google button. akadmin keeps its password (Google is never the only way in).
- Re-running the wizard creates nothing twice and changes only the client ID/secret; the flow, policy and group are left
  as authentik has them.

The client secret goes from the password field to the local server to authentik in one request; it is not stored by
the manager, not logged, not returned and not shown again. To rotate it: create a new secret in Google, run the wizard
again with it (only the source changes), then delete the old secret in Google.

## Sign-in page (Google first)

*Use this sign-in page* creates the authentication flow `dm-authentication`, a copy of authentik's default flow whose
identification stage `dm-identification` shows **Google** first (promoted, with its label) and email or username with
password below it; the default brand uses it and gets the title *Sign in to <domain>*. Clicking Google goes straight to
Google's own account chooser: nobody types an email into authentik first. The default flow is not changed and stays the
local recovery route (`/if/flow/default-authentication-flow/` on the local address). *Restore the previous sign-in page*
puts the brand's previous flow and title back. authentik's Google source type does not allow extra authorization
parameters, so the manager cannot force Google's account chooser when only one Google account is signed in (Google then
continues with that account).

**Customized sign-in pages are kept.** If the brand's sign-in flow was changed in authentik to a flow of your own (any
flow other than `default-authentication-flow` and `dm-authentication`), *Use this sign-in page* leaves it in place and
says so; only the title is set. A DTC upgrade therefore never replaces a sign-in page you built yourself in authentik
(your own flow, stages, brand CSS or a template override in the authentik project's `custom-templates`). DTC does not
ship or manage such customizations; keep them, and the tools you use for them, with your authentik deployment.

### Troubleshooting: the page spins after Google

If sign-in hangs on a spinner after choosing the Google account (about 30 s, then back to the sign-in page), authentik
most likely cannot reach Google's token endpoint. authentik's server log shows `Unable to fetch access token ...
oauth2.googleapis.com ... Network is unreachable` (or a timeout) and `Authentication Failure`; the worker log shows the
same for `version.goauthentik.io`. This is independent of the sign-in page. A hung Docker Desktop engine (`docker ps`
does not answer, containers have no outbound network) is one known cause; restarting Docker Desktop fixes it.
`Test-AuthentikGoogleCallback` (`lib\Authentik.psm1`) and `tests\Test-AuthentikSignInHealth.ps1` check exactly this
return leg: a real OAuth state and a deliberately invalid code that authentik must have rejected by Google within 10 s.
## Owner verification

Path B: *Continue with Google* opens authentik's Google sign-in directly (`/source/oauth/login/google/`); after signing
in, *I've signed in - check again* checks, item by item: the Google identity (the owner's verified address; the Google
subject seen first is pinned, a different Google identity with the same address is refused), the account is **Internal**,
it is in `DTC owners`, an administrator if chosen, and the sign-in completed. Path A: *Start the sign-in check*, sign in
with akadmin's password, check again (only a sign-in after the check started counts). Nothing can be marked verified by
hand, and these memberships are only added during this explicit step.

## Protecting applications

*Protect applications* lists the services with a checkbox each (compatible: enabled, one hostname, not the sign-in page
itself), **Select all**, **Clear all** and the selected count, and one action, **Protect selected with authentik**.
Ticking never re-renders the page, so it does not jump. Already protected applications are labelled and cannot be ticked:
leaving something unticked never removes protection. The result lists, per application, backend reachability, the route
loaded by Traefik and ForwardAuth enforcement separately (sign-in verification follows from real use). Nothing about people is asked. For each selected application
(preview first, then one after the other, each with its own Traefik backup):

- proxy provider `dm-<service>` (mode `forward_single`, external host `https://<hostname>`) and application
  `dm-<service>`: created, or reused when they exist (only the provider's mode/address and the link are corrected);
- access: when the application has **no** binding in authentik yet, the group `DTC owners` is bound (owner-only, never
  "every signed-in user"); an application that already has bindings keeps exactly those;
- assignment to the embedded outpost;
- the Traefik route with ForwardAuth (diff, validation in a throwaway Traefik, backup, reload). The route switches only
  after the outpost has loaded the provider, and the application counts as protected only after an unauthenticated
  request was sent to sign in (loops are detected);
- Cloudflare Access: by default authentik becomes the only interactive sign-in and an Access application this manager
  created for the hostname is deleted (listed in the preview). Keeping Cloudflare Access in front as well is an explicit
  choice, *Layered*, stored as `auth.layered` on the service (two sign-ins).

### Application launcher (same step)

Every application (protected or not) is one row with:

- its name, the hostname as a link and **Open**: both go straight to the application's configured address
  (`https://<hostname>/` when published, `http://<hostname>:<Traefik port>/` when local only) in a new tab. DTC does not
  start a sign-in: Traefik and authentik decide whether one is needed, so an existing authentik session is reused;
- **Authentik**: the application's page in authentik's admin interface at the **public** authentik address
  (`<publicUrl>/if/admin/#/core/applications/dm-<service>`). Only when authentik has no public address yet does it fall
  back to the local address, with a warning: Google sign-in cannot work there (see below);
- container status (running, stopped, missing, Windows/LAN service), route and publication status, the authentication
  mode, any Cloudflare Access application that covers the hostname (exact, path-scoped, wildcard or multi-domain, read
  from the Cloudflare API at most every two minutes), and one diagnosis from `lib\AccessDiagnostics.psm1`: healthy,
  local only, stopped, missing container, backend unreachable, missing route, missing protection, provider error
  (application missing, wrong external address or mode), outpost error, ForwardAuth not enforced or misrouted,
  redundant Cloudflare login, foreign Access conflict, Access missing, OAuth configuration. Availability problems are
  never reported as authentication failures: a stopped container is "Stopped (after signing in, Bad gateway)";
- **Trace** (read-only): one anonymous request without cookies to the public address and one through this PC's Traefik,
  listing each hop (no query strings, codes or tokens) and which component asked for authentication first (Cloudflare
  Access, Cloudflare challenge, authentik, Google, a local address, tunnel, Traefik or the application);
- **Remove Cloudflare login…** when a Cloudflare Access application *created by DTC* still sits in front of an
  authentik-protected application. Preview and apply both check first that the route asks authentik and that an
  anonymous request is sent to sign in right now (fails closed), that authentik has an application with at least one
  access rule for it, and that the recorded Access application still covers exactly that hostname (never a wildcard,
  path or multi-domain one). Before deleting, a copy of the Access application and its policies is written to
  `backups\cloudflare-access\<time>-<hostname>.json`; if that copy cannot be saved nothing is deleted. Only that Access application is deleted; the route,
  DNS record, tunnel route and Access applications DTC did not create stay. Undo: edit the service, choose
  *Internet, layered: Cloudflare Access + authentik*.

Each protected application also shows how many access rules authentik has (read only).

**Remove protection…** (one application at a time) previews exactly what changes: the route drops the ForwardAuth
middleware and the provider is unassigned from the embedded outpost. It also lists what stays: the container, the route
and hostname, the authentik application with its provider, users, groups and access rules (protecting again reuses
them), and Cloudflare Access (kept; change it on the Services page). When the application would be published without
any sign-in, the preview says so and Remove needs an explicit *I understand that this application becomes publicly
accessible*.

Removing protection: Traefik first (the route stops asking authentik), then the outpost stops serving the provider. The
authentik application, its provider and its access rules stay in authentik; protecting again reuses them. The preview
says what remains in front of the application.

ForwardAuth vs. native OpenID Connect: ForwardAuth works for any web application without changing it (the app sees
`X-authentik-*` headers and keeps its own login if it has one). Applications with OIDC support (Portainer, Immich, …) can
sign users in natively through an authentik OAuth2 provider; the manager does not configure native OIDC yet.

## Authentication & Routing page (`#routing/<service>`)

Opened with **View Authentication Flow** on Identity & Access (no sidebar entry; **Back to Identity & Access** returns).
Choose an application; the page draws its real request path from `GET /api/routing?service=<name>`
(`lib\RoutingModel.psm1` builds the model from facts gathered by `webui.ps1`). Nobody has to open it to publish or protect
an application.

- **Browser journey**: the ten steps of a visit (open the address, Cloudflare and the tunnel, the Traefik router,
  ForwardAuth, the redirect to the sign-in page, choosing Google, authentik's policies, the return to
  `https://<app>/outpost.goauthentik.io/callback`, the second check, the application's answer). Each step says whether it is
  the browser's request or a server-to-server request; the browser never talks to the internal outpost address.
- **Internal routing**: the stages in request order with their real values: public hostname, DNS, Cloudflare Access,
  tunnel origin, router rule, middleware order, ForwardAuth address (internal), authentik application, provider and outpost,
  where the outpost sends browsers, the public sign-in page, the return address, the backend URL and the Docker networks.
  Browser endpoints (public HTTPS) and internal endpoints (Docker names) are labelled as such.
- **States**: *Verified* only from a real request; *Configured, not tested* when only configuration was read; *Warning*;
  *Failed*; *Not applicable*. A failed stage opens with the tested endpoint, the expected and the actual result, why, and
  what to do. Each stage has a **?** explaining what it does, why it is needed, what the manager sets up, what you may
  manage yourself, and common failures. Choosing Google and authentik's access decision are never shown as verified
  without evidence of a real sign-in.
- **Run checks** is read-only: one anonymous GET through Traefik (no cookies; it never follows a sign-in and never tries
  to get past Google or authentik), the backend request from Traefik's container (as on the Services page), GETs to the
  public application and sign-in addresses through Cloudflare, and GET requests to the Cloudflare and authentik APIs.
  Redirect addresses are shown with `state`, `client_id` and codes redacted; tokens and cookies are never returned.
- **Guided mode** only for now. The stage model and its checks are separate from the page so that a later manual mode can
  inspect and edit the same stages (backend, networks, routers, middleware order, Cloudflare routes, authentik settings).

### Public and internal sign-in addresses

Two different addresses are involved, and mixing them up breaks sign-in for everyone except the authentik PC:

| Used by | Address | Set in |
| --- | --- | --- |
| Traefik asking authentik (server to server) | `http://<authentik container>:9000/outpost.goauthentik.io/auth/traefik` | the ForwardAuth middleware (generated) |
| Browsers sent to sign in | `https://auth.<domain>/` | the embedded outpost's `authentik_host` (or `authentik_host_browser`) |

If the outpost's `authentik_host` is `http://127.0.0.1:9000` (or a LAN IP, or a Docker name), ForwardAuth still works, but
every sign-in redirect points there: it works only on the PC running authentik. The manager now:

- refuses a loopback, LAN, raw-IP or Docker-only address as the public sign-in address;
- includes "Embedded outpost: send browsers to https://auth.<domain>/" in the preview whenever protecting an application
  finds the outpost elsewhere (and refuses to protect while no public sign-in address is set and the outpost would send
  browsers to a local address);
- reports such a redirect as **misrouted** (not "sign-in required") in every check, and a current failed check outranks
  older sign-in evidence.

The application's own address (the proxy provider's external host, the return address after signing in, and the Host
every check sends through Traefik) uses the scheme and port of the public sign-in address: `https://<host>` in
production. authentik's outpost matches the forwarded Host, port included, against the provider's address and answers
404 for anything else, so the two must agree. After protecting, the manager waits up to a minute for the outpost to
reload a corrected sign-in address before reporting the result.

### Cloudflare Access left in front

Turning **Require Cloudflare Access** off (on the Services page, or *Remove Cloudflare Access* when protecting) now deletes
the Access application this manager created for that hostname, listed in the preview. An Access application left over
from an earlier change that turned Access off (the registry already says off, but the application was never deleted) is
reported everywhere and removed when a change explicitly asks for cleanup: *Remove Cloudflare login…* on Identity &
Access, or saving the service on the Services page (cleanup is part of that preview). Only Access applications this
manager recorded creating are ever deleted; ones created by hand, including wildcard (`*.example.com`) and multi-domain
applications, are detected and reported ("visitors sign in twice"), never changed.

## Authentication architecture and modes

```
Browser -> Cloudflare (DNS, HTTPS, tunnel) -> Traefik -> authentik ForwardAuth -> application
```

- **Google** is only an upstream identity source of authentik (one OAuth client, one redirect URI:
  `<authentik public URL>/source/oauth/callback/<source slug>/`). Adding an application never touches Google.
- **authentik** holds the session (a cookie on its own hostname), decides who may open what (per-application bindings),
  and sends unauthenticated visitors through its flow (Google when configured).
- **Traefik** enforces authentik's decision with a ForwardAuth middleware per route and fails closed: authentik
  unreachable means the request is refused.
- **Cloudflare** provides DNS, HTTPS and the tunnel. It adds no interactive login in front of an authentik application
  unless layered authentication was chosen.

Modes (one per service; `Get-ServiceAuthMode`): `authentik` (normal, reusable), `cloudflare-access` (Access only, for
apps without authentik), `layered` (both, explicit `auth.layered`), `native` (the application's own login), `none`
(published without any sign-in: warned). Validation refuses authentik + Cloudflare Access unless `layered` is set, and a
service request that names authentik gets Access off by default.

### Per-application ForwardAuth (`forward_single`) versus domain-level (`forward_domain`)

| | Per application (used) | Domain level |
| --- | --- | --- |
| Session reuse | Yes: the authentik session (on the sign-in hostname) is reused; each application adds one invisible redirect to set its own cookie | Yes: one cookie on the parent domain, no extra redirect |
| Authorization | Per application: own provider, application and bindings (owner-only by default) | One application for the whole domain: per-application rules need extra policies keyed on the host |
| Cookie scope | Host-only cookie per application | Cookie for `.example.com`, sent to every subdomain, including applications not behind authentik |
| Outpost | One provider per application on the embedded outpost | One provider; every route uses it |
| Risk | A mistake affects one application | A leaked domain cookie or a mis-scoped rule affects every subdomain |

The manager keeps per-application providers: session reuse already works, and application-specific access control is
not sacrificed. Domain level would remove one redirect per first visit only.

### Why Google can report `redirect_uri_mismatch`

authentik builds the Google callback from the address the browser used. Opening authentik at its local address
(`http://127.0.0.1:9000`) — earlier versions linked **Open in authentik** there — starts a fresh sign-in with
`redirect_uri=http://127.0.0.1:9000/source/oauth/callback/google/`, which is not registered with Google. Links now use the
public address. Never register local or per-application redirect URIs with Google.

### Integration contract for other front ends (e.g. a Claude skill)

Install through the provisioning engine (`/api/provision/import` → `plan` with `auth: "authentik"` → `apply`) or protect an
existing service with `/api/identity/protect/plan|apply`. Do not create Cloudflare Access applications, Google clients,
authentik providers or Traefik middlewares directly: the engine creates the provider, binds `DTC owners`, assigns the
embedded outpost, writes the route with ForwardAuth, verifies it fails closed and leaves Access off. `GET /api/identity`
returns `launcher[]` (open URL, authentik admin URL, diagnosis) and `POST /api/identity/trace` explains any sign-in
problem.

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

## Identity contract (universal provisioning)

The New app page (universal provisioning engine) protects new applications through seven contract functions in
webui.ps1 that wrap this subsystem; it never talks to authentik itself and never creates a second authentication
system. Readiness, protectability, providers and the rollback rules are pure functions in `lib\IdentityContract.psm1`.
Details, and what the provisioner may and may never change: [provisioning.md](provisioning.md#identity-contract-authentik)
and the checkpoint [provisioning-identity-compatibility.md](provisioning-identity-compatibility.md).

## Tests

| Test | What it covers |
| --- | --- |
| `tests\Test-Identity.ps1` | No authentik: ForwardAuth YAML (and, with Docker, acceptance by a throwaway Traefik), validation guards, Google values, allow-lists and policy expressions (injection), discovery, every model state, config resume, secret store, catalog manifest. |
| `tests\Test-IdentityLive.ps1` | Disposable instance + authentik installed through the catalog API: bootstrap, readiness, network isolation, adopt, token, sign-in route, outpost, Google source with **synthetic** credentials (redirect check, idempotency, secret never leaks), protect/unprotect, sign-ins through the real outpost (allowed, denied, wrong password, group), access evidence, loop detection, fail closed, interrupted setup, rollback, persistence, bootstrap-only-once, browser (screenshots). Removes everything it created and checks that no other container changed. |
| `tests\Test-AuthRouting.ps1` | No Docker: browser versus internal addresses, sign-in redirects leaking 127.0.0.1, LAN or Docker-only addresses, the return address after signing in, redaction, the routing model's states for healthy and broken paths (missing or unhealthy authentication endpoint, broken router, missing network, tunnel to localhost, leftover Access), the ForwardAuth probe against a stub outpost, the public sign-in address guard, Access cleanup on turn-off (Cloudflare API mock). |
| `tests\Test-RoutingBrowser.ps1` | No Docker: the Authentication & Routing page in headless Edge with models from the real model code: link and way back, application selection, both views, failed-stage details, help, Run checks, redaction, 1366 px and 390 px. |
| `tests\Test-IdentityProtectBrowser.ps1` | No Docker: step 8 and 9 completion (8/8, green checks kept when revisiting), a failing check, a deliberate skip, protecting more applications and removing protection safely; the launcher (hostname and Open links, Authentik at the public address, stopped/missing containers, redundant Cloudflare login, Trace, Remove Cloudflare login preview and apply, authentik-only default, 390 px). |
| `tests\Test-AccessDiagnostics.ps1` | No Docker: Access coverage (exact, path, wildcard, multi-domain, destinations), modes, every diagnosis state, redirect-hop classification, redaction, browser addresses, the layered validation rule. |
| `tests\Test-IdentityWizardBrowser.ps1` | No Docker, small footprint: the wizard in headless Edge with the authentik side of `/api/identity` answered in the page. Select all / Clear all / count, ticking without the page moving, already protected applications never selectable, exactly the ticked applications sent, review before apply, per-application result, 390 px. Real protection is covered by the live test. |
| `tests\Test-Provisioning.ps1` | The identity contract: readiness, providers, ForwardAuth suitability, auth choices per access, rollback rules, and the real `Sync-AuthentikAppProtection` / `Remove-AuthentikAppProtection` against an in-memory authentik (preview changes nothing, create, reuse without duplicates, rollback deletes only what the operation created, a reused application is only unassigned). |
| `tests\Test-AuthentikSignInHealth.ps1 -InstallPath <deployment> -ProtectedUrl <app address>` | Live, against your own authentik, bounded waits, Google **not** blocked: the Google callback answers (return leg), the sign-in stage renders without a lingering spinner (desktop and phone), the protected address leads to the brand's sign-in flow with path and query carried, the Google button lands on Google's real sign-in page with `redirect_uri`/`state` and no forced prompt, local admin reaches the password step, the recovery flow loads. Works with any sign-in flow, including one customized in authentik. A real Google sign-in still needs a person. |
| `node tests\ui-logic.test.js` | Browser-side helpers (state vocabulary, redirect URI, client ID, credential status, next step). |

## Limitations

- Creating the Google OAuth client is manual (Google provides no API for it).
- Authelia is listed but install-only; its sign-in integration is not implemented.
- Native OpenID Connect for applications is not configured by the manager (ForwardAuth only).
- The manager uses an authentik administrator's API token; a dedicated service account with a narrower RBAC role is
  possible in authentik but not set up automatically yet.
- Domain-level ForwardAuth (`forward_domain`) is deliberately not offered (see the comparison above); every application
  gets its own provider and rules, and the authentik session is reused across them.
- Reading Cloudflare Access applications needs the token's optional *Access: Apps and Policies* permission. WAF,
  Turnstile, zone security settings and Zero Trust identity providers are not read (the token has no permission for them).
- `native` (the application's own login) is a mode in the diagnostics; the Services form does not set it yet.
- Services with more than one hostname cannot be protected yet (authentik identifies an application by one address).
- The App Catalog's memory check uses Windows' *free* physical memory; on PCs where WSL already reserves most memory it
  can refuse to start authentik (about 1.5 GB) even when Docker has room. The API accepts an explicit override
  (`force`), the website does not offer it yet; this check is existing App Catalog behaviour, unchanged here.

Not tested here: a real Google sign-in (needs your Google account and consent), real Cloudflare DNS/tunnel changes for
the sign-in hostname, the production installation.
