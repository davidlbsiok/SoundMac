#!/bin/bash
# Builds SoundMac in release mode and packages it as SoundMac.app in the
# project root, with its icon and Info.plist, ad-hoc signed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$ROOT_DIR/SoundMac"
APP="$ROOT_DIR/SoundMac.app"

cd "$PKG_DIR"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SoundMac "$APP/Contents/MacOS/SoundMac"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/SoundMac.app"
    cp -R "$APP" "/Applications/SoundMac.app"
    codesign --force --deep --sign - "/Applications/SoundMac.app"
    echo "Installed to /Applications/SoundMac.app"
fi
