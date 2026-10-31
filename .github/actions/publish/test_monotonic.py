import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class MonotonicPublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / "remote.git"
        self.seed = self.root / "seed"
        self.checkout = self.root / ".tap-publish"
        self.staging = self.root / "staging"
        self.formula = Path("Formula/cc-notes.rb")
        self.action = Path(__file__).resolve().parent
        self.env = {
            key: value
            for key, value in os.environ.items()
            if key not in {
                "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            }
        } | {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
            "PUBLISH_DIR": str(self.staging),
            "PUBLISH_MSG": "publish fixture",
            "MONOTONIC_FILE": str(self.formula),
            "DELETE_FILE": "",
            "GITHUB_ACTION_PATH": str(self.action),
        }
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.root, "clone", str(self.remote), str(self.seed))
        self.write_formula(self.seed, "1.0.9")
        (self.seed / "unrelated.txt").write_text("initial\n")
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-m", "initial")
        self.git(self.seed, "push", "origin", "main")

    def git(self, cwd, *args):
        return subprocess.run(
            ["git", *args], cwd=cwd, env=self.env, capture_output=True,
            text=True, check=True, timeout=15,
        ).stdout.strip()

    def write_formula(self, root, version, description=""):
        path = root / self.formula
        path.parent.mkdir(parents=True, exist_ok=True)
        metadata = f'  desc "{description}"\n' if description else ""
        path.write_text(f'class CcNotes < Formula\n  version "{version}"\n{metadata}end\n')

    def current(self):
        return self.git(self.root, "--git-dir", str(self.remote), "show", f"main:{self.formula}")

    def head(self):
        return self.git(self.root, "--git-dir", str(self.remote), "rev-parse", "main")

    def publish(self, version, description=""):
        self.write_formula(self.staging, version, description)
        return subprocess.run(
            ["bash", os.environ["PUBLISH_SCRIPT"]], cwd=self.root, env=self.env,
            capture_output=True, text=True, timeout=30,
        )

    def clone_checkout(self):
        self.git(self.root, "clone", str(self.remote), str(self.checkout))

    def advance(self, version):
        self.write_formula(self.seed, version)
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-m", f"release {version}")
        self.git(self.seed, "push", "origin", "main")

    def race(self, version=None):
        previous = self.head()
        if version is not None:
            self.write_formula(self.seed, version)
        (self.seed / "unrelated.txt").write_text("concurrent\n")
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-m", "concurrent publication")
        next_head = self.git(self.seed, "rev-parse", "HEAD")
        self.git(self.seed, "push", "origin", "HEAD:refs/heads/concurrent")
        marker = self.root / "race-fired"
        hook = self.checkout / ".git/hooks/pre-push"
        hook.write_text(
            "#!/bin/sh\nset -eu\n"
            f"if [ ! -e {shlex.quote(str(marker))} ]; then\n"
            f"  touch {shlex.quote(str(marker))}\n"
            "  unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE\n"
            "  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES\n"
            f"  git --git-dir={shlex.quote(str(self.remote))} update-ref refs/heads/main {next_head} {previous}\n"
            "fi\n"
        )
        hook.chmod(0o755)
        return marker

    def test_numeric_patch_order_advances(self):
        self.clone_checkout()
        result = self.publish("1.0.10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('version "1.0.10"', self.current())

    def test_older_and_equal_targets_do_not_mutate(self):
        self.advance("1.0.11")
        self.clone_checkout()
        before = self.head()
        for version in ["1.0.10", "1.0.11"]:
            with self.subTest(version=version):
                result = self.publish(version)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.head(), before)

    def test_newer_race_rejects_and_skips_stale_payload(self):
        self.clone_checkout()
        marker = self.race("1.0.11")
        result = self.publish("1.0.10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(marker.is_file())
        self.assertIn('version "1.0.11"', self.current())
        self.assertIn("newer than the target", result.stdout)

    def test_equal_version_changed_metadata_uses_existing_writer_policy(self):
        self.advance("1.0.10")
        self.clone_checkout()
        before = self.head()
        result = self.publish("1.0.10", "updated metadata")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual(self.head(), before)
        self.assertEqual(self.current(), (self.staging / self.formula).read_text().strip())

    def test_monotonic_retirement_combination_is_rejected_before_publication(self):
        retirement = self.seed / "Casks/retire-me.rb"
        retirement.parent.mkdir(parents=True)
        retirement.write_text('cask "retire-me" do\nend\n')
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-m", "retirement fixture")
        self.git(self.seed, "push", "origin", "main")
        self.clone_checkout()
        before = self.head()
        self.env["DELETE_FILE"] = "Casks/retire-me.rb"
        result = self.publish("1.0.10")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("monotonic-file cannot be combined with delete-file", result.stderr)
        self.assertEqual(self.head(), before)
        self.assertEqual(
            self.git(self.root, "--git-dir", str(self.remote), "show", "main:Casks/retire-me.rb"),
            retirement.read_text().strip(),
        )

    def test_older_race_reapplies_newer_payload(self):
        self.clone_checkout()
        marker = self.race("1.0.10")
        result = self.publish("1.0.11")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(marker.is_file())
        self.assertIn('version "1.0.11"', self.current())
        self.assertEqual(self.git(self.root, "--git-dir", str(self.remote), "show", "main:unrelated.txt"), "concurrent")

    def test_unrelated_race_preserves_other_changes(self):
        self.clone_checkout()
        marker = self.race()
        result = self.publish("1.0.10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(marker.is_file())
        self.assertIn('version "1.0.10"', self.current())
        self.assertEqual(self.git(self.root, "--git-dir", str(self.remote), "show", "main:unrelated.txt"), "concurrent")

    def test_malformed_current_version_fails_without_push(self):
        self.advance("not-semver")
        self.clone_checkout()
        before = self.head()
        result = self.publish("1.0.10")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected one numeric formula version", result.stderr)
        self.assertEqual(self.head(), before)

    def test_unselected_existing_publish_path(self):
        self.clone_checkout()
        self.env["MONOTONIC_FILE"] = ""
        result = self.publish("1.0.10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('version "1.0.10"', self.current())


if __name__ == "__main__":
    unittest.main()
