# Architecture inventory (Phase 0)

Read-only review of this repository and the related repositories owned by `jdepew88`, done before the HomeLab
platform work (Infrastructure Explorer, Docker discovery and publishing, app catalog, host adapters). Licences were
checked in both the LICENSE files and the GitHub API.

## Repositories

| Repository | Licence (confirmed) | What it is | Verdict |
| --- | --- | --- | --- |
| `traefik-cloudflared-windows` (this) | MIT | Windows Traefik v3 + socket-proxy + cloudflared manager: PowerShell web UI, service registry, Cloudflare API, backups, discovery, launcher | Base platform |
| `Homelab-in-a-box` | MIT | Debian VPS bootstrap (Python): cloudflared, Traefik v3.3, Portainer, Traefik Manager, Authelia + Postgres + Redis, Rocket.Chat. No tests | Reuse templates and ideas (Debian adapter, Authelia forwardAuth) |
| `homelabinabox-site` | **Unconfirmed**: README and `src/config.ts` say MIT, but there is no LICENSE file and GitHub reports none | React/Vite/Tailwind documentation site (homelabinabox.com) | Design reference only until a LICENSE is added |
| `update_traefik_and_pihole`, `update_traefik_cloudflare_authelia`, `update_traefik_and_cloudflare`, `traefik_add_to_config.yml` | GPL-3.0 | Python scripts that add a Traefik router/service to a file-provider YAML, a Cloudflare CNAME, a Pi-hole v5 CNAME or an Authelia access rule (Unraid `/mnt/user/appdata` paths) | Ideas only; no code copied |
| `install_traefik_compose` | MIT | Traefik 2.6 + DNS-01 installer for Linux | Historical |
| `authelia` (fork of ibracorp/authelia) | GPL-3.0 | Only a README with links | Not relevant |
| `k3s-rancher-traefik` (fork of TechnoTim launchpad) | None (all rights reserved) | Starter compose files and Ansible | Reference only; do not copy |
| `traefik-cloudflared-omnivoice` | MIT | Sibling Windows stack | Independent; never modified |
| `bazzite-xbox-context-menu-toolkit` | GPL-3.0 | KDE service menus | Not container related |

No repository contains Unraid Community Applications XML templates, Unraid User Scripts or Podman/Bazzite container
tooling; those adapters need new work.

## Design reference (homelabinabox-site)

Dark navy surfaces (`#050a14`/`#0f172a`, cards `#1e3a5f`-ish, borders `#334155`), cyan accent `#38bdf8` with blue
`#60a5fa`, purple/indigo only for primary calls to action (`#8b5cf6` → `#6366f1`), Inter + JetBrains Mono, 10-14px
radii, uppercase pill tags, and a left-to-right flow Browser → Cloudflare (HTTPS) → Tunnel (encrypted) → cloudflared →
Traefik :80 (HTTP) → containers. Its diagrams are raster images (undocumented provenance, third-party logos) and CSS
chips; there is no SVG diagram or animation to reuse. The Explorer therefore draws its own diagram with the
manager's existing tokens, adjusted toward this palette, and brand marks from Simple Icons (CC0 data; trademarks stay
with their owners).

## Inventory

**Already exists here:** hardened Compose (digest-pinned images, GET-only socket-proxy on an internal network,
loopback-only ports, fixed cloudflared address for trusted forwarded headers); file-provider route generation and
validation in a throwaway Traefik; Cloudflare zones/tunnels/DNS/Access plans with previews and recovery points;
dashboard verification probes; deployment discovery and attach; backups; four detail levels; mock Cloudflare, Edge
CDP browser tests and an isolated live-instance test.

**Reuse:** the service registry and plan/apply pipeline for every publish (one routing owner: the file provider);
`Invoke-ProbeRequest` and the dashboard verification pattern for per-service health; the Cloudflare plan logic for DNS,
tunnel routes and Access; Homelab-in-a-box's Authelia/forwardAuth templates (MIT) for Phase 6.

**Windows-specific:** DPAPI token storage, NTFS ACLs, `%LOCALAPPDATA%` state, the PowerShell 5.1 TcpListener server,
`START-HERE.cmd`, `host.docker.internal`, Docker Desktop checks, `Get-NetTCPConnection` port checks,
`%USERPROFILE%\.docker\projects` discovery root.

**Portable:** Traefik YAML generation and validation rules, Cloudflare REST flows, the backup manifest format and
credential scanning, `compose.yaml` (generic Linux containers apart from the host-gateway name and socket path), the
static CSP-clean web UI.

**Needs a host adapter:** secret storage, file permissions, Docker/Podman socket path, host-gateway name, appdata root
(`/opt/appdata`, `/mnt/user/appdata`, the install folder), port-in-use checks, launcher/service install, discovery
roots.

**Independent applications:** Portainer, Arcane, Traefik Manager, Authelia, Authentik and every catalog app stay
ordinary Compose projects that keep working without the manager; the OmniVoice stack and `unifi-lan` are discovered
only.

**New implementation:** Docker container discovery and publishing, a curated catalog schema with Compose generation,
the Infrastructure Explorer, Unraid template import, Podman support, Authentik integration, the containerised-manager
proof of concept.

## Ideas taken from the GPL scripts (reimplemented, not copied)

Upsert a router and a `<name>` service into file-provider YAML with a backup first (this repository already does this
per service file); create a proxied Cloudflare CNAME per hostname (done here against the tunnel); add a subdomain to an
Authelia access rule (Phase 6); Pi-hole local DNS (v5 API only; not planned).

## Cautions

- Never copy code from the GPL-3.0 repositories or the unlicensed fork into this MIT project.
- Add a LICENSE file to `homelabinabox-site` before reusing its code or CSS; do not redistribute its raster images or
  logos.
- Homelab-in-a-box uses `:latest` tags, a raw `docker.sock` in Traefik and Portainer and `POST=1` on its socket-proxy;
  reuse its structure, not those defaults. Its `.env.example` contains a real domain and user name.
