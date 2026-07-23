#!/usr/bin/env bash
set -euo pipefail

asset="${1:-}"
[[ -n "$asset" ]] || { echo "::error::checksum asset path is required" >&2; exit 1; }
[[ -f "$asset" ]] || { echo "::error::checksum asset '$asset' is not a file" >&2; exit 1; }

filename="${asset##*/}"
sha="$(shasum -a 256 "$asset" | awk '{print $1}')"
printf '%s  %s\n' "$sha" "$filename" > "$asset.sha256"
printf '%s\n' "$sha"
