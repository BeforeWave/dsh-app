#!/bin/bash
set -euo pipefail

# ============================================================
# build-dsh-app.sh
#
# Maintainer-only build script.
#
# Output:
#   DS Harness.app
#
# End users do not need this script. They install the prebuilt app from
# GitHub Releases through install.sh.
#
# Build requirements:
#   - macOS
#   - Xcode Command Line Tools
#   - Node.js
#   - a working dsh command
#
# Embedded runtime behavior:
#   - Reuse an existing DSH Web server on 127.0.0.1:3080.
#   - Otherwise prefer the installed `dsh web`.
#   - Fall back to a pinned @deepseek-ai/dsh version through npx.
#   - Keep the backend alive with launchd for the current login session.
#   - Do not auto-start after reboot/login.
#   - Resolve Node explicitly for launchd.
#   - Use ~/.dsh as DSH_HOME.
#   - Migrate retired launcher jobs before reusing port 3080.
#   - Refresh managed runtime files automatically when launcher logic changes.
#   - Check for newer DSH versions without silently upgrading.
# ============================================================

APP_NAME="DS Harness"
BUNDLE_ID="com.beforewave.ds-harness"
PACKAGE="@deepseek-ai/dsh"
URL="http://127.0.0.1:3080"

OUT_DIR="${1:-$PWD}"
APP_DIR="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
INFO="$CONTENTS/Info.plist"

BUILD_TMP="$(mktemp -d)"
BUILD_LOG="$OUT_DIR/.dsh-build.log"
TEMP_DSH_PID=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "${TEMP_DSH_PID:-}" ]; then
    kill "$TEMP_DSH_PID" >/dev/null 2>&1 || true
    wait "$TEMP_DSH_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$BUILD_TMP"
}
trap cleanup EXIT

find_cmd() {
  local name="$1"
  local result=""

  for dir in \
    /opt/homebrew/bin \
    /usr/local/bin \
    "$HOME/.volta/bin" \
    "$HOME/.local/bin" \
    "$HOME/.npm-global/bin" \
    /usr/bin \
    /bin
  do
    if [ -x "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done

  result="$(
    /bin/zsh -lic "command -v '$name' 2>/dev/null" 2>/dev/null \
      | /usr/bin/grep '^/' \
      | /usr/bin/tail -n 1 || true
  )"

  if [ -n "$result" ] && [ -x "$result" ]; then
    printf '%s\n' "$result"
    return 0
  fi

  return 1
}

backend_up() {
  # Build-time health check is intentionally independent of desktop config.
  /usr/bin/curl -fsS --max-time 1 "$URL/" >/dev/null 2>&1
}

# ─────────────────────────────────────────────
# Build dependency checks
# ─────────────────────────────────────────────

[ "$(uname -s)" = "Darwin" ] || die "This build script must run on macOS."

/usr/bin/xcrun --find clang >/dev/null 2>&1 \
  || die "Xcode Command Line Tools are required. Run: xcode-select --install"

NODE_BIN="$(find_cmd node || true)"
[ -n "$NODE_BIN" ] || die "Node.js was not found on the build machine."

DSH_BIN="$(find_cmd dsh || true)"
[ -n "$DSH_BIN" ] || die "dsh was not found on the build machine."

# Put Node first so dsh's /usr/bin/env node shebang can resolve it.
BUILD_NODE_DIR="$(dirname "$NODE_BIN")"
BUILD_PATH="$BUILD_NODE_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

env PATH="$BUILD_PATH" "$DSH_BIN" --version >/dev/null 2>&1 \
  || die "dsh exists but cannot run: $DSH_BIN"

# ─────────────────────────────────────────────
# STEP 1: Ensure DSH Web is available while building.
#
# If 3080 is already available:
#   reuse the existing service and leave it untouched.
#
# If 3080 is not available:
#   start a temporary `dsh web`.
#   stop only the temporary process after icon preparation.
# ─────────────────────────────────────────────

if backend_up; then
  echo "Using existing DSH Web on $URL"
else
  : > "$BUILD_LOG"

  echo "Starting temporary DSH: $DSH_BIN web"
  env PATH="$BUILD_PATH" "$DSH_BIN" web >>"$BUILD_LOG" 2>&1 &
  TEMP_DSH_PID=$!

  for _ in $(seq 1 600); do
    if backend_up; then
      break
    fi

    if ! kill -0 "$TEMP_DSH_PID" >/dev/null 2>&1; then
      die "Temporary DSH exited before becoming ready. See: $BUILD_LOG"
    fi

    /bin/sleep 0.2
  done

  backend_up || die "Timed out waiting for DSH on port 3080. See: $BUILD_LOG"

  echo "Temporary DSH is ready."
fi

# ─────────────────────────────────────────────
# STEP 2: Read the DSH Web App icon.
# ─────────────────────────────────────────────

INDEX_HTML="$BUILD_TMP/index.html"
MANIFEST_JSON="$BUILD_TMP/manifest.json"

/usr/bin/curl -fsSL "$URL/" -o "$INDEX_HTML" \
  || die "Failed to fetch the DSH Web root."

MANIFEST_URL="$(
  "$NODE_BIN" - "$INDEX_HTML" <<'NODE' || true
const fs = require("fs");

const html = fs.readFileSync(process.argv[2], "utf8");
const base = "http://127.0.0.1:3080/";

for (const m of html.matchAll(/<link\b[^>]*>/gi)) {
  const tag = m[0];
  const rel = tag.match(/\brel\s*=\s*["']([^"']+)["']/i)?.[1] || "";
  const href = tag.match(/\bhref\s*=\s*["']([^"']+)["']/i)?.[1] || "";

  if (href && rel.toLowerCase().split(/\s+/).includes("manifest")) {
    process.stdout.write(new URL(href, base).href);
    process.exit(0);
  }
}
process.exit(1);
NODE
)"

ICON_URL=""
ICON_TYPE=""

if [ -n "$MANIFEST_URL" ] && \
   /usr/bin/curl -fsSL "$MANIFEST_URL" -o "$MANIFEST_JSON" >/dev/null 2>&1
then
  ICON_META="$(
    "$NODE_BIN" - "$MANIFEST_JSON" "$MANIFEST_URL" <<'NODE' || true
const fs = require("fs");

const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const manifestUrl = process.argv[3];

const icons = (manifest.icons || [])
  .filter(x => x && x.src)
  .map(x => {
    let score = 0;

    for (const token of String(x.sizes || "").split(/\s+/)) {
      if (token === "any") {
        score = Math.max(score, 1_000_000_000);
        continue;
      }

      const m = token.match(/^(\d+)x(\d+)$/);
      if (m) score = Math.max(score, Number(m[1]) * Number(m[2]));
    }

    const url = new URL(x.src, manifestUrl).href;
    const type = String(x.type || "");

    if (type === "image/svg+xml" || /\.svg(?:$|\?)/i.test(url)) {
      score = Math.max(score, 1_000_000_000);
    }

    return {
      url,
      type,
      purpose: String(x.purpose || ""),
      score
    };
  })
  .sort((a, b) => {
    const aMaskOnly = a.purpose.trim() === "maskable" ? 1 : 0;
    const bMaskOnly = b.purpose.trim() === "maskable" ? 1 : 0;

    if (aMaskOnly !== bMaskOnly) return aMaskOnly - bMaskOnly;
    return b.score - a.score;
  });

if (!icons.length) process.exit(1);

process.stdout.write(`${icons[0].url}\t${icons[0].type}`);
NODE
  )"

  if [ -n "$ICON_META" ]; then
    ICON_URL="${ICON_META%%$'\t'*}"
    if [[ "$ICON_META" == *$'\t'* ]]; then
      ICON_TYPE="${ICON_META#*$'\t'}"
    fi
  fi
fi

# Use the DSH favicon as a fallback.
if [ -z "$ICON_URL" ]; then
  if /usr/bin/curl -fsS "$URL/favicon.svg" >/dev/null 2>&1; then
    ICON_URL="$URL/favicon.svg"
    ICON_TYPE="image/svg+xml"
  else
    die "No usable icon was found in the manifest or /favicon.svg."
  fi
fi

echo "Using icon: $ICON_URL"

case "$ICON_TYPE:$ICON_URL" in
  image/svg+xml:*|*:*.svg|*:*.svg\?*)
    ICON_SOURCE="$BUILD_TMP/source.svg"
    ;;
  image/png:*|*:*.png|*:*.png\?*)
    ICON_SOURCE="$BUILD_TMP/source.png"
    ;;
  image/webp:*|*:*.webp|*:*.webp\?*)
    ICON_SOURCE="$BUILD_TMP/source.webp"
    ;;
  *)
    ICON_SOURCE="$BUILD_TMP/source.img"
    ;;
esac

/usr/bin/curl -fsSL "$ICON_URL" -o "$ICON_SOURCE" \
  || die "Failed to download the DSH icon."

ICON_PNG="$BUILD_TMP/icon-1024.png"

if /usr/bin/sips -s format png "$ICON_SOURCE" --out "$ICON_PNG" >/dev/null 2>&1; then
  :
else
  rm -f "$ICON_PNG"

  QL_DIR="$BUILD_TMP/ql"
  mkdir -p "$QL_DIR"

  /usr/bin/qlmanage -t -s 1024 -o "$QL_DIR" "$ICON_SOURCE" >/dev/null 2>&1 || true
  QL_PNG="$(find "$QL_DIR" -type f -name '*.png' -print -quit || true)"

  if [ -n "$QL_PNG" ]; then
    cp "$QL_PNG" "$ICON_PNG"
  fi

  [ -s "$ICON_PNG" ] \
    || die "Failed to rasterize the DSH icon with macOS Quick Look."
fi

[ -s "$ICON_PNG" ] || die "Icon rasterization did not produce a PNG."

ICONSET="$BUILD_TMP/DSH.iconset"
mkdir -p "$ICONSET"

/usr/bin/sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

/usr/bin/iconutil -c icns "$ICONSET" -o "$BUILD_TMP/DSH.icns" \
  || die "Failed to generate DSH.icns."

echo "Prepared DSH.icns."

# Stop only the temporary DSH started by this build.
# If DSH was already running when the build started, TEMP_DSH_PID is empty,
# so the existing user process is left untouched.
if [ -n "$TEMP_DSH_PID" ]; then
  echo "Stopping temporary DSH..."
  kill "$TEMP_DSH_PID" >/dev/null 2>&1 || true
  wait "$TEMP_DSH_PID" >/dev/null 2>&1 || true
  TEMP_DSH_PID=""

  for _ in $(seq 1 50); do
    backend_up || break
    /bin/sleep 0.1
  done
else
  echo "Existing DSH Web was reused; leaving it running."
fi

# ─────────────────────────────────────────────
# STEP 3: Assemble DS Harness.app.
# ─────────────────────────────────────────────

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BUILD_TMP/DSH.icns" "$RESOURCES/DSH.icns"

cat > "$INFO" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>DS Harness</string>

  <key>CFBundleDisplayName</key>
  <string>DS Harness</string>

  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>

  <key>CFBundleExecutable</key>
  <string>DSH</string>

  <key>CFBundleIconFile</key>
  <string>DSH.icns</string>

  <key>CFBundlePackageType</key>
  <string>APPL</string>

  <key>CFBundleVersion</key>
  <string>1</string>

  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>

  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>

  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>

    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

# ─────────────────────────────────────────────
# STEP 4: Embed end-user runtime logic.
# ─────────────────────────────────────────────

cat > "$RESOURCES/launcher.sh" <<'LAUNCHER'
#!/bin/bash
set -u

LABEL="com.beforewave.ds-harness.web"
URL="http://127.0.0.1:3080"
PACKAGE="@deepseek-ai/dsh"

SUPPORT_DIR="$HOME/Library/Application Support/DS Harness"
LOG_DIR="$HOME/Library/Logs/DS Harness"

PLIST="$SUPPORT_DIR/$LABEL.plist"
RUNNER="$SUPPORT_DIR/run-dsh.sh"

MODE_FILE="$SUPPORT_DIR/mode"
NPX_PATH_FILE="$SUPPORT_DIR/npx-path"
NPM_PATH_FILE="$SUPPORT_DIR/npm-path"
NODE_PATH_FILE="$SUPPORT_DIR/node-path"
RUNTIME_PATH_FILE="$SUPPORT_DIR/runtime-path"
VERSION_FILE="$SUPPORT_DIR/version"
LAUNCHER_BUILD_ID_FILE="$SUPPORT_DIR/launcher-build-id"
DSH_HOME_DIR="$HOME/.dsh"

CONFIG_DIR="$HOME/.config/dsh-desktop"

# Replaced by the maintainer build script with a SHA-256 hash of the embedded
# launcher logic. If the launcher logic changes in a future app build, the
# managed backend is restarted with freshly generated runtime files.
LAUNCHER_BUILD_ID="__LAUNCHER_BUILD_ID__"

# Bump this when the on-disk launchd runtime format changes.  This is
# deliberately independent of the launcher hash so stale generated runtime
# files are rebuilt even if a previous build recorded the wrong build id.
# Runtime v3: dsh/npx executable paths are resolved inside zsh -lic at launch
# time; stale package-manager absolute paths are never trusted.
RUNTIME_SCHEMA="3"
RUNTIME_SCHEMA_FILE="$SUPPORT_DIR/runtime-schema"

# Known historical launcher identities owned by this project.
# Keep LABEL stable from now on; add future retired labels here if necessary.
LEGACY_LABELS=(
  "com.beforewave.dsh.web"
)

LEGACY_SUPPORT_DIR="$HOME/Library/Application Support/DSH"

mkdir -p "$SUPPORT_DIR" "$LOG_DIR" "$DSH_HOME_DIR"

source_extension_env() {
  # DS Harness never creates or mutates ~/.config/dsh-desktop.
  # The repository/user-owned config is read directly.
  set +u
  if [ -f "$CONFIG_DIR/env.sh" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_DIR/env.sh"
  fi
  set -u
}

run_config_hooks() {
  local hook_dir_name="$1"
  local hook_dir="$CONFIG_DIR/$hook_dir_name"
  local hook
  local status=0

  for hook in "$hook_dir"/*.sh; do
    [ -f "$hook" ] || continue

    echo "DS Harness extension hook: $hook" >>"$LOG_DIR/extensions.log"
    if ! /bin/bash "$hook" >>"$LOG_DIR/extensions.log" 2>&1; then
      status=1
      echo "DS Harness extension hook failed: $hook" >>"$LOG_DIR/extensions.log"
    fi
  done

  return "$status"
}

source_extension_env

export DSH_DESKTOP_CONFIG_DIR="$CONFIG_DIR"
export DSH_DESKTOP_SUPPORT_DIR="$SUPPORT_DIR"
export DSH_DESKTOP_LOG_DIR="$LOG_DIR"
export DSH_DESKTOP_SERVICE_LABEL="$LABEL"
export DSH_DESKTOP_URL="$URL"

dialog_error() {
  MSG="$1" /usr/bin/osascript <<'EOF' >/dev/null 2>&1
set msg to system attribute "MSG"
display dialog msg with title "DS Harness" buttons {"OK"} default button "OK" with icon stop
EOF
}

find_command() {
  local name="$1"
  local result=""

  for dir in \
    /opt/homebrew/bin \
    /usr/local/bin \
    "$HOME/.volta/bin" \
    "$HOME/.local/bin" \
    "$HOME/.npm-global/bin" \
    /usr/bin \
    /bin
  do
    if [ -x "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done

  # Resolve nvm/fnm/asdf/mise and shell-managed installations.
  result="$(
    /bin/zsh -lic "command -v '$name' 2>/dev/null" 2>/dev/null \
      | /usr/bin/grep '^/' \
      | /usr/bin/tail -n 1 || true
  )"

  if [ -n "$result" ] && [ -x "$result" ]; then
    printf '%s\n' "$result"
    return 0
  fi

  return 1
}

backend_up() {
  if [ -f "$CONFIG_DIR/healthcheck.sh" ]; then
    /bin/bash "$CONFIG_DIR/healthcheck.sh"
    return $?
  fi

  /usr/bin/curl -fsS --max-time 1 "$URL/" >/dev/null 2>&1
}

wait_for_backend_down() {
  local i=0

  while [ "$i" -lt 50 ]; do
    if ! backend_up; then
      return 0
    fi

    /bin/sleep 0.1
    i=$((i + 1))
  done

  return 1
}

migrate_legacy_runtime() {
  local domain
  local legacy_label
  local legacy_was_loaded=0

  domain="gui/$(id -u)"

  for legacy_label in "${LEGACY_LABELS[@]}"; do
    if /bin/launchctl print "$domain/$legacy_label" >/dev/null 2>&1; then
      legacy_was_loaded=1
      /bin/launchctl bootout "$domain/$legacy_label" >/dev/null 2>&1 || true
    fi
  done

  # Give a retired launchd-managed backend a moment to release port 3080.
  # If another independently started DSH still owns the port, leave it alone.
  if [ "$legacy_was_loaded" -eq 1 ]; then
    wait_for_backend_down || true
  fi

  # Remove only files known to have been generated by the retired launcher.
  # ~/.dsh is deliberately untouched because it contains user configuration.
  /bin/rm -f     "$LEGACY_SUPPORT_DIR/com.beforewave.dsh.web.plist"     "$LEGACY_SUPPORT_DIR/run-dsh.sh"     "$LEGACY_SUPPORT_DIR/mode"     "$LEGACY_SUPPORT_DIR/dsh-path"     "$LEGACY_SUPPORT_DIR/npx-path"     "$LEGACY_SUPPORT_DIR/npm-path"     "$LEGACY_SUPPORT_DIR/node-path"     "$LEGACY_SUPPORT_DIR/runtime-path"     "$LEGACY_SUPPORT_DIR/version"     >/dev/null 2>&1 || true

  /bin/rmdir "$LEGACY_SUPPORT_DIR" >/dev/null 2>&1 || true
}

refresh_managed_runtime_if_needed() {
  local domain
  local installed_build_id=""
  local installed_runtime_schema=""

  domain="gui/$(id -u)"
  installed_build_id="$(cat "$LAUNCHER_BUILD_ID_FILE" 2>/dev/null || true)"
  installed_runtime_schema="$(cat "$RUNTIME_SCHEMA_FILE" 2>/dev/null || true)"

  if [ "$installed_build_id" = "$LAUNCHER_BUILD_ID" ] && \
     [ "$installed_runtime_schema" = "$RUNTIME_SCHEMA" ]; then
    return 0
  fi

  # A backend created by an older DS Harness build is ours to restart.
  # Never kill a process merely because it occupies port 3080.
  if /bin/launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
    wait_for_backend_down || true
  fi

  # Generated runtime files are disposable. Remove stale path caches from
  # older launchers so a dead absolute path can never survive a refresh.
  /bin/rm -f \
    "$RUNNER" \
    "$PLIST" \
    "$MODE_FILE" \
    "$SUPPORT_DIR/dsh-path" \
    "$NPX_PATH_FILE" \
    "$RUNTIME_PATH_FILE" \
    >/dev/null 2>&1 || true

  return 0
}

resolve_runtime_path() {
  local node_bin node_dir

  node_bin="$(find_command node || true)"

  if [ -z "$node_bin" ]; then
    dialog_error "Node.js was not found.

DSH is a Node.js CLI and cannot start without Node.js.
Install Node.js and try again."
    return 1
  fi

  node_dir="$(dirname "$node_bin")"

  # Node must be first because dsh/npm/npx may use /usr/bin/env node.
  RUNTIME_PATH="$node_dir:/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  printf '%s\n' "$node_bin" > "$NODE_PATH_FILE"
  printf '%s\n' "$RUNTIME_PATH" > "$RUNTIME_PATH_FILE"

  export PATH="$RUNTIME_PATH"

  return 0
}

latest_version() {
  local npm_bin runtime_path

  npm_bin="$(cat "$NPM_PATH_FILE" 2>/dev/null || true)"
  runtime_path="$(cat "$RUNTIME_PATH_FILE" 2>/dev/null || true)"

  if [ -z "$npm_bin" ] || [ ! -x "$npm_bin" ]; then
    npm_bin="$(find_command npm || true)"
  fi

  [ -z "$npm_bin" ] && return 1
  [ -z "$runtime_path" ] && return 1

  env PATH="$runtime_path" \
    npm_config_fetch_timeout=5000 \
    npm_config_fetch_retries=0 \
    "$npm_bin" view "$PACKAGE" version --silent 2>/dev/null \
      | /usr/bin/tail -n 1
}

configure_runtime() {
  local runtime_path
  local npx_bin
  local npm_bin
  local latest

  resolve_runtime_path || return 1
  runtime_path="$(cat "$RUNTIME_PATH_FILE")"

  npm_bin="$(find_command npm || true)"
  if [ -n "$npm_bin" ]; then
    printf '%s\n' "$npm_bin" > "$NPM_PATH_FILE"
  fi

  # Resolve `dsh` inside the user's login+interactive shell every time.
  # Do not persist an absolute dsh path: Homebrew/npm/nvm/fnm upgrades can
  # move or replace the executable while the Desktop app is still installed.
  if /bin/zsh -lic '
    export HOME="$1"
    export DSH_HOME="$2"
    dsh_bin="$(command -v dsh 2>/dev/null || true)"
    [ -n "$dsh_bin" ] && [ -x "$dsh_bin" ] || exit 1
    "$dsh_bin" --version >/dev/null 2>&1
  ' _ "$HOME" "$DSH_HOME" >/dev/null 2>&1
  then
    printf '%s\n' direct > "$MODE_FILE"
    /bin/rm -f "$SUPPORT_DIR/dsh-path" >/dev/null 2>&1 || true
    return 0
  fi

  # No working dsh in the login shell: prepare the npx fallback.
  npx_bin="$(find_command npx || true)"

  if [ -z "$npx_bin" ]; then
    dialog_error "No working dsh command or npx was found.

Verify that Node.js/npm is installed correctly."
    return 1
  fi

  if ! env PATH="$runtime_path" "$npx_bin" --version >/dev/null 2>&1; then
    dialog_error "npx was found but could not run.

Node:
$(cat "$NODE_PATH_FILE" 2>/dev/null)

npx:
$npx_bin"
    return 1
  fi

  printf '%s\n' "$npx_bin" > "$NPX_PATH_FILE"

  if [ ! -s "$VERSION_FILE" ]; then
    latest="$(latest_version || true)"

    if [ -z "$latest" ]; then
      dialog_error "Failed to query the latest @deepseek-ai/dsh version from npm."
      return 1
    fi

    printf '%s\n' "$latest" > "$VERSION_FILE"
  fi

  printf '%s\n' npx > "$MODE_FILE"
  return 0
}

write_runner() {
  cat > "$RUNNER" <<'EOF'
#!/bin/bash
set -u

SUPPORT_DIR="$HOME/Library/Application Support/DS Harness"
VERSION_FILE="$SUPPORT_DIR/version"
RUNTIME_PATH_FILE="$SUPPORT_DIR/runtime-path"

runtime_path="$(cat "$RUNTIME_PATH_FILE" 2>/dev/null || true)"

if [ -z "$runtime_path" ]; then
  echo "DSH Launcher: runtime PATH missing." >&2
  exit 127
fi

export HOME="${HOME:?HOME is missing}"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
export PATH="$runtime_path"

# launchd does not inherit the launcher process environment, so source the
# repository/user-owned desktop config here as well. This file is read only.
DESKTOP_CONFIG_DIR="$HOME/.config/dsh-desktop"
set +u
if [ -f "$DESKTOP_CONFIG_DIR/env.sh" ]; then
  # shellcheck disable=SC1090
  source "$DESKTOP_CONFIG_DIR/env.sh"
fi
set -u

version="$(cat "$VERSION_FILE" 2>/dev/null || true)"

echo "DSH Launcher HOME: $HOME" >&2
echo "DSH Launcher DSH_HOME: $DSH_HOME" >&2
echo "DSH Launcher settings: $DSH_HOME/settings.yaml" >&2
if [ -f "$DSH_HOME/settings.yaml" ]; then
  echo "DSH Launcher settings file: FOUND" >&2
else
  echo "DSH Launcher settings file: MISSING" >&2
fi

# Resolve the executable at the moment launchd starts the service. Never use
# an absolute dsh/npx path saved by a previous build or package-manager state.
exec /bin/zsh -lic '
  export HOME="$1"
  export DSH_HOME="$2"

  dsh_bin="$(command -v dsh 2>/dev/null || true)"
  if [ -n "$dsh_bin" ] && [ -x "$dsh_bin" ]; then
    echo "DSH Launcher runtime: $dsh_bin" >&2
    exec "$dsh_bin" web
  fi

  version="$3"
  if [ -z "$version" ]; then
    echo "DSH executable was not found and no fallback version is pinned." >&2
    exit 127
  fi

  npx_bin="$(command -v npx 2>/dev/null || true)"
  if [ -z "$npx_bin" ] || [ ! -x "$npx_bin" ]; then
    echo "Neither dsh nor npx was found in the login shell PATH." >&2
    exit 127
  fi

  echo "DSH Launcher runtime: $npx_bin @deepseek-ai/dsh@$version" >&2
  exec "$npx_bin" -y "@deepseek-ai/dsh@$version" web
' _ "$HOME" "$DSH_HOME" "$version"
EOF

  chmod +x "$RUNNER"
}

write_plist() {
  local runtime_path
  runtime_path="$(cat "$RUNTIME_PATH_FILE")"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$RUNNER</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>

    <key>DSH_HOME</key>
    <string>$HOME/.dsh</string>

    <key>PATH</key>
    <string>$runtime_path</string>
  </dict>

  <key>WorkingDirectory</key>
  <string>$HOME</string>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>StandardOutPath</key>
  <string>$LOG_DIR/web.log</string>

  <key>StandardErrorPath</key>
  <string>$LOG_DIR/web-error.log</string>
</dict>
</plist>
EOF
}

ensure_backend() {
  local domain
  domain="gui/$(id -u)"

  # Migration and managed-runtime refresh must happen BEFORE checking port 3080.
  # Otherwise a retired launcher can keep serving 3080 and be silently reused.
  migrate_legacy_runtime
  refresh_managed_runtime_if_needed

  # After migration, an independently started DSH may still be serving 3080.
  # Reuse it and never kill arbitrary user processes.
  if backend_up; then
    return 0
  fi

  if ! run_config_hooks "pre-start.d"; then
    dialog_error "A pre-start extension hook failed.

Check:
$LOG_DIR/extensions.log"
    return 1
  fi

  configure_runtime || return 1
  write_runner
  write_plist

  # launchd caches loaded job definitions. Re-bootstrap our own job so the
  # newly generated runner/plist is guaranteed to be the active definition.
  if /bin/launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || true
    wait_for_backend_down || true
  fi

  if ! /bin/launchctl bootstrap "$domain" "$PLIST" >/dev/null 2>&1; then
    dialog_error "Failed to start the DSH background service.

Error log:
$LOG_DIR/web-error.log"
    return 1
  fi

  # Record the launcher/runtime format only after launchd accepted the new job.
  printf '%s\n' "$LAUNCHER_BUILD_ID" > "$LAUNCHER_BUILD_ID_FILE"
  printf '%s\n' "$RUNTIME_SCHEMA" > "$RUNTIME_SCHEMA_FILE"

  local i=0
  while [ "$i" -lt 600 ]; do
    if backend_up; then
      return 0
    fi

    /bin/sleep 0.2
    i=$((i + 1))
  done

  dialog_error "DSH did not become available at $URL.

Check:
$LOG_DIR/web-error.log"

  return 1
}

current_version() {
  local mode

  mode="$(cat "$MODE_FILE" 2>/dev/null || true)"

  if [ "$mode" = "npx" ]; then
    cat "$VERSION_FILE" 2>/dev/null || true
    return 0
  fi

  # Same rule as the runner: resolve dsh from the current login shell instead
  # of trusting an absolute path saved by an earlier launch.
  /bin/zsh -lic '
    dsh_bin="$(command -v dsh 2>/dev/null || true)"
    [ -n "$dsh_bin" ] && [ -x "$dsh_bin" ] || exit 1
    "$dsh_bin" --version
  ' 2>/dev/null \
    | /usr/bin/grep -Eo '[0-9]+\.[0-9]+\.[0-9]+[-+._A-Za-z0-9]*' \
    | /usr/bin/head -n 1 || true
}

check_update_async() {
  (
    /bin/sleep 2

    # Resolve runtime again so update checks can use npm/node.
    resolve_runtime_path >/dev/null 2>&1 || exit 0

    npm_bin="$(find_command npm || true)"
    if [ -n "$npm_bin" ]; then
      printf '%s\n' "$npm_bin" > "$NPM_PATH_FILE"
    fi

    current="$(current_version || true)"
    latest="$(latest_version || true)"

    [ -z "$current" ] && exit 0
    [ -z "$latest" ] && exit 0
    [ "$current" = "$latest" ] && exit 0

    mode="$(cat "$MODE_FILE" 2>/dev/null || true)"

    if [ "$mode" = "npx" ]; then
      CHOICE_FILE="$SUPPORT_DIR/update-choice"
      rm -f "$CHOICE_FILE"

      CURRENT="$current" \
      LATEST="$latest" \
      CHOICE_FILE="$CHOICE_FILE" \
      /usr/bin/osascript <<'EOF' >/dev/null 2>&1
set cur to system attribute "CURRENT"
set lat to system attribute "LATEST"
set choiceFile to system attribute "CHOICE_FILE"

set r to display dialog "A new DeepSeek Harness version is available." & return & return & ¬
  "Current: " & cur & return & ¬
  "Latest: " & lat & return & return & ¬
  "The current task will not be interrupted. The new version will be used the next time the backend starts." ¬
  with title "DS Harness Update" ¬
  buttons {"Later", "Update Next Start"} ¬
  default button "Later"

if button returned of r is "Update Next Start" then
  do shell script "/bin/echo " & quoted form of lat & " > " & quoted form of choiceFile
end if
EOF

      if [ -s "$CHOICE_FILE" ]; then
        cat "$CHOICE_FILE" > "$VERSION_FILE"
        rm -f "$CHOICE_FILE"
      fi
    else
      CURRENT="$current" \
      LATEST="$latest" \
      /usr/bin/osascript <<'EOF' >/dev/null 2>&1
set cur to system attribute "CURRENT"
set lat to system attribute "LATEST"

set r to display dialog "A new DeepSeek Harness version is available." & return & return & ¬
  "Current: " & cur & return & ¬
  "Latest: " & lat ¬
  with title "DS Harness Update" ¬
  buttons {"Later", "Copy Update Command"} ¬
  default button "Later"

if button returned of r is "Copy Update Command" then
  set the clipboard to "npm install -g @deepseek-ai/dsh@latest"
end if
EOF
    fi
  ) >/dev/null 2>&1 &
}

# MAIN

if ! ensure_backend; then
  exit 1
fi

# Post-ready hooks are best-effort: they must never prevent the desktop UI
# from opening once DSH itself is healthy.
run_config_hooks "post-ready.d" || true

check_update_async

exit 0
LAUNCHER

# ─────────────────────────────────────────────
# STEP 4.1: Embed the menu command runner only.
#
# No env/hooks/healthcheck/menu command files are generated or copied into
# the app bundle. All extension configuration is read directly from:
#   ~/.config/dsh-desktop
# ─────────────────────────────────────────────

cat > "$RESOURCES/run-command.sh" <<'EOF'
#!/bin/bash
set -u

if [ "$#" -ne 1 ]; then
  echo "usage: run-command.sh <command-script>" >&2
  exit 64
fi

COMMAND_SCRIPT="$1"
CONFIG_DIR="$HOME/.config/dsh-desktop"

SUPPORT_DIR="$HOME/Library/Application Support/DS Harness"
LOG_DIR="$HOME/Library/Logs/DS Harness"
LABEL="com.beforewave.ds-harness.web"
URL="http://127.0.0.1:3080"

mkdir -p "$LOG_DIR"

export DSH_DESKTOP_CONFIG_DIR="$CONFIG_DIR"
export DSH_DESKTOP_SUPPORT_DIR="$SUPPORT_DIR"
export DSH_DESKTOP_LOG_DIR="$LOG_DIR"
export DSH_DESKTOP_SERVICE_LABEL="$LABEL"
export DSH_DESKTOP_URL="$URL"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

set +u
if [ -f "$CONFIG_DIR/env.sh" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_DIR/env.sh"
fi
set -u

if [ ! -f "$COMMAND_SCRIPT" ]; then
  echo "DS Harness menu command does not exist: $COMMAND_SCRIPT"     >>"$LOG_DIR/commands.log"
  exit 66
fi

{
  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] $COMMAND_SCRIPT"
  /bin/bash "$COMMAND_SCRIPT"
  status=$?
  echo "exit=$status"
  exit "$status"
} >>"$LOG_DIR/commands.log" 2>&1
EOF

chmod +x "$RESOURCES/run-command.sh"

# Use the embedded launcher content itself as the managed-runtime revision.
# This avoids relying on a manually maintained migration/version number.
LAUNCHER_BUILD_ID="$(
  /usr/bin/shasum -a 256 "$RESOURCES/launcher.sh"     | /usr/bin/awk '{print $1}'
)"

[ -n "$LAUNCHER_BUILD_ID" ]   || die "Failed to calculate launcher build ID."

/usr/bin/sed -i ''   "s/__LAUNCHER_BUILD_ID__/$LAUNCHER_BUILD_ID/g"   "$RESOURCES/launcher.sh"

chmod +x "$RESOURCES/launcher.sh"

# ─────────────────────────────────────────────
# STEP 5: Compile the tiny AppKit/WKWebView host.
#
# DS Harness owns the macOS window, Dock identity, and app lifecycle.
# WKWebView renders the local DSH Web UI directly. The DSH backend is still
# independently managed by launchd.
# ─────────────────────────────────────────────

cat > "$BUILD_TMP/shim.m" <<'OBJC'
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

static NSString * const DSHURLString = @"http://127.0.0.1:3080";

@interface DSHAppDelegate : NSObject
    <NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, copy) NSString *launcherPath;
@property(nonatomic, assign) BOOL launcherRunning;
@property(nonatomic, assign) BOOL backendReady;
@end

@implementation DSHAppDelegate

- (NSDictionary *)menuCommandMetadataAtPath:(NSString *)path {
    NSError *error = nil;
    NSString *content =
        [NSString stringWithContentsOfFile:path
                                  encoding:NSUTF8StringEncoding
                                     error:&error];

    if (content == nil) {
        return nil;
    }

    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    metadata[@"order"] = @100;

    NSArray<NSString *> *lines =
        [content componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];

    for (NSString *rawLine in lines) {
        NSString *line =
            [rawLine stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];

        if (line.length == 0) {
            continue;
        }

        if (![line hasPrefix:@"#"]) {
            break;
        }

        if (![line hasPrefix:@"# @"]) {
            continue;
        }

        NSString *body =
            [line substringFromIndex:3];

        NSRange space = [body rangeOfCharacterFromSet:
            [NSCharacterSet whitespaceCharacterSet]];

        NSString *key = nil;
        NSString *value = @"";

        if (space.location == NSNotFound) {
            key = body.lowercaseString;
        } else {
            key = [[body substringToIndex:space.location] lowercaseString];
            value =
                [[body substringFromIndex:NSMaxRange(space)]
                    stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
        }

        if ([key isEqualToString:@"menu"]) {
            metadata[@"title"] = value;
        } else if ([key isEqualToString:@"shortcut"]) {
            metadata[@"shortcut"] = value;
        } else if ([key isEqualToString:@"order"]) {
            metadata[@"order"] = @([value integerValue]);
        } else if ([key isEqualToString:@"separator"]) {
            metadata[@"separator"] = value.lowercaseString;
        } else if ([key isEqualToString:@"enabled"]) {
            metadata[@"enabled"] = value.lowercaseString;
        }
    }

    NSString *title = metadata[@"title"];
    if (title.length == 0) {
        return nil;
    }

    NSString *enabled = metadata[@"enabled"];
    if ([enabled isEqualToString:@"false"] ||
        [enabled isEqualToString:@"no"] ||
        [enabled isEqualToString:@"0"]) {
        return nil;
    }

    metadata[@"path"] = path;
    return metadata;
}

- (void)addCommandFilesFromDirectory:(NSString *)directory
                            intoMap:(NSMutableDictionary<NSString *, NSString *> *)map {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names =
        [fm contentsOfDirectoryAtPath:directory error:nil];

    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if (![[name pathExtension].lowercaseString isEqualToString:@"sh"]) {
            continue;
        }

        NSString *path =
            [directory stringByAppendingPathComponent:name];

        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory) {
            // Command files are keyed by basename.
            map[name] = path;
        }
    }
}

- (NSArray<NSDictionary *> *)menuCommandEntries {
    NSString *commandsDir =
        [@"~/.config/dsh-desktop/commands.d" stringByExpandingTildeInPath];

    NSMutableDictionary<NSString *, NSString *> *commands =
        [NSMutableDictionary dictionary];

    [self addCommandFilesFromDirectory:commandsDir intoMap:commands];

    NSMutableArray<NSDictionary *> *entries =
        [NSMutableArray array];

    for (NSString *name in commands) {
        NSDictionary *metadata =
            [self menuCommandMetadataAtPath:commands[name]];
        if (metadata != nil) {
            [entries addObject:metadata];
        }
    }

    [entries sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSInteger left = [a[@"order"] integerValue];
            NSInteger right = [b[@"order"] integerValue];

            if (left < right) {
                return NSOrderedAscending;
            }
            if (left > right) {
                return NSOrderedDescending;
            }

            return [a[@"title"] compare:b[@"title"]
                                options:NSCaseInsensitiveSearch];
        }];

    return entries;
}

- (void)applyShortcut:(NSString *)shortcut
           toMenuItem:(NSMenuItem *)item {
    if (shortcut.length == 0) {
        return;
    }

    NSArray<NSString *> *parts =
        [shortcut.lowercaseString componentsSeparatedByString:@"+"];

    NSEventModifierFlags modifiers = 0;
    NSString *key = nil;

    for (NSString *rawPart in parts) {
        NSString *part =
            [rawPart stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];

        if ([part isEqualToString:@"cmd"] ||
            [part isEqualToString:@"command"]) {
            modifiers |= NSEventModifierFlagCommand;
        } else if ([part isEqualToString:@"shift"]) {
            modifiers |= NSEventModifierFlagShift;
        } else if ([part isEqualToString:@"option"] ||
                   [part isEqualToString:@"alt"]) {
            modifiers |= NSEventModifierFlagOption;
        } else if ([part isEqualToString:@"ctrl"] ||
                   [part isEqualToString:@"control"]) {
            modifiers |= NSEventModifierFlagControl;
        } else if (part.length > 0) {
            key = part;
        }
    }

    if ([key isEqualToString:@"space"]) {
        key = @" ";
    } else if ([key isEqualToString:@"comma"]) {
        key = @",";
    } else if ([key isEqualToString:@"period"]) {
        key = @".";
    }

    if (key.length == 1) {
        item.keyEquivalent = key;
        item.keyEquivalentModifierMask = modifiers;
    }
}

- (void)runMenuCommand:(NSMenuItem *)sender {
    NSString *commandPath = sender.representedObject;
    if (commandPath.length == 0) {
        return;
    }

    NSString *runnerPath =
        [[[NSBundle mainBundle] resourcePath]
            stringByAppendingPathComponent:@"run-command.sh"];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[ runnerPath, commandPath ];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self showLauncherError:
            [NSString stringWithFormat:@"Failed to run menu command: %@",
                                       error.localizedDescription]];
    }
}

- (void)reloadUI:(id)sender {
    (void)sender;

    if (self.backendReady) {
        [self showWindowAndLoadIfNeeded:YES];
    } else if (!self.launcherRunning) {
        [self startBackend];
    }
}

- (void)showWindowAction:(id)sender {
    (void)sender;

    if (self.backendReady) {
        [self showWindowAndLoadIfNeeded:NO];
    } else if (!self.launcherRunning) {
        [self startBackend];
    }
}

- (void)installStatusMenu {
    if (self.statusItem == nil) {
        self.statusItem =
            [[NSStatusBar systemStatusBar]
                statusItemWithLength:NSVariableStatusItemLength];

        NSStatusBarButton *button = self.statusItem.button;
        button.title = @"DSH";
        button.toolTip = @"DS Harness";
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"DS Harness"];

    NSMenuItem *openItem =
        [[NSMenuItem alloc] initWithTitle:@"Open DS Harness"
                                  action:@selector(showWindowAction:)
                           keyEquivalent:@""];
    openItem.target = self;
    [menu addItem:openItem];

    NSMenuItem *reloadItem =
        [[NSMenuItem alloc] initWithTitle:@"Reload UI"
                                  action:@selector(reloadUI:)
                           keyEquivalent:@"r"];
    reloadItem.target = self;
    [menu addItem:reloadItem];

    NSArray<NSDictionary *> *entries = [self menuCommandEntries];

    if (entries.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
    }

    for (NSDictionary *entry in entries) {
        NSString *separator = entry[@"separator"];

        if ([separator isEqualToString:@"before"] &&
            menu.itemArray.lastObject != nil &&
            ![menu.itemArray.lastObject isSeparatorItem]) {
            [menu addItem:[NSMenuItem separatorItem]];
        }

        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:entry[@"title"]
                                      action:@selector(runMenuCommand:)
                               keyEquivalent:@""];

        item.target = self;
        item.representedObject = entry[@"path"];
        [self applyShortcut:entry[@"shortcut"] toMenuItem:item];
        [menu addItem:item];

        if ([separator isEqualToString:@"after"]) {
            [menu addItem:[NSMenuItem separatorItem]];
        }
    }

    if (menu.itemArray.lastObject != nil &&
        ![menu.itemArray.lastObject isSeparatorItem]) {
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *quitItem =
        [[NSMenuItem alloc] initWithTitle:@"Quit DS Harness"
                                  action:@selector(terminate:)
                           keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

- (void)installMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *appMenuItem =
        [[NSMenuItem alloc] initWithTitle:@""
                                  action:nil
                           keyEquivalent:@""];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"DS Harness"];

    NSMenuItem *aboutItem =
        [[NSMenuItem alloc] initWithTitle:@"About DS Harness"
                                  action:@selector(orderFrontStandardAboutPanel:)
                           keyEquivalent:@""];
    aboutItem.target = NSApp;
    [appMenu addItem:aboutItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *reloadItem =
        [[NSMenuItem alloc] initWithTitle:@"Reload UI"
                                  action:@selector(reloadUI:)
                           keyEquivalent:@"r"];
    reloadItem.target = self;
    [appMenu addItem:reloadItem];

    NSArray<NSDictionary *> *entries = [self menuCommandEntries];

    if (entries.count > 0) {
        [appMenu addItem:[NSMenuItem separatorItem]];
    }

    for (NSDictionary *entry in entries) {
        NSString *separator = entry[@"separator"];

        if ([separator isEqualToString:@"before"] &&
            appMenu.itemArray.lastObject != nil &&
            ![appMenu.itemArray.lastObject isSeparatorItem]) {
            [appMenu addItem:[NSMenuItem separatorItem]];
        }

        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:entry[@"title"]
                                      action:@selector(runMenuCommand:)
                               keyEquivalent:@""];

        item.target = self;
        item.representedObject = entry[@"path"];
        [self applyShortcut:entry[@"shortcut"] toMenuItem:item];
        [appMenu addItem:item];

        if ([separator isEqualToString:@"after"]) {
            [appMenu addItem:[NSMenuItem separatorItem]];
        }
    }

    if (appMenu.itemArray.lastObject != nil &&
        ![appMenu.itemArray.lastObject isSeparatorItem]) {
        [appMenu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *hideItem =
        [[NSMenuItem alloc] initWithTitle:@"Hide DS Harness"
                                  action:@selector(hide:)
                           keyEquivalent:@"h"];
    hideItem.target = NSApp;
    [appMenu addItem:hideItem];

    NSMenuItem *hideOthersItem =
        [[NSMenuItem alloc] initWithTitle:@"Hide Others"
                                  action:@selector(hideOtherApplications:)
                           keyEquivalent:@"h"];
    hideOthersItem.target = NSApp;
    hideOthersItem.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItem:hideOthersItem];

    NSMenuItem *showAllItem =
        [[NSMenuItem alloc] initWithTitle:@"Show All"
                                  action:@selector(unhideAllApplications:)
                           keyEquivalent:@""];
    showAllItem.target = NSApp;
    [appMenu addItem:showAllItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem =
        [[NSMenuItem alloc] initWithTitle:@"Quit DS Harness"
                                  action:@selector(terminate:)
                           keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [appMenu addItem:quitItem];

    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    // Standard Edit menu. Nil targets intentionally use AppKit's responder
    // chain so Copy/Paste/Undo work correctly inside WKWebView.
    NSMenuItem *editMenuItem =
        [[NSMenuItem alloc] initWithTitle:@"Edit"
                                  action:nil
                           keyEquivalent:@""];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

    NSMenuItem *undoItem =
        [[NSMenuItem alloc] initWithTitle:@"Undo"
                                  action:@selector(undo:)
                           keyEquivalent:@"z"];
    undoItem.target = nil;
    [editMenu addItem:undoItem];

    NSMenuItem *redoItem =
        [[NSMenuItem alloc] initWithTitle:@"Redo"
                                  action:@selector(redo:)
                           keyEquivalent:@"z"];
    redoItem.target = nil;
    redoItem.keyEquivalentModifierMask =
        NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:redoItem];

    [editMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *cutItem =
        [[NSMenuItem alloc] initWithTitle:@"Cut"
                                  action:@selector(cut:)
                           keyEquivalent:@"x"];
    cutItem.target = nil;
    [editMenu addItem:cutItem];

    NSMenuItem *copyItem =
        [[NSMenuItem alloc] initWithTitle:@"Copy"
                                  action:@selector(copy:)
                           keyEquivalent:@"c"];
    copyItem.target = nil;
    [editMenu addItem:copyItem];

    NSMenuItem *pasteItem =
        [[NSMenuItem alloc] initWithTitle:@"Paste"
                                  action:@selector(paste:)
                           keyEquivalent:@"v"];
    pasteItem.target = nil;
    [editMenu addItem:pasteItem];

    [editMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *selectAllItem =
        [[NSMenuItem alloc] initWithTitle:@"Select All"
                                  action:@selector(selectAll:)
                           keyEquivalent:@"a"];
    selectAllItem.target = nil;
    [editMenu addItem:selectAllItem];

    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];

    [NSApp setMainMenu:mainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    [self installMainMenu];
    [self installStatusMenu];

    self.launcherPath =
        [[[NSBundle mainBundle] resourcePath]
            stringByAppendingPathComponent:@"launcher.sh"];

    [self startBackend];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;

    // Re-scan ~/.config/dsh-desktop/commands.d whenever the app becomes
    // active, so menu customizations do not require rebuilding the app.
    [self installMainMenu];
    [self installStatusMenu];
}

- (void)showLauncherError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"DS Harness";
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleCritical;
    [alert runModal];
}

- (void)buildWindowIfNeeded {
    if (self.window != nil) {
        return;
    }

    NSRect frame = NSMakeRect(0, 0, 1280, 820);
    NSWindowStyleMask style =
        NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable;

    self.window =
        [[NSWindow alloc] initWithContentRect:frame
                                   styleMask:style
                                     backing:NSBackingStoreBuffered
                                       defer:NO];

    self.window.title = @"DS Harness";
    self.window.releasedWhenClosed = NO;
    self.window.minSize = NSMakeSize(800, 520);
    [self.window center];

    WKWebViewConfiguration *configuration =
        [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

    self.webView =
        [[WKWebView alloc] initWithFrame:self.window.contentView.bounds
                           configuration:configuration];

    self.webView.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;

    self.window.contentView = self.webView;
}

- (void)showWindowAndLoadIfNeeded:(BOOL)forceReload {
    [self buildWindowIfNeeded];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if (forceReload || self.webView.URL == nil) {
        NSURL *url = [NSURL URLWithString:DSHURLString];
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

- (void)startBackend {
    if (self.launcherRunning) {
        return;
    }

    if (![[NSFileManager defaultManager]
            isExecutableFileAtPath:self.launcherPath]) {
        [self showLauncherError:
            @"launcher.sh is missing or is not executable."];
        [NSApp terminate:nil];
        return;
    }

    self.launcherRunning = YES;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[ self.launcherPath ];

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) selfRef = weakSelf;
            if (selfRef == nil) {
                return;
            }

            selfRef.launcherRunning = NO;

            if (finishedTask.terminationStatus != 0) {
                [NSApp terminate:nil];
                return;
            }

            selfRef.backendReady = YES;
            [selfRef showWindowAndLoadIfNeeded:YES];
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        self.launcherRunning = NO;
        [self showLauncherError:
            [NSString stringWithFormat:@"Failed to start launcher: %@",
                                       error.localizedDescription]];
        [NSApp terminate:nil];
    }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                    hasVisibleWindows:(BOOL)flag {
    (void)sender;

    if (self.backendReady) {
        [self showWindowAndLoadIfNeeded:NO];
    } else if (!self.launcherRunning) {
        [self startBackend];
    }

    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:
    (NSApplication *)sender {
    (void)sender;
    return NO;
}

- (BOOL)isLocalURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"127.0.0.1"] ||
           [host isEqualToString:@"localhost"];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:
                        (void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;

    if (navigationAction.navigationType == WKNavigationTypeLinkActivated &&
        url != nil &&
        ![self isLocalURL:url]) {
        [[NSWorkspace sharedWorkspace] openURL:url];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    (void)configuration;
    (void)windowFeatures;

    if (navigationAction.targetFrame == nil) {
        NSURL *url = navigationAction.request.URL;

        if (url != nil && [self isLocalURL:url]) {
            [webView loadRequest:navigationAction.request];
        } else if (url != nil) {
            [[NSWorkspace sharedWorkspace] openURL:url];
        }
    }

    return nil;
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        DSHAppDelegate *delegate = [[DSHAppDelegate alloc] init];
        app.delegate = delegate;

        [app run];

        // Keep the delegate alive for the lifetime of NSApplication.
        (void)delegate;
    }

    return 0;
}
OBJC

/usr/bin/xcrun --sdk macosx clang \
  -fobjc-arc \
  -Os \
  -Wall \
  -Wextra \
  "$BUILD_TMP/shim.m" \
  -framework AppKit \
  -framework WebKit \
  -o "$MACOS/DSH"

chmod +x "$MACOS/DSH"

# ─────────────────────────────────────────────
# STEP 6: Validate the bundle.
# ─────────────────────────────────────────────

/usr/bin/plutil -lint "$INFO" >/dev/null \
  || die "Info.plist is invalid."

/usr/bin/file "$MACOS/DSH" | /usr/bin/grep -q "Mach-O" \
  || die "The app shim is not a Mach-O executable."

[ -x "$RESOURCES/launcher.sh" ] \
  || die "launcher.sh is missing or not executable."

[ -f "$RESOURCES/DSH.icns" ] \
  || die "DSH.icns is missing."

/usr/bin/touch "$APP_DIR"

echo
echo "Built:"
echo "  $APP_DIR"
echo
echo "Test:"
echo "  open \"$APP_DIR\""
echo
echo "Legacy launcher migration is automatic."
echo
echo "Managed launchd service:"
echo "  com.beforewave.ds-harness.web"
echo
echo "Background error log:"
echo "  $HOME/Library/Logs/DS Harness/web-error.log"

echo
echo "This app is intentionally unsigned."
echo "For the first launch after downloading, right-click DS Harness.app in Finder,"
echo "choose Open, then confirm Open."
