#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="$root/verify.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git init -q --bare "$work/origin.git"
git clone -q "$work/origin.git" "$work/repo"
cd "$work/repo"
git config user.name "Release Fixture"
git config user.email "release@example.invalid"
printf 'fixture\n' >fixture.txt
git add fixture.txt
git commit -qm initial
git branch -M main
git push -q -u origin main
main_sha="$(git rev-parse HEAD)"

verify() {
  local tag="$1"
  local sha="$2"
  local manifest="${3:-}"
  env \
    GITHUB_REF_NAME="$tag" \
    GITHUB_SHA="$sha" \
    PLUGIN_MANIFEST="$manifest" \
    "$verifier"
}

expect_failure() {
  local tag="$1"
  local sha="$2"
  local expected="$3"
  local manifest="${4:-}"
  local output
  if output="$(verify "$tag" "$sha" "$manifest" 2>&1)"; then
    echo "FAIL: $tag unexpectedly passed" >&2
    exit 1
  fi
  grep -Fq "$expected" <<<"$output" || {
    echo "FAIL: $tag did not report '$expected':" >&2
    echo "$output" >&2
    exit 1
  }
}

git tag v1.2.3 "$main_sha"
git tag -a -m v1.2.4 v1.2.4 "$main_sha"
git push -q origin refs/tags/v1.2.3 refs/tags/v1.2.4

printf '{"version":"1.2.3"}\n' >plugin.json
verify v1.2.3 "$main_sha" plugin.json
verify v1.2.4 "$main_sha"

printf '{"version":"9.9.9"}\n' >wrong-version.json
expect_failure v1.2.3 "$main_sha" "does not match" wrong-version.json
expect_failure v1.2.3 "$main_sha" "does not exist" "$work/absent.json"
printf '{}\n' >no-version.json
expect_failure v1.2.3 "$main_sha" "has no top-level string version" no-version.json

expect_failure v1.2 "$main_sha" "must be a semantic release tag"
expect_failure v1.2.3 not-a-commit-sha "must be one exact commit"

git tag v1.2.5 "$main_sha"
git push -q origin refs/tags/v1.2.5
git push -q origin "main:refs/heads/refs/tags/v1.2.5"
expect_failure v1.2.5 "$main_sha" "must advertise exactly one refs/tags/v1.2.5 object"

git push -q origin "main:refs/heads/refs/tags/v1.2.8"
expect_failure v1.2.8 "$main_sha" "origin returned an inexact tag ref"

git -c advice.nestedTag=false tag -a -m v1.2.9 v1.2.9 "$(git rev-parse refs/tags/v1.2.4)"
git push -q origin refs/tags/v1.2.9
expect_failure v1.2.9 "$main_sha" "v1.2.9 is a tag object pointing at a tag, not a commit"

git switch -qc side
printf 'side\n' >>fixture.txt
git commit -qam side
side_sha="$(git rev-parse HEAD)"
git tag v1.2.6 "$side_sha"
git push -q origin refs/tags/v1.2.6
expect_failure v1.2.6 "$side_sha" "which is not on main"
git switch -q main

printf 'second\n' >>fixture.txt
git commit -qam second
second_sha="$(git rev-parse HEAD)"
git push -q origin main
expect_failure v1.2.3 "$second_sha" "origin advertises v1.2.3 at $main_sha"
expect_failure v1.2.4 "$second_sha" "origin advertises v1.2.4 at $main_sha"

real_git="$(command -v git)"
mkdir -p "$work/bin/mover" "$work/bin/liar"
cat >"$work/bin/mover/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == "refs/tags/\$SHIM_TAG:refs/tags/\$SHIM_TAG" ]]; then
    "$real_git" --git-dir="$work/origin.git" update-ref "refs/tags/\$SHIM_TAG" "\$SHIM_OBJECT"
    break
  fi
done
exec "$real_git" "\$@"
EOF
cat >"$work/bin/liar/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == "refs/tags/\$SHIM_TAG^{}" ]]; then
    printf '%s\trefs/tags/%s^{}\n' "\$SHIM_OBJECT" "\$SHIM_TAG"
    exit 0
  fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$work/bin/mover/git" "$work/bin/liar/git"

git tag v1.2.7 "$main_sha"
git tag -a -m v1.3.0 v1.3.0 "$main_sha"
git tag -a -m v1.3.1 v1.3.1 "$main_sha"
git tag -a -m swapped v1.3.2 "$main_sha"
git tag v1.3.3 "$main_sha"
git push -q origin refs/tags/v1.2.7 refs/tags/v1.3.0 refs/tags/v1.3.1 refs/tags/v1.3.2 refs/tags/v1.3.3
swapped_tag_object="$(git rev-parse refs/tags/v1.3.2)"

(
  export PATH="$work/bin/mover:$PATH" SHIM_TAG=v1.2.7 SHIM_OBJECT="$second_sha"
  expect_failure v1.2.7 "$main_sha" "v1.2.7 moved while its release gate was running"
)
(
  export PATH="$work/bin/mover:$PATH" SHIM_TAG=v1.3.1 SHIM_OBJECT="$swapped_tag_object"
  expect_failure v1.3.1 "$main_sha" "v1.3.1 moved while its release gate was running"
)
(
  export PATH="$work/bin/liar:$PATH" SHIM_TAG=v1.3.0 SHIM_OBJECT="$second_sha"
  expect_failure v1.3.0 "$second_sha" "the fetched v1.3.0 resolves to $main_sha"
)
(
  export PATH="$work/bin/liar:$PATH" SHIM_TAG=v1.3.3 SHIM_OBJECT="$second_sha"
  expect_failure v1.3.3 "$second_sha" "the fetched v1.3.3 resolves to $main_sha"
)

echo "ok: release-tag gate"
