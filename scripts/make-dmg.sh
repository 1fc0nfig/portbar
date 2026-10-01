#!/usr/bin/env bash
# Packs build/portbar.app into dist/portbar-<version>.dmg and dist/portbar-<version>.zip.
# Run scripts/build-app.sh first. Uses create-dmg when it is installed, else plain hdiutil.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat version.txt)}"
APP=build/portbar.app
DMG="dist/portbar-$VERSION.dmg"
ZIP="dist/portbar-$VERSION.zip"
[ -d "$APP" ] || { echo "missing $APP: run scripts/build-app.sh first" >&2; exit 1; }

mkdir -p dist
rm -f "$DMG" "$ZIP"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/portbar.app"

if command -v create-dmg >/dev/null; then
  # --skip-jenkins skips the Finder layout script, which needs a logged-in session (CI has none).
  extra=()
  [ -n "${CI:-}" ] && extra+=(--skip-jenkins)
  create-dmg \
    --volname "portbar $VERSION" \
    --volicon assets/brand/AppIcon.icns \
    --window-size 540 340 \
    --icon-size 112 \
    --icon "portbar.app" 140 160 \
    --app-drop-link 400 160 \
    --hide-extension "portbar.app" \
    --no-internet-enable \
    ${extra[@]+"${extra[@]}"} \
    "$DMG" "$STAGE" || true   # create-dmg exits non-zero on harmless signing skips
else
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "portbar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi
[ -f "$DMG" ] || { echo "DMG build failed" >&2; exit 1; }

ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$DMG" "$ZIP"
