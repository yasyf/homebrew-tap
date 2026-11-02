import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


baseline = str(Path(os.environ["PROBE_BASELINE_GIT"]).resolve(strict=True))
candidate = str(Path(os.environ["PROBE_CANDIDATE_GIT"]).resolve(strict=True))
output = Path(os.environ["PROBE_OUTPUT"])
output.mkdir(parents=True, exist_ok=True)
commands = []
rows = []


with tempfile.TemporaryDirectory(prefix="git-native-ref-controls-") as owned:
    root = Path(owned)
    environment = {
        "PATH": os.environ["PATH"], "HOME": str(root), "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1",
        "GIT_AUTHOR_NAME": "Probe", "GIT_AUTHOR_EMAIL": "probe@example.invalid",
        "GIT_COMMITTER_NAME": "Probe", "GIT_COMMITTER_EMAIL": "probe@example.invalid",
        "GIT_AUTHOR_DATE": "1700000000 +0000", "GIT_COMMITTER_DATE": "1700000000 +0000",
    }

    def run(binary, repo, arguments, data=None, namespace=""):
        argv = [binary, "-C", str(repo), *arguments]
        env = environment | ({"GIT_NAMESPACE": namespace} if namespace else {})
        result = subprocess.run(argv, input=data, capture_output=True, env=env, timeout=30)
        commands.append({"argv": argv, "namespace": namespace, "exit": result.returncode,
                         "stdin_sha256": hashlib.sha256(data).hexdigest() if data is not None else None,
                         "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        assert result.returncode == 0, commands[-1]
        return result.stdout.decode().strip()

    for algorithm in ["sha1", "sha256"]:
        for layout in ["loose", "packed"]:
            for namespace in ["", "team"]:
                label = f"{algorithm}-{layout}-{namespace or 'root'}"
                repo = root / label
                repo.mkdir()
                run(baseline, repo, ["init", "--bare", "--initial-branch=main", f"--object-format={algorithm}"])
                tree = run(baseline, repo, ["mktree"], b"")
                names = {"main": "refs/heads/main", "a": "refs/hidden/a", "b": "refs/hidden/b",
                         "sibling": "refs/hidden-sibling/kept", "after": "refs/zafter/kept"}
                prefix = f"refs/namespaces/{namespace}/" if namespace else ""
                oids = {}
                for name, refname in names.items():
                    oids[name] = run(baseline, repo, ["commit-tree", tree], (name + "\n").encode())
                    run(baseline, repo, ["update-ref", prefix + refname, oids[name]])
                alias = prefix + "refs/heads/alias"
                run(baseline, repo, ["symbolic-ref", alias, prefix + names["a"]])
                if layout == "packed":
                    run(baseline, repo, ["pack-refs", "--all"])
                all_names = set(oids)
                hidden_names = all_names - {"b"}
                cases = [
                    ("prefix", ["refs/hidden"], hidden_names),
                    ("trailing-slash", ["refs/hidden///"], hidden_names),
                    ("ordered-unhide", ["refs/hidden", "!refs/hidden/b"], all_names),
                    ("ordered-rehide", ["!refs/hidden/b", "refs/hidden"], hidden_names),
                    ("full-namespace", ["^" + prefix + "refs/hidden"], hidden_names),
                    ("literal-glob", ["refs/hidden/*"], all_names),
                    ("literal-backslash", [r"refs/hidden\a"], all_names),
                ]
                if namespace:
                    cases.append(("outside-namespace", ["^refs/hidden"], all_names))
                for case, patterns, expected in cases:
                    args = [value for pattern in patterns for value in ["-c", "fetch.hideRefs=" + pattern]]
                    args += ["rev-list", "--no-walk", "--exclude-hidden=fetch", "--all"]
                    before = run(baseline, repo, args, namespace=namespace)
                    after = run(candidate, repo, args, namespace=namespace)
                    row = {"fixture": label, "case": case, "expected_OIDs": sorted(oids[key] for key in expected),
                           "baseline": before.splitlines(), "candidate": after.splitlines()}
                    rows.append(row)
                    (output / "rows.json").write_text(json.dumps(rows, indent=2) + "\n")
                    assert before == after, row
                    assert set(before.splitlines()) == {oids[key] for key in expected}, row
                visible = {prefix + refname: oids[name] for name, refname in names.items() if name not in {"a", "b"}}
                visible[alias] = oids["a"]
                for marker in [prefix + "refs/heads/main", prefix + "refs/hidden", prefix + "refs/hidden/a"]:
                    args = ["for-each-ref", "--format=%(refname) %(objectname)",
                            "--exclude=" + prefix + "refs/hidden", "--start-after=" + marker]
                    expected = [f"{name} {oid}" for name, oid in sorted(visible.items()) if name > marker]
                    before = run(baseline, repo, args, namespace=namespace)
                    after = run(candidate, repo, args, namespace=namespace)
                    row = {"fixture": label, "case": "explicit-seek", "marker": marker,
                           "expected": expected, "baseline": before.splitlines(), "candidate": after.splitlines()}
                    rows.append(row)
                    (output / "rows.json").write_text(json.dumps(rows, indent=2) + "\n")
                    assert before == after and before.splitlines() == expected, row

report = {"status": "PASS", "baseline": baseline, "candidate": candidate, "cases": rows,
          "limits": ["Hosted private-fixture semantics only; no physical IO or installed Mac proof",
                     "Explicit seek may read an excluded directory; no zero-open claim for seek"]}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": "PASS", "cases": len(rows), "native_commands": len(commands)}))
