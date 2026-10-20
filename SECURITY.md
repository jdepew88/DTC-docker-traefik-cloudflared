# Security

## Threat model in one paragraph

The only inbound path from the Internet is the outbound-initiated Cloudflare Tunnel. Cloudflare terminates
public HTTPS and forwards each configured public hostname over the tunnel to `cloudflared`, which talks plain
HTTP to Traefik on a private Docker network. No router port forwarding, no host port 80/443, and nothing
published on the LAN: Traefik's two ports are bound to `127.0.0.1` only. Anyone who can reach a public
hostname can reach the app behind it, so **apps without their own authentication must sit behind
Cloudflare Access**.

## Controls in this repository

| Area | Control |
| --- | --- |
| Docker API | Traefik never mounts `docker.sock`. It uses `tecnativa/docker-socket-proxy` on an `internal: true` network with only `CONTAINERS`, `EVENTS`, `VERSION`, `PING` (GET only, `POST=0`). Port 2375 is never published. Tests assert `/images` and POSTs return 403. |
| Dashboard | `api.insecure: false`. The dashboard/API router is bound to the `traefik` entry point only, published on `127.0.0.1:8181`. cloudflared can only reach the `web` entry point. |
| Forwarded headers | `X-Forwarded-*` are trusted only from cloudflared's fixed address `172.31.250.10` on the dedicated `tunnel` network. Apps on the shared `proxy` network cannot reach cloudflared or spoof that source; all other clients get the headers overwritten. |
| Request hardening | `aliasHeadersStrategy: delete` and all `encodedCharacters.*` set to `false` (Traefik v3.6+ hardening). |
| Containers | Pinned tag + digest images, `read_only`, `no-new-privileges`, `cap_drop: ALL` where the image allows, log rotation. No `latest` tags. |
| Secrets | The tunnel token is stored in `secrets\cloudflare_tunnel_token` (ACL: current user, SYSTEM, Administrators), mounted as a Compose secret and read with `TUNNEL_TOKEN_FILE`, so it is not in `.env`, the command line or `docker inspect` output. `.env`, `secrets/` and `*token*` are git-ignored. |
| Test backend | `whoami` only runs under the `test` profile and the test script removes it afterwards. |

## Operator responsibilities

1. **Cloudflare Access before publishing.** Create an Access application (Zero Trust > Access > Applications >
   Self-hosted) for every hostname whose app has no login (OmniVoice Studio has none). Add the policy first,
   then the tunnel public hostname.
2. **Token hygiene.** Anyone with the tunnel token can run your tunnel. Never paste it into Compose files,
   commits, chats or screenshots. If exposed: Cloudflare dashboard > Tunnel > Refresh/rotate token, then
   `.\install.ps1 -SetTunnelToken` and `docker compose --profile tunnel up -d`.
3. **Shared network membership.** Every container attached to `proxy` can reach every other one by name.
   Attach only the web-facing service of an app, not its database.
4. **Cloudflare limits.** Uploads above the plan limit (100 MB on Free/Pro) and responses slower than 100 s
   fail at the Cloudflare edge (HTTP 413 / 524), independent of Traefik.

## Reporting

Private repository; open an issue or contact the owner directly. Do not include tokens in reports:
`scripts\Get-Diagnostics.ps1` redacts them automatically.
