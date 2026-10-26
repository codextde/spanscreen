#!/bin/bash
# Usage: scripts/package-mac.sh <signed Spanscreen.app> <output.dmg>
# Needs ASC_KEY_ID and ASC_ISSUER_ID and the key in ~/.appstoreconnect/private_keys.
set -euo pipefail
app="$1"
dmg="$2"
key="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
identity="${SIGN_IDENTITY:-Developer ID Application}"

codesign --verify --deep --strict --verbose=2 "$app"

notarize() {
  xcrun notarytool submit "$1" --key "$key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 30m
}

work="$(mktemp -d)"
ditto -c -k --keepParent "$app" "$work/app.zip"
notarize "$work/app.zip"
xcrun stapler staple "$app"

mkdir -p "$work/dmg"
cp -R "$app" "$work/dmg/"
ln -s /Applications "$work/dmg/Applications"
rm -f "$dmg"
hdiutil create -volname "Spanscreen" -srcfolder "$work/dmg" -ov -format ULFO "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
spctl --assess --type execute --verbose=2 "$app"
rm -rf "$work"
echo "Packaged $dmg"
