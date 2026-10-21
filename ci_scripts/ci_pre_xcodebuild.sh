#!/bin/sh
set -e

# Runs on Xcode Cloud before xcodebuild.
#
# App Store Connect uploads MUST use scheme `laradeck-AppStore` (Release-AppStore):
# sandbox on, Sparkle stripped. Scheme `laradeck` embeds Sparkle and has no App Sandbox
# → ASC rejects with ITMS-90296 / "Preparing build for App Store Connect failed".

SCHEME="${CI_XCODE_SCHEME:-}"
echo "note: Xcode Cloud scheme is '${SCHEME}'"

case "${SCHEME}" in
  *AppStore*)
    echo "note: App Store scheme — sandbox + no Sparkle expected"
    ;;
  laradeck)
    echo "error: scheme 'laradeck' is for Developer ID / Sparkle (direct download) builds."
    echo "error: For App Store Connect, edit the Xcode Cloud workflow → Scheme = 'laradeck-AppStore'."
    echo "error: Refusing to continue so ASC does not get a Sparkle-bundled, non-sandboxed archive."
    exit 1
    ;;
  *)
    echo "warning: unexpected scheme '${SCHEME}' — expected 'laradeck-AppStore' for Mac App Store."
    ;;
esac
