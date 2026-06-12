#!/usr/bin/env bash
# One-time: create the self-signed "BetterWheel Signing" code-signing identity
# in the login keychain, entirely via CLI (no Keychain Access GUI).
#
# Why: Tauri's default ad-hoc macOS signature makes Gatekeeper flag a quarantined
# download as "…is damaged and can't be opened" on Apple Silicon. Signing with a
# real (even self-signed, untrusted) identity downgrades that to the bypassable
# "unidentified developer" dialog. release.sh uses this identity; see CLAUDE.md.
#
# Trust is intentionally NOT set: codesign signs fine with an untrusted identity,
# and local trust never affects the signature end users receive (their machine
# doesn't have the cert, so it's "unidentified developer" either way). The cert
# therefore shows in `security find-identity -p codesigning` but NOT in the `-v`
# (valid) subset — that's expected.
#
# Usage:  scripts/create-macos-signing-cert.sh
# Remove: security delete-identity -c "BetterWheel Signing"

set -euo pipefail

NAME="BetterWheel Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "${NAME}"; then
  echo ">> '${NAME}' identity already present — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/cert.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = BetterWheel Signing
[ v3 ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

echo ">> generating self-signed code-signing cert (10y)"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" \
  -days 3650 -config "${TMP}/cert.cnf" 2>/dev/null

# Import cert and key separately: OpenSSL 3's PKCS#12 MAC isn't readable by
# Apple's `security import`, and a bare cert+key pair auto-forms an identity.
# -A lets codesign use the key without an "allow access" prompt at release time.
echo ">> importing into login keychain"
security import "${TMP}/cert.pem" -k "${KEYCHAIN}" -A
security import "${TMP}/key.pem"  -k "${KEYCHAIN}" -A -T /usr/bin/codesign

echo ">> done. code-signing identities now include:"
security find-identity -p codesigning | grep "${NAME}"
