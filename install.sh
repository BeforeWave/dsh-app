#!/bin/bash
set -euo pipefail

REPOSITORY="${DS_HARNESS_REPO:-beforewave/dsh-desktop}"
VERSION="${DS_HARNESS_VERSION:-latest}"
ASSET_NAME="dsh-desktop-macOS.zip"
APP_NAME="DS Harness.app"

INSTALL_DIR="${DS_HARNESS_INSTALL_DIR:-$HOME/Applications}"
TARGET="$INSTALL_DIR/$APP_NAME"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: DS Harness is available for macOS only." >&2
  exit 1
fi

if [ "$VERSION" = "latest" ]; then
  DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/latest/download/$ASSET_NAME"
else
  DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$VERSION/$ASSET_NAME"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading DS Harness..."
echo "$DOWNLOAD_URL"

/usr/bin/curl \
  --fail \
  --location \
  --retry 3 \
  --connect-timeout 10 \
  "$DOWNLOAD_URL" \
  --output "$TMP_DIR/$ASSET_NAME"

mkdir -p "$TMP_DIR/unpacked"
/usr/bin/ditto -x -k "$TMP_DIR/$ASSET_NAME" "$TMP_DIR/unpacked"

SOURCE="$TMP_DIR/unpacked/$APP_NAME"

if [ ! -d "$SOURCE" ]; then
  echo "Error: '$APP_NAME' was not found in the release archive." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET"
/usr/bin/ditto "$SOURCE" "$TARGET"

echo
echo "Installed:"
echo "  $TARGET"
echo
echo "DS Harness is intentionally unsigned."
echo "For the first launch:"
echo "  1. Open Finder and go to $INSTALL_DIR"
echo "  2. Right-click 'DS Harness.app'"
echo "  3. Choose 'Open'"
echo "  4. Confirm 'Open' if macOS displays a security warning"
echo
echo "Runtime requirements:"
echo "  - a working dsh command, or Node.js/npm/npx"
