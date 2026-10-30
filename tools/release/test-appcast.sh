#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <app-path> <archive-path> <notes-file> <sparkle-bin-directory> <test-key-file>" >&2
  exit 2
fi
app=$1
archive=$2
notes=$3
sparkle_bin=$4
test_key=$5
script_dir=$(cd "$(dirname "$0")" && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/airport-monitor-update-test.XXXXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
tag="v$version"

if (unset SPARKLE_PRIVATE_KEY; "$script_dir/prepare-appcast.sh" "$app" "$archive" "$tag" "$notes" "$temporary_dir/missing" "$sparkle_bin") > "$temporary_dir/missing.log" 2>&1; then
  echo "An update feed was generated without a signing key." >&2
  exit 1
fi
wrong_key=$(openssl rand -base64 32)
if SPARKLE_PRIVATE_KEY="$wrong_key" "$script_dir/prepare-appcast.sh" "$app" "$archive" "$tag" "$notes" "$temporary_dir/wrong" "$sparkle_bin" > "$temporary_dir/wrong.log" 2>&1; then
  echo "An update feed was generated with the wrong signing key." >&2
  exit 1
fi

SPARKLE_PRIVATE_KEY=$(cat "$test_key") "$script_dir/prepare-appcast.sh" "$app" "$archive" "$tag" "$notes" "$temporary_dir/valid" "$sparkle_bin"
"$sparkle_bin/sign_update" --verify --ed-key-file "$test_key" "$temporary_dir/valid/appcast.xml"
signature=$(python3 - "$temporary_dir/valid/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
enclosure = root.find(".//enclosure")
if enclosure is None:
    raise SystemExit("Missing update enclosure")
print(enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"])
PY
)
"$sparkle_bin/sign_update" --verify --ed-key-file "$test_key" "$archive" "$signature"
cp "$archive" "$temporary_dir/tampered.zip"
python3 - "$temporary_dir/tampered.zip" <<'PY'
import sys
with open(sys.argv[1], "r+b") as archive:
    archive.seek(1000)
    value = archive.read(1)
    if not value:
        raise SystemExit("Test archive is too short")
    archive.seek(1000)
    archive.write(bytes([value[0] ^ 1]))
PY
if "$sparkle_bin/sign_update" --verify --ed-key-file "$test_key" "$temporary_dir/tampered.zip" "$signature" > "$temporary_dir/tampered.log" 2>&1; then
  echo "A tampered update archive was accepted." >&2
  exit 1
fi
echo "Update feed signing and rejection checks passed."
