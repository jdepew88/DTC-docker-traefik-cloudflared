# DTC sign-in experience for authentik

The authentik sign-in page with the **Glassmorphism** theme, a personalized **"Continue as &lt;owner&gt;"** Google button
and a **picture shortcut**: tap landmarks of the background picture in order to press that same button.

Both the button and the picture only *start* authentik's Google sign-in. Google authenticates; authentik decides who may
have an account (owner-only enrollment) and what each person may open (application policies). An unrelated Google
account that is chosen at Google is refused by authentik exactly as before.

## How it works

| Piece | Where | What it does |
| --- | --- | --- |
| Flow `dm-login` | authentik | Copy of DTC's sign-in flow (`dm-authentication`) with its own identification stage `dm-login-identification` (Google button + email/username form, password, MFA as before). |
| Policy `dm-login-google-hint` | authentik | Bound to that stage and re-evaluated on every visit: puts the owner's address into the flow plan. authentik's own Google redirect turns it into `login_hint=<owner>`. No `prompt` is sent, so Google reuses a signed-in session instead of forcing the account picker. Scopes stay `email profile`. |
| Brand CSS | authentik (default brand) | `upstream/theme.css` (unmodified, MIT, by VULGA) + `dtc-additions.css`. |
| Background | authentik file API | `background.jpg` (the upstream `Background_2.0.jpg`, 2560 px) uploaded as `dtc-login-<hash>.jpg` and set as the brand's default flow background. The CSS uses authentik's per-request `--ak-global--background-image` (authentik's file URLs are signed and expire). |
| Brand attribute `dtc_login` | authentik | Owner address, button text and picture points for the page script. |
| `custom-templates/if/flow.html` + `dtc/login-experience.js` | authentik project folder (mounted at `/templates`) | Extends authentik's own `if/flow.html` and inlines the page script, only when the brand's `dtc_login.flowSlug` equals the flow being shown and never in a recovery session. |

The page script relabels authentik's own Google button (its click handler, keyboard behaviour and the server-side
request stay authentik's) and listens for taps on the picture outside the sign-in card. The targets are computed at tap
time from the element that actually draws the picture (`body::before`: its size, `background-size` and
`background-position`), so resizing and cropping map back to the same landmarks. On portrait screens the whole picture
is shown unblurred above the card. A wrong tap, or a pause longer than `tapTimeoutMs`, resets the sequence silently; the
last correct tap presses the button exactly once.

## Change the picture points

Edit `config\login-experience.json` in the deployment (created on first apply from `login-experience.default.json`):

```json
"pictureShortcut": {
  "enabled": true,
  "tapTimeoutMs": 6000,
  "minTargetRadiusPx": 28,
  "points": [
    { "name": "Left snowfield", "x": 0.185, "y": 0.258, "r": 0.035 },
    { "name": "Right spire",    "x": 0.765, "y": 0.215, "r": 0.035 },
    { "name": "Red cliff",      "x": 0.895, "y": 0.565, "r": 0.035 }
  ]
}
```

- `x`, `y`: fractions of the picture (0,0 = top left, 1,1 = bottom right). Order = tap order. 2 to 6 points; add a
  fourth line for four taps.
- `r`: tap radius as a fraction of the picture width; never smaller than `minTargetRadiusPx` on screen (28 px = 56 px
  wide targets on phones).
- To read coordinates, open the sign-in page with `#dtc-calibrate` at the end of the address
  (`https://auth.<domain>/if/flow/dm-login/#dtc-calibrate`): the targets are drawn and every click shows its `x`/`y`.
  Sign-in never starts in that mode.

Then apply again: `powershell -ExecutionPolicy Bypass -File scripts\Set-AuthentikLogin.ps1 -InstallPath <deployment> -Action Apply`.
Points live in the brand attribute, so no restart is needed. Keep points outside the card on wide screens (left and right
thirds of the picture); the browser test checks this for common sizes.

## Commands

```powershell
# state + a live check of the Google request authentik would send (nothing is sent to Google)
scripts\Set-AuthentikLogin.ps1 -InstallPath <deployment>
# try it on http://localhost:9000 only (separate brand; the public page does not change)
scripts\Set-AuthentikLogin.ps1 -InstallPath <deployment> -Action Preview -RestartServer
# the public sign-in page
scripts\Set-AuthentikLogin.ps1 -InstallPath <deployment> -Action Apply
# undo (each Preview/Apply writes backups\login-experience\<time>-<action>\ with ROLLBACK.md)
scripts\Set-AuthentikLogin.ps1 -InstallPath <deployment> -Action Restore -BackupDir <that folder>
```

`-RestartServer` is needed only when the template files are new or changed (authentik caches templates).

## Offline preview and tests

- `preview.html`: open from disk. Real picture, real script and default points on a stand-in card that is labelled
  PREVIEW; its button only reports what would happen. Nothing contacts Google or authentik.
- `node tests\authentik-login.test.js`: geometry, sequence, timeout, configuration.
- `tests\Test-AuthentikLogin.ps1`: configuration, CSS, hint expression, template files.
- `tests\Test-AuthentikLoginBrowser.ps1`: Edge with real mouse, keyboard and touch input against the preview, or `-Live
  -Url <sign-in page> [-ProtectedUrl <app address>]` against authentik (Google requests are blocked in the test browser).

## authentik upgrades

The override extends authentik's own template, so authentik's page changes come through. After an upgrade run the
browser test with `-Live`; if authentik renamed its Google button (`button[name="source-google"]`) or the flow template
blocks, the page falls back to authentik's normal "Continue with Google" button, which still sends `login_hint`.

## Google Cloud values

Authorized redirect URI: `https://auth.<domain>/source/oauth/callback/google/` (the existing DTC Google client already
has it). Scopes: `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile`. No change is needed for this feature.
