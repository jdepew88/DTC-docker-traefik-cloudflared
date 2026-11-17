# Traefik + Cloudflare Tunnel reverse proxy for Windows (Docker Desktop)

A general-purpose reverse proxy for Windows 11 and Docker Desktop. Route any number of applications through
one Traefik v3 instance and, optionally, publish them through a Cloudflare Tunnel:

- **Docker containers** on this PC (by container name, over a shared Docker network)
- **Apps running directly on Windows** (via `host.docker.internal`)
- **Other devices on your LAN** (a NAS, a media server, a router UI, ... by IP address or DNS name)

No port forwarding, no host port 80/443, no ACME/DNS-01: public HTTPS terminates at Cloudflare and the only
inbound path is the outbound-initiated tunnel. A read-only Docker socket proxy, request hardening, security
headers, previews, validation, backups and rollback are built in.

```
Internet --HTTPS--> Cloudflare edge (+ Access) ==tunnel==> cloudflared
                                                              | http://traefik:80   (network: <stack>_tunnel)
127.0.0.1:8180 ------------------------------------------> traefik :80  (web)
127.0.0.1:8181 ------------------------------------------> traefik :8080 (dashboard + /ping, loopback only)
                                                              |
              +-----------------------------+-----------------+--------------------+
              | docker target               | host target                          | lan target
       network: proxy (shared)       host.docker.internal:<port>           10.10.0.11:32800
       http://<container>:<port>     (app on this Windows PC)              (another device)

traefik --socket-internal (internal)--> socket-proxy --> docker.sock (read-only, GET only)
```

## Getting started (no terminal needed)

**Download → Extract → Double-click `START-HERE.cmd` → Follow the website.**

1. Install **Docker Desktop** for Windows (WSL 2 backend, Linux containers) and start it. This is the main
   prerequisite; the website opens without it and explains what is missing.
2. Download this project as a ZIP (or a release) and extract it to any folder, for example your Desktop.
3. Double-click **`START-HERE.cmd`**. It checks Windows PowerShell and the program files, starts the local website
   (127.0.0.1 only) and opens it in your browser. Keep its window open while you use the website; close it (or use
   *Settings > Stop the manager*, or `STOP-MANAGER.cmd`) to stop. Your deployments keep running either way.
4. In the website choose:
   - **Continue where you left off**: the manager lists deployments it finds (recently opened folders, the folders
     in `%USERPROFILE%\.docker\projects`, and the folders of running Traefik + socket-proxy stacks) and lets you pick
     another folder. *Review and open* shows what was found and opens it without changing anything.
   - **Start a new deployment**: the guided seven-step installation.

Double-clicking `START-HERE.cmd` again while the manager runs offers to open it again instead of starting a second
copy. If port 8190 is taken, the next free port is used. No administrator rights are needed.

### One click, no window: the DTC launcher (optional)

Double-click **`Setup-Launcher.cmd`** once. It creates a **DTC Deployment Manager** shortcut on the desktop and in the
Start menu, plus **DTC - Choose deployment** and **DTC - Recovery mode**. The shortcut starts the manager in the
background with a **system-tray icon**: no PowerShell window, and it opens your **default deployment** without asking.
The tray menu offers Open Dashboard, Choose Deployment, Restart Manager and Exit.

Run `Setup-Launcher.cmd -Autostart` (or use the tray menu or the Deployments page) to turn on **Start with Windows**.
DTC then starts silently when you sign in: it waits for Docker Desktop and opens no browser. Once you have opened the
dashboard from the tray, a bookmark to `http://127.0.0.1:8190/` keeps working. See [docs/launcher.md](docs/launcher.md).

### Reopening an existing deployment (for example `traefik-ext1`)

Start the manager with `START-HERE.cmd`; under *Continue where you left off* select the deployment (or *Open another
folder…* and choose its folder, such as `C:\Users\<you>\.docker\projects\traefik-proxy`), then **Review and open**.
The review reads the folder, Docker and, with the deployment's own stored token, Cloudflare (read-only) and shows
what was **detected**, **verified**, **missing**, what **needs reconnection** (for example a token saved by another
Windows account) and whether an **upgrade is available**. **Open existing deployment** makes it the active one; the
Overview then shows its containers, tunnel, domain, dashboard and services.

### Attach, Upgrade and Restore

| Operation | What it does | Changes |
| --- | --- | --- |
| **Attach** (*Open existing deployment*) | Manages a deployment as it is. | Nothing: no file, container or Cloudflare resource is created, changed or restarted. |
| **Upgrade** (*Preview upgrade*) | Updates the deployment's application files to this manager's version (`install.ps1` without `-Start`). Optional: an older deployment can be opened and managed without it. | Application files only, after a dry-run preview, your confirmation and a recovery point. `.env`, `config\`, `secrets\`, routes, backups and logs are kept; edited files are kept with the new version as `.dist`. No container is restarted. |
| **Restore** (*Backups* page) | Recovers configuration from a backup file. | Configuration files (and, with a separate approval, missing Cloudflare resources). Not needed to open an existing deployment. |

### Several deployments

Each deployment lives in its own folder with its own settings and credentials; the manager switches between them
(*Switch deployment*) without mixing them. The list of recent deployments is kept outside every deployment in
`%LOCALAPPDATA%\TraefikProxy\webui.json` (paths and names only); *Remove from list* forgets a folder without touching
its files or containers. The earlier single-app layout (fixed container names) is listed for information only and is
never changed.

## Project status

| Area | Status |
| --- | --- |
| Generic service registry (`config\services.json` -> `traefik\dynamic\svc-<name>.yml`) | **Implemented and tested** (63 offline/deep checks, live walkthrough). |
| Docker, Windows-host and LAN targets; http / https (optionally self-signed) / h2c; path prefixes | **Implemented and live-tested** in an isolated instance. |
| Preview, shallow validation, Traefik validation in a throwaway container, backup, rollback | **Implemented and tested.** |
| Instance isolation via `.env` (stack name, ports, network, tunnel subnet) | **Implemented and tested** (a second instance ran next to an existing production stack without touching it). |
| Installer (`-DryRun`, `-Start`, `-Reload`, `-Rollback`, `-Stop`) | **Implemented and exercised** against an isolated instance. |
| Interactive wizard (`-Wizard`, `-AddApp`) | **Implemented**; uses the shared service backend. The Cloudflare steps have **not** been run end to end against a real tunnel from this repository. |
| Cloudflare Tunnel connector (`cloudflared`) | Compose service and token handling implemented; **not live-validated** in this repository. |
| Browser-based setup and management UI (`webui.ps1`) | **Implemented and tested** against a Cloudflare API mock and a live isolated instance. Not yet run against the real Cloudflare API. |
| Cloudflare-first onboarding (token template link, permission discovery, domain allowlist, local-only path) | **Implemented and mock-tested**, including a confirmed local-only install of a disposable instance. The template link has not been opened against a real Cloudflare account. |
| Cloudflare API automation (tunnel create, connector token, DNS, tunnel routes, Access apps) | **Implemented and mock-tested**; DPAPI-encrypted API token. |
| Portable backups (.json / .zip export, import with preview, two-part restore, recovery points) | **Implemented and tested** against the mock (round trip, version compatibility, credential exclusion, idempotency) and live in an isolated instance (local restore). |
| Traefik dashboard bootstrap (public `/dashboard/` behind Cloudflare Access, fail closed) | **Implemented**; routing **live-tested** in an isolated instance, Cloudflare steps mock-tested. Not yet run against a real Access application. |
| Deployment review (prepared / validated / applied / verified / action required, technical output) | **Implemented** for the installation, restores and the dashboard. |
| App Catalog: 36 entries in groups A-E: **A** Traefik Manager, Uptime Kuma, Portainer, Homepage, Arcane, Dozzle, What's Up Docker, Diun (headless), CrowdSec (detection only), Pi-hole, HTTP echo; **B** authentik + PostgreSQL, Authelia, LLDAP, OpenLDAP, Vaultwarden; **C** Plex, Jellyfin, Immich, Dispatcharr, Channels DVR, MediaFusion, RomM; **D** Nextcloud, Paperless-ngx, File Browser (deprecated upstream), Rocket.Chat, Gitea, n8n, Mealie, HFS; **E** Shinobi (listed, manual setup); building blocks PostgreSQL, Redis/Valkey; not offered: Watchtower (Prowlarr, Sonarr and Radarr are not part of the catalog). Each installed app is its own Compose project in its own folder: **modular stacks** (one small Compose file per component; `dtc-stack.json` describes it without secrets), pinned images, private networks for databases, generated secrets and credentials, host compatibility, opt-in extra ports (Git over SSH, DNS, direct Plex access), resource checks, prepare-only, first-start steps, backups, **restore and update rollback**, interrupted-installation recovery, per-app **stack, routing and diagnostics** view, backup-first updates and data-keeping removal. Existing installations on the PC (managed, hand-made Compose projects, plain containers, other builds such as LinuxServer.io Plex) are shown on each card and offered for adoption or inspection instead of a second installation. See [docs/app-catalog.md](docs/app-catalog.md) and the inventory in [docs/catalog-inventory.md](docs/catalog-inventory.md) | **Implemented and tested** (all 32 installable templates validated with `docker compose config` as file sets and routes; lifecycle with fixture apps on a disposable instance; real isolated installations of the apps marked *live-tested* in the inventory; the others are statically validated only). |
| Docker discovery and publishing: Services offers *Discover running containers*, *Install a new application* (App Catalog, next milestone) and *Enter an HTTP backend manually*; containers with networks, ports (likely HTTP / not HTTP / never publish), health and existing routes; port test in a short-lived probe container; wizard (name → port → hostname suggested and checked against every existing definition → reachability: shared network, confirmed attach, or published port → who can reach it → preview); one owner per hostname; per-service request-path health (DNS, Access, tunnel, router, service, backend, HTTP, optional public URL) that marks every check it did not perform | **Implemented and tested** (unit, a disposable instance with throwaway containers, browser); read-only compatibility checks against a real installation. |
| Infrastructure Explorer: the request path (browser → DNS → Cloudflare → Access → tunnel → cloudflared → Traefik router → middleware → service → Docker network → app) with six separate states per component (detected, configured, running, reachable, authenticated, verified), tools shown apart from the path, small diagram and quick actions on the Overview | **Implemented and tested** (model unit tests, a disposable running instance, browser at three widths and four levels). Read-only. |
| One-click launcher (`START-HERE.cmd`) and existing-deployment discovery / attach | **Implemented and tested** (launcher, discovery, attach without changes, recent projects, upgrade preview/apply on test folders, browser); discovery and read-only Cloudflare verification also run against a real installation. |
| DTC tray launcher (`Setup-Launcher.cmd`, `launcher\DTC.exe`): no console window, tray menu, start modes default / choose / recovery, default deployment, Start with Windows (per-user Startup folder, waits for Docker Desktop), remembered browsers for a bookmarked address, logs | **Implemented and tested** in isolated folders (`tests\Test-Launcher.ps1`: real DTC.exe and tray, setup, all modes, port conflict, duplicate start, failures, the Deployments page in headless Edge). **Not done on this PC:** the setup was not run against your real desktop, Start menu and Startup folder, and the container-unchanged checks were skipped while Docker Desktop was stopped. |
| Redesigned web UI: seven-step journey, four detail levels, review states, topology, operational pages, learning catalog | **Implemented and browser-tested** in headless Edge (desktop, tablet and phone widths, keyboard and accessible-name checks), including an installation of a disposable instance through the UI. The tunnel path through the UI has only run against the Cloudflare API mock. |
| Identity & Access (optional): authentik installed from the catalog with a bootstrap administrator and API token, or an existing installation adopted; its sign-in hostname routed through the existing Traefik and tunnel; guided Google sign-in (Google offers no API for OAuth clients) with automatic authentik configuration (Google source, restricted sign-up, login button); an initial owner (owner-only enrollment and access group), then "protect selected applications" with per-application ForwardAuth (embedded outpost); afterwards users and access are managed in authentik only; resumable setup, health states that are only "verified" from real sign-in evidence; Explorer hop. See [docs/identity.md](docs/identity.md) | **Implemented and tested** against a disposable authentik 2026.8.5 (catalog install, API configuration, sign-ins with local test users through the real outpost and Traefik, fail closed, rollback, browser) with **synthetic** Google credentials. A real Google sign-in and the real Cloudflare publication of the sign-in hostname have **not** been run (they need your accounts). |
| New app (universal provisioning): paste a Docker Hub, GitHub, Compose-file, Unraid template (XML) or awesome-selfhosted link; the manager builds a normalized manifest (images pinned by digest, dependencies, generated secrets, open questions instead of guesses), reviews it for security and host compatibility, and deploys it in one approved operation: Compose project (App Catalog installer) -> explicit Traefik route -> authentik protection through the identity contract -> Cloudflare publication through the existing tunnel -> stage-by-stage verification, with a journal and rollback of only what it created. Optional AI completion (your own Anthropic API key; per-request estimate and approval, limits, cache, redaction). Local installation recipes with sanitized export. See [docs/provisioning.md](docs/provisioning.md) | **Implemented and tested on Windows + Docker Desktop** (sources through fixtures and read-only checks against Docker Hub, GitHub, GHCR and an Unraid template; a real disposable two-service deployment with verification and rollback; authentik contract against an in-memory authentik; AI with a mocked provider). **Not run:** a real AI request, a real public Cloudflare publication and authentik protection of a provisioned app (they need your accounts or approval); other host platforms are designed, not tested. |

## Requirements

1. **Windows 10/11** with virtualisation enabled and **WSL 2**.
2. **Docker Desktop** (tested with engine 29.8.2 / Compose v5.5.1) using the **WSL 2 backend** and **Linux
   containers**. Do **not** enable *Expose daemon on tcp://localhost:2375*.
3. **Windows PowerShell 5.1** (built in) or PowerShell 7. `curl.exe` (built into Windows 10+) is used by tests.
4. Two free loopback ports (default `8180`, `8181`).
5. For publishing: a domain on Cloudflare and access to the Zero Trust dashboard (Free plan is fine).

## Verified versions (2026-10-18)

| Component | Image | Notes |
| --- | --- | --- |
| Traefik | `traefik:v3.7.15@sha256:0f615020...` | Docker API negotiated to 1.56 (Docker Desktop engine 29.8.2). |
| cloudflared | `cloudflare/cloudflared:2026.10.1@sha256:a15a3b50...` | Uses `TUNNEL_TOKEN_FILE` and the `tunnel ready` health check. |
| Socket proxy | `tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b5...` | Tags are `v`-prefixed. |
| Test backend | `traefik/whoami:v1.12.0@sha256:c4717a8d...` | `test` profile only. |

Full digests are in `compose.yaml`.

## Advanced: using the terminal

Everything the website does is also available from PowerShell.

```powershell
.\Start-DeploymentManager.ps1                  # what START-HERE.cmd runs; -Status, -Stop, -Restart, -Port, -InstallPath
.\Start-DeploymentManager.ps1 -InstallPath D:\proxy   # open one deployment directly (skips the chooser)
.\Start-DeploymentManager.ps1 -StartMode default    # open the saved default deployment (choose / recovery: see docs\launcher.md)
.\launcher\Install-Launcher.ps1 -Autostart          # what Setup-Launcher.cmd runs: DTC.exe, shortcuts, default, Start with Windows
```

```powershell
cd <this repo>
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun     # shows every action, changes nothing
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Start      # installs to %USERPROFILE%\.docker\projects\traefik-proxy
cd $env:USERPROFILE\.docker\projects\traefik-proxy
.\services.ps1 add -Name whoami -Hostname whoami.example.com -TargetType docker -TargetHost my-container -Port 80
```

The last command only **previews** the change. Add `-Apply` to write it. Then publish it through Cloudflare
with the [web UI](#web-ui), the guided console wizard (`.\install.ps1 -Wizard` the first time,
`.\install.ps1 -AddApp` later), or by hand (see [Cloudflare](#cloudflare-tunnel-remotely-managed)).

## Web UI

A local browser interface (the *Deployment Manager*) for the whole lifecycle: a guided seven-step installation,
then an operational dashboard for services, Cloudflare, the Traefik dashboard, backups and diagnostics. It is
plain HTML, CSS and JavaScript served by `webui.ps1`; nothing else needs to be installed.

```powershell
# from the repository (targets %USERPROFILE%\.docker\projects\traefik-proxy) or from the install folder
powershell -ExecutionPolicy Bypass -File .\webui.ps1                 # opens the browser
powershell -ExecutionPolicy Bypass -File .\webui.ps1 -Port 8190 -NoBrowser -InstallPath D:\proxy
```

The console prints a one-time sign-in link (`http://127.0.0.1:8190/?k=...`). Stop the server with Ctrl+C.

On a new machine, start it from the repository: modules, scripts and the installer always load from the folder
`webui.ps1` runs from, while the install folder only holds the instance's `.env`, configuration, secrets, backups
and logs, so it does not need to exist yet. Until the stack is installed, status, logs, validation and
diagnostics report *Not installed*; the Setup page installs it.

**Detail levels.** *Beginner*, *Intermediate*, *Advanced* and *Expert* (top bar, remembered in this browser) only
change what is shown: Beginner tucks Docker networks, subnets and static addresses away and explains every check;
Intermediate adds ports, addresses and summaries; Advanced adds networks, DNS records and Traefik details; Expert
adds generated files, exact commands, identifiers and raw output. A level never changes what is allowed, how
changes are validated, or anything on the server. Small **?** buttons next to fields open a short explanation
from the learning catalog (`webui\learn.json`), and *Help and Learning* lists every topic with links to official
documentation. Topic ids are stable, so a future learning site can be linked without changing the app.

**Review states.** *Validated* (the tool checked it), *Reviewed* (you looked at it; changes nothing technical),
*Applied* (the change was made), *Healthy* (a live check passed), *Warning* and *Failed*. Review sections can be
expanded, collapsed, marked reviewed (which collapses them to a summary) and reopened, and show their technical
output and differences on request. When the content of a reviewed section changes, the mark is invalidated
("Changed since review").

**Setup journey (first run).** One vertical page with a step rail (a progress menu on phones). Nothing in
Docker or Cloudflare changes until you approve the local changes (step 5) and the Cloudflare changes (step 6)
separately and select *Install* (step 7):

1. **Connect Cloudflare.** *Create Cloudflare API Token* opens Cloudflare's pre-filled token page
   (`dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=...&accountId=*&zoneId=all`) asking for
   *Zone > Zone > Read*, *Zone > DNS > Edit*, *Account > Cloudflare Tunnel > Edit* and, optionally,
   *Account > Access: Apps and Policies > Edit*. Restrict the accounts and zones there before creating the token.
   Cloudflare shows the token only once: copy it, paste it into the masked field, then close the Cloudflare tab.
   The token is verified, stored with DPAPI (never in a URL, the browser, logs or Git), and read-only calls show
   which accounts, domains, tunnels and permissions it has; missing permissions are explained. One visible
   domain is allowed automatically; with several, you choose. Services can only be published under these
   allowed domains. You can replace or remove the token at any time, or **skip** this step for a local-only
   installation. Account-level and zone-level permissions are explained. If the token can read your Cloudflare
   profile email (not part of the template), it is offered as your contact email for you to confirm.
2. **Prepare Docker Desktop**: automatic, read-only checks with the reason for each: Docker CLI, engine, Linux
   containers, Compose, a writable install folder, container names, ports, networks, subnet overlap, the
   installation state, and how many other containers stay untouched. Instructions appear if Docker is not ready.
3. **Configure the deployment**: install folder (default under your profile), instance name, ports and, in
   Advanced, the Docker network, tunnel subnet and static address. Values that collide with nothing on this PC
   are pre-filled (*Suggest free values* re-computes them); subnet validation always runs, even when hidden. The
   Traefik dashboard hostname is suggested from the instance name (`traefik-ext1` →
   `traefik-ext1.<allowed domain>`); you can edit it, and later name changes no longer overwrite your edit until
   you select *Reset to automatic*.
4. **Configure ingress**: *Cloudflare Tunnel* (new or existing dashboard-managed tunnel, with a summary of the
   account, domains, connector, Traefik destination and DNS behaviour) or *Local only* (no Cloudflare; how
   internal DNS such as Pi-hole fits in, and that Traefik's ports are loopback-only in this version).
   *Public IP* is shown as planned and cannot be selected.
5. **Review local infrastructure**: the installer's checks, `docker compose config` and an installer dry run as
   review sections, an optional contact email (used only as the default Cloudflare Access sign-in; not for
   certificates, and nothing is sent), then your approval of the local changes.
6. **Review Cloudflare changes**: account and domain, the tunnel to create or reuse, the public dashboard
   (Access application, tunnel route, DNS record), DNS safety (email records are never touched; existing records
   are only replaced after a per-record confirmation), security and rollback; then your separate approval.
7. **Install and verify**: applies both approvals (the server refuses an installation that creates Cloudflare
   resources without the Cloudflare approval), publishes the dashboard behind Access if chosen, then verifies
   each component on its own (containers, tunnel connectivity, local dashboard, internal router, DNS, Access,
   requests without Access refused) with a topology diagram. A running container alone is never reported as a
   healthy deployment. On success: **Your reverse proxy is ready.**

**After installation** the menu switches to *Overview* (health, containers, tunnel, domains, dashboard links,
services, warnings, recent changes and a request-flow diagram), *Services*, *Cloudflare*, *Traefik Dashboard*,
*Backups*, *Diagnostics* (logs, validation, report, activity, and in Expert the generated configuration and
commands), *Settings* (detail level, theme, instance, upgrade commands) and *Help and Learning*. The setup journey
stays available.

### Public Traefik dashboard

Generated into `traefik\dynamic\admin-dashboard.yml` from `config\dashboard.json`. Only `/dashboard/` and `/api`
(plus a redirect from `/`) are routed to Traefik's `api@internal`, on the `web` entry point that cloudflared uses.

- **Cloudflare Access is mandatory and comes first.** The apply order is: create (or reuse) the Access
  application, confirm through the API that it protects the hostname, validate the route in a throwaway Traefik,
  write the route, then add the tunnel route and the DNS record. If Access cannot be established (no Access
  permission, no sign-in emails, Cloudflare refuses the change), nothing is published: no route, no tunnel route,
  no DNS record.
- The router also requires the `Cf-Access-Jwt-Assertion` header that Cloudflare Access adds to authenticated
  requests, so a request that did not pass through Access gets 404 from Traefik. Traefik does not verify the
  token's signature; Cloudflare Access is the authentication.
- **Verify** runs independent checks: local dashboard, route file, local routing through the `web` entry point
  (with and without the Access header), the Access application, the tunnel route, the connector, the DNS record
  and the public URL (it must redirect to the Cloudflare Access login).
- Running it again changes nothing; existing Access applications are reused. Removing it deletes the route first,
  then only the DNS record, tunnel route and Access application this tool created.

### Backups and restore

The Backups page:

- **Export configuration (.json)**: a versioned manifest (`format: traefik-proxy-config`, `schemaVersion: 1`,
  manager version) of this instance: settings, Docker names and images, the Cloudflare account, zones, tunnel,
  DNS record and Access application ids, public hostnames, routes, middlewares, service definitions and the
  public dashboard settings.
- **Download full backup (.zip)**: the manifest plus this instance's configuration files (`.env` with known keys
  only, `config\*.json`, `traefik\dynamic\*.yml`) and an `INVENTORY.txt`.
- **Never exported**: the Cloudflare API token, the tunnel connector token and anything under `secrets\`, plus
  logs and earlier backups. Every exported text is scanned for credential patterns and for the stored tokens;
  an export that would contain one is refused (a credential-like hand-written file is left out and listed). The
  manifest lists the credentials to reconnect after a restore.
- Only this instance's install folder is read, so other applications, other Traefik instances and other projects
  on the PC are never packaged.
- **Import backup** accepts a .json or .zip made by this tool, or a `config\services.json` from an earlier
  version. The format, schema version (newer schemas are refused with an upgrade hint), file names and contents
  are checked; a file containing a credential is refused. The preview shows every change before anything happens.
- **Restore** has two separately approved parts:
  1. *Local configuration*: setup choices (for a not yet installed folder, as the setup draft, so the Setup page
     continues at *Review and install*), Cloudflare selections, the service registry and generated routes,
     hand-written Traefik files from a .zip, the dashboard settings; then a Traefik reload. An installed
     instance's `.env` is never changed. No container is started.
  2. *Cloudflare*: recorded ids are verified first (the tunnel and zones must exist in the expected account; DNS
     record and Access application ids are adopted only if they still match). Missing DNS records, tunnel routes
     and Access applications are created; an existing DNS record is only replaced after a per-record
     confirmation; an existing Access application is reused, never duplicated; tunnels are never recreated.
     The public dashboard is republished with the same fail-closed order.
  Restoring the same backup again changes nothing.
- **Recovery points**: before every configuration change (service changes, rollbacks, restores, the dashboard)
  a backup .zip is written to `backups\recovery\` (read-only, readable only by your Windows account, SYSTEM and
  Administrators). They can be downloaded or restored like an imported backup and are never deleted
  automatically. The change is refused if the recovery point cannot be written.

**Adding a service** (Services > Add a service): *name → hostname → destination → publish*. Enter a display name
(for example *Notflix*); the subdomain is suggested from it (`notflix`) and can be changed (`movies`, giving
`movies.<domain>`) without changing the display name, and a manual subdomain is not overwritten by later name
changes. The domain is chosen from the allowed Cloudflare domains, never typed again. Choose where the app runs:
a Docker container on the shared network (reached by its container name, for example
`http://uptime-kuma:3001`), this Windows PC, another device on the LAN, or (Advanced) a container on another
network reached by address. Path-prefix routing, extra hostnames, TLS verification and middlewares are in
Advanced, with a warning that many apps need a configured base path. Only HTTP(S) (including WebSockets and
h2c to the backend) is published; raw TCP or UDP is not. Choose who can reach it (Cloudflare
Access with a list of emails, public, or local only), then **Preview changes**. The preview shows the Traefik
file diff, validation warnings (for example the media-streaming notice for Plex) and every Cloudflare action:
create the Access application, add the tunnel route `hostname -> http://traefik:80`, create the proxied CNAME to
`<tunnel-id>.cfargotunnel.com`. Nothing happens until you tick *I reviewed these changes* and **Apply**. Then
the configuration is validated in a throwaway Traefik container, backed up, written and reloaded, and the
Cloudflare changes run in a safe order (Access first, DNS last).

Cloudflare safety rules:

- The API token is verified before it is stored, encrypted with Windows DPAPI for the current Windows user
  (`secrets\cloudflare_api.dpapi`, ACL restricted) and never sent back to the browser.
- An existing DNS record or tunnel route that points somewhere else is only replaced after a separate
  per-resource confirmation. A/AAAA and multi-record names are never changed automatically (the change is
  blocked with an explanation). Existing Access applications are reused, never modified.
- Removing a service (or changing its hostname) can clean up only what points at this instance's tunnel and
  Access applications this tool created (tracked in `config\cloudflare.json`). Disabling keeps Cloudflare as is.
- A preview is single-use and expires after 15 minutes; if Traefik files or the relevant Cloudflare state
  changed in between, the apply is refused and you preview again.
- Without a token, every preview lists the exact manual steps for the Cloudflare dashboard instead.

Scoped token permissions: *Account > Cloudflare Tunnel > Edit*, *Account > Access: Apps and Policies > Edit*
(only for automatic Access), *Zone > DNS > Edit* and *Zone > Zone > Read* for the zones you use. The template
link uses Cloudflare's documented keys `zone`, `dns` and `access`; for Cloudflare Tunnel it uses `argotunnel`,
which works in other tools' links but is not in Cloudflare's published key table. If Cloudflare's page does not
list Cloudflare Tunnel, add it by hand; the permission check after pasting the token reports it either way.

Security of the interface itself: it listens on a `127.0.0.1` socket only (not reachable from the LAN), needs
the sign-in link (HttpOnly, SameSite=Strict session cookie), rejects foreign `Host` headers (DNS rebinding),
requires a matching `Origin`, a per-session CSRF token and JSON bodies for every change, limits request sizes,
serves a fixed whitelist of static files with a strict Content-Security-Policy, and writes every change to
`logs\webui-audit.log` (redacted).

## Managing services

Every proxied application is one entry in `config\services.json`:

| Field | Meaning |
| --- | --- |
| `name` | Short identifier (`plex`, `home-assistant`): lowercase letters, digits, dashes. |
| `hostnames` | One or more public hostnames, e.g. `plex.example.com`. |
| `pathPrefix`, `stripPrefix` | Optional: route only `/api...` and optionally remove the prefix before forwarding. |
| `target.type` | `docker` (container name), `host` (this Windows PC), `lan` (IP address or DNS name). |
| `target.host`, `target.port` | Where the app listens. For `docker`, the port **inside** the container. |
| `target.protocol` | `http`, `https` or `h2c`. `tlsSkipVerify` for self-signed HTTPS backends on a trusted LAN. |
| `middlewares` | Traefik middlewares, default `default-headers@file`. Also shipped: `compress@file`, `no-index@file`. |
| `cloudflare.publish`, `cloudflare.access` | Intent for the tunnel: publish at all, and protect with Cloudflare Access. Used for warnings and guidance. |
| `enabled` | Disabled services keep their definition but get no route. |

`services.ps1` is the command-line front end (the planned web UI uses the same backend,
`lib\TraefikProxy.psm1`). Commands that change something show a **preview** (a diff of the generated Traefik
files plus validation errors and warnings) and do nothing unless `-Apply` is given. With `-Apply`:

1. The planned configuration is loaded into a **throwaway Traefik container** (no network, removed afterwards);
   if Traefik reports any router, service or middleware error, nothing is changed.
2. The current registry and route files are saved to `backups\services\<timestamp>\`.
3. `config\services.json` and `traefik\dynamic\svc-<name>.yml` are written (atomically).
4. Traefik reloads them without a restart, and the command waits until the routes are live.

```powershell
.\services.ps1 list
.\services.ps1 add -Name plex -Hostname plex.example.com -TargetType lan -TargetHost 10.10.0.11 -Port 32800
.\services.ps1 add -Name wiki -Hostname wiki.example.com -TargetType docker -TargetHost wikijs -Port 3000 -Apply
.\services.ps1 add -Name grafana -Hostname grafana.example.com -TargetType host -Port 3000 -Apply
.\services.ps1 add -Name nas -Hostname nas.example.com -TargetType lan -TargetHost 192.168.1.20 -Port 5001 -Protocol https -TlsSkipVerify -LocalOnly -Apply
.\services.ps1 set -Name plex -Port 32400 -Apply        # edit any field
.\services.ps1 disable -Name plex -Apply                # route removed, definition kept
.\services.ps1 enable -Name plex -Apply
.\services.ps1 remove -Name plex -Apply
.\services.ps1 show -Name plex                          # definition + generated YAML
.\services.ps1 preview                                  # registry vs. files on disk
.\services.ps1 apply                                    # regenerate everything from config\services.json
.\services.ps1 validate -Deep                           # rules + throwaway Traefik container
.\services.ps1 backups
.\services.ps1 rollback -Apply                          # undo the last apply (repeat to go further back)
```

Validation catches, among others: invalid names/hostnames, ports, protocols; hostnames already routed by
another service; loopback LAN targets (they would point at Traefik itself); IPv6 targets; skip-verify on plain
HTTP; undefined middlewares; values that could inject into a Traefik rule. Warnings cover services published
without Cloudflare Access, public IPs as LAN targets, self-signed HTTPS by IP, and likely media-streaming apps.

### Example: Plex on another device

```powershell
.\services.ps1 add -Name plex -Hostname plex.jrtechconsult.com -TargetType lan -TargetHost 10.10.0.11 -Port 32800 -Description 'Plex Media Server'
```

generates `traefik\dynamic\svc-plex.yml`:

```yaml
http:
  routers:
    svc-plex:
      rule: 'Host(`plex.jrtechconsult.com`)'
      entryPoints: [web]
      middlewares: [default-headers@file]
      service: svc-plex
  services:
    svc-plex:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: http://10.10.0.11:32800
```

and warns that this looks like a **media streaming** service. Cloudflare's self-serve terms restrict serving
video or a disproportionate amount of non-HTML content through its proxy and Tunnel unless a dedicated
Cloudflare media product is used; heavy streaming can be throttled or the account suspended, and request
bodies are capped at 100 MB on Free/Pro. For Plex, prefer Plex's own Remote Access or a private network
(Cloudflare WARP / Cloudflare One, a VPN) for streaming, and use the tunnel at most for light web access behind
Cloudflare Access. The remaining Cloudflare steps for the hostname are the same as for any service (below).

### Backend addresses: "How should Traefik connect to this application?"

The Add Service and Edit Service forms ask one question with three options: **Docker container** (its container
network name and internal port), **Application on this computer** (an HTTP app running directly on Windows) and
**Another computer or network device** (any IP address or hostname on your network). The option helps the manager
discover and recommend an address; it never restricts what you may choose. The manager proposes the address Traefik
must use from *inside* its container (`lib\BackendResolver.psm1`, `POST /api/services/backend`) and tests it from
Traefik's own network before anything is saved:

| You run or type | Recommended | Why |
| --- | --- | --- |
| A container on the shared network (`uptime-kuma`) | `http://uptime-kuma:3001` | Docker DNS name and the port *inside* the container |
| A Windows app, typed as `127.0.0.1:4119` or `localhost:4119` | `http://host.docker.internal:4119` | Inside Traefik, 127.0.0.1 is Traefik itself (the typed address cannot be selected) |
| A Windows app, typed as this PC's LAN address (`10.10.0.11:80`) | `http://host.docker.internal:80`, next to `http://10.10.0.11:80` | Both are selectable; the LAN address depends on Docker routing to the LAN |
| A Windows port that a container publishes (`127.0.0.1:3010`) | `http://homepage:3000` | The container is reached directly, by name and internal port |
| Another device (`10.10.0.8:8080`, `nas.home.arpa`) | As typed | Never replaced by `host.docker.internal`; a Docker subnet that captures it is reported |
| A container on another network | Options: its published port through the host gateway, or a Compose network attachment | Shown as choices, never picked silently; databases and caches are never offered |

**A recommendation is never a requirement.** The form lists every candidate with its own radio button: *Address you
entered*, *Recommended alternative*, other *Discovered alternatives* and, in Advanced and Expert, a *Custom address*
(a complete URL such as `http://10.10.0.8:8080`). The address you typed stays selected until you pick another one;
**Use recommended address** switches to the recommendation. The address you select is the one tested, previewed and
written to the Traefik service (`loadBalancer.servers[0].url`). Editing an existing service keeps its saved backend
until you choose another one, and a backend picked under one option is kept when you switch options and back.

Notices are of four kinds: *recommendations* (informational, never blocking), *connectivity warnings* (the address may
not connect, for example because a Docker network overlaps the destination subnet; they disappear once the selected
address passes a test), *restrictions* (an address that cannot or must not be used: loopback, a base path in the
URL, a database container) and *help*. On native Linux, Podman or Unraid, `host.docker.internal` is recommended only
after it is verified to resolve inside Traefik (add `extra_hosts: ['host.docker.internal:host-gateway']` to the
Traefik service otherwise).

**Docker networks that overlap your LAN.** A Docker network whose subnet contains a LAN address (for example a
Compose network on `10.10.0.0/24` while the LAN is `10.10.0.0/24`) captures that traffic inside Docker Desktop's VM:
Traefik's requests to `10.10.0.11` go to that bridge, not to Windows, and time out. The form names the network;
the fix is to move that network to another subnet in its compose file (or remove it once nothing uses it). The
manager never changes networks itself.

The connection test is the readiness check. **Test connection** tests the selected address; **Test every address**
tests each candidate on its own, never substituting one for another. Each test reports DNS, the TCP connection, the
HTTP answer, TLS, redirects and the Host header (the public hostname, compared with the backend's own address so an
app that rejects unfamiliar hostnames is recognised), and names the result: *Verified reachable*, *Reachable,
authentication required*, *Application redirect*, *Wrong protocol*, *Wrong port*, *DNS resolution failure*,
*Connection refused*, *Timeout*, *Hostname rejected*, *TLS verification failure*, *Application error* or *Not
tested*. An HTTP 400 is never a pass. The test runs during the preview and again immediately before applying; a
route whose backend fails is saved only after an explicit **Save the route anyway**, and is never shown as healthy.

### Target notes

- **docker:** attach only the app's web-facing container to the shared network: `docker network connect proxy
  <container>` (live, no restart) and add the network to the app's Compose file so it survives recreation (see
  `examples\compose-labels.example.yaml`). The wizard can attach it for you.
- **host:** the Windows app must listen on `0.0.0.0` (or the Docker Desktop host address), not only `127.0.0.1`,
  and Windows Firewall must allow the port.
- **lan:** Docker Desktop containers reach the LAN through the host's network stack. Prefer IP addresses or
  fully qualified names; single-label names (`nas`) usually do not resolve inside Docker Desktop.
- Hand-written routes for special cases go in any other file in `traefik\dynamic\` (see
  `examples\manual-route.yml.example`); `svc-*.yml` files are generated and overwritten. Docker labels also
  keep working (`examples\compose-labels.example.yaml`).

## Install

### Instance settings (`.env`)

Everything instance-specific is in `.env` in the install folder (created from `.env.example`):

| Variable | Default | Purpose |
| --- | --- | --- |
| `STACK_NAME` | `traefik-proxy` | Compose project name and container prefix (`traefik-proxy-traefik`, ...). |
| `TRAEFIK_HTTP_PORT`, `TRAEFIK_DASHBOARD_PORT` | `8180`, `8181` | Loopback-only ports for local tests and the dashboard. |
| `PROXY_NETWORK` | `proxy` | Shared network for `docker` targets. Created if missing, never recreated. |
| `TUNNEL_SUBNET`, `TUNNEL_IP_RANGE`, `CLOUDFLARED_IP` | `172.31.250.0/28`, `.0/29`, `.10` | Private cloudflared <-> Traefik network; `CLOUDFLARED_IP` is the only trusted source of `X-Forwarded-*`. |
| `TRAEFIK_LOG_LEVEL`, `TRAEFIK_READ_TIMEOUT` | `INFO`, `300s` | Logging and slow-upload tolerance. |

Traefik's static configuration is passed as command-line flags in `compose.yaml` so it can use these values:
Traefik does not expand variables in a configuration file, and Compose cannot inject a generated config file
into the read-only Traefik container. Change `.env`, then re-run `.\install.ps1 -Start` to apply it.

Several instances can run side by side: install each into its own folder with its own `STACK_NAME`, ports,
`PROXY_NETWORK` and tunnel subnet, e.g. `.\install.ps1 -InstallPath D:\proxy-lab -EnvFile .\lab.env -Start`.
The installer refuses to start if a container name, port or subnet is already taken.

### What the installer does, and does not do

- Checks the engine is Linux, prints existing containers and ports, validates `.env`.
- Fails if a stack container name already belongs to another Compose project, if a loopback port is taken, or
  if another Docker network overlaps the tunnel subnet.
- Creates the shared network if missing; reuses it as-is otherwise (warns if another project owns it).
- Copies files without clobbering your edits: unchanged files are updated (old copy in `backups\<timestamp>\`);
  files you edited are kept and the new version is written as `<file>.dist`.
- Reports whether the route files match `config\services.json`.
- Never writes secrets to `.env`; never runs `down -v`, `prune` or `network rm`.

| Switch | Effect |
| --- | --- |
| `-InstallPath <dir>` | Target folder (default `%USERPROFILE%\.docker\projects\traefik-proxy`). |
| `-EnvFile <file>` | `.env` to use when the target has none yet (default: `.env.example`). |
| `-DryRun` | Report only. |
| `-Start` | `docker compose up -d --wait` (adds the tunnel profile with `-EnableTunnel`). |
| `-Wizard` | Guided tunnel + first app setup. |
| `-AddApp` | Guided: route and publish another hostname on the existing tunnel. |
| `-Domain`, `-TunnelName`, `-AppHostname` | Pre-answer wizard questions. |
| `-AppTarget <spec>` | `container:<name>:<port>`, `windows:<port>`, `lan:<host>:<port>` or `existing`. |
| `-AppProtocol` | `http` (default), `https` or `h2c` for the wizard's app. |
| `-LocalOnly` | With `-Wizard`/`-AddApp`: Traefik route only; skip the Cloudflare steps and public test. |
| `-SetTunnelToken` | Hidden prompt for the token; pasting the whole `docker run ... --token X` command is fine. |
| `-EnableTunnel` | Include cloudflared. |
| `-Rollback` | Restore installer-managed files from the latest `backups\<timestamp>` (current files saved first). |
| `-Stop` | `docker compose down --remove-orphans` for this instance only (no `-v`; the shared network stays). |
| `-Reload` | Make Traefik re-read `traefik\dynamic\` after hand edits (see below). |

**Editing `traefik\dynamic\` by hand:** Docker Desktop does not pass file-change notifications from Windows
folders into the Linux VM, so Traefik's file `watch` does not see edits made in Windows. Run
`.\install.ps1 -Reload` afterwards. `services.ps1`, the wizard and the installer do this automatically.

## Cloudflare Tunnel (remotely managed)

`.\install.ps1 -Wizard` performs these steps interactively. Manual equivalent:

1. **Cloudflare Access first** for every app without its own login (Zero Trust > Access > Applications > Add >
   Self-hosted): application domain `app.example.com`, policy e.g. *Allow - Emails - you@example.com*.
2. Zero Trust > Networks > Tunnels > **Create a tunnel** > Cloudflared, name e.g. `traefik-windows`.
   Copy the token from the Docker install command.
3. On the PC:
   ```powershell
   cd $env:USERPROFILE\.docker\projects\traefik-proxy
   .\install.ps1 -SetTunnelToken -Start -EnableTunnel
   docker logs --tail 50 traefik-proxy-cloudflared     # expect "Registered tunnel connection" lines
   ```
4. Tunnel > **Published application routes** (older layouts: Public hostnames) > Add: the app's hostname,
   service **HTTP**, URL `traefik:80`. One route per hostname, all pointing at `traefik:80`; Traefik routes by
   Host header. If the hostname already has a DNS record, the dashboard asks to replace it.
5. Never add a public hostname for the dashboard (8181) or the socket proxy.

Testing the tunnel end to end with the echo backend: temporarily add a public hostname such as
`whoami-test.example.com` -> `http://traefik:80` (behind Access, or remove it right after), then
`.\tests\Test-Stack.ps1 -PublicTestHost whoami-test.example.com`.

### Coexisting with another cloudflared connector

A separate tunnel (different token) can keep running in its own project; nothing here touches it. Do not run
this stack's cloudflared with another tunnel's token: connectors of one tunnel are load-balanced replicas, so
requests would land on a connector that cannot reach this Traefik. The wizard refuses tokens that another
container on this PC already uses.

## Tests and diagnostics

```powershell
.\tests\Test-ServiceConfig.ps1          # 63 checks: generator, validation, plan/apply, rollback, deep validation
.\tests\Test-WebUi.ps1                  # web UI + Cloudflare automation against a loopback Cloudflare API mock
.\tests\Test-FirstRun.ps1               # first run: web UI and diagnostics from the source folder, nothing installed yet
.\tests\Test-Onboarding.ps1             # Cloudflare-first wizard against the mock: token link, discovery, permissions,
                                        # allowlist, local-only, preview, confirmed install of a disposable instance
.\tests\Test-Backup.ps1                 # export/import/restore against the mock: round trip, version compatibility,
                                        # credential exclusion, idempotency, authorization failures, recovery points
.\tests\Test-Dashboard.ps1              # dashboard bootstrap: route, fail-closed Access, no duplicates, removal
.\tests\Test-UiBrowser.ps1 -ScreenshotDir .\screens   # the UI in headless Edge (DevTools protocol): journey,
                                        # detail levels, naming, reviews, approvals, a disposable local install,
                                        # responsive layout (390/820/1366 px), keyboard and accessible names
.\tests\Test-Explorer.ps1               # Infrastructure Explorer: model (fixture facts), a disposable running instance, browser;
                                        # -LiveReadOnly also checks %USERPROFILE%\.docker\projects\traefik-proxy read-only
.\tests\Test-Provisioning.ps1           # New app: sources (fixtures), manifests, security review, identity contract (in-memory authentik),
                                        # AI (mocked), recipes, API, one disposable deployment + rollback (-SkipDocker: no containers)
.\tests\Test-ProvisionBrowser.ps1       # New app page in headless Edge (in-page API stand-in)
.\tests\Test-CatalogInstall.ps1 -Apps echo,diun,uptime-kuma -Cloudflare   # real catalog apps, one at a time, on a disposable deployment
.\tests\Find-TestOrphans.ps1 [-Remove]  # leftovers of interrupted test runs (only tpx-/tpm- test prefixes)
.\tests\Test-Catalog.ps1                # App Catalog: manifests, templates, Compose generation, install, lifecycle, update,
                                        # removal and data retention, browser; fixture apps only (no image downloads)
.\tests\Test-Discovery.ps1              # Docker discovery, port probes, hostname claims, publishing (network / published port),
                                        # health, conflicts, browser wizard; throwaway containers only
.\tests\Test-Routing.ps1                # request-path diagnosis rules (no Docker): first failing hop, container vs Windows
                                        # localhost, LAN subnets captured by Docker, wrong port/protocol, timeouts, tunnel
                                        # route mismatches, Access login ("authentication required", never "passed")
.\tests\Test-BackendResolver.ps1        # backend address selection (no Docker): 127.0.0.1 / this PC's LAN IP -> host gateway,
                                        # containers (shared, several, no shared network, private), LAN devices, overlapping
                                        # subnets, native Linux / Podman / Unraid, entered vs recommended addresses, custom URLs;
                                        # connection-test classification, generated service URL, hostname collisions
.\tests\Test-WizardBrowser.ps1 -InstallPath <install> -AppAddress <this PC's LAN IP> -AppPort 80 [-AccessEmail you@example.com]
                                        # browser test of "How should Traefik connect to this application?" against an
                                        # installed instance, read-only (never applies; fails if routes, registry,
                                        # tunnel config, containers or networks change); -ScreenshotDir saves screenshots
.\tests\Test-Launcher.ps1               # DTC tray launcher: settings, start modes, remembered browsers, autostart, setup, real DTC.exe + tray,
                                        # port conflict, duplicate start, failures, Deployments page (isolated folders; -SkipTray, -SkipBrowser)
.\tests\Test-Projects.ps1               # launcher (single-use link, duplicate start, ports, stop, START-HERE.cmd), discovery,
                                        # attach without changes, recent projects, upgrade preview/apply, browser;
                                        # -LiveReadOnly also inspects %USERPROFILE%\.docker\projects\traefik-proxy read-only
.\tests\Test-Identity.ps1              # Identity & Access without authentik: ForwardAuth routes (accepted by a throwaway Traefik),
                                        # guards, Google values, owner rule, discovery, model states, resume, credentials, secret store
.\tests\Test-IdentityLive.ps1 -ScreenshotDir .\screens   # disposable instance + authentik from the catalog: adopt, token,
                                        # sign-in route, outpost, Google source (synthetic credentials), protect/unprotect,
                                        # allowed/denied sign-ins through the real outpost, fail closed, rollback, browser
node .\tests\ui-logic.test.js           # developer-only unit tests of webui\logic.js (Node is not needed to run the tool)
.\tests\Invoke-UiPreview.ps1            # developer tool: quick screenshots of pages at chosen levels and widths
.\tests\Invoke-IsolatedTest.ps1         # (repository only) disposable second instance: install, live tests,
                                        # services.ps1 walkthrough with docker/LAN/host targets, a web UI
                                        # end-to-end change (mock Cloudflare), live dashboard routing and a live
                                        # restore, teardown
.\tests\Test-Stack.ps1                  # live checks against a running instance, exit code 1 on failure
.\tests\Test-Stack.ps1 -PublicTestHost whoami-test.example.com
.\scripts\Get-Diagnostics.ps1 -OutFile diag.txt
```

`Invoke-IsolatedTest.ps1` takes before/after snapshots of every other container on the engine (ID, start
time, state) and fails if anything outside its own instance changed.

## Upgrading the manager on an installed instance

The installer never overwrites instance data: `.env`, `config\`, `secrets\`, generated routes
(`traefik\dynamic\svc-*.yml`, `admin-dashboard.yml`), `backups\` and `logs\` stay as they are. Package files
(scripts, web UI, `compose.yaml`, `security.yml`, `dashboard.yml`) are updated only if you did not edit them; the
previous copy goes to `backups\<timestamp>\`, and an edited file is kept with the new version written next to it
as `<file>.dist`.

```powershell
cd <this repo>; git fetch; git checkout <new version>
# 1. Back up first (read-only): Backups > "Download full backup (.zip)". Keep the file outside the install folder.
powershell -ExecutionPolicy Bypass -File .\webui.ps1 -InstallPath <install folder>      # Ctrl+C when done
# 2. See what would change (nothing is written):
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallPath <install folder> -DryRun
# 3. Update the package files. Without -Start, no container is started, stopped or recreated (a running Traefik
#    is only asked to re-read traefik\dynamic\, which a throwaway container triggers):
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallPath <install folder>
```

If the dry run lists `compose.yaml` as `same`, the running containers need nothing. If it changed, apply it
when convenient with `.\install.ps1 -InstallPath <install folder> -Start` (add `-EnableTunnel` in tunnel mode).
Undo the file update with `.\install.ps1 -InstallPath <install folder> -Rollback`. If configuration is ever lost,
import the backup on the Backups page and apply part 1 (and part 2 for Cloudflare).

## Upgrades

1. Read the Traefik release notes and migration guide for every version between the current and the target.
2. Find the new digest: `docker buildx imagetools inspect traefik:v3.x.y` (top-level `Digest:`).
3. Edit the `image:` line in this repo's `compose.yaml` (tag **and** digest) and `$script:TraefikImage` in
   `lib\TraefikProxy.psm1`, run the tests, commit, then `.\install.ps1 -Start`.
4. Check `docker logs <stack>-traefik` for `WRN`/`ERR`.
5. Same procedure for cloudflared and the socket proxy. Never use `latest`.

## Rollback / removal

- Undo the last service change: `.\services.ps1 rollback -Apply` (repeat to go further back).
- Undo the last installer file update: `.\install.ps1 -Rollback; docker compose up -d`.
- Stop this instance only: `.\install.ps1 -Stop`. Do **not** add `-v`, do not remove the shared network while
  apps are attached, never `docker system prune`.
- Detach an app: `docker network disconnect proxy <container>` (and remove the network from its Compose file).

## Migrating from the earlier single-app layout

Earlier versions used fixed container names (`traefik`, `socket-proxy`, `cloudflared`), the project name
`traefik-cloudflared`, `traefik\traefik.yml` and the install folder
`%USERPROFILE%\.docker\projects\traefik-cloudflared-windows`. This version installs to a new default folder
and uses `<STACK_NAME>-*` container names, so it never modifies an existing deployment of the old layout.
Because the defaults use the same ports and tunnel subnet, the installer will refuse to start next to a running
old instance until you either stop the old one or give the new instance other values in `.env`. Hand-written
routes from the old `traefik\dynamic\` folder can be copied over as-is, or re-created with `services.ps1`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| 404 from Traefik | Host rule doesn't match the hostname; `.\services.ps1 list` and `scripts\Get-Diagnostics.ps1`. |
| 502 Bad Gateway | Backend not on the shared network, wrong *container* port, Windows app bound to 127.0.0.1 only / firewall, LAN device unreachable. |
| Any public hostname fails | **Check health** on the service (Services or Infrastructure Explorer) names the *first failing hop*: DNS, Access, tunnel route, Traefik router, service, Traefik to backend (a real request from Traefik's own network with the public Host header), application, public URL. A lock means a login page answered: reachable, sign-in not tested. |
| HTTP 400 through Traefik, 200 on the local port | The app rejects the public hostname (allowed-hosts list). Homepage: add the hostname to `HOMEPAGE_ALLOWED_HOSTS` in its `.env`, then `docker compose up -d` in its folder. |
| LAN target times out from Traefik, works from Windows | A Docker network uses the LAN's subnet and captures the traffic (`scripts\Get-NetworkAudit.ps1` lists it as CONFLICT). For an app on this PC, target `host.docker.internal` (type `host`) instead of the PC's LAN address. |
| Gateway Timeout / no answer from `host.docker.internal` | Windows Firewall blocks the port from the Docker Desktop VM, or the app listens only on 127.0.0.1. |
| `services.ps1 ... -Apply` says Traefik rejected the configuration | The error names the router/middleware; nothing was changed. |
| 524 at Cloudflare | Backend took > 100 s. |
| cloudflared restarting | Bad/rotated token: `.\install.ps1 -SetTunnelToken`; `docker logs <stack>-cloudflared`. |
| Traefik sees no labelled containers | `docker logs <stack>-socket-proxy` for 403s; container needs `traefik.enable=true`. |
| Port 8180 in use | Set `TRAEFIK_HTTP_PORT` in `.env`, re-run installer. |
| Tunnel subnet overlaps | Set `TUNNEL_SUBNET`, `TUNNEL_IP_RANGE`, `CLOUDFLARED_IP` in `.env`. |
| Edited a route by hand, nothing changed | `.\install.ps1 -Reload`. |
| `.ps1` blocked by policy | Launch with `powershell -ExecutionPolicy Bypass -File ...`. |

## Known limitations

- Cloudflare automation (web UI) has been tested against a mock of the API, not yet against the real Cloudflare
  API; in particular, Access applications are created with an inline email policy, which should be checked on
  first real use. The console wizard and `services.ps1` remain guided (manual Cloudflare steps).
- The tunnel path (cloudflared, public test) has not been validated end to end from this repository.
- Identity & Access: Google sign-in has only been exercised with synthetic credentials (the redirect to Google is
  checked, a real login is not); creating the Google OAuth client is manual (no Google API exists for it); Authelia
  is install-only; native OpenID Connect for applications is not configured by the manager; the manager uses an
  administrator's API token (a service account with a narrower RBAC role is possible in authentik but not set up yet).
- The web UI handles one request at a time; long operations (installer, deep validation) block it briefly.
  Service snapshots and rollback cover Traefik only; a backup restore re-creates missing Cloudflare resources but
  never deletes Cloudflare resources that are not in the backup.
- The public dashboard relies on Cloudflare Access for authentication; Traefik only checks that the Access header
  is present, not its signature.
- HTTP only between Cloudflare and Traefik inside Docker; TLS terminates at the Cloudflare edge. LAN clients
  cannot use the proxy (ports are loopback-only by design).
- Cloudflare edge limits apply: 100 MB request body (Free/Pro), 100 s response timeout (HTTP 524), and
  content restrictions for video streaming.
- One backend server per service (no load balancing across several servers) and IPv4 targets only.
- Tested on one Windows 11 machine with Docker Desktop 29.8.2 and Windows PowerShell 5.1.
