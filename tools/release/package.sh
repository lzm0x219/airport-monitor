#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <app-path> <version-tag> <output-directory>" >&2
  exit 2
fi

app=$1
tag=$2
output_dir=$3

if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Expected a stable version tag such as v1.0.0; got: $tag" >&2
  exit 1
fi

info_plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/Airport Monitor"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")

if [[ "$tag" != "v$version" ]]; then
  echo "Tag $tag does not match app version $version." >&2
  exit 1
fi
if [[ "$bundle_id" != local.SurgeTrafficMonitor ]]; then
  echo "Unexpected bundle identifier: $bundle_id" >&2
  exit 1
fi
if [[ "$build" != "$version" ]]; then
  echo "The build number must match the version for update ordering." >&2
  exit 1
fi
if [[ "${AIRPORT_TEST_PACKAGE:-0}" != 1 && "$feed_url" != "https://github.com/lzm0x219/airport-monitor/releases/latest/download/appcast.xml" ]]; then
  echo "Release packages must use the official update feed." >&2
  exit 1
fi

verify_architectures() {
  local architectures arch
  architectures=$(lipo -archs "$1")
  for arch in arm64 x86_64; do
    if [[ " $architectures " != *" $arch "* ]]; then
      echo "Missing $arch architecture in $1: $architectures" >&2
      return 1
    fi
  done
}

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/airport-monitor-package.XXXXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

verify_architectures "$executable"
codesign --verify --all-architectures --deep --strict --verbose=2 "$app"
signature=$(codesign -dvv "$app" 2>&1)
if [[ "$signature" == *"Signature=adhoc"* ]]; then
  if [[ "${AIRPORT_TEST_PACKAGE:-0}" != 1 ]]; then
    echo "Ad-hoc builds are only allowed for isolated testing." >&2
    exit 1
  fi
else
  if [[ "$signature" != *"Authority=Developer ID Application:"* || "$signature" == *"TeamIdentifier=not set"* ]]; then
    echo "Release packages require a Developer ID Application signature." >&2
    exit 1
  fi
  xcrun stapler validate "$app"
fi
codesign -d --xml --entitlements - "$app" > "$temporary_dir/entitlements.plist"
for entitlement in com.apple.security.app-sandbox com.apple.security.network.client; do
  value=$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$temporary_dir/entitlements.plist")
  if [[ "$value" != true ]]; then
    echo "Required entitlement is not enabled: $entitlement" >&2
    exit 1
  fi
done
if [[ "${AIRPORT_TEST_PACKAGE:-0}" != 1 ]]; then
  library_validation=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$temporary_dir/entitlements.plist" 2>/dev/null || true)
  if [[ "$library_validation" == true ]]; then
    echo "Release packages must retain library validation." >&2
    exit 1
  fi
fi
for suffix in spks spki; do
  if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name' "$temporary_dir/entitlements.plist" | grep -Fq "$bundle_id-$suffix"; then
    echo "Missing the updater's sandbox communication entitlement." >&2
    exit 1
  fi
done
for setting in SUEnableInstallerLauncherService SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
  if [[ $(/usr/libexec/PlistBuddy -c "Print :$setting" "$info_plist") != true ]]; then
    echo "Required updater setting is not enabled: $setting" >&2
    exit 1
  fi
done
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist")
key_bytes=$(printf '%s' "$public_key" | /usr/bin/base64 -D 2>/dev/null | wc -c | tr -d ' ' || true)
if [[ "$key_bytes" != 32 ]]; then
  echo "The application has no valid update signing public key." >&2
  exit 1
fi
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for binary in "$framework/Sparkle" "$framework/Autoupdate" "$framework/Updater.app/Contents/MacOS/Updater" "$framework/XPCServices/Installer.xpc/Contents/MacOS/Installer"; do
  verify_architectures "$binary"
done

mkdir -p "$output_dir"
archive="Airport-Monitor-$tag-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/$archive"

ditto -x -k "$output_dir/$archive" "$temporary_dir"
codesign --verify --all-architectures --deep --strict --verbose=2 "$temporary_dir/Airport Monitor.app"
verify_architectures "$temporary_dir/Airport Monitor.app/Contents/MacOS/Airport Monitor"

(
  cd "$output_dir"
  shasum -a 256 "$archive" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
