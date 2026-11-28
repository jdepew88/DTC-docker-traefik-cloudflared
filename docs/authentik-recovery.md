# authentik backup and disaster recovery

For authentik installed from the App Catalog (`catalog/apps/authentik.json`, authentik 2026.8.5 with PostgreSQL 16).
Verified only on a disposable installation (`tests\Test-IdentityLive.ps1 -RecoveryOnly`); production authentik was
never backed up, restored or touched by these tests.

## What authentik's state is

| Part | Where (App Catalog layout) | Why it is needed |
| --- | --- | --- |
| PostgreSQL database | volume `<project>_database` | Everything configured in authentik: users, groups, applications, providers, sources (including their client secrets), flows, stages, policies and bindings, outposts, tokens, certificates, brands, blueprint instances |
| Secret key | `.env`: `AUTHENTIK_SECRET_KEY` | Signs sessions, cookies and tokens; a restored database with another key loses signed-in sessions and signed links |
| Database password | `.env` (the generated value used by server, worker and PostgreSQL) | The restored database keeps its user and password; the containers must use the same one |
| Media | folder `data` (`/data`) | Uploaded icons, backgrounds and other media |
| Certificates | folder `certs` (`/certs`, worker) | Certificates discovered from files (keypairs created in authentik live in the database) |
| Custom templates | folder `templates` (`/templates`) | Custom page templates, if any |
| Compose files | `compose.yaml`, `compose.database.yaml` | The pinned images and settings that match the database schema |

Not part of authentik's state: the embedded outpost has no data of its own (its configuration is in the database);
blueprints applied by default come from the image (no custom blueprint folder is mounted in this recipe); the
Deployment Manager's own records (`config\identity.json`, the DPAPI token in `secrets\`) belong to the proxy
deployment and are covered by its portable backup.

A PostgreSQL dump alone is not a complete backup: without the same secret key and media it restores users and
configuration but loses sessions, signed data and uploaded files.

## Backup (Installed apps > authentik > Back up, or `POST /api/apps/backup`)

One backup folder `backups\<yyyyMMdd-HHmmss>` in the authentik project folder, readable only by your Windows account,
SYSTEM and Administrators, holds:

1. `<project>_postgresql.pgdump`: a logical dump made with PostgreSQL's own `pg_dump -Fc` while authentik runs (a
   consistent snapshot), checked with `pg_restore --list`. Portable to a newer PostgreSQL or another host.
2. The Compose files, `.env` (secret key, database password) and `dtc-stack.json`.
3. The `data`, `certs` and `templates` folders.
4. `<project>_database.tar.gz`: the PostgreSQL data folder copied while the stack is stopped for a few seconds. It
   restores only into the same PostgreSQL major version (16), which is what the recipe pins.

## Restore (Installed apps > authentik > Backups > Restore, or `POST /api/apps/restore-data`)

1. A safety backup of the current state is made first.
2. The stack stops; the database volume is replaced from the archive (created again if it was lost); with "restore
   files" the Compose files and `.env` come back; the folders are copied back.
3. The stack starts and its health is checked.
4. If a volume archive cannot be restored (for example a damaged file), nothing is half-restored: the volumes of the
   safety backup are put back and authentik starts in its previous state; the result says `rolledBack`.

## Disaster recovery

- **The volume or the whole folder content is lost, the backup folder is kept:** restore the newest backup with
  "restore files" (verified: database volume, `data` folder and `.env` deleted, then restored; users, groups,
  applications with their providers, access rules, expression policies, the source with its client secret, the
  outpost assignment and the stored API token all worked again; protected applications asked for sign-in and admitted
  only permitted users).
- **The PC is lost:** keep copies of the backup folders elsewhere (they contain secrets: store them encrypted). On a
  new PC: install authentik from the App Catalog with the same project name, stop it, copy the backup folder into
  `backups\`, then restore it with "restore files".
- **A newer PostgreSQL major version or a different layout:** create an empty database with the same name and
  owner, then `pg_restore -U authentik -d authentik --no-owner <project>_postgresql.pgdump` inside the PostgreSQL
  container, with the old `AUTHENTIK_SECRET_KEY` in `.env`, before starting the server and worker (verified only as
  far as restoring the dump into an empty PostgreSQL 16 and reading the users back).
- Upgrading authentik itself: one minor version at a time, back up first (authentik migrates the database on start).

## Limitations

- Verified on a disposable installation with representative objects, not on a large or long-lived authentik.
- Google sign-in itself was not exercised (it needs Google); its source secret is stored the same way as the
  verified one.
- The dump-only path (a different PostgreSQL major version) is documented and its dump verified, but a full start of
  authentik from a dump-only restore was not automated.
- Production authentik backups are your decision: nothing backs up or restores it automatically.
- The backup holds authentik's secrets in plain text (`.env`, the database) behind an owner-only ACL. Copies taken
  off the PC must be encrypted; see [credential-portability.md](credential-portability.md). Taking the stopped-volume
  copy stops authentik for a few seconds (sign-in unavailable); before an upgrade an online dump avoids that:
  `docker exec <postgresql container> pg_dump -U <user> -d <database> -Fc > authentik.dump`.
