#!/usr/bin/env bash
# Makes, once and for all, the self-signed certificate that `./build.sh
# release-selfsigned` signs with, until there is a Developer ID.
#
#   Tools/make-signing-certificate.sh ~/Sauvegardes/rushes-signing.p12
#
# Gatekeeper does not trust it, so a downloaded copy is still blocked the first
# time. What it buys is a signature that stays the same from one version to
# the next: macOS keys the removable volumes permission to the designated
# requirement, `identifier "eu.stevenrsl.rushes" and certificate leaf = H"…"`,
# where an ad-hoc signature is keyed to the binary and asked again at every
# version. install.sh checks every download against that same hash.
#
# The key goes into the login keychain and into the .p12 given as argument,
# which is the only copy that survives this Mac: lose both and every tester
# is asked for the volumes again, once, under a new certificate. The .p12 is
# refused inside the repository. The certificate's SHA-1 is written into
# install.sh, which must then be committed.
#
# RUSHES_KEYCHAIN picks another keychain than the login one (for trying it).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Rushes"
BACKUP="${1:-}"
KEYCHAIN="${RUSHES_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if [ -z "$BACKUP" ]; then
  echo "usage: Tools/make-signing-certificate.sh <backup.p12, outside the repository>" >&2
  exit 2
fi
mkdir -p "$(dirname "$BACKUP")"
BACKUP="$(cd "$(dirname "$BACKUP")" && pwd)/$(basename "$BACKUP")"
case "$BACKUP" in
  "$(pwd)"/*) echo "The .p12 holds the private key: keep it out of the repository." >&2; exit 1 ;;
esac
if [ -e "$BACKUP" ]; then
  echo "$BACKUP already exists." >&2
  exit 1
fi
# A second certificate of the same name would make the signature depend on
# which one the keychain hands out first.
if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
  echo "The keychain already holds a signing identity \"$NAME\"." >&2
  exit 1
fi

read -r -s -p "Mot de passe de la sauvegarde .p12 : " PASSWORD; echo
read -r -s -p "Encore une fois : " AGAIN; echo
if [ -z "$PASSWORD" ] || [ "$PASSWORD" != "$AGAIN" ]; then
  echo "The passwords are empty or differ." >&2
  exit 1
fi

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# The system's LibreSSL, not a Homebrew OpenSSL 3: its .p12 is the kind
# `security import` reads. Twenty years, so it never expires under a tester.
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -passout fd:3 -out "$WORK/identity.p12" 3<<<"$PASSWORD"

# Only codesign may use the key without asking.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASSWORD" -T /usr/bin/codesign
cp "$WORK/identity.p12" "$BACKUP"

SHA1="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')"
sed -i '' "s/^CERT_SHA1=.*/CERT_SHA1=\"$SHA1\"/" install.sh

echo "Certificate \"$NAME\": $SHA1"
echo "Key kept in the keychain and in $BACKUP."
echo "install.sh now expects it: commit install.sh, then ./build.sh release-selfsigned."
