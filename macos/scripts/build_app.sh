#!/bin/sh
# Builds build/Portolan.app (macOS) from this repository and the game data in core/assets.
# core/assets is not part of the repository: build it from your own copy of the original game with
# core/tools/build_assets.sh (see README).
set -eu
cd "$(dirname "$0")/.."
ASSETS="${PORTOLAN_ASSETS:-../core/assets}"
if [ "${PORTOLAN_BUNDLE_PRIVATE_ASSETS:-0}" = 1 ] && [ ! -f "$ASSETS/world_mask.bin" ]; then
    echo "Selected private assets are missing; build them from your own copy first." >&2
    exit 1
fi
VERSION=$(python3 -c "import json; print(json.load(open('config/build-version.json'))['appVersion'])")
BUILD=$(python3 -c "import json; print(json.load(open('config/build-version.json'))['buildNumber'])")
set -- -c release
if [ -n "${PORTOLAN_SDK_PATH:-}" ]; then set -- "$@" --sdk "$PORTOLAN_SDK_PATH"; fi
swift build "$@" --product Portolan
BIN=$(swift build "$@" --show-bin-path)
APP=build/Portolan.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Portolan" "$APP/Contents/MacOS/Portolan"
cp ../LICENSE ../NOTICE.md ../THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
if [ "${PORTOLAN_BUNDLE_PRIVATE_ASSETS:-0}" = 1 ]; then
    cp -R "$ASSETS" "$APP/Contents/Resources/assets"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Portolan</string>
    <key>CFBundleIdentifier</key><string>app.portolan.mac</string>
    <key>CFBundleExecutable</key><string>Portolan</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [ "${PORTOLAN_BUNDLE_PRIVATE_ASSETS:-0}" = 1 ]; then
    echo "built $APP with PRIVATE GAME DATA: do not redistribute this app."
else
    echo "built $APP without game data. Set PORTOLAN_ASSETS when launching locally."
fi
