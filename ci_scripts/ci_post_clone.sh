#!/bin/sh

set -e

# Allow Swift Package Manager build tool plugins (e.g. SwiftTermBuildInfoPlugin)
# in non-interactive CI environments such as Xcode Cloud.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
