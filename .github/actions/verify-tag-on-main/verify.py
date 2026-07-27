#!/usr/bin/env python3
"""Fail-closed verification for a GitHub release tag."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class VerificationError(RuntimeError):
    """VerificationError identifies an invalid release tag."""


def _mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise VerificationError(f"{field} must be an object")
    return value


def _ref_object(ref_payload: dict[str, Any]) -> dict[str, Any]:
    ref_object = _mapping(ref_payload.get("object"), "remote ref object")
    sha = ref_object.get("sha")
    if not isinstance(sha, str) or not sha:
        raise VerificationError("remote ref object has no SHA")
    return ref_object


def validate(
    ref_payload: dict[str, Any],
    tag_payload: dict[str, Any] | None,
    expected_tag: str,
    expected_sha: str,
) -> None:
    """Validate a lightweight or annotated tag over the exact expected commit."""
    expected_ref = f"refs/tags/{expected_tag}"
    if ref_payload.get("ref") != expected_ref:
        raise VerificationError(
            f"remote ref is {ref_payload.get('ref')!r}, expected {expected_ref!r}"
        )

    ref_object = _ref_object(ref_payload)
    ref_object_sha = ref_object["sha"]
    if ref_object.get("type") == "commit":
        if ref_object_sha != expected_sha:
            raise VerificationError(
                f"remote ref names {ref_object_sha!r}, but this run is for {expected_sha!r}"
            )
        return
    if ref_object.get("type") != "tag":
        raise VerificationError(
            "remote ref object is neither a commit nor a tag "
            f"(type={ref_object.get('type')!r})"
        )

    tag_payload = _mapping(tag_payload, "tag object")
    if tag_payload.get("sha") != ref_object_sha:
        raise VerificationError(
            "fetched tag object SHA does not match the remote ref "
            f"({tag_payload.get('sha')!r} != {ref_object_sha!r})"
        )
    if tag_payload.get("tag") != expected_tag:
        raise VerificationError(
            f"tag object name is {tag_payload.get('tag')!r}, expected {expected_tag!r}"
        )

    target = _mapping(tag_payload.get("object"), "tag target")
    if target.get("type") != "commit":
        raise VerificationError(
            f"tag target is not a commit (type={target.get('type')!r})"
        )
    if target.get("sha") != expected_sha:
        raise VerificationError(
            f"tag targets {target.get('sha')!r}, but this run is for {expected_sha!r}"
        )


def fetch_json(url: str, token: str) -> dict[str, Any]:
    """Fetch one authenticated GitHub API object."""
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
        raise VerificationError(f"GitHub API request failed for {url}: {error}") from error
    return _mapping(payload, f"GitHub API response from {url}")


def main() -> int:
    """Verify the release tag described by the GitHub Actions environment."""
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    tag = os.environ.get("GITHUB_REF_NAME", "")
    sha = os.environ.get("GITHUB_SHA", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    missing = [
        name
        for name, value in (
            ("GITHUB_REPOSITORY", repository),
            ("GITHUB_REF_NAME", tag),
            ("GITHUB_SHA", sha),
            ("GITHUB_TOKEN", token),
        )
        if not value
    ]
    if missing:
        raise VerificationError(f"missing required environment: {', '.join(missing)}")

    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    encoded_tag = urllib.parse.quote(tag, safe="")
    ref_payload = fetch_json(
        f"{api_url}/repos/{repository}/git/ref/tags/{encoded_tag}", token
    )
    ref_object = _ref_object(ref_payload)
    tag_payload: dict[str, Any] | None = None
    if ref_object.get("type") == "tag":
        tag_payload = fetch_json(
            f"{api_url}/repos/{repository}/git/tags/{ref_object['sha']}", token
        )
    validate(ref_payload, tag_payload, tag, sha)
    print(f"✓ {tag} resolves to exactly {sha}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VerificationError as error:
        print(f"::error title=Invalid release tag::{error}", file=sys.stderr)
        raise SystemExit(1) from error
