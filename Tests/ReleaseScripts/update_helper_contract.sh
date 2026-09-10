#!/bin/bash
# Contract for the `--install-update` helper mode (UpdateInstallerMode). Runs
# the actual compiled debug binary against throwaway fixtures under a temp
# directory — nothing under /Applications or the real
# ~/Library/Application Support/QwertySwitcher is ever touched
# (QSW_UPDATES_ROOT_DIR redirects the transaction/broken markers;
# --target/--stage point straight at the temp fixtures).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $1"; exit 1; }

DEVELOPER_PATH=$(xcode-select -p 2>/dev/null || true)
COMPATIBLE_CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
SWIFT_SDK_ARGS=()
if [[ "$DEVELOPER_PATH" != *"Xcode.app/Contents/Developer"* ]] && [ -d "$COMPATIBLE_CLT_SDK" ]; then
    SWIFT_SDK_ARGS=(--sdk "$COMPATIBLE_CLT_SDK")
fi

cd "$PROJECT_DIR"
swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c debug >/dev/null \
    || fail "could not build the debug binary"
BIN_DIR=$(swift build --disable-sandbox ${SWIFT_SDK_ARGS[@]+"${SWIFT_SDK_ARGS[@]}"} -c debug --show-bin-path)
DEBUG_BIN="$BIN_DIR/QwertySwitcher"
[ -x "$DEBUG_BIN" ] || fail "debug binary not found at $DEBUG_BIN"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export QSW_UPDATES_ROOT_DIR="$WORK/updates"
export QSW_UPDATE_HELPER_TEST_MODE=1
mkdir -p "$QSW_UPDATES_ROOT_DIR"

# ── Fixture builder: a minimal ad-hoc signed "Qwerty Switcher.app" with a
#    given payload string and install.sh sealed into Contents/Resources, like
#    build.sh now does. `install_script_path` defaults to the real
#    Scripts/install.sh; case 2 below substitutes a small stand-in. ──
build_fixture_app() {
    local app_path="$1" payload="$2" install_script_path="${3:-$PROJECT_DIR/Scripts/install.sh}"
    mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
    cp /bin/echo "$app_path/Contents/MacOS/QwertySwitcher"
    cp "$PROJECT_DIR/Resources/Info.plist" "$app_path/Contents/Info.plist"
    cp "$install_script_path" "$app_path/Contents/Resources/install.sh"
    chmod +x "$app_path/Contents/Resources/install.sh"
    echo "$payload" > "$app_path/Contents/Resources/payload.txt"
    codesign --force --deep --sign - "$app_path" >/dev/null 2>&1 \
        || fail "could not ad-hoc sign fixture at $app_path"
}

# ── Case 1: successful install ──
TARGET1="$WORK/case1/dest/Qwerty Switcher.app"
STAGE1="$WORK/case1/stage"
mkdir -p "$(dirname "$TARGET1")" "$STAGE1"
build_fixture_app "$TARGET1" "installed-v1"
# rsync's default quick-check skips a file whose size AND mtime already
# match — without this gap, target's and stage's independently-generated
# _CodeSignature/CodeResources can land in the same wall-clock second and
# get silently skipped while payload.txt (different size) still copies,
# which breaks the seal for a reason that has nothing to do with the code
# under test (same fix install_contract.sh already applies for the same
# reason).
sleep 1
build_fixture_app "$STAGE1/Qwerty Switcher.app" "staged-v2"
inode_before="$(stat -f %i "$TARGET1")"

"$DEBUG_BIN" --install-update --stage "$STAGE1" --target "$TARGET1" --parent-pid 0 \
    || fail "successful install case exited non-zero"

[ "$(stat -f %i "$TARGET1")" = "$inode_before" ] \
    || fail "successful install recreated the target bundle directory (TCC-unsafe)"
[ "$(cat "$TARGET1/Contents/Resources/payload.txt")" = "staged-v2" ] \
    || fail "successful install did not apply the staged content"
codesign --verify --deep --strict "$TARGET1" >/dev/null 2>&1 \
    || fail "target does not satisfy its Designated Requirement after a successful install"
[ -f "$QSW_UPDATES_ROOT_DIR/.transaction" ] \
    && fail "the .transaction marker was not removed after a successful install"

# ── Case 2: install.sh reports a broken post-sync seal (exit 6) → the helper
#    rolls back to the pre-supplied backup, byte-identical.
#    install.sh's OWN internal gates (source signature, identity, sync,
#    "$DEST_APP" verify) are already exercised end-to-end by
#    install_contract.sh — this contract is specifically about what THIS
#    helper does with that exit code, so exit 6 is reproduced with a tiny
#    stand-in script that first writes a "partial sync" artifact (simulating
#    what a genuinely interrupted rsync would leave behind) and then exits 6,
#    exactly as install.sh's own step [5/5] gate does on a real failure. ──
FAKE_INSTALL_SH="$WORK/fake-install.sh"
cat > "$FAKE_INSTALL_SH" <<'FAKE'
#!/bin/bash
DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="$2"; shift 2 ;;
        *) shift ;;
    esac
done
echo "partial-sync-artifact" > "$DEST/Qwerty Switcher.app/Contents/Resources/payload.txt"
exit 6
FAKE
chmod +x "$FAKE_INSTALL_SH"

TARGET2="$WORK/case2/dest/Qwerty Switcher.app"
STAGE2="$WORK/case2/stage"
mkdir -p "$(dirname "$TARGET2")" "$STAGE2"
build_fixture_app "$TARGET2" "installed-good"
build_fixture_app "$STAGE2/Qwerty Switcher.app" "staged-irrelevant" "$FAKE_INSTALL_SH"
cp -R "$TARGET2" "$STAGE2/backup"

"$DEBUG_BIN" --install-update --stage "$STAGE2" --target "$TARGET2" --parent-pid 0 \
    && fail "the broken-post-sync-seal case should not report success"

[ "$(cat "$TARGET2/Contents/Resources/payload.txt")" = "installed-good" ] \
    || fail "rollback did not restore the backup's content (target still shows the partial-sync artifact)"
diff -r "$STAGE2/backup" "$TARGET2" >/dev/null 2>&1 \
    || fail "target is not byte-identical to the backup after rollback"
codesign --verify --deep --strict "$TARGET2" >/dev/null 2>&1 \
    || fail "target fails signature verification after rollback"
[ -f "$QSW_UPDATES_ROOT_DIR/.broken" ] \
    && fail "a successful rollback should not leave the .broken marker behind"

# ── Case 3: second run while a DIFFERENT transaction is still live must not
#    touch the target ──
TARGET3="$WORK/case3/dest/Qwerty Switcher.app"
STAGE3A="$WORK/case3/stageA"
STAGE3B="$WORK/case3/stageB"
mkdir -p "$(dirname "$TARGET3")" "$STAGE3A" "$STAGE3B"
build_fixture_app "$TARGET3" "installed-v1"
build_fixture_app "$STAGE3A/Qwerty Switcher.app" "staged-A"
build_fixture_app "$STAGE3B/Qwerty Switcher.app" "staged-B"

python3 - "$QSW_UPDATES_ROOT_DIR/.transaction" "$$" "$TARGET3" "$STAGE3A" <<'PY'
import json, sys, time
path, pid, target, stage = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(path, "w") as f:
    json.dump({
        "helperPid": pid, "timestampEpoch": time.time(),
        "target": target, "stage": stage,
    }, f)
PY

SNAPSHOT3="$WORK/case3-before-snapshot"
cp -R "$TARGET3" "$SNAPSHOT3"

"$DEBUG_BIN" --install-update --stage "$STAGE3B" --target "$TARGET3" --parent-pid 0 \
    && fail "a second run racing a live transaction for a DIFFERENT stage should not report success"

diff -r "$SNAPSHOT3" "$TARGET3" >/dev/null 2>&1 \
    || fail "target was modified despite another transaction being live"

rm -f "$QSW_UPDATES_ROOT_DIR/.transaction"

# ── Source guards (also unit-tested in UpdatesTests.swift; re-checked here
#    as a release-time gate independent of the Swift suite) ──
HELPER_SOURCE="$PROJECT_DIR/Sources/QwertySwitcher/Services/Updates/UpdateInstallerMode.swift"
LAUNCHER_SOURCE="$PROJECT_DIR/Sources/QwertySwitcher/Services/Updates/UpdateInstallLauncher.swift"
[ -f "$HELPER_SOURCE" ] || fail "UpdateInstallerMode.swift is missing"
[ -f "$LAUNCHER_SOURCE" ] || fail "UpdateInstallLauncher.swift is missing"

HELPER_CODE="$(grep -v '^[[:space:]]*//' "$HELPER_SOURCE")"
if printf '%s\n' "$HELPER_CODE" | grep -q 'osascript'; then
    fail "UpdateInstallerMode.swift shells out to osascript"
fi
if printf '%s\n' "$HELPER_CODE" | grep -q -- '--allow-identity-change'; then
    fail "UpdateInstallerMode.swift passes --allow-identity-change to install.sh"
fi
LAUNCHER_CODE="$(grep -v '^[[:space:]]*//' "$LAUNCHER_SOURCE")"
if printf '%s\n' "$LAUNCHER_CODE" | grep -q -- '--allow-identity-change'; then
    fail "UpdateInstallLauncher.swift passes --allow-identity-change to the helper"
fi

echo "PASS: --install-update helper installs in place, rolls back a broken post-sync seal byte-identically, refuses a racing transaction, and stays osascript-free"
