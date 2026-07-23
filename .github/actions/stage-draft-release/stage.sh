#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

load_release_state() {
  local release_id="$1" expected_draft="$2" output="$3"
  gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" > "$output" \
    || fail "release $release_id cannot be read by exact ID"
  [ "$(jq -r .id "$output")" = "$release_id" ] || fail "release identity changed"
  [ "$(jq -r .tag_name "$output")" = "$RELEASE_TAG" ] || fail "release ID changed tag"
  [ "$(jq -r .draft "$output")" = "$expected_draft" ] || fail "release draft state changed"
  [ "$(jq -r .prerelease "$output")" = "$RELEASE_PRERELEASE" ] \
    || fail "release prerelease state changed"
}

recover_created_release() {
  local attempt=1
  local recovered="$RUNNER_TEMP/recovered-release-matches"
  local count recovered_id recovered_draft recovered_prerelease
  while [ "$attempt" -le "$RELEASE_RECOVERY_ATTEMPTS" ]; do
    if gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
      | jq -r --arg tag "$RELEASE_TAG" \
          '.[] | select(.tag_name == $tag) | [.id, .draft, .prerelease] | @tsv' \
          > "$recovered"; then
      count="$(wc -l < "$recovered" | tr -d ' ')"
      [ "$count" -le 1 ] || fail "tag $RELEASE_TAG resolves to multiple releases during recovery"
      if [ "$count" = 1 ]; then
        IFS=$'\t' read -r recovered_id recovered_draft recovered_prerelease < "$recovered"
        [[ "$recovered_id" =~ ^[0-9]+$ ]] || fail "recovered release ID is not numeric"
        [ "$recovered_prerelease" = "$RELEASE_PRERELEASE" ] \
          || fail "recovered release prerelease state conflicts with the request"
        [ "$recovered_draft" = true ] \
          || fail "public release conflicts with lost create response for tag $RELEASE_TAG"
        printf '%s\n' "$recovered_id"
        return 0
      fi
    fi
    if [ "$attempt" -lt "$RELEASE_RECOVERY_ATTEMPTS" ]; then
      sleep "$RELEASE_RECOVERY_DELAY_SECONDS"
    fi
    attempt=$((attempt + 1))
  done
  fail "lost create response for tag $RELEASE_TAG could not be recovered"
}

test -n "${GH_TOKEN:-}" || fail "token is required"
test -n "${GITHUB_REPOSITORY:-}" || fail "GITHUB_REPOSITORY is required"
test -n "${RELEASE_TAG:-}" || fail "tag is required"
test -f "${ASSET_MANIFEST:-}" || fail "asset manifest is missing"
case "${RELEASE_PRERELEASE:-}" in
  true|false) ;;
  *) fail "prerelease must be true or false" ;;
esac
RELEASE_RECOVERY_ATTEMPTS="${RELEASE_RECOVERY_ATTEMPTS:-6}"
RELEASE_RECOVERY_DELAY_SECONDS="${RELEASE_RECOVERY_DELAY_SECONDS:-1}"
[[ "$RELEASE_RECOVERY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
  || fail "release recovery attempts must be a positive integer"
[[ "$RELEASE_RECOVERY_DELAY_SECONDS" =~ ^[0-9]+$ ]] \
  || fail "release recovery delay must be a non-negative integer"

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
  create_succeeded=false
  if gh api --method POST "repos/${GITHUB_REPOSITORY}/releases" --input "$payload" > "$created"; then
    create_succeeded=true
  fi
  release_id="$(jq -er '.id | select(type == "number") | tostring' "$created" 2>/dev/null || true)"
  if [ "$create_succeeded" != true ] || [[ ! "$release_id" =~ ^[0-9]+$ ]]; then
    release_id="$(recover_created_release)"
  fi
  draft=true
  prerelease="$RELEASE_PRERELEASE"
else
  IFS=$'\t' read -r release_id draft prerelease < "$matches"
fi

[[ "$release_id" =~ ^[0-9]+$ ]] || fail "release ID is not numeric"
[ "$prerelease" = "$RELEASE_PRERELEASE" ] \
  || fail "release $release_id prerelease state does not match the requested state"

state="$RUNNER_TEMP/release-state.json"
load_release_state "$release_id" "$draft" "$state"

if [ "$draft" = true ]; then
  load_release_state "$release_id" true "$state"
  upload_url="$(jq -r '.upload_url | sub("\\{.*$"; "")' "$state")"
  [[ "$upload_url" == https://uploads.github.com/* ]] || fail "release upload URL is invalid"
  asset_ids="$RUNNER_TEMP/release-asset-ids"
  gh api --paginate "repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?per_page=100" \
    | jq -r '.[].id' > "$asset_ids"
  while IFS= read -r asset_id || [ -n "$asset_id" ]; do
    [ -n "$asset_id" ] || continue
    load_release_state "$release_id" true "$state"
    gh api --method DELETE "repos/${GITHUB_REPOSITORY}/releases/assets/${asset_id}"
  done < "$asset_ids"

  for asset in "${assets[@]}"; do
    load_release_state "$release_id" true "$state"
    name="$(basename "$asset")"
    encoded="$(jq -rn --arg value "$name" '$value | @uri')"
    gh api --method POST \
      -H 'Content-Type: application/octet-stream' \
      --input "$asset" \
      "${upload_url}?name=${encoded}" \
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
