# App Catalog inventory (2026-11-17)

Every curated application, what the catalog does with it, and what has actually been demonstrated. Tested on
**Windows 11 with Docker Desktop (WSL2)** only; other platforms are recorded as *untested* in each manifest.

- **Live install: Passed** means `tests\Test-CatalogInstall.ps1` installed exactly the pinned images on a disposable
  proxy deployment (own project, network, ports and folder; production untouched) and ran the whole lifecycle: plan
  with host compatibility, install, health, the application's own API or log, network isolation, the modular stack on
  disk (`dtc-stack.json` without secrets, plain `docker compose` with `COMPOSE_FILE`), stop/start, an explicit Traefik
  file-provider route through the disposable Traefik, backup and restore of its data, and removal with its data.
- **Static checks: Passed** means `tests\Test-Catalog.ps1` validated the manifest, generated its file set, ran
  `docker compose config` on it, checked that only the web front end joins the shared proxy network, that no secret is
  in any Compose file or `dtc-stack.json`, and that its Traefik file-provider route points at its Docker DNS name.
  A statically validated app has **not** been shown to install or run.
- **On this PC** is a read-only inspection of the Compose projects and containers on this PC on 2026-11-17. Installed
  applications are offered for management or adoption on their catalog card, never installed a second time silently.

Summary: 36 manifests; 30 installable applications (plus the HTTP echo test app and one variant),
1 listed with manual setup (Shinobi), 2 building blocks (PostgreSQL, Redis/Valkey) and 1 retired entry
(Watchtower). Live-tested in full: Arcane, Authelia, Channels DVR Server, CrowdSec (detection), Dispatcharr, Dispatcharr (modular), Diun, Dozzle, File Browser, Gitea, HFS (HTTP File Server), Homepage, Immich, Jellyfin, LLDAP (directory), Mealie, MediaFusion, Nextcloud, OpenLDAP, Paperless-ngx, Pi-hole, Plex Media Server, Portainer CE, Rocket.Chat, RomM, Traefik Manager, Uptime Kuma, Vaultwarden, What's Up Docker, n8n. Partly live-tested: authentik. Statically validated only: none.

### A. Docker management, infrastructure and monitoring

| Application | Pinned version | Dependencies (own stack) | On this PC (read-only check) | Catalog status | Windows (Docker Desktop) | Sign-in | Static checks | Live install | Backup/restore | Known limitations |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Arcane | `getarcaneapp/manager:v2.16.1` | - | Installed, managed (arcane, v2.16.1) | Installable | supported | ForwardAuth OK | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Needs the Docker socket (full control of Docker on this PC). |
| CrowdSec (detection) | `crowdsecurity/crowdsec:v1.8.2` | docker-socket-proxy:v0.5.0 | Not installed | Installable | supported | n/a (no web sign-in) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Firewall bouncers (iptables/nftables) cannot protect a Windows host through Docker Desktop; blocking would have to happen in Traefik.; HTTP scenarios need Traefik's access log on its standard output; without it CrowdSec sees only Traefik's own messages. |
| Diun | `crazymax/diun:4.33.1` | docker-socket-proxy:v0.5.0 | Not installed | Installable | supported | n/a (no web sign-in) | Passed | Passed (2026-11-16) | Tested (backup, restore, app works after) | Reads Docker through a read-only socket proxy; it notifies only and never pulls or updates anything.; Without a notifier configured in config/diun.yml, results appear only in its log. |
| Dozzle | `amir20/dozzle:v11.4.3` | docker-socket-proxy:v0.5.0 | Not installed | Installable | supported | ForwardAuth OK | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Shows the containers of this PC only (one Docker host). |
| Homepage | `ghcr.io/gethomepage/homepage:v2.6.0` | - | Installed, managed (homepage) | Installable | supported | ForwardAuth OK | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Resource widgets show the Docker Desktop VM, not Windows. |
| Pi-hole | `pihole/pihole:2026.11.0` | - | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Docker Desktop puts DNS clients behind its network proxy: queries may all appear to come from one address, so per-device statistics and DHCP do not work.; Port 53 can be in use on Windows (Internet Connection Sharing, Hyper-V DNS proxy); the plan checks it before installing. |
| Portainer CE | `portainer/portainer-ce:2.45.2` | - | Installed, managed (portainer) | Installable | supported | ForwardAuth OK | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Needs the Docker socket (full control of Docker on this PC).; Uses a self-signed HTTPS certificate on its local port. |
| Traefik Manager | `ghcr.io/chr0nzz/traefik-manager:1.15.4` | - | Installed, managed by the production manager (project traefik-manager) | Installable | supported | ForwardAuth OK | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | - |
| Uptime Kuma | `louislam/uptime-kuma:2.5.6` | - | Installed, managed (uptime-kuma) | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-16) | Tested (backup, restore, app works after) | - |
| What's Up Docker | `getwud/wud:9.5.0` | docker-socket-proxy:v0.5.0 | Registered (whats-up-docker) but no containers on this PC | Installable | supported | ForwardAuth OK | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Reads Docker through a read-only socket proxy; it reports updates but never applies them here. |

### B. Sign-in, passwords and directories

| Application | Pinned version | Dependencies (own stack) | On this PC (read-only check) | Catalog status | Windows (Docker Desktop) | Sign-in | Static checks | Live install | Backup/restore | Known limitations |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Authelia | `authelia/authelia:4.39.28` | - | Installed, managed (authelia) | Installable | supported | n/a (no web sign-in) | Passed | Passed (2026-11-16) | Tested (backup, restore, app works after) | Session cookies need a real domain with HTTPS: it protects apps only after a public or LAN hostname is configured. |
| authentik | `ghcr.io/goauthentik/server:2026.8.5` | server:2026.8.5, postgres:16-alpine | Installed, managed (authentik; Identity & Access, Google sign-in) | Installable | supported | n/a (no web sign-in) | Passed | Partial (2026-11-19) | Not reached | - |
| LLDAP (directory) | `lldap/lldap:v0.6.3` | - | Installed, managed (lldap) | Installable | supported | n/a (no web sign-in) | Passed | Passed (2026-11-16) | Tested (backup, restore, app works after) | The LDAP port is not published: only containers on its private network, or clients you connect explicitly, can use it. |
| OpenLDAP | `ghcr.io/intechcore/openldap:2.6.16-6` | - | Not installed | Installable | supported | n/a (no web sign-in) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | The container comes from a small vendor (intechcore) that packages the official Symas OpenLDAP 2.6 LTS builds; osixia/openldap is unmaintained and the free Bitnami images were withdrawn.; No web interface: manage entries with LDAP tools (ldapadd, Apache Directory Studio) or use LLDAP for a simpler directory with a web interface. |
| Vaultwarden | `vaultwarden/server:1.37.5` | - | Not installed | Installable | supported | Not with ForwardAuth | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Over plain http on a LAN address or hostname, the web vault refuses to sign in; use http://127.0.0.1 locally or publish it with HTTPS.; Bitwarden clients need version 2026.7.0 or later for Vaultwarden 1.37. |

### C. Media and personal libraries

| Application | Pinned version | Dependencies (own stack) | On this PC (read-only check) | Catalog status | Windows (Docker Desktop) | Sign-in | Static checks | Live install | Backup/restore | Known limitations |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Channels DVR Server | `fancybits/channels-dvr:latest` | - | Installed, managed (channels-dvr) | Installable | limited | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Docker Desktop has no Bonjour/mDNS from the LAN: Channels apps must be pointed at the server by IP.; No /dev/dri: hardware transcoding is not available in Docker Desktop. |
| Dispatcharr | `ghcr.io/dispatcharr/dispatcharr:0.32.0` | - | Installed, managed (dispatcharr) | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | SSDP/HDHomeRun discovery from LAN devices does not reach containers on Docker Desktop: add tuners and clients by URL. |
| Dispatcharr (modular) | `ghcr.io/dispatcharr/dispatcharr:0.32.0` | dispatcharr:0.32.0, postgres:17, valkey:9.1.2-alpine | Not installed | Variant of Dispatcharr | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | SSDP/HDHomeRun discovery from LAN devices does not reach containers on Docker Desktop: add tuners and clients by URL. |
| Immich | `ghcr.io/immich-app/immich-server:v3.3.5` | immich-machine-learning:v3.3.5 (optional), valkey:9, postgres:14-vectorchord0.4.3-pgvectors0.2.0 | Installed, managed (immich) | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | The PostgreSQL database must be on a Docker volume (not a Windows folder) on Docker Desktop.; Machine learning runs on the CPU (no CUDA/OpenVINO variant is offered here) and needs about 2 GB of extra memory. |
| Jellyfin | `jellyfin/jellyfin:12.2.20261005-225228` | - | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Hardware transcoding: only NVIDIA GPUs through WSL2 (experimental); Intel Quick Sync and VA-API (/dev/dri) are not available in Docker Desktop.; DLNA and client auto-discovery do not cross the Docker Desktop VM. |
| MediaFusion | `mhdzumair/mediafusion:6.2.0` | mediafusion:6.2.0, postgres:18-alpine, valkey:9 | Detected: hand-made Compose project `docker-compose` (MediaFusion 6.1.3 + PostgreSQL 18 + Redis + Prowlarr); offered for adoption, not reinstalled | Installable | supported | Not with ForwardAuth | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Results stay sparse for the first hour while the background scrapers fill the database.; Changing the secret key later invalidates every add-on link already installed in Stremio. |
| Plex Media Server | `plexinc/pms-docker:1.43.5.11079-b3b13e506` | - | Not installed | Installable | supported | Not with ForwardAuth | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Plex does not recommend Docker on Windows; this keeps its database in a Docker volume inside WSL2, which avoids the file-locking problem.; Local discovery (GDM, DLNA) needs multicast, which Docker Desktop does not pass: apps may need the server address entered or found through plex.tv. |
| RomM | `rommapp/romm:5.4.1` | mariadb:11.8 | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Large libraries on a Windows drive are read through Docker Desktop file sharing: scans are slower, and new files may not be noticed automatically (scan manually). |

### D. Productivity, files and communication

| Application | Pinned version | Dependencies (own stack) | On this PC (read-only check) | Catalog status | Windows (Docker Desktop) | Sign-in | Static checks | Live install | Backup/restore | Known limitations |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| File Browser | `filebrowser/filebrowser:v2.63.23` | - | Not installed | Installable (deprecated upstream) | supported | ForwardAuth OK | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Archived upstream: no further releases or security fixes.; Folders on Windows drives are accessed through Docker Desktop file sharing and are slower than Docker volumes. |
| Gitea | `gitea/gitea:28.4.0` | postgres:18-alpine | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Port 22 on Windows is usually taken; SSH uses 2222 by default.; Real-time notifications use WebSockets: the route must allow them (Traefik does by default). |
| HFS (HTTP File Server) | `rejetto/hfs:v3.4.1` | - | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | Folders on Windows drives are read through Docker Desktop file sharing (slower than local disks). |
| Mealie | `ghcr.io/mealie-recipes/mealie:v3.31.0` | - | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | SQLite suits a household; for many concurrent users switch to PostgreSQL (not offered by this recipe). |
| n8n | `n8nio/n8n:2.48.4` | postgres:18-alpine | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | n8n 3.0 is in beta (one-way upgrade); this catalog stays on the 2.x stable line.; Webhook URLs use the address chosen at installation; after publishing it, set WEBHOOK_URL and N8N_EDITOR_BASE_URL in .env to the https address and restart. |
| Nextcloud | `nextcloud:34.0.6-apache` | nextcloud:34.0.6-apache, postgres:18-alpine, valkey:9 | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | User files stay in a Docker volume: Windows folders (NTFS) fail Nextcloud's ownership and permission checks and are slow through Docker Desktop.; Big uploads through Cloudflare are limited to 100 MB per request on free plans; the sync clients upload in chunks, browsers may not. |
| Paperless-ngx | `ghcr.io/paperless-ngx/paperless-ngx:3.4.2` | postgres:18-alpine, valkey:9, gotenberg:8.38 (optional), tika:3.3.1.0 (optional) | Not installed | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | On x86 the CPU needs SSE4.2 (any PC from the last decade).; Windows folders do not deliver file-change events into Docker: the inbox is polled every 10 seconds instead. |
| Rocket.Chat | `registry.rocket.chat/rocketchat/rocket.chat:8.9.0` | mongodb-community-server:8.2-ubi8, mongodb-community-server:8.2-ubi8, mongodb-community-server:8.2-ubi8, nats:2.11-alpine | Installed, managed (rocket-chat) | Installable | supported | ForwardAuth with care (own clients) | Passed | Passed (2026-11-17) | Tested (backup, restore, app works after) | MongoDB runs as a single-node replica set (no high availability).; Mobile push notifications need a Rocket.Chat Cloud registration. |

### E. Cameras and surveillance

| Application | Pinned version | Dependencies (own stack) | On this PC (read-only check) | Catalog status | Windows (Docker Desktop) | Sign-in | Static checks | Live install | Backup/restore | Known limitations |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Shinobi | `registry.gitlab.com/shinobi-systems/shinobi:dev` | - | Not installed | Listed, manual setup | supported | ForwardAuth with care (own clients) | Passed | - | - | Only moving tags (dev, latest) are published; a digest pin cannot be updated by version.; Camera discovery (ONVIF multicast) does not work through Docker Desktop; enter camera addresses manually. |

The HTTP echo test app (`traefik/whoami`, group A) is live-tested on every run and used for route, tunnel and Access
checks.

## Core infrastructure (not catalog applications)

| Component | Role | Notes |
| --- | --- | --- |
| Traefik | Reverse proxy of each deployment | Explicit file-provider routes (`traefik/dynamic/svc-<route>.yml`); catalog apps never use Docker labels. The production `compose.yaml` keeps its Docker provider setting; it is not changed by catalog work. |
| Cloudflared | Cloudflare Tunnel connector | Publication (DNS, tunnel route, Access) only after explicit approval; previews against the mock API in tests |
| Docker socket proxy | Read-only Docker API for apps that need it | Per app (What's Up Docker, Diun, Dozzle, CrowdSec), on the app's private network, POST/exec/delete refused |
| PostgreSQL, MariaDB, MongoDB, Valkey/Redis, NATS | Building blocks | Generated inside each application's own stack (own container, volume, credentials and private network); never shared between applications, never published |

## Not in the catalog

| Application | Status | Why |
| --- | --- | --- |
| Watchtower | Retired, not offered | Archived upstream; it updates containers unattended, which the manager does not do. Existing installations are still recognized and never removed. |
| Prowlarr, Sonarr, Radarr | Excluded | Not part of the curated collection; never offered or used as dependencies. A Prowlarr container that already runs (inside the hand-made MediaFusion project) is left alone. |

## Manual setup and host-specific notes

Each card lists its manual steps (*Requires manual setup* filter). The most important ones:

- **Plex**: claim token from https://www.plex.tv/claim/ right before installing (or finish setup from this PC); local
  discovery (GDM/DLNA) and Intel Quick Sync do not work through Docker Desktop; NVIDIA transcoding through WSL2 untested.
- **Pi-hole**: installing changes no DNS setting. DNS on port 53 is opt-in; Docker Desktop hides client addresses.
- **CrowdSec**: detection only; HTTP scenarios need Traefik's access log on standard output; blocking (a bouncer) is a
  separate, deliberate step.
- **Vaultwarden**: create your account, then turn sign-ups off; the web vault needs HTTPS (or http://127.0.0.1).
- **Nextcloud / Paperless-ngx / n8n**: after publishing on a hostname, set the published https address in `.env`
  (`overwriteprotocol`, `PAPERLESS_URL`, `WEBHOOK_URL`) and restart.
- **Mealie**: change the default administrator (changeme@example.com / MyPassword) immediately.
- **File Browser**: archived upstream (no security fixes); the generated admin password is in its log.
- **Shinobi**: not installable from the catalog (moving image tags only, MariaDB inside the app image, licence limits
  commercial use); install it with the official guide and adopt the Compose project.
- **Authelia**: installs and runs; using it as the ForwardAuth provider for other apps is not implemented (needs a real
  domain with HTTPS to verify).

## Known issues found in this round (2026-11-17)

- **authentik ForwardAuth re-protection (fixed 2026-11-17):** `tests\Test-IdentityLive.ps1` failed 8 of 116 checks after
  its "misroute" step (also on f989dbf). Cause: the manager assumed every protected application is at `https://<host>`.
  Protecting again rewrote the authentik provider from the deployment's real address (`http://<host>:<port>` on the
  test entry point) to `https://<host>`; authentik's outpost matches the forwarded Host, port included, against that
  address, so it answered 404 (passed through by Traefik ForwardAuth). The application address now follows the scheme
  and port of the public sign-in address (unchanged in production: `https://<host>`), in the provider, the routing view
  and every probe; apply also waits for the outpost to reload a corrected sign-in address. Verified live on 2026-11-19:
  the complete run passed every identity check (127 passed), including re-protection, the routing view, the outpost
  wait and rollback. Its one failure was the test harness: a second headless Edge received
  `--host-resolver-rules=MAP *.idtest.example 127.0.0.1` split at the spaces (Windows PowerShell's Start-Process does
  not quote arguments) and never opened DevTools, so 8 browser checks were not reached. With the arguments quoted
  they passed in `Test-IdentityLive.ps1 -BrowserOnly` (82 passed, 0 failed). Catalog backup/restore of authentik is
  still not run, hence "Partial".
- **Browser test harness (fixed 2026-11-19):** a DevTools reply that took longer than its timeout (an occasional
  full-page screenshot) cancelled the WebSocket receive, which closes the socket for good: every later browser command
  of that run failed. A timeout now leaves the receive pending and the session usable. `Test-UiBrowser.ps1` failed
  in the service wizard because it switched the detail level and used a field in the same step, before the page had
  re-rendered; it now waits for the field (71 passed, 0 failed).
- **Immich** was live-tested with machine learning off; the machine-learning service (about 2.5 GB) was not started.
- **Paperless-ngx** Gotenberg and Tika (optional office-document services) were not started.
- **Plex** was tested without a claim token and without GPU; claiming and hardware transcoding are not verified.

## Versions not adopted (2026-11-17)

Pinned versions are the ones validated here. Newer upstream releases seen on 2026-11-17 and not adopted: Rocket.Chat
9.0.0 (major: LDAP/SAML/custom OAuth become premium, several logins removed), Arcane 3.0.1 (major: requires 2.17.3
first, all settings renamed with an `ARCANE_` prefix, agents re-enrolled), Nextcloud 35 (not yet promoted to its
stable tag), Paperless-ngx 3.5.0 (released the same day), n8n 3.x (beta), RomM 5.5 (alpha), Uptime Kuma 2.5.11,
Homepage 2.8.0, Immich 3.4.1, Jellyfin 12.4, Dispatcharr 0.34.0, What's Up Docker 9.8.0, MediaFusion (the catalog pins
6.2.0; the existing hand-made installation runs 6.1.3 and is not changed).
