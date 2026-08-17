#!/bin/bash
# @menu Check for Updates
# @order 40
# @separator before

set -u

PACKAGE="@deepseek-ai/dsh"
SUPPORT_DIR="${DSH_DESKTOP_SUPPORT_DIR:-$HOME/Library/Application Support/DS Harness}"
MODE_FILE="$SUPPORT_DIR/mode"
RUNTIME_PATH_FILE="$SUPPORT_DIR/runtime-path"
DSH_PATH_FILE="$SUPPORT_DIR/dsh-path"
NPM_PATH_FILE="$SUPPORT_DIR/npm-path"
VERSION_FILE="$SUPPORT_DIR/version"

show_error() {
  MESSAGE="$1" /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
set msg to system attribute "MESSAGE"
display alert "DS Harness Update" message msg as critical buttons {"OK"} default button "OK"
APPLESCRIPT
}

runtime_path="$(cat "$RUNTIME_PATH_FILE" 2>/dev/null || true)"
mode="$(cat "$MODE_FILE" 2>/dev/null || true)"

current=""
if [ "$mode" = "npx" ]; then
  current="$(cat "$VERSION_FILE" 2>/dev/null || true)"
else
  dsh_bin="$(cat "$DSH_PATH_FILE" 2>/dev/null || true)"
  if [ -n "$dsh_bin" ] && [ -x "$dsh_bin" ]; then
    current="$(env PATH="${runtime_path:-$PATH}" "$dsh_bin" --version 2>/dev/null \
      | /usr/bin/grep -Eo '[0-9]+\.[0-9]+\.[0-9]+[-+._A-Za-z0-9]*' \
      | /usr/bin/head -n 1 || true)"
  fi
fi

if [ -z "$current" ]; then
  show_error "Could not determine the current DeepSeek Harness version."
  exit 1
fi

npm_bin="$(cat "$NPM_PATH_FILE" 2>/dev/null || true)"
if [ -z "$npm_bin" ] || [ ! -x "$npm_bin" ]; then
  npm_bin="$(command -v npm 2>/dev/null || true)"
fi

if [ -z "$npm_bin" ]; then
  show_error "npm was not found, so the latest DeepSeek Harness version could not be checked."
  exit 1
fi

latest="$(env PATH="${runtime_path:-$PATH}" \
  npm_config_fetch_timeout=5000 \
  npm_config_fetch_retries=0 \
  "$npm_bin" view "$PACKAGE" version --silent 2>/dev/null \
  | /usr/bin/tail -n 1)"

if [ -z "$latest" ]; then
  show_error "Failed to query the latest DeepSeek Harness version from npm."
  exit 1
fi

if [ "$current" = "$latest" ]; then
  CURRENT="$current" /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
set cur to system attribute "CURRENT"
display dialog "DeepSeek Harness is up to date." & return & return & "Current: " & cur with title "DS Harness Update" buttons {"OK"} default button "OK"
APPLESCRIPT
  exit 0
fi

if [ "$mode" = "npx" ]; then
  CHOICE_FILE="$SUPPORT_DIR/update-choice"
  rm -f "$CHOICE_FILE"

  CURRENT="$current" LATEST="$latest" CHOICE_FILE="$CHOICE_FILE" \
    /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
set cur to system attribute "CURRENT"
set lat to system attribute "LATEST"
set choiceFile to system attribute "CHOICE_FILE"

set r to display dialog "A new DeepSeek Harness version is available." & return & return & ¬
  "Current: " & cur & return & ¬
  "Latest: " & lat & return & return & ¬
  "The new version will be used the next time the backend starts." ¬
  with title "DS Harness Update" ¬
  buttons {"Later", "Update Next Start"} ¬
  default button "Update Next Start"

if button returned of r is "Update Next Start" then
  do shell script "/bin/echo " & quoted form of lat & " > " & quoted form of choiceFile
end if
APPLESCRIPT

  if [ -s "$CHOICE_FILE" ]; then
    cat "$CHOICE_FILE" > "$VERSION_FILE"
    rm -f "$CHOICE_FILE"
  fi
else
  CURRENT="$current" LATEST="$latest" \
    /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1
set cur to system attribute "CURRENT"
set lat to system attribute "LATEST"

set r to display dialog "A new DeepSeek Harness version is available." & return & return & ¬
  "Current: " & cur & return & ¬
  "Latest: " & lat ¬
  with title "DS Harness Update" ¬
  buttons {"Later", "Copy Update Command"} ¬
  default button "Copy Update Command"

if button returned of r is "Copy Update Command" then
  set the clipboard to "npm install -g @deepseek-ai/dsh@latest"
end if
APPLESCRIPT
fi
