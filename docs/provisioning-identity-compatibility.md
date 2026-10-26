# Authentik compatibility assessment (checkpoint before the universal provisioning engine)

Written 2026-10-26 on `development` at `f524bc2` (identical to `main`), working tree clean, before any provisioning
code touched authentication. The existing Identity & Access work was inspected in code, not taken from earlier
prompts.

## Existing modules

| Module | Responsibility | Status |
| --- | --- | --- |
| `lib/IdentityProvider.psm1` | Provider list (`Get-IdentityProviders`), `config\identity.json` (choice, adopted/installed authentik, public hostname, Google client ID, owner, protected apps `authentik.apps.<service>`), discovery of authentik installations, the pure setup model (`Get-IdentityModel`) | Implemented, unit tested |
| `lib/Authentik.psm1` | authentik REST API: health, token check, overview (flows, outpost, sources), Google OAuth source, owners group and owner-only access, Google-first login page and its restore, `Sync-AuthentikAppProtection` (proxy provider `dm-<service>`, application, owner-only binding on a new app, outpost assignment and browser host), `Remove-AuthentikAppProtection` (unassign; `-DeleteObjects` deletes app + provider), `Test-ForwardAuthChallenge`, `Wait-AuthentikOutpost`, evidence of real sign-ins | Implemented, unit tested; live test exists (`Test-IdentityLive.ps1`, disposable authentik) |
| `lib/TraefikProxy.psm1` | Explicit file-provider YAML per service (`svc-<name>.yml`) including the `svc-<name>-authentik` ForwardAuth middleware when `auth.provider = authentik`; validation in a throwaway Traefik; registry | Implemented, tested |
| `lib/SecretStore.psm1`, `lib/CredentialManager.psm1` | DPAPI secrets (authentik API token, Cloudflare token), managed-credential checks | Implemented, tested |
| `lib/RoutingModel.psm1` | Per-hop routing view including the auth hop | Implemented, tested |
| `webui.ps1` (Identity section) | `Get-IdentityContext`, plan/apply endpoints for adopt, token, hostname, outpost, owner, Google, login page, `protect`/`unprotect` (`Get-ProtectRequest`, `Invoke-IdentityProtectPlan`/`Apply`: authentik first, wait for the outpost, then the Traefik route; verified by an anonymous challenge) | Implemented, tested (Test-WebUi, browser suites) |
| `webui/identity.js`, `webui/logic.js` | The nine-step wizard, protection management (steps 8/9 verified from live state) | Implemented, browser tested |

**Partially implemented / planned:** Authelia is install-only (no integration, status `install-only`); a real external
Google sign-in test and Access apps in front of the other seven services are pending user approval; native
OIDC/SAML wiring per application does not exist (only ForwardAuth).

## Baseline tests (2026-10-26, before changes, run sequentially)

| Suite | Result |
| --- | --- |
| ui-logic (`node tests/ui-logic.test.js`) | 46 passed |
| Test-Identity (with the throwaway Traefik) | 93 passed |
| Test-AuthRouting | 46 passed |
| Test-Routing | 30 passed |
| Test-AppLifecycle -SkipDocker | 54 passed, 1 skipped |
| Test-Catalog -SkipBrowser -SkipInstance | 30 passed |
| Test-WebUi (installation, Cloudflare previews, recovery, backups) | 95 passed, 1 skipped |
| Test-IdentityProtectBrowser | 18 passed |
| Test-IdentityWizardBrowser | 15 passed |

Not run: Test-IdentityLive (memory-heavy disposable authentik; free memory was 0.8-2.9 GB), Test-UiBrowser (known
pre-existing failure in the service wizard's backend-address section, unrelated to identity).

## Public interfaces the provisioner reuses

- Provider list and status: `Get-IdentityProviders`, `Get-IdentityModel` (component states), `Get-IdentityContext`.
- Protection: `Get-ProtectRequest` + `Build-ChangePlan` (one change body for Traefik and Cloudflare),
  `Sync-AuthentikAppProtection -WhatIf` (preview) and without `-WhatIf` (apply), `Wait-AuthentikOutpost`,
  `Test-ForwardAuthChallenge`, `Remove-AuthentikAppProtection`.
- Ownership: `Set-IdentityApp` / `Get-IdentityApp` in `config\identity.json`.

## Missing interfaces (extended, not duplicated)

1. A **contract** the provisioner calls instead of individual endpoints: list providers, readiness, can-protect,
   preview, request, verify, roll back. Implemented as thin functions in `webui.ps1` over the functions above, with
   the pure decisions in `lib/IdentityContract.psm1` (readiness, protectability, rollback plan). No second
   authentication subsystem, no direct database access, no new authentik object types.
2. **Protecting a route that does not exist yet**: today protection needs an existing service route. The
   provisioner creates the route first *without* public exposure, protects it through the same apply path, and only
   then publishes it (so a protected app never becomes public unprotected, even for a moment).
3. **Ownership for rollback**: the provisioning journal records which authentik objects the approved operation
   created (from the `Kind = create` actions of `Sync-AuthentikAppProtection`) or reused. Rollback deletes only
   objects it created (application + provider + its owner-only binding, via `Remove-AuthentikAppProtection
   -DeleteObjects` when both were created by the operation), otherwise only unassigns the provider from the outpost.
   The outpost, owners group, Google source, flows and brand are shared and never removed.

## Potential conflicts

- Names: authentik objects are `dm-<service>`; the provisioner uses the same service name for the route, so an
  imported app whose service name already exists in authentik is **reused** (reported as reuse), never recreated.
- Route ownership: one hostname, one owner (`Find-HostnameClaims`); Docker-label routing stays disabled; imported
  Compose files' `traefik.*` labels are dropped (noted in the draft).
- `config\identity.json` keeps being written only by the identity functions.
- The authentik sign-in service itself can never be protected by authentik (existing refusal reused).

## What the provisioner may do (through the contract)

Read identity state; preview protection; after the user approves the combined deployment review: create or reuse
`dm-<service>` (provider, application, owner-only binding on a new application), assign it to the embedded outpost,
add the ForwardAuth middleware to the new app's own route, verify with an anonymous request, and on rollback remove
only what that operation created.

## What it must never do independently

Create, rename or delete authentik installations, Compose projects, PostgreSQL volumes or credentials; touch the
Google OAuth source, flows, brand/login page, owners group or other applications' policies; change the outpost
other than assigning/unassigning the new app's provider; change other routes' middleware or Cloudflare Access
policies; read or write authentik's database; store or log the API token or client secrets; publish an app
selected for authentik protection before protection is verified.
