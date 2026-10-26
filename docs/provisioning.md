# Universal provisioning engine (New app)

Paste a link, and the Deployment Manager works out how to install the application (**Container**), where it is
reachable (**Reverse proxy**) and who may open it (**Authentication**). One review lists everything that will happen;
nothing is installed, routed or published before you approve it.

Status in this version (2026-10-26): implemented and tested on **Windows 11 with Docker Desktop (WSL2)** only.
Other hosts are designed (host adapters below) but not tested and not offered.

## Pipeline

```
link ──> source adapter ──> normalized manifest (draft) ──> security review + host compatibility
          (SafeFetch)        (lib\AppSources.psm1)          (lib\ProvisionPolicy.psm1, lib\HostPlatform.psm1)
                                   │  open questions?
                                   ├──> you answer (web port, settings)          ── deterministic first
                                   └──> optional AI proposal (lib\AiAssist.psm1)  ── only on approval, merged into
                                                                                     open questions only
review (POST /api/provision/plan) = App Catalog installation preview + service change plan (Traefik YAML, Cloudflare)
                                    + Identity & Access preview (identity contract)
apply  (POST /api/provision/apply) = install → backend check → route (not public) → authentik → publish → verify
journal (config\provision\operations\<id>.json): every resource created / reused / modified / shared
rollback: only what the journal says this operation created or modified
```

Discovery, interpretation, planning, validation and execution are separate: the importers never run Docker commands
that create anything (Compose files are parsed by `docker compose config` in an empty temporary folder, with no
interpolation, no env files and no path resolution); only the apply step changes anything, through the existing
installers.

## Order of preference

1. Verified locally maintained recipe: the curated App Catalog (`catalog\apps`). When an import matches a catalog
   application, the draft says so and recommends the catalog.
2. Compatible verified community recipe (local recipe store; see [community-recipes.md](community-recipes.md)).
3. Official upstream Compose configuration (GitHub repositories, Compose files, Compose examples in a Docker Hub README).
4. Deterministic translation from structured metadata (Unraid templates, image configuration from the registry).
5. AI-assisted completion of what is still unknown (optional, approved per request).

## Sources

| Source | Accepted input | What is read | Notes |
| --- | --- | --- | --- |
| Docker Hub | `https://hub.docker.com/r/<ns>/<repo>`, `/_/<name>`, image names | repository API (description, README), tags, registry manifest index (platforms, digest), image configuration (exposed ports, volumes, labels: licence, source) | A Compose example in the README is preferred; otherwise one service from the image. No exposed port means an open question, never an invented port |
| GitHub | repository URL, `/tree/<ref>/<dir>`, `/blob/<ref>/<file>`, raw links | repository API (description, licence, topics, archived), latest release, Compose file in the root, `docker/`, `deploy/`, `docker-compose/`, `compose/`, `contrib/docker/`, `.env.example` defaults | `build:`-only services are unsupported (published images only) |
| Other registries | `ghcr.io/…`, `quay.io/…`, `lscr.io/…` image names | OCI distribution API with the standard anonymous bearer challenge | Private images are refused |
| Unraid | raw template XML (`raw.githubusercontent.com/...xml` or GitHub blob links) | `<Container version="2">`: Repository, Network, Privileged, WebUI, Config (Port, Path, Variable, Device), ExtraParams, Overview, Project, Support, Licence | Parsed without DTDs or external entities. Plugins (`<PluginURL>`, `.plg`) are refused. Community Applications web pages are not scraped: paste the template link |
| awesome-selfhosted | entries in `awesome-selfhosted-data/software/*.yml` | name, description, licences, website, `source_code_url` | Discovery only: the source repository is imported; attribution (CC BY-SA 3.0) is kept |

Unraid translation on Docker Desktop: `/mnt/user/appdata/...` becomes a named volume; other shares become a named
volume you may replace with a folder of this PC; PUID/PGID 99:100 (Unraid's nobody:users) become 1000; masked
variables become generated secrets; custom networks (`br0`, macvlan) are explained and replaced by the bridge network
behind Traefik; devices and `--cap-add` are reported (devices are not available in Docker Desktop containers).

**Adding a source:** write a function that returns facts and a Compose-like model (`services.<name>` with `image`,
`ports`, `volumes`, `environment`, `depends_on`, `healthcheck`, `command`, …, the same shape as `docker compose config
--format json`), call `ConvertFrom-ComposeModel` and `New-NormalizedManifest`, then `Complete-ImportedImages`; add the
link pattern to `Get-AppSourceKind`, the host to the SafeFetch allow-list, fixtures and tests to
`tests\Test-Provisioning.ps1`. Never run anything from the source; never add an undocumented endpoint.

## Normalized manifest

Imported applications use the catalog's DTC manifest (schema 1, [app-catalog.md](app-catalog.md)) with
`source.type = 'imported'`, so the same validation (`Test-AppManifest -AllowImported`), Compose generator, lifecycle,
updates, backups and removal apply. Extra fields:

| Field | Meaning |
| --- | --- |
| `source` | `type: imported`, `kind` (dockerhub, github, unraid, registry), `url`, `upstream` |
| `provenance` | source type and URL, retrieval time, fetched documents (URL, kind, SHA-256), attribution, licence |
| `verification` | `status` (`unverified` until a deployment's stages pass), checks |
| `authentication` | `forwardAuth` suitability, `native` (e.g. OIDC found in settings or documentation) |
| `architectures` | platforms the web image is published for (from the registry index) |
| `hardware` | `gpu`, `devices`, `hostNetwork` |
| `knownIssues`, `recipes` | notes for the review; recipe references |
| `draft.unresolved` | open questions (field + reason); they are review items until answered |
| `draft.unsupported` | settings the manager does not generate (block installation as imported) |
| `draft.evidence` | where each value came from (field, value, source, how) |
| `draft.assumptions` | AI answers to check (prefixed `AI:`) |

Images are pinned by digest from the registry (`name:tag@sha256:…`); an image that cannot be pinned blocks
installation. Tag choice: the stable version tag that `latest` points to, else the newest stable version, else
`latest` (pinned). Updates are never automatic.

## Compose generation and dependencies

The Compose project is generated by the catalog generator (`ConvertTo-AppCompose`), never copied:

- One project per application, in its own folder next to the proxy deployment; the imported manifest is kept as
  `.dtc-manifest.json` next to `compose.yaml` (start, update, backup and removal use it).
- Only the web service joins the shared proxy network (`proxynet`); databases, caches, brokers, workers and jobs stay
  on the project's private network. Only the web port is published, on `127.0.0.1`.
- Dependencies come from the source (`depends_on` with conditions, health checks); nothing is invented. Roles come
  from images (PostgreSQL/MariaDB/MongoDB = database, Redis/Valkey = cache, NATS/RabbitMQ = messaging), from
  `service_completed_successfully` (one-time jobs) and from names (worker).
- Every application gets its own database container and volume; it is never connected to another PostgreSQL.
- Secrets: variables named like passwords, tokens or keys become generated secrets (24 random bytes); example values
  in the source are never used; the same variable shared by the application and its database stays one secret. They
  live only in `.env` (restricted ACL); `compose.yaml` references `${VAR}`.
- Storage: named volumes (`<project>_<name>`); project-relative bind mounts become named volumes; other host folders
  become named volumes you may replace with a folder you choose; host system paths are refused.
- Checks before installation: project and folder free, port free, existing installations (also unregistered
  containers running the same image), volumes, shared network, memory, disk, `docker compose config`.

Lifecycle (prepare, preview, validate, install, start, stop, restart, health, update, backup, restore of data, remove)
is the App Catalog's (Installed apps page); removal of data is separate from removal of containers.

## Reverse proxy (explicit Traefik file provider)

The route is a regular service definition (`config\services.json` → `traefik\dynamic\svc-<project>.yml`) created
through the existing change pipeline (validation in a throwaway Traefik, backups, recovery points). The backend is the
web container's DNS name on the shared network and its container port (stable across container recreation). Traefik's
Docker provider stays disabled; `traefik.*` labels in imported files are ignored (noted in the draft); one hostname has
one owner (`Find-HostnameClaims`).

Access choices: **Only this PC** (127.0.0.1 port, no route), **A host name on your network** (route only; in this
deployment Traefik listens on 127.0.0.1, so other devices reach it only after a LAN binding, which the provisioner does
not change), **A public address** (route + Cloudflare). Remote-server access is not implemented.

## Cloudflare publication

Public hostnames must be in one of the deployment's Cloudflare domains. The existing tunnel is used (never a new one
per application); DNS record, tunnel route and, when chosen, a Cloudflare Access application are planned by the
existing Cloudflare service plan. Existing DNS records are never overwritten without an explicit confirmation of that
resource. Publication runs only after the route works and, with authentik, after protection is verified.

## Identity contract (authentik)

The provisioner never talks to authentik: it calls Identity & Access through seven functions in webui.ps1 ("Identity
contract" section), with the shared decisions in `lib\IdentityContract.psm1`. See the checkpoint
[provisioning-identity-compatibility.md](provisioning-identity-compatibility.md).

| # | Operation | Implementation |
| --- | --- | --- |
| 1 | List configured providers | `Get-IdentityContractStatus` → `Get-ContractProviders` (authentik integrated; Authelia install-only) |
| 2 | Provider readiness | `Get-IdentityReadiness` from the Identity & Access context (installation running, on the proxy network, token accepted, outpost, public sign-in address, owners group) |
| 3 | Can this application be protected | `Get-ProtectionCompatibility` (apps with their own clients, native OIDC) + refusal of authentik's own sign-in page |
| 4 | Preview | `Get-IdentityProtectionPreview` → `Sync-AuthentikAppProtection -WhatIf` (create or reuse `dm-<service>`) |
| 5 | Request protection | `Request-IdentityProtection` → the existing protect plan/apply (authentik first, wait for the outpost, then the route) |
| 6 | Verify | `Test-IdentityProtection` → `Test-ForwardAuthChallenge` (an anonymous request must be sent to sign in) |
| 7 | Roll back | `Undo-IdentityProtection` → route first, then unassign the provider; delete the application and provider only when this operation created both |

Never touched by the provisioner: authentik installations and their Compose projects, PostgreSQL volumes, the Google
source, flows, brand/login page, the owners group, other applications and their policies, Cloudflare Access policies
of other hostnames. If authentik is not ready, authentik protection is not offered; an application chosen for
authentik is never published before protection is verified.

## Verification

Each stage is checked on its own and reported as passed, failed, not tested or does not apply:

`compose` (docker compose config) · `images` (present, pinned) · `containers` · `dependencies` (health checks) ·
`backend` (a real request from the proxy network) · `docker-dns` · `router` (Traefik router loaded and answering) ·
`cloudflare` (DNS record and tunnel route) · `public` (a real HTTPS request through Cloudflare; a sign-in page proves
only that the protection layer answers) · `auth-challenge` and `unauthorized-rejected` (anonymous request sent to sign
in) · `authorized-access` (not tested: needs your real sign-in).

## AI assistance

Off by default. Provider-independent interface (`Get-AiProviders`): `anthropic` is implemented (your own API key,
stored with DPAPI, never shown or logged); `openai-compatible` is planned; a Claude Code subscription is not an API
key and is never used. Default model `claude-haiku-5-5` (small); escalation to `claude-sonnet-5-5` only when allowed in
the settings.

- Asked only about the draft's open questions; answers are structured JSON (JSON schema output) with evidence quotes,
  assumptions and uncertainties, merged only into open fields: web port, setting names (secrets become generated
  values; defaults only for non-secret settings), storage paths. Commands, entrypoints, privileges, devices, host
  paths, first-start steps and dependencies are never applied (dependencies are listed for you).
- Context: application structure with setting names (never values), the open questions and the documentation
  sections most likely to answer them, within a character budget; everything private is removed first (secrets,
  tokens, JWTs, API keys, e-mail and IP addresses, Windows and home paths, your domains, host names, user and machine
  names). Documentation is marked untrusted in the prompt.
- Cost control: an upper-bound estimate before every request (input tokens from size, output bounded by max tokens, at
  the published price: Haiku 5.5 $0.10 / $0.50, Sonnet 5.5 $2 / $10, Opus 5.5 $4 / $20 per million input/output
  tokens, cached 2026-10-06); approval of that estimate per request; per-request limit (default $0.05) and monthly
  limit (default $2.00); identical requests are answered from `config\ai-cache` at no cost; actual usage from the
  API's token counts is recorded in `config\ai-usage.json`. A typical draft costs well under one cent with Haiku 5.5.
- Never used during deployment.

## Security boundaries

| Risk | Control |
| --- | --- |
| SSRF, local or private resources | https only, port 443, no credentials in URLs, allow-listed hosts only, every resolved address must be public (IPv4/IPv6, mapped, CGNAT, link-local metadata), redirects re-checked (at most 4), bearer tokens never follow a redirect |
| Oversized downloads | size limit per document (read incrementally), 256 KB Compose files, 1 MB XML |
| XML external entities | DTDs prohibited, no resolver |
| Compose directives that read host files | `include:` and `extends:` refused; `docker compose config` without interpolation, env files or path resolution |
| Embedded shell commands | commands and entrypoints shown in the review; shell commands are review items; AI can never add one; imported apps may not run first-start steps |
| Privileged containers, Docker socket, devices, host network | declared privileges, high-risk findings, explicit acknowledgement plus the installer's privilege confirmation |
| Host filesystem mounts | system paths refused; other host folders only when you choose them |
| Capabilities, sysctls, PID/IPC namespaces, secrets/configs, `network_mode: service:` | unsupported (block): a curated recipe is needed |
| Untrusted registries, supply chain | digest pinning (unpinned blocks), unknown registries are review items, platforms checked |
| Unexpected port publication, public databases | only the web port, on 127.0.0.1; databases never on the proxy network |
| Prompt injection through documentation | documentation marked untrusted; the model may only fill open fields; validators run on everything |
| Weakening existing security | no change to Traefik bindings, other routes, Access policies, identity settings; protected apps never published unprotected |

## Host platforms

`lib\HostPlatform.psm1` describes each host: architectures, host-gateway name, Docker socket, appdata root, secret
store, file permissions, GPU, devices, host networking, UDP ports, firewall, startup and management access.

| Adapter | Status |
| --- | --- |
| Windows 11 + Docker Desktop (WSL2) | implemented, tested |
| Debian / Arch with Docker Engine | planned (systemd, `/opt/appdata`, POSIX permissions, NVIDIA toolkit) |
| Unraid | planned (`/mnt/user/appdata`, older Docker/Compose versions recorded in recipes) |
| macOS + Docker Desktop | planned (no GPU or devices, amd64 emulation) |
| Headless VPS | planned: the manager stays on 127.0.0.1; first access through an SSH tunnel with a one-time bootstrap token, then an approved Cloudflare Tunnel hostname behind Access or authentik; never an unauthenticated public port; "localhost" is the server, not your browser |

## Testing and rollback

- `tests\Test-Provisioning.ps1` (93 checks; `-SkipDocker`: 77): URL safety, sources through fixtures, Compose and
  Unraid translation, security review, host compatibility, the identity contract against an in-memory authentik, AI
  (mocked provider), recipes, the web API on a throwaway instance, and one real disposable two-service deployment
  (local Traefik image, nothing downloaded) with verification and rollback; every other container keeps its ID and
  start time.
- `tests\Test-ProvisionBrowser.ps1`: the New app page in headless Edge with an in-page API stand-in.
- Rollback (`POST /api/provision/rollback`, preview first): Cloudflare records and the route the operation created, its
  authentik objects (only those it created), then the Compose project; data volumes only with *delete data* and the
  project name typed. Reused and shared resources are listed as kept.

## Not supported / known limitations

Building images from source; applications that need extra host ports (DNS servers, game servers, UDP discovery);
`network_mode: service:<x>` (VPN sidecars); capabilities and sysctls; devices on Docker Desktop; private registries;
multi-file Compose projects (`include`, `extends`, external env files); Kubernetes/Helm; CA web pages (use template
links); LAN access while Traefik listens on 127.0.0.1; native OIDC/SAML wiring (recognized and recommended, configured
in authentik and the application by you); Authelia protection; remote-server access; automatic dependency proposals
from AI; a community recipe server.
