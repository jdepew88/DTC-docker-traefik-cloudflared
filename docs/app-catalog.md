# App Catalog

The App Catalog installs curated applications as ordinary Docker Compose projects. Each app gets its own folder
(default: next to the proxy deployment, e.g. `%USERPROFILE%\.docker\projects\uptime-kuma`) with:

- `compose.yaml`: pinned image (tag and digest), the shared proxy network as an external network, named volumes
  (`<project>_<name>`) or folders you chose, `no-new-privileges`, log rotation, labels `org.traefik-proxy.app` and
  `org.traefik-proxy.project`. Secrets appear only as `${VAR}`.
- `.env`: settings and generated secrets, readable by your Windows account, SYSTEM and Administrators only.
- `README.md`: how to run, update and remove the app with plain `docker compose`, without the manager.

The manager remembers what it installed in the deployment's `config\apps.json` (folder and project only). It manages
only projects it generated (the compose file must still carry its project label); any other Compose stack is never
changed. Apps are not published until you choose to: publishing uses the normal Services workflow (hostname,
Cloudflare Access by default, preview, confirmation).

## Curated apps

| App | Image (pinned) | Web port | Data | Notes |
| --- | --- | --- | --- | --- |
| HTTP echo | `traefik/whoami:v1.12.0` | 80 | none | For testing hostnames and Access |
| Uptime Kuma | `louislam/uptime-kuma:2.5.6` | 3001 | volume `/app/data` | Create the admin right after the first start |
| Jellyfin | `jellyfin/jellyfin:12.2.20261005-225228` | 8096 | volumes `/config`, `/cache`; media folder read-only | Local only by default: streaming through Cloudflare is restricted by its terms |
| Portainer CE | `portainer/portainer-ce:2.45.2` (LTS) | 9443 (HTTPS, self-signed) | volume `/data` | Mounts the Docker socket; Access required, never public |
| Arcane | `getarcaneapp/manager:v2.16.1` | 3552 | volume `/app/data` | Mounts the Docker socket; `ENCRYPTION_KEY` and `JWT_SECRET` generated; Access required |
| Authelia, authentik | listed, not installable | | | Configured by the optional authentication integration (Phase 6) |

Image tags, digests, exposed ports, volumes and required variables were read from the registries (image
configuration) and the projects' own documentation and Compose examples when curated (2026-10-21); nothing was
assumed.

## Manifest (`catalog\apps\<id>.json`, schema 1)

| Field | Meaning |
| --- | --- |
| `id`, `name`, `description`, `category`, `maintainer`, `license`, `source`, `docs` | Identity; `docs` are https links |
| `platforms` | `windows-docker-desktop`, `linux-docker`, `unraid`, `podman`: `supported`, `untested` or `unsupported` |
| `installable`, `installNote` | Listed-only entries explain why |
| `services.<name>` | `image` (must be `name:tag@sha256:...`), `ports` (`container`, `protocol` http/https/tcp/udp, exactly one `primary`), `volumes` (`name`, `target`, `kind` volume/folder, `readOnly`, `input` for folders), `environment` (templates), `dockerSocket`, `healthcheck`, `command`, `restart` |
| `inputs` | `text`, `secret`, `generated` (random bytes, hex), `folder` (existing local folder, no network paths), `timezone` |
| Templates | `{{input:<id>}}`, `{{project}}`, `{{appUrl}}`, `{{timezone}}`, `{{webPort}}`; unknown variables are errors |
| `privileges` | e.g. `docker-socket` with an explanation; the user confirms them before deploying |
| `security`, `dependencies`, `update`, `web`, `exposure` | Warnings, notes, the web interface and the default/allowed exposure (`allowPublic: false` hides "public") |

`tests\Test-Catalog.ps1` validates every shipped manifest and runs `docker compose config` on generated projects.

## Sources (architecture)

| Source | Status | Treatment |
| --- | --- | --- |
| Curated first-party manifests | Implemented | Installable |
| GitHub Compose repositories | Planned | Import a Compose file as a draft for review; never executed automatically |
| Docker Hub, GitHub Container Registry | Planned | Image discoveries (tags, digests, ports) only: not installable templates by themselves |
| Unraid Community Applications XML | Planned | Import compatible templates (image, ports, paths, variables) into a draft manifest; no undocumented catalog endpoint and no Unraid code |
| Your own Compose file | Planned | Adopted as an external project: discovered and publishable, managed only with permission |

No unrestricted community-template execution exists.

## Lifecycle

- **Install**: preview (compose.yaml, masked .env, checks: project name, empty folder outside the deployment, data
  volumes not already present unless you choose to reuse them, local port, network, `docker compose config`) →
  approve → `docker compose up -d` → health (container state and a real HTTP request) → optional publishing.
- **Start / stop / restart, logs** (secrets redacted), **health**.
- **Update**: preview the image change, confirm; `compose.yaml` is backed up, only image lines change, volumes stay.
- **Remove**: containers only by default; deleting data volumes or the generated files needs the project name typed;
  folders you chose (e.g. media) are never deleted; removal is refused while a service route still points at the app.
