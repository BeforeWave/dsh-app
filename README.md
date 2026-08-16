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

