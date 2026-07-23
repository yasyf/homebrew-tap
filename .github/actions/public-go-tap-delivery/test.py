#!/usr/bin/env python3
from __future__ import annotations

from contextlib import redirect_stderr
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


ACTION_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(ACTION_DIR))

import prepare  # noqa: E402
import verify_darwin_signatures as signatures  # noqa: E402


SHA_A = "a" * 64
SHA_B = "b" * 64
COMMIT_A = "a" * 40
COMMIT_B = "b" * 40


class FailureAssertions(unittest.TestCase):
    def assert_fails(self, expected: str, function, *args, **kwargs) -> None:
        error = io.StringIO()
        with redirect_stderr(error), self.assertRaises(SystemExit):
            function(*args, **kwargs)
        self.assertIn(expected, error.getvalue())


class ContractTests(FailureAssertions):
    def test_json_object_rejects_duplicate_keys_and_non_string_values(self) -> None:
        self.assert_fails("duplicate key", prepare.strict_object, '{"asset":"a","asset":"b"}', "manifest")
        self.assert_fails("keys and values must be strings", prepare.strict_object, '{"asset":1}', "manifest")

    def test_release_requires_exact_public_stable_id_and_tag(self) -> None:
        release = {"id": 42, "tag_name": "v1.2.3", "draft": False, "prerelease": False}
        self.assertEqual(prepare.validate_release(release, 42, "v1.2.3", "test"), release)
        for field, value, message in (
            ("id", 43, "release ID"),
            ("tag_name", "v1.2.4", "release tag"),
            ("draft", True, "not public"),
            ("prerelease", True, "prerelease"),
        ):
            changed = dict(release)
            changed[field] = value
            self.assert_fails(message, prepare.validate_release, changed, 42, "v1.2.3", "test")

    def test_recursive_tag_peel_and_cycle_rejection(self) -> None:
        responses = [
            {"object": {"type": "tag", "sha": COMMIT_A}},
            {"object": {"type": "commit", "sha": COMMIT_B}},
        ]
        with mock.patch.object(prepare, "gh_json", side_effect=responses):
            self.assertEqual(prepare.peel_tag("yasyf/example", "v1.2.3"), COMMIT_B)
        cycle = [
            {"object": {"type": "tag", "sha": COMMIT_A}},
            {"object": {"type": "tag", "sha": COMMIT_A}},
        ]
        with mock.patch.object(prepare, "gh_json", side_effect=cycle):
            self.assert_fails("cycle", prepare.peel_tag, "yasyf/example", "v1.2.3")

    def test_release_asset_contract_is_exact_and_digest_bound(self) -> None:
        rows = {"payload.tar.gz": {"digest": f"sha256:{SHA_A}", "state": "uploaded"}}
        prepare.validate_asset_contract(rows, {"payload.tar.gz": SHA_A})
        self.assert_fails("exact public asset set", prepare.validate_asset_contract, rows, {"other": SHA_A})
        self.assert_fails(
            "records digest",
            prepare.validate_asset_contract,
            {"payload.tar.gz": {"digest": f"sha256:{SHA_B}", "state": "uploaded"}},
            {"payload.tar.gz": SHA_A},
        )
        self.assert_fails(
            "not in uploaded state",
            prepare.validate_asset_contract,
            {"payload.tar.gz": {"digest": f"sha256:{SHA_A}", "state": "new"}},
            {"payload.tar.gz": SHA_A},
        )
        self.assert_fails(
            "not in uploaded state",
            prepare.validate_asset_contract,
            {"payload.tar.gz": {"digest": f"sha256:{SHA_A}"}},
            {"payload.tar.gz": SHA_A},
        )

    def test_download_requires_exact_size_and_hash(self) -> None:
        payload = b"signed payload"
        digest = hashlib.sha256(payload).hexdigest()
        rows = {"payload": {"id": 9, "size": len(payload)}}
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(prepare, "gh_bytes", return_value=payload):
            prepare.download_assets("yasyf/example", rows, {"payload": digest}, Path(raw) / "ok")
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(prepare, "gh_bytes", return_value=payload):
            self.assert_fails(
                "has size",
                prepare.download_assets,
                "yasyf/example",
                {"payload": {"id": 9, "size": len(payload) + 1}},
                {"payload": digest},
                Path(raw) / "bad-size",
            )
        with tempfile.TemporaryDirectory() as raw, mock.patch.object(prepare, "gh_bytes", return_value=payload):
            self.assert_fails(
                "has SHA-256",
                prepare.download_assets,
                "yasyf/example",
                rows,
                {"payload": SHA_A},
                Path(raw) / "bad-sha",
            )

    def test_checksum_file_must_close_over_every_other_asset(self) -> None:
        payloads = {"one.tar.gz": b"one", "two.tar.gz": b"two"}
        hashes = {name: hashlib.sha256(value).hexdigest() for name, value in payloads.items()}
        checksum = "".join(f"{hashes[name]}  {name}\n" for name in sorted(payloads)).encode()
        hashes["checksums.txt"] = hashlib.sha256(checksum).hexdigest()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for name, value in payloads.items():
                (root / name).write_bytes(value)
            (root / "checksums.txt").write_bytes(checksum)
            prepare.verify_checksum_closure(root, hashes)
            missing = dict(hashes)
            missing["extra.tar.gz"] = SHA_A
            (root / "extra.tar.gz").write_bytes(b"extra")
            self.assert_fails("closure differs", prepare.verify_checksum_closure, root, missing)

    def test_mode_controls_source_and_output_kind(self) -> None:
        prepare.validate_source_path(".github/formula/example.rb.tmpl", "formula-template", "example")
        prepare.validate_source_path(".goreleaser.yaml", "goreleaser-cask", "example")
        self.assert_fails(
            "must end in .tmpl or .rb",
            prepare.validate_source_path,
            ".goreleaser.yaml",
            "formula-template",
            "example",
        )
        self.assert_fails(
            "must end in .yaml or .yml",
            prepare.validate_source_path,
            ".github/formula/example.rb.tmpl",
            "goreleaser-cask",
            "example",
        )
        self.assert_fails(
            "basename must equal delivery-name",
            prepare.validate_source_path,
            ".github/formula/other.rb.tmpl",
            "formula-template",
            "example",
        )
        self.assertEqual(prepare.delivery_relative_path("formula-template", "example"), Path("Formula/example.rb"))
        self.assertEqual(prepare.delivery_relative_path("goreleaser-cask", "example"), Path("Casks/example.rb"))

    def test_formula_render_rejects_unresolved_and_unknown_asset_tokens(self) -> None:
        assets = {
            "example_1.2.3_darwin_amd64.tar.gz": "1" * 64,
            "example_1.2.3_darwin_arm64.tar.gz": "2" * 64,
            "example_1.2.3_linux_amd64.tar.gz": "3" * 64,
            "example_1.2.3_linux_arm64.tar.gz": "4" * 64,
        }
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            template = root / "formula.rb.tmpl"
            output = root / "Formula/example.rb"
            template.write_text('class Example < Formula\n  version "__VERSION__"\n  sha256 "__SHA_DARWIN_ARM64__"\nend\n')
            prepare.render_formula(template, output, "1.2.3", assets, {})
            self.assertIn("2" * 64, output.read_text())
            template.write_text('class Example < Formula\n  sha256 "__UNKNOWN__"\nend\n')
            self.assert_fails("unfilled tokens", prepare.render_formula, template, output, "1.2.3", assets, {})
            self.assert_fails(
                "unknown asset",
                prepare.render_formula,
                template,
                output,
                "1.2.3",
                assets,
                {"__UNKNOWN__": "absent.tar.gz"},
            )


class CaskRendererTests(FailureAssertions):
    def fixture(self, root: Path, *, formats: str = "[tar.gz]", delivery_name: str = "example") -> tuple[Path, Path, Path]:
        config = root / ".goreleaser.yaml"
        config.write_text(
            "\n".join(
                (
                    "version: 2",
                    "project_name: example",
                    "archives:",
                    "  - id: archive",
                    f"    formats: {formats}",
                    '    name_template: "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"',
                    "homebrew_casks:",
                    "  - name: example",
                    "    ids: [archive]",
                    "    binaries: [example]",
                    "    repository:",
                    "      owner: yasyf",
                    "      name: homebrew-tap",
                    "    homepage: https://github.com/yasyf/example",
                    "    description: Exact public example",
                    "",
                )
            )
        )
        assets = {
            f"example_1.2.3_{os_name}_{arch}.tar.gz": str(index) * 64
            for index, (os_name, arch) in enumerate(
                (("darwin", "amd64"), ("darwin", "arm64"), ("linux", "amd64"), ("linux", "arm64")),
                start=1,
            )
        }
        metadata = root / "metadata.json"
        metadata.write_text(
            json.dumps(
                {
                    "repository": "yasyf/example",
                    "tag": "v1.2.3",
                    "version": "1.2.3",
                    "source_sha": COMMIT_A,
                    "source_path": ".goreleaser.yaml",
                    "delivery_name": delivery_name,
                    "assets": assets,
                }
            )
        )
        return config, metadata, root / "Casks/example.rb"

    def run_renderer(self, config: Path, metadata: Path, output: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["ruby", str(ACTION_DIR / "render_goreleaser_cask.rb"), str(config), str(metadata), str(output)],
            check=False,
            text=True,
            capture_output=True,
        )

    def test_cask_renderer_requires_name_and_exact_tar_kind(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            config, metadata, output = self.fixture(Path(raw))
            result = self.run_renderer(config, metadata, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('cask "example" do', output.read_text())
            self.assertEqual(subprocess.run(["ruby", "-c", str(output)], check=False).returncode, 0)
        with tempfile.TemporaryDirectory() as raw:
            config, metadata, output = self.fixture(Path(raw), delivery_name="other")
            result = self.run_renderer(config, metadata, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not equal tagged cask name", result.stderr)
        with tempfile.TemporaryDirectory() as raw:
            config, metadata, output = self.fixture(Path(raw), formats="[binary]")
            result = self.run_renderer(config, metadata, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact artifact kind", result.stderr)


class SignatureTests(FailureAssertions):
    def make_tar(self, root: Path, name: str, member: tarfile.TarInfo, payload: bytes = b"") -> Path:
        archive = root / name
        with tarfile.open(archive, "w:gz") as bundle:
            bundle.addfile(member, io.BytesIO(payload) if member.isfile() else None)
        return archive

    def test_safe_extraction_rejects_traversal_and_links(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            traversal = tarfile.TarInfo("../escape")
            traversal.size = 1
            archive = self.make_tar(root, "traversal.tar.gz", traversal, b"x")
            self.assert_fails("unsafe path", signatures.safe_extract_tar, archive, root / "out-one")
            link = tarfile.TarInfo("binary")
            link.type = tarfile.SYMTYPE
            link.linkname = "/tmp/escape"
            archive = self.make_tar(root, "link.tar.gz", link)
            self.assert_fails("non-regular entry", signatures.safe_extract_tar, archive, root / "out-two")

    def test_safe_extraction_rejects_casefolded_and_unicode_path_aliases(self) -> None:
        for names in (("Payload", "payload"), ("caf\u00e9", "cafe\u0301")):
            with tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                archive = root / "aliases.tar.gz"
                with tarfile.open(archive, "w:gz") as bundle:
                    for name, payload in zip(names, (b"A", b"B"), strict=True):
                        member = tarfile.TarInfo(name)
                        member.size = 1
                        bundle.addfile(member, io.BytesIO(payload))
                self.assert_fails(
                    "platform-aliased path",
                    signatures.safe_extract_tar,
                    archive,
                    root / "contents",
                )

    def test_codesign_contract_requires_team_authority_runtime_and_arch(self) -> None:
        details = "\n".join(
            (
                "Authority=Developer ID Application: Example (SXKCTF23Q2)",
                "TeamIdentifier=SXKCTF23Q2",
                "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=2+7 location=embedded",
            )
        )

        def valid_command(*args: str) -> str:
            if args[:2] == ("codesign", "-d"):
                return details
            if args[0] == "lipo":
                return "arm64\n"
            return ""

        with mock.patch.object(signatures, "command", side_effect=valid_command):
            signatures.verify_macho(Path("example"), "arm64")
        with mock.patch.object(signatures, "command", side_effect=lambda *args: "arm64\n" if args[0] == "lipo" else ""):
            self.assert_fails("TeamIdentifier", signatures.verify_macho, Path("example"), "arm64")

        def universal_command(*args: str) -> str:
            if args[:2] == ("codesign", "-d"):
                return details
            if args[0] == "lipo":
                return "x86_64 arm64\n"
            return ""

        with mock.patch.object(signatures, "command", side_effect=universal_command):
            signatures.verify_macho(Path("example"), "universal")

    def test_every_darwin_archive_and_bare_binary_is_selected(self) -> None:
        names = {
            "example_1.2.3_darwin_amd64.tar.gz": SHA_A,
            "example_1.2.3_darwin_arm64.tar.gz": SHA_A,
            "example_darwin_amd64": SHA_A,
            "example_darwin_arm64": SHA_A,
            "example_1.2.3_linux_amd64.tar.gz": SHA_A,
        }
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for name in names:
                (root / name).write_bytes(b"\xcf\xfa\xed\xfe")
            with (
                mock.patch.object(signatures.sys, "platform", "darwin"),
                mock.patch.object(signatures, "verify_archive") as verify_archive,
                mock.patch.object(signatures, "verify_macho") as verify_macho,
                mock.patch.object(signatures, "is_macho", return_value=True),
            ):
                signatures.verify_release_assets(root, names)
            self.assertEqual(verify_archive.call_count, 2)
            self.assertEqual(verify_macho.call_count, 2)

    def test_archive_extracts_into_fresh_child_and_verifies_macho(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            member = tarfile.TarInfo("example")
            member.size = 4
            member.mode = 0o755
            archive = self.make_tar(root, "example_darwin_arm64.tar.gz", member, b"\xcf\xfa\xed\xfe")
            with mock.patch.object(signatures, "verify_macho") as verify_macho:
                signatures.verify_archive(archive, "arm64")
            self.assertEqual(verify_macho.call_count, 1)
            self.assertEqual(verify_macho.call_args.args[1], "arm64")

    def test_universal_archive_covers_both_architectures_and_partial_shape_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            universal = {"example-darwin-universal.tar.gz": SHA_A}
            (root / "example-darwin-universal.tar.gz").write_bytes(b"archive")
            with (
                mock.patch.object(signatures.sys, "platform", "darwin"),
                mock.patch.object(signatures, "verify_archive") as verify_archive,
            ):
                signatures.verify_release_assets(root, universal)
            verify_archive.assert_called_once_with(root / "example-darwin-universal.tar.gz", "universal")

            partial = {"example_darwin_amd64.tar.gz": SHA_A}
            (root / "example_darwin_amd64.tar.gz").write_bytes(b"archive")
            with mock.patch.object(signatures.sys, "platform", "darwin"):
                self.assert_fails("do not cover both architectures", signatures.verify_release_assets, root, partial)

    def test_unsupported_darwin_looking_assets_fail_closed(self) -> None:
        assets = {
            "ok_darwin_amd64.tar.gz": SHA_A,
            "ok_darwin_arm64.tar.gz": SHA_A,
            "unsigned_darwin_x86_64.tar.gz": SHA_A,
            "unsigned_darwin_arm64.zip": SHA_A,
        }
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for name in assets:
                (root / name).write_bytes(b"payload")
            with mock.patch.object(signatures.sys, "platform", "darwin"):
                self.assert_fails("unsupported Darwin-looking", signatures.verify_release_assets, root, assets)


if __name__ == "__main__":
    unittest.main(verbosity=2)
