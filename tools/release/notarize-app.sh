#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <app-path> <notary-key-path> <notary-key-id> <notary-issuer-id>" >&2
  exit 2
fi
app=$1
notary_key=$2
key_id=$3
issuer=$4
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/airport-monitor-notary.XXXXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary_dir/submission.zip"
xcrun notarytool submit "$temporary_dir/submission.zip" --key "$notary_key" --key-id "$key_id" \
  --issuer "$issuer" --wait --output-format json > "$temporary_dir/result.json"
python3 - "$temporary_dir/result.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as result:
    status = json.load(result).get("status")
if status != "Accepted":
    raise SystemExit(f"Apple notarization did not accept the app: {status}")
print("Apple notarization accepted the app.")
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
