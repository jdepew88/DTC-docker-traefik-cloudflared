# Public project website: plan (not built)

The local web UI (`webui.ps1`) is the product. A separate public website would explain it; it is a separate
project and deliverable. This note records the plan so the two stay consistent.

## Purpose and audience

- People with Docker Desktop and a Cloudflare account who want a local app (for example `http://10.10.0.11:4119`)
  reachable as a secure public hostname (`https://notflix.example.com`) without assembling a reverse-proxy stack
  or opening router ports.
- Experienced users who want to know exactly what the tool changes before trying it.

## Pages

1. **Home**: what it does in one diagram (visitor → Cloudflare edge and Access → tunnel → cloudflared → Traefik →
   apps), who it is for, the download / GitHub link.
2. **How it works**: Cloudflare Tunnel and Traefik together; why no port forwarding is needed; Docker containers,
   apps on Windows (`host.docker.internal`) and LAN devices; local-only mode.
3. **Prerequisites**: Windows 10/11, WSL 2, Docker Desktop in Linux-containers mode, a domain on Cloudflare, an API
   token with the listed permissions.
4. **Install and update**: the setup journey with screenshots of the seven steps; the upgrade procedure (backup,
   `install.ps1 -DryRun`, `install.ps1`).
5. **Security model and limitations**: taken from `SECURITY.md` and the README's known limitations; credentials
   never leave the PC except to `api.cloudflare.com`; fail-closed public dashboard; what is not supported
   (public-IP ingress, raw TCP/UDP, Let's Encrypt).
6. **Learn**: the topics of `webui/learn.json`, by the same stable ids, so the in-app "?" links can point to these
   pages later (only each topic's `links` / `destination` changes).

## Content sources

- Screenshots: `tests\Test-UiBrowser.ps1 -ScreenshotDir <folder>` (desktop, tablet, phone).
- Diagrams: the same topology as the app's Overview.
- Texts: README sections and the learning catalog, so the site and the app do not drift apart.

## Out of scope for the website

- Hosting or exposing the management UI publicly (it stays on 127.0.0.1).
- Accounts, telemetry or analytics collecting anything from installations.
