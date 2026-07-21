#!/bin/bash
# Local deploy: build, sign with a STABLE identity (so macOS remembers the
# microphone/accessibility permissions across updates), install and relaunch.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Klip"
SRC_BUNDLE="$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
SIGN_IDENTITY_NAME="Klip Code Signing"

# Creates (once) a self-signed code-signing certificate and marks it trusted, so the
# signature stays stable across rebuilds → TCC (microphone, etc.) does NOT re-prompt.
# Prints the identity name on stdout; fails (return 1) if it couldn't be prepared.
ensure_identity() {
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY_NAME"; then
        echo "$SIGN_IDENTITY_NAME"; return 0
    fi
    command -v openssl >/dev/null 2>&1 || return 1
    local kc tmp legacy
    kc="$(security default-keychain | tr -d ' \t"')"
    tmp="$(mktemp -d)"
    legacy=""; openssl version 2>/dev/null | grep -q "OpenSSL 3" && legacy="-legacy" || true
    cat > "$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $SIGN_IDENTITY_NAME
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k.pem" -out "$tmp/c.pem" \
            -days 3650 -config "$tmp/req.cnf" -extensions v3 >/dev/null 2>&1 \
       && openssl pkcs12 -export $legacy -inkey "$tmp/k.pem" -in "$tmp/c.pem" -out "$tmp/c.p12" \
            -passout pass:klip -name "$SIGN_IDENTITY_NAME" >/dev/null 2>&1 \
       && security import "$tmp/c.p12" -k "$kc" -P klip -T /usr/bin/codesign -A >/dev/null 2>&1; then
        security add-trusted-cert -r trustRoot -p codeSign -k "$kc" "$tmp/c.pem" >/dev/null 2>&1 || true
        rm -rf "$tmp"
        if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY_NAME"; then
            echo "$SIGN_IDENTITY_NAME"; return 0
        fi
    fi
    rm -rf "$tmp"; return 1
}

echo "==> 1) Building the .app (release)…"
./build.sh release

echo "==> 2) Closing previous instances (if any)…"
/usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
/usr/bin/pkill -x Pasta 2>/dev/null || true   # previous name
perl -e 'select(undef,undef,undef,0.4)'

echo "==> 3) Installing into /Applications…"
SUDO=""
if [ ! -w /Applications ]; then SUDO="sudo"; fi
$SUDO rm -rf "$DEST"
$SUDO cp -R "$SRC_BUNDLE" "$DEST"
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Signing identity: stable if possible (no sudo, so it can use the user's keychain).
SIGN_ID="-"
if [ -z "$SUDO" ]; then
    if ID="$(ensure_identity)"; then SIGN_ID="$ID"; fi
fi

echo "==> 3.5) Signing in /Applications (stable location, no metadata re-added)…"
$SUDO xattr -cr "$DEST" 2>/dev/null || true
if ! $SUDO codesign --force --sign "$SIGN_ID" --identifier com.proper.klip \
        --entitlements Resources/Klip.entitlements "$DEST" 2>/tmp/klip_sign_err; then
    if [ "$SIGN_ID" != "-" ]; then
        echo "  ⚠ signing with '$SIGN_ID' failed; falling back to ad-hoc"
        SIGN_ID="-"
        $SUDO codesign --force --sign - --identifier com.proper.klip \
            --entitlements Resources/Klip.entitlements "$DEST"
    else
        cat /tmp/klip_sign_err; rm -f /tmp/klip_sign_err; exit 1
    fi
fi
rm -f /tmp/klip_sign_err
$SUDO codesign --verify --strict "$DEST" && echo "  ✓ valid signature in /Applications"
if [ "$SIGN_ID" = "-" ]; then
    echo "  (ad-hoc signature: macOS will re-ask for permissions after each reinstall)"
else
    echo "  (stable signature '$SIGN_ID': the microphone permission is remembered across updates)"
fi

# Local default language (UI + audio transcription). Only on a FRESH install (respects a later choice).
# Override with KLIP_DEFAULT_LANG=en ./install.sh
KLIP_LANG="${KLIP_DEFAULT_LANG:-es}"
defaults read com.proper.klip uiLanguage            >/dev/null 2>&1 || defaults write com.proper.klip uiLanguage            -string "$KLIP_LANG"
defaults read com.proper.klip transcriptionLanguage >/dev/null 2>&1 || defaults write com.proper.klip transcriptionLanguage -string "$KLIP_LANG"

echo "==> 4) Launching…"
open "$DEST"

echo ""
echo "✓ Installed at $DEST"
echo "  · Default shortcuts:  History ⌥⇧E · Voice ⌥⇧R · Annotate ⌥⇧D · OCR text ⌥⇧F · Upload ⌥⇧O · Record ⌥⇧V · Scroll ⌥⇧S"
echo "    (the exact ones are shown in the Klip menu and can be changed in Preferences › Shortcuts)"
echo "  · Launch at login: registered automatically the first time."
echo "    If Settings › General › Login Items asks for approval, enable it there."
echo "  · Auto-paste: enable it from the Klip menu → 'Enable auto-paste…'"
echo "    (grant Accessibility when the system asks)."
