#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
APP_BUNDLE="$ROOT_DIR/dist/Stay.app"
INSTALL_PATH="$INSTALL_ROOT/Stay.app"

"$ROOT_DIR/Scripts/build-stay-app.sh"

mkdir -p "$INSTALL_ROOT"
rm -rf "$INSTALL_PATH"
/usr/bin/ditto "$APP_BUNDLE" "$INSTALL_PATH"

echo "Installed $INSTALL_PATH"
