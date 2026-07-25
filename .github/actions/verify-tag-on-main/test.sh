#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="$root/verify.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

production_fingerprint="$(
  gpg --batch --show-keys --with-colons --fingerprint "$root/release-signing-key.asc" |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"
[[ "$production_fingerprint" == F3299DE3FE0F6C3CF2B66BFBF7ECDD88A700D73A ]]

generate_key() {
  local home="$1"
  local identity="$2"
  mkdir -p "$home"
  chmod 700 "$home"
  gpg --batch --homedir "$home" --pinentry-mode loopback --passphrase "" \
    --quick-generate-key "$identity" rsa2048 sign 0 >/dev/null 2>&1
  gpg --batch --homedir "$home" --with-colons --fingerprint |
    awk -F: '$1 == "fpr" { print $10; exit }'
}

signing_home="$work/signing"
wrong_home="$work/wrong"
signing_fingerprint="$(generate_key "$signing_home" "Fleet Test <fleet@example.invalid>")"
wrong_fingerprint="$(generate_key "$wrong_home" "Wrong Test <wrong@example.invalid>")"
trusted_key="$work/trusted.asc"
gpg --batch --homedir "$signing_home" --armor --export "$signing_fingerprint" >"$trusted_key"
gpg --batch --homedir "$wrong_home" --armor --export "$wrong_fingerprint" >>"$trusted_key"

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

create_signed_tag() {
  local tag="$1"
  local home="$2"
  local fingerprint="$3"
  local target="$4"
  GNUPGHOME="$home" git -c user.signingkey="$fingerprint" \
    tag -s -m "$tag" "$tag" "$target"
  git push -q origin "refs/tags/$tag"
}

verify() {
  local tag="$1"
  local sha="$2"
  local manifest="${3:-}"
  env \
    GITHUB_REF_NAME="$tag" \
    GITHUB_SHA="$sha" \
    PLUGIN_MANIFEST="$manifest" \
    TRUSTED_RELEASE_KEY="$trusted_key" \
    TRUSTED_RELEASE_FINGERPRINT="$signing_fingerprint" \
    "$verifier"
}

expect_failure() {
  local tag="$1"
  local sha="$2"
  local expected="$3"
  local output
  if output="$(verify "$tag" "$sha" 2>&1)"; then
    echo "FAIL: $tag unexpectedly passed" >&2
    exit 1
  fi
  grep -Fq "$expected" <<<"$output" || {
    echo "FAIL: $tag did not report '$expected':" >&2
    echo "$output" >&2
    exit 1
  }
}

create_signed_tag v1.2.3 "$signing_home" "$signing_fingerprint" "$main_sha"
printf '{"version":"1.2.3"}\n' >plugin.json
verify v1.2.3 "$main_sha" plugin.json

git tag v1.2.4 "$main_sha"
git push -q origin refs/tags/v1.2.4
expect_failure v1.2.4 "$main_sha" "must be one annotated tag object"

git tag -a -m v1.2.5 v1.2.5 "$main_sha"
git push -q origin refs/tags/v1.2.5
expect_failure v1.2.5 "$main_sha" "signature verification failed"

create_signed_tag v1.2.6 "$wrong_home" "$wrong_fingerprint" "$main_sha"
expect_failure v1.2.6 "$main_sha" "is not signed by trusted key"

git switch -qc side
printf 'side\n' >>fixture.txt
git commit -qam side
side_sha="$(git rev-parse HEAD)"
create_signed_tag v1.2.7 "$signing_home" "$signing_fingerprint" "$side_sha"
expect_failure v1.2.7 "$side_sha" "which is not on main"
git switch -q main

printf 'second\n' >>fixture.txt
git commit -qam second
second_sha="$(git rev-parse HEAD)"
git push -q origin main
create_signed_tag v1.2.8 "$signing_home" "$signing_fingerprint" "$main_sha"
expect_failure v1.2.8 "$second_sha" "peels to $main_sha"

echo "ok: signed annotated release-tag gate"
