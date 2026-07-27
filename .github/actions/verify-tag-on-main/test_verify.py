#!/usr/bin/env python3
"""Deterministic contract tests for release-tag verification."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import pathlib
import re
import unittest
from collections.abc import Callable
from typing import Any
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name("verify.py")
SPEC = importlib.util.spec_from_file_location("verify_tag_on_main", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)

TAG = "v1.2.3"
COMMIT_SHA = "1" * 40
TAG_SHA = "2" * 40
REPOSITORY = "yasyf/homebrew-tap"
REF_URL = f"https://api.github.com/repos/{REPOSITORY}/git/ref/tags/{TAG}"
TAG_URL = f"https://api.github.com/repos/{REPOSITORY}/git/tags/{TAG_SHA}"


def annotated_payloads() -> tuple[dict[str, object], dict[str, object]]:
    return (
        {
            "ref": f"refs/tags/{TAG}",
            "object": {"type": "tag", "sha": TAG_SHA},
        },
        {
            "sha": TAG_SHA,
            "tag": TAG,
            "object": {"type": "commit", "sha": COMMIT_SHA},
        },
    )


def lightweight_ref() -> dict[str, object]:
    return {
        "ref": f"refs/tags/{TAG}",
        "object": {"type": "commit", "sha": COMMIT_SHA},
    }


def run_main(
    payloads: list[dict[str, object]], omit: str | None = None
) -> tuple[int, list[str]]:
    urls: list[str] = []

    def fetch_json(url: str, token: str) -> dict[str, object]:
        urls.append(url)
        return payloads[len(urls) - 1]

    environment = {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_REF_NAME": TAG,
        "GITHUB_SHA": COMMIT_SHA,
        "GITHUB_TOKEN": "token",
    }
    if omit is not None:
        del environment[omit]
    with (
        mock.patch.object(VERIFY, "fetch_json", fetch_json),
        mock.patch.dict(os.environ, environment, clear=True),
    ):
        return VERIFY.main(), urls


class ValidateTest(unittest.TestCase):
    def assert_rejected(
        self,
        mutate: Callable[[dict[str, Any], dict[str, Any]], None],
        pattern: str,
    ) -> None:
        ref_payload, tag_payload = annotated_payloads()
        mutate(ref_payload, tag_payload)
        with self.assertRaisesRegex(VERIFY.VerificationError, pattern):
            VERIFY.validate(ref_payload, tag_payload, TAG, COMMIT_SHA)

    def test_accepts_annotated_tag(self) -> None:
        ref_payload, tag_payload = annotated_payloads()
        VERIFY.validate(ref_payload, tag_payload, TAG, COMMIT_SHA)

    def test_accepts_lightweight_tag(self) -> None:
        VERIFY.validate(lightweight_ref(), None, TAG, COMMIT_SHA)

    def test_rejects_lightweight_tag_over_wrong_commit(self) -> None:
        ref_payload = lightweight_ref()
        ref_payload["object"] = {"type": "commit", "sha": "3" * 40}
        with self.assertRaisesRegex(VERIFY.VerificationError, "remote ref names"):
            VERIFY.validate(ref_payload, None, TAG, COMMIT_SHA)

    def test_rejects_wrong_remote_ref_for_lightweight(self) -> None:
        ref_payload = lightweight_ref()
        ref_payload["ref"] = "refs/tags/v9.9.9"
        with self.assertRaisesRegex(VERIFY.VerificationError, "remote ref is"):
            VERIFY.validate(ref_payload, None, TAG, COMMIT_SHA)

    def test_rejects_unknown_ref_object_type(self) -> None:
        self.assert_rejected(
            lambda ref, _tag: ref["object"].update(type="tree"),
            "neither a commit nor a tag",
        )

    def test_rejects_ref_object_without_sha(self) -> None:
        ref_payload = lightweight_ref()
        ref_payload["object"] = {"type": "commit"}
        with self.assertRaisesRegex(VERIFY.VerificationError, "no SHA"):
            VERIFY.validate(ref_payload, None, TAG, COMMIT_SHA)

    def test_rejects_annotated_ref_without_tag_payload(self) -> None:
        ref_payload, _tag_payload = annotated_payloads()
        with self.assertRaisesRegex(
            VERIFY.VerificationError, "tag object must be an object"
        ):
            VERIFY.validate(ref_payload, None, TAG, COMMIT_SHA)

    def test_rejects_non_commit_target(self) -> None:
        self.assert_rejected(
            lambda _ref, tag: tag["object"].update(type="tree"),
            "target is not a commit",
        )

    def test_rejects_wrong_tag_name(self) -> None:
        self.assert_rejected(
            lambda _ref, tag: tag.update(tag="v9.9.9"),
            "tag object name",
        )

    def test_rejects_wrong_commit(self) -> None:
        self.assert_rejected(
            lambda _ref, tag: tag["object"].update(sha="3" * 40),
            "tag targets",
        )

    def test_rejects_tag_object_mismatch(self) -> None:
        self.assert_rejected(
            lambda _ref, tag: tag.update(sha="4" * 40),
            "tag object SHA does not match",
        )

    def test_rejects_wrong_remote_ref(self) -> None:
        self.assert_rejected(
            lambda ref, _tag: ref.update(ref="refs/tags/v9.9.9"),
            "remote ref is",
        )

    def test_rejects_non_object_ref_payload_object(self) -> None:
        self.assert_rejected(
            lambda ref, _tag: ref.update(object=[{"type": "commit"}]),
            "remote ref object must be an object",
        )

    def test_rejects_non_object_tag_target(self) -> None:
        self.assert_rejected(
            lambda _ref, tag: tag.update(object=[{"type": "commit"}]),
            "tag target must be an object",
        )


class FetchJsonTest(unittest.TestCase):
    def test_rejects_non_object_response(self) -> None:
        body = io.BytesIO(json.dumps([lightweight_ref()]).encode())
        with (
            mock.patch.object(VERIFY.urllib.request, "urlopen", return_value=body),
            self.assertRaisesRegex(
                VERIFY.VerificationError,
                re.escape(f"GitHub API response from {REF_URL} must be an object"),
            ),
        ):
            VERIFY.fetch_json(REF_URL, "token")

    def test_rejects_unreachable_api(self) -> None:
        failure = VERIFY.urllib.error.HTTPError(REF_URL, 403, "Forbidden", {}, None)
        with (
            mock.patch.object(VERIFY.urllib.request, "urlopen", side_effect=failure),
            self.assertRaisesRegex(
                VERIFY.VerificationError,
                re.escape(f"GitHub API request failed for {REF_URL}: HTTP Error 403"),
            ),
        ):
            VERIFY.fetch_json(REF_URL, "token")


class MainTest(unittest.TestCase):
    def test_lightweight_tag_costs_one_request(self) -> None:
        status, urls = run_main([lightweight_ref()])
        self.assertEqual(status, 0)
        self.assertEqual(urls, [REF_URL])

    def test_rejects_lightweight_tag_over_another_commit(self) -> None:
        ref_payload = lightweight_ref()
        ref_payload["object"] = {"type": "commit", "sha": "3" * 40}
        with self.assertRaisesRegex(VERIFY.VerificationError, "remote ref names"):
            run_main([ref_payload])

    def test_annotated_tag_costs_two_requests(self) -> None:
        status, urls = run_main(list(annotated_payloads()))
        self.assertEqual(status, 0)
        self.assertEqual(urls, [REF_URL, TAG_URL])

    def test_rejects_missing_environment(self) -> None:
        for name in (
            "GITHUB_REPOSITORY",
            "GITHUB_REF_NAME",
            "GITHUB_SHA",
            "GITHUB_TOKEN",
        ):
            with self.subTest(name=name):
                with self.assertRaisesRegex(
                    VERIFY.VerificationError, f"missing required environment: {name}"
                ):
                    run_main([lightweight_ref()], omit=name)


if __name__ == "__main__":
    unittest.main()
