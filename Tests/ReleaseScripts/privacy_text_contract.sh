#!/bin/bash
# Contract: the opt-in updater made "no network calls at all" false, and the
# privacy copy has to say so honestly wherever it used to make that claim.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "FAIL: $1"; exit 1; }

BANNED_PATTERNS=(
    "no network calls at all"
    "makes no network calls"
)

for pattern in "${BANNED_PATTERNS[@]}"; do
    if grep -rIl "$pattern" "$PROJECT_DIR/Sources" 2>/dev/null | grep -q .; then
        fail "the retired claim '$pattern' still appears somewhere under Sources/"
    fi
    if grep -Il "$pattern" "$PROJECT_DIR/README.md" >/dev/null 2>&1; then
        fail "the retired claim '$pattern' still appears in README.md"
    fi
done

NEW_PHRASE="Network is used only if you enable update checks"

# Both files legitimately wrap this sentence across multiple source/comment
# lines — collapse newlines before matching so the phrase-level check isn't
# defeated by where a line happens to break.
contains_phrase() {
    # Strip Swift doc-comment markers too, so a phrase wrapped onto a new
    # `///` line (PrivacyService.swift) doesn't leave "/// " glued into the
    # middle of the joined sentence.
    sed -e 's#///##g' -e 's#//##g' "$1" | tr '\n' ' ' | tr -s ' ' | grep -q "$NEW_PHRASE"
}

contains_phrase "$PROJECT_DIR/Sources/QwertySwitcher/Services/PrivacyService.swift" \
    || fail "PrivacyService.swift does not carry the new network-honesty formulation"
contains_phrase "$PROJECT_DIR/README.md" \
    || fail "README.md does not carry the new network-honesty formulation"

echo "PASS: the retired 'no network calls' claim is gone, and the new opt-in-network formulation is present in PrivacyService.swift and README.md"
