# Credentials, backups and portability

What the Deployment Manager (DTC) stores, how it is protected, what a backup contains and what has to be entered
again after a restore or a move. Audited 2026-11-19 (release-readiness audit, development branch).

## 1. Where each credential lives

| Credential | File (in the deployment folder) | Protection | In a configuration backup? |
|---|---|---|---|
| Cloudflare API token | `secrets\cloudflare_api.dpapi` | DPAPI, current Windows user, extra entropy, owner-only ACL | No (listed to reconnect) |
| Cloudflare tunnel connector token | `secrets\cloudflare_tunnel_token` | Plain text (cloudflared reads it as a Docker secret), owner-only ACL | No (downloaded again for the same tunnel) |
| authentik API token | `secrets\authentik_api.dpapi` | DPAPI, current user, owner-only ACL | No (listed to reconnect) |
| Portainer / Arcane connector keys | `secrets\manager-<id>-api.dpapi` | DPAPI, current user, owner-only ACL | No (listed to reconnect, per connector) |
| Anthropic API key (optional AI help) | `secrets\ai_anthropic_api_key.dpapi` | DPAPI, current user, owner-only ACL | No (listed to reconnect) |
| Credential status records | `config\credentials.json` | No secret values (who, which server, last validation, expiry) | Not included (rebuilt on the next validation) |
| Imported / catalog application secrets | `<project>\.env` (and `credentials.txt` for generated admin passwords) | Plain text, owner-only ACL | Not in the configuration backup; in the app's own backup (below) |

Rules that hold for every credential (verified in code and by `tests\Test-Backup.ps1`):

- Secret values are never returned to the browser, written to `config\`, logged, or put in an exported archive.
  Every exported file passes a credential-pattern check and a check against the stored API token; a file that
  matches is left out and listed (`Excluded`).
- A replacement credential is validated first; a failed candidate leaves the stored one untouched
  (`lib\CredentialManager.psm1`).
- Connector keys are only ever sent as a header on GET requests to the configured address.

## 2. The two kinds of backup

**Configuration backup** (Backups page, `New-ConfigBackupArchive`): `manifest.json`, `INVENTORY.txt` and the
configuration files: `.env` (known non-secret keys only), `config\services.json`, `cloudflare.json`, `setup.json`,
`dashboard.json`, `identity.json`, and since this audit `config\applications.json` (integrated and observed
applications) and `config\managers.json` (connector addresses), plus hand-written Traefik files. It contains no
credential and is safe to keep anywhere. Restoring it creates the application registry and the connectors when they
are missing and never overwrites an existing registry (newer integrations would be lost); a registry written by a
newer manager is refused.

**Application backup** (Installed apps > Back up, `Invoke-AppBackupCore`, stored in `<project>\backups\<timestamp>\`):
Compose files, `.env`, `dtc-stack.json`, the project folder, tar archives of the stopped volumes and, for PostgreSQL
services, a `pg_dump -Fc`. **It contains the application's secrets in plain text** (for authentik: the secret key and
the database password in `.env`, plus the database itself). The files get the owner-only ACL; the manager offers no
download of these backups. If you copy them off the PC (USB disk, cloud drive), treat the copy like a password vault:
encrypt the destination (BitLocker To Go, an encrypted archive) or keep it offline.

authentik recovery needs the application backup (database, `.env`, `data`/`certs`/`templates`); the configuration
backup only restores DTC's choices. See [authentik-recovery.md](authentik-recovery.md).

## 3. Moving or restoring

| Situation | What happens | What you do |
|---|---|---|
| Same Windows user, same PC (manager upgrade, reinstall into the same folder) | Every `.dpapi` secret stays readable. | Nothing. |
| Restore into a new folder on the same PC and user | Configuration comes back from the backup; secrets are not in it. | Reconnect: Cloudflare token, authentik token, connector keys, AI key (each page shows "not connected"). The tunnel token is downloaded again from Cloudflare. |
| Another Windows user on the same PC | DPAPI refuses to decrypt. The manager reports "cannot be decrypted by this Windows account" and treats the credential as missing; nothing is overwritten silently. | Save each credential again as that user. |
| Another Windows PC | Same as another user (DPAPI keys are per user and machine for local accounts). | Restore the configuration backup, reconnect every credential, restore application backups (they carry their own `.env`). |
| Linux host | Not supported by this release: the secret store is DPAPI only (`lib\SecretStore.psm1` documents the four functions another host must implement). | Application backups (Compose, `.env`, volume tars, `pg_dump`) restore with plain `docker compose` on Linux; DTC itself does not run there yet. |
| Backup restored without the old `secrets\` folder | Same as a new folder: configuration restored, credentials listed under "Credentials to reconnect". | Reconnect them. |
| A credential is rotated or revoked | The next use fails with "refused" (401/403). Cloudflare/authentik pages show the token as rejected; a connector shows "The API key was refused" and ownership falls back to Docker labels. Nothing else changes. | Create a new token/key, paste it (validated before it replaces the old one), revoke the old one at the provider. |

DTC never decrypts and re-encrypts credentials on its own, never migrates them between users, and never exports them.

## 4. Portable credential recovery (proposed, not implemented)

A portable recovery would need an explicit, user-held secret. A compatible, staged design:

1. **Stage 1 (no format change).** Keep DPAPI as the at-rest store. Add an optional "recovery kit" export that the
   user must request explicitly: the selected credentials encrypted with a key derived from a user-chosen passphrase
   (PBKDF2-SHA256 or Argon2id, ≥ 600k iterations / tuned memory cost, random salt, AES-256-GCM), written as a separate
   file, never inside the configuration backup, never stored on disk unencrypted.
2. **Stage 2.** Import of a recovery kit on another user/PC/host: decrypt with the passphrase, validate each credential
   against its provider (existing validators), then store it with the local secret store. A failed validation keeps
   the credential out.
3. **Stage 3 (Linux).** A file-based secret store (0600, owned by the service user, optionally the kernel keyring or
   `systemd-creds`) implementing the four `SecretStore` functions; recovery kits make the move from Windows possible.

Until then, the supported path is: reconnect credentials after a move; application data travels with application
backups.
