#!/bin/bash
# Klip doctor — answers "why is Klip misbehaving?" without needing an expert.
#
# STRICTLY READ-ONLY. It never deletes, never writes a default, never calls tccutil or sudo.
# Everything below is a read: stat, codesign --verify, sqlite3 -readonly, sfltool dumpbtm, find.
# If you are tempted to add a fix here, put it in install.sh instead — a diagnostic the user cannot
# trust to be harmless is a diagnostic they won't run.
#
# --brief prints only what still needs the user (install.sh ends with this, so the install verifies
# itself instead of reciting advice). Exit code: 0 = nothing wrong, 1 = something needs attention.
#
# Deliberately NOT `set -e`: every check has to run even when an earlier one fails. A doctor that
# stops at the first symptom is the bug it is here to replace.
set -uo pipefail

BRIEF=0
case "${1:-}" in
    --brief)      BRIEF=1 ;;
    -h|--help)    echo "Usage: ./doctor.sh [--brief]"; exit 0 ;;
    "")           ;;
    *)            echo "unknown option: $1" >&2; exit 2 ;;
esac

cd "$(dirname "$0")" 2>/dev/null || true

APP="${KLIP_APP_PATH:-/Applications/Klip.app}"
BIN="$APP/Contents/MacOS/Klip"
BUNDLE_ID="io.github.tamibot.klip"
OLD_ID="com.proper.klip"          # pre-rename; its leftovers are reported, never touched
DATA="$HOME/Library/Application Support/Klip"
MIN_MACOS=14                      # same requirement build.sh's preflight enforces
# Overridable like uninstall.sh's targets, so the "cannot read the permission database" path can be
# rehearsed by pointing these somewhere unreadable instead of waiting to meet a Mac without it.
TCC_USER="${KLIP_TCC_USER_DB:-$HOME/Library/Application Support/com.apple.TCC/TCC.db}"
TCC_SYS="${KLIP_TCC_SYS_DB:-/Library/Application Support/com.apple.TCC/TCC.db}"

TODO=()                           # what still needs the user, each with the exact place to do it
# Findings print twice on purpose: once in the section that found them (so the full report has
# context and no empty headings), once as the action list at the end (so nothing scrolls past).
todo() { TODO+=("$1"$'\n'"      → $2"); [ "$BRIEF" = 1 ] || printf '  ✗ %s\n' "$1"; }
say()  { [ "$BRIEF" = 1 ] || printf '%s\n' "$*"; }
head_() { say ""; say "$*"; }

# ---------------------------------------------------------------- environment
head_ "Environment"
OS="$(sw_vers -productVersion 2>/dev/null || echo '?')"
case "${OS%%.*}" in
    ''|*[!0-9]*) say "  macOS $OS — could not read the version" ;;
    *) if [ "${OS%%.*}" -lt "$MIN_MACOS" ]; then
           todo "macOS $OS is older than the macOS $MIN_MACOS Klip needs." \
                "System Settings › General › Software Update"
       else say "  macOS $OS ✓"; fi ;;
esac

# The toolchain only matters for rebuilding. Broken is a finding, not a reason to stop — doctor.sh
# has to survive exactly the state build.sh refuses to run in.
if [ -z "${DEVELOPER_DIR:-}" ] && ! /usr/bin/xcrun --find swift >/dev/null 2>&1 \
   && [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
case "$(swift --version 2>&1 || true)" in
    *"Swift version"*) say "  Swift toolchain ✓ (only needed to rebuild)" ;;
    *) todo "No usable Swift toolchain — ./build.sh and ./install.sh cannot run." \
            "run  xcode-select --install${DEVELOPER_DIR:+   (DEVELOPER_DIR is '$DEVELOPER_DIR')}" ;;
esac

# ---------------------------------------------------------------- the install
head_ "Install"
INSTALLED=0
if [ -d "$APP" ]; then
    INSTALLED=1
    VER="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
    say "  $APP  (version $VER)"

    if codesign --verify --strict "$APP" 2>/dev/null; then
        # An ad-hoc signature is valid but unstable: it changes every install, so macOS treats each
        # reinstall as a new app and forgets every permission. Worth naming, not worth alarming.
        if codesign -dv "$APP" 2>&1 | grep -q 'Signature=adhoc'; then
            say "  signature: valid, but ad-hoc — macOS re-asks for permissions after every reinstall"
        else
            say "  signature: valid and stable ✓"
        fi
    else
        todo "The signature of $APP does not verify — macOS may kill it at launch as damaged." \
             "./install.sh   (re-signs in place)"
    fi

    if pgrep -f "^$BIN" >/dev/null 2>&1; then
        say "  running ✓"
    else
        todo "Klip is not running." "open $APP   (if it dies immediately, see the crash section below)"
    fi
else
    todo "Klip is not installed at $APP." "./install.sh"
fi

# ---------------------------------------------------------------- permissions
# What a plain shell can honestly know: TCC's own record, if this shell happens to be allowed to read
# the databases (Full Disk Access). It cannot ASK the system on Klip's behalf — a runtime probe from
# here would answer for the terminal, not for Klip. So: read the record, or say unknown. Never guess.
head_ "Permissions (as recorded by macOS)"
perm_state() {   # $1 service, $2 the database that owns it → granted | denied | never | unknown
    local svc="$1" own="$2" db v
    for db in "$TCC_SYS" "$TCC_USER"; do
        [ -r "$db" ] || continue
        v="$(sqlite3 -readonly "$db" \
             "select auth_value from access where service='$svc' and client='$BUNDLE_ID' \
              order by auth_value desc limit 1;" 2>/dev/null)"
        case "$v" in
            ''|NULL) ;;
            0)  echo denied;  return ;;
            *)  [ "$v" -ge 2 ] && { echo granted; return; }; echo denied; return ;;
        esac
    done
    [ -r "$own" ] && echo never || echo unknown
}

check_perm() {   # $1 label, $2 service, $3 owning db, $4 System Settings pane
    local state; state="$(perm_state "$2" "$3")"
    case "$state" in
        granted) say "  $1: granted ✓" ;;
        denied)  todo "$1: denied." "System Settings › Privacy & Security › $4 → turn Klip on" ;;
        never)   todo "$1: never granted." "System Settings › Privacy & Security › $4 → add/turn Klip on" ;;
        unknown) todo "$1: unknown — this Mac does not let a script read the permission database." \
                      "check in the app: Klip menu › Welcome / permissions" ;;
    esac
}
check_perm "Microphone"      kTCCServiceMicrophone    "$TCC_USER" "Microphone"
check_perm "Screen Recording" kTCCServiceScreenCapture "$TCC_SYS" \
           "Screen Recording ('Screen & System Audio Recording' on macOS 15+)"
check_perm "Accessibility"   kTCCServiceAccessibility "$TCC_SYS" "Accessibility"

# ---------------------------------------------------------------- stray bundles
# The documented cause of "Klip is damaged": a leftover build carrying the same bundle id but a
# different ad-hoc signature. Opening one runs a second Klip that holds none of the permissions.
head_ "Stray bundles"
STRAY="$(find "$HOME" "$PWD" -maxdepth 5 -name 'Klip*.app' -prune -print 2>/dev/null | sort -u)"
if [ -n "$STRAY" ]; then
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        todo "Stray bundle: $s" "delete it — only $APP should exist (./install.sh removes build leftovers)"
    done <<< "$STRAY"
else
    say "  none outside /Applications ✓"
fi

# ---------------------------------------------------------------- old bundle id
head_ "Leftovers from the previous bundle id ($OLD_ID)"
BTM="$(sfltool dumpbtm 2>/dev/null)"
if [ -z "$BTM" ]; then
    say "  login items: could not be listed on this Mac — check System Settings › General › Login Items"
else
    # Records print Disposition before Bundle Identifier, so keep the last one seen.
    DISP="$(awk -v id="$OLD_ID" '
        /Disposition:/ { d=$0; sub(/^ *Disposition: *\[/,"",d); sub(/\].*/,"",d) }
        $0 ~ ("Bundle Identifier: " id "$") { print d; exit }' <<< "$BTM")"
    if [ -n "$DISP" ]; then
        # NEVER removed here: the record belongs to another bundle id. Only the user may touch it.
        todo "A login item is still registered under the old id $OLD_ID ($DISP)." \
             "System Settings › General › Login Items & Extensions → remove the duplicate 'Klip' by hand"
    else
        say "  no stale login item ✓"
    fi
fi
if defaults read "$OLD_ID" >/dev/null 2>&1; then
    say "  preferences under $OLD_ID still exist (harmless; ./uninstall.sh clears them)"
fi

# ---------------------------------------------------------------- data
head_ "Data"
if [ -d "$DATA" ]; then
    say "  $DATA — $(du -sh "$DATA" 2>/dev/null | cut -f1), $(find "$DATA" -type f 2>/dev/null | wc -l | tr -d ' ') files"
else
    say "  no data folder yet (created on first use)"
fi

# ---------------------------------------------------------------- freshness
head_ "Is the installed app built from this source?"
if [ "$INSTALLED" = 0 ]; then
    say "  nothing installed to compare"
elif [ ! -d Sources ]; then
    say "  not run from the repo — skipped"
else
    STALE=""
    NEWER="$(find Sources -name '*.swift' -newer "$BIN" -print -quit 2>/dev/null)"
    [ -n "$NEWER" ] && STALE="source files are newer than the installed binary (e.g. $NEWER)"
    CT="$(git log -1 --format=%ct -- Sources/ 2>/dev/null)"
    BT="$(stat -f %m "$BIN" 2>/dev/null)"
    if [ -n "$CT" ] && [ -n "$BT" ] && [ "$CT" -gt "$BT" ]; then
        STALE="the last commit touching Sources/ is newer than the installed binary"
    fi
    if [ -n "$STALE" ]; then
        todo "The installed app is out of date: $STALE." "./install.sh"
    else
        say "  installed binary is at least as new as Sources/ ✓"
    fi
fi

# ---------------------------------------------------------------- crashes
head_ "Recent crashes (last 14 days)"
CRASHES="$(find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports \
                -maxdepth 1 -name 'Klip-*.ips' -mtime -14 2>/dev/null | sort -r | head -5)"
if [ -z "$CRASHES" ]; then
    say "  none ✓"
else
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        # The termination object is the one line that explains the crash, buried in a JSON file
        # nobody scrolls: {"namespace":"CODESIGNING","indicator":"Launch Constraint Violation"}.
        T="$(sed -n 's/.*"termination"[^{]*{\([^}]*\)}.*/\1/p' "$c" | head -1)"
        NS="$(sed -n 's/.*"namespace":"\([^"]*\)".*/\1/p' <<< "$T")"
        IND="$(sed -n 's/.*"indicator":"\([^"]*\)".*/\1/p' <<< "$T")"
        # Only crashes NEWER than the installed binary say anything about the install you have now;
        # older ones are history from a build that has since been replaced. Reporting those as
        # problems is how a diagnostic teaches people to ignore it.
        if [ "$INSTALLED" = 1 ] && [ ! "$c" -nt "$BIN" ]; then
            say "  $(basename "$c"): ${NS:-?} — ${IND:-no reason recorded}  (older than this build, historical)"
            continue
        fi
        say "  $(basename "$c"): ${NS:-?} — ${IND:-no reason recorded}"
        case "$NS" in
            CODESIGNING) todo "macOS killed Klip over its signature: $IND." \
                              "./install.sh — re-signing in /Applications is what fixes this" ;;
            SIGNAL)      todo "Klip crashed on its own: $IND (this build, $(basename "$c"))." \
                              "a bug in the app, not in the install — report it with that file at https://github.com/tamibot/klip/issues" ;;
        esac
    done <<< "$CRASHES"
    say "  (full reports: open ~/Library/Logs/DiagnosticReports)"
fi

# ---------------------------------------------------------------- verdict
if [ ${#TODO[@]} -eq 0 ]; then
    say ""
    echo "Klip is healthy: installed, signed, running, and all three permissions are granted."
    exit 0
fi
say ""
if [ "$BRIEF" = 1 ]; then echo "Still needs you:"; else echo "Needs your attention (${#TODO[@]}):"; fi
printf '  · %s\n' "${TODO[@]}"
[ "$BRIEF" = 1 ] && echo "  Full diagnosis: ./doctor.sh"
exit 1
