#!/bin/bash
set -euo pipefail
p12_base64="$1"
p12_password="$2"
keychain_password="$3"
keychain="$RUNNER_TEMP/signing.keychain-db"
cert="$RUNNER_TEMP/cert-$RANDOM.p12"

if [ ! -f "$keychain" ]; then
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
fi
security unlock-keychain -p "$keychain_password" "$keychain"
echo "$p12_base64" | base64 --decode > "$cert"
security import "$cert" -P "$p12_password" -A -f pkcs12 -k "$keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
rm -f "$cert"
security find-identity -v -p codesigning "$keychain"
