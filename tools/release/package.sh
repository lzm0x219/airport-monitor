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
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")

if [[ "$tag" != "v$version" ]]; then
  echo "Tag $tag does not match app version $version." >&2
  exit 1
fi
if [[ "$bundle_id" != local.SurgeTrafficMonitor ]]; then
  echo "Unexpected bundle identifier: $bundle_id" >&2
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
if [[ "$signature" != *"Signature=adhoc"* ]]; then
  echo "Expected the project's ad-hoc signature." >&2
  exit 1
fi
codesign -d --xml --entitlements - "$app" > "$temporary_dir/entitlements.plist"
for entitlement in com.apple.security.app-sandbox com.apple.security.network.client; do
  value=$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$temporary_dir/entitlements.plist")
  if [[ "$value" != true ]]; then
    echo "Required entitlement is not enabled: $entitlement" >&2
    exit 1
  fi
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
