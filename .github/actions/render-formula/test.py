import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class RenderFormulaTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.template = self.root / "tool.rb.tmpl"
        self.checksums = self.root / "checksums.txt"
        self.output = self.root / "staging/Formula/tool.rb"
        self.github_output = self.root / "github-output"
        self.env = os.environ | {
            "TEMPLATE": str(self.template),
            "OUTPUT": "Formula/tool.rb",
            "STAGING": str(self.root / "staging"),
            "VERSION_IN": "1.2.3",
            "NAME": "tool",
            "CHECKSUMS": str(self.checksums),
            "SUBSTITUTIONS": "",
            "GITHUB_REF_NAME": "v1.2.3",
            "GITHUB_OUTPUT": str(self.github_output),
        }

    def render(self, platforms, available):
        self.template.write_text(
            'version "__VERSION__"\n'
            + "".join(f'sha256 "__SHA_{platform.upper()}__"\n' for platform in platforms)
        )
        self.checksums.write_text(
            "".join(
                f"{checksum}  tool_1.2.3_{platform}.tar.gz\n"
                for platform, checksum in available.items()
            )
        )
        return subprocess.run(
            ["bash", os.environ["RENDER_FORMULA_SCRIPT"]],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_darwin_template_needs_only_darwin_archives(self):
        available = {"darwin_arm64": "a" * 64, "darwin_amd64": "b" * 64}
        result = self.render(available, available)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = 'version "1.2.3"\n' + "".join(
            f'sha256 "{checksum}"\n' for checksum in available.values()
        )
        self.assertEqual(self.output.read_text(), expected)

    def test_four_platform_template_keeps_all_checksums(self):
        available = {
            "darwin_arm64": "a" * 64,
            "darwin_amd64": "b" * 64,
            "linux_arm64": "c" * 64,
            "linux_amd64": "d" * 64,
        }
        result = self.render(available, available)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = 'version "1.2.3"\n' + "".join(
            f'sha256 "{checksum}"\n' for checksum in available.values()
        )
        self.assertEqual(self.output.read_text(), expected)

    def test_missing_required_linux_checksum_rejects_publication(self):
        result = self.render(["linux_arm64"], {"darwin_arm64": "a" * 64})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "::error::no checksum for tool_1.2.3_linux_arm64.tar.gz",
            result.stderr,
        )
        self.assertFalse(self.output.exists())
        self.assertFalse(self.github_output.exists())

    def test_missing_required_darwin_checksum_rejects_publication(self):
        result = self.render(
            ["darwin_arm64", "darwin_amd64"], {"darwin_arm64": "a" * 64}
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "::error::no checksum for tool_1.2.3_darwin_amd64.tar.gz",
            result.stderr,
        )
        self.assertFalse(self.output.exists())
        self.assertFalse(self.github_output.exists())


if __name__ == "__main__":
    unittest.main()
