#!/usr/bin/env bash
set -euo pipefail

path=$1

test -s "${MACOS_NOTARY_KEY_FILE:-}" || { echo "::error::MACOS_NOTARY_KEY_FILE missing — refusing to notarize $path"; exit 1; }
test -n "${MACOS_NOTARY_KEY_ID:-}" || { echo "::error::MACOS_NOTARY_KEY_ID unset — refusing to notarize $path"; exit 1; }
test -n "${MACOS_NOTARY_ISSUER:-}" || { echo "::error::MACOS_NOTARY_ISSUER unset — refusing to notarize $path"; exit 1; }

echo "macos-notarize: notarizing $path"
zip="$(mktemp -d)/$(basename "$path").zip"
ditto -c -k "$path" "$zip"
out="$(mktemp -d)/notary.json"
attempt=1
while :; do
  if xcrun notarytool submit "$zip" \
    --key "$MACOS_NOTARY_KEY_FILE" \
    --key-id "$MACOS_NOTARY_KEY_ID" \
    --issuer "$MACOS_NOTARY_ISSUER" \
    --wait --timeout 20m --output-format json > "$out"; then
    break
  fi
  if [ "$attempt" -ge 3 ]; then
    echo "::error::notarytool submit failed for $path after 3 attempts"; exit 1
  fi
  echo "::warning::notarytool submit failed for $path (attempt $attempt/3); retrying in $((attempt * 30))s"
  sleep "$((attempt * 30))"
  attempt=$((attempt + 1))
done
cat "$out"
# notarytool submit --wait exits 0 on an Invalid verdict too, and the per-issue log is the
# only place Apple names the rejection reason.
sid="$(plutil -extract id raw -o - "$out")"
if [ "$(plutil -extract status raw -o - "$out")" != "Accepted" ]; then
  xcrun notarytool log "$sid" \
    --key "$MACOS_NOTARY_KEY_FILE" --key-id "$MACOS_NOTARY_KEY_ID" --issuer "$MACOS_NOTARY_ISSUER" || true
  echo "::error::notarization not Accepted for $path (submission $sid)"; exit 1
fi
