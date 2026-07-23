#!/usr/bin/env bash
set -euo pipefail

tap_dir=${1:?tap checkout directory is required}
delete_file=${2-}

[ -n "$delete_file" ] || exit 0

fail() {
  echo "::error::delete-file $*" >&2
  exit 1
}

case "$delete_file" in
  /*|\\*|[A-Za-z]:/*|[A-Za-z]:\\*) fail "must be relative to the tap root: $delete_file" ;;
  *'..'*)
    if [[ "$delete_file" =~ (^|/)\.\.(/|$) ]]; then
      fail "must not contain traversal: $delete_file"
    fi
    ;;
esac

case "$delete_file" in
  *\**|*\?*|*\[*|*\]*) fail "must not contain glob syntax: $delete_file" ;;
esac

case "$delete_file" in
  ./*|*/./*|*/.|*//*|*$'\n'*|*$'\r'*) fail "must be a canonical tap-relative path: $delete_file" ;;
esac

cd "$tap_dir"
[ ! -d "$delete_file" ] || fail "must name a file, not a directory: $delete_file"
[ -e "$delete_file" ] || [ -L "$delete_file" ] || fail "does not exist: $delete_file"
GIT_LITERAL_PATHSPECS=1 git ls-files --error-unmatch -- "$delete_file" >/dev/null 2>&1 \
  || fail "is not an exact tracked file: $delete_file"
GIT_LITERAL_PATHSPECS=1 git rm -- "$delete_file"
