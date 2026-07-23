#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "go-release-manifest: $*" >&2
  exit 1
}

[ "$#" -eq 2 ] || fail "usage: $0 ARTIFACTS_JSON OUTPUT"
artifacts="$1"
output="$2"
test -f "$artifacts" || fail "artifacts file '$artifacts' is missing"
jq -e 'type == "array"' "$artifacts" >/dev/null || fail "artifacts JSON is not an array"

rows="${output}.rows.$$"
manifest="${output}.tmp.$$"
names="${output}.names.$$"
trap 'rm -f -- "$rows" "$manifest" "$names"' EXIT
mkdir -p "$(dirname "$output")"
: > "$manifest"
: > "$names"

jq -r '
  def uploadable:
    . as $type |
    [
      "Archive", "File", "Source", "Makeself Package", "Linux Package",
      "MSIX", "Flatpak", "Source RPM", "SBOM", "Wheel", "Source Dist",
      "Checksum", "Signature", "Certificate"
    ] | index($type) != null;
  .[] |
  .type as $type |
  if ($type | uploadable) then
    ["release", $type, .name, .path]
  elif $type == "Binary" and (.path | test("^dist/[^/]+$")) then
    ["release", $type, .name, .path]
  elif $type == "Binary" or $type == "Metadata" then
    ["local", $type, .name, .path]
  elif $type == "Homebrew Cask" or $type == "Homebrew Formula" then
    ["homebrew", $type, .name, .path]
  else
    ["unsupported", $type, .name, .path]
  end | @tsv
' "$artifacts" > "$rows"

checksum_count=0
release_count=0
while IFS=$'\t' read -r class type name path || [ -n "${class:-}" ]; do
  [ -n "$class" ] || continue
  case "$path" in
    dist/*) ;;
    *) fail "$type artifact '$name' escapes dist: $path" ;;
  esac
  test -f "$path" || fail "$type artifact '$name' is missing at $path"

  case "$class" in
    release)
      [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "unsafe release artifact name '$name'"
      [ "$name" = "$(basename "$path")" ] \
        || fail "$type artifact name '$name' differs from path basename '$(basename "$path")'"
      printf '%s\n' "$path" >> "$manifest"
      printf '%s\n' "$name" >> "$names"
      release_count=$((release_count + 1))
      if [ "$type" = Checksum ]; then checksum_count=$((checksum_count + 1)); fi
      ;;
    local)
      ;;
    homebrew)
      [[ "$path" == dist/homebrew/*.rb || "$path" == dist/homebrew/*/*.rb ]] \
        || fail "$type artifact '$name' is outside dist/homebrew: $path"
      ;;
    unsupported)
      fail "unsupported GoReleaser artifact class '$type' for '$name'"
      ;;
    *)
      fail "internal classification error for '$name'"
      ;;
  esac
done < "$rows"

[ "$release_count" -gt 0 ] || fail "no release artifacts were classified"
[ "$checksum_count" -gt 0 ] || fail "release has no checksum artifact"
[ "$(sort -u "$names" | wc -l | tr -d ' ')" = "$release_count" ] \
  || fail "release artifact basenames are not unique"

sort -o "$manifest" "$manifest"
mv "$manifest" "$output"
