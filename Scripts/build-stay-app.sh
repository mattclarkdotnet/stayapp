#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
APP_NAME="Stay.app"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/dist}"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME"
INFO_PLIST_SOURCE="$ROOT_DIR/AppBundle/Info.plist"
SIGNING_IDENTITY=${SIGNING_IDENTITY:-}
MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION:-1}
PRODUCT_BUNDLE_IDENTIFIER=${PRODUCT_BUNDLE_IDENTIFIER:-net.mattclark.stay}
ASSET_CATALOG_SOURCE="$ROOT_DIR/AppBundle/Assets.xcassets"
ACTOOL_INFO_PLIST="$BUILD_ROOT/actool-info.plist"

if [[ ! -f "$INFO_PLIST_SOURCE" ]]; then
  echo "Missing Info.plist template at $INFO_PLIST_SOURCE" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"

swift build -c "$CONFIGURATION" --product Stay
BIN_PATH=$(swift build -c "$CONFIGURATION" --show-bin-path)
EXECUTABLE="$BIN_PATH/Stay"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Expected Stay executable at $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

/usr/bin/ditto "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/Stay"
/usr/bin/ditto "$INFO_PLIST_SOURCE" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PRODUCT_BUNDLE_IDENTIFIER" \
  "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
  "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CURRENT_PROJECT_VERSION" \
  "$APP_BUNDLE/Contents/Info.plist"

if [[ -d "$ASSET_CATALOG_SOURCE" ]] && command -v xcrun >/dev/null 2>&1; then
  xcrun actool "$ASSET_CATALOG_SOURCE" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --output-format human-readable-text \
    --output-partial-info-plist "$ACTOOL_INFO_PLIST" \
    --notices \
    --warnings \
    --app-icon AppIcon \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx \
    --bundle-identifier "$PRODUCT_BUNDLE_IDENTIFIER" \
    >/dev/null

  rm -f "$ACTOOL_INFO_PLIST"
fi

if command -v codesign >/dev/null 2>&1; then
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk '/Developer ID Application:/ { print $2; exit }'
    )
  fi

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk '/Apple Development:/ { print $2; exit }'
    )
  fi

  CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --timestamp=none)
  if [[ -n "$SIGNING_IDENTITY" ]] && /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -q "^ *[0-9][0-9]*) $SIGNING_IDENTITY \".*Developer ID Application:"; then
    CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --timestamp --options runtime)
  fi

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE" >/dev/null
    echo "Signed with $SIGNING_IDENTITY"
  else
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
    echo "Signed ad hoc (no Apple Development identity found)"
  fi
fi

echo "Built $APP_BUNDLE"
