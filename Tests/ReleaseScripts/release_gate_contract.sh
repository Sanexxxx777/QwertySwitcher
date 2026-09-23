#!/bin/bash
# Contract: release.sh refuses to package an untested or (by default) dirty
# tree, and make-dmg.sh stamps the bundle with its source commit before it
# is signed. Plan 009 — see plans/009-release-gate-and-port-parity.md.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE_SCRIPT="$PROJECT_DIR/Scripts/release.sh"
MAKE_DMG_SCRIPT="$PROJECT_DIR/Scripts/make-dmg.sh"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$RELEASE_SCRIPT" ]   || fail "Scripts/release.sh is missing"
[ -f "$MAKE_DMG_SCRIPT" ]  || fail "Scripts/make-dmg.sh is missing"
bash -n "$RELEASE_SCRIPT"  || fail "Scripts/release.sh does not parse"
bash -n "$MAKE_DMG_SCRIPT" || fail "Scripts/make-dmg.sh does not parse"

# ── release.sh: --allow-dirty is recognized, and a dirty tree is refused
#    (exit 4) unless it's passed ──
RELEASE_CODE_ONLY="$(grep -v '^[[:space:]]*#' "$RELEASE_SCRIPT")"
# Here-strings, not a `... | grep -q` pipe: grep -q exits the instant it
# finds a match, and under pipefail a large enough upstream writer can get
# SIGPIPE'd before it finishes — turning a real PASS into a spurious FAIL.
grep -q 'arg" = "--allow-dirty"' <<< "$RELEASE_CODE_ONLY" \
    || fail "release.sh does not parse an --allow-dirty flag"
grep -q 'ALLOW_DIRTY" = true' <<< "$RELEASE_CODE_ONLY" \
    || fail "release.sh has no ALLOW_DIRTY gate on the dirty-tree check"

allow_dirty_arg_line=$(grep -n 'arg" = "--allow-dirty"' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1 || true)
dirty_exit_line=$(grep -n 'exit 4' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1 || true)
test_call_line=$(grep -n '\./Scripts/test\.sh' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1 || true)
test_exit_line=$(grep -n 'exit 5' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1 || true)
dmg_call_line=$(grep -n '\./Scripts/make-dmg\.sh' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1 || true)

[ -n "$allow_dirty_arg_line" ] || fail "release.sh never reads the --allow-dirty argument"
[ -n "$dirty_exit_line" ]      || fail "release.sh has no exit 4 for a dirty tree"
[ -n "$test_call_line" ]       || fail "release.sh does not run ./Scripts/test.sh"
[ -n "$test_exit_line" ]       || fail "release.sh has no exit 5 for a failing test suite"
[ -n "$dmg_call_line" ]        || fail "release.sh does not run ./Scripts/make-dmg.sh"

# Flag parsing happens before the dirty-tree gate uses it; the dirty-tree
# gate (and its exit) run before the test suite; the test suite (and its
# exit) run before make-dmg.sh ever builds anything.
[ "$allow_dirty_arg_line" -lt "$dirty_exit_line" ] \
    || fail "release.sh checks the dirty tree before it has parsed --allow-dirty"
[ "$dirty_exit_line" -lt "$test_call_line" ] \
    || fail "release.sh does not exit on a dirty tree BEFORE running the test suite"
[ "$test_call_line" -lt "$test_exit_line" ] \
    || fail "release.sh's test-failure exit does not follow the test.sh call"
[ "$test_exit_line" -lt "$dmg_call_line" ] \
    || fail "release.sh does not run the test suite (and gate on it) BEFORE ./Scripts/make-dmg.sh"

# ── make-dmg.sh: QSWSourceCommit is written into the COPIED bundle plist,
#    never Resources/Info.plist, on a line BEFORE the first codesign --force ──
MAKE_DMG_CODE_ONLY="$(grep -v '^[[:space:]]*#' "$MAKE_DMG_SCRIPT")"
grep -q 'APP_BUNDLE/Contents/Info.plist' <<< "$MAKE_DMG_CODE_ONLY" \
    || fail "make-dmg.sh does not target the copied bundle's Info.plist"

stamp_line=$(grep -n 'QSWSourceCommit string\|QSWSourceCommit \$SOURCE_COMMIT' "$MAKE_DMG_SCRIPT" | head -1 | cut -d: -f1 || true)
codesign_line=$(grep -n 'codesign --force' "$MAKE_DMG_SCRIPT" | head -1 | cut -d: -f1 || true)
[ -n "$stamp_line" ]    || fail "make-dmg.sh does not write QSWSourceCommit via PlistBuddy"
[ -n "$codesign_line" ] || fail "make-dmg.sh has no codesign --force step"
[ "$stamp_line" -lt "$codesign_line" ] \
    || fail "make-dmg.sh stamps QSWSourceCommit AFTER the first codesign --force"

echo "PASS: release.sh gates packaging on --allow-dirty + a green test suite before make-dmg.sh, and make-dmg.sh stamps QSWSourceCommit before signing"
