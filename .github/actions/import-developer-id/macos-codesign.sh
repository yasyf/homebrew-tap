#!/usr/bin/env bash
# Developer ID code-sign one macOS build artifact. The single canonical
# copy — dropped on the runner by the import-developer-id action and exported as
# $MACOS_CODESIGN_SCRIPT. Never vendor a copy into a repo.
#
# Invoked per-build by goreleaser's `builds.hooks.post`:
#     bash "$MACOS_CODESIGN_SCRIPT" "{{ .Path }}" "{{ .Target }}"
#
# Why not goreleaser's built-in `notarize` signing (quill)? quill's arm64 signatures get
# SIGKILLed by macOS 15/26 at exec (anchore/quill#566, closed "not planned"). Apple's
# own codesign builds a correct designated requirement from the resolved
# system chain regardless of p12 ordering. So repos that already run on a macOS runner
# (cgo native clang, lipo, an Xcode .app) sign this way; pure-Go repos that release on
# ubuntu keep quill (cheaper, and fine with a full-chain p12).
#
# Non-Darwin targets are ignored. A Darwin target fails closed unless the imported
# Developer ID identity and its derived Team ID are both present and coherent.
#
# Env (set by the import-developer-id action):
#   MACOS_SIGN_IDENTITY        — "Developer ID Application: NAME (TEAMID)"
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

