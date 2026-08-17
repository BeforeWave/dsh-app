# DS Harness

A lightweight macOS app wrapper for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

DS Harness turns `dsh web` into a normal macOS application with a native window, Dock icon, and persistent background service — without Electron or an external browser window.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/beforewave/dsh-desktop/main/install.sh | bash
```

DS Harness is installed to:

```text
~/Applications/DS Harness.app
```

The app is currently unsigned. On first launch, right-click **DS Harness.app** in Finder, choose **Open**, then confirm.

## Why DS Harness?

You can always run:

```bash
dsh web
```

DS Harness does not replace DeepSeek Harness. It provides the desktop lifecycle around it.

| `dsh web`                                               | DS Harness                                |
| ------------------------------------------------------- | ----------------------------------------- |
| Start from Terminal                                     | Launch from Finder, Spotlight, or Dock    |
| Open in a browser                                       | Native macOS window                       |
| Backend tied to manual process management               | Backend managed by `launchd`              |
| Restart manually after a crash                          | `launchd` keeps the backend alive         |
| Manage duplicate instances yourself                     | Reuses an existing DSH server             |
| Shell environment may differ under background execution | Resolves Node and runtime PATH explicitly |
| No desktop lifecycle                                    | Normal macOS app lifecycle                |
| Manual upgrade awareness                                | Checks for newer DSH versions             |

The goal is to keep the wrapper small and let upstream DeepSeek Harness remain the actual application.

## How it works

```text
DS Harness.app
    │
    ├── AppKit
    │     └── WKWebView
    │           └── http://127.0.0.1:3080
    │
    └── launcher
          └── launchd
                └── dsh web
```

The desktop window is a thin native AppKit host.

`WKWebView` renders the existing DSH Web UI directly inside the app, so Chrome and Electron are not required at runtime.

The `dsh web` backend runs independently under `launchd`.

## Lifecycle

The desktop UI and DSH backend intentionally have separate lifecycles.

```text
Open DS Harness
    → start or reuse dsh web
    → open the native window

Close the window
    → backend keeps running

Click the Dock icon
    → window opens again

Cmd+Q
    → desktop app exits
    → backend keeps running

dsh web crashes
    → launchd restarts it

Open DS Harness again
    → existing backend is reused

Logout / reboot
    → backend stops
    → it does not automatically start at next login
```

This gives DSH a persistent backend during the current login session without turning DS Harness into a login item.

## Existing DSH instances

Before starting a backend, DS Harness checks:

```text
http://127.0.0.1:3080
```

If a working DSH Web server is already available, it is reused.

DS Harness does not kill an arbitrary process simply because it owns port `3080`.

## DSH runtime

DS Harness prefers an existing working `dsh` installation:

```bash
dsh web
```

If no working `dsh` command is available, it can fall back to a pinned npm version:

```bash
npx -y @deepseek-ai/dsh@<version> web
```

Node.js is required.

DS Harness explicitly resolves the Node executable and runtime `PATH` before handing the backend to `launchd`, avoiding common background-process issues such as:

```text
env: node: No such file or directory
```

## Configuration

DS Harness uses the normal DeepSeek Harness configuration directory:

```text
~/.dsh
```

including:

```text
~/.dsh/settings.yaml
```

The launcher explicitly sets:

```text
DSH_HOME=~/.dsh
```

Your DSH configuration is not copied, replaced, or removed by DS Harness.

## Desktop configuration

DS Harness desktop-side customization is read directly from:

```text
~/.config/dsh-desktop/
├── env.sh
├── healthcheck.sh
├── pre-start.d/
├── post-ready.d/
└── commands.d/
```

All files are optional. DS Harness does **not** create, copy, overwrite, or mutate this directory. There are no built-in command files in the app bundle; this directory is the single source of truth for desktop customization.

### Environment

If present, `env.sh` is sourced before DS Harness resolves or starts the backend, and is also sourced when a menu command runs.

Example:

```bash
# ~/.config/dsh-desktop/env.sh
export HTTPS_PROXY="http://127.0.0.1:7890"
```

### Lifecycle hooks

Scripts in `pre-start.d/*.sh` run before a DS Harness-managed backend is started. If any pre-start hook fails, startup is aborted.

Scripts in `post-ready.d/*.sh` run after the backend becomes healthy. Post-ready hook failures are logged but do not prevent the desktop UI from opening.

Hook output is written to:

```text
~/Library/Logs/DS Harness/extensions.log
```

### Custom health check

If `healthcheck.sh` exists, DS Harness uses it instead of the default HTTP readiness check against `http://127.0.0.1:3080`. A zero exit status means the backend is healthy.

### Configurable native menu commands

Each `commands.d/*.sh` file containing `# @menu` metadata becomes a native menu action. The same configured actions are shown in both the **DS Harness** application menu and the right-side macOS status menu.

Example:

```bash
#!/bin/bash
# @menu Restart Backend
# @shortcut cmd+shift+r
# @order 10
# @separator before

launchctl kickstart -k \
  "gui/$(id -u)/${DSH_DESKTOP_SERVICE_LABEL}"
```

Supported metadata:

```text
@menu       required menu title
@shortcut   e.g. cmd+r, cmd+shift+r, cmd+option+l
@order      numeric sort order; default 100
@separator  before or after
@enabled    true/false
```

The command list is re-scanned whenever DS Harness becomes active, so changing `commands.d` does not require rebuilding the app. `Reload UI` and the standard macOS items such as About, Hide, Edit, and Quit remain built into the host.

Extension scripts receive these environment variables:

```text
DSH_DESKTOP_CONFIG_DIR
DSH_DESKTOP_SUPPORT_DIR
DSH_DESKTOP_LOG_DIR
DSH_DESKTOP_SERVICE_LABEL
DSH_DESKTOP_URL
DSH_HOME
```

A useful optional command is `commands.d/check-for-updates.sh`: it compares the current DSH version with `@deepseek-ai/dsh@latest`. If an update is available, the menu presents a single **Update** action; the script handles the underlying runtime automatically. The currently running backend is never interrupted.

Menu command stdout/stderr is written to:

```text
~/Library/Logs/DS Harness/commands.log
```

## Background service

The managed launchd service is:

```text
com.beforewave.ds-harness.web
```

Runtime state is stored under:

```text
~/Library/Application Support/DS Harness
```

Logs are stored under:

```text
~/Library/Logs/DS Harness
```

The launchd definition is created at runtime rather than installed into `~/Library/LaunchAgents`.

As a result, the backend can remain alive after the desktop app exits without automatically starting after a reboot or new login.

## Updates

DS Harness can check whether a newer `@deepseek-ai/dsh` version is available.

Updates are never silently applied to a running backend.

For an installed `dsh`, DS Harness can provide the npm update command.

For the `npx` fallback, it can update the pinned version used the next time the backend starts.

## Launcher migration

DS Harness also migrates runtime state created by earlier launcher versions.

For example, the retired service:

```text
com.beforewave.dsh.web
```

is migrated to:

```text
com.beforewave.ds-harness.web
```

Migration happens before checking port `3080`, preventing an obsolete DS Harness-managed backend from being silently reused.

Only launcher-owned runtime files are cleaned up.

The user's:

```text
~/.dsh
```

directory is deliberately left untouched.

## Requirements

* macOS 12 or later
* Node.js
* DeepSeek Harness installed globally, or npm/npx available

Chrome is not required.

## Troubleshooting

Check whether DSH is responding:

```bash
curl http://127.0.0.1:3080
```

Check which process owns the port:

```bash
lsof -nP -iTCP:3080 -sTCP:LISTEN
```

Check the managed service:

```bash
launchctl print gui/$(id -u)/com.beforewave.ds-harness.web
```

Check logs:

```bash
tail -200 "$HOME/Library/Logs/DS Harness/web-error.log"
tail -200 "$HOME/Library/Logs/DS Harness/web.log"
```

## Uninstall

Stop the managed backend:

```bash
launchctl bootout \
  gui/$(id -u)/com.beforewave.ds-harness.web \
  2>/dev/null || true
```

Remove DS Harness:

```bash
rm -rf "$HOME/Applications/DS Harness.app"
rm -rf "$HOME/Library/Application Support/DS Harness"
rm -rf "$HOME/Library/Logs/DS Harness"
```

Your DeepSeek Harness configuration in `~/.dsh` is intentionally preserved.

## Co-work

Developed with assistance from [ChatGPT](https://chatgpt.com).

