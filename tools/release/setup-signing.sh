#!/usr/bin/env bash
set -euo pipefail

for name in APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_NOTARY_KEY_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID SPARKLE_PRIVATE_KEY RUNNER_TEMP GITHUB_ENV; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing release signing configuration: $name" >&2
    exit 1
  fi
done

umask 077
keychain="$RUNNER_TEMP/airport-monitor-signing.keychain-db"
certificate="$RUNNER_TEMP/airport-monitor-signing.p12"
notary_key="$RUNNER_TEMP/airport-monitor-notary-key.p8"
keychain_password=$(openssl rand -base64 32)
printf '%s' "$APPLE_CERTIFICATE_BASE64" | /usr/bin/base64 -D > "$certificate"
printf '%s' "$APPLE_NOTARY_KEY_BASE64" | /usr/bin/base64 -D > "$notary_key"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
rm -f "$certificate"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"

identities=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2}')
if [[ $(printf '%s\n' "$identities" | grep -c '^[A-Fa-f0-9]\{40\}$' || true) != 1 ]]; then
  echo "The certificate must contain exactly one Developer ID Application identity." >&2
  exit 1
fi
{
  printf 'AIRPORT_SIGNING_IDENTITY=%s\n' "$identities"
  printf 'AIRPORT_SIGNING_KEYCHAIN=%s\n' "$keychain"
  printf 'AIRPORT_NOTARY_KEY_PATH=%s\n' "$notary_key"
} >> "$GITHUB_ENV"
