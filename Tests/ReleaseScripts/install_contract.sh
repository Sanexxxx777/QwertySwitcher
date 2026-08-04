#!/bin/bash
# Contract for Scripts/install.sh — the TCC-safe installer.
#
# Two halves:
#   (1) static — the properties that made permissions survive at all
#       (no rm -rf of the destination, --delete prunes orphans, signature gate
#       after the sync, app stopped before the files move);
#   (2) functional — actually installs a throwaway signed bundle into a temp
#       directory twice and checks idempotency, in-place update and the refusal
#       paths. Nothing under /Applications is touched.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SCRIPT="$PROJECT_DIR/Scripts/install.sh"

fail() { echo "FAIL: $1"; exit 1; }

# ── 1. Static contract ──────────────────────────────────────────────────────
[ -x "$INSTALL_SCRIPT" ] || fail "Scripts/install.sh is missing or not executable"
bash -n "$INSTALL_SCRIPT" || fail "Scripts/install.sh does not parse"

# Comments explain the root cause and legitimately name the banned commands —
# only executable lines are checked.
CODE_ONLY="$(grep -v '^[[:space:]]*#' "$INSTALL_SCRIPT")"

# The whole point: deleting the bundle directory is what reset TCC.
if printf '%s\n' "$CODE_ONLY" | grep -q 'rm -rf'; then
    fail "install.sh removes files — deleting the installed bundle is exactly what resets TCC grants"
fi
# ditto merges instead of pruning, which breaks the sealed resources.
if printf '%s\n' "$CODE_ONLY" | grep -qw 'ditto'; then
    fail "install.sh uses ditto — it merges and leaves orphans that invalidate the signature"
fi

grep -q 'rsync -a --delete' "$INSTALL_SCRIPT" \
    || fail "install.sh does not update the bundle in place with a pruning rsync"
grep -q 'rsync -a --delete "\$SOURCE_APP/" "\$DEST_APP/"' "$INSTALL_SCRIPT" \
    || fail "rsync source/destination are missing the trailing slashes (bundle would nest inside itself)"

quit_line=$(grep -n 'osascript -e' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
sync_line=$(grep -n 'rsync -a --delete "\$SOURCE_APP/"' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
gate_line=$(grep -n 'codesign --verify --deep --strict --verbose=2 "\$DEST_APP"' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
src_gate_line=$(grep -n 'codesign --verify --deep --strict "\$SOURCE_APP"' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)

[ -n "$quit_line" ]     || fail "install.sh never stops the running copy"
[ -n "$sync_line" ]     || fail "install.sh has no bundle sync step"
[ -n "$gate_line" ]     || fail "install.sh does not verify the installed signature"
[ -n "$src_gate_line" ] || fail "install.sh does not verify the source bundle before installing it"

[ "$src_gate_line" -lt "$sync_line" ] \
    || fail "the source must be signature-checked before it overwrites a working install"
[ "$quit_line" -lt "$sync_line" ] \
    || fail "the running app must be quit BEFORE its files are swapped, not after"
[ "$gate_line" -gt "$sync_line" ] \
    || fail "the installed signature must be verified after the sync, not before"

# The stored csreq names the signing identity, and `codesign --verify` cannot
# see a change of it (it checks the bundle against its own embedded DR). So the
# identity has to be compared explicitly, and before anything is touched.
identity_gate_line=$(grep -n 'DEST_IDENTITY" != "\$SOURCE_IDENTITY' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)
[ -n "$identity_gate_line" ] \
    || fail "install.sh does not compare the signing identity of the new build with the installed copy"
[ "$identity_gate_line" -lt "$quit_line" ] \
    || fail "the identity gate must run before the running app is quit, so a refusal changes nothing"

# A partial rsync leaves a half-updated bundle; `set -e` would abort before the
# step [5/5] gate could say so.
grep -q 'if ! rsync -a --delete' "$INSTALL_SCRIPT" \
    || fail "install.sh does not handle a failing rsync — a half-updated bundle would be left without a word"

# "TCC grants kept" is a claim about the csreq still matching, not about inodes.
grep -q 'IDENTITY_KEPT" = true \]; then' "$INSTALL_SCRIPT" \
    || fail "install.sh reports 'TCC grants kept' without checking that the signing identity survived"

grep -q 'stat -f %i' "$INSTALL_SCRIPT" \
    || fail "install.sh does not check that the bundle directory was reused (inode)"

# ── 2. Functional contract ──────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/src/Qwerty Switcher.app"
DEST_DIR="$WORK/dest"
mkdir -p "$SRC/Contents/MacOS" "$SRC/Contents/Resources" "$DEST_DIR"
# A real Mach-O executable: an ad-hoc signature lives inside the binary, so the
# fixture verifies the same way the shipped bundle does.
cp /bin/echo "$SRC/Contents/MacOS/QwertySwitcher"
cp "$PROJECT_DIR/Resources/Info.plist" "$SRC/Contents/Info.plist"
echo "v1" > "$SRC/Contents/Resources/payload.txt"
codesign --force --deep --sign - "$SRC" >/dev/null 2>&1 \
    || fail "could not ad-hoc sign the test fixture"

"$INSTALL_SCRIPT" --source "$SRC" --dest "$DEST_DIR" --no-launch >/dev/null 2>&1 \
    || fail "first install failed"
DEST="$DEST_DIR/Qwerty Switcher.app"
[ -d "$DEST" ] || fail "first install produced no bundle"
inode_first="$(stat -f %i "$DEST")"

# An orphan left by a previous release must break verification — this is the
# failure mode `ditto` used to leave behind.
echo "orphan" > "$DEST/Contents/Resources/RemovedInNewRelease.txt"
if codesign --verify --deep --strict "$DEST" >/dev/null 2>&1; then
    fail "an extra file inside the bundle did not invalidate the signature — fixture is not representative"
fi

# Different length AND a later mtime, so the check is about the installer and
# not about rsync's same-size/same-second quick-check heuristic.
sleep 1
echo "release-two-payload" > "$SRC/Contents/Resources/payload.txt"
codesign --force --deep --sign - "$SRC" >/dev/null 2>&1

"$INSTALL_SCRIPT" --source "$SRC" --dest "$DEST_DIR" --no-launch >/dev/null 2>&1 \
    || fail "second install failed (not idempotent)"
inode_second="$(stat -f %i "$DEST")"

[ "$inode_first" = "$inode_second" ] \
    || fail "the bundle directory was recreated ($inode_first -> $inode_second) — TCC grants would be dropped"
[ ! -e "$DEST/Contents/Resources/RemovedInNewRelease.txt" ] \
    || fail "an orphan from the previous release survived the update"
[ "$(cat "$DEST/Contents/Resources/payload.txt")" = "release-two-payload" ] \
    || fail "the new release contents were not installed"
codesign --verify --deep --strict "$DEST" >/dev/null 2>&1 \
    || fail "the installed bundle does not satisfy its Designated Requirement after the update"

# Third run with nothing changed stays green and keeps the same directory.
"$INSTALL_SCRIPT" --source "$SRC" --dest "$DEST_DIR" --no-launch >/dev/null 2>&1 \
    || fail "re-running the installer with no changes failed"
[ "$(stat -f %i "$DEST")" = "$inode_first" ] \
    || fail "a no-op install still recreated the bundle directory"

# Refusal path: a source whose seal is broken must never reach the destination.
echo "tampered" > "$SRC/Contents/Resources/UnsignedExtra.txt"
if "$INSTALL_SCRIPT" --source "$SRC" --dest "$DEST_DIR" --no-launch >/dev/null 2>&1; then
    fail "installer accepted a source bundle that fails its own signature check"
fi
[ "$(cat "$DEST/Contents/Resources/payload.txt")" = "release-two-payload" ] \
    || fail "a rejected install still modified the existing copy"

# Refusal path: never overwrite a different application.
FOREIGN="$WORK/foreign"
mkdir -p "$FOREIGN/Qwerty Switcher.app/Contents"
sed 's|tech.sasha.qwertyswitch|com.example.other|' "$PROJECT_DIR/Resources/Info.plist" \
    > "$FOREIGN/Qwerty Switcher.app/Contents/Info.plist"
rm -f "$SRC/Contents/Resources/UnsignedExtra.txt"
codesign --force --deep --sign - "$SRC" >/dev/null 2>&1
if "$INSTALL_SCRIPT" --source "$SRC" --dest "$FOREIGN" --no-launch >/dev/null 2>&1; then
    fail "installer overwrote a bundle belonging to a different identifier"
fi

# Refusal path: a build signed with a DIFFERENT identity keeps the directory and
# its inode, passes `codesign --verify`, and still drops the grants — the stored
# csreq names the identity. Needs a real second identity, so it is skipped (and
# said out loud) on machines that do not have the dev certificate.
DEV_IDENTITY="SashaSwitcher Developer"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$DEV_IDENTITY"; then
    payload_before="$(cat "$DEST/Contents/Resources/payload.txt")"
    dr_before="$(codesign -d -r- "$DEST" 2>/dev/null || true)"
    sleep 1
    echo "identity-change-payload" > "$SRC/Contents/Resources/payload.txt"
    codesign --force --deep --sign "$DEV_IDENTITY" "$SRC" >/dev/null 2>&1 \
        || fail "could not sign the fixture with '$DEV_IDENTITY'"

    if "$INSTALL_SCRIPT" --source "$SRC" --dest "$DEST_DIR" --no-launch >/dev/null 2>&1; then
        fail "installer accepted a build signed with another identity — the grants would reset silently"
    fi
    [ "$(cat "$DEST/Contents/Resources/payload.txt")" = "$payload_before" ] \
        || fail "a refused identity change still modified the installed copy"
    [ "$(codesign -d -r- "$DEST" 2>/dev/null || true)" = "$dr_before" ] \
        || fail "a refused identity change still altered the installed signature"

    # Deliberate identity changes stay possible, but must not be reported as safe.
    out="$("$INSTALL_SCRIPT" --source "$SRC" --dest "$DEST_DIR" --no-launch --allow-identity-change 2>&1)" \
        || fail "--allow-identity-change refused to install the differently signed build"
    if printf '%s' "$out" | grep -q 'TCC grants kept'; then
        fail "installer claimed 'TCC grants kept' while the signing identity changed"
    fi
    identity_case="enforced"
else
    identity_case="SKIPPED — no '$DEV_IDENTITY' identity on this machine"
fi

echo "PASS: install.sh updates the bundle in place, prunes orphans, gates on the signature and refuses bad input"
echo "      identity-change gate: $identity_case"
