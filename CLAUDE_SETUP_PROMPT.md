# Claude / Cursor completion prompt

You are working in a Windows 11 PowerShell 5.1 + Docker Desktop (Linux containers) setup. Start from this repository and refer to https://github.com/jdepew88/install_traefik_compose as the historical Linux version. Build and test a safe Windows-native Compose proxy stack, targeting **Traefik v3.7.15**. Keep the old Linux repo unchanged.

User's intended directory structure: Compose in the project root on C:, with Traefik configs inside the same project rather than a separate appdata directory. First inspect `C:\Users\Joe\.docker\projects\unifi-lan` and ask before selecting a different target than the packaged default `C:\Docker\traefik-cloudflared`.

## Required work

1. Inspect Docker Desktop context/engine, `docker info`, `docker compose version`, `docker ps`, networks, published ports, storage root and existing Compose projects. No deletes, prunes or destructive network recreation.
2. Verify the Traefik **3.7.15** Docker image exists. Verify/pin the cloudflared image to a real released tag or digest; the placeholder candidate tag `2026.10.0` must be checked before installation. Verify socket-proxy image/tag exists and works with current Docker Engine API; replace it if necessary, securely. Never publish Docker API port 2375.
3. Inspect ALL packaged files for Traefik v3.7 compatibility, especially Docker API version negotiation, file provider keys, middleware and socket proxy permissions. Validate semantics with a running container; `docker compose config` alone is insufficient.
4. Audit the installer: make PowerShell 5.1-safe, idempotent without overwriting user changes, detect port collision on loopback 8180, handle preexisting `proxy` network safely (either import as external or use a conflict-free named network), prompt for configuration rather than embedding secrets, and support dry-run/rollback without loss of data.
5. Keep Traefik, cloudflared and socket-proxy in one Compose project. Cloudflared tunnel is remotely managed: Cloudflare dashboard hostname routes to `http://traefik:80`. Do not require DNS-01 / ACME for tunnel-only deployment. Keep public HTTPS at Cloudflare edge; no router port forward.
6. OmniVoice must remain in its separate Compose project. Inspect the REAL OmniVoice service's internal web port and existing Compose networks/volumes, then add shared external `proxy` network and appropriate Traefik labels, preserving current behavior. Confirm WebSockets and audio/upload streaming where applicable. Protect private endpoints with Cloudflare Access or equivalent auth before opening to public Internet.
7. Add a disposable echo-backend test that confirms internal service DNS, host-based routing, tunnel egress, and forwarded host/proto handling; do not leave it Internet-accessible.
8. Add tests, diagnostics, SECURITY.md, upgrade steps, and Windows setup/rollback directions. Use no untested `latest` image tags and no obsolete v2 keys.
9. If GitHub auth is available, create private repo `jdepew88/traefik-cloudflared-windows` or use existing repo if already created; commit/push ONLY after tests, never commit `.env` or tunnel token. Give exact commit hash and URL. Do not claim deployed without live validation.

Report what changed, test results, remaining Cloudflare dashboard steps, and any blockers. Make safe decisions without asking repetitive questions. If a step could disrupt other Docker containers, stop and get explicit approval first.
