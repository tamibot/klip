#!/bin/bash
# Builds Klip and assembles the .app bundle (no Xcode, just Command Line Tools).
# Also owns the PREFLIGHT below: install.sh gets it by calling this script, so the
# requirements are stated in exactly one place.
set -e

APP_NAME="Klip"
BUNDLE="$APP_NAME.app"
CONFIG="${1:-release}"
BUILD_DIR=".build/$CONFIG"
BUNDLE_ID="com.proper.klip"
ENTITLEMENTS="Resources/Klip.entitlements"
MIN_MACOS=14        # keep in sync with Package.swift: platforms: [.macOS(.v14)]

cd "$(dirname "$0")"

# Everything a stranger's Mac has to have before the (slow) build starts.
preflight() {
    local os major swift_out

    os="$(sw_vers -productVersion 2>/dev/null || true)"
    major="${os%%.*}"          # numeric compare on the major only: "26.0" > "9.0", and a bare "14" works
    case "$major" in
        ''|*[!0-9]*)
            echo "✗ Could not read the macOS version (sw_vers -productVersion)." >&2
            echo "  Klip needs macOS $MIN_MACOS or newer." >&2
            exit 1 ;;
    esac
    if [ "$major" -lt "$MIN_MACOS" ]; then
        echo "✗ Klip needs macOS $MIN_MACOS or newer — this Mac runs macOS $os." >&2
        echo "  Update in System Settings › General › Software Update, then run this script again." >&2
        exit 1
    fi

    # Prefer the Command Line Tools when a freshly-installed Xcode has an unaccepted license — that
    # state makes every swift/xcrun call fail with "You have not agreed to the Xcode license
    # agreements", which looks like a broken build. Only used if the CLT are actually present.
    if [ -z "${DEVELOPER_DIR:-}" ] && ! /usr/bin/xcrun --find swift >/dev/null 2>&1 \
       && [ -d /Library/Developer/CommandLineTools ]; then
        export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    fi

    # Judge the toolchain by its OUTPUT, not its exit status: a DEVELOPER_DIR pointing at a directory
    # with no toolchain makes /usr/bin/swift print an xcrun error that used to reach the user as a
    # mid-build failure (and, on some setups, a zero exit code).
    swift_out="$(swift --version 2>&1 || true)"
    case "$swift_out" in
        *"Swift version"*) ;;
        *)
            echo "✗ No usable Swift toolchain: 'swift --version' did not report a version." >&2
            echo "  ${swift_out:-(no output)}" >&2
            echo "  Install the Command Line Tools:  xcode-select --install" >&2
            if [ -n "${DEVELOPER_DIR:-}" ]; then
                echo "  DEVELOPER_DIR is '$DEVELOPER_DIR' — unset it or point it at a real toolchain." >&2
            fi
            exit 1 ;;
    esac
}
preflight

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
echo "  Shortcuts: ⌥⇧E history · ⌥⇧R voice · ⌥⇧D annotate · ⌥⇧F OCR"
echo "             ⌥⇧O upload  · ⌥⇧M meeting · ⌥⇧V record · ⌥⇧S scroll"
echo "  Install: ./install.sh   ·   Remove everything: ./uninstall.sh"
