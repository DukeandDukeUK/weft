#!/bin/bash
# Builds Weft.app (Apple Silicon + Intel) into .build-app/.
#
#   ./make-app.sh
#
# Needs the full Xcode app (the Command Line Tools alone lack SwiftUI's macro
# plugin). If Xcode isn't your active developer directory, run:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./make-app.sh
#
# Signing: uses SIGN_IDENTITY if set, otherwise the first "Developer ID
# Application" certificate in your keychain, otherwise ad-hoc (runs on this
# Mac only). To release a notarized build, use ./release.sh.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Weft"
EXEC_NAME="Weft"
BUNDLE_ID="com.dukeandduke.weft"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUT_DIR=".build-app"
APP_DIR="$OUT_DIR/$APP_NAME.app"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found. Install Xcode from the App Store." >&2
    exit 1
fi

echo "==> Building (release, Apple Silicon + Intel)…"
swift build -c release --arch arm64 --arch x86_64

BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_DIR/$EXEC_NAME"
if [ ! -f "$BIN" ]; then
    echo "error: expected binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$EXEC_NAME"

# Sparkle (automatic updates). ditto keeps the framework's internal symlinks.
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
# The Downloader service is only needed by sandboxed apps; Weft isn't one.
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"

echo "==> Drawing icon…"
swift scripts/make-icon.swift "$OUT_DIR" >/dev/null
iconutil -c icns "$OUT_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

# NSAllowsLocalNetworking: allow plain HTTP to localhost (Ollama / LM Studio).
# Everything else stays under App Transport Security.
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Weft sends your replies through the Messages app.</string>
    <key>NSContactsUsageDescription</key>
    <string>Weft shows contact names next to phone numbers so you can find your conversation.</string>
    <key>SUFeedURL</key>
    <string>https://github.com/DukeandDukeUK/weft/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>UrFI52Nv0o1NgZOQqLk9j9NXkehx9GIMlCthDXp4QN4=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing with: $IDENTITY"
    # Hardened runtime + secure timestamp are required for notarization.
    # The Apple Events entitlement lets the hardened app drive Messages.
    # Sparkle's parts first, innermost to outermost (Sparkle's documented
    # order), then the app itself.
    SPK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
    codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK/Versions/B/XPCServices/Installer.xpc"
    codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK/Versions/B/Autoupdate"
    codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK/Versions/B/Updater.app"
    codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPK"
    codesign --force --options runtime --timestamp \
        --entitlements Weft.entitlements \
        --sign "$IDENTITY" "$APP_DIR"
    codesign --verify --deep --strict --verbose=1 "$APP_DIR"
else
    echo "==> No Developer ID certificate found — ad-hoc signing (this Mac only)…"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo ""
echo "Done: $APP_DIR (version $VERSION)"
echo "First launch: grant Full Disk Access in System Settings > Privacy & Security,"
echo "then pick the conversation to sort and the AI to sort it with (Settings)."
