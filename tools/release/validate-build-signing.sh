#!/usr/bin/env bash
set -euo pipefail

if [[ "${CONFIGURATION:-}" != Release ]]; then
  exit 0
fi
if [[ "${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} ${OTHER_SWIFT_FLAGS:-}" == *UPDATE_TESTING* ]]; then
  echo "error: UPDATE_TESTING is not allowed in Release builds." >&2
  exit 1
fi
if [[ "${SPARKLE_FEED_URL:-}" != "https://github.com/lzm0x219/airport-monitor/releases/latest/download/appcast.xml" ]]; then
  echo "error: Release builds must use the official update feed." >&2
  exit 1
fi
case "${AIRPORT_RELEASE_SIGNING:-}" in
  adhoc)
    if [[ "${CODE_SIGN_IDENTITY:-}" != "-" || "${CODE_SIGN_ENTITLEMENTS:-}" != AirportMonitor.AdHoc.entitlements ]]; then
      echo "error: Ad-hoc Release builds must use the ad-hoc identity and entitlements." >&2
      exit 1
    fi
    ;;
  developer-id)
    if [[ -z "${CODE_SIGN_IDENTITY:-}" || "$CODE_SIGN_IDENTITY" == "-" || "${CODE_SIGN_ENTITLEMENTS:-}" != AirportMonitor.entitlements ]]; then
      echo "error: Developer ID Release builds need an Apple signing identity and release entitlements." >&2
      exit 1
    fi
    ;;
  *)
    echo "error: AIRPORT_RELEASE_SIGNING must be adhoc or developer-id." >&2
    exit 1
    ;;
esac
if [[ "${CODE_SIGN_INJECT_BASE_ENTITLEMENTS:-}" != NO ]]; then
  echo "error: Release builds must not inject debugging entitlements." >&2
  exit 1
fi
if [[ -z "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  echo "error: Release builds need the update signing public key." >&2
  exit 1
fi
key_bytes=$(printf '%s' "$SPARKLE_PUBLIC_KEY" | /usr/bin/base64 -D 2>/dev/null | wc -c | tr -d ' ' || true)
if [[ "$key_bytes" != 32 ]]; then
  echo "error: The update signing public key must be a base64-encoded Ed25519 public key." >&2
  exit 1
fi
