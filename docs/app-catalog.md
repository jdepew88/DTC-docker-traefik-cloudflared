# App Catalog

The App Catalog installs curated applications as ordinary Docker Compose projects, one project per application,
each in its own folder next to the proxy deployment (e.g. `%USERPROFILE%\.docker\projects\uptime-kuma`):

- `compose.yaml`: images pinned by tag and digest, the shared proxy network (external) for the web service only,
  a private network for the app's other services (databases, caches), named volumes (`<project>_<name>`) or folders
  you chose, `no-new-privileges`, log rotation, labels `org.traefik-proxy.app` / `org.traefik-proxy.project`.
  Secrets appear only as `${VAR}`.
- `compose.<component>.yaml` (multi-service apps): the other parts of the same Compose project, one small file per
  component (see *Modular application stacks* below).
- `dtc-stack.json`: a machine-readable description of the stack (no secrets).
- `.env`: settings and generated secrets (readable by your Windows account, SYSTEM and Administrators only).
- `credentials.txt` (apps with a sign-in password): the administrator credentials, same restricted access.
- Configuration files the app needs (e.g. Authelia's `config/`, Homepage's `config/`), written once and never
  overwritten, so your edits are kept.
- `README.md`: how to run, update and remove the app with plain `docker compose`, without the manager.
- `backups/<time>/`: backups made by *Back up* or before an update.

The manager remembers what it installed in the deployment's `config\apps.json` (folders and project names only) and
manages only projects it generated. Nothing is published automatically: an installed app appears under
*Services > Discover running containers*, from where you create its Traefik route and, optionally, publish it
through the existing Cloudflare Tunnel (Cloudflare Access by default).

## Applications

Images, ports, volumes and required settings were taken from each project's official compose files, documentation and
registry metadata on 2026-10-21 (groups A-E as first shipped) and 2026-11-17 (the applications added in the second
round). RAM figures are the manager's planning estimates. Groups follow the curated collection: **A** Docker
management, infrastructure and monitoring; **B** sign-in, passwords and directories; **C** media and personal
libraries; **D** productivity, files and communication; **E** cameras and surveillance. What has been verified for each
entry (static checks or a live installation) is in [catalog-inventory.md](catalog-inventory.md).

| Group | App | Image (pinned) | Local URL (127.0.0.1) | Dependencies | Notes |
| --- | --- | --- | --- | --- | --- |
| A | Traefik Manager | `ghcr.io/chr0nzz/traefik-manager:1.15.4` | :5000 | the existing Traefik API (read-only) | No Docker socket; its routes stay in its own `config/routes` until an ownership plan is approved; admin password set via its own `flask reset-password` |
| A | Uptime Kuma | `louislam/uptime-kuma:2.5.6` | :3001 | | SQLite in a volume; create the admin on first visit |
| A | Portainer CE | `portainer/portainer-ce:2.45.2` (LTS) | https :9443 | Docker socket | Alternative to Arcane (one of the two is enough); admin created right after start (setup token from its log); never public |
| A | Homepage | `ghcr.io/gethomepage/homepage:v2.6.0` | :3010 | | First `services.yaml` lists installed apps (links + HTTP status); `scripts\Update-HomepageConfig.ps1` refreshes it (see below); no Docker socket |
| A | Arcane | `getarcaneapp/manager:v2.16.1` | :3552 | Docker socket | Recommended optional Docker and Compose management (not needed by the manager); never public |
| A | HTTP echo | `traefik/whoami:v1.12.0` | :18080 | | For testing routes, tunnel and Access |
| B | authentik | `ghcr.io/goauthentik/server:2026.8.5` (server + worker) | :9000 | PostgreSQL 16 (`postgres:16-alpine`) | No Redis (removed in 2025.10); initial setup at `/if/flow/initial-setup/`; LDAP not required |
| B | Authelia | `authelia/authelia:4.39.28` | :9091 | | File-backed users (argon2 hash computed by Authelia), secrets as files; needs a real domain and HTTPS; protects apps only once a forwardAuth middleware is added |
| B | LLDAP | `lldap/lldap:v0.6.3` | :17170 (LDAP 3890 internal only) | | Not on the shared network (`web.proxy: false`): a private network of its own, local only; OpenLDAP itself is listed only (see below) |
| C | Jellyfin | `jellyfin/jellyfin:12.2.20261005-225228` | :8096 | | Up to three read-only library folders; optional NVIDIA GPU (experimental on Docker Desktop); local only by default |
| C | Dispatcharr | `ghcr.io/dispatcharr/dispatcharr:0.32.0` (all-in-one) | :9191 | embedded PostgreSQL/Redis | Tuners added by URL (no SSDP through Docker Desktop) |
| C | Dispatcharr: modular variant | same image, web + celery | :9192 | `postgres:17`, Valkey 9.1 | Listed under Dispatcharr (`variantOf`), not as a separate app |
| C | Channels DVR | `fancybits/channels-dvr:latest` (digest) | :8089 | | Limited on Docker Desktop (no Bonjour, no `/dev/dri`, tuners by IP); subscription; native Windows server recommended |
| D | Immich | `ghcr.io/immich-app/immich-server:v3.3.5` + machine learning (optional) | :2283 | `immich-db` (`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`), `immich-redis` (Valkey 9) | 6-8 GB RAM recommended; database must be a Docker volume on Windows; library in a volume or a chosen folder |
| D | Rocket.Chat (id `rocketchat`, alias `rocket-chat`) | `registry.rocket.chat/rocketchat/rocket.chat:8.9.0` | :3100 | MongoDB 8.2 (official `mongodb-community-server`, replica set), NATS 2.11; two setup jobs (MongoDB permissions, replica-set initialization) | Monitoring stack of the official compose left out; MongoDB never published |
| A | What's Up Docker | `getwud/wud:9.5.0` | :3200 | read-only Docker socket proxy (`tecnativa/docker-socket-proxy:v0.5.0`) | Notification only: no update trigger, and the proxy refuses POST/DELETE |
| B | OpenLDAP | `ghcr.io/intechcore/openldap:2.6.16-6` (Symas OpenLDAP 2.6 LTS packages) | none (LDAP; optional 127.0.0.1:3389) | | Headless: never routed; osixia is unmaintained and the free Bitnami images are gone, so a small maintained vendor image is used |
| - | PostgreSQL, Redis/Valkey | building blocks (`availability: reference`) | | | Bundled inside the apps that need them; never shared or published; never identify an installation |
| A | Diun | `crazymax/diun:4.33.1` (headless) | none (no web interface) | read-only Docker socket proxy (`tecnativa/docker-socket-proxy:v0.5.0`) | Offered again (2026-11-16) as the headless alternative to What's Up Docker (choice group *update notifications*); notification only; notifiers in `config/diun.yml` (written once, your edits kept) |
| A | Dozzle | `amir20/dozzle:v11.4.3` | :8087 | read-only Docker socket proxy | Live log viewer; actions and shell disabled; no login of its own (protect with authentik or Access) |
| A | CrowdSec (detection) | `crowdsecurity/crowdsec:v1.8.2` (headless) | none | read-only Docker socket proxy | Reads the Traefik container's log (`config/acquis.d/traefik.yaml`); offline by default; no bouncer or firewall rule is installed |
| A | Pi-hole | `pihole/pihole:2026.11.0` | :8053 (`/admin/`) | | DNS on port 53 only when chosen (opt-in, LAN); no DNS setting of the PC or router is changed |
| B | Vaultwarden | `vaultwarden/server:1.37.5` | :8222 | | SQLite in a volume; signups on for the first account; `/admin` disabled; ForwardAuth unsuitable (Bitwarden clients) |
| C | Plex Media Server | `plexinc/pms-docker:1.43.5.11079-b3b13e506` | :32400 (`/web`) | | Media folder read-only; config in a volume (file locking); optional LAN port 32400, claim token, NVIDIA GPU; LinuxServer.io/hotio installations are recognized |
| C | MediaFusion | `mhdzumair/mediafusion:6.2.0` (API + worker) | :8001 | PostgreSQL 18, Valkey 9 | No Prowlarr; Stremio/Kodi clients need direct access |
| C | RomM | `rommapp/romm:5.4.1` | :8095 | MariaDB 11.8 | No games or BIOS included; optional IGDB/SteamGridDB keys |
| D | Nextcloud | `nextcloud:34.0.6-apache` (+ cron) | :8090 | PostgreSQL 18, Valkey 9 | Installed with the administrator from the form; user files in a Docker volume; 34 is the production line |
| D | Paperless-ngx | `ghcr.io/paperless-ngx/paperless-ngx:3.4.2` | :8010 | PostgreSQL 18, Valkey 9; optional Gotenberg 8.38 and Tika 3.3 | Inbox folder polled every 10 s; 3.5.0 (released 2026-11-17) not adopted yet |
| D | File Browser | `filebrowser/filebrowser:v2.63.23` | :8085 | | Deprecated: archived upstream 2026-09; one chosen folder only |
| D | Gitea | `gitea/gitea:28.4.0` | :3030 | PostgreSQL 18 | Optional Git over SSH on a chosen port (default 2222, LAN) |
| D | n8n | `n8nio/n8n:2.48.4` | :5678 | PostgreSQL 18 | 2.x stable line (3.0 is beta); webhooks need the published address in `.env` |
| D | Mealie | `ghcr.io/mealie-recipes/mealie:v3.31.0` | :9925 | | SQLite; default administrator must be changed at once |
| D | HFS | `rejetto/hfs:v3.4.1` | :8086 | | One chosen folder under `/shares`; nothing shared until set in `/~/admin`; self-update disabled |
| E | Shinobi | listed only (manual setup) | | | Only moving tags (`dev`, `latest`), MariaDB embedded in the app image, licence restricts commercial use; adopt a hand-made project instead |
| - | Watchtower | no longer offered (`availability: retired`, 2026-10-25) | | | Archived (2025-12), fails on current Docker; unattended updates are not recommended; existing containers are still recognized |

## Modular application stacks

Every installed application has its own folder and its own Compose project; there is never one large Compose file for
all apps. A multi-service application is split into small Compose files by component and combined with Compose's own
multi-file mechanism (`-f compose.yaml -f compose.database.yaml ...`):

| File | Component | Holds (role) |
| --- | --- | --- |
| `compose.yaml` | app | the web front end and other application services; the project `name:` |
| `compose.database.yaml` | database | PostgreSQL, MongoDB, ... |
| `compose.cache.yaml` | cache | Redis, Valkey |
| `compose.messaging.yaml` | messaging | NATS, brokers |
| `compose.support.yaml` | support | e.g. the read-only Docker socket proxy |
| `compose.workers.yaml` | workers | background workers (Immich machine learning, Dispatcharr celery) |
| `compose.setup.yaml` | setup | one-time jobs (init, migration, maintenance) |

The component comes from the service's `role` (or a manifest `component`); the web service always belongs to
`compose.yaml`. Single-service apps keep one `compose.yaml`. Examples: Rocket.Chat = `compose.yaml` (Rocket.Chat),
`compose.database.yaml` (MongoDB), `compose.messaging.yaml` (NATS), `compose.setup.yaml` (permission and replica-set
jobs); Immich = application, database, cache and machine-learning worker.

- Start, stop, restart, logs, health, update, backup, restore and removal always pass the complete file set (recorded
  as `composeFiles` in `config\apps.json` and in `dtc-stack.json`).
- `.env` sets `COMPOSE_FILE=compose.yaml:compose.database.yaml:...` (with `COMPOSE_PATH_SEPARATOR=:`), so plain
  `docker compose up -d` / `ps` / `logs` in the folder uses the complete set too; the README names the files.
- `depends_on` (with `service_healthy` / `service_completed_successfully` conditions) works across the files, so
  databases are ready before the application starts.
- The fingerprint that detects edits made with other tools covers every file of the set (for a single file it is the
  same SHA-256 as before, so existing records stay comparable).
- `dtc-stack.json`: Compose project and files, every service with its component, role, lifecycle, image, networks,
  volumes, ports, dependencies and health check, the start order, the web front end and its backend URL on the shared
  network, the private and shared networks, the authentication fit, routing ownership (explicit Traefik file
  provider, no Docker labels) and lifecycle requirements (backup volumes, whether a backup stops the app, update
  policy, first-start steps). Names of `.env` variables and of secret variables only; never a value.

**Existing installations** keep their file structure: nothing is split or moved. *Stack & routing* describes them from
their own Compose files (`docker compose config --no-interpolate`, no `.env` values read), and *Write
dtc-stack.json* adds only that file after a confirmation.

## Stack, routing and diagnostics per app

*Stack & routing* on the Installed apps page (`GET /api/apps/stack`) shows one app's own files and nothing else:

- findings, worst first, each with what to do: missing Compose files, files changed outside the manager, a web service
  that is not running or not answering on the shared network, failed setup jobs, unexpectedly stopped or unhealthy
  services, a database/cache/broker found on the shared proxy network, routes whose file is missing or whose routers
  Traefik does not serve;
- the Compose files (they contain `${VAR}` references only), the stack description, the start order, dependencies,
  shared and private networks, the web front end, and the names of the `.env` variables;
- every route that points at the app: its file in `traefik\dynamic` (the directory Traefik's file provider loads; it
  does not read sub-folders), split into routers (with their rule), services (with their backend URLs) and middlewares,
  and whether Traefik's API reports each router as served.

Routes stay one file per route (`svc-<name>.yml`) holding that route's routers, service and middlewares. One file is
written atomically and validated in a throwaway Traefik before it replaces the old one, so a route is never
half-applied; the view splits it into its parts for inspection.

## Restore and roll back

*Restore…* lists the app's backups (manual, *before an update*, *before a restore*) and restores one after a preview:

1. a safety backup of the current state is made first, so a restore can itself be undone;
2. the app is stopped;
3. each data volume of the backup is emptied and filled from its archive (only volumes named `<project>_...`; a backup
   that names another project's volume is refused);
4. optionally the Compose files, `.env` and `dtc-stack.json` of the backup are put back. This is how an update is
   rolled back: every update makes a backup first, and the Installed apps page offers *Roll back this update…*;
5. configuration folders are copied back; the app is started and checked.

Folders you chose (media, photos, recordings), routes, Cloudflare and authentik settings are never touched. Adopted
projects are not restored by the manager (it did not create their data).

## Interrupted installations

An installation is registered before its files are written (`installState: writing`) and marked complete once every
file is there. If the manager stops in between, the Installed apps page shows *Installation interrupted* instead of an
orphaned folder: it cannot be started or updated, and *Discard…* removes the files the manager generates (Compose
files, `.env`, README, `dtc-stack.json`, credentials), any containers of the project and the record. Data volumes and
the folder are kept when they hold anything else. Then install again from the catalog.

## Host compatibility

Every installation preview (and every catalog card) checks the manifest against what Docker reports on this PC:

- **CPU architecture**: `architectures` lists the platforms every image of the stack is published for (the
  intersection, read from the registries' manifest lists); an app without the host's architecture cannot be installed;
- **GPU**: requested GPU access needs an NVIDIA driver on Windows (`nvidia-smi`); with it, GPU access through WSL2 is
  reported as experimental;
- **host devices** (`/dev/...`) are reported as unavailable in Docker Desktop;
- **Docker Engine and Compose**: Compose v2 is required; both versions are shown;
- memory, disk, ports, volumes, the shared network and existing installations, as before.

Shared manifests carry no Windows-specific values: host paths, ports and the proxy network come from the plan, and
`limitations` lists what is limited on *this* host (Docker Desktop on Windows) in words.

## Existing installations in the catalog

Before anything is offered, the catalog page inspects this PC read-only (`docker inspect` of every container) and puts
on each card what it finds: installations managed here (**Managed here**: *Manage*), Compose projects that run the
application but were made elsewhere (**Detected on this PC**: *Review and adopt*, never a plain *Install*), and
containers started without Compose (*Inspect and route*: they can be routed but not adopted, because adoption manages a
Compose project). An application is recognized by the manager's label or by the image of its own web service
(plus `identifiedBy`); an image that is only a dependency (PostgreSQL inside MediaFusion, Prowlarr next to it) never
makes a project an installation of anything else. Disposable test deployments are ignored. Installing anyway needs the
explicit *Install another, separate instance* choice; adoption keeps the containers, files and data as they are and
records only what the manager will operate (start, stop, logs, backup, routing). The state filter shows *Available*,
*Already installed* (managed or detected), *Managed here*, *Detected on this PC*, *Requires manual setup* and *Not
supported on this PC*. Retired entries (Watchtower) appear only while an installation of them exists.

## Headless applications

An app without a web interface (`web.headless: true`, e.g. Diun) has no primary port, no local port and no route. Its
health is its containers' state and health checks; the installation wizard says there is nothing to publish.

## Applications, variants and installed instances

An **application** (e.g. Rocket.Chat) has one canonical id (`rocketchat`) that is not its display name, Compose project
name, folder, container name or hostname. `aliases` lists earlier ids and other spellings (`rocket-chat`); ids,
aliases and names are compared ignoring case, dashes and dots, so `Rocket.Chat`, `rocket-chat` and `rocketchat` are
the same application, and two manifests may not claim the same one. A **variant** (`variantOf`, `variant.label`,
`variant.reason`), e.g. Dispatcharr's modular compose, installs the same application in another topology and is shown
under it, not as another product. `choiceGroup` marks alternatives (Arcane, recommended, or Portainer: one is enough).
`availability` is `offered` (default), `reference` (building blocks such as PostgreSQL) or `retired` (Diun,
Watchtower: never offered again, kept so existing installations are still recognized).

An **installed instance** is one deployment of an application: `config\apps.json` records its `instanceId`, the manifest
(`appId`, resolved through aliases), the Compose project, folder, optional `label` (e.g. Production, Testing), `origin`
(`installed` by the manager, or `adopted`), `archived`, and the fingerprint of the generated `compose.yaml`. Records
written before instance ids get a stable id (`legacy-<project>`); nothing is rewritten.

- **Duplicate detection.** Before an installation, the plan lists existing installations of the same application:
  registered instances (any alias or variant), archived records, and unregistered Compose projects recognized by the
  manager's `org.traefik-proxy.app` label or by the image of the application's own web service. Dependency images never
  count (a PostgreSQL or MongoDB container inside another app identifies nothing; nor does a proxy deployment's test
  backend). The plan is blocked until you manage, adopt or archive the existing one, or explicitly choose
  **Install another, separate instance** (with its own project, folder, volumes, port and optional label).
- **Archive record** hides an obsolete record (only when none of its containers runs). Nothing else changes: folder,
  containers, volumes, routes, Cloudflare and authentik stay; *Restore* brings the record back.
- **Adopt** registers a recognized, unregistered Compose project after a review; its file may have any of the standard names (`compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`, picked in that order, as docker compose does) and is recorded as `composeFile`. Nothing in it changes; the manager
  never deletes an adopted project's data or files.
- **Remove** first shows an inventory: containers, data volumes (volumes also used by other containers are never
  deleted), networks (the shared proxy network and networks of other projects are kept), generated files, and the
  Cloudflare and authentik references it leaves unchanged. Deleting data needs the project name typed again.

## Service lifecycle (status of a Compose application)

A Compose application may run long-running services (application, database, cache, message bus, workers) and
one-time jobs (permissions, database initialization, migrations) that exit when done. The Installed apps page counts
them separately, e.g. Rocket.Chat: **3/3 running · 2 setup jobs completed** (not "running 3/5"). The role of each
service comes from, in order: the manifest (`role`: `app`, `database`, `cache`, `messaging`, `worker`, `support`,
`proxy`, `init`, `migration`, `maintenance`; optional `lifecycle`, `label`, `purpose`); another service waiting for it
with `depends_on: service_completed_successfully`; a restart policy that keeps it running (`always`,
`unless-stopped`); a health check; another service waiting for it to start or be healthy; the restart policy
`on-failure` (marked as inferred). Otherwise the role is unknown and an exit code 0 is reported neutrally, never as a
completed job.

| Status | Meaning |
| --- | --- |
| Running, healthy | Its health check passes |
| Running; no health check | The container runs; readiness is not verified (e.g. NATS) |
| Completed successfully | A one-time job exited with code 0 |
| Failed | A one-time job exited with an error: the app's status becomes a problem |
| Stopped unexpectedly | A long-running service exited while the app should run |
| Stopped | The whole app was stopped |
| Prepared, not started / No container | Nothing created yet, or removed |
| Optional, not enabled | An optional service this installation left out |
| Exited (code 0); role unknown | Nothing says whether it should keep running |

The status opens the details: every service with its role (and where that comes from), image (tag and digest), state,
health check, exit code and whether exiting was expected, dependencies in both directions and its logs; the networks
it is on with the other containers there and their DNS names; published ports; data volumes; hostnames, Cloudflare
and authentik references. No environment values or commands are read. **Tidy up completed setup containers** removes,
after a preview and a confirmation, only containers of jobs whose role is declared (manifest or Compose) and that
exited with code 0; the Compose definitions, volumes and data stay, nothing else is stopped or recreated, and Compose
creates the jobs again the next time the app starts.

## DTC Manifests (foundation for community and generated manifests)

A **DTC Manifest** (`catalog\apps\<id>.json`) describes an application deployment: identity (`id`, `aliases`,
`manifestVersion`, publisher/`maintainer`, `source`), platforms, images, supporting services and their roles, storage,
inputs and generated secrets, health checks, networking, the web port, exposure (Traefik, Cloudflare, authentik) and
update notes. The Docker services themselves are generated as an ordinary `compose.yaml`; the manifest does not replace
Compose. `source.type` is `curated`, `community` or `generated`; all three pass through the same validation
(`Test-AppManifest`) and the same plan, preview and confirmation. In this version only curated manifests are
installable; there is no public registry, voting, moderation or AI builder yet.

## Installation groups and resources

Install one application at a time (heavy ones such as Immich, Rocket.Chat, Nextcloud and Paperless-ngx only with
several GB free). The catalog page
shows free Docker and Windows memory and disk; every installation checks the app's estimate against the lower of
Docker's and Windows' free memory and refuses to start an app that does not fit. **Prepare only** writes the complete
project (files, secrets, credentials) without downloading or starting anything; *Start* on the Installed apps page
checks memory again, downloads the pinned images and runs the app's first-start steps.

## Updates

- *Updates* compares the installed images with the catalog and asks the registry whether the same tag now points to a
  newer build (notification; nothing is pulled).
- Applying an update first backs up the configuration and data volumes (apps with a database are stopped for a
  consistent copy), saves `compose.yaml.bak-<time>`, changes only image lines, and recreates the containers.
- Database services never change major version through this path; their upgrades follow the application's own
  documented procedure.
- Watchtower and Diun are no longer offered; What's Up Docker provides notifications; nothing updates unattended.
- An update preview says when `compose.yaml` was changed outside the manager (Arcane, Portainer, an editor) since it
  was written here (`composeSha256` in `config\apps.json`); the update then needs an explicit confirmation and changes
  only the image lines, keeping those edits.

## Backups, removal and data

- *Back up*: `compose.yaml`, `.env`, configuration folders and named volumes (as `.tar.gz`), into `backups/<time>/`.
  Media libraries, model caches and recordings are not copied (they are your data, not configuration).
- *Remove* removes containers only; deleting data volumes or the generated files requires typing the project name.
  Folders you chose (media, photos, recordings) and earlier backups are never deleted. Removal is refused while a
  service route still points at the app.

## Networks

- The shared proxy network (`proxynet` on this PC) carries only the web front end of each app, which Traefik must reach.
- Databases, caches, brokers, workers and socket proxies join the app's private `<project>_internal` network only.
- An app whose `web.proxy` is `false` (LLDAP) never joins the shared network.
- The website refuses to attach a database, cache, broker or directory container to the shared network.
- `scripts\Get-NetworkAudit.ps1` is a read-only audit. It shows:
  - which project owns each container and network;
  - networks in use, needed only by stopped containers, or unused;
  - Docker networks overlapping the LAN, which capture traffic to LAN targets such as a device behind Traefik;
  - ports published on all interfaces.

  It never prunes or removes anything.

## Homepage configuration

`scripts\Update-HomepageConfig.ps1 -ProjectPath <deployment>` previews, and with `-Apply` writes, these Homepage files:

- `services.yaml`: cards grouped as Infrastructure, Monitoring, Identity, Media, Communication and Other services. They cover:
  - the Traefik dashboard (status and the read-only Traefik widget);
  - the Deployment Manager;
  - the Cloudflare Tunnel (link only: its status is not checkable without an API token);
  - every installed app;
  - selected not-installed apps;
  - services published through Traefik.
- `bookmarks.yaml`: public addresses, listed only when the Cloudflare edge answers and Traefik routes the hostname to a working backend.
- `widgets.yaml`: the Docker VM's CPU, memory and disk.
- `settings.yaml`: a compact layout.

How the files are written:

- Running apps link to their local URL and are checked over the shared network.
- Prepared, stopped and not-installed apps get no link and no status check, so they never appear healthy.
- Generated text sits between `# BEGIN Deployment Manager` and `# END Deployment Manager`; everything else is kept as written.
- A card whose name you already use outside the block is not generated again.
- The `services.yaml` written at installation is taken over as a whole.
- Previous files go to `backups\homepage-config-<time>\` in the Homepage folder.
- Homepage reloads the files itself, so nothing is restarted.
- No secrets or API keys are written.

## Manifest (`catalog\apps\<id>.json`, schema 1)

| Field | Meaning |
| --- | --- |
| `id`, `name`, `description`, `category`, `group`, `maintainer`, `license`, `source`, `docs` | Identity; `docs` are https links |
| `platforms` | `windows-docker-desktop`, `linux-docker`, `unraid`, `podman`: `supported`, `limited`, `untested` or `unsupported` |
| `architectures` | CPU architectures every image of the stack is published for (`amd64`, `arm64`, `arm/v7`, ...); required for curated installable manifests |
| `authentication` | `forwardAuth`: `compatible`, `caution` (own clients/APIs that ForwardAuth would block), `unsuitable`, `not-applicable` (identity providers, headless apps); `native` sign-in methods; `notes` (WebSockets, mobile apps, callbacks); required for curated installable manifests |
| `limitations` | Known limitations on the current host (Docker Desktop on Windows), in words |
| `installable`, `installNote`, `deprecated`, `deprecationNote`, `alternatives` | Listed-only entries explain why |
| `manifestVersion`, `aliases`, `variantOf` + `variant`, `choiceGroup`, `availability` + `retired` | Identity, variants, alternatives and whether new installations may use it (see above) |
| `services.<name>` | `image` (`name:tag@sha256:...`), `role`, `lifecycle`, `label`, `purpose`, `ports` (one `primary`), `volumes` (`volume` [optionally replaced by a chosen folder], `folder`, `project` [relative folder], `tmpfs`; `readOnly`, `backup`), `environment`, `command`, `entrypoint`, `user`, `dependsOn`, `healthcheck`, `shmSize`, `stateful`, `when` (boolean input), `proxy`, `dockerSocket`, `dockerSocketReadOnly`, `networkMode: host`, `devices`, `gpus` (true or a boolean input), `privileged`, `resources` |
| `inputs` | `text`, `secret`, `generated` (random hex), `password` (sign-in password, generated if empty, saved to credentials.txt), `folder`, `timezone`, `boolean`, `derived` (`authelia-argon2`) |
| Templates | `{{input:<id>}}`, `{{service:<name>}}`, `{{project}}`, `{{appUrl}}`, `{{timezone}}`, `{{webPort}}`, `{{localPort}}`, `{{traefikContainer}}`, `{{proxyNetwork}}`, `{{domains}}`; in files also `{{installedApps}}` |
| `files` | Created once in the project folder (`secret: true` = restricted ACL) |
| `postInstall` | First-start steps: `command` (docker exec) or `http` (POST to the app on 127.0.0.1, optional `tokenFromLog`) |
| `privileges` | `docker-socket`, `host-network`, `device`, `gpu`, `privileged`, with an explanation the user confirms |
| `web` (`service`, `localPort`, `status`, `proxy`: false keeps the app off the shared network, `headless`: no web interface), `exposure` (`default`, `allowPublic`, `warning`), `resources`, `security`, `update` (required) | |
| `services.<name>.component` | Optional: the Compose file of a modular stack (`compose.<component>.yaml`); default from the role |
| `services.<name>.ports[].publish` | Optional extra host port, off unless chosen: `hostPort`, `address` (`local` = 127.0.0.1, `lan` = every interface; `lan` must be opt-in with `when`), `when` (boolean input), `input` (text input holding the host port). The plan checks the port (TCP or UDP) is free; `dtc-stack.json` lists it under `publishedPorts` |
| `identifiedBy` | Other image repositories of the same application (e.g. the LinuxServer.io Plex image), so an existing installation made from them is recognized |
| `testStatus` | What was demonstrated: `static` (`passed`/`not-run`), `live` (`passed`, `partial`, `not-run`, `failed`), `date`, `notes`. Shown on the card ("Live-tested" or "Static checks only") |
| `manualSetup` | Steps the user does in the app itself (claim token, first administrator, setting the published address); shown before installing and filterable as *Requires manual setup* |
| `website` | The project's home page (optional) |

`tests\Test-AppLifecycle.ps1` covers identity, lifecycle, instances, duplicates, archiving, removal inventories,
interrupted installations and a small disposable Compose project; `tests\Test-AppsBrowser.ps1` the catalog and
Installed apps pages in headless Edge. `tests\Test-Catalog.ps1` validates every manifest, generates every installable
project and runs `docker compose config` on it (also as the modular file set through plain `docker compose` with
`COMPOSE_FILE`, with the shared-network, secret and route checks), and exercises the lifecycle with fixture apps on a disposable instance
(modular two-file stack, backup, restore, update rollback, stack view). `tests\Test-CatalogInstall.ps1 -Apps ...`
installs real catalog applications one at a time on a disposable proxy deployment: plan, install, health, the app's own
API or log, network isolation, the stack on disk, stop/start, an explicit Traefik route through the disposable
Traefik, the routing view, backup and restore, removal with data, and (with `-Cloudflare`) the publication preview
against the mock Cloudflare API.
It checks free memory before each application (and memory and system-drive space before it starts) and skips what does
not fit, reported as SKIP rather than forced.

These four suites register their run prefix (`tpx-ci-<id>`, `tpx-ct-<id>`, `tpm-alc-<id>`, ...) with its process
ID and sweeps first: containers, volumes, networks and the `%TEMP%` folder of an earlier run whose process is gone (killed
for low memory, closed window) are removed before anything new is created. `tests\Find-TestOrphans.ps1` lists such
leftovers (`-Remove` removes them; prefixes without an ownership record need `-IncludeUnregistered`). Only names with a
disposable test prefix are considered, and a network or volume still used by anything outside that prefix is kept.

## Sources (architecture)

| Source | Status | Treatment |
| --- | --- | --- |
| Curated first-party manifests | Implemented | Installable from the catalog (highest trust) |
| GitHub Compose repositories and files | Implemented (New app page) | Imported as a draft manifest (`source.type: imported`), reviewed, then installed through the same installer; never executed automatically |
| Docker Hub, GitHub Container Registry, Quay, lscr.io | Implemented (New app page) | Draft from the README's Compose example or the image configuration; open questions instead of guesses |
| Unraid Community Applications XML | Implemented (New app page) | Template links (raw XML) translated into a draft; no undocumented endpoint, no Unraid code; plugins refused |
| awesome-selfhosted | Implemented (New app page) | Discovery index: the entry's source repository is imported, attribution kept |
| Your own Compose file | Implemented (adoption) | Adopted as an external project: discovered and publishable, managed only with permission |

Imported manifests are never written to `catalog\apps` (catalog files must be curated to be installable); see
[provisioning.md](provisioning.md) for the engine, the security review and the identity contract.
