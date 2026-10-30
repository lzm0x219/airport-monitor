#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <app-path> <signing-identity> <keychain-path>" >&2
  exit 2
fi
app=$1
identity=$2
keychain=$3
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/airport-monitor-signing.XXXXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
codesign -d --xml --entitlements - "$app" > "$temporary_dir/entitlements.plist"

codesign -f -s "$identity" -o runtime --keychain "$keychain" "$framework/XPCServices/Installer.xpc"
codesign -f -s "$identity" -o runtime --keychain "$keychain" --preserve-metadata=entitlements "$framework/XPCServices/Downloader.xpc"
codesign -f -s "$identity" -o runtime --keychain "$keychain" "$framework/Autoupdate"
codesign -f -s "$identity" -o runtime --keychain "$keychain" "$framework/Updater.app"
codesign -f -s "$identity" -o runtime --keychain "$keychain" "$app/Contents/Frameworks/Sparkle.framework"
codesign -f -s "$identity" -o runtime --keychain "$keychain" --entitlements "$temporary_dir/entitlements.plist" "$app"
codesign --verify --all-architectures --deep --strict "$app"
