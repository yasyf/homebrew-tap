#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "::error title=Release tag rejected::$*" >&2
  exit 1
}

TAG="${GITHUB_REF_NAME:-}"
SHA="${GITHUB_SHA:-}"
MANIFEST="${PLUGIN_MANIFEST:-}"

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] ||
  fail "GITHUB_REF_NAME must be a semantic release tag"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA must be one exact commit"

git fetch --no-tags --quiet origin main
git merge-base --is-ancestor "$SHA" FETCH_HEAD ||
  fail "$TAG points at $SHA, which is not on main"

raw_lines="$(git ls-remote --refs origin "refs/tags/$TAG")"
[[ "$(grep -c . <<<"$raw_lines" || true)" == 1 ]] ||
  fail "origin must advertise exactly one refs/tags/$TAG object"
read -r remote_tag_object remote_ref <<<"$raw_lines"
[[ "$remote_ref" == "refs/tags/$TAG" ]] || fail "origin returned an inexact tag ref"

peeled_lines="$(git ls-remote origin "refs/tags/$TAG^{}")"
if [[ -n "$peeled_lines" ]]; then
  read -r remote_commit _ <<<"$peeled_lines"
else
  remote_commit="$remote_tag_object"
fi
[[ "$remote_commit" == "$SHA" ]] ||
  fail "origin advertises $TAG at $remote_commit, but this run checked out $SHA"

git fetch --force --no-tags --quiet origin "refs/tags/$TAG:refs/tags/$TAG"
local_tag_object="$(git rev-parse "refs/tags/$TAG")"
[[ "$local_tag_object" == "$remote_tag_object" ]] ||
  fail "$TAG moved while its release gate was running"
read -r local_object_type local_target local_target_type <<<"$(
  git for-each-ref --format='%(objecttype) %(object) %(type)' "refs/tags/$TAG"
)"
if [[ "$local_object_type" == tag ]]; then
  [[ "$local_target_type" == commit ]] ||
    fail "$TAG is a tag object pointing at a $local_target_type, not a commit"
  local_commit="$local_target"
else
  local_commit="$local_tag_object"
fi
[[ "$local_commit" == "$SHA" ]] ||
  fail "the fetched $TAG resolves to $local_commit, but this run checked out $SHA"

if [[ -n "$MANIFEST" ]]; then
  [[ -f "$MANIFEST" ]] || fail "plugin manifest $MANIFEST does not exist"
  version="$(jq -er '.version | select(type == "string" and length > 0)' "$MANIFEST" 2>/dev/null)" ||
    fail "plugin manifest $MANIFEST has no top-level string version"
  [[ "$TAG" == "v$version" ]] ||
    fail "$TAG does not match $MANIFEST version v$version"
fi

echo "✓ $TAG names $SHA, an exact commit on main."
