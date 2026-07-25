#!/usr/bin/env python3
"""Deterministic contract tests for release-tag verification."""

from __future__ import annotations

import importlib.util
import pathlib
import unittest
from collections.abc import Callable
from typing import Any


MODULE_PATH = pathlib.Path(__file__).with_name("verify.py")
SPEC = importlib.util.spec_from_file_location("verify_tag_on_main", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)

TAG = "v1.2.3"
COMMIT_SHA = "1" * 40
TAG_SHA = "2" * 40


def valid_payloads() -> tuple[dict[str, object], dict[str, object]]:
    return (
        {
            "ref": f"refs/tags/{TAG}",
            "object": {"type": "tag", "sha": TAG_SHA},
        },
        {
            "sha": TAG_SHA,
            "tag": TAG,
            "object": {"type": "commit", "sha": COMMIT_SHA},
            "verification": {"verified": True, "reason": "valid"},
        },
    )


class ValidateTest(unittest.TestCase):
    def assert_rejected(
        self,
        mutate: Callable[[dict[str, Any], dict[str, Any]], None],
        pattern: str,
    ) -> None:
        ref_payload, tag_payload = valid_payloads()
        mutate(ref_payload, tag_payload)
        with self.assertRaisesRegex(VERIFY.VerificationError, pattern):
            VERIFY.validate(ref_payload, tag_payload, TAG, COMMIT_SHA)

    def test_accepts_exact_verified_annotated_tag(self) -> None:
        ref_payload, tag_payload = valid_payloads()
        VERIFY.validate(ref_payload, tag_payload, TAG, COMMIT_SHA)

    def test_rejects_lightweight_tag(self) -> None:
        self.assert_rejected(
            lambda ref, _tag: ref["object"].update(type="commit"),
            "lightweight tags are forbidden",
        )

    def test_rejects_unsigned_tag(self) -> None:
        self.assert_rejected(
            lambda _ref, tag: tag["verification"].update(
                verified=False, reason="unsigned"
            ),
            "did not verify.*unsigned",
        )

    def test_rejects_bad_signature(self) -> None:
        self.assert_rejected(
            lambda _ref, tag: tag["verification"].update(
                verified=False, reason="invalid"
            ),
            "did not verify.*invalid",
        )

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


if __name__ == "__main__":
    unittest.main()
