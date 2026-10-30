#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version-tag> <sparkle-bin-directory>" >&2
  exit 2
fi
tag=$1
sparkle_bin=$2
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ || -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "A stable version tag and update signing key are required." >&2
  exit 1
fi
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/airport-monitor-previous-release.XXXXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
if ! gh api 'repos/lzm0x219/airport-monitor/releases/latest' > "$temporary_dir/release.json" 2> "$temporary_dir/error.txt"; then
  if grep -q 'HTTP 404' "$temporary_dir/error.txt"; then
    if ! gh api 'repos/lzm0x219/airport-monitor' > /dev/null; then
      echo "Could not confirm that the release repository is accessible." >&2
      exit 1
    fi
    echo "No published stable release exists yet."
    exit 0
  fi
  echo "Could not verify the latest published release." >&2
  cat "$temporary_dir/error.txt" >&2
  exit 1
fi

previous_tag=$(python3 - "$temporary_dir/release.json" "$tag" <<'PY'
import json
import re
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    release = json.load(f)
def parse(value):
    match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value)
    if not match:
        raise SystemExit("The previous release does not have a stable version tag.")
    return tuple(map(int, match.groups()))
previous = release["tag_name"]
if parse(sys.argv[2]) <= parse(previous):
    raise SystemExit("The new release version must be newer than the latest published version.")
print(previous)
PY
)
if python3 - "$temporary_dir/release.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    release = json.load(f)
raise SystemExit(0 if any(asset["name"] == "appcast.xml" for asset in release["assets"]) else 1)
PY
then
  gh release download "$previous_tag" --repo lzm0x219/airport-monitor --pattern appcast.xml --dir "$temporary_dir"
  if ! printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --verify --ed-key-file - "$temporary_dir/appcast.xml"; then
    echo "The update signing key cannot verify the previous release feed." >&2
    exit 1
  fi
  echo "The update signing key matches the previous release."
else
  # A missing feed does not prove that the previous app lacked an updater.
  # Inspect the published app before treating it as a legacy release.
  previous_archive="Airport-Monitor-$previous_tag-macOS-universal.zip"
  gh release download "$previous_tag" --repo lzm0x219/airport-monitor --pattern "$previous_archive" --dir "$temporary_dir"
  unzip -p "$temporary_dir/$previous_archive" 'Airport Monitor.app/Contents/Info.plist' > "$temporary_dir/previous-info.plist"
  previous_public_key=$(python3 - "$temporary_dir/previous-info.plist" "$previous_tag" <<'PY'
import base64
import binascii
import plistlib
import sys
with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)
if info.get("CFBundleIdentifier") != "local.SurgeTrafficMonitor" or "v" + info.get("CFBundleShortVersionString", "") != sys.argv[2]:
    raise SystemExit("The previous release archive has an unexpected app identity or version.")
if "SUPublicEDKey" not in info:
    print("legacy")
else:
    key = info["SUPublicEDKey"]
    try:
        if not isinstance(key, str) or len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError
    except (ValueError, binascii.Error):
        raise SystemExit("The previous app has an invalid update public key.")
    print("key:" + key)
PY
  )
  if [[ "$previous_public_key" == legacy ]]; then
    echo "The previous release has no updater; its users need a manual update first."
  else
    script_dir=$(cd "$(dirname "$0")" && pwd)
    signing_public_key=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | /usr/bin/swift "$script_dir/update-public-key.swift")
    if [[ "$previous_public_key" != "key:$signing_public_key" ]]; then
      echo "The update signing key does not match the previous application." >&2
      exit 1
    fi
    echo "The previous feed is missing; the update signing key matches the previous application."
  fi
fi
