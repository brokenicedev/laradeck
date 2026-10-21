#!/usr/bin/env bash
# Sign a release DMG for Sparkle and patch website/appcast.xml.
#
# Prerequisites:
#   - Sparkle EdDSA private key in Keychain (account: laradeck)
#     See scripts/generate-sparkle-keys.sh
#   - Build the laradeck scheme once so sign_update is available via SPM
#
# Usage:
#   ./scripts/sign-release-dmg.sh release/LaraDeck-1.0.4.dmg
#   ./scripts/sign-release-dmg.sh dist/LaraDeck-1.0.4.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST_PATH="$ROOT/website/appcast.xml"
DOWNLOADS_DIR="$ROOT/website/downloads"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-laradeck}"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$ROOT/secrets/sparkle/ed25519-priv.key}"

find_sign_update() {
  if [[ -n "${SPARKLE_SIGN_UPDATE:-}" && -x "${SPARKLE_SIGN_UPDATE}" ]]; then
    echo "$SPARKLE_SIGN_UPDATE"
    return
  fi
  local candidate
  candidate="$(find "$HOME/Library/Developer/Xcode/DerivedData"/laradeck-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    echo "$candidate"
    return
  fi
  if command -v sign_update >/dev/null 2>&1; then
    command -v sign_update
    return
  fi
  echo ""
}

run_sign_update() {
  local sign_update="$1"
  local dmg_path="$2"
  local output=""

  if output="$("$sign_update" --account "$SPARKLE_ACCOUNT" "$dmg_path" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  fi

  if [[ -f "$SPARKLE_KEY_FILE" ]]; then
    echo "→ Retrying sign_update with $SPARKLE_KEY_FILE" >&2
    output="$("$sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$dmg_path" 2>&1)" || {
      echo "$output" >&2
      return 1
    }
    printf '%s\n' "$output"
    return 0
  fi

  echo "$output" >&2
  cat <<EOF >&2

Sparkle signing failed. Expected Keychain account "$SPARKLE_ACCOUNT" or key file:
  $SPARKLE_KEY_FILE

Generate/import keys with: ./scripts/generate-sparkle-keys.sh
EOF
  return 1
}

patch_appcast() {
  local version="$1"
  local build="$2"
  local length="$3"
  local signature="$4"

  echo "→ Updating appcast.xml for $version (build $build)"
  python3 - <<'PY' "$APPCAST_PATH" "$version" "$build" "$length" "$signature"
import re, sys
path, version, build, length, signature = sys.argv[1:6]
text = open(path, encoding="utf-8").read()
pattern = re.compile(
    rf'(<item>\s*<title>{re.escape(version)}</title>.*?'
    rf'<sparkle:version>){build}(</sparkle:version>.*?'
    rf'<enclosure\s+url="[^"]+"\s+)length="[^"]*"(\s+type="application/octet-stream"\s+)'
    rf'sparkle:edSignature="[^"]*"',
    re.DOTALL,
)
def repl(match):
    return (
        f'{match.group(1)}{build}{match.group(2)}length="{length}"'
        f'{match.group(3)}sparkle:edSignature="{signature}"'
    )
new_text, count = pattern.subn(repl, text, count=1)
if count != 1:
    raise SystemExit(f"Could not patch appcast item for version {version}")
open(path, "w", encoding="utf-8").write(new_text)
PY
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 path/to/LaraDeck-X.Y.Z.dmg" >&2
  exit 1
fi

DMG_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

DMG_NAME="$(basename "$DMG_PATH")"
if [[ "$DMG_NAME" =~ LaraDeck-([0-9]+\.[0-9]+\.[0-9]+)\.dmg ]]; then
  VERSION="${BASH_REMATCH[1]}"
else
  echo "Could not parse version from filename (expected LaraDeck-X.Y.Z.dmg): $DMG_NAME" >&2
  exit 1
fi

BUILD="$(python3 -c "import json; print(json.load(open('$ROOT/website/version.json'))['build'])")"
FEED_VERSION="$(python3 -c "import json; print(json.load(open('$ROOT/website/version.json'))['latest'])")"
if [[ "$VERSION" != "$FEED_VERSION" ]]; then
  echo "Warning: DMG is $VERSION but website/version.json latest is $FEED_VERSION." >&2
fi

SIGN_UPDATE="$(find_sign_update)"
if [[ -z "$SIGN_UPDATE" ]]; then
  cat <<EOF >&2
sign_update not found.

Build laradeck once in Xcode, then re-run, or set:
  export SPARKLE_SIGN_UPDATE=/path/to/sign_update
EOF
  exit 1
fi

echo "→ Signing $DMG_PATH"
OUTPUT="$(run_sign_update "$SIGN_UPDATE" "$DMG_PATH")"
echo "$OUTPUT"

LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$OUTPUT" | head -1)"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$OUTPUT" | head -1)"
if [[ -z "$LENGTH" || -z "$SIGNATURE" ]]; then
  echo "Could not parse sign_update output." >&2
  exit 1
fi

patch_appcast "$VERSION" "$BUILD" "$LENGTH" "$SIGNATURE"

mkdir -p "$DOWNLOADS_DIR"
cp -f "$DMG_PATH" "$DOWNLOADS_DIR/$DMG_NAME"

echo
echo "Done."
echo "  length:          $LENGTH"
echo "  edSignature:     $SIGNATURE"
echo "  appcast:         $APPCAST_PATH"
echo "  downloads copy:  $DOWNLOADS_DIR/$DMG_NAME"
echo
echo "Deploy to production:"
echo "  website/version.json"
echo "  website/appcast.xml"
echo "  website/downloads/$DMG_NAME  →  https://laradeck.brokenice.it/downloads/$DMG_NAME"
