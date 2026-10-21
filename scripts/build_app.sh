#!/bin/zsh
# Builds build/Marmalade.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Marmalade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Marmalade "$APP/Contents/MacOS/Marmalade"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon (generated once, then cached in Resources/)
if [[ ! -f Resources/AppIcon.icns ]]; then
    TMP=$(mktemp -d)
    swift scripts/make_icon.swift "$TMP/icon.png"
    mkdir "$TMP/AppIcon.iconset"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
    rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS will launch it on Apple Silicon
codesign --force --deep --sign - "$APP"
echo "Built $APP"
