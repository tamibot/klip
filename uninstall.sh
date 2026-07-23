#!/bin/bash
# Undoes install.sh: the app in /Applications, the launch-at-login registration and the self-signed
# code-signing certificate. Your clipboard history is only removed if you explicitly say so.
# Nothing is deleted without either an interactive "y" or an explicit flag.
set -euo pipefail

# What to remove. Overridable so the destructive path can be rehearsed against a fake bundle and a
# fake data folder in /tmp instead of the real install.
APP="${KLIP_APP_PATH:-/Applications/Klip.app}"
DATA="${KLIP_DATA_DIR:-$HOME/Library/Application Support/Klip}"
BUNDLE_ID="${KLIP_BUNDLE_ID:-io.github.tamibot.klip}"
IDENTITY="${KLIP_KEYCHAIN_IDENTITY:-Klip Code Signing}"
MODELS="$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml"

usage() {
    cat <<EOF
Usage: ./uninstall.sh [--dry-run] [--yes] [--keep-data]

  --dry-run    print the plan and change nothing
  --yes, -y    no questions: remove everything, including the data folder
  --keep-data  never touch $DATA
  -h, --help   this text

With no flags it asks before anything is removed, and defaults to NO on the data question.
Env overrides (targets): KLIP_APP_PATH, KLIP_DATA_DIR, KLIP_BUNDLE_ID, KLIP_KEYCHAIN_IDENTITY.
EOF
}

DRY=0; ASSUME_YES=0; KEEP_DATA=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        --keep-data) KEEP_DATA=1 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

REMOVED=()
note() { REMOVED+=("$1"); }

# Human-readable size, or "" when the path isn't there.
size_of()  { if [ -e "$1" ]; then du -sh "$1" 2>/dev/null | cut -f1; fi; }
count_in() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

data_inventory() {
    echo "      images: $(count_in "$DATA/images") · voice notes: $(count_in "$DATA/audio") ·" \
         "recordings: $(count_in "$DATA/videos") · plus the history metadata — $(size_of "$DATA") in total"
}

# ---------------------------------------------------------------- plan
echo "Klip uninstaller"
echo ""
echo "  Will remove:"
if [ -e "$APP" ]; then
    echo "    · $APP  (quitting it first if it is running)"
    echo "    · the launch-at-login registration (it dies with the bundle; see the manual step below)"
else
    echo "    · $APP  — not installed, skipping"
fi
echo "    · the '$IDENTITY' certificate from your login keychain"
echo ""
if [ "$KEEP_DATA" = 1 ]; then
    echo "  Will KEEP (--keep-data):"
    echo "    · $DATA"
    echo "    · preferences ($BUNDLE_ID) and the credential encryption key in the keychain"
elif [ -d "$DATA" ]; then
    if [ "$ASSUME_YES" = 1 ]; then echo "  Will ALSO remove (--yes):"; else echo "  Will ask about:"; fi
    echo "    · $DATA"
    data_inventory
    echo "    · preferences ($BUNDLE_ID), caches, and the credential encryption key in the keychain"
    echo "      ⚠ that key is the ONLY thing that can decrypt saved credentials, and it lives in the"
    echo "        keychain — not in the folder above. Copying the folder does not back it up. Delete"
    echo "        the key and every saved credential becomes unreadable, restore or no restore."
else
    echo "  No data folder at $DATA."
fi
echo ""

if [ "$DRY" = 1 ]; then
    echo "Dry run — nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------- consent
confirm() {   # default is always NO, and a non-interactive shell never counts as a yes
    if [ "$ASSUME_YES" = 1 ]; then return 0; fi
    if [ ! -t 0 ]; then return 1; fi
    local answer=""
    read -r -p "$1 [y/N] " answer || true
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

if ! confirm "Remove Klip?"; then
    if [ "$ASSUME_YES" = 0 ] && [ ! -t 0 ]; then
        echo "Not a terminal and --yes was not given: nothing was removed." >&2
        echo "Re-run with --yes, or with --dry-run to just see the plan." >&2
        exit 1
    fi
    echo "Cancelled — nothing was removed."
    exit 0
fi

DELETE_DATA=0
if [ "$KEEP_DATA" = 0 ] && [ -d "$DATA" ]; then
    if [ "$ASSUME_YES" = 0 ]; then
        echo ""
        echo "  This deletes your clipboard history permanently — it is not in the Trash afterwards:"
        data_inventory
    fi
    if confirm "Delete that too?"; then DELETE_DATA=1; fi
fi

# ---------------------------------------------------------------- act
echo ""

# Match on the executable path so only the instance we are removing is asked to quit.
if pgrep -f "^$APP/Contents/MacOS/" >/dev/null 2>&1; then
    pkill -f "^$APP/Contents/MacOS/" 2>/dev/null || true
    perl -e 'select(undef,undef,undef,0.4)'
    note "quit the running Klip"
fi

if [ -e "$APP" ]; then
    SUDO=""; [ -w "$(dirname "$APP")" ] || SUDO="sudo"
    $SUDO rm -rf "$APP"
    note "$APP"
    # ponytail: no scripted removal of the login item. Klip registers with SMAppService.mainApp
    # (LoginItem.swift), which has no CLI to unregister from outside the app; the record is pruned
    # once the bundle is gone. Legacy `osascript … delete login item` can't see SMAppService items
    # and would only cost the user an Automation prompt. It is printed as a manual step instead.
    note "launch-at-login registration (dropped with the bundle — verify in Login Items)"
fi

# -t also drops the trust setting install.sh added with add-trusted-cert.
# macOS may ask for your keychain password here.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    if security delete-identity -c "$IDENTITY" -t >/dev/null 2>&1; then
        note "'$IDENTITY' certificate + key from the login keychain"
        echo "  · Removed the '$IDENTITY' certificate. A future ./install.sh creates a NEW one, so"
        echo "    macOS will treat Klip as a different app and ask again for microphone, screen"
        echo "    recording and accessibility permission."
    else
        echo "  ⚠ could not remove the '$IDENTITY' certificate — delete it in Keychain Access › login." >&2
    fi
fi

if [ "$DELETE_DATA" = 1 ]; then
    rm -rf "$DATA"
    note "$DATA (history, images, voice notes, recordings)"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && note "preferences ($BUNDLE_ID)" || true
    security delete-generic-password -a "$BUNDLE_ID.credentialKey" >/dev/null 2>&1 \
        && note "credential encryption key from the keychain" || true
    # Klip's bundle id changed; an install that predates the rename left its preferences and its
    # encryption key under the old one. A "remove everything" that leaves those behind is a lie.
    for old in com.proper.klip com.proper.pastaclip; do
        defaults delete "$old" >/dev/null 2>&1 && note "preferences ($old, pre-rename)" || true
    done
    security delete-generic-password -a "com.proper.klip.credentialKey" >/dev/null 2>&1 \
        && note "credential encryption key from the keychain (pre-rename)" || true
    for leftover in "$HOME/Library/Caches/$BUNDLE_ID" \
                    "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
                    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"; do
        [ -e "$leftover" ] && rm -rf "$leftover" && note "$leftover" || true
    done
elif [ -d "$DATA" ]; then
    echo "  · Kept $DATA — a reinstall picks the history back up."
fi

# ---------------------------------------------------------------- report
echo ""
if [ ${#REMOVED[@]} -eq 0 ]; then
    echo "Nothing to remove — Klip was not installed here."
else
    echo "Removed:"
    printf '  · %s\n' "${REMOVED[@]}"
fi

echo ""
echo "You have to finish by hand (no script may touch these):"
echo "  · System Settings › Privacy & Security › Microphone            → remove Klip"
echo "  · System Settings › Privacy & Security › Screen Recording      → remove Klip"
echo "      (named 'Screen & System Audio Recording' on macOS 15 and newer)"
echo "  · System Settings › Privacy & Security › Accessibility         → remove Klip"
echo "  · System Settings › General › Login Items & Extensions         → remove Klip if still listed"
if [ -d "$MODELS" ]; then
    echo "  · $MODELS ($(size_of "$MODELS"))"
    echo "      Speech-to-text models. Left in place on purpose: that folder is the shared WhisperKit"
    echo "      cache, so other apps may be using it. Delete it yourself if nothing else needs it."
fi
