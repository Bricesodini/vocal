#!/bin/bash
# Construit Vocal.app dans build/ avec l'identifiant et la signature de scripts/identite.sh.
# Usage : scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/identite.sh
swift build -c release --product Vocal
app=build/Vocal.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Vocal "$app/Contents/MacOS/Vocal"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$VOCAL_BUNDLE_ID" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --timestamp=none --sign "$VOCAL_SIGNATURE" "$app"
codesign --verify --strict "$app"
echo "$app"
