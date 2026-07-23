#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

assert_unique_release() {
  expected_draft="$1"
  current="$RUNNER_TEMP/publish-current-release-matches"
  gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    | jq -r --arg tag "$RELEASE_TAG" \
        '.[] | select(.tag_name == $tag) | [.id, .draft] | @tsv' \
        > "$current"
  [ "$(wc -l < "$current" | tr -d ' ')" = 1 ] \
    || fail "tag $RELEASE_TAG does not resolve to exactly one release"
  IFS=$'\t' read -r current_id current_draft < "$current"
  [ "$current_id" = "$RELEASE_ID" ] || fail "release identity changed"
  [ "$current_draft" = "$expected_draft" ] || fail "release draft state changed"
}

test -n "${GH_TOKEN:-}" || fail "token is required"
test -n "${GITHUB_REPOSITORY:-}" || fail "GITHUB_REPOSITORY is required"
[[ "${RELEASE_ID:-}" =~ ^[0-9]+$ ]] || fail "release ID is not numeric"
test -n "${RELEASE_TAG:-}" || fail "tag is required"
test -f "${ASSET_MANIFEST:-}" || fail "asset manifest is missing"
case "${RELEASE_PRERELEASE:-}" in
  true|false) ;;
  *) fail "prerelease must be true or false" ;;
esac
case "${RELEASE_MAKE_LATEST:-}" in
  true|false) ;;
  *) fail "make-latest must be true or false" ;;
esac
[ "$RELEASE_PRERELEASE" != true ] || [ "$RELEASE_MAKE_LATEST" != true ] \
  || fail "a prerelease cannot be the latest stable release"

assets=()
expected="$RUNNER_TEMP/publish-expected-assets"
: > "$expected"
while IFS= read -r asset || [ -n "$asset" ]; do
  [ -n "$asset" ] || continue
  test -f "$asset" || fail "release asset '$asset' is missing"
  name="$(basename "$asset")"
  [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "unsafe release asset name '$name'"
  assets+=("$asset")
  printf '%s\n' "$name" >> "$expected"
done < "$ASSET_MANIFEST"
[ "${#assets[@]}" -gt 0 ] || fail "asset manifest is empty"
[ "$(sort -u "$expected" | wc -l | tr -d ' ')" = "${#assets[@]}" ] \
  || fail "asset basenames must be unique"
sort -o "$expected" "$expected"

state="$RUNNER_TEMP/publish-release-state.json"
gh api "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}" > "$state"
[ "$(jq -r .tag_name "$state")" = "$RELEASE_TAG" ] || fail "release ID does not match tag"
[ "$(jq -r .prerelease "$state")" = "$RELEASE_PRERELEASE" ] \
  || fail "release prerelease state does not match"
assert_unique_release "$(jq -r .draft "$state")"

rows="$RUNNER_TEMP/publish-release-asset-rows"
actual="$RUNNER_TEMP/publish-actual-assets"
gh api --paginate "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets?per_page=100" \
  | jq -r '.[] | [.id, .name] | @tsv' > "$rows"
cut -f2 "$rows" | sort > "$actual"
diff -u "$expected" "$actual" || fail "release does not contain the exact asset set"

for asset in "${assets[@]}"; do
  name="$(basename "$asset")"
  asset_id="$(awk -F '\t' -v name="$name" '$2 == name { print $1 }' "$rows")"
  [[ "$asset_id" =~ ^[0-9]+$ ]] || fail "asset ID for '$name' is missing"
  downloaded="$RUNNER_TEMP/publish-${RELEASE_ID}-${name}"
  gh api -H 'Accept: application/octet-stream' \
    "repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}" > "$downloaded"
  cmp "$asset" "$downloaded" || fail "downloaded asset '$name' differs"
done

if [ "$(jq -r .draft "$state")" = true ]; then
  assert_unique_release true
  payload="$RUNNER_TEMP/publish-release.json"
  jq -n \
    --argjson prerelease "$RELEASE_PRERELEASE" \
    --arg make_latest "$RELEASE_MAKE_LATEST" \
    '{draft: false, prerelease: $prerelease, make_latest: $make_latest}' > "$payload"
  published="$RUNNER_TEMP/published-release.json"
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}" \
    --input "$payload" > "$published"
else
  published="$state"
fi

[ "$(jq -r .id "$published")" = "$RELEASE_ID" ] || fail "published release ID changed"
[ "$(jq -r .tag_name "$published")" = "$RELEASE_TAG" ] || fail "published release tag changed"
[ "$(jq -r .draft "$published")" = false ] || fail "release remains a draft"
[ "$(jq -r .prerelease "$published")" = "$RELEASE_PRERELEASE" ] \
  || fail "published prerelease state changed"
echo "url=$(jq -r .html_url "$published")" >> "$GITHUB_OUTPUT"
