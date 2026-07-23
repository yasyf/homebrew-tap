#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "go-release-manifest: $*" >&2
  exit 1
}

sidecar_attaches() {
  local type="$1" sidecar="$2" target="$3"
  case "$type" in
    Signature)
      case "$sidecar" in
        "$target".sig|"$target".sigstore.json|"$target".asc|"$target".minisig|"${target}_sig") return 0 ;;
      esac
      ;;
    Certificate)
      case "$sidecar" in
        "$target".pem|"$target".crt|"$target".cert) return 0 ;;
      esac
      ;;
    SBOM)
      case "$sidecar" in
        "$target".sbom|"$target".sbom.json|"$target".spdx|"$target".spdx.json|"$target".cdx.json|"$target".cyclonedx.json) return 0 ;;
      esac
      ;;
    *) fail "internal sidecar type '$type'" ;;
  esac
  return 1
}

[ "$#" -eq 2 ] || fail "usage: $0 ARTIFACTS_JSON OUTPUT"
artifacts="$1"
output="$2"
test -f "$artifacts" || fail "artifacts file '$artifacts' is missing"
jq -e '
  type == "array" and all(.[];
    type == "object" and
    ((.type | type) == "string") and
    ((.name | type) == "string") and
    ((.path | type) == "string") and
    ([.type, .name, .path] | all(test("[\\t\\r\\n]") | not))
  )
' "$artifacts" >/dev/null || fail "artifacts JSON is not a well-formed artifact array"

rows="${output}.rows.$$"
candidates="${output}.candidates.$$"
checksums="${output}.checksums.$$"
sidecars="${output}.sidecars.$$"
references="${output}.references.$$"
primary_names="${output}.primary-names.$$"
release_rows="${output}.release-rows.$$"
manifest="${output}.tmp.$$"
materialized="${output}.files"
trap 'rm -f -- "$rows" "$candidates" "$checksums" "$sidecars" "$references" "$primary_names" "$release_rows" "$manifest"' EXIT
mkdir -p "$(dirname "$output")"
[ ! -e "$materialized" ] && [ ! -L "$materialized" ] \
  || fail "materialized asset directory '$materialized' already exists"
mkdir "$materialized"
: > "$candidates"
: > "$checksums"
: > "$sidecars"
: > "$references"
: > "$primary_names"
: > "$release_rows"
: > "$manifest"

jq -r '
  def file_artifact:
    . as $type |
    [
      "Archive", "Binary", "File", "Universal Binary", "Source",
      "Makeself Package", "Linux Package", "MSIX", "Flatpak", "Source RPM",
      "Wheel", "Source Dist", "App Bundle", "DMG", "MacOS Package", "MSI",
      "NPM Package", "Snap", "Krew Plugin Manifest", "Scoop Manifest",
      "PKGBUILD", "SRCINFO", "Chocolatey", "C Header", "C Archive Library",
      "C Shared Library", "Winget Manifest", "Nixpkg", "Metadata", "Checksum",
      "Signature", "Certificate", "SBOM"
    ] | index($type) != null;
  .[] |
  .type as $type |
  if $type == "Homebrew Cask" or $type == "Homebrew Formula" then
    ["homebrew", $type, .name, .path]
  elif ($type | file_artifact) then
    ["artifact", $type, .name, .path]
  else
    ["unsupported", $type, .name, .path]
  end | @tsv
' "$artifacts" > "$rows"

dist_root="$(cd dist 2>/dev/null && pwd -P)" || fail "dist directory is missing"
while IFS=$'\t' read -r class type name path || [ -n "${class:-}" ]; do
  [ -n "$class" ] || continue
  case "$path" in
    dist/*) ;;
    *) fail "$type artifact '$name' escapes dist: $path" ;;
  esac
  case "/$path/" in
    *'/../'*|*'/./'*|*'//') fail "$type artifact '$name' has a non-canonical path: $path" ;;
  esac
  test -f "$path" || fail "$type artifact '$name' is missing at $path"
  real_path="$(realpath "$path")"
  case "$real_path" in
    "$dist_root"/*) ;;
    *) fail "$type artifact '$name' resolves outside dist: $path" ;;
  esac

  [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] \
    || fail "unsafe artifact name '$name' at $path"

  case "$class" in
    artifact)
      printf '%s\t%s\t%s\n' "$name" "$path" "$type" >> "$candidates"
      case "$type" in
        Checksum)
          printf '%s\t%s\n' "$name" "$path" >> "$checksums"
          ;;
        Signature|Certificate|SBOM)
          printf '%s\t%s\t%s\n' "$type" "$name" "$path" >> "$sidecars"
          ;;
      esac
      ;;
    homebrew)
      [[ "$path" == dist/homebrew/*.rb || "$path" == dist/homebrew/*/*.rb ]] \
        || fail "$type artifact '$name' is outside dist/homebrew: $path"
      ;;
    unsupported)
      fail "unsupported GoReleaser artifact class '$type' for '$name'"
      ;;
    *) fail "internal classification error for '$name'" ;;
  esac
done < "$rows"

[ -s "$checksums" ] || fail "release has no checksum artifact"
duplicate_checksum="$(sort -u "$checksums" | cut -f1 | sort | uniq -d | sed -n '1p')"
[ -z "$duplicate_checksum" ] \
  || fail "checksum basename '$duplicate_checksum' ambiguously maps to multiple artifact paths"
duplicate_sidecar="$(awk -F '\t' '{print $2 "\t" $3}' "$sidecars" | sort -u | cut -f1 | sort | uniq -d | sed -n '1p')"
[ -z "$duplicate_sidecar" ] \
  || fail "sidecar basename '$duplicate_sidecar' ambiguously maps to multiple artifact paths"

while IFS=$'\t' read -r checksum_name checksum_path || [ -n "${checksum_name:-}" ]; do
  printf '%s\t%s\n' "$checksum_name" "$checksum_path" >> "$release_rows"
  printf '%s\n' "$checksum_name" >> "$primary_names"
  entry_count=0
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    if [[ ! "$line" =~ ^[0-9A-Fa-f]{64}[[:space:]]+\*?([A-Za-z0-9._+-]+)$ ]]; then
      fail "checksum artifact '$checksum_path' has an unsafe or malformed entry at line $line_number"
    fi
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$checksum_name" >> "$references"
    entry_count=$((entry_count + 1))
  done < "$checksum_path"
  [ "$entry_count" -gt 0 ] || fail "checksum artifact '$checksum_path' is empty"
done < <(sort -u "$checksums")

duplicate_reference="$(sort "$references" | uniq -d | sed -n '1p')"
[ -z "$duplicate_reference" ] \
  || fail "checksum artifact '${duplicate_reference#*$'\t'}' references '${duplicate_reference%%$'\t'*}' more than once"

while IFS= read -r referenced_name || [ -n "$referenced_name" ]; do
  [ -n "$referenced_name" ] || continue
  matches="$(awk -F '\t' -v name="$referenced_name" '$1 == name {print $2}' "$candidates" | sort -u)"
  match_count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$match_count" -gt 0 ] \
    || fail "checksum reference '$referenced_name' has no matching artifact path"
  [ "$match_count" -eq 1 ] \
    || fail "checksum reference '$referenced_name' ambiguously matches $match_count artifact paths"
  printf '%s\t%s\n' "$referenced_name" "$matches" >> "$release_rows"
  referenced_type="$(awk -F '\t' -v name="$referenced_name" -v path="$matches" '$1 == name && $2 == path {print $3}' "$candidates" | sort -u)"
  [ "$(printf '%s\n' "$referenced_type" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "checksum reference '$referenced_name' maps to conflicting artifact types"
  case "$referenced_type" in
    Signature|Certificate|SBOM) ;;
    *) printf '%s\n' "$referenced_name" >> "$primary_names" ;;
  esac
done < <(cut -f1 "$references" | sort -u)

sort -u -o "$primary_names" "$primary_names"
while IFS=$'\t' read -r type sidecar_name sidecar_path || [ -n "${type:-}" ]; do
  attachment_count=0
  while IFS= read -r target_name || [ -n "$target_name" ]; do
    [ -n "$target_name" ] || continue
    if sidecar_attaches "$type" "$sidecar_name" "$target_name"; then
      attachment_count=$((attachment_count + 1))
    fi
  done < "$primary_names"
  [ "$attachment_count" -gt 0 ] \
    || fail "$type sidecar '$sidecar_name' is not attached to a primary payload or checksum"
  [ "$attachment_count" -eq 1 ] \
    || fail "$type sidecar '$sidecar_name' ambiguously attaches to $attachment_count release artifacts"
  printf '%s\t%s\n' "$sidecar_name" "$sidecar_path" >> "$release_rows"
done < <(sort -u "$sidecars")

sort -u -o "$release_rows" "$release_rows"
release_count="$(wc -l < "$release_rows" | tr -d ' ')"
[ "$release_count" -gt 1 ] || fail "release has no primary payloads"
duplicate_release_name="$(cut -f1 "$release_rows" | sort | uniq -d | sed -n '1p')"
[ -z "$duplicate_release_name" ] \
  || fail "release asset name '$duplicate_release_name' maps to multiple artifact paths"

workspace="$(pwd -P)"
while IFS=$'\t' read -r name path || [ -n "${name:-}" ]; do
  target="$materialized/$name"
  cp "$workspace/$path" "$target"
  printf '%s\n' "$target" >> "$manifest"
done < "$release_rows"

while IFS=$'\t' read -r checksum_name checksum_path || [ -n "${checksum_name:-}" ]; do
  (
    cd "$materialized"
    shasum -a 256 -c "$checksum_name"
  ) || fail "checksum artifact '$checksum_path' does not verify the exact release manifest"
done < <(sort -u "$checksums")

mv "$manifest" "$output"
