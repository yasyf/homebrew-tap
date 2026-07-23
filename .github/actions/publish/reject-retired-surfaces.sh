#!/usr/bin/env bash
set -euo pipefail

root=${1:?publish root is required}

fail() {
  echo "::error::$*" >&2
  exit 1
}

reject_content() {
  label=$1
  regex=$2
  shift 2
  roots=()
  for path in "$@"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || roots+=("$path")
  done
  [ "${#roots[@]}" -gt 0 ] || return 0
  if grep -RIlE "$regex" "${roots[@]}" >/dev/null 2>&1; then
    fail "$label exists"
  else
    status=$?
    [ "$status" -eq 1 ] || fail "could not scan for $label"
  fi
}

for path in \
  Casks/fusekit-holder.rb \
  Casks/cc-notes-holder.rb \
  Casks/cc-notes-helper.rb \
  Casks/cc-pool-status.rb; do
  [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ] \
    || fail "retired standalone runtime file exists: $path"
done

reject_content \
  "retired standalone FuseKit runtime content" \
  'fusekit-holder|com\.yasyf\.fusekit-holder|cc-notes-holder|CCNotesHolder\.app|cc-notes-helper|com\.yasyf\.cc-notes\.helper|CCNotesHelper\.app' \
  "$root/Casks" "$root/Formula"
reject_content \
  "retired standalone CCPoolStatus cask content" \
  'cc-pool-status|CCPoolStatus\.app|com\.yasyf\.cc-pool\.status' \
  "$root/Casks"
