# Security

## Threat model in one paragraph

The only inbound path from the Internet is the outbound-initiated Cloudflare Tunnel. Cloudflare terminates
public HTTPS and forwards each configured public hostname over the tunnel to `cloudflared`, which talks plain
HTTP to Traefik on a private Docker network. No router port forwarding, no host port 80/443, and nothing
published on the LAN: Traefik's two ports are bound to `127.0.0.1` only. Traefik forwards each hostname to one
backend: a container on the shared network, an app on the Windows host, or a device on the LAN. Anyone who can
reach a public hostname can reach the app behind it, so **apps without their own authentication must sit
behind Cloudflare Access**, and publishing a LAN device extends the Internet's reach into the LAN.

## Controls in this repository

| Area | Control |
| --- | --- |
| Docker API | Traefik never mounts `docker.sock`. It uses `tecnativa/docker-socket-proxy` on an `internal: true` network with only `CONTAINERS`, `EVENTS`, `VERSION`, `PING` (GET only, `POST=0`). Port 2375 is never published. Tests assert `/images` and POSTs return 403. |
| Dashboard | `api.insecure=false`. The dashboard/API router is bound to the `traefik` entry point only, published on `127.0.0.1`. cloudflared can only reach the `web` entry point. Tests assert `/api` is not served on `web`. |
| Forwarded headers | `X-Forwarded-*` are trusted only from cloudflared's fixed address (`CLOUDFLARED_IP`) on the dedicated tunnel network. Apps on the shared network cannot reach cloudflared or spoof that source; all other clients get the headers overwritten (tested). |
| Request hardening | `aliasHeadersStrategy=delete` and all `encodedCharacters.*` set to `false` on both entry points (tested). |
| Generated routes | Every service field is validated against strict patterns (names, hostnames, hosts, ports, path prefixes, middleware references) before rendering, so registry input cannot inject Traefik rule syntax or YAML. Every apply is first loaded into a throwaway, network-less Traefik container; any Traefik error aborts the change. |
| Change safety | Changes are previewed, then backed up to `backups\services\` before writing; files are written atomically; `services.ps1 rollback` restores earlier states. No command starts, stops or recreates stack containers except `install.ps1 -Start/-Stop` and the wizard's tunnel step. |
| Instance isolation | All names, ports, networks and the tunnel subnet come from `.env`; the installer refuses names, ports or subnets already used by something else. Test backends carry no Traefik labels, so no other Traefik instance on the engine routes them. |
| Backend TLS | `tlsSkipVerify` is opt-in per service, only allowed for `https` targets, and reported as a warning. |
| Containers | Pinned tag + digest images, `read_only`, `no-new-privileges`, `cap_drop: ALL` where the image allows, log rotation. No `latest` tags. |
| Web UI | `webui.ps1` binds a raw socket to `127.0.0.1` only. Sign-in needs the random link printed at startup (session cookie: HttpOnly, SameSite=Strict). Every request is checked for an allowed `Host` header (DNS rebinding); every change needs a same-origin `Origin`, a per-session CSRF token, a JSON body (max 1 MB), an explicit confirmation flag and, for Cloudflare overwrites, a per-resource confirmation. Previews are single-use, expire after 15 minutes and are re-checked against the current Traefik and Cloudflare state before applying. Strict CSP, no inline script, DOM built without `innerHTML`, fixed static-file whitelist. Changes are logged to `logs\webui-audit.log` (redacted). |
| Cloudflare API | The API token is verified, then stored with Windows DPAPI (CurrentUser scope, app-specific entropy) in `secrets\cloudflare_api.dpapi` with a restricted ACL; it is decrypted per request and never returned to the browser or logged. The API endpoint is fixed to `api.cloudflare.com` (only a `127.0.0.1` mock is allowed for tests, and only from the command line). Automatic cleanup deletes only DNS records/tunnel routes pointing at this instance's tunnel and Access apps this tool created. Use a token scoped to the minimum permissions listed in the README. |
| Secrets | The tunnel token is stored in `secrets\cloudflare_tunnel_token` (ACL: current user, SYSTEM, Administrators), mounted as a Compose secret and read with `TUNNEL_TOKEN_FILE`, so it is not in `.env`, the command line or `docker inspect` output. `.env`, `secrets/`, `*token*`, `config/services.json` and generated routes are git-ignored. Diagnostics redact anything token-shaped. |

## Operator responsibilities

1. **Cloudflare Access before publishing.** Create an Access application (Zero Trust > Access > Applications >
   Self-hosted) for every hostname whose app has no login of its own. Add the policy first, then the tunnel's
   published route. `services.ps1` warns about services marked as published without Access.
2. **Token hygiene.** Anyone with the tunnel token can run your tunnel. Never paste it into Compose files,
   commits, chats or screenshots. If exposed: rotate it in the Cloudflare dashboard, then
   `.\install.ps1 -SetTunnelToken` and `.\install.ps1 -Start -EnableTunnel`.
3. **Shared network membership.** Every container attached to the shared proxy network can reach every other
   one by name. Attach only the web-facing service of an app, not its database.
4. **LAN targets.** Publishing a LAN device (NAS, router, camera, media server) exposes its web interface to
   whoever passes Cloudflare Access. Keep device firmware current, prefer Access, and prefer `-LocalOnly` for
   administrative interfaces. Skip certificate verification only for devices on a trusted network.
5. **Windows host targets.** The app must listen beyond `127.0.0.1`, which also makes it reachable from the LAN
   unless Windows Firewall restricts it. Scope firewall rules to the Docker Desktop/WSL network where possible.
6. **Cloudflare limits and terms.** Uploads above the plan limit (100 MB on Free/Pro) and responses slower than
   100 s fail at the Cloudflare edge (HTTP 413 / 524). Serving video or other large non-HTML content through
   Cloudflare's proxy/Tunnel is restricted by its terms unless you use a Cloudflare media product; do not route
   media streaming (Plex, Jellyfin, ...) through the tunnel as a bandwidth path.

## Reporting

Open an issue or contact the repository owner directly. Do not include tokens in reports:
`scripts\Get-Diagnostics.ps1` redacts them automatically.
