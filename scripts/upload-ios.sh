#!/bin/bash
# Archives the iOS app with the local Xcode and uploads it to App Store Connect.
# Used while the GitHub runners lack the iOS 27.1 SDK, which iPhone Duo needs for full-screen apps.
# usage: ASC_KEY_ID=... ASC_ISSUER_ID=... scripts/upload-ios.sh <build-number> [version]
set -euo pipefail
cd "$(dirname "$0")/.."

build="${1:?usage: scripts/upload-ios.sh <build-number> [version]}"
version="${2:-$(grep -m1 'MARKETING_VERSION' project.yml | awk '{print $2}')}"
certs="${SPANSCREEN_CERTS:-$HOME/.apple-certs/spanscreen}"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"

sdk=$(xcrun --sdk iphoneos --show-sdk-version)
if [ "$(printf '%s\n27.1\n' "$sdk" | sort -V | head -1)" != "27.1" ]; then
  echo "iOS SDK $sdk is older than 27.1" >&2
  exit 1
fi

tmp=$(mktemp -d)
keychain="$tmp/signing.keychain-db"
password=$(uuidgen)
original=$(security list-keychains -d user | tr -d '"')
cleanup() {
  security list-keychains -d user -s $original
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security list-keychains -d user -s "$keychain" $original
security unlock-keychain -p "$password" "$keychain"
security import "$certs/dist.p12" -P "$(cat "$certs/p12.pass")" -A -f pkcs12 -k "$keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
identity=$(security find-identity -v -p codesigning "$keychain" | awk 'NR==1 {print $2}')

profile="$certs/appstore.mobileprovision"
uuid=$(security cms -D -i "$profile" | plutil -extract UUID raw -)
team=$(security cms -D -i "$profile" | plutil -extract TeamIdentifier.0 raw -)
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$profile" "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.mobileprovision"

echo "Archiving Spanscreen $version ($build) with iOS SDK $sdk"
xcodebuild archive -quiet \
  -project Spanscreen.xcodeproj \
  -scheme SpanscreenIOS \
  -destination generic/platform=iOS \
  -archivePath "$tmp/Spanscreen-ios.xcarchive" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  PROVISIONING_PROFILE_SPECIFIER="$uuid" \
  DEVELOPMENT_TEAM="$team" \
  OTHER_CODE_SIGN_FLAGS="--keychain $keychain"

sed -e "s/__TEAM__/$team/" -e "s/__PROFILE__/$uuid/" scripts/ExportOptions-ios.plist > "$tmp/ExportOptions.plist"
plutil -replace signingCertificate -string "$identity" "$tmp/ExportOptions.plist"
xcodebuild -exportArchive -quiet -archivePath "$tmp/Spanscreen-ios.xcarchive" -exportPath "$tmp/ios" -exportOptionsPlist "$tmp/ExportOptions.plist"

xcrun altool --upload-app -f "$tmp/ios/Spanscreen.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
