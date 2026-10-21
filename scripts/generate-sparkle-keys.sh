#!/usr/bin/env bash
# Generate or print Sparkle EdDSA keys for direct-distribution updates.
# Public key → laradeck/Info.plist SUPublicEDKey
# Private key → macOS Keychain (account: laradeck); optional export under secrets/sparkle/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_DIR="${ROOT}/secrets/sparkle"
ACCOUNT="laradeck"
mkdir -p "${KEYS_DIR}"

find_generate_keys() {
  if command -v generate_keys >/dev/null 2>&1; then
    command -v generate_keys
    return
  fi
  local candidate
  candidate="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -path '*/Sparkle/bin/generate_keys' 2>/dev/null | head -1 || true)"
  if [[ -n "${candidate}" ]]; then
    echo "${candidate}"
    return
  fi
  return 1
}

if ! GENERATE_KEYS="$(find_generate_keys)"; then
  cat <<EOF
Could not find Sparkle's generate_keys.

Build the laradeck scheme once (resolves the Sparkle package), then re-run this script, or
download Sparkle from https://github.com/sparkle-project/Sparkle/releases.
EOF
  exit 1
fi

echo "Using ${GENERATE_KEYS}"
"${GENERATE_KEYS}" --account "${ACCOUNT}"

echo
echo "Exporting private key backup to ${KEYS_DIR}/ed25519-priv.key (gitignored)…"
"${GENERATE_KEYS}" --account "${ACCOUNT}" -x "${KEYS_DIR}/ed25519-priv.key"

PUB="$("${GENERATE_KEYS}" --account "${ACCOUNT}" -p)"
printf '%s\n' "${PUB}" > "${KEYS_DIR}/ed25519-pub.txt"
echo "Public key written to ${KEYS_DIR}/ed25519-pub.txt"
echo
echo "Ensure laradeck/Info.plist contains:"
echo "  <key>SUPublicEDKey</key>"
echo "  <string>${PUB}</string>"
