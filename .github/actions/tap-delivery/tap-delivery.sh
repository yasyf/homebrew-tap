#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "tap-delivery: $*" >&2
  exit 1
}

require_identity() {
  case "$DELIVERY_MODE" in
    pack|verify) ;;
    *) fail "mode must be pack or verify" ;;
  esac
  [[ "$DELIVERY_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || fail "repository is invalid"
  [[ "$DELIVERY_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "source SHA is invalid"
  [[ "$DELIVERY_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] \
    || fail "tag is invalid"
  [[ "$DELIVERY_RELEASE_ID" =~ ^[0-9]+$ ]] || fail "release ID is not numeric"
  [[ "$DELIVERY_RUN_ID" =~ ^[0-9]+$ ]] || fail "run ID is not numeric"
  test -n "$DELIVERY_BUNDLE" || fail "bundle is required"
}

assert_plain_tree() {
  root=$1
  label=$2
  test -d "$root" || fail "$label directory is missing"
  if find "$root" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
    fail "$label contains a symlink or special file"
  fi
}

manifest_paths() {
  manifest=$1
  sed -E 's/^[0-9a-f]{64}  //' "$manifest"
}

verify_manifest() {
  bundle=$1
  manifest=$2
  root=$3
  label=$4
  test -s "$bundle/$manifest" || fail "$label checksum manifest is missing or empty"
  expected=$(mktemp "${TMPDIR:-/tmp}/tap-delivery-expected.XXXXXX")
  actual=$(mktemp "${TMPDIR:-/tmp}/tap-delivery-actual.XXXXXX")
  manifest_paths "$bundle/$manifest" | LC_ALL=C sort > "$expected"
  find "$bundle/$root" -type f -print | sed "s|^$bundle/||" | LC_ALL=C sort > "$actual"
  diff -u "$expected" "$actual" || fail "$label file set changed"
  (cd "$bundle" && shasum -a 256 -c "$manifest") \
    || fail "$label bytes changed"
  rm -f "$expected" "$actual"
}

verify_bundle() {
  bundle=$1
  assert_plain_tree "$bundle" bundle
  test -f "$bundle/provenance.json" || fail "provenance is missing"
  expected_top=$(mktemp "${TMPDIR:-/tmp}/tap-delivery-top-expected.XXXXXX")
  actual_top=$(mktemp "${TMPDIR:-/tmp}/tap-delivery-top-actual.XXXXXX")
  printf '%s\n' \
    provenance.json \
    release-assets \
    release-assets.sha256 \
    tap \
    tap.sha256 \
    > "$expected_top"
  find "$bundle" -mindepth 1 -maxdepth 1 -print | sed "s|^$bundle/||" | LC_ALL=C sort > "$actual_top"
  diff -u "$expected_top" "$actual_top" || fail "bundle top-level file set changed"
  rm -f "$expected_top" "$actual_top"

  jq -e \
    --arg repository "$DELIVERY_REPOSITORY" \
    --arg source_sha "$DELIVERY_SOURCE_SHA" \
    --arg tag "$DELIVERY_TAG" \
    --arg release_id "$DELIVERY_RELEASE_ID" \
    --arg run_id "$DELIVERY_RUN_ID" '
      type == "object" and
      keys == ["release_id", "repository", "run_id", "schema", "source_sha", "tag"] and
      .schema == 1 and
      .repository == $repository and
      .source_sha == $source_sha and
      .tag == $tag and
      .release_id == $release_id and
      .run_id == $run_id
    ' "$bundle/provenance.json" >/dev/null || fail "provenance does not match this release"

  assert_plain_tree "$bundle/release-assets" "release assets"
  assert_plain_tree "$bundle/tap" "tap delivery"
  verify_manifest "$bundle" release-assets.sha256 release-assets "release-assets"
  verify_manifest "$bundle" tap.sha256 tap tap
}

pack_bundle() {
  test -n "$DELIVERY_RELEASE_DIR" || fail "release-dir is required in pack mode"
  test -n "$DELIVERY_TAP_DIR" || fail "tap-dir is required in pack mode"
  assert_plain_tree "$DELIVERY_RELEASE_DIR" "release source"
  assert_plain_tree "$DELIVERY_TAP_DIR" "tap source"
  test ! -e "$DELIVERY_BUNDLE" || fail "bundle already exists"
  mkdir -p "$DELIVERY_BUNDLE/release-assets" "$DELIVERY_BUNDLE/tap"

  release_count=0
  while IFS= read -r source; do
    name=${source##*/}
    [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "unsafe release asset name '$name'"
    cp "$source" "$DELIVERY_BUNDLE/release-assets/$name"
    release_count=$((release_count + 1))
  done < <(find "$DELIVERY_RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f -print | LC_ALL=C sort)
  [ "$release_count" -gt 0 ] || fail "release source is empty"

  tap_count=0
  while IFS= read -r source; do
    relative=${source#"$DELIVERY_TAP_DIR"/}
    [[ "$relative" =~ ^(Casks|Formula)/[A-Za-z0-9._+-]+\.rb$ ]] \
      || fail "unsafe tap delivery path '$relative'"
    mkdir -p "$DELIVERY_BUNDLE/tap/${relative%/*}"
    cp "$source" "$DELIVERY_BUNDLE/tap/$relative"
    tap_count=$((tap_count + 1))
  done < <(find "$DELIVERY_TAP_DIR" -type f -print | LC_ALL=C sort)
  [ "$tap_count" -gt 0 ] || fail "tap source is empty"

  jq -n -S \
    --arg repository "$DELIVERY_REPOSITORY" \
    --arg source_sha "$DELIVERY_SOURCE_SHA" \
    --arg tag "$DELIVERY_TAG" \
    --arg release_id "$DELIVERY_RELEASE_ID" \
    --arg run_id "$DELIVERY_RUN_ID" \
    '{schema: 1, repository: $repository, source_sha: $source_sha, tag: $tag, release_id: $release_id, run_id: $run_id}' \
    > "$DELIVERY_BUNDLE/provenance.json"
  (
    cd "$DELIVERY_BUNDLE"
    find release-assets -type f -print | LC_ALL=C sort | xargs shasum -a 256 > release-assets.sha256
    find tap -type f -print | LC_ALL=C sort | xargs shasum -a 256 > tap.sha256
  )
  verify_bundle "$DELIVERY_BUNDLE"
}

require_identity
case "$DELIVERY_MODE" in
  pack) pack_bundle ;;
  verify) verify_bundle "$DELIVERY_BUNDLE" ;;
esac
