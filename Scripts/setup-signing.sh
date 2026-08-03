#!/bin/bash
# Creates a persistent self-signed code-signing identity for Qwerty Switcher.
# so that macOS TCC (Privacy/Accessibility) keeps permissions across rebuilds.
# Run once — subsequent build.sh invocations will reuse the identity.

set -e

# Keep the legacy identity name so existing developer machines do not need a
# second private certificate. Product branding and bundle ID are independent.
IDENTITY_NAME="SashaSwitcher Developer"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"

# Self-signed certs show up as CSSMERR_TP_NOT_TRUSTED but codesign still uses
# them, so we check without -v.
if security find-identity -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "✓ Identity '$IDENTITY_NAME' already exists in login keychain."
    security find-identity -p codesigning | grep "$IDENTITY_NAME"
    exit 0
fi

echo "→ Creating self-signed code-signing identity: $IDENTITY_NAME"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = x509_ext
prompt             = no

[ dn ]
CN = $IDENTITY_NAME

[ x509_ext ]
basicConstraints        = critical, CA:FALSE
keyUsage                = critical, digitalSignature
extendedKeyUsage        = critical, codeSigning
subjectKeyIdentifier    = hash
EOF

openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -config "$TMP/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export \
    -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY_NAME" \
    -passout pass:nfa

echo "→ Importing into login keychain (you may be prompted for your login password)…"
security import "$TMP/identity.p12" \
    -k "$KEYCHAIN_PATH" \
    -P nfa \
    -T /usr/bin/codesign \
    -A

echo "→ Allowing codesign to use the key without prompt…"
echo "  (macOS will ask for your login password once)"
read -s -p "  login password: " LOGIN_PW
echo ""
security unlock-keychain -p "$LOGIN_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,unsigned: \
    -s -k "$LOGIN_PW" \
    "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
unset LOGIN_PW

echo ""
echo "✓ Done. Identity registered:"
security find-identity -p codesigning | grep "$IDENTITY_NAME" || echo "  (not visible yet — rerun this script if needed)"
echo ""
echo "Note: self-signed certs show as CSSMERR_TP_NOT_TRUSTED, that is expected."
echo "      codesign will still use them, and TCC permissions will persist."
echo ""
echo "Next: ./Scripts/build.sh"
