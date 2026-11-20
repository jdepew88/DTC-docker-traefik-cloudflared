# Installation recipes (local now, community later)

A recipe records how an application was installed on a kind of host and what was verified. Recipes work locally,
without any server; sharing is opt-in, always previewed, and never automatic. Implementation: `lib\Recipes.psm1`;
tests: `tests\Test-Provisioning.ps1` (part 1i).

## Format (recipeVersion 1)

```json
{
  "recipeVersion": 1,
  "id": "<app-id>-<12 hex>",
  "application": { "id": "uptime-kuma", "name": "Uptime Kuma", "upstream": "https://github.com/louislam/uptime-kuma", "version": "0.1.0-import" },
  "manifest": { "...": "the normalized manifest: structure only, no secret values, no folder choices" },
  "manifestSha256": "<sha256 of the manifest JSON>",
  "images": [{ "service": "uptime-kuma", "image": "louislam/uptime-kuma:2@sha256:..." }],
  "host": { "platform": "windows-docker-desktop", "os": "windows", "osVersion": "10.0.26220", "architecture": "linux/amd64",
            "kernel": "6.6.x-microsoft-standard-WSL2", "dockerEngine": "28.x", "dockerCompose": "5.5.1", "runtime": "docker-desktop" },
  "validation": { "stages": [{ "stage": "backend", "status": "passed" }], "passed": ["backend"], "failed": [], "healthCheck": true, "verifiedAt": "..." },
  "knownIssues": [],
  "provenance": { "origin": "local | curated | upstream | community", "source": "<source url>", "sourceKind": "github", "createdAt": "..." },
  "trust": { "status": "verified-local | claimed", "deployments": 1, "failureReports": 0, "securityReview": "" },
  "privacy": { "sanitized": false }
}
```

Validation (`Test-Recipe`): version, id, manifest fingerprint (a manifest changed after the recipe was made is
rejected), every image pinned by digest, a known origin, no first-start commands, no secret-looking values, no user or
home paths.

## Privacy

`New-Recipe` keeps structure only: setting names, ports, storage paths inside containers, image digests and the host
fingerprint (`Get-HostFingerprint`: platform, OS version, architecture, kernel, Docker and Compose versions; never host
name, user name, paths or addresses). Defaults of secret, password, generated and folder inputs are dropped.

Before sharing, `ConvertTo-SanitizedRecipe` replaces e-mail addresses, IP addresses, Windows and home paths, values of
fields named like passwords, secrets or tokens, and the deployment's private names (Cloudflare domains, service host
names, authentik host name, Windows user and machine names, the installation folder). The page shows exactly what an
exported file contains and what was removed (`POST /api/provision/recipe/share`). Nothing is uploaded; declining has no
effect on local functionality.

## Trust and ranking

Claims and verified results are kept apart: a recipe created and verified by this manager is `verified-local`; an
imported recipe is always `community` / `claimed`, whatever it says about itself. `Get-RecipeRanking` explains every
score:

| Signal | Points |
| --- | --- |
| Origin: curated / upstream / local / community | +50 / +30 / +20 / +10 |
| Same host platform | +20 |
| Different CPU architecture | -100 (listed as incompatible) |
| Verified by this manager | +15 |
| Independent successful deployments | +3 each beyond the first, at most +15 |
| Health-check evidence | +10 |
| Verified in the last 90 days / older than a year | +10 / -10 |
| Failure reports | -15 each |
| Rejected by security review | -50 |

Popularity alone never wins; conflicting recipes for different hosts or versions coexist. A successful HTTP response
alone does not prove a correct or secure configuration: recipes carry the stage results, and every recipe still goes
through the security review, host compatibility and your approval before anything runs. Community recipes are data,
never scripts.

## Local store and files

`config\recipes\<id>.json` in the deployment. API: `GET /api/provision/recipes?app=<id>` (ranked for this host),
`POST /api/provision/recipe/save` (from a deployment's journal), `POST /api/provision/recipe/share` (sanitized preview
= export), `POST /api/provision/recipe/import` (validated, stored as community/claimed).

## Future registry protocol (draft, not implemented)

`dtc-recipes/1`, designed so the engine never depends on it being online:

- `GET /v1/apps/{appId}/recipes?platform=&arch=` → signed index of recipe summaries (id, host, trust signals, digest).
- `GET /v1/recipes/{id}` → the recipe document (as above, sanitized), with the registry's signature.
- `POST /v1/recipes` (opt-in, authenticated contributor, rate limited) → submission of a sanitized recipe; the
  registry re-runs `Test-Recipe`, records the submission as a claim, and counts independent deployments by distinct
  contributors.
- `POST /v1/recipes/{id}/reports` → success or failure report (stage results only).
- Trust model: registry signatures (Ed25519) verified locally against pinned keys; security review states
  (`pending`, `approved`, `rejected`); curated recipes signed by the project; local verification always outranks remote
  claims; a remote outage or revoked key leaves local recipes untouched.

No registry is configured in this version (`Get-RecipeRegistryInfo`).
