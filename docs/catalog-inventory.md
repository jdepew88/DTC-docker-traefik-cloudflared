# App Catalog inventory (2026-11-16)

Status of every requested application on the development branch, tested on **Windows 11 with Docker Desktop (WSL2)**
only. "Installed in isolation" means `tests\Test-CatalogInstall.ps1` installed the real catalog application on a
disposable proxy deployment (own stack, network, ports and folder; production untouched) and ran its whole lifecycle:
plan with host compatibility, install, health, the application's own API or log, network isolation, the stack on
disk (all Compose files, `dtc-stack.json` without secrets, plain `docker compose` with `COMPOSE_FILE`), stop/start, an
explicit Traefik file-provider route through the disposable Traefik with the per-app routing view, backup + restore
(where it has data), and removal with its data. "Compose-validated" means the generated file set passed
`docker compose config` (tests\Test-Catalog.ps1) but the application was not started in this round.

Versions are the pins of 2026-10-21/11-16 (tag and digest). Newer upstream releases found on 2026-11-16 are listed
under *Remaining*; they were not adopted because the pinned images are the ones tested here, and most of them are
already on this PC (the system drive has about 8 GB free, so no large downloads were made).

## Applications

Compose files: the modular file set the manager writes (`compose.yaml` plus one `compose.<component>.yaml` per further
component). Sign-in fit: how authentik ForwardAuth suits the app (`compatible`; `caution`: own clients, APIs or
webhooks that a browser sign-in would block; `not-applicable`: identity providers and apps without a web interface).

| Group | Application | Pinned version | Compose files | Sign-in fit | Status (2026-11-16) | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| A | HTTP echo (whoami) | traefik/whoami v1.12.0 | 1 | compatible | **Installed in isolation**, whole lifecycle, incl. the Cloudflare publication preview (mock API: DNS, tunnel route and Access planned, nothing written) | Test fixture app. |
| A | Uptime Kuma | 2.5.6 | 1 | caution | **Installed in isolation** (entry-page API, Traefik route, backup + restore) | First administrator and monitors are set up in the app. Status pages and push monitors must stay reachable without sign-in. |
| A | Arcane | v2.16.1 | 1 | compatible | Compose-validated (file set, route) | Docker socket through its own socket proxy. Arcane 3.0.1 is available upstream (major release, not adopted). |
| A | Homepage | v2.6.0 | 1 | compatible | Compose-validated | Generated `services.yaml` skips apps without a web interface. 2.8.0 available upstream. |
| A | Portainer CE | 2.45.2 | 1 | compatible | Compose-validated | 2.45.3 available upstream. |
| A | Traefik Manager | 1.15.4 | 1 | compatible | Compose-validated | 1.15.7 available upstream. |
| B | Authelia | 4.39.28 | 1 | not-applicable | **Installed in isolation** (`/api/health`, Traefik route, backup + restore) | Installed as an application; using Authelia as the ForwardAuth provider is not implemented (it needs HTTPS on a real domain to verify). |
| B | LLDAP (directory) | v0.6.3 | 1 | not-applicable | **Installed in isolation** (administrator login API, backup + restore) | Directory port stays on the app's private network. |
| B | authentik | 2026.8.5 + PostgreSQL 16 | 3 (app, database, workers) | not-applicable | Compose-validated; its live suite (`Test-IdentityLive.ps1`) was not rerun this round (memory) | Identity & Access adopts it; existing installations are never changed. |
| C | Dispatcharr | 0.32.0 | 1 | caution | Installed in isolation **up to the Traefik route**; backup/restore and removal not reached (the run was stopped by low system memory) | 0.34.0 available upstream. |
| C | Dispatcharr (modular) | 0.32.0 + PostgreSQL 17 + Valkey 9.1.2 | 4 (app, database, cache, workers) | caution | Compose-validated | Database and cache images not on this PC. |
| C | Jellyfin | 12.2 (20261005) | 1 | caution | Compose-validated; not started (image not on this PC, ~1 GB) | Media clients use their own sign-in; ForwardAuth blocks them. 12.4 available upstream. |
| C | Channels DVR Server | `latest` (vendor publishes only `latest`) | 1 | caution | Compose-validated | Discovery (mDNS/DLNA) is limited on Docker Desktop. |
| D | Immich | v3.3.5 (+ machine learning, Valkey 9, PostgreSQL 14 with VectorChord) | 4 (app, database, cache, workers) | caution | Compose-validated as a file set; **live install deferred** (needs several GB of memory) | Mobile apps use the API; ForwardAuth blocks them. 3.4.1 available upstream. |
| D | Rocket.Chat | 8.9.0 + MongoDB 8.2 + NATS 2.11 | 4 (app, database, messaging, setup) | caution | Compose-validated as a file set; **live install deferred** (needs several GB of memory) | Desktop and mobile clients use the API. 9.0.0 available upstream (major release). |
| E | What's Up Docker | 9.5.0 + socket proxy | 2 (app, support) | compatible | Compose-validated | Recommended for update notifications; it never updates containers. 9.8.0 available upstream. |
| E | Diun | 4.33.1 + socket proxy | 2 (app, support) | not-applicable | **Installed in isolation** (headless: log "Found N images", backup + restore) | No web interface: never routed or published. Notifications are configured in `config/diun.yml`. |

All 17 installable templates are also checked on every `Test-Catalog.ps1` run as modular file sets: plain
`docker compose` with `COMPOSE_FILE` sees the same project and services as the single file, only the web front end is
on the shared proxy network, no secret value appears in any Compose file or `dtc-stack.json`, no Docker labels route,
and every proxied front end gets an explicit Traefik file-provider route to its Docker DNS name.

## Not offered

| Application | Status | Why |
| --- | --- | --- |
| Watchtower | Retired (recognized if installed; not offered) | `containrrr/watchtower` was archived in 2025-12 (last release v1.7.1, 2023). A maintained fork exists (`nicholas-fedor/watchtower` v1.24.0, 2026-11-04), but Watchtower updates containers unattended, which this manager does not do; What's Up Docker or Diun notify instead and updates stay backup-first and approved. |
| OpenLDAP | Listed only | `osixia/openldap` 1.5.0 dates from 2021 (v2 is beta) and the free Bitnami images are gone; no maintained, suitably licensed image was found. LLDAP covers the "small directory for other apps" case; OpenLDAP is for full LDAP schemas and replication, which this manager does not configure. |
| PostgreSQL, Redis/Valkey | Building blocks | Generated inside each application that needs them (own container, own volume, private network, health check, backup with the app). Never shared between apps, never published. |
