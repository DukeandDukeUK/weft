#!/bin/bash
# Builds, signs and notarizes Weft, and packages it as a disk image with the
# usual "drag Weft to Applications" window.
#
#   VERSION=0.1.0 ./release.sh
#
# One-time setup (stores your notarization login in the keychain):
#   xcrun notarytool store-credentials weft-notary \
#       --apple-id <your Apple ID email> --team-id <team id>
# It asks for an app-specific password, made at https://account.apple.com
# (Sign-In and Security > App-Specific Passwords).
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${VERSION:?set VERSION, e.g. VERSION=0.1.0 ./release.sh}"
PROFILE="${NOTARY_PROFILE:-weft-notary}"
APP=".build-app/Weft.app"
DIST="dist"
DMG="$DIST/Weft-$VERSION.dmg"

VERSION="$VERSION" ./make-app.sh

SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
    echo "error: the app isn't signed with a Developer ID certificate, so it can't be notarized." >&2
    exit 1
fi

mkdir -p "$DIST"
rm -f "$DMG"

echo "==> Sending the app to Apple for notarization (usually a few minutes)…"
ditto -c -k --keepParent "$APP" "$DIST/notarize-upload.zip"
xcrun notarytool submit "$DIST/notarize-upload.zip" --keychain-profile "$PROFILE" --wait
rm -f "$DIST/notarize-upload.zip"

echo "==> Attaching Apple's approval to the app…"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Disk-image layout tool, kept inside .build so nothing is installed system-wide.
VENV=".build/dmg-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    echo "==> Installing dmgbuild (one time)…"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q dmgbuild
fi

echo "==> Building the disk image…"
swift scripts/make-dmg-background.swift .build/dmg >/dev/null
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D app="$APP" -D background=.build/dmg/dmg-background.png \
    "Weft" "$DMG"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Sending the disk image to Apple for notarization…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

# Sparkle update feed: lists this version, signed with the update key in
# your keychain (account "weft"). Upload appcast.xml with every release —
# installed copies read it from .../releases/latest/download/appcast.xml.
echo "==> Writing the update feed (appcast.xml)…"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
FEED_DIR="$DIST/feed"
rm -rf "$FEED_DIR" && mkdir -p "$FEED_DIR"
cp "$DMG" "$FEED_DIR/"
"$SPARKLE_BIN/generate_appcast" --account weft \
    --download-url-prefix "https://github.com/DukeandDukeUK/weft/releases/download/v$VERSION/" \
    --link "https://github.com/DukeandDukeUK/weft" \
    -o "$DIST/appcast.xml" "$FEED_DIR"
rm -rf "$FEED_DIR"

echo ""
echo "Ready to upload: $DMG and $DIST/appcast.xml"
