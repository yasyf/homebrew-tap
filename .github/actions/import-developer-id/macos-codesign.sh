#!/usr/bin/env bash
# Developer ID code-sign + notarize one macOS build artifact. The single canonical
# copy — dropped on the runner by the import-developer-id action and exported as
# $MACOS_CODESIGN_SCRIPT. Never vendor a copy into a repo.
#
# Invoked per-build by goreleaser's `builds.hooks.post`:
#     bash "$MACOS_CODESIGN_SCRIPT" "{{ .Path }}" "{{ .Target }}"
#
# Why not goreleaser's built-in `notarize` (quill)? quill's arm64 signatures get
# SIGKILLed by macOS 15/26 at exec (anchore/quill#566, closed "not planned"). Apple's
# own codesign + notarytool build a correct designated requirement from the resolved
# system chain regardless of p12 ordering. So repos that already run on a macOS runner
# (cgo native clang, lipo, an Xcode .app) sign this way; pure-Go repos that release on
# ubuntu keep quill (cheaper, and fine with a full-chain p12).
#
# No-op unless the target is darwin AND MACOS_SIGN_IDENTITY is set, so a repo without
# the MACOS_* secrets still releases (unsigned).
#
# Env (set by the import-developer-id action):
#   MACOS_SIGN_IDENTITY        — "Developer ID Application: NAME (TEAMID)"
#   MACOS_NOTARY_KEY_FILE      — path to the App Store Connect API .p8 (enables notarization)
#   MACOS_NOTARY_KEY_ID        — the key's Key ID
#   MACOS_NOTARY_ISSUER        — the team's Issuer ID
#   MACOS_CODESIGN_ENTITLEMENTS — optional path to an entitlements plist. Set this for a
#       cgo binary that dlopens a third-party dylib (e.g. libfuse-t): the plist must carry
#       com.apple.security.cs.disable-library-validation, or hardened runtime blocks the load.
set -euo pipefail

bin=$1
target=${2:-}

case "$target" in
  darwin_*) ;;
  *) exit 0 ;;
esac

if [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo "macos-codesign: MACOS_SIGN_IDENTITY unset — leaving $bin unsigned"
  exit 0
fi

ents_args=()
if [ -n "${MACOS_CODESIGN_ENTITLEMENTS:-}" ]; then
  test -f "$MACOS_CODESIGN_ENTITLEMENTS" || { echo "::error::MACOS_CODESIGN_ENTITLEMENTS=$MACOS_CODESIGN_ENTITLEMENTS not found"; exit 1; }
  ents_args=(--entitlements "$MACOS_CODESIGN_ENTITLEMENTS")
fi

echo "macos-codesign: signing $bin ($target)"
# ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty — safe under `set -u`
# on the macOS runner's bash 3.2, where a bare "${arr[@]}" on an empty array aborts.
codesign --force --options runtime --timestamp ${ents_args[@]+"${ents_args[@]}"} -s "$MACOS_SIGN_IDENTITY" "$bin"
codesign --verify --strict --verbose=2 "$bin"

if [ -n "${MACOS_NOTARY_KEY_FILE:-}" ]; then
  echo "macos-codesign: notarizing $bin"
  zip="$(mktemp -d)/$(basename "$bin").zip"
  ditto -c -k "$bin" "$zip"
  # notarytool submit --wait exits 0 even on an Invalid result, so capture the JSON and
  # FAIL LOUD unless status == Accepted, dumping the per-issue log (the only place the
  # rejection reason appears).
  out="$(mktemp -d)/notary.json"
  xcrun notarytool submit "$zip" \
    --key "$MACOS_NOTARY_KEY_FILE" \
    --key-id "$MACOS_NOTARY_KEY_ID" \
    --issuer "$MACOS_NOTARY_ISSUER" \
    --wait --timeout 20m --output-format json > "$out"
  cat "$out"
  sid="$(plutil -extract id raw -o - "$out")"
  if [ "$(plutil -extract status raw -o - "$out")" != "Accepted" ]; then
    xcrun notarytool log "$sid" \
      --key "$MACOS_NOTARY_KEY_FILE" --key-id "$MACOS_NOTARY_KEY_ID" --issuer "$MACOS_NOTARY_ISSUER" || true
    echo "::error::notarization not Accepted for $bin (submission $sid)"; exit 1
  fi
  # A bare Mach-O can't be stapled; notarization is recorded against its cdhash and
  # verified online by Gatekeeper. (.app bundles are stapled by the macos-app-cask action.)
fi
