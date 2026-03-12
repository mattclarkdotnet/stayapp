#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$DIST_DIR/Stay.app"
ZIP_PATH="$DIST_DIR/Stay.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set NOTARY_PROFILE to a notarytool keychain profile name." >&2
  echo "Example: NOTARY_PROFILE=StayNotary ./Scripts/notarize-stay-app.sh" >&2
  exit 1
fi

"$ROOT_DIR/Scripts/build-stay-app.sh"

rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
spctl -a -vv "$APP_BUNDLE"

echo "Notarized and stapled $APP_BUNDLE"
