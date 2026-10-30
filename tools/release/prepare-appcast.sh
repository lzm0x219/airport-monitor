#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 <app-path> <archive-path> <version-tag> <notes-file> <output-directory> <sparkle-bin-directory>" >&2
  exit 2
fi

app=$1
archive=$2
tag=$3
notes=$4
output_dir=$5
sparkle_bin=$6
script_dir=$(cd "$(dirname "$0")" && pwd)

if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Expected a stable version tag such as v1.0.0." >&2
  exit 1
fi
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "The update signing key is not configured." >&2
  exit 1
fi
if [[ ! -f "$archive" || ! -s "$notes" || ! -x "$sparkle_bin/generate_appcast" || ! -x "$sparkle_bin/sign_update" ]]; then
  echo "Update archive, release notes or Sparkle signing tools are missing." >&2
  exit 1
fi

info="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
if [[ "$tag" != "v$version" || "$build" != "$version" || "$bundle_id" != "local.SurgeTrafficMonitor" ]]; then
  echo "The update version, build number or application identifier is invalid." >&2
  exit 1
fi
if [[ $(basename "$archive") != "Airport-Monitor-$tag-macOS-universal.zip" ]]; then
  echo "Unexpected update archive name." >&2
  exit 1
fi

signing_public_key=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | /usr/bin/swift "$script_dir/update-public-key.swift")
if [[ "$signing_public_key" != "$public_key" ]]; then
  echo "The update signing key does not match the application." >&2
  exit 1
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}/airport-monitor-appcast.XXXXXXXX")
trap 'rm -rf "$staging"' EXIT
archive_name=$(basename "$archive")
cp "$archive" "$staging/$archive_name"
cp "$notes" "$staging/${archive_name%.zip}.md"
download_prefix="https://github.com/lzm0x219/airport-monitor/releases/download/$tag/"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" --ed-key-file - \
  --download-url-prefix "$download_prefix" --embed-release-notes --maximum-deltas 0 "$staging"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --verify --ed-key-file - "$staging/appcast.xml"
mkdir -p "$output_dir"
cp "$staging/appcast.xml" "$output_dir/appcast.xml"
if [[ -f "$output_dir/SHA256SUMS.txt" ]]; then
  (
    cd "$output_dir"
    shasum -a 256 appcast.xml >> SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
  )
fi
