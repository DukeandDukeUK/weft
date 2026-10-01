#!/bin/bash
# Builds, signs, notarizes and packages Weft for download.
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
ZIP="$DIST/Weft-$VERSION.zip"

VERSION="$VERSION" ./make-app.sh

SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
    echo "error: the app isn't signed with a Developer ID certificate, so it can't be notarized." >&2
    exit 1
fi

mkdir -p "$DIST"
rm -f "$ZIP"

echo "==> Sending to Apple for notarization (usually a few minutes)…"
ditto -c -k --keepParent "$APP" "$DIST/notarize-upload.zip"
xcrun notarytool submit "$DIST/notarize-upload.zip" --keychain-profile "$PROFILE" --wait
rm -f "$DIST/notarize-upload.zip"

echo "==> Attaching Apple's approval to the app…"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
echo ""
echo "Ready to upload: $ZIP"
