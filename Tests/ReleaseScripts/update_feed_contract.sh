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

# MAJOR fix (security review): release.sh must verify the appcast it just
# signed against the SAME public key the app itself trusts — extracted from
# UpdateKeyRing.swift, not a second hardcoded literal that could drift out
# of sync (e.g. k1/k2 swapped by mistake, discovered only when every client
# reports badSignature).
printf '%s\n' "$CODE_ONLY" | grep -q 'UpdateKeyRing.swift' \
    || fail "release.sh does not extract the verification key from UpdateKeyRing.swift"
printf '%s\n' "$CODE_ONLY" | grep -q 'sign-update.swift" verify' \
    || fail "release.sh does not run a verify step after signing"

verify_line=$(grep -n 'sign-update.swift" verify' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1 || true)
sign_line=$(grep -n 'sign-update.swift" sign' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1 || true)
[ -n "$verify_line" ] && [ -n "$sign_line" ] && [ "$verify_line" -gt "$sign_line" ] \
    || fail "release.sh's verify step does not run after the sign step"

# Functionally prove the extraction actually works against the real
# UpdateKeyRing.swift and the real embedded k1/k2 (not just that the grep
# commands exist): the SAME extraction release.sh uses, run here directly,
# must yield a 32-byte raw Ed25519 public key for both keyIds.
KEYRING_SOURCE="$PROJECT_DIR/Sources/QwertySwitcher/Services/Updates/UpdateKeyRing.swift"
[ -f "$KEYRING_SOURCE" ] || fail "UpdateKeyRing.swift is missing"
for key_id in k1 k2; do
    extracted=$(grep -o "\"$key_id\": *\"[A-Za-z0-9+/=]*\"" "$KEYRING_SOURCE" | head -1 | sed -E 's/.*"([A-Za-z0-9+\/=]+)"$/\1/')
    [ -n "$extracted" ] || fail "could not extract a public key for $key_id from UpdateKeyRing.swift"
    decoded_len=$(printf '%s' "$extracted" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [ "$decoded_len" = "32" ] || fail "$key_id in UpdateKeyRing.swift does not decode to a 32-byte raw Ed25519 key"
done

echo "PASS: sign-update.swift signs/verifies correctly and rejects tampering; release.sh stays a local, non-publishing script"
