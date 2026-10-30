#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <test-key-file> <sparkle-bin-directory> <signed-appcast>" >&2
  exit 2
fi
test_key=$1
sparkle_bin=$2
appcast=$3
script_dir=$(cd "$(dirname "$0")" && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/airport-monitor-release-guards.XXXXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
mkdir -p "$temporary_dir/bin" "$temporary_dir/fixtures"
cp "$appcast" "$temporary_dir/fixtures/appcast.xml"

cat > "$temporary_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == api && "$2" == repos/lzm0x219/airport-monitor/releases/latest ]]; then
  if [[ "$GUARD_SCENARIO" == no_release || "$GUARD_SCENARIO" == inaccessible ]]; then
    echo 'HTTP 404' >&2
    exit 1
  fi
  if [[ "$GUARD_SCENARIO" == feed ]]; then
    printf '%s\n' '{"tag_name":"v0.9.0","assets":[{"name":"appcast.xml"}]}'
  else
    printf '%s\n' '{"tag_name":"v0.9.0","assets":[]}'
  fi
elif [[ "$1" == api && "$2" == repos/lzm0x219/airport-monitor ]]; then
  [[ "$GUARD_SCENARIO" != inaccessible ]]
elif [[ "$1" == release && "$2" == download ]]; then
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) shift 2 ;;
      --pattern) pattern=$2; shift 2 ;;
      --dir) destination=$2; shift 2 ;;
      *) exit 1 ;;
    esac
  done
  cp "$GUARD_FIXTURES/$pattern" "$destination/$pattern"
else
  exit 1
fi
MOCK
chmod +x "$temporary_dir/bin/gh"

export PATH="$temporary_dir/bin:$PATH"
export GUARD_FIXTURES="$temporary_dir/fixtures"
SPARKLE_PRIVATE_KEY=$(cat "$test_key")
export SPARKLE_PRIVATE_KEY
public_key=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | /usr/bin/swift "$script_dir/update-public-key.swift")
wrong_key=$(openssl rand -base64 32)

expect_failure() {
  if "$@" > "$temporary_dir/failure.log" 2>&1; then
    echo "A release guard unexpectedly accepted an invalid input." >&2
    exit 1
  fi
}

GUARD_SCENARIO=no_release "$script_dir/verify-previous-release.sh" v1.0.0 "$sparkle_bin"
expect_failure env GUARD_SCENARIO=inaccessible "$script_dir/verify-previous-release.sh" v1.0.0 "$sparkle_bin"
GUARD_SCENARIO=feed "$script_dir/verify-previous-release.sh" v1.0.0 "$sparkle_bin"
expect_failure env GUARD_SCENARIO=feed SPARKLE_PRIVATE_KEY="$wrong_key" "$script_dir/verify-previous-release.sh" v1.0.0 "$sparkle_bin"
expect_failure env GUARD_SCENARIO=feed "$script_dir/verify-previous-release.sh" v0.9.0 "$sparkle_bin"

for key in legacy "$public_key" invalid; do
  python3 - "$temporary_dir/fixtures/Airport-Monitor-v0.9.0-macOS-universal.zip" "$key" <<'PY'
import plistlib
import sys
import zipfile
info = {"CFBundleIdentifier": "local.SurgeTrafficMonitor", "CFBundleShortVersionString": "0.9.0"}
if sys.argv[2] != "legacy":
    info["SUPublicEDKey"] = sys.argv[2]
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("Airport Monitor.app/Contents/Info.plist", plistlib.dumps(info))
PY
  if [[ "$key" == invalid ]]; then
    expect_failure env GUARD_SCENARIO=archive "$script_dir/verify-previous-release.sh" v1.0.0 "$sparkle_bin"
  else
    GUARD_SCENARIO=archive "$script_dir/verify-previous-release.sh" v1.0.0 "$sparkle_bin"
    if [[ "$key" != legacy ]]; then
      expect_failure env GUARD_SCENARIO=archive SPARKLE_PRIVATE_KEY="$wrong_key" "$script_dir/verify-previous-release.sh" v1.0.0 "$sparkle_bin"
    fi
  fi
done

expected_feed=https://github.com/lzm0x219/airport-monitor/releases/latest/download/appcast.xml
expect_failure env CONFIGURATION=Release CODE_SIGN_IDENTITY='test identity' SPARKLE_FEED_URL="$expected_feed" \
  SPARKLE_PUBLIC_KEY="$public_key" SWIFT_ACTIVE_COMPILATION_CONDITIONS=UPDATE_TESTING "$script_dir/validate-build-signing.sh"
expect_failure env CONFIGURATION=Release CODE_SIGN_IDENTITY='test identity' SPARKLE_FEED_URL=https://example.com/appcast.xml \
  SPARKLE_PUBLIC_KEY="$public_key" "$script_dir/validate-build-signing.sh"
env CONFIGURATION=Release CODE_SIGN_IDENTITY='test identity' SPARKLE_FEED_URL="$expected_feed" \
  SPARKLE_PUBLIC_KEY="$public_key" "$script_dir/validate-build-signing.sh"
echo "Release configuration and signing continuity checks passed."
