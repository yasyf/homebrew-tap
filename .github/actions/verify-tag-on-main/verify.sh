#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "::error title=Release tag rejected::$*" >&2
  exit 1
}

TAG="${GITHUB_REF_NAME:-}"
SHA="${GITHUB_SHA:-}"
MANIFEST="${PLUGIN_MANIFEST:-}"
TRUSTED_KEY="${TRUSTED_RELEASE_KEY:-}"
TRUSTED_FINGERPRINT="${TRUSTED_RELEASE_FINGERPRINT:-}"

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] ||
  fail "GITHUB_REF_NAME must be a semantic release tag"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "GITHUB_SHA must be one exact commit"
[[ -s "$TRUSTED_KEY" ]] || fail "trusted release public key is missing"
[[ "$TRUSTED_FINGERPRINT" =~ ^[0-9A-F]{40}$ ]] ||
  fail "trusted release fingerprint is invalid"

git fetch --no-tags --quiet origin main
git merge-base --is-ancestor "$SHA" FETCH_HEAD ||
  fail "$TAG points at $SHA, which is not on main"

raw_lines="$(git ls-remote --refs origin "refs/tags/$TAG")"
[[ "$(grep -c . <<<"$raw_lines" || true)" == 1 ]] ||
  fail "origin must advertise exactly one refs/tags/$TAG object"
read -r remote_tag_object remote_ref <<<"$raw_lines"
[[ "$remote_ref" == "refs/tags/$TAG" ]] || fail "origin returned an inexact tag ref"

peeled_lines="$(git ls-remote origin "refs/tags/$TAG^{}")"
[[ "$(grep -c . <<<"$peeled_lines" || true)" == 1 ]] ||
  fail "$TAG must be one annotated tag object"
read -r remote_commit peeled_ref <<<"$peeled_lines"
[[ "$peeled_ref" == "refs/tags/$TAG^{}" ]] || fail "origin returned an inexact peeled ref"
[[ "$remote_commit" == "$SHA" ]] ||
  fail "$TAG peels to $remote_commit, but this run checked out $SHA"

git fetch --force --no-tags --quiet origin "refs/tags/$TAG:refs/tags/$TAG"
local_tag_object="$(git rev-parse "refs/tags/$TAG")"
[[ "$local_tag_object" == "$remote_tag_object" ]] ||
  fail "$TAG moved while its release gate was running"
[[ "$(git cat-file -t "refs/tags/$TAG")" == tag ]] ||
  fail "$TAG must be an annotated tag object"

tag_target="$(git cat-file -p "refs/tags/$TAG" | awk '$1 == "object" { print $2; exit }')"
tag_target_type="$(git cat-file -p "refs/tags/$TAG" | awk '$1 == "type" { print $2; exit }')"
[[ "$tag_target_type" == commit ]] || fail "$TAG must directly name one commit"
[[ "$tag_target" == "$SHA" ]] ||
  fail "$TAG directly names $tag_target, but this run checked out $SHA"

keyring="$(mktemp -d)"
trap 'rm -rf "$keyring"' EXIT
chmod 700 "$keyring"
gpg --batch --homedir "$keyring" --import "$TRUSTED_KEY" >/dev/null 2>&1 ||
  fail "trusted release public key cannot be imported"

status="$(GNUPGHOME="$keyring" git verify-tag --raw "refs/tags/$TAG" 2>&1)" ||
  fail "$TAG signature verification failed"
valid_signatures="$(
  awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $3 " " $NF }' <<<"$status"
)"
[[ "$(grep -c . <<<"$valid_signatures" || true)" == 1 ]] ||
  fail "$TAG must contain exactly one valid signature"
read -r signing_fingerprint primary_fingerprint <<<"$valid_signatures"
if [[ "$signing_fingerprint" != "$TRUSTED_FINGERPRINT" &&
      "$primary_fingerprint" != "$TRUSTED_FINGERPRINT" ]]; then
  fail "$TAG is not signed by trusted key $TRUSTED_FINGERPRINT"
fi

if [[ -n "$MANIFEST" ]]; then
  [[ -f "$MANIFEST" ]] || fail "plugin manifest $MANIFEST does not exist"
  version="$(jq -er '.version | select(type == "string" and length > 0)' "$MANIFEST" 2>/dev/null)" ||
    fail "plugin manifest $MANIFEST has no top-level string version"
  [[ "$TAG" == "v$version" ]] ||
    fail "$TAG does not match $MANIFEST version v$version"
fi

echo "✓ $TAG is an exact main commit signed by $TRUSTED_FINGERPRINT."
