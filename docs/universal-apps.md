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
| Portainer / Arcane APIs | — | Not implemented: their stacks are recognized from Docker, which is enough to integrate them |

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

authentik protection of both is verified against a real authentik only in `tests\Test-IdentityLive.ps1`; the
universal test reports it as not tested unless an identity environment is ready.

## 7. Supported and unsupported

Supported: single and multi-service Compose applications with published images; dependencies with health
conditions; generated secrets; named volumes; one web front end per application behind Traefik; ForwardAuth for
browser applications; Cloudflare publication through the existing tunnel; Portainer/Arcane/Compose/docker-run
applications integrated without taking ownership.

Not supported (refused or reported, never guessed): building images from source; `include:`/`extends:`; capabilities,
sysctls, PID/IPC namespaces, `network_mode: service:`; devices on Docker Desktop; private registries; applications
that need extra host ports for non-HTTP protocols (DNS, game servers, UDP discovery); native OIDC wiring (recognized
and recommended, configured by you in authentik and the application); Portainer and Arcane API calls; Linux, Unraid
and macOS hosts. No claim is made that every Docker image works: an imported application is `unverified` until its
deployment's stages pass, and a Compose file that validates is not a verified deployment.
