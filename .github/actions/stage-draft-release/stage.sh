#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

assert_unique_release() {
  expected_id="$1"
  expected_draft="$2"
  current="$RUNNER_TEMP/current-release-matches"
  gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    | jq -r --arg tag "$RELEASE_TAG" \
        '.[] | select(.tag_name == $tag) | [.id, .draft] | @tsv' \
        > "$current"
  [ "$(wc -l < "$current" | tr -d ' ')" = 1 ] \
    || fail "tag $RELEASE_TAG does not resolve to exactly one release"
  IFS=$'\t' read -r current_id current_draft < "$current"
  [ "$current_id" = "$expected_id" ] || fail "release identity changed"
  [ "$current_draft" = "$expected_draft" ] || fail "release draft state changed"
}

test -n "${GH_TOKEN:-}" || fail "token is required"
test -n "${GITHUB_REPOSITORY:-}" || fail "GITHUB_REPOSITORY is required"
test -n "${RELEASE_TAG:-}" || fail "tag is required"
test -f "${ASSET_MANIFEST:-}" || fail "asset manifest is missing"
case "${RELEASE_PRERELEASE:-}" in
  true|false) ;;
  *) fail "prerelease must be true or false" ;;
esac

assets=()
names="$RUNNER_TEMP/release-asset-names"
: > "$names"
while IFS= read -r asset || [ -n "$asset" ]; do
  [ -n "$asset" ] || continue
  test -f "$asset" || fail "release asset '$asset' is missing"
  name="$(basename "$asset")"
  [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "unsafe release asset name '$name'"
  assets+=("$asset")
  printf '%s\n' "$name" >> "$names"
done < "$ASSET_MANIFEST"
[ "${#assets[@]}" -gt 0 ] || fail "asset manifest is empty"
[ "$(sort -u "$names" | wc -l | tr -d ' ')" = "${#assets[@]}" ] \
  || fail "asset basenames must be unique"
sort -o "$names" "$names"

matches="$RUNNER_TEMP/release-matches"
gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
  | jq -r --arg tag "$RELEASE_TAG" \
      '.[] | select(.tag_name == $tag) | [.id, .draft, .prerelease] | @tsv' \
      > "$matches"
count="$(wc -l < "$matches" | tr -d ' ')"
[ "$count" -le 1 ] || fail "multiple releases exist for tag $RELEASE_TAG"

if [ "$count" = 0 ]; then
  title="${RELEASE_TITLE:-$RELEASE_TAG}"
  payload="$RUNNER_TEMP/create-release.json"
  jq -n \
    --arg tag "$RELEASE_TAG" \
    --arg title "$title" \
    --argjson prerelease "$RELEASE_PRERELEASE" \
    '{tag_name: $tag, name: $title, draft: true, prerelease: $prerelease, generate_release_notes: true}' \
    > "$payload"
  created="$RUNNER_TEMP/created-release.json"
  gh api --method POST "repos/${GITHUB_REPOSITORY}/releases" --input "$payload" > "$created"
  release_id="$(jq -r .id "$created")"
  draft=true
  prerelease="$(jq -r .prerelease "$created")"
else
  IFS=$'\t' read -r release_id draft prerelease < "$matches"
fi

[[ "$release_id" =~ ^[0-9]+$ ]] || fail "release ID is not numeric"
[ "$prerelease" = "$RELEASE_PRERELEASE" ] \
  || fail "release $release_id prerelease state does not match the requested state"

state="$RUNNER_TEMP/release-state.json"
gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" > "$state"
[ "$(jq -r .tag_name "$state")" = "$RELEASE_TAG" ] || fail "release ID changed tag"
[ "$(jq -r .draft "$state")" = "$draft" ] || fail "release draft state changed"
assert_unique_release "$release_id" "$draft"

if [ "$draft" = true ]; then
  assert_unique_release "$release_id" true
  asset_ids="$RUNNER_TEMP/release-asset-ids"
  gh api --paginate "repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?per_page=100" \
    | jq -r '.[].id' > "$asset_ids"
  while IFS= read -r asset_id || [ -n "$asset_id" ]; do
    [ -n "$asset_id" ] || continue
    assert_unique_release "$release_id" true
    gh api --method DELETE "repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}"
  done < "$asset_ids"

  for asset in "${assets[@]}"; do
    assert_unique_release "$release_id" true
    name="$(basename "$asset")"
    encoded="$(jq -rn --arg value "$name" '$value | @uri')"
    gh api --method POST \
      -H 'Content-Type: application/octet-stream' \
      --input "$asset" \
      "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?name=${encoded}" \
      > /dev/null
  done
fi

rows="$RUNNER_TEMP/release-asset-rows"
actual="$RUNNER_TEMP/actual-release-assets"
gh api --paginate "repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?per_page=100" \
  | jq -r '.[] | [.id, .name] | @tsv' > "$rows"
cut -f2 "$rows" | sort > "$actual"
diff -u "$names" "$actual" || fail "release does not contain the exact asset set"

download_dir="$RUNNER_TEMP/exact-release-${release_id}"
rm -rf "$download_dir"
mkdir -p "$download_dir"
for asset in "${assets[@]}"; do
  name="$(basename "$asset")"
  asset_id="$(awk -F '\t' -v name="$name" '$2 == name { print $1 }' "$rows")"
  [[ "$asset_id" =~ ^[0-9]+$ ]] || fail "asset ID for '$name' is missing"
  gh api -H 'Accept: application/octet-stream' \
    "repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}" \
    > "$download_dir/$name"
  cmp "$asset" "$download_dir/$name" || fail "downloaded asset '$name' differs"
done

{
  echo "release_id=$release_id"
  echo "download_dir=$download_dir"
  if [ "$draft" = true ]; then
    echo "already_published=false"
  else
    echo "already_published=true"
  fi
} >> "$GITHUB_OUTPUT"
