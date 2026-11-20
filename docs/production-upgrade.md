# Production upgrade and rollback: Deployment Manager 1.1.0 → Universal Application Engine

Prepared 2026-11-19 during the release-readiness audit. **Nothing here has been executed against production.** Every
step needs the owner's approval at the time it is run.

## 1. What is installed today (read-only inspection, 2026-11-19)

| Item | Production state |
|---|---|
| Deployment folder | `C:\Users\Joe\.docker\projects\traefik-proxy`, Compose project `traefik-ext1` |
| Installed manager copy | Manager **1.1.0**, installed 2026-10-21 by `install.ps1` (33 managed files, all unmodified since; 5 library modules). `backups\20261021-054447` holds its predecessor. |
| Manager actually in use | The **development edition** started by the DTC tray launcher from `...\traefik-cloudflared-windows-development` (port 8290, state `%LOCALAPPDATA%\TraefikProxy-dev\...`), default deployment `traefik-ext1`. The running process started 2026-11-16 17:23 and holds the code of that moment in memory; restarting it loads whatever the development worktree contains. |
| Stack containers | `traefik-ext1-traefik`, `traefik-ext1-cloudflared`, `traefik-ext1-socket-proxy` (restart: unless-stopped) |
| Traefik dynamic configuration | `traefik\dynamic\` (12 `svc-*.yml` routes, `security.yml`, `dashboard.yml`, `admin-dashboard.yml`) |
| Cloudflare connector | `cloudflared` in `traefik-ext1` with the token in `secrets\cloudflare_tunnel_token` (Docker secret); tunnel and Access settings in `config\cloudflare.json` |
| authentik | Separate Compose project `authentik` (`C:\Users\Joe\.docker\projects\authentik`): `./data`, `./certs`, `./custom-templates`, database volume `authentik_database` (PostgreSQL), networks `proxynet` + `authentik_internal` |
| Networks the stack depends on | `proxynet` (shared, external), `traefik-ext1_tunnel` (172.31.249.0/28), `traefik-ext1_socket-internal` |
| Configuration | `config\services.json`, `cloudflare.json`, `setup.json`, `dashboard.json`, `identity.json`, `credentials.json`, `apps.json`, `provision\` (the last three were written by the development edition) |
| Secrets | `secrets\` (DPAPI files for Cloudflare and authentik tokens, tunnel token file) |
| Backups | `backups\` (installer backups, `services\` snapshots, `recovery\` points) |

**Development vs production files.** `compose.yaml`, `traefik\dynamic\security.yml`, `traefik\dynamic\dashboard.yml`
and `.env.example` are byte-identical in development and production: the upgrade changes **manager code only** (PowerShell
modules, web UI, catalog, scripts, docs). The Traefik, cloudflared and socket-proxy containers do not need to be
recreated or restarted.

**Schema migrations.** None is applied to existing files:
- `config\services.json`: the optional `owner` field is new; existing entries without it stay valid and are never rewritten
  on read.
- `config\applications.json` (new, contract version 1): created only when an application is observed or integrated.
- `config\managers.json`, `config\provision\repairs\` : created only when connectors or repairs are used.
- A registry written by a newer manager is refused, not rewritten.
The upgrade preflight (§3) measures this on a copy of the real deployment.

> **Important.** Because the manager in daily use is the development edition, quitting and restarting it from the tray
> (or a reboot followed by a manual start) already loads the current development code against production, without
> this procedure. The preflight shows that merely opening it writes no file and changes no container, but actions
> taken in it (install, protect, repair) use the new code. Until the owner approves the upgrade, either keep the
> running process, or start the installed 1.1.0 copy instead.

## 2. Prerequisites (each is a gate)

1. `development` reviewed and merged into `main` by the owner (not done by this audit).
2. Release checks green on the merge commit: lightweight suites, browser suites, `Test-IdentityLive.ps1` full run,
   `Test-UpgradePreflight.ps1` against production (read-only).
3. Free RAM ≥ 2 GB and Docker Desktop running (it is never restarted by this procedure).
4. A maintenance window for the **manager only** (about 5 minutes). Applications stay online.

## 3. Upgrade preflight (read-only, run first)

```powershell
cd <release checkout>
.\tests\Test-UpgradePreflight.ps1          # defaults: ~\.docker\projects\traefik-proxy and ~\.docker\projects
```

It copies the deployment (without `secrets\`, `backups\`, `logs\`) and the project folders' top-level files to
`%TEMP%\tpx-up-*`, runs this release's `install.ps1` over the copy, starts the upgraded manager on the copy with Docker
reachable only through a disposable read-only socket proxy, opens every page endpoint, and reports: files the upgrade
changed, files merely opening the manager writes, every Docker write that was attempted (refused), and that the real
deployment folder, project folders and every container are unchanged. The copy and the proxy are removed afterwards.

**Result on 2026-11-19 (development working tree, against the production deployment): 13 passed, 0 failed.**
- `install.ps1` (no `-Start`) completed: 25 manager files updated (previous copies in `backups\<timestamp>\`), 106
  added (new modules, web UI files, catalog, launcher scripts), **0 deleted, no configuration, route or `.env` file
  changed**. Its only Docker write is the Traefik reload helper: a throwaway container from the Traefik image with
  `--network none` that touches `traefik\dynamic\.reload` so Traefik re-reads its (unchanged) route files; Traefik is
  not restarted. On the copy the helper was refused by design, so the installer printed "Could not trigger a Traefik
  reload … run: docker restart"; that line is advice only, nothing is restarted, and on the real upgrade the reload
  succeeds.
- Opening the upgraded manager and every page endpoint (30 pages, 14 applications × 4 detail views) **wrote no file**
  (no `applications.json`, no migration). Its only Docker writes are health probes: short-lived containers named
  `traefik-ext1-validate-probe-<id>` (`wget` from the Traefik image, `--rm --read-only --cap-drop ALL`, 32 MB) on an
  application's network, one per running application whose detail is opened. They change no container, volume or
  network. (The audit fixed a retry loop that made a page view probe up to 10 times with 4-second pauses.)
- The real deployment folder, project folders and all 34 containers were unchanged.

## 4. Upgrade procedure

**Step 1: Record the current state** (no change):
```powershell
$ts = Get-Date -Format yyyyMMdd-HHmmss
$keep = "C:\Users\Joe\.docker\dtc-upgrade\$ts"; New-Item -ItemType Directory -Force $keep | Out-Null
docker ps -a --format '{{.Names}} {{.ID}} {{.Status}}' > "$keep\containers-before.txt"
docker inspect $(docker ps -aq) --format '{{.Name}} {{.Id}} {{.State.StartedAt}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}' > "$keep\fingerprint-before.txt"
```

**Step 2: Verified backups.**
1. Full copy of the deployment folder, secrets included, owner-only:
   `robocopy C:\Users\Joe\.docker\projects\traefik-proxy "$keep\traefik-proxy" /E /COPY:DATS /XD logs` then check
   `(Get-ChildItem "$keep\traefik-proxy" -Recurse -File).Count` against the source.
2. A configuration backup from the Backups page (portable, no credentials) saved to `$keep`.
3. authentik database, **online** (authentik keeps running):
   `docker exec authentik-postgresql pg_dump -U authentik -Fc -f /tmp/ak.pgdump authentik; docker cp authentik-postgresql:/tmp/ak.pgdump "$keep\authentik.pgdump"; docker exec authentik-postgresql rm /tmp/ak.pgdump`,
   verified with `docker exec authentik-postgresql pg_restore --list /tmp/...` before removal (or locally with a
   scratch PostgreSQL). Copy `C:\Users\Joe\.docker\projects\authentik\.env` next to it (it holds the secret key; keep
   `$keep` on an encrypted disk). A full stopped-volume backup via Installed apps > Back up is also possible but stops
   authentik (sign-in unavailable for about a minute), so it is not part of the default path.
4. Copy of the launcher state folder `%LOCALAPPDATA%\TraefikProxy-dev` to `$keep\launcher-state`.

**Step 3: Stop the manager only.** Tray icon > Quit (or create the manager's stop file). Containers are not touched.
Check: `docker ps` unchanged.

**Step 4: Apply the new manager code.** From the release checkout (merged `main`):
```powershell
.\install.ps1 -InstallPath C:\Users\Joe\.docker\projects\traefik-proxy      # no -Start
```
It updates unmodified managed files (previous copies in `backups\<timestamp>\`), adds new modules, keeps edited files
(writing `<file>.dist` beside them), reuses `proxynet`, validates `config\services.json` and, if Traefik is running,
asks it to re-read `traefik\dynamic\` (no restart; the route files are unchanged, so nothing changes). It never runs
`docker compose up` without `-Start`.

**Step 5: Start the updated manager.** Decide which copy the launcher starts:
- *Recommended:* the installed copy in the deployment folder (stable; updated only by this procedure). Reinstall the
  launcher from the installed copy (`launcher\Install-Launcher.ps1`), which records its own program path.
- Or keep the development-edition launcher, accepting that every restart loads the current development worktree.
Open the manager; it migrates nothing on its own (§1).

**Step 6–10: Verify** (all read-only):
6. App Catalog page lists the catalog; Installed apps lists the existing projects with their real state.
7. Routing: `services.ps1 preview` reports no route-file differences; every route answers through Traefik
   (`curl.exe -s -o NUL -w "%{http_code}" -H "Host: <hostname>" http://127.0.0.1:8180/`).
8. authentik: Identity & Access shows the token valid; for each protected route an anonymous request is redirected to
   sign-in (302 to `auth.<domain>`); the owner can sign in to one application.
9. Cloudflare: the Cloudflare page shows the tunnel healthy and the published hostnames unchanged (read-only check).
10. Containers unchanged: compare `fingerprint-before.txt` with a new fingerprint (ids, start times, restart counts).

**Expected downtime:** applications, Traefik, cloudflared and authentik: **none**. The manager UI: from Step 3 to
Step 5 (a few minutes).

## 5. Rollback

A Git checkout alone is not a rollback (the deployment folder holds its own copy of the manager). Rollback restores the
manager files from the full copy taken in Step 2 and leaves applications, volumes and data alone:

1. Quit the manager (tray > Quit).
2. Restore the manager's code files only (configuration and secrets stay as they are unless step 4 applies):
   ```powershell
   $src = "$keep\traefik-proxy"; $dst = 'C:\Users\Joe\.docker\projects\traefik-proxy'
   robocopy $src $dst /E /XD "$src\config" "$src\secrets" "$src\backups" "$src\logs" "$src\traefik"
   Copy-Item "$src\.install-manifest.json" $dst -Force
   ```
   Files added by the new version (new modules, `webui\applications.js`, …) can stay: 1.1.0 does not load them.
   (`install.ps1 -Rollback` restores from the newest timestamped folder in `backups\`; a token rotation after the
   upgrade also creates such folders, so the explicit copy above is the reliable path.)
3. Restore the launcher state folder from `$keep\launcher-state` if the launcher was reinstalled.
4. Only if the new manager changed configuration you want undone: restore single files from `$keep\traefik-proxy\config\`
   (for example `services.json`) and run `services.ps1 apply` (re-renders routes; Traefik reloads without restart).
   New files the old manager does not read (`applications.json`, `managers.json`, `provision\repairs\`) can stay.
5. Start the previous manager and repeat the verification of §4 (routes, sign-in redirects, containers unchanged).

Rollback never deletes installed applications, containers, volumes, networks, authentik data or Cloudflare resources.
