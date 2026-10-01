#!/usr/bin/env bash
# Builds build/portbar.app, ad-hoc signed.
#
#   scripts/build-app.sh               release build for this Mac
#   scripts/build-app.sh --universal   arm64 + x86_64, for releases
#   scripts/build-app.sh --install     build, copy to /Applications, and start it
#
# VERSION sets CFBundleShortVersionString. It defaults to version.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat version.txt)}"
UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --install) INSTALL=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if $UNIVERSAL; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/portbar
else
  swift build -c release
  BIN=.build/release/portbar
fi

APP=build/portbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/portbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp assets/brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"

# Sign the whole bundle, not only the binary, so the signature seals Info.plist.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($VERSION)"

if $INSTALL; then
  pkill -x portbar || true
  pkill -x PortRunner || true
  # The app was called PortRunner before the rename.
  rm -rf /Applications/PortRunner.app /Applications/portbar.app
  cp -R "$APP" /Applications/
  open /Applications/portbar.app
  echo "installed /Applications/portbar.app"
fi
