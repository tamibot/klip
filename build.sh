#!/bin/bash
# Builds Klip and assembles the .app bundle (no Xcode, just Command Line Tools).
set -e

APP_NAME="Klip"
BUNDLE="$APP_NAME.app"
CONFIG="${1:-release}"
BUILD_DIR=".build/$CONFIG"
BUNDLE_ID="com.proper.klip"
ENTITLEMENTS="Resources/Klip.entitlements"

cd "$(dirname "$0")"

echo "→ Building ($CONFIG)…"
swift build -c "$CONFIG"

echo "→ Assembling $BUNDLE…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# .icns icon from Resources/AppIcon.png via iconutil/sips (no Xcode).
if [ -f "Resources/AppIcon.png" ]; then
    echo "→ Generating icon…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s             Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
        sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png"   >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Interface sounds (see Resources/Sounds/bake-sounds.mjs). SoundFX loads them from Contents/Resources/Sounds.
if [ -d "Resources/Sounds" ]; then
    echo "→ Copying sounds…"
    mkdir -p "$BUNDLE/Contents/Resources/Sounds"
    cp Resources/Sounds/*.wav "$BUNDLE/Contents/Resources/Sounds/"
fi

echo "→ Signing ad-hoc (retries for synced folders that re-add metadata)…"
SIGNED=0
for attempt in 1 2 3; do
    xattr -cr "$BUNDLE" 2>/dev/null || true
    find "$BUNDLE" -name '._*' -delete 2>/dev/null || true
    if codesign --force --sign - --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$BUNDLE" 2>/dev/null; then
        SIGNED=1; break
    fi
done
if [ "$SIGNED" = "1" ] && codesign --verify --strict "$BUNDLE" 2>/dev/null; then
    echo "  valid signature ✓"
else
    echo "  ⚠ local signature invalid (synced folder). Use ./install.sh: it signs in /Applications."
fi

echo ""
echo "✓ Done: $BUNDLE   (run:  open $BUNDLE)"
echo "  Shortcuts: ⌥⇧E (history) · ⌥⇧R (voice) · ⌥⇧D (annotate) · ⌥⇧F (OCR) · ⌥⇧O (upload)   ·   Install: ./install.sh"
