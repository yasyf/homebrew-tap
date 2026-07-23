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
# Non-Darwin targets are ignored. A Darwin target fails closed unless the imported
# Developer ID identity and its derived Team ID are both present and coherent.
#
# Env (set by the import-developer-id action):
#   MACOS_SIGN_IDENTITY        — "Developer ID Application: NAME (TEAMID)"
#   MACOS_NOTARY_KEY_FILE      — path to the required App Store Connect API .p8
#   MACOS_NOTARY_KEY_ID        — the key's Key ID
#   MACOS_NOTARY_ISSUER        — the team's Issuer ID
#   MACOS_CODESIGN_ENTITLEMENTS — optional path to an entitlements plist.
#   MACOS_CODESIGN_DISABLE_LIBRARY_VALIDATION — set to 1 to sign with a built-in
#       com.apple.security.cs.disable-library-validation entitlement (no plist to hand-write).
#       Needed by a cgo binary that dlopens a third-party dylib (e.g. libfuse-t) under the
#       hardened runtime. Ignored when MACOS_CODESIGN_ENTITLEMENTS is given (that wins).
#   MACOS_CODESIGN_IDENTIFIER   — optional explicit codesign --identifier for a bare CLI Mach-O
#       granted a TCC permission. tccd keys the grant by the signing identifier only when it's
#       reverse-DNS-shaped (dotted); codesign defaults it to the binary basename, and an undotted
#       one (e.g. "cc-pool") makes tccd key on the absolute exec path instead — so every brew
#       upgrade (new Cellar path) re-prompts. A dotted identifier is keyed once and survives
#       upgrades. .app bundles don't need this (they key on CFBundleIdentifier).
set -euo pipefail

bin=$1
target=${2:-}

case "$target" in
  darwin_*) ;;
  *) exit 0 ;;
esac

if [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo "::error::MACOS_SIGN_IDENTITY unset — refusing to ship unsigned Darwin binary $bin"
  exit 1
fi
if [ -z "${TEAM_ID:-}" ]; then
  echo "::error::TEAM_ID unset — refusing to sign Darwin binary $bin without an exact team"
  exit 1
fi
case "$MACOS_SIGN_IDENTITY" in
  *"($TEAM_ID)") ;;
  *) echo "::error::MACOS_SIGN_IDENTITY '$MACOS_SIGN_IDENTITY' does not match TEAM_ID '$TEAM_ID'"; exit 1 ;;
esac
test -s "${MACOS_NOTARY_KEY_FILE:-}" || { echo "::error::MACOS_NOTARY_KEY_FILE missing — refusing to ship unnotarized Darwin binary $bin"; exit 1; }
test -n "${MACOS_NOTARY_KEY_ID:-}" || { echo "::error::MACOS_NOTARY_KEY_ID unset — refusing to ship unnotarized Darwin binary $bin"; exit 1; }
test -n "${MACOS_NOTARY_ISSUER:-}" || { echo "::error::MACOS_NOTARY_ISSUER unset — refusing to ship unnotarized Darwin binary $bin"; exit 1; }

ents_args=()
if [ -n "${MACOS_CODESIGN_ENTITLEMENTS:-}" ]; then
  test -f "$MACOS_CODESIGN_ENTITLEMENTS" || { echo "::error::MACOS_CODESIGN_ENTITLEMENTS=$MACOS_CODESIGN_ENTITLEMENTS not found"; exit 1; }
  ents_args=(--entitlements "$MACOS_CODESIGN_ENTITLEMENTS")
elif [ "${MACOS_CODESIGN_DISABLE_LIBRARY_VALIDATION:-}" = "1" ]; then
  ent="$(mktemp -d)/disable-library-validation.entitlements"
  printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>' > "$ent"
  ents_args=(--entitlements "$ent")
fi

id_args=()
if [ -n "${MACOS_CODESIGN_IDENTIFIER:-}" ]; then
  id_args=(--identifier "$MACOS_CODESIGN_IDENTIFIER")
fi

echo "macos-codesign: signing $bin ($target)"
# ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty — safe under `set -u`
# on the macOS runner's bash 3.2, where a bare "${arr[@]}" on an empty array aborts.
codesign --force --options runtime --timestamp ${ents_args[@]+"${ents_args[@]}"} ${id_args[@]+"${id_args[@]}"} -s "$MACOS_SIGN_IDENTITY" "$bin"
codesign --verify --strict --verbose=2 "$bin"
actual_team="$(codesign -dvv "$bin" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n1)"
if [ "$actual_team" != "$TEAM_ID" ]; then
  echo "::error::signed Darwin binary $bin has TeamIdentifier '$actual_team', expected '$TEAM_ID'"
  exit 1
fi

echo "macos-codesign: notarizing $bin"
zip="$(mktemp -d)/$(basename "$bin").zip"
ditto -c -k "$bin" "$zip"
# notarytool submit --wait exits 0 even on an Invalid result, so capture the JSON and
# FAIL LOUD unless status == Accepted, dumping the per-issue log (the only place the
# rejection reason appears).
out="$(mktemp -d)/notary.json"
# notarytool's submit/upload is the flakiest step (network, Apple 5xx, timeout); the release
# only publishes after notarization succeeds, so a clean retry is safe. Retry the submit up to
# 3x with backoff. A SUCCESSFUL submit that returns a non-Accepted status is a terminal verdict
# on the binary, not a hiccup — that is handled below (fail loud), never retried.
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
    echo "::error::notarytool submit failed for $bin after 3 attempts"; exit 1
  fi
  echo "::warning::notarytool submit failed for $bin (attempt $attempt/3); retrying in $((attempt * 30))s"
  sleep "$((attempt * 30))"
  attempt=$((attempt + 1))
done
cat "$out"
sid="$(plutil -extract id raw -o - "$out")"
if [ "$(plutil -extract status raw -o - "$out")" != "Accepted" ]; then
  xcrun notarytool log "$sid" \
    --key "$MACOS_NOTARY_KEY_FILE" --key-id "$MACOS_NOTARY_KEY_ID" --issuer "$MACOS_NOTARY_ISSUER" || true
  echo "::error::notarization not Accepted for $bin (submission $sid)"; exit 1
fi
# A bare Mach-O can't be stapled; notarization is recorded against its cdhash and
# verified online by Gatekeeper. (.app bundles are stapled by the macos-app-cask action.)
