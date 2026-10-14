#!/bin/bash
# Builds the app for a real iPhone without signing it and packs it as out/dokkit-ios-unsigned.ipa.
# Whoever installs it signs it with their own Apple account first. Needs Xcode and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
rm -rf build out
xcodebuild -project Dokkit.xcodeproj -scheme Dokkit -configuration Release -sdk iphoneos \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build \
  2>&1 | grep -E 'error:|BUILD|\*\*' | sort -u
app=build/Build/Products/Release-iphoneos/Dokkit.app
test -d "$app"
mkdir -p out/Payload
cp -R "$app" out/Payload/
(cd out && zip -qry dokkit-ios-unsigned.ipa Payload && rm -rf Payload && shasum -a 256 dokkit-ios-unsigned.ipa > dokkit-ios-unsigned.ipa.sha256 && ls -l)
