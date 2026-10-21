#!/usr/bin/env bash
# Build Laradeck, notarize, create a branded DMG, sign for Sparkle, and patch appcast.xml.
#
# Prerequisites:
#   brew install create-dmg
#   Xcode + Developer ID certificate
#   Sparkle signing key in Keychain (see scripts/generate-sparkle-keys.sh)
#   Notary credentials — either NOTARY_KEYCHAIN_PROFILE or NOTARY_APPLE_ID / TEAM_ID / PASSWORD
#
# Usage:
#   ./scripts/release-dmg.sh
#   ./scripts/release-dmg.sh --skip-build          # dist/LaraDeck.app already present
#   ./scripts/release-dmg.sh --skip-notarize       # local testing only
#   ./scripts/release-dmg.sh --skip-sparkle        # DMG only, no appcast signature
#
# Outputs:
#   dist/LaraDeck.app
#   dist/LaraDeck-<version>.dmg
#   website/downloads/LaraDeck-<version>.dmg   (copy for upload)
#   website/appcast.xml                        (length + edSignature updated)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="laradeck"
BUILD_DIR="$ROOT/build/release"
ARCHIVE_PATH="$BUILD_DIR/laradeck.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
SOURCE_APP_NAME="laradeck.app"
DIST_DIR="$ROOT/dist"
DISPLAY_APP_NAME="LaraDeck.app"

SKIP_BUILD=0
SKIP_NOTARIZE=0
SKIP_SPARKLE=0

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --skip-sparkle) SKIP_SPARKLE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

VERSION="$(python3 -c "import json; print(json.load(open('$ROOT/website/version.json'))['latest'])")"
BUILD="$(python3 -c "import json; print(json.load(open('$ROOT/website/version.json'))['build'])")"
DMG_NAME="LaraDeck-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
APPCAST_PATH="$ROOT/website/appcast.xml"
DOWNLOADS_DIR="$ROOT/website/downloads"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-laradeck}"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$ROOT/secrets/sparkle/ed25519-priv.key}"

read_signing_team() {
  xcodebuild -showBuildSettings \
    -project "$ROOT/laradeck.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    2>/dev/null \
    | awk -F' = ' '/ DEVELOPMENT_TEAM = / { print $2; exit }'
}

write_export_options() {
  local team_id="$1"
  local plist_path="$2"
  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${team_id}</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF
}

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
  return 1
}

build_and_stage_app() {
  echo "→ Cleaning build output"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$DIST_DIR"

  echo "→ Archiving Release build"
  xcodebuild archive \
    -project "$ROOT/laradeck.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH"

  local team_id
  team_id="$(read_signing_team)"
  if [[ -z "$team_id" ]]; then
    echo "Could not read DEVELOPMENT_TEAM from the Release build settings." >&2
    exit 1
  fi
  echo "→ Using signing team $team_id (same as Xcode project)"

  local export_options="$BUILD_DIR/ExportOptions.plist"
  write_export_options "$team_id" "$export_options"

  echo "→ Exporting Developer ID signed app"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$export_options"

  local app_path="$EXPORT_PATH/$SOURCE_APP_NAME"
  if [[ ! -d "$app_path" ]]; then
    echo "Expected app not found at $app_path" >&2
    exit 1
  fi

  if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    local zip_path="$BUILD_DIR/Laradeck-${VERSION}.zip"
    echo "→ Creating zip for notarization"
    ditto -c -k --keepParent "$app_path" "$zip_path"

    echo "→ Submitting to Apple notary service (this can take a few minutes)"
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
      xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    else
      : "${NOTARY_APPLE_ID:?Set NOTARY_APPLE_ID or NOTARY_KEYCHAIN_PROFILE}"
      : "${NOTARY_TEAM_ID:?Set NOTARY_TEAM_ID or NOTARY_KEYCHAIN_PROFILE}"
      : "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD (app-specific password) or NOTARY_KEYCHAIN_PROFILE}"
      xcrun notarytool submit "$zip_path" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait
    fi

    echo "→ Stapling notarization ticket"
    xcrun stapler staple "$app_path"
  fi

  echo "→ Staging $DISPLAY_APP_NAME in dist/"
  rm -rf "$DIST_DIR/$DISPLAY_APP_NAME"
  ditto "$app_path" "$DIST_DIR/$DISPLAY_APP_NAME"
}

create_dmg() {
  echo "→ Creating DMG with create-dmg"
  rm -f "$DMG_PATH"

  create-dmg \
    --volname "LaraDeck" \
    --window-pos 200 120 \
    --window-size 660 420 \
    --icon-size 110 \
    --icon "$DISPLAY_APP_NAME" 170 210 \
    --hide-extension "$DISPLAY_APP_NAME" \
    --app-drop-link 490 210 \
    "$DMG_PATH" \
    "$DIST_DIR/"
}

patch_appcast() {
  local length="$1"
  local signature="$2"

  echo "→ Updating appcast.xml for $VERSION (build $BUILD)"
  python3 - <<'PY' "$APPCAST_PATH" "$VERSION" "$BUILD" "$length" "$signature"
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

sign_sparkle_and_patch_appcast() {
  local sign_update
  sign_update="$(find_sign_update)"
  if [[ -z "$sign_update" ]]; then
    echo "sign_update not found. Build the project once in Xcode (Sparkle SPM) or set SPARKLE_SIGN_UPDATE." >&2
    exit 1
  fi

  echo "→ Signing DMG for Sparkle"
  local output
  output="$(run_sign_update "$sign_update" "$DMG_PATH")"
  echo "$output"

  local length signature
  length="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$output" | head -1)"
  signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$output" | head -1)"

  if [[ -z "$length" || -z "$signature" ]]; then
    echo "Could not parse sign_update output." >&2
    exit 1
  fi

  patch_appcast "$length" "$signature"
}

copy_to_downloads() {
  mkdir -p "$DOWNLOADS_DIR"
  cp -f "$DMG_PATH" "$DOWNLOADS_DIR/$DMG_NAME"
}

echo "Laradeck release DMG — version $VERSION (build $BUILD)"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_and_stage_app
else
  if [[ ! -d "$DIST_DIR/$DISPLAY_APP_NAME" ]]; then
    echo "Expected $DIST_DIR/$DISPLAY_APP_NAME — run without --skip-build or copy the app there." >&2
    exit 1
  fi
  mkdir -p "$DIST_DIR"
fi

create_dmg
copy_to_downloads

if [[ "$SKIP_SPARKLE" -eq 0 ]]; then
  sign_sparkle_and_patch_appcast
fi

echo
echo "Done."
echo "  App:     $DIST_DIR/$DISPLAY_APP_NAME"
echo "  DMG:     $DMG_PATH"
echo "  Mirror:  $DOWNLOADS_DIR/$DMG_NAME"
if [[ "$SKIP_SPARKLE" -eq 0 ]]; then
  echo "  Appcast: $APPCAST_PATH"
fi
echo
echo "Deploy to production:"
echo "  website/version.json"
echo "  website/appcast.xml"
echo "  website/downloads/$DMG_NAME  →  https://laradeck.brokenice.it/downloads/$DMG_NAME"
