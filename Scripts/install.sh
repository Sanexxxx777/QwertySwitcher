#!/bin/bash
# Qwerty Switcher — update the installed copy WITHOUT resetting TCC permissions.
#
# WHY THIS SCRIPT EXISTS (root cause, 04.08.2026 — do not "simplify" it back):
#
#   1. `rm -rf "/Applications/Qwerty Switcher.app"` before copying is what kept
#      wiping Accessibility / Input Monitoring. macOS reads the disappearance of
#      the bundle directory as "app uninstalled" and drops its TCC.db row (that
#      row is keyed by bundle id + csreq, not by CDHash). Proven by A/B on this
#      Mac: recreated bundle → `perms accessibility=false`, same bundle updated
#      in place with a different CDHash → `perms accessibility=true`.
#      => the destination directory must survive the update. Never delete it.
#
#   2. `ditto src dst` over an existing bundle MERGES — it never removes files
#      the new release dropped. One orphan inside Contents/ breaks the sealed
#      resources, the app stops satisfying its own Designated Requirement, tccd
#      can no longer match the stored csreq, and permissions are asked again.
#      => the copy must prune, hence `rsync -a --delete`.
#
#   3. The stored csreq names the SIGNING IDENTITY (`identifier "..." and
#      certificate leaf = H"..."`). A build signed with a different identity —
#      most often the ad-hoc fallback build.sh silently drops to when
#      "SashaSwitcher Developer" is missing from the Keychain — no longer
#      matches that csreq, so the grants are gone even though the directory and
#      its inode survived. `codesign --verify` cannot catch this: it checks the
#      bundle against the DR embedded in its own signature, so an ad-hoc build
#      happily "satisfies its Designated Requirement".
#      => the identity of the source must be compared with the installed copy
#         BEFORE the sync, hence the gate in step [2/5].
#
#   `rsync -a --delete` fixes #1 and #2 at once: same directory (same inode), no
#   orphans. The `codesign --verify` gate below is what proves #2 held; the
#   identity gate is what proves #3 held.
#
# Usage:
#   ./Scripts/install.sh                    # build/Qwerty Switcher.app -> /Applications
#   ./Scripts/install.sh --no-launch        # install but don't open the app
#   ./Scripts/install.sh --source <app>     # install a specific .app bundle
#   ./Scripts/install.sh --dest <dir>       # install into another folder (tests)
#   ./Scripts/install.sh --allow-identity-change
#                                           # install a differently signed build
#                                           # anyway (permissions WILL reset)
#
# Idempotent: running it twice in a row is a no-op for the destination inode and
# leaves the signature valid.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="Qwerty Switcher"
BINARY_NAME="QwertySwitcher"
EXPECTED_BUNDLE_ID="tech.sasha.qwertyswitch"

SOURCE_APP="$PROJECT_DIR/build/$PRODUCT_NAME.app"
DEST_DIR="${QSW_INSTALL_DIR:-/Applications}"
LAUNCH_AFTER=true
ALLOW_IDENTITY_CHANGE=false
# Set to false as soon as anything makes the stored TCC csreq unmatchable, so
# the final report never claims grants were kept when they were not.
IDENTITY_KEPT=true

while [ $# -gt 0 ]; do
    case "$1" in
        --no-launch)             LAUNCH_AFTER=false; shift ;;
        --source)                SOURCE_APP="${2:-}"; shift 2 ;;
        --dest)                  DEST_DIR="${2:-}"; shift 2 ;;
        --allow-identity-change) ALLOW_IDENTITY_CHANGE=true; shift ;;
        -h|--help)               /usr/bin/sed -n '2,45p' "$0"; exit 0 ;;
        *)                       echo "✗ Unknown argument: $1"; exit 2 ;;
    esac
done

DEST_APP="$DEST_DIR/$PRODUCT_NAME.app"

bundle_id_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# The bundle's Designated Requirement, reduced to what tccd matches on.
#   "unsigned" — no signature at all.
#   "adhoc"    — cdhash-based DR (ad-hoc signature). It changes on every
#                rebuild, so grants can never survive regardless of the copy.
#   otherwise  — the identity-bearing DR string, compared verbatim.
signing_identity_of() {
    local dr
    dr="$(codesign -d -r- "$1" 2>/dev/null | sed -n 's/^.*designated => //p' | head -1)"
    if [ -z "$dr" ]; then
        echo "unsigned"
    elif printf '%s' "$dr" | grep -q 'cdhash'; then
        echo "adhoc"
    else
        echo "$dr"
    fi
}

echo "=== Installing $PRODUCT_NAME ==="
echo "  source: $SOURCE_APP"
echo "  target: $DEST_APP"

# ── 1. Preflight the source: never push a broken bundle onto a working one ──
echo "[1/5] Checking source bundle..."
if [ ! -d "$SOURCE_APP" ]; then
    echo "✗ Source bundle not found: $SOURCE_APP"
    echo "  Build it first:  ./Scripts/build.sh"
    exit 3
fi
if [ ! -x "$SOURCE_APP/Contents/MacOS/$BINARY_NAME" ]; then
    echo "✗ Source bundle has no executable at Contents/MacOS/$BINARY_NAME"
    exit 3
fi

SOURCE_ID="$(bundle_id_of "$SOURCE_APP")"
if [ "$SOURCE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "✗ Source bundle identifier is '$SOURCE_ID', expected '$EXPECTED_BUNDLE_ID'"
    exit 3
fi

if ! codesign --verify --deep --strict "$SOURCE_APP" 2>/dev/null; then
    echo "✗ Source bundle fails its own signature check — refusing to install it."
    echo "  Rebuild:  ./Scripts/build.sh"
    exit 4
fi
echo "  ✓ signed, identifier $SOURCE_ID"

# ── 2. Guard the destination and remember its identity ──
echo "[2/5] Checking destination..."
INODE_BEFORE=""
if [ -e "$DEST_APP" ]; then
    if [ ! -d "$DEST_APP" ]; then
        echo "✗ $DEST_APP exists but is not a bundle directory — refusing to touch it."
        exit 5
    fi
    DEST_ID="$(bundle_id_of "$DEST_APP")"
    if [ -n "$DEST_ID" ] && [ "$DEST_ID" != "$EXPECTED_BUNDLE_ID" ]; then
        echo "✗ $DEST_APP belongs to '$DEST_ID' — refusing to overwrite a different app."
        exit 5
    fi
    INODE_BEFORE="$(stat -f %i "$DEST_APP")"
    echo "  ✓ existing install found (inode $INODE_BEFORE) — it will be updated in place"

    # Identity gate (root cause #3). Runs BEFORE the app is quit and before any
    # file moves, so a refusal leaves the working install completely untouched.
    DEST_IDENTITY="$(signing_identity_of "$DEST_APP")"
    SOURCE_IDENTITY="$(signing_identity_of "$SOURCE_APP")"
    if [ "$DEST_IDENTITY" != "$SOURCE_IDENTITY" ]; then
        IDENTITY_KEPT=false
        echo "  ✗ the new build is signed with a DIFFERENT identity than the installed copy:"
        echo "      installed: $DEST_IDENTITY"
        echo "      new build: $SOURCE_IDENTITY"
        echo "    tccd matches the stored csreq, which names the identity — this update"
        echo "    resets Accessibility / Input Monitoring no matter how the files are copied."
        if [ "$ALLOW_IDENTITY_CHANGE" != true ]; then
            echo "    Fix the signing identity and rebuild:"
            echo "      ./Scripts/setup-signing.sh && ./Scripts/build.sh"
            echo "    Or, if the change is intentional (e.g. moving to Developer ID), re-run:"
            echo "      ./Scripts/install.sh --allow-identity-change"
            exit 7
        fi
        echo "    ⚠ --allow-identity-change given — continuing, permissions will be re-requested."
    elif [ "$SOURCE_IDENTITY" = "adhoc" ] || [ "$SOURCE_IDENTITY" = "unsigned" ]; then
        IDENTITY_KEPT=false
        echo "  ⚠ both copies are ad-hoc signed: the DR is a cdhash and changes on every"
        echo "    rebuild, so macOS will ask for permissions again after this update."
        echo "    Run ./Scripts/setup-signing.sh once for a stable identity."
    else
        echo "  ✓ same signing identity as the installed copy — the stored csreq still matches"
    fi
else
    echo "  ✓ no existing install — fresh copy"
fi

# ── 3. Quit only the instance running from the destination ──
# The running process holds the old executable inode; the new code would not be
# picked up otherwise. Quit BEFORE swapping files, never after.
echo "[3/5] Stopping the running copy (if any)..."
running_pids() {
    # Own pid / parent excluded so the script never matches itself.
    pgrep -f "$DEST_APP/Contents/MacOS/$BINARY_NAME" 2>/dev/null \
        | while read -r pid; do
            [ "$pid" = "$$" ] && continue
            [ "$pid" = "$PPID" ] && continue
            echo "$pid"
        done
}

PIDS="$(running_pids || true)"
if [ -n "$PIDS" ]; then
    echo "  running: $(echo "$PIDS" | tr '\n' ' ')"
    osascript -e "tell application id \"$EXPECTED_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    WAITED=0
    while [ -n "$(running_pids || true)" ] && [ "$WAITED" -lt 10 ]; do
        sleep 1
        WAITED=$((WAITED + 1))
    done
    LEFT="$(running_pids || true)"
    if [ -n "$LEFT" ]; then
        echo "  did not quit in ${WAITED}s — sending TERM"
        echo "$LEFT" | xargs kill -TERM 2>/dev/null || true
        sleep 2
    fi
    LEFT="$(running_pids || true)"
    if [ -n "$LEFT" ]; then
        echo "  still alive — sending KILL"
        echo "$LEFT" | xargs kill -KILL 2>/dev/null || true
        sleep 1
    fi
    echo "  ✓ stopped"
else
    echo "  ✓ not running"
fi

# ── 4. Update the bundle IN PLACE ──
# Trailing slashes on BOTH paths are load-bearing: without them rsync nests the
# bundle inside the bundle. --delete prunes files dropped by the new release.
# There is deliberately no `rm -rf` of the destination anywhere in this script.
echo "[4/5] Syncing bundle contents..."
mkdir -p "$DEST_DIR"
# A partial rsync leaves the destination half-updated: new _CodeSignature over
# old payload, i.e. exactly the broken-seal state this script exists to avoid.
# `set -e` alone would abort here silently, before the step [5/5] gate could
# report it — so the failure is reported explicitly instead.
# --checksum (field e2e 10.09.2026): rsync's default quick-check skips a file
# whose size AND mtime already match — a re-signed executable of the same
# size, signed within the same second the copy was taken, was left as the OLD
# binary while its Info.plist was replaced, so the installed bundle failed
# the [5/5] seal check ("invalid Info.plist") and the updater rolled back.
# Content comparison costs a checksum over ~14 MB — nothing next to the
# permission reset a broken seal would cause.
if ! rsync -a --checksum --delete "$SOURCE_APP/" "$DEST_APP/"; then
    echo "✗ Sync failed — $DEST_APP is now HALF-UPDATED and its seal is broken."
    echo "  Do not launch it: macOS will ask for Accessibility / Input Monitoring"
    echo "  again while the bundle stays in this state."
    echo "  Fix the cause (locked file, no disk space, permissions) and re-run:"
    echo "    ./Scripts/install.sh"
    exit 8
fi
xattr -rd com.apple.quarantine "$DEST_APP" 2>/dev/null || true
echo "  ✓ contents synced"

# ── 5. Blocking gate — an install that fails this WILL lose permissions ──
echo "[5/5] Verifying installed signature..."
if ! codesign --verify --deep --strict --verbose=2 "$DEST_APP"; then
    echo "✗ Installed bundle does not satisfy its Designated Requirement."
    echo "  macOS will ask for Accessibility / Input Monitoring again in this state."
    exit 6
fi

INSTALLED_ID="$(bundle_id_of "$DEST_APP")"
if [ "$INSTALLED_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "✗ Installed bundle identifier is '$INSTALLED_ID', expected '$EXPECTED_BUNDLE_ID'"
    exit 6
fi

INODE_AFTER="$(stat -f %i "$DEST_APP")"
if [ -n "$INODE_BEFORE" ]; then
    if [ "$INODE_BEFORE" = "$INODE_AFTER" ] && [ "$IDENTITY_KEPT" = true ]; then
        echo "  ✓ bundle updated in place (inode $INODE_AFTER unchanged) — TCC grants kept"
    elif [ "$INODE_BEFORE" = "$INODE_AFTER" ]; then
        echo "  ⚠ bundle updated in place (inode $INODE_AFTER unchanged), but the signing"
        echo "    identity is not the one the stored csreq was granted to —"
        echo "    macOS WILL ask for Accessibility / Input Monitoring again."
    else
        echo "  ⚠ bundle directory was recreated (inode $INODE_BEFORE → $INODE_AFTER)."
        echo "    macOS may have dropped the TCC grants — re-check System Settings."
    fi
else
    echo "  ✓ installed (inode $INODE_AFTER)"
fi

echo ""
echo "✓ $DEST_APP"
echo "  version:    $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "  identifier: $INSTALLED_ID"

if [ "$LAUNCH_AFTER" = true ]; then
    echo "  launching..."
    open "$DEST_APP"
else
    echo "  not launched (--no-launch)"
fi
