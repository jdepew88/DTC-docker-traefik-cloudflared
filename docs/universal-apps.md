# Universal application engine

DTC installs curated catalog applications, imported applications and applications other tools already run through
one model: **Discover → Analyze → Normalize → Configure → Install or Integrate → Route → Authenticate → Publish →
Verify → Maintain.** This document records the architecture audit (2026-11-19), the contract that came out of it,
what works today and what does not.

Status: implemented and tested on Windows 11 with Docker Desktop (WSL2) only, like the rest of the manager.

## 1. Architecture audit and gap analysis

The audit traced every component listed in the assignment. Most of the pipeline already treated imported and curated
applications the same way; the gaps were about applications DTC did not install, ownership, drift and pasted input.

| Area | What exists (reused) | Works for arbitrary apps? | Gap found |
| --- | --- | --- | --- |
| Manifest schema | `schema: 1` manifests, `Test-AppManifest` (`lib\AppCatalog.psm1`); imported drafts use the same schema with `source.type = imported` | Yes (`-AllowImported`) | No migration hook for future schema versions |
| Compose generation | `ConvertTo-AppComposeSet`: one project per app, `compose.yaml` + `compose.<component>.yaml`, `COMPOSE_FILE` in `.env`, private `<project>_internal` network, only the web service on the proxy network; `dtc-stack.json` (`New-AppStackManifest`) | Yes | None |
| Provisioning engine | `docs/provisioning.md`: import → draft → security review → plan → apply → journal → rollback | Yes | Only links: no pasted Compose, no pasted Unraid XML, no multi-file Compose |
| Source adapters | Docker Hub, GitHub, registries (ghcr, quay, lscr), Unraid template links, awesome-selfhosted (`lib\AppSources.psm1`, `lib\SafeFetch.psm1`) | Yes | Repeated imports created duplicate drafts |
| AI assistance | `lib\AiAssist.psm1`: opt-in, redacted, budgeted, cached, merges only into open fields | Yes | None (kept as is) |
| Recipes | `lib\Recipes.psm1`: local recipes, trust ranking, sanitized export | Yes | Trust was not shown per installed instance |
| Installed apps | `config\apps.json` instances (installed, adopted), lifecycle, updates, backups, restore, removal | Only apps DTC installed or adopted from the catalog | No record for apps owned by Portainer, Arcane or plain Compose |
| Discovery | `lib\DockerDiscovery.psm1` inventory, port probes, hostname claims; Discover page publishes a container through the Services pipeline | Yes | A published container's route had no owner and no link to the app; the management tool was not identified |
| Traefik | Explicit file-provider YAML per route (`svc-<name>.yml`), validation in a throwaway Traefik, backups, recovery points, `Find-HostnameClaims` | Yes | Routes had no ownership record |
| Identity & Access | Identity contract (7 functions in webui.ps1), `Sync-AuthentikAppProtection`, ForwardAuth middleware, re-protection fix of 2026-11-17 | Yes, by route name | Authentication choices were not reported as states per method |
| Cloudflare | Service plans for DNS, tunnel route and Access through the existing tunnel | Yes | None |
| Diagnostics | Stack & Routing view, route health, `drift` = route files that differ from the registry | Partly | No comparison of intended vs observed state for applications (containers, networks, ports, protection, ownership) |

Conclusion: no rewrite was needed. The assignment's requirements were met by adding a contract layer, an ownership
registry, a reconciliation engine and pasted-input adapters on top of the existing modules, and by recording route
ownership in the existing service registry. Public interfaces are unchanged; every addition is optional on disk
(registries written by earlier versions are read unchanged).

Duplicated logic and hard-coded assumptions found and left alone deliberately: per-application port hints in
`DockerDiscovery.psm1` and client-app patterns in `IdentityContract.psm1` are data tables, not code paths; they only
inform previews and never change an installation.

## 2. The contract: Recipe, Instance, Integration

`lib\AppContract.psm1`.

| Object | Identifier | Stored in | Holds |
| --- | --- | --- | --- |
| **Recipe** | `catalog:<id>@<manifestVersion>`, `imported:<id>`, `recipe:<id>` (`Get-RecipeRef`) | `catalog\apps\*.json`, `config\provision\drafts\*.json`, `config\recipes\*.json` | The manifest (schema 1): source and provenance, pinned images, architectures, services and roles, dependencies, settings and secrets (names only), ports, volumes, networks, health checks, web front end, authentication capabilities, backup needs, verification status, open questions |
| **Instance** | `i-<hex>` (managed) or `x-<hex>` (integrated / observed) | `config\apps.json` (managed, unchanged) or `config\applications.json` | Compose project, containers, management authority, ownership mode, observed baseline |
| **Integration** | `int-<hex>` | `config\applications.json` (inside its instance) and the route's `owner` field in `config\services.json` | The DTC-owned route, its protection and publication |

Recipe trust is separate from installation success (`Get-RecipeTrust`): `curated`, `verified-local`, `claimed`
(imported recipe) or `untrusted` (imported draft), with status `draft` (open questions or unsupported settings),
`ready` or `verified`. An image that starts is never promoted to trusted.

### Ownership modes

| Mode | DTC may | Stored |
| --- | --- | --- |
| **DTC Managed** | install, update, restart, back up and remove what it created; routes, sign-in, publication | `apps.json` |
| **DTC Integrated** | only the routes, sign-in and publication it created for the app; monitor | `applications.json` |
| **DTC Observed** | list and monitor; nothing else | `applications.json` |

A route never transfers ownership: integrating an app creates a route owned by the integration and nothing else.
Switching Integrated → Observed is only possible after its integrations are removed.

### Management authority

`Get-ManagementAuthority` reads Docker's labels and the Compose working folder and reports `dtc`, `portainer`,
`arcane`, `compose`, `docker-cli` or `unknown`, with `certain`/`likely` confidence and the evidence:

- Portainer: `io.portainer.*` labels (certain) or a working folder `/data/compose/<n>` (likely).
- Arcane: `com.getarcaneapp.*` labels (certain) or a working folder `.../data/projects/<name>` (likely).
- Compose: any other Compose project; docker run: no Compose labels.

These are heuristics for the review; DTC never acts on an authority guess, it only refuses to change containers it
does not own.

### Versioning and migration

- Manifests: `schema: 1` (unchanged). `Test-AppManifest` refuses other versions, so an older manager never installs a
  newer manifest.
- `config\applications.json`: `{ kind: "dtc-applications", contractVersion: 1, instances: [...] }`.
  `ConvertTo-CurrentContractRegistry` migrates version 0 (draft format) and refuses newer versions without changing
  the file. Every save validates the registry (`Test-ContractRegistry`), writes atomically and keeps the previous file
  as `applications.json.bak`.
- Route ownership: an optional `owner` object (`kind`, `instanceId`, `integrationId`) on a service definition, stored
  only when set, so registries written by earlier versions are byte-for-byte unchanged.

User data survives DTC updates: `config\` (apps, applications, services, drafts, recipes, journals) is never part of
the managed file list that an upgrade replaces (`Get-ManagedFileList`), which `tests\Test-Projects.ps1` covers.

## 3. Sources

All sources produce the same normalized draft (`New-NormalizedManifest`) and go through the same security review,
host compatibility check, plan, apply, journal and rollback.

| Source | Input | Status |
| --- | --- | --- |
| Curated catalog | catalog entry | Working |
| Docker Hub, registries | link or image name | Working (fixtures in tests; live fetch needs the internet) |
| GitHub | repository, folder or Compose-file link | Working |
| Compose (pasted) | 1 main file + up to 3 override files, 256 KB total; optional https project link | **New**, working |
| Unraid template (pasted) | the template XML | **New**, working (template links already worked) |
| Existing Docker apps | the engine's containers and Compose projects | **New**: integrate or observe without recreating anything |
| awesome-selfhosted | entry link | Working |
| Portainer / Arcane APIs | optional read-only connectors (section 8) | Add evidence (stack identity, status, containers); Docker discovery works without them |

Repeated imports of the same link or text return the existing draft (`importKey`); duplicates of running apps are
caught by the plan ("already runs on this PC").

## 4. Integrating an application another tool owns

`POST /api/integrations/plan` → `/apply` → (optional) `/protect` → `POST /api/integrations/remove/plan` → `/remove`.

1. The container is checked: not this deployment, not proxy/tunnel infrastructure, not a database or cache, on the
   shared proxy network (otherwise the review shows the Compose lines to add *in the owner's file*; DTC does not edit
   it), a TCP port that answers HTTP from Traefik's network.
2. The plan is the ordinary service change plan: explicit Traefik YAML (router, service, middleware references), the
   hostname-claim check, the backend test from Traefik's network and, when publication is chosen, the Cloudflare
   preview (DNS record, tunnel route, Access) through the existing tunnel.
3. Apply writes the route through the same pipeline (validation in a throwaway Traefik, backup, reload, wait for the
   router), records the integration and the observed baseline (container id, name, image, Compose project/service,
   networks, aliases, port, authority).
4. Protection uses the identity contract (`Request-IdentityProtection`), only for routes the integration owns.
5. Removal deletes only the integration's route (and the protection it set up); the container, its Compose files,
   volumes and networks are not touched.

## 5. Reconciliation (drift detection and repairs)

`lib\Reconcile.psm1`, `POST /api/applications/drift`, `POST /api/applications/repair/plan`, `/repair/apply`.

Detected: missing or stopped containers, recreated containers, changed Compose identity, changed image, changed
management tool, containers no longer on the proxy network, stale backend names, changed ports, unreachable backends
(real probe from Traefik's network), missing route files, routers Traefik did not load, references to middleware that
does not exist, protection removed outside DTC, hostnames claimed by another configuration, routes an integration
created that disappeared, missing data volumes of managed stacks, unhealthy containers.

Added after the live proofs: lost storage mounts (container paths recorded in the baseline; host paths never), a
protected route whose authentik address is out of date (`auth-endpoint-stale`, repaired to the current address with
the sign-in kept), and, with a Portainer or Arcane connector, stacks the owner reports as stopped while their
container runs, recreated containers the owner does not list, and two tools claiming one application.

Added in the release-readiness audit: a sign-in bypass through a published port (`auth-bypass-port`): a route
protected by authentik, Authelia or Cloudflare Access whose container also publishes a host port. Bound to the network
(0.0.0.0, a LAN address) it is an error, bound to 127.0.0.1 a warning (programs and users on this PC). It is reported
with the lines to remove from the owner's Compose file and never changed automatically. The authentik protection
preview shows the same warning before an application is protected, also for routes to a port on this PC
(`host.docker.internal`) that listens on all interfaces.

Repairs are journalled (`config\provision\repairs\<id>.json`): a backup of every route file and the service
registry is taken first; if a later step of a multi-step repair fails, everything goes back to that backup; a repair
interrupted by a stopped manager stays `running` and is offered for rollback (`GET /api/applications/repairs`,
`POST /api/applications/repair/rollback`). Drift is checked on request only (no background polling).

Each finding has an explanation, evidence and a repair. Repairs DTC may apply (`owner: dtc`) are route updates
(backend name, port, middleware list), route re-syncs and re-creation from the integration record; they are
previewed as an ordinary change plan and applied through the same validation, backup and rollback. Everything owned
by the application's tool is explained with the lines to change there, never applied.

## 6. Proofs of concept

`tests\Test-UniversalApps.ps1` on a disposable deployment (its own Traefik, network and Cloudflare mock):

1. **An unfamiliar application imported from pasted Compose**: a two-service application not in the catalog
   (see the test for the exact images; nothing application-specific in the engine), normalized, modular Compose
   (`compose.yaml` + `compose.database.yaml`), private database network, explicit route, real requests through
   Traefik, backup, restore, removal.
2. **An externally owned application**: a disposable Compose project created outside DTC (with a Portainer-style
   working folder), detected, integrated with a separately owned route, verified through Traefik, a controlled
   backend change detected with a proposed repair, the repair applied to the DTC-owned route, the integration
   removed, the original project unchanged (same container id, Compose files untouched).

Results on 2026-11-19 (this PC, Windows 11 + Docker Desktop, production running alongside and untouched):

- Proof 1, Miniflux (an RSS reader, not in the catalog) imported from
  `https://github.com/miniflux/v2/blob/main/contrib/docker-compose/basic.yml`: 19 passed, 0 failed. Two services,
  images pinned, the example database password embedded in `DATABASE_URL` linked to the generated database secret,
  `compose.yaml` + `compose.database.yaml`, database only on the private network without a host port, route through
  Traefik, anonymous API requests refused (401) and the generated administrator accepted (200), data written,
  backed up, deleted, restored, then removed (only the backups folder you made is kept).
- Proof 2, a Compose project with Portainer's access-control label: 17 passed, 0 failed, 2 not tested (proof 1 was
  skipped in that run; authentik needs a real identity environment).

authentik protection of an imported and of an externally owned application is verified against a real, disposable
authentik in `tests\Test-IdentityLive.ps1 -UniversalOnly` (section 7); this test reports it as not tested.

## 7. authentik ForwardAuth on imported and integrated applications

Verified live with a real, disposable authentik (`tests\Test-IdentityLive.ps1 -UniversalOnly`, which installs authentik
from the catalog, connects it, publishes its sign-in page and sets the owner, then):

- **Imported** (pasted Compose: a web service and a PostgreSQL database): provisioned with `auth = authentik`; modular
  Compose, router, service and ForwardAuth middleware; one authentik application and proxy provider; anonymous
  visitors sent to the sign-in; the owner group admitted; another signed-in user refused; a wrong password never
  admitted; no direct web port and no other route to the container; protecting again keeps `http(s)://host[:port]` on
  the provider (the 404 fix) without duplicate objects; unprotect / protect; rollback removes the route, the authentik
  objects the operation created and the containers.
- **Externally owned** (a Compose project with Portainer's label): discovered, observed, integrated after an explicit
  switch, protected through the identity contract, owner admitted / outsider refused, protected again, drift after the
  owner recreated it on another port, repair of the DTC-owned route only (ForwardAuth kept), removal of the route and
  the authentik objects the integration created; the container kept running with the same ID, networks and Compose
  file.

Defects found and fixed by this run: the objects a provisioning created in authentik were recorded as "reused", so a
rollback kept them; a provisioned application behind authentik or Cloudflare Access still published a direct web
port on 127.0.0.1, which bypassed the sign-in (now no host port is published when the route is protected).

## 8. Portainer and Arcane connectors (optional, read-only)

`lib\ExternalManagers.psm1`, Applications page > "Portainer and Arcane", `GET/POST /api/managers*`.

| | Portainer CE 2.45 | Arcane 2.16 |
| --- | --- | --- |
| Authentication | access token, header `X-API-Key` | API key, header `X-API-Key` |
| Least privilege | a token carries every right of the user who created it (CE has no read-only role). Use a dedicated non-administrator user; it sees only the stacks shared with it (stack > Access control) and **can operate those stacks' containers** | a key with `environments:list/read`, `projects:list/read`, `containers:list/read` only; writes are refused (403) |
| Read | `/api/stacks` (id, name, environment, status 1 active / 2 inactive, `/data/compose/<id>`, Git source), `/api/endpoints/{id}/docker/containers/json?all=1` | `/api/environments`, `/api/environments/{id}/projects`, `/api/environments/{id}/containers` (paginated, every page read; `/api/agents/{id}/...` only as a fallback) |
| Compose association | stack name = Compose project label of its containers | project name = Compose project label; working folder `/app/data/projects/<name>` |

DTC sends GET requests only. Keys are DPAPI secrets for this Windows account, never written to `config\managers.json`,
returned or logged. Plain http is accepted only for this PC or a private address. Snapshots are cached for 60
seconds; without a connector, or when it does not answer, ownership comes from Docker labels and Compose folders as
before. API evidence confirms Docker's guess (`confirmed`), names the owner of a plain Compose project, or reports a
`conflict`; DTC still never edits a stack or takes over its lifecycle.

**Verification levels (2026-11-19).**

| | Documented | Mock-tested (`Test-ExternalManagers.ps1`, 19) | Live-verified on disposable instances (`Test-ManagerConnectorsLive.ps1`, 14) | Verified against your installed instance |
| --- | --- | --- | --- | --- |
| Arcane 2.16.1 | OpenAPI served by the instance itself | yes (pagination, fallback path, refused key, unreachable) | yes: project + container listed with a read-only key, authority confirmed, write refused (403), wrong key refused, API down falls back to Docker evidence | **no** (needs your authorization and a key) |
| Portainer CE 2.45.2 | Portainer API | yes (stacks, containers, refused key, empty list explained) | yes: non-admin token sees only shared stacks (explained), shared stack + container listed, authority confirmed, the token can stop a shared container (documented limit), wrong token refused | **no** (needs your authorization and a token) |

Corrected by the live check: Arcane 2.16 serves projects under `/api/environments/{id}/projects` (the
`/api/agents/...` path from older documentation does not exist), its lists are paginated (only the first 20 items were
read before), and the Git field is `gitRepositoryURL`.

## 9. Add application wizard

One wizard for every source (New app page; Applications page for running containers): 1 Application source
(publisher, source, trust, open questions, security review), 2 Stack and dependencies (roles, private services, the
Compose file each service goes to), 3 Storage and networking (volumes, the web port, the absence of a host port behind
a sign-in, Docker Desktop restrictions), 4 Routing (with an exact router/service/middleware preview), 5 Authentication
(per-method states and client incompatibilities), 6 Publication (Cloudflare preview; changes only at deploy), 7 Review
and deploy, 8 Verify and manage (planned, installed, running, healthy, routed, sign-in, published, verified; a running
container is never shown healthy without its checks). Stages 2, 3 and 6 add no mandatory clicks. Detail levels are kept;
the heading of each stage receives the focus when moving between stages.

Accessibility (audited 2026-11-19 in `tests\Test-ProvisionBrowser.ps1`, every stage and the 390 px layout): every
form control and button has an accessible name, ids are unique, no positive tabindex, each stage has a heading that
receives the focus, and the stage list marks the current stage with `aria-current="step"` plus screen-reader text for
complete and unavailable stages. Not covered: a screen-reader session (NVDA/JAWS) and colour-contrast measurement.

## 10. Supported and unsupported

Supported: single and multi-service Compose applications with published images; dependencies with health
conditions; generated secrets; named volumes; one web front end per application behind Traefik; ForwardAuth for
browser applications; Cloudflare publication through the existing tunnel; Portainer/Arcane/Compose/docker-run
applications integrated without taking ownership.

Not supported (refused or reported, never guessed): building images from source; `include:`/`extends:`; capabilities,
sysctls, PID/IPC namespaces, `network_mode: service:`; devices on Docker Desktop; private registries; applications
that need extra host ports for non-HTTP protocols (DNS, game servers, UDP discovery); native OIDC wiring (recognized
and recommended, configured by you in authentik and the application); changing Portainer or Arcane stacks (the connectors only read; verified on disposable Portainer 2.45.2 and Arcane 2.16.1, not against your own instances); Linux, Unraid
and macOS hosts. No claim is made that every Docker image works: an imported application is `unverified` until its
deployment's stages pass, and a Compose file that validates is not a verified deployment.
