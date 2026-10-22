# App Catalog

The App Catalog installs curated applications as ordinary Docker Compose projects, one project per application,
each in its own folder next to the proxy deployment (e.g. `%USERPROFILE%\.docker\projects\uptime-kuma`):

- `compose.yaml`: images pinned by tag and digest, the shared proxy network (external) for the web service only,
  a private network for the app's other services (databases, caches), named volumes (`<project>_<name>`) or folders
  you chose, `no-new-privileges`, log rotation, labels `org.traefik-proxy.app` / `org.traefik-proxy.project`.
  Secrets appear only as `${VAR}`.
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
registry metadata on 2026-10-21. RAM figures are the manager's planning estimates.

| Group | App | Image (pinned) | Local URL (127.0.0.1) | Dependencies | Notes |
| --- | --- | --- | --- | --- | --- |
| A | Traefik Manager | `ghcr.io/chr0nzz/traefik-manager:1.15.4` | :5000 | the existing Traefik API (read-only) | No Docker socket; its routes stay in its own `config/routes` until an ownership plan is approved; admin password set via its own `flask reset-password` |
| A | Uptime Kuma | `louislam/uptime-kuma:2.5.6` | :3001 | | SQLite in a volume; create the admin on first visit |
| A | Portainer CE | `portainer/portainer-ce:2.45.2` (LTS) | https :9443 | Docker socket | Admin created right after start (setup token from its log); never public |
| A | Homepage | `ghcr.io/gethomepage/homepage:v2.6.0` | :3010 | | First `services.yaml` lists installed apps (links + HTTP status); no Docker socket |
| A | Arcane | `getarcaneapp/manager:v2.16.1` | :3552 | Docker socket | Never public |
| A | HTTP echo | `traefik/whoami:v1.12.0` | :18080 | | For testing routes, tunnel and Access |
| B | authentik | `ghcr.io/goauthentik/server:2026.8.5` (server + worker) | :9000 | PostgreSQL 16 (`postgres:16-alpine`) | No Redis (removed in 2025.10); initial setup at `/if/flow/initial-setup/`; LDAP not required |
| B | Authelia | `authelia/authelia:4.39.28` | :9091 | | File-backed users (argon2 hash computed by Authelia), secrets as files; needs a real domain and HTTPS; protects apps only once a forwardAuth middleware is added |
| B | LLDAP | `lldap/lldap:v0.6.3` | :17170 (LDAP 3890 internal only) | | The installable directory; OpenLDAP itself is listed only (see below) |
| C | Jellyfin | `jellyfin/jellyfin:12.2.20261005-225228` | :8096 | | Up to three read-only library folders; optional NVIDIA GPU (experimental on Docker Desktop); local only by default |
| C | Dispatcharr | `ghcr.io/dispatcharr/dispatcharr:0.32.0` (all-in-one) | :9191 | embedded PostgreSQL/Redis | Tuners added by URL (no SSDP through Docker Desktop) |
| C | Dispatcharr (modular) | same image, web + celery | :9192 | `postgres:17`, Valkey 9.1 | Advanced option of the official modular compose |
| C | Channels DVR | `fancybits/channels-dvr:latest` (digest) | :8089 | | Limited on Docker Desktop (no Bonjour, no `/dev/dri`, tuners by IP); subscription; native Windows server recommended |
| D | Immich | `ghcr.io/immich-app/immich-server:v3.3.5` + machine learning (optional) | :2283 | `immich-db` (`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`), `immich-redis` (Valkey 9) | 6-8 GB RAM recommended; database must be a Docker volume on Windows; library in a volume or a chosen folder |
| D | Rocket.Chat | `registry.rocket.chat/rocketchat/rocket.chat:8.9.0` | :3100 | MongoDB 8.2 (official `mongodb-community-server`, replica set), NATS 2.11 | Monitoring stack of the official compose left out; MongoDB never published |
| E | What's Up Docker | `getwud/wud:9.5.0` | :3200 | read-only Docker socket proxy (`tecnativa/docker-socket-proxy:v0.5.0`) | Notification only (no update trigger) |
| - | OpenLDAP | listed | | | osixia 1.5.0 is from 2021, v2 is beta; free Bitnami images are gone |
| - | PostgreSQL, Redis/Valkey | listed | | | Bundled inside the apps that need them; never shared or published |
| E | Diun | listed | | | Headless; What's Up Docker preferred |
| E | Watchtower | listed, deprecated | | | Archived (2025-12), fails on current Docker; unattended updates are disabled |

## Installation groups and resources

Install one group at a time (A: management, B: identity, C: media, D: heavy services, E: updates). The catalog page
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
- Watchtower is not offered; What's Up Docker (or Diun) provide notifications; nothing updates unattended.

## Backups, removal and data

- *Back up*: `compose.yaml`, `.env`, configuration folders and named volumes (as `.tar.gz`), into `backups/<time>/`.
  Media libraries, model caches and recordings are not copied (they are your data, not configuration).
- *Remove* removes containers only; deleting data volumes or the generated files requires typing the project name.
  Folders you chose (media, photos, recordings) and earlier backups are never deleted. Removal is refused while a
  service route still points at the app.

## Manifest (`catalog\apps\<id>.json`, schema 1)

| Field | Meaning |
| --- | --- |
| `id`, `name`, `description`, `category`, `group`, `maintainer`, `license`, `source`, `docs` | Identity; `docs` are https links |
| `platforms` | `windows-docker-desktop`, `linux-docker`, `unraid`, `podman`: `supported`, `limited`, `untested` or `unsupported` |
| `installable`, `installNote`, `deprecated`, `deprecationNote`, `alternatives` | Listed-only entries explain why |
| `services.<name>` | `image` (`name:tag@sha256:...`), `ports` (one `primary`), `volumes` (`volume` [optionally replaced by a chosen folder], `folder`, `project` [relative folder], `tmpfs`; `readOnly`, `backup`), `environment`, `command`, `entrypoint`, `user`, `dependsOn`, `healthcheck`, `shmSize`, `stateful`, `when` (boolean input), `proxy`, `dockerSocket`, `dockerSocketReadOnly`, `networkMode: host`, `devices`, `gpus` (true or a boolean input), `privileged`, `resources` |
| `inputs` | `text`, `secret`, `generated` (random hex), `password` (sign-in password, generated if empty, saved to credentials.txt), `folder`, `timezone`, `boolean`, `derived` (`authelia-argon2`) |
| Templates | `{{input:<id>}}`, `{{service:<name>}}`, `{{project}}`, `{{appUrl}}`, `{{timezone}}`, `{{webPort}}`, `{{localPort}}`, `{{traefikContainer}}`, `{{proxyNetwork}}`, `{{domains}}`; in files also `{{installedApps}}` |
| `files` | Created once in the project folder (`secret: true` = restricted ACL) |
| `postInstall` | First-start steps: `command` (docker exec) or `http` (POST to the app on 127.0.0.1, optional `tokenFromLog`) |
| `privileges` | `docker-socket`, `host-network`, `device`, `gpu`, `privileged`, with an explanation the user confirms |
| `web` (`service`, `localPort`, `status`), `exposure` (`default`, `allowPublic`, `warning`), `resources`, `security`, `update` | |

`tests\Test-Catalog.ps1` validates every manifest, generates every installable project and runs
`docker compose config` on it, and exercises the lifecycle with fixture apps on a disposable instance.

## Sources (architecture)

| Source | Status | Treatment |
| --- | --- | --- |
| Curated first-party manifests | Implemented | Installable |
| GitHub Compose repositories | Planned | Imported as a draft manifest for review; never executed automatically |
| Docker Hub, GitHub Container Registry | Planned | Image discoveries only, not installable templates by themselves |
| Unraid Community Applications XML | Planned | Compatible templates imported into a draft manifest; no undocumented endpoint, no Unraid code |
| Your own Compose file | Planned | Adopted as an external project: discovered and publishable, managed only with permission |
