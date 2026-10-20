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
| Browser-based setup and management UI | Planned (separate branch). |

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

## Quick start

```powershell
cd <this repo>
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun     # shows every action, changes nothing
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Start      # installs to %USERPROFILE%\.docker\projects\traefik-proxy
cd $env:USERPROFILE\.docker\projects\traefik-proxy
.\services.ps1 add -Name whoami -Hostname whoami.example.com -TargetType docker -TargetHost my-container -Port 80
```

The last command only **previews** the change. Add `-Apply` to write it. Then publish it through Cloudflare
with the guided wizard (`.\install.ps1 -Wizard` the first time, `.\install.ps1 -AddApp` later), or by hand
(see [Cloudflare](#cloudflare-tunnel-remotely-managed)).

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
.\tests\Invoke-IsolatedTest.ps1         # (repository only) disposable second instance: install, live tests,
                                        # services.ps1 walkthrough with docker/LAN/host targets, teardown
.\tests\Test-Stack.ps1                  # live checks against a running instance, exit code 1 on failure
.\tests\Test-Stack.ps1 -PublicTestHost whoami-test.example.com
.\scripts\Get-Diagnostics.ps1 -OutFile diag.txt
```

`Invoke-IsolatedTest.ps1` takes before/after snapshots of every other container on the engine (ID, start
time, state) and fails if anything outside its own instance changed.

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
| `services.ps1 ... -Apply` says Traefik rejected the configuration | The error names the router/middleware; nothing was changed. |
| 524 at Cloudflare | Backend took > 100 s. |
| cloudflared restarting | Bad/rotated token: `.\install.ps1 -SetTunnelToken`; `docker logs <stack>-cloudflared`. |
| Traefik sees no labelled containers | `docker logs <stack>-socket-proxy` for 403s; container needs `traefik.enable=true`. |
| Port 8180 in use | Set `TRAEFIK_HTTP_PORT` in `.env`, re-run installer. |
| Tunnel subnet overlaps | Set `TUNNEL_SUBNET`, `TUNNEL_IP_RANGE`, `CLOUDFLARED_IP` in `.env`. |
| Edited a route by hand, nothing changed | `.\install.ps1 -Reload`. |
| `.ps1` blocked by policy | Launch with `powershell -ExecutionPolicy Bypass -File ...`. |

## Known limitations

- The Cloudflare side is guided, not automated: tunnels, published routes, DNS records and Access applications
  are created in the Cloudflare dashboard (API automation is planned for the web UI, with explicit confirmation).
- The tunnel path (cloudflared, public test) has not been validated end to end from this repository.
- HTTP only between Cloudflare and Traefik inside Docker; TLS terminates at the Cloudflare edge. LAN clients
  cannot use the proxy (ports are loopback-only by design).
- Cloudflare edge limits apply: 100 MB request body (Free/Pro), 100 s response timeout (HTTP 524), and
  content restrictions for video streaming.
- One backend server per service (no load balancing across several servers) and IPv4 targets only.
- Tested on one Windows 11 machine with Docker Desktop 29.8.2 and Windows PowerShell 5.1.
