# Traefik v3.7.15 + Cloudflare Tunnel on Docker Desktop (Windows)

A Windows-native Compose project for Docker Desktop (Linux containers, WSL 2 backend): Traefik as the
reverse proxy, a read-only Docker socket proxy, and a remotely managed Cloudflare Tunnel. Apps in **other**
Compose projects join one shared `proxy` network and are routed by **container name**, never by IP.
No port forwarding, no host port 80/443, no ACME/DNS-01: public HTTPS terminates at Cloudflare.

This is the Windows successor to the Linux repo
[jdepew88/install_traefik_compose](https://github.com/jdepew88/install_traefik_compose), which is unchanged.

```
Internet --HTTPS--> Cloudflare edge (+ Access) ==tunnel==> cloudflared
                                                              | http://traefik:80   (network: tunnel, 172.31.250.0/28)
127.0.0.1:8180 ------------------------------------------> traefik :80  (web)
127.0.0.1:8181 ------------------------------------------> traefik :8080 (dashboard + /ping, loopback only)
                                                              |                    \
                                          network: proxy (shared, external)    network: socket-internal (internal)
                                           |            |            |                \
                               omnivoice-triton-api  omnivoice-   future apps       socket-proxy -> docker.sock (ro)
                                     :18081        perform-api:18090
traefik --file provider--> host.docker.internal:8010 (OmniVoice Vite UI on Windows)
```

## Project status

| Area | Status |
| --- | --- |
| Traefik 3.7.15 + socket proxy on Docker Desktop | **Deployed and live-tested** (`tests\Test-Stack.ps1`: all local checks pass). |
| Shared `proxy` network, container-name routing | **Working.** OmniVoice API containers attached; routes answer locally on `127.0.0.1:8180`. |
| OmniVoice Studio routes (`/api`, `/perform-api`, UI, Vite HMR WebSocket) | **Working locally** through Traefik. Not yet reachable from the Internet. |
| Installer (`-DryRun`, `-Start`, `-Reload`, `-Rollback`, `-Stop`, `-OmniVoiceHost`, `-AttachOmniVoice`) | **Implemented and exercised** on the target PC. |
| Interactive wizard (`-Wizard`, `-AddApp`), `scripts\TunnelWizard.ps1` | **Implemented.** Token decoding, duplicate-connector guard, route generation, existing-route detection and local route checks were tested in isolation. **The full wizard has not yet been completed end to end against a real Cloudflare tunnel.** |
| Dedicated Cloudflare Tunnel for this stack | **Not configured.** No tunnel token is installed, the `cloudflared` service has not been started, and no public hostname has been validated through it. |
| Public access / Cloudflare Access for OmniVoice | **Not configured or validated.** |
| Browser-based GUI | Not started (planned). |

Everything in this README marked as tunnel/public behaviour describes what the code does; it becomes verified
only after the wizard has been run against a real tunnel and `tests\Test-Stack.ps1` reports cloudflared as
healthy (it is currently skipped).

## Verified versions (2026-10-18)

| Component | Image | Notes |
| --- | --- | --- |
| Traefik | `traefik:v3.7.15@sha256:0f615020...` | Released 2026-10-15. Docker API negotiated to 1.56 (Docker Desktop engine 29.8.2). |
| cloudflared | `cloudflare/cloudflared:2026.10.1@sha256:a15a3b50...` | The packaged candidate `2026.10.0` exists, but `2026.10.1` is the current release. Uses `TUNNEL_TOKEN_FILE` and `tunnel ready` health check. |
| Socket proxy | `tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b5...` | The packaged tag `0.4.1` does **not exist** (tags are `v`-prefixed). HAProxy 3.4.2. |
| Test backend | `traefik/whoami:v1.12.0@sha256:c4717a8d...` | `test` profile only. |

Full digests are in `compose.yaml`.

## Layout

```
compose.yaml                  traefik + socket-proxy (+ cloudflared: profile tunnel, whoami: profile test)
traefik/traefik.yml           static config (file only; CLI flags/env are ignored when a file is used)
traefik/dynamic/security.yml  default-headers middleware
traefik/dynamic/dashboard.yml dashboard on the loopback-only entry point
traefik/dynamic/host-app.yml.example  template for an app running directly on Windows
examples/                     OmniVoice route template + compose fragment, label template for new apps
install.ps1                   idempotent installer: dry-run, start, wizard, token prompt, reload, rollback, stop
scripts/TunnelWizard.ps1      wizard functions (dot-sourced by install.ps1)
scripts/Get-Diagnostics.ps1   read-only, token-redacted diagnostics
tests/Test-Stack.ps1          live semantic tests
SECURITY.md                   threat model, controls, operator responsibilities
CLAUDE_SETUP_PROMPT.md        original task brief from the source package

Generated in the deployed folder only (git-ignored):
.env                          local ports / test hostname (from .env.example)
secrets/cloudflare_tunnel_token  tunnel token (user-only ACL)
traefik/dynamic/omnivoice.yml OmniVoice routes for your hostname
traefik/dynamic/app-*.yml     routes written by the wizard / -AddApp
tunnel.json                   wizard answers (domain, tunnel name/ID, apps; no secrets)
.install-manifest.json, backups/, *.dist   installer state for safe updates and rollback
```

The installer deploys to `%USERPROFILE%\.docker\projects\traefik-cloudflared-windows` by default (override with
`-InstallPath`), and all configuration lives in that folder. Traefik keeps no other state: with no ACME there is
nothing in a data volume. The source repository is never used as the running project.

## Install

### Prerequisites

1. **Windows 10/11** with virtualisation enabled and **WSL 2** (`wsl --install` in an elevated prompt, reboot).
2. **Docker Desktop** (tested with 29.8.2 / Compose v5.5.1) using the **WSL 2 backend** and **Linux
   containers** (the default; tray icon > *Switch to Linux containers* if needed). Start it and wait until
   `docker info` works. Do **not** enable *Expose daemon on tcp://localhost:2375*: this stack never needs it.
3. **Windows PowerShell 5.1** (built in) or PowerShell 7. `curl.exe` (built into Windows 10+) is used for tests.
4. Free loopback ports `8180` and `8181` (or set others in `.env`).
5. For publishing: a domain on Cloudflare and access to the Zero Trust dashboard (Free plan is fine).

### Quick start: guided setup (recommended)

```powershell
cd <this repo>
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Wizard
```

The wizard installs the stack, then walks you through the Cloudflare side and tests each step:

1. **Questions** - your Cloudflare domain, a name for the new tunnel, the application hostname, what serves
   it (a container by name + port, an app on Windows by port, or the OmniVoice Studio preset), and whether to
   put Cloudflare Access in front (default yes).
2. **Create the tunnel** - step-by-step instructions for the Zero Trust dashboard (it can open it for you).
3. **Token** - paste the token, or the whole `docker run ... --token ...` command, at a hidden prompt.
   It is validated, checked against other cloudflared containers on this PC (it refuses to reuse a token that
   another connector already runs), and saved to `secrets\cloudflare_tunnel_token` with a user-only ACL.
4. **Start cloudflared** - and wait for registered tunnel connections.
5. **Route the app** - writes `traefik\dynamic\app-<host>.yml` (or the OmniVoice preset), attaches the
   container to `proxy` and checks the route locally.
6. **Cloudflare Access** - instructions to create the Access application before anything is public.
7. **Published route** - exact values to enter: subdomain, domain, Service `HTTP`, URL `traefik:80`.
8. **Test** - requests `https://<hostname>`: an Access login redirect, or a request seen in Traefik's access
   log, confirms the path. With Access on, it can watch while you sign in from your browser and confirm that a
   request with your public IP reached Traefik through the tunnel.

Non-secret answers are kept in `tunnel.json`. To publish **another app on the same tunnel** later (nothing is
recreated): `.\install.ps1 -AddApp`. Answers can also be passed as parameters, e.g.
`.\install.ps1 -AddApp -AppHostname wiki.example.com -AppTarget container:wiki:3000`.

### Manual / scripted install

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun     # shows every action, changes nothing
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Start
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.docker\projects\traefik-cloudflared-windows\tests\Test-Stack.ps1"
```

What the installer does, and does not do:

- Checks the engine is Linux, prints existing containers and ports.
- Fails if `127.0.0.1:8180`/`8181` are taken by something other than this stack (change them in `.env`).
- Creates the shared `proxy` bridge network if missing. If it exists, it is reused as-is (never recreated or
  removed); a warning is shown if another Compose project owns it.
- Fails if another network overlaps the tunnel subnet `172.31.250.0/28`.
- Copies files without clobbering your edits: unchanged files are updated (old copy in `backups\<timestamp>\`);
  files you edited are kept and the new version is written as `<file>.dist`.
- Never writes secrets to `.env`; never runs `down -v`, `prune` or `network rm`.

| Switch | Effect |
| --- | --- |
| `-Wizard` | Guided tunnel + first app setup (see above). |
| `-AddApp` | Guided: route and publish another hostname on the existing tunnel. |
| `-Domain`, `-TunnelName`, `-AppHostname` | Pre-answer wizard questions. |
| `-AppTarget <spec>` | `container:<name>:<port>`, `windows:<port>`, `preset:omnivoice` or `existing`. |
| `-LocalOnly` | With `-Wizard`/`-AddApp`: Traefik route only; skip the Cloudflare steps and public test. |
| `-InstallPath <dir>` | Target folder (default above). |
| `-DryRun` | Report only. |
| `-Start` | `docker compose up -d --wait` (adds the tunnel profile with `-EnableTunnel`). |
| `-SetTunnelToken` | Hidden prompt for the token; pasting the whole `docker run ... --token X` command is fine. |
| `-EnableTunnel` | Include cloudflared. |
| `-OmniVoiceHost <fqdn>` | Generate `traefik\dynamic\omnivoice.yml` from the example (if absent). |
| `-AttachOmniVoice` | `docker network connect proxy` for the two OmniVoice API containers (live, no restart). |
| `-Rollback` | Restore files from the latest `backups\<timestamp>` (current files saved first). |
| `-Stop` | `docker compose down --remove-orphans` for this project only (no `-v`; `proxy` stays). |
| `-Reload` | Make Traefik re-read `traefik\dynamic\` after hand edits (see below). |

**Editing `traefik\dynamic\` by hand:** Docker Desktop does not pass file-change notifications from Windows
folders into the Linux VM, so Traefik's file `watch` does not see edits made in Windows. Run
`.\install.ps1 -Reload` afterwards: it touches a file from a throwaway container inside the VM, which Traefik
does notice, and reloads without a restart. (The wizard and installer do this automatically.)

## Cloudflare Tunnel (remotely managed)

`.\install.ps1 -Wizard` performs these steps interactively. Manual equivalent:

1. **Cloudflare Access first** (Zero Trust > Access > Applications > Add > Self-hosted): application domain
   `voice.example.com`, policy e.g. *Allow - Emails - you@example.com*. OmniVoice has no login of its own.
2. Zero Trust > Networks > Tunnels > **Create a tunnel** > Cloudflared, name e.g. `traefik-windows`.
   Copy the token from the Docker install command.
3. On the PC:
   ```powershell
   cd $env:USERPROFILE\.docker\projects\traefik-cloudflared-windows
   .\install.ps1 -SetTunnelToken -Start -EnableTunnel
   docker compose logs --tail=50 cloudflared      # expect "Registered tunnel connection" lines
   ```
4. Tunnel > **Published application routes** (older layouts: Public hostnames) > Add: `voice.example.com`, service **HTTP** `traefik:80`.
   One route per hostname, all pointing at `http://traefik:80`; Traefik routes by Host header.
   If the hostname already has a DNS record (for example from another tunnel), the dashboard asks to replace
   it: that moves the hostname to this tunnel.
5. Do not add a public hostname for the dashboard (8181) or the socket proxy.

Testing the tunnel end to end with the echo backend: temporarily add a public hostname such as
`whoami-test.example.com` -> `http://traefik:80` (put it behind Access too, or remove it right after), then
`.\tests\Test-Stack.ps1 -PublicTestHost whoami-test.example.com`. The test checks that the request arrives
with `X-Forwarded-Proto: https`, the public Host header and `Cf-Connecting-Ip`. Delete the hostname afterwards;
whoami itself is removed by the script.

### Coexisting with an existing cloudflared container

A separate tunnel (different token) can keep running in its own project; nothing here touches it. Do not run
this stack's cloudflared with another tunnel's token: connectors of one tunnel are load-balanced replicas,
so requests would randomly land on a connector that cannot reach `traefik`. To migrate hostnames, move each
public hostname to this tunnel in the dashboard, then retire the old connector at a time of your choosing.

## OmniVoice integration

OmniVoice Studio as found on this PC:

| Part | Runs as | Internal endpoint | Unchanged host port |
| --- | --- | --- | --- |
| UI | Vite (`npm run dev` / `preview`) on Windows, port 8010 | `host.docker.internal:8010` | 8010 |
| `/api` | container `omnivoice-triton-api` (plain `docker run`) | `omnivoice-triton-api:18081` | 18080 |
| `/perform-api` | container `omnivoice-perform-api` (Compose project `omnivoice-wrapper-site`) | `omnivoice-perform-api:18090` | 18090 |

`examples/omnivoice.dynamic.yml.example` reproduces the Vite proxy (prefix stripping included) but sends the
API paths directly to the containers by name over `proxy`. Steps:

```powershell
.\install.ps1 -OmniVoiceHost voice.example.com -AttachOmniVoice
```

and add the `proxy` network to `docker-compose.perform.yml` (see `examples/omnivoice.compose.example.yaml`)
so it survives the next `docker compose up`. OmniVoice stays in its own project; its `default` network, ports
and volumes are untouched. The Vite config already allows the public hostname (`allowedHosts`).

Uploads are multipart (`FormData`) and stream through Traefik without a size limit; the `web` entry point's
`readTimeout` is raised to 300 s for slow uploads. WebSockets (e.g. Vite HMR) pass through natively; the test
suite verifies a `101 Switching Protocols` upgrade.

Local check without the tunnel:

```powershell
curl.exe -s -H "Host: voice.example.com" http://127.0.0.1:8180/api/health
curl.exe -s -H "Host: voice.example.com" http://127.0.0.1:8180/perform-api/health
```

## Adding another app

Easiest: `.\install.ps1 -AddApp`. It reuses the existing tunnel, attaches the container to `proxy`, writes the
route, guides the Access + published-route steps and tests the result.

Alternatively, with labels in the app's own Compose file (the Docker provider picks these up live): attach only
its web service to the external `proxy` network, no `ports:` needed. Use the **container** port.

```yaml
services:
  myapp:
    networks: [default, proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`myapp.example.com`)
      - traefik.http.routers.myapp.entrypoints=web
      - traefik.http.routers.myapp.middlewares=default-headers@file
      - traefik.http.services.myapp.loadbalancer.server.port=8000
networks:
  proxy:
    external: true
    name: proxy
```

For a non-Compose container, `docker network connect proxy <name>` plus a file-provider route in
`traefik\dynamic\<app>.yml` (`url: http://<container-name>:<port>`). For an app running directly on Windows,
see `traefik/dynamic/host-app.yml.example` (`host.docker.internal`; check the app listens on 0.0.0.0 and the
Windows firewall allows it). Then add the public hostname in the tunnel (behind Access if needed).

## Tests and diagnostics

```powershell
.\tests\Test-Stack.ps1                    # ~25 live checks, exit code 1 on failure
.\tests\Test-Stack.ps1 -PublicTestHost whoami-test.example.com
.\scripts\Get-Diagnostics.ps1 -OutFile diag.txt
```

`docker compose config` only checks Compose syntax and interpolation; the test script checks Traefik
semantics against the running containers (see its header for the full list).

## Upgrades

1. Read the Traefik release notes and the migration guide (https://doc.traefik.io/traefik/migrate/v3/) for
   every version between the current and the target.
2. Find the new digest: `docker buildx imagetools inspect traefik:v3.x.y` (top-level `Digest:`).
3. Edit the `image:` line in this repo's `compose.yaml` (tag **and** digest), commit, then
   `.\install.ps1 -Start` (the previous compose.yaml is saved to `backups\`).
4. `docker compose up -d --wait`, then `.\tests\Test-Stack.ps1`. Check `docker logs traefik` for `WRN`/`ERR`.
5. Same procedure for cloudflared (`cloudflare/cloudflared:YYYY.M.P`) and the socket proxy.

Never use `latest`. Rollback = previous tag+digest: `.\install.ps1 -Rollback`, then `docker compose up -d`.

## Rollback / removal

- Undo the last file update: `.\install.ps1 -Rollback; docker compose up -d`.
- Stop this stack only: `.\install.ps1 -Stop` (equivalent to `docker compose --profile tunnel --profile test down`).
  Do **not** add `-v`, do not `docker network rm proxy` while apps are attached, never `docker system prune`.
- Detach an app: `docker network disconnect proxy <container>` (and remove `proxy` from its Compose file).
- OmniVoice compose backup: `docker-compose.perform.yml.bak-20261018` next to the original.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| 404 from Traefik | Host rule doesn't match the public hostname; `scripts\Get-Diagnostics.ps1` lists routers. |
| 502 Bad Gateway | Backend not on `proxy`, wrong *container* port, or (UI) Vite not running on 8010. |
| 524 at Cloudflare | Backend took > 100 s. |
| cloudflared restarting | Bad/rotated token: `.\install.ps1 -SetTunnelToken`; `docker compose logs cloudflared`. |
| Traefik sees no containers | `docker logs socket-proxy` for 403s; container needs `traefik.enable=true`. |
| Port 8180 in use | Set `TRAEFIK_HTTP_PORT` in `.env`, re-run installer. |
| Edited a route, nothing changed | Run `.\install.ps1 -Reload` (Windows file changes are not seen inside the VM). |
| Wizard says the token is already in use | Another cloudflared container on this PC runs the same tunnel; create a new tunnel instead of reusing its token. |
| Public hostname times out / 530 | Hostname not on this tunnel, or cloudflared not connected: `docker compose logs cloudflared`. |
| `.ps1` blocked by policy | Launch with `powershell -ExecutionPolicy Bypass -File ...` (no system-wide policy change needed). |

## Known limitations

- **The dedicated tunnel is not set up yet** (see *Project status*): the Cloudflare steps of the wizard, the
  public test and the cloudflared checks in `Test-Stack.ps1` have not run against a live tunnel.
- The Cloudflare side is guided, not automated: the wizard cannot create tunnels, published routes, DNS records
  or Access applications for you (that would need an API token, which this project deliberately avoids).
- Traefik's file `watch` does not see edits made from Windows; use `-Reload` (the installer and wizard do).
- HTTP only between Cloudflare and Traefik inside Docker; TLS terminates at the Cloudflare edge. LAN clients
  cannot use the proxy (ports are loopback-only by design).
- Cloudflare edge limits apply: 100 MB request body (Free/Pro) and a 100 s response timeout (HTTP 524).
- The OmniVoice UI route expects the Vite server on Windows port 8010; if it is not running Traefik returns 502.
- `omnivoice-triton-api` is a plain `docker run` container: if it is recreated without `--network proxy`,
  re-run `.\install.ps1 -AttachOmniVoice`.
- The tunnel network uses the fixed subnet `172.31.250.0/28`; the installer stops if another network overlaps it.
- Tested on one Windows 11 machine with Docker Desktop 29.8.2 and Windows PowerShell 5.1.
- No browser-based GUI yet; everything is driven from PowerShell.
