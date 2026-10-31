# Adopting an existing application

Install an application any way you like (Compose, Portainer, Arcane, `docker run`), open the manager, go to **Adopt an app**, click
**Adopt**, check the routes, approve the cutover, and optionally retire the old proxy. Containers, models, volumes and the
application's own compose file stay as they are.

## What is changed, and when

| Step | Action | Changes | Confirmation |
| --- | --- | --- | --- |
| 1-2 | Discover, preview | Nothing | - |
| 3 | Check reachability | Nothing (short-lived probe containers) | - |
| 4 | Prepare and validate | `config\adoptions\<id>\prepared\` only; a throwaway Traefik reads the files | - |
| 5 | Activate and test | `docker network connect` (live) and `traefik\dynamic\adopt-<id>-*.yml`. **No traffic moves**: only DNS or the tunnel send visitors to these routers | Yes |
| 6 | Review the cutover | Nothing (Cloudflare GET requests) | - |
| 7 | Cut over | Cloudflare DNS and tunnel route | Yes, plus separate Cloudflare approval, plus each overwrite individually |
| 8 | Verify | Nothing | - |
| 9 | Retire old proxy | Stop a container | Yes; only after verification |
| 10 | Delete old proxy | Remove a stopped container or unused network | Yes, name typed |

Each step requires the one before it, so a cutover is refused until every local test passes. Volumes, model folders, databases and
application containers are never candidates for retirement, and `docker rm` runs without `-v`.

**Exception to "no traffic moves":** if the tunnel already routes the external hostname to this Traefik (or has a wildcard for it),
activating the routes starts serving that hostname. *Review the cutover* shows `Tunnel route ... already exists` in that case.

## Separate checks

Local proxy reachability, DNS, TLS and sign-in have separate states: `ok`, `failed`, `pending` or `unverified`. A check that was not
made is `unverified`, never `ok`. HTTP 530 at Cloudflare reads as DNS ok, TLS ok, public path failed. An anonymous HTTP 200 on a
protected route reads as route ok, sign-in failed.

| Kind | Meaning |
| --- | --- |
| `backend` | The backend answers from the proxy's Docker network. `pending` means it answers but is not attached yet. |
| `config` | A throwaway Traefik accepted the generated file. |
| `router` | The running Traefik loaded the router. |
| `route` | An anonymous request through the proxy by Host header. |
| `auth` | Anonymous requests on the external route are sent to sign-in. |
| `websocket` | An Upgrade request answered 101 (needs `websocketTestPath`; behind sign-in it stays `unverified`). |
| `separation` | Each proxy answers 404 for the other's hostname (separate stacks only). |
| `dns`, `tls`, `public` | One public DNS query and one anonymous HTTPS request, in Verify. |

## Two proxies

| Proxy | Reached through | Sign-in | Route file |
| --- | --- | --- | --- |
| External (`traefik-ext1`, this deployment) | Cloudflare Tunnel | authentik ForwardAuth on every path, including APIs | `adopt-<id>-external.yml` |
| Internal (`traefik-int1`) | LAN DNS | None | `adopt-<id>-internal.yml` |

The internal proxy is found in this order: the folder named `internalInstallPath` in `config\adoption.json`; a running stack named
`traefik-int*`; the `lan-secure` entry point of Networking v2 on the same Traefik. Without any of them, internal routes can be
previewed but not activated. Internal hostnames are never passed to the Cloudflare code.

## Routing specification

`catalog\adoption\<id>.json`. DTC has no application-specific code: OmniVoice is only `catalog\adoption\omnivoice.json`. A container
without a specification gets a generated one-backend specification.

```json
{
  "schemaVersion": 1, "id": "myapp", "displayName": "My App",
  "backends": [
    { "id": "web", "kind": "host", "port": 8010, "healthPath": "/" },
    { "id": "api", "kind": "container", "containerNames": ["myapp-api"], "port": 8000, "healthPath": "/health",
      "timeouts": { "dial": "10s", "responseHeader": "600s", "idleConn": "180s" } }
  ],
  "routes": [
    { "id": "api", "backend": "api", "pathPrefix": "/api", "stripPrefix": true, "priority": 200, "maxRequestBodyBytes": 104857600 },
    { "id": "web", "backend": "web", "priority": 100, "websocket": true, "websocketTestPath": "/ws" }
  ],
  "legacy": { "composeProjects": ["myapp-old-proxy"] },
  "notes": ["Shown in every preview."]
}
```

Rules checked by `Test-AdoptionSpec`: priorities are unique and path routes outrank the catch-all, so order never depends on rule
length; sign-in middleware cannot appear in a specification; an upload limit cannot be combined with WebSocket, because it uses request
buffering. Backends are found by `containerNames`, `composeService` or `imagePattern`; matching two containers blocks the plan.

## Redeploys

`docker network connect` does not survive a recreate. Each network change in the preview includes the lines to add to the application's
own definition, and the manager never edits it. After a recreate the page reports drift and offers **Attach the networks again**.

## Rollback

*Roll back* restores or removes the route files, detaches only the networks this adoption attached, and removes only the Cloudflare
records it created. A failed cutover undoes what it created straight away.

**Manual reversal:** when a cutover *replaces* an existing DNS record or tunnel route (an overwrite you confirmed individually), the
old value is not restored automatically. The rollback lists each one; put the previous value back in the Cloudflare dashboard. Note it
from the cutover review before approving. Deleted old-proxy containers and networks cannot be rolled back.

## Read-only preview from a terminal

```powershell
.\scripts\Get-AdoptionPreview.ps1 -InstallPath <deployment folder> -Mode both -ExternalHost voice.example.com `
  -InternalHost voice.local.example.com -AuthEndpoint http://authentik-server:9000
```

## Tests

`tests\Test-Adoption.ps1` runs unit tests, then two disposable proxy stacks with throwaway echo containers, a fake authentik and the
Cloudflare mock. It checks that every other container keeps its ID, start time and state and that live route files keep their hashes.
`-SkipInstance` runs the unit tests only.

## Dependency on Networking v2

The `feature/networking-v2-pihole-dual-routing` worktree has uncommitted work on internal routing (`lib\Networking.psm1`,
`lib\PiHole.psm1`, a `service.internal` registry field and the `lan-secure` entry point). Adoption does not depend on it and does not
duplicate it:

- Adoption never modifies `lib\TraefikProxy.psm1` or `services.json`; it writes its own `adopt-*` files. It reads only that branch's
  `infrastructure\traefik\compose.lan.yaml` location, to detect the entry point.
- LAN DNS records are left to `lib\Networking.psm1` / `lib\PiHole.psm1`. Adoption reports internal DNS as `unverified`.
- The internal route carries its own headers middleware, so it does not need `dtc-internal-headers@file`.
- The throwaway validator on this base has no `lan-secure` entry point, so a `lan-entrypoint` target is `unverified` at Prepare. Traefik
  checks it at activation, and it cannot be tested from loopback.
- Expected merge overlap is small: one line each in `webui.ps1` (imports, static file, dispatch), `webui\index.html`, `webui\app.js`
  (navigation) and `install.ps1` (managed files).

**Open design question:** this branch's brief asks for a separate `traefik-int1`, while Networking v2 implements internal routing as an
entry point on one Traefik. Adoption works with either. A shared Traefik cannot enforce separation by proxy, so the `separation` check
only runs against separate stacks.
