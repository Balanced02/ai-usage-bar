#!/bin/bash
# Builds AIUsageBar and assembles a runnable .app bundle (menu-bar agent).
#
#   Scripts/build-app.sh            # build + bundle into dist/AIUsageBar.app
#   Scripts/build-app.sh --run      # also (re)launch it
#   Scripts/build-app.sh --install  # copy to /Applications (needed for launch-at-login)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="AIUsageBar"
BUNDLE_ID="com.aiusagebar.AIUsageBar"
VERSION="0.1.0"
APP="$ROOT/dist/$APP_NAME.app"
CONFIG="release"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$ROOT/.build/$CONFIG/$APP_NAME"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

echo "▸ generating app icon"
ICON_PNG="$ROOT/dist/AppIcon-1024.png"
"$ROOT/.build/$CONFIG/icongen" "$ICON_PNG" >/dev/null 2>&1 || true
if [ -f "$ICON_PNG" ]; then
    ICONSET="$ROOT/dist/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    sips -z 16 16     "$ICON_PNG" --out "$ICONSET/icon_16x16.png"      >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_32x32.png"      >/dev/null
    sips -z 64 64     "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
    sips -z 128 128   "$ICON_PNG" --out "$ICONSET/icon_128x128.png"    >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_256x256.png"    >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_512x512.png"    >/dev/null
    cp "$ICON_PNG"                "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && echo "  ✓ AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>AI Usage Bar</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "▸ ad-hoc code signing"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign warning ignored — ad-hoc)"

echo "✓ built $APP"

case "${1:-}" in
    --run)
        echo "▸ relaunching"
        pkill -x "$APP_NAME" 2>/dev/null || true
        sleep 0.5
        open "$APP"
        ;;
    --install)
        echo "▸ installing to /Applications (for launch-at-login stability)"
        pkill -x "$APP_NAME" 2>/dev/null || true
        rm -rf "/Applications/$APP_NAME.app"
        cp -R "$APP" "/Applications/$APP_NAME.app"
        open "/Applications/$APP_NAME.app"
        echo "✓ installed and launched"
        ;;
esac
