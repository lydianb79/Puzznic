#!/bin/bash
# Builds "Puzznic Remastered.app" into ./build
# Requirements: macOS 13+, Xcode or the Xcode Command Line Tools (Swift 5.9+).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
echo "▸ Building ($CONFIG)…"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c "$CONFIG"
    BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi

APP="build/Puzznic Remastered.app"
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PuzznicRemastered" "$APP/Contents/MacOS/PuzznicRemastered"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon
if [[ ! -f Resources/AppIcon.png ]]; then
    echo "  ! Resources/AppIcon.png not found, app will have no icon"
elif ! command -v iconutil >/dev/null; then
    echo "  ! iconutil not found (install Xcode Command Line Tools), app will have no icon"
else
    echo "▸ Creating AppIcon.icns"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

# Bundle your own ROM dump if it sits next to the project (it is never redistributed by this repo).
for rom in "../Puzznic.nes" "Puzznic.nes"; do
    if [[ -f "$rom" ]]; then cp "$rom" "$APP/Contents/Resources/Puzznic.nes"; echo "▸ Bundled ROM from $rom"; break; fi
done

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

# Refresh Finder/Dock icon caches for this bundle (macOS caches icons per path)
touch "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
echo "✓ Done: $APP"
echo "  Run with: open \"$APP\""
