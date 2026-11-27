# DTC launcher: one click, system tray, start modes and Start with Windows

The DTC launcher runs the Deployment Manager in the background, with no PowerShell window. A tray icon gives you
access to it. The manager is still the same PowerShell backend (`Start-DeploymentManager.ps1` → `webui.ps1`) and the
same web UI. The launcher adds no Electron, no service, no scheduled task and no administrator rights.

## One-time setup

Double-click **`Setup-Launcher.cmd`** in the program folder. To also start DTC when you sign in to Windows, run it
from a terminal with `-Autostart`:

```powershell
.\Setup-Launcher.cmd -Autostart
# or, with an explicit default deployment:
.\launcher\Install-Launcher.ps1 -DefaultDeployment "$env:USERPROFILE\.docker\projects\traefik-proxy" -Autostart
```

The setup does the following:

1. Builds `launcher\DTC.exe` from `launcher\DtcLauncher.cs`. It uses the C# compiler of the .NET Framework that comes
   with Windows, so nothing is downloaded. `DTC.exe` is a small Windows (GUI) program. It starts
   `launcher\DTC-Tray.ps1` with `powershell.exe` and *no window at all*, even when Windows Terminal is your default
   terminal. If it cannot be built, the shortcuts start PowerShell hidden instead, and a console may flash briefly.
2. Creates the shortcuts:
   - On the desktop: **DTC Deployment Manager**.
   - In the Start menu folder **DTC Deployment Manager**: the same shortcut, plus **DTC - Choose deployment** and
     **DTC - Recovery mode**.
3. Saves the **default deployment**. This is `-DefaultDeployment` if you give it. Otherwise the default already
   saved is kept, or else the deployment the manager opened last becomes the default (for this installation,
   `traefik-proxy` with stack **traefik-home**).
4. With `-Autostart`, adds **Start with Windows** (see below).

Run it again at any time; it updates the shortcuts. Other options:

| Option | Effect |
|---|---|
| `-NoAutostart` | Turns Start with Windows off. |
| `-OpenBrowser yes\|no` | Sets whether a manual start opens the browser. |
| `-NoDesktopShortcut` | Skips the desktop shortcut. |
| `-Launch` | Starts DTC once setup is done. |
| `-Uninstall` | Removes the shortcuts and Start with Windows; settings and logs are kept. |

## Starting DTC

Each start mode has its own shortcut, which runs the same command:

| Shortcut | Command | What happens |
|---|---|---|
| **DTC Deployment Manager** | `launcher\DTC.exe` | **Default:** opens the saved default deployment without asking. If no default is set, or it is missing, the chooser opens with a notice. |
| **DTC - Choose deployment** | `launcher\DTC.exe -Mode choose` | **Choose:** opens the deployment chooser, where you switch deployments or change the default (*Make default*). |
| **DTC - Recovery mode** | `launcher\DTC.exe -Mode recovery` | **Recovery:** starts the manager without opening any deployment. Changes are refused until you choose one. Use it for troubleshooting. |

A manual start opens the dashboard in your browser, unless you turned **Open the browser when I start DTC** off.
The choose and recovery modes always open the chooser. If DTC is already running, starting a shortcut again does
not start a second copy. Instead, it asks the running tray to open the dashboard (default), open the chooser
(choose), or restart in recovery mode (recovery).

### The tray menu

| Item | What it does |
|---|---|
| **Open Dashboard** (also a left click on the icon) | Signs this browser in and opens the dashboard. Starts the manager first if it is not running. |
| **Choose Deployment…** | Opens the chooser in the browser. Switching deployments there opens the folder read-only. |
| **Restart Manager** | Stops and restarts only the manager website, with the default deployment. |
| **Restart in Recovery Mode** | Restarts the website without opening any deployment. |
| **Start with Windows** | Turns autostart on or off (same as the setting in the website). |
| **Open browser on manual start** | Turns the browser-opening preference on or off. |
| **Open Log Folder** | Opens `logs\` in the state folder. |
| **Exit** | Stops the manager the tray started and removes the icon. A manager you started with `START-HERE.cmd` is left running. |

**Finding the icon.** Windows 11 puts new tray icons in the hidden-icons overflow (the **^** arrow next to the clock)
at first. To keep it visible, drag it onto the taskbar. You can also turn it on under *Settings > Personalization >
Taskbar > Other system tray icons*. It is listed there as **Windows PowerShell**, because the tray runs inside
`powershell.exe`.

The icon has a status dot:

| Dot | Meaning |
|---|---|
| Green | Running. Hover over the icon for the port and deployment. |
| Amber | Starting, or waiting for Docker Desktop. |
| Red | Failed. A notification says why, and the reason is in the log. |
| Grey | Stopped, for example from the website. **Open Dashboard** starts it again. |

**No action of the launcher starts, stops, recreates or redeploys a Docker container.** Restart and Exit stop only
the website. Traefik, cloudflared and your apps keep running. Switching the deployment, or changing the default,
only records a folder path; the deployment is opened read-only, exactly like *Review and open*.

## Start with Windows (silent autostart)

To turn it on, use any of these:

- `Setup-Launcher.cmd -Autostart`
- The tray menu: **Start with Windows**
- The website: *Deployments* → *Startup and default deployment* → **Start with Windows**

This is how autostart behaves:

- **Mechanism:** a shortcut named *DTC Deployment Manager.lnk* in your own Startup folder
  (`shell:startup`), running `DTC.exe -Autostart`.
  - It is per user. It needs no administrator rights, no registry Run key and no scheduled task.
  - Windows lists it in **Task Manager > Startup apps**. If you disable it there, the website shows "On, but disabled
    in Task Manager".
- **Waiting for Docker Desktop:** the tray appears at once with an amber dot and checks `docker info` every 5 seconds,
  for up to `dockerWaitSeconds` (default 300). It does not start Docker Desktop; enable Docker Desktop's own *Start
  when you sign in* for that. If Docker is not ready in time, the manager starts anyway and shows Docker as not running.
- **Silence:** no browser opens and no notification appears when the start succeeds. A failure shows one notification
  and is written to the log.
- **Opening it later:** click the tray icon, or use your bookmark (next section).

## Bookmark: `http://127.0.0.1:8190/`

The manager listens on 127.0.0.1 only, on the **saved port**: 8190 for the installed manager, 8290 for a development
checkout.

Access still needs a sign-in. Any program running on the PC can reach a loopback port, including programs of other
Windows users, so the address alone does not sign you in. The sign-in works like this:

1. The first time, open the dashboard from the **tray icon** (or a shortcut). That uses a single-use sign-in link
   from a file only your Windows account can read.
2. The sign-in sets a **remembered-browser cookie**: HttpOnly and SameSite=Strict, valid for 30 days (`rememberDays`).
3. From then on, a bookmark to `http://127.0.0.1:8190/` opens the manager directly, also after restarts and after
   Start with Windows.

Where the cookie is stored, and how to revoke it:

- The manager stores only a SHA-256 hash of each remembered cookie, in `sessions.json` in the state folder. The file
  is readable by your account only, so a copy of it signs nobody in.
- **Sign out this browser** on the Deployments page forgets the browser.

If a bookmark shows "Not signed in", click the tray icon once.

If another program uses the saved port, the manager starts on the next free port. The tray and the website then say
so, and the bookmark works again once the port is free.

## Settings, state and logs

The installed manager and extracted packages use **`%LOCALAPPDATA%\TraefikProxy`**. A development checkout (a git
checkout or worktree) uses `%LOCALAPPDATA%\TraefikProxy-dev\<folder>-<hash>`, outside the installed manager's folder. It therefore has its own settings, port
(8290), sign-in link, tray, shortcuts ("(development)") and Start-with-Windows entry. It never controls, restarts or
stops the installed manager.

| File | Contents |
|---|---|
| `launcher.json` | No secrets. `programPath` (installation path), `edition`, `defaultDeployment` + `defaultStackName`, `autostart`, `openBrowserOnManualLaunch`, `port`, `dockerWaitSeconds`, `rememberBrowser`, `rememberDays`. |
| `manager.json` | The running manager's process id, port and program folder. |
| `launch.url` | The current single-use sign-in link. User-only ACL. |
| `sessions.json` | Hashes of remembered-browser cookies, with their expiry. User-only ACL. |
| `webui.json` | The recently opened deployments (paths and names). |
| `logs\launcher.log` | Tray, setup and start events, warnings and errors (missing default, port fallback, start failures). Sign-in keys, cookies and token-like strings are redacted. Rotated at 1 MB. |
| `logs\manager.log` | The hidden manager's console output (a PowerShell transcript), rotated at 1 MB. |

## Problems and what happens

| Situation | Behaviour |
|---|---|
| DTC already running | A second start passes its request to the running tray and exits. There is one tray per state folder (a named mutex). |
| A manager started with `START-HERE.cmd` is running | The tray uses it and does not start a second one. **Exit** leaves it running; **Restart** replaces it with a hidden one. |
| Saved port in use | The manager uses the next free port, and the tray, website and log say so. If all 31 ports are taken, the start fails and is logged. |
| Default deployment missing (moved, renamed, drive disconnected) | The chooser opens with a warning. The saved default is kept, so it works again when the folder is back. |
| Default deployment not finished, or no longer a deployment | The chooser opens with an explanation. |
| The manager does not start, or stops unexpectedly | The tray turns red, shows one notification and logs the reason. Nothing is retried in a loop: use **Restart Manager** or **Open Log Folder**. |
| Stopped from the website or with `STOP-MANAGER.cmd` | The tray turns grey. **Open Dashboard** starts the manager again. |
| Docker Desktop not running | The manager starts anyway, and its pages show Docker as not running. At sign-in, the tray waits up to `dockerWaitSeconds` first. |
| Program folder moved | Run `Setup-Launcher.cmd` again from the new folder. The shortcuts point to `launcher\DTC.exe` by absolute path. |

## Development versus production

The **installed manager** is the program files in the deployment folder, written by `install.ps1`. An upgrade
copies the launcher files there as well. After upgrading, run `Setup-Launcher.cmd` *from the install folder* to point
the shortcuts and Start with Windows at it.

A **development checkout** can be set up the same way. Its shortcuts end in "(development)", and it runs from its own
state folder and port, so both can be installed side by side. Only one of them should have Start with Windows
turned on.

## Tests

`tests\Test-Launcher.ps1` runs everything in a temporary folder. It never touches your real state folder, Startup
folder, desktop, Start menu, deployments or containers. It covers:

- the module: settings, editions, start plans, logging and redaction, autostart and the icon
- the hidden manager in each mode: default, choose, recovery, missing default, duplicate start, port conflict, start
  failure, remembered browsers and sign out, and the settings API
- setup: shortcuts, default, autostart, uninstall and seeding
- the tray end to end through the real `DTC.exe`: no window, second launch, restart, recovery, exit, autostart
  waiting for Docker, and start failure
- the Deployments page in headless Edge

When Docker is running, it also checks that switching or changing the default deployment leaves every container's
id, start time and restart count unchanged.
