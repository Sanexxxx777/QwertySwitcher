#!/bin/bash
# Contract for Scripts/sign-update.swift and the static shape of
# Scripts/release.sh — the update feed's signing tool and the packaging
# script that drives it.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN_SCRIPT="$PROJECT_DIR/Scripts/sign-update.swift"
RELEASE_SCRIPT="$PROJECT_DIR/Scripts/release.sh"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SIGN_SCRIPT" ]     || fail "Scripts/sign-update.swift is missing"
[ -x "$RELEASE_SCRIPT" ]  || fail "Scripts/release.sh is missing or not executable"
bash -n "$RELEASE_SCRIPT" || fail "Scripts/release.sh does not parse"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo '{"version":"9.9.9","build":999,"minSystemVersion":"13.0","archiveURL":"https://example.com/x.zip","size":1,"sha256":"aa","publishedAt":"2026-01-01T00:00:00Z","validUntil":"2099-01-01T00:00:00Z","notes":"test"}' \
    > "$WORK/manifest.json"

swift "$SIGN_SCRIPT" keygen --out-private "$WORK/priv.key" --out-public "$WORK/pub.txt" > "$WORK/keygen.out" \
    || fail "keygen failed"
PUB=$(grep '^public:' "$WORK/keygen.out" | sed 's/^public: //')
[ -n "$PUB" ] || fail "keygen produced no public key"

swift "$SIGN_SCRIPT" sign --key "$WORK/priv.key" --key-id test --manifest "$WORK/manifest.json" --out "$WORK/appcast.json" \
    || fail "sign failed"
[ -f "$WORK/appcast.json" ] || fail "sign did not write an appcast file"

swift "$SIGN_SCRIPT" verify --public "$PUB" --appcast "$WORK/appcast.json" >/dev/null \
    || fail "verify rejected a validly signed appcast"

# Tamper one character of manifestBase64 — verify must now fail.
python3 - "$WORK/appcast.json" "$WORK/tampered.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    doc = json.load(f)
chars = list(doc["manifestBase64"])
i = 0 if chars[0] != "A" else 1
chars[i] = "A" if chars[i] != "A" else "B"
doc["manifestBase64"] = "".join(chars)
with open(dst, "w") as f:
    json.dump(doc, f)
PY

if swift "$SIGN_SCRIPT" verify --public "$PUB" --appcast "$WORK/tampered.json" >/dev/null 2>&1; then
    fail "verify accepted a tampered manifestBase64"
fi

# Wrong public key must also fail.
swift "$SIGN_SCRIPT" keygen --out-private "$WORK/priv2.key" --out-public "$WORK/pub2.txt" > "$WORK/keygen2.out" \
    || fail "second keygen failed"
PUB2=$(grep '^public:' "$WORK/keygen2.out" | sed 's/^public: //')
if swift "$SIGN_SCRIPT" verify --public "$PUB2" --appcast "$WORK/appcast.json" >/dev/null 2>&1; then
    fail "verify accepted a signature checked against the wrong public key"
fi

# ── Static contract on release.sh ──
CODE_ONLY="$(grep -v '^[[:space:]]*#' "$RELEASE_SCRIPT")"
printf '%s\n' "$CODE_ONLY" | grep -q 'ditto -c -k' \
    || fail "release.sh does not zip the update archive with ditto -c -k"
printf '%s\n' "$CODE_ONLY" | grep -q 'shasum -a 256' \
    || fail "release.sh does not compute a sha256 for the archive"
printf '%s\n' "$CODE_ONLY" | grep -q 'release-secret-scan.sh' \
    || fail "release.sh does not run the secret scanner"
printf '%s\n' "$CODE_ONLY" | grep -q 'DOWNLOADS_DIR' \
    || fail "release.sh does not scan the downloads folder before publishing"
if printf '%s\n' "$CODE_ONLY" | grep -Ev '^[[:space:]]*echo' | grep -qE 'git push|gh release create'; then
    fail "release.sh executes git push / gh release create instead of only printing them for the owner"
fi

echo "PASS: sign-update.swift signs/verifies correctly and rejects tampering; release.sh stays a local, non-publishing script"
