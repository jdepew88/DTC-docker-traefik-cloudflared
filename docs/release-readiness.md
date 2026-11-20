# Release readiness: Universal Application Engine (audit of 2026-11-19)

Scope: the `development` branch after `beafded` (universal application engine, authentik ForwardAuth and recovery,
Portainer/Arcane connectors, 8-stage Add application wizard, drift repairs) on its way to the first controlled
production upgrade from the installed manager 1.1.0. Nothing was merged, deployed or changed in production during
this audit; production was inspected read-only.

**Verdict: ready for a controlled upgrade once the owner approves the merge**, with the open items in §8. No blocking
defect is known. The three items that are *not* verified are listed as such and are not release blockers.

## 1. Identity (authentik)

| Check | Result |
| --- | --- |
| Full `tests\Test-IdentityLive.ps1` (disposable authentik; install, onboarding, Google wizard, ForwardAuth, universal apps, recovery, browser pages, teardown) | **170 passed, 0 failed**, clean teardown, 34 other containers unchanged. A rerun on the final code passed all 148 checks it reached (everything except the browser pages, including the universal and recovery sections) and was stopped because Windows commit headroom fell to 0.86 GB; the browser pages passed in the first run and in the browser suites (§7) |
| The 4 checks that failed in the previous full run (Google wizard steps, question-mark help, verified owner state, a page script error) | **all pass**: the recovery section now restores the outpost address |
| Re-protection 404 | **fixed and still verified**: "protecting again keeps http://host:port, the owner still reaches the app (no 404), no duplicate objects" (universal A) and the batch protection checks |
| authentik backup and disaster recovery | verified in the same run (users, groups, source secret, rules, policy, API token, protected access back after losing the database volume, media and `.env`; corrupted archive rolled back) |

Remaining authentication issues: none failing. Published host ports that bypass the sign-in exist in production
(§3). Google sign-in itself is not exercised end to end (needs Google).

## 2. External managers (Portainer, Arcane)

| | Documented | Mock-tested | Live on disposable instance | Your installed instance |
| --- | --- | --- | --- | --- |
| Arcane 2.16.1 | instance's own OpenAPI | 19 checks (with Portainer) | 7 checks | not connected |
| Portainer CE 2.45.2 | Portainer API | (same suite) | 5 checks | not connected |

`tests\Test-ManagerConnectorsLive.ps1` (14 passed) runs the catalog versions in throwaway containers, creates one stack
in each through the tool's own API and reads it with a least-privilege credential. Defects found and fixed:
Arcane 2.16 serves projects under `/api/environments/{id}/projects` (the `/api/agents/...` path tried first does not
exist), its lists are paginated (DTC read only the first 20 containers, so a project's containers could be missing),
and the Git field is `gitRepositoryURL`. Portainer: a non-administrator token sees only stacks shared with it; DTC now
says so instead of reporting an empty, healthy result. A Portainer CE token cannot be read-only (verified: the
shared-stack token can stop a container); DTC only sends GET requests. Arcane read-only keys are enforced (a stop is
refused with 403).

Requires your authorization: connecting DTC to your own Portainer and Arcane (create the key/token yourself; DTC
never creates or extracts one).

## 3. Security

**Credentials** ([credential-portability.md](credential-portability.md)): Cloudflare, authentik, connector and AI keys
are DPAPI-encrypted for the Windows account with an owner-only ACL; the tunnel token and application `.env` files are
plain text with an owner-only ACL (cloudflared and Compose need them). Configuration backups never contain a
credential (pattern checks and refusal); application backups do contain the application's secrets and are not
downloadable from the manager. Moving to another user or PC means re-entering credentials (DTC never decrypts or
migrates them on its own); Linux is not supported yet. A passphrase-protected "recovery kit" is proposed as a staged
design, not implemented.

Fixed in this audit: configuration backups now include `config\applications.json` and `config\managers.json` (the
registry of integrated/observed applications and connector addresses were lost on a restore); restore creates them
only when missing and refuses a registry from a newer manager; connector keys and the AI key are listed among the
credentials to reconnect; a rotated tunnel token's backup copy now gets the owner-only ACL.

**Authentication bypass.** New drift finding `auth-bypass-port` and a warning in the protection preview when a
protected route's container publishes a host port (or a host-port route listens on all interfaces). Never changed
automatically. Production today (read-only inspection):

| Route (authentik-protected) | Direct path that skips the sign-in | Severity | Owner action |
| --- | --- | --- | --- |
| arcane, channels-dvr-server, homepage, manager (traefik-manager), photos (immich), rocket-chat, uptime-kuma | each container publishes its web port on `127.0.0.1` | warning: anyone on this PC | remove the `ports:` entry in each app's Compose file if nothing local needs it |
| prowlarr | `0.0.0.0:9696` (MediaFusion Compose project) | **error: reachable from the network** unless Windows Firewall blocks it | bind to 127.0.0.1 or block in the firewall, then check the route |
| notflix | a Node process listening on `0.0.0.0:8420` | **error: reachable from the network** unless Windows Firewall blocks it | same |

## 4. Ownership and routing

Verified live (IdentityLive universal B in this audit; the `Test-UniversalApps.ps1` proofs passed earlier the same
day and were not rerun): an externally owned Compose project is discovered,
inspected, integrated with a DTC-owned route, protected through authentik, checked for drift after its owner recreated
it with another port, repaired by changing only DTC's route (the owner's Compose file and container untouched), and
disconnected without removing the container. Ownership metadata follows the Compose project/service identity across
container recreation (`identity-changed` only when the identity really changes). Removal deletes only routes whose
`owner.instanceId` matches; shared middleware is never deleted (a missing reference is removed from the route only).

## 5. User interface

8-stage wizard (`tests\Test-ProvisionBrowser.ps1`, 27 checks): stages, focus on each stage heading, 390 px layout,
detail levels, previews (Compose files, Traefik YAML, Cloudflare publication, authentik objects), persistent drafts,
rollback of an interrupted install. New accessibility audit at every stage and on mobile: named controls and buttons,
unique ids, no positive tabindex, stage heading, `aria-current` on the current stage: **no findings**. Fixed: the
stage list's accessible name still said "New app steps". Not done: a real screen-reader session and colour-contrast
measurement. Externally running applications are integrated from the Applications page by design (the wizard says so);
catalog apps can open in the wizard, and the catalog keeps its quick install form.

## 6. Upgrade

See [production-upgrade.md](production-upgrade.md). Production runs the installed manager **1.1.0** (2026-10-21) in
`traefik-proxy`, but the manager in daily use is the **development edition** started by the tray launcher from the
development worktree (running since 2026-11-16 with that day's code). Stack files are identical between production and
development, so the upgrade changes manager code only: **no downtime** for applications, Traefik, cloudflared or
authentik; the manager UI is unavailable for a few minutes. `tests\Test-UpgradePreflight.ps1` rehearsed the upgrade
on a copy of production with Docker read-only (`13 passed, 0 failed`): no file deleted, no configuration changed, opening
the new manager writes nothing; only the Traefik reload helper and health-probe containers touch Docker. Rollback
restores the manager files from a full pre-upgrade copy (an installer `-Rollback` alone is not reliable, see the doc).

## 7. Tests run (sequentially, 2026-11-19)

| Suite | Result |
| --- | --- |
| `Test-IdentityLive.ps1` (full, live, disposable authentik) | 170 passed, 0 failed; rerun on the final code: 148 passed, 0 failed, stopped before the browser pages (commit headroom 0.86 GB), resources swept |
| `Test-ManagerConnectorsLive.ps1` (live, disposable Portainer / Arcane) | 14 passed, 0 failed |
| `Test-UpgradePreflight.ps1` (copy of production, Docker read-only) | 13 passed, 0 failed |
| AppContract | 48 passed (1 new: sign-in bypass) |
| ExternalManagers | 19 passed (updated to the live-verified Arcane API; 1 new) |
| Provisioning | 95 passed |
| AppLifecycle | 73 passed |
| ServiceConfig | 63 passed |
| BackendResolver | 60 passed |
| Catalog | 102 passed |
| Identity | 94 passed |
| AuthRouting | 49 passed |
| Routing | 30 passed |
| Backup | 47 passed (2 new: registry/connectors in backups) |
| Discovery | 79 passed |
| Explorer | 51 passed |
| WebUi | 95 passed, 1 skipped (pre-existing skip) |
| Projects | 48 passed |
| Launcher | 75 passed |
| ApplicationsBrowser | 20 passed |
| ProvisionBrowser | 27 passed (1 new: accessibility audit of every stage) |
| UiBrowser | 71 passed |
| AppsBrowser | 35 passed |
| RoutingBrowser | 20 passed |
| IdentityWizardBrowser | 15 passed |
| IdentityProtectBrowser | 18 passed |
| ui-logic (node) | 50 passed |

No suite failed. Not rerun in this audit: the 30-plus catalog live installations (`Test-CatalogInstall.ps1`, last run
2026-11-17; the catalog manifests did not change) and `Test-UniversalApps.ps1` (passed earlier on 2026-11-19).

Resources: free RAM stayed between about 4 and 11 GB during testing (floor 2 GB; optional stacks stopped at the
owner's request) until the last IdentityLive rerun, which was stopped at 2.0 GB free / 0.86 GB commit headroom; every disposable resource (`tpx-`/`tpm-`) was removed and the 34 non-test containers were
unchanged after each live run.

## 8. Open items (not blocking)

1. The owner's approval to merge `development` into `main` and to run the upgrade procedure.
2. Connectors against the owner's own Portainer/Arcane (needs a key/token the owner creates).
3. Production sign-in bypasses in §3 (owner's Compose files / firewall).
4. A screen-reader session and contrast measurement of the wizard.
5. A full authentik start from a dump-only restore into a newer PostgreSQL (documented, dump verified).
6. Portable credential recovery (design only).
