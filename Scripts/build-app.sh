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
VERSION="${VERSION:-0.1.0}"                       # CI passes the tag (e.g. 1.2.3)
APP="$ROOT/dist/$APP_NAME.app"
CONFIG="release"

# Signing + auto-update config — all optional; sensible defaults keep local
# builds ad-hoc signed and update-inert until you supply real values.
#   SIGN_IDENTITY        "Developer ID Application: Name (TEAMID)"  (default: - = ad-hoc)
#   SPARKLE_FEED_URL     appcast URL baked into Info.plist
#   SPARKLE_PUBLIC_KEY   base64 EdDSA public key (from Sparkle's generate_keys)
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://balanced02.github.io/ai-usage-bar/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

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

SPARKLE_KEYS="    <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>"
if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    SPARKLE_KEYS="$SPARKLE_KEYS
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>"
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
$SPARKLE_KEYS
</dict>
</plist>
PLIST

echo "▸ embedding Sparkle.framework"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
SPARKLE_FW="$(find "$ROOT/.build" -path '*/Products/Release/Sparkle.framework' -type d 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$FRAMEWORKS/"
    # The binary loads @rpath/Sparkle.framework/… — point @rpath at Contents/Frameworks.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
else
    echo "  ! Sparkle.framework not found in .build — did 'swift build -c release' run?" >&2
fi

# Code signing. Ad-hoc by default (SIGN_IDENTITY=-); a real Developer ID identity
# adds hardened runtime + a secure timestamp so the build can be notarized. Sign
# inside-out: nested helpers → framework → app.
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "▸ ad-hoc code signing"
    RUNTIME=""
else
    echo "▸ code signing as: $SIGN_IDENTITY (hardened runtime)"
    RUNTIME="--options runtime --timestamp"
fi

# $RUNTIME is intentionally unquoted so its flags word-split (empty → nothing).
sign() { codesign --force $RUNTIME --sign "$SIGN_IDENTITY" "$@" 2>/dev/null; }
SPV="$FRAMEWORKS/Sparkle.framework/Versions/B"
if [ -d "$SPV" ]; then
    for x in "$SPV/XPCServices/"*.xpc; do [ -e "$x" ] && sign "$x"; done
    [ -e "$SPV/Autoupdate" ] && sign "$SPV/Autoupdate"
    [ -e "$SPV/Updater.app" ] && sign "$SPV/Updater.app"
    sign "$FRAMEWORKS/Sparkle.framework"
fi
sign "$APP" || echo "  (codesign warning ignored)"

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
