#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

fail() {
  echo "::error::prepare-app-build: $*" >&2
  exit 1
}

validate_relative_file() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || return 0
  case "$value" in
    /*|../*|*/../*|*/..) fail "$name must stay inside the caller workspace" ;;
  esac
  [[ -f "$GITHUB_WORKSPACE/$value" ]] || fail "$name '$value' does not exist"
}

validate_inputs() {
  if [[ "$VALIDATE_ONLY" != true && "$VALIDATE_ONLY" != false ]]; then
    fail "validate-only must be true or false"
  fi
  if [[ -n "$GO_VERSION" ]] && ! [[ "$GO_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "go-version '$GO_VERSION' must be exact MAJOR.MINOR.PATCH"
  fi
  if [[ -n "$GO_CACHE_DEPENDENCY_PATH" && -z "$GO_VERSION" ]]; then
    fail "go-cache-dependency-path requires go-version"
  fi
  validate_relative_file go-cache-dependency-path "$GO_CACHE_DEPENDENCY_PATH"
  validate_relative_file prebuild-script "$PREBUILD_SCRIPT"

  local package
  while IFS= read -r package || [[ -n "$package" ]]; do
    [[ -n "$package" ]] || continue
    case "$package" in
      -*|/*|*..*|*[!A-Za-z0-9@+._/-]*) fail "invalid brew package '$package'" ;;
    esac
  done <<<"$BREW_PACKAGES"
}

validate_inputs
[[ "$mode" == validate ]] && exit 0
[[ "$mode" == run ]] || fail "mode must be validate or run"

packages=()
while IFS= read -r package || [[ -n "$package" ]]; do
  [[ -n "$package" ]] && packages+=("$package")
done <<<"$BREW_PACKAGES"
if ((${#packages[@]} > 0)); then
  [[ "${RUNNER_OS:-}" == macOS ]] || fail "brew packages require a macOS runner"
  brew install "${packages[@]}"
fi
if [[ -n "$PREBUILD_SCRIPT" ]]; then
  bash "$GITHUB_WORKSPACE/$PREBUILD_SCRIPT"
fi
