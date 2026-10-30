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
if [[ -z "${CODE_SIGN_IDENTITY:-}" || "$CODE_SIGN_IDENTITY" == "-" ]]; then
  echo "error: Release builds with the updater need an Apple signing identity." >&2
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
