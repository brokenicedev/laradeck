#!/usr/bin/env bash
# Build, sign (Developer ID), notarize and zip Laradeck for beta distribution.
#
# Prerequisites:
#   1. Apple Developer Program active
#   2. "Developer ID Application" certificate in Keychain (Xcode → Settings → Accounts → Manage Certificates)
#   3. Notary credentials — either:
#        export NOTARY_APPLE_ID="you@example.com"
#        export NOTARY_TEAM_ID="7QHJ63V536"
#        export NOTARY_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password
#      or store once:
#        xcrun notarytool store-credentials "laradeck-notary" \
#          --apple-id "you@example.com" --team-id "7QHJ63V536" --password "app-specific-password"
#        export NOTARY_KEYCHAIN_PROFILE="laradeck-notary"
#
# Usage:
#   ./scripts/release-beta.sh
#   ./scripts/release-beta.sh --skip-notarize   # sign + zip only (local testing)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="laradeck"
VERSION="$(python3 -c "import json; print(json.load(open('$ROOT/website/version.json'))['latest'])")"
BUILD_DIR="$ROOT/build/release"
ARCHIVE_PATH="$BUILD_DIR/laradeck.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="laradeck.app"
ZIP_PATH="$BUILD_DIR/Laradeck-${VERSION}.zip"
SKIP_NOTARIZE=0

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

for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "→ Cleaning output folder"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "→ Archiving Release build"
xcodebuild archive \
  -project "$ROOT/laradeck.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH"

TEAM_ID="$(read_signing_team)"
if [[ -z "$TEAM_ID" ]]; then
  echo "Could not read DEVELOPMENT_TEAM from the Release build settings." >&2
  exit 1
fi
echo "→ Using signing team $TEAM_ID (same as Xcode project)"

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
write_export_options "$TEAM_ID" "$EXPORT_OPTIONS"

echo "→ Exporting Developer ID signed app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app not found at $APP_PATH" >&2
  exit 1
fi

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "→ Creating zip for notarization"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

  echo "→ Submitting to Apple notary service (this can take a few minutes)"
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    SUBMIT_ID="$(xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait | awk '/id:/{print $2; exit}')"
  else
    : "${NOTARY_APPLE_ID:?Set NOTARY_APPLE_ID or NOTARY_KEYCHAIN_PROFILE}"
    : "${NOTARY_TEAM_ID:?Set NOTARY_TEAM_ID or NOTARY_KEYCHAIN_PROFILE}"
    : "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD (app-specific password) or NOTARY_KEYCHAIN_PROFILE}"
    SUBMIT_ID="$(xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait | awk '/id:/{print $2; exit}')"
  fi

  echo "→ Notarization id: $SUBMIT_ID"
  echo "→ Stapling ticket to app"
  xcrun stapler staple "$APP_PATH"
fi

echo "→ Creating distributable zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo
echo "Done."
echo "  App:  $APP_PATH"
echo "  Zip:  $ZIP_PATH"
echo
echo "Upload the zip to your beta host and point beta_link in website/beta/config.php to it."
