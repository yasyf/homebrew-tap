#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

from verify_darwin_signatures import verify_release_assets


ASSET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
DELIVERY_RE = re.compile(r"^[a-z0-9][a-z0-9+._-]*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SOURCE_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SEMVER_RE = re.compile(
    r"^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
TOKEN_RE = re.compile(r"^__[A-Z0-9_]+__$")
CHECKSUM_LINE_RE = re.compile(r"^([0-9A-Fa-f]{64})[ \t]+\*?([A-Za-z0-9._+-]+)$")


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        fail(f"{name} is required")
    return value


def strict_object(raw: str, label: str) -> dict[str, str]:
    def pairs_hook(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label} contains duplicate key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(raw, object_pairs_hook=pairs_hook)
    except (json.JSONDecodeError, TypeError) as exc:
        fail(f"{label} is not a valid JSON object: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    if not all(isinstance(key, str) and isinstance(item, str) for key, item in value.items()):
        fail(f"{label} keys and values must be strings")
    return value


def gh_bytes(*args: str) -> bytes:
    command = ["gh", "api", *args]
    result = subprocess.run(command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        fail(f"GitHub API request failed: {detail}")
    return result.stdout


def gh_json(endpoint: str) -> object:
    raw = gh_bytes(endpoint)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"GitHub API returned invalid JSON for {endpoint}: {exc}")


def validate_source_path(path: str, mode: str, delivery_name: str) -> None:
    if (
        path.startswith("/")
        or path.startswith("./")
        or "//" in path
        or not re.fullmatch(r"[A-Za-z0-9._/-]+", path)
        or any(part in ("", ".", "..") for part in path.split("/"))
    ):
        fail(f"source-path is not a canonical repository-relative path: {path!r}")
    if mode == "formula-template" and not path.endswith((".tmpl", ".rb")):
        fail("formula-template source-path must end in .tmpl or .rb")
    if mode == "formula-template" and Path(path).name not in (
        f"{delivery_name}.rb.tmpl",
        f"{delivery_name}.rb",
    ):
        fail("formula-template source-path basename must equal delivery-name")
    if mode == "goreleaser-cask" and not path.endswith((".yaml", ".yml")):
        fail("goreleaser-cask source-path must end in .yaml or .yml")


def validate_release(release: object, release_id: int, tag: str, label: str) -> dict[str, object]:
    if not isinstance(release, dict):
        fail(f"{label} release response is not an object")
    if release.get("id") != release_id:
        fail(f"{label} release ID does not equal {release_id}")
    if release.get("tag_name") != tag:
        fail(f"{label} release tag does not equal {tag!r}")
    if release.get("draft") is not False:
        fail(f"release {release_id} is not public")
    if release.get("prerelease") is not False:
        fail(f"release {release_id} is a prerelease")
    return release


def peel_tag(repository: str, tag: str) -> str:
    ref = gh_json(f"repos/{repository}/git/ref/tags/{quote(tag, safe='')}")
    if not isinstance(ref, dict) or not isinstance(ref.get("object"), dict):
        fail(f"tag ref {tag!r} is malformed")
    current = ref["object"]
    seen: set[str] = set()
    for _ in range(16):
        object_type = current.get("type")
        object_sha = current.get("sha")
        if not isinstance(object_sha, str) or not SOURCE_SHA_RE.fullmatch(object_sha):
            fail(f"tag {tag!r} contains an invalid Git object SHA")
        if object_type == "commit":
            return object_sha
        if object_type != "tag":
            fail(f"tag {tag!r} resolves to unsupported Git object type {object_type!r}")
        if object_sha in seen:
            fail(f"tag {tag!r} contains an annotated-tag cycle")
        seen.add(object_sha)
        annotated = gh_json(f"repos/{repository}/git/tags/{object_sha}")
        if not isinstance(annotated, dict) or not isinstance(annotated.get("object"), dict):
            fail(f"annotated tag object {object_sha} is malformed")
        current = annotated["object"]
    fail(f"tag {tag!r} exceeds the annotated-tag peel limit")


def release_assets(release: dict[str, object]) -> dict[str, dict[str, object]]:
    rows = release.get("assets")
    if not isinstance(rows, list) or not rows:
        fail("public release has no assets")
    result: dict[str, dict[str, object]] = {}
    for row in rows:
        if not isinstance(row, dict):
            fail("public release contains a malformed asset")
        name = row.get("name")
        asset_id = row.get("id")
        size = row.get("size")
        if not isinstance(name, str) or not ASSET_RE.fullmatch(name):
            fail(f"public release contains an unsafe asset name: {name!r}")
        if name in result:
            fail(f"public release contains duplicate asset name {name!r}")
        if not isinstance(asset_id, int) or asset_id <= 0:
            fail(f"public release asset {name!r} has an invalid ID")
        if not isinstance(size, int) or size < 0:
            fail(f"public release asset {name!r} has an invalid size")
        result[name] = row
    return result


def validate_asset_contract(
    rows: dict[str, dict[str, object]], expected_sha: dict[str, str]
) -> None:
    if set(rows) != set(expected_sha):
        missing = sorted(set(rows) - set(expected_sha))
        extra = sorted(set(expected_sha) - set(rows))
        fail(f"asset-sha256 differs from the exact public asset set; missing={missing}, extra={extra}")
    for name, row in rows.items():
        digest = row.get("digest")
        if digest is not None and digest != f"sha256:{expected_sha[name]}":
            fail(f"GitHub records digest {digest!r} for {name!r}, expected sha256:{expected_sha[name]}")
        if row.get("state") != "uploaded":
            fail(f"public release asset {name!r} is not in uploaded state")


def download_assets(
    repository: str,
    rows: dict[str, dict[str, object]],
    expected_sha: dict[str, str],
    destination: Path,
) -> None:
    destination.mkdir()
    for name in sorted(rows):
        row = rows[name]
        payload = gh_bytes(
            "-H",
            "Accept: application/octet-stream",
            f"repos/{repository}/releases/assets/{row['id']}",
        )
        if len(payload) != row["size"]:
            fail(f"downloaded asset {name!r} has size {len(payload)}, expected {row['size']}")
        actual_sha = hashlib.sha256(payload).hexdigest()
        if actual_sha != expected_sha[name]:
            fail(f"downloaded asset {name!r} has SHA-256 {actual_sha}, expected {expected_sha[name]}")
        (destination / name).write_bytes(payload)


def verify_checksum_closure(asset_dir: Path, expected_sha: dict[str, str]) -> None:
    checksum_names = [
        name
        for name in expected_sha
        if name.lower().endswith("checksums.txt") or name.lower() == "sha256sums.txt"
    ]
    if len(checksum_names) != 1:
        fail(f"expected exactly one checksum asset, found {len(checksum_names)}")
    checksum_name = checksum_names[0]
    try:
        lines = (asset_dir / checksum_name).read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as exc:
        fail(f"checksum asset {checksum_name!r} is not UTF-8: {exc}")
    entries: dict[str, str] = {}
    for index, line in enumerate(lines, start=1):
        match = CHECKSUM_LINE_RE.fullmatch(line)
        if not match:
            fail(f"checksum asset {checksum_name!r} has malformed line {index}")
        sha, name = match.groups()
        sha = sha.lower()
        if name in entries:
            fail(f"checksum asset {checksum_name!r} repeats {name!r}")
        entries[name] = sha
    expected_names = set(expected_sha) - {checksum_name}
    if set(entries) != expected_names:
        missing = sorted(expected_names - set(entries))
        extra = sorted(set(entries) - expected_names)
        fail(f"checksum asset closure differs from the public manifest; missing={missing}, extra={extra}")
    for name, sha in entries.items():
        if sha != expected_sha[name]:
            fail(f"checksum asset records {sha} for {name!r}, expected {expected_sha[name]}")
        actual = hashlib.sha256((asset_dir / name).read_bytes()).hexdigest()
        if actual != sha:
            fail(f"checksum verification failed for {name!r}")


def fetch_source(repository: str, source_path: str, source_sha: str, destination: Path) -> None:
    endpoint = f"repos/{repository}/contents/{quote(source_path, safe='/')}"
    payload = gh_bytes(
        "--method",
        "GET",
        "-H",
        "Accept: application/vnd.github.raw+json",
        endpoint,
        "-f",
        f"ref={source_sha}",
    )
    if not payload:
        fail(f"tagged source contract {source_path!r} is empty")
    destination.write_bytes(payload)


def target_asset(expected_sha: dict[str, str], os_name: str, arch: str) -> str:
    pattern = re.compile(rf"(?:^|_){re.escape(os_name)}_{re.escape(arch)}(?:\.|_)")
    matches = sorted(
        name
        for name in expected_sha
        if name.endswith(".tar.gz") and pattern.search(name)
    )
    if len(matches) != 1:
        fail(f"expected one {os_name}/{arch} tar.gz asset, found {matches}")
    return matches[0]


def render_formula(
    template: Path,
    output: Path,
    version: str,
    expected_sha: dict[str, str],
    custom_tokens: dict[str, str],
) -> None:
    try:
        content = template.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        fail(f"formula template is not UTF-8: {exc}")
    content = content.replace("__VERSION__", version)
    standard = {
        "__SHA_DARWIN_ARM64__": ("darwin", "arm64"),
        "__SHA_DARWIN_AMD64__": ("darwin", "amd64"),
        "__SHA_LINUX_ARM64__": ("linux", "arm64"),
        "__SHA_LINUX_AMD64__": ("linux", "amd64"),
    }
    for token, target in standard.items():
        if token in content:
            name = target_asset(expected_sha, *target)
            content = content.replace(token, expected_sha[name])
    for token, name in custom_tokens.items():
        if not TOKEN_RE.fullmatch(token):
            fail(f"invalid template asset token {token!r}")
        if name not in expected_sha:
            fail(f"template asset token {token!r} names unknown asset {name!r}")
        if token not in content:
            fail(f"template asset token {token!r} is absent from the tagged template")
        content = content.replace(token, expected_sha[name])
    leftovers = sorted(set(re.findall(r"__[A-Z0-9_]+__", content)))
    if leftovers:
        fail(f"unfilled tokens remain in the tagged formula template: {leftovers}")
    output.parent.mkdir(parents=True)
    output.write_text(content, encoding="utf-8")


def render_cask(
    config: Path,
    output: Path,
    repository: str,
    tag: str,
    source_sha: str,
    source_path: str,
    delivery_name: str,
    expected_sha: dict[str, str],
) -> None:
    metadata = {
        "repository": repository,
        "tag": tag,
        "version": tag[1:],
        "source_sha": source_sha,
        "source_path": source_path,
        "delivery_name": delivery_name,
        "assets": expected_sha,
    }
    metadata_path = config.parent / "cask-metadata.json"
    metadata_path.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
    renderer = Path(os.environ["GITHUB_ACTION_PATH"]) / "render_goreleaser_cask.rb"
    result = subprocess.run(
        ["ruby", str(renderer), str(config), str(metadata_path), str(output)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        fail(f"GoReleaser cask rendering failed: {result.stderr.strip()}")


def delivery_relative_path(mode: str, delivery_name: str) -> Path:
    directory = "Formula" if mode == "formula-template" else "Casks"
    return Path(directory) / f"{delivery_name}.rb"


def main() -> None:
    repository = required_env("SOURCE_REPOSITORY")
    release_id_raw = required_env("RELEASE_ID")
    tag = required_env("RELEASE_TAG")
    source_sha = required_env("TAGGED_SOURCE_SHA")
    mode = required_env("DELIVERY_MODE")
    source_path = required_env("SOURCE_PATH")
    delivery_name = required_env("DELIVERY_NAME")
    if not re.fullmatch(r"yasyf/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
        fail("source-repository must be an exact yasyf owner/name repository")
    if not re.fullmatch(r"[1-9][0-9]*", release_id_raw):
        fail("release-id must be a positive decimal integer")
    release_id = int(release_id_raw)
    if not SEMVER_RE.fullmatch(tag):
        fail("tag must be an exact v-prefixed SemVer tag")
    if "-" in tag[1:].split("+", 1)[0]:
        fail("tag must be a stable SemVer tag")
    if not SOURCE_SHA_RE.fullmatch(source_sha):
        fail("tagged-source-sha must be a lowercase 40-character commit SHA")
    if mode not in ("formula-template", "goreleaser-cask"):
        fail("delivery-mode must be formula-template or goreleaser-cask")
    if not DELIVERY_RE.fullmatch(delivery_name):
        fail("delivery-name is not a safe Homebrew name")
    validate_source_path(source_path, mode, delivery_name)

    expected_sha = strict_object(required_env("ASSET_SHA256"), "asset-sha256")
    if not expected_sha:
        fail("asset-sha256 must not be empty")
    for name, sha in expected_sha.items():
        if not ASSET_RE.fullmatch(name):
            fail(f"asset-sha256 contains unsafe basename {name!r}")
        if not SHA256_RE.fullmatch(sha):
            fail(f"asset-sha256 value for {name!r} is not a lowercase SHA-256")
    custom_tokens = strict_object(os.environ.get("TEMPLATE_ASSET_TOKENS", "{}"), "template-asset-tokens")
    if mode != "formula-template" and custom_tokens:
        fail("template-asset-tokens is only valid for formula-template mode")

    by_id = validate_release(
        gh_json(f"repos/{repository}/releases/{release_id}"), release_id, tag, "ID-selected"
    )
    by_tag = validate_release(
        gh_json(f"repos/{repository}/releases/tags/{quote(tag, safe='')}"),
        release_id,
        tag,
        "tag-selected",
    )
    if by_id.get("node_id") != by_tag.get("node_id"):
        fail("release ID and tag do not select the same public release object")
    rows = release_assets(by_id)
    validate_asset_contract(rows, expected_sha)

    peeled_sha = peel_tag(repository, tag)
    if peeled_sha != source_sha:
        fail(f"tag {tag!r} peels to {peeled_sha}, expected {source_sha}")

    work = Path(tempfile.mkdtemp(prefix="public-go-tap-", dir=os.environ.get("RUNNER_TEMP")))
    asset_dir = work / "assets"
    download_assets(repository, rows, expected_sha, asset_dir)
    verify_checksum_closure(asset_dir, expected_sha)
    verify_release_assets(asset_dir, expected_sha)

    source_contract = work / ("formula.rb.tmpl" if mode == "formula-template" else "goreleaser.yaml")
    fetch_source(repository, source_path, source_sha, source_contract)
    staging = work / "tap-staging"
    output = staging / delivery_relative_path(mode, delivery_name)
    version = tag[1:]
    if mode == "formula-template":
        render_formula(source_contract, output, version, expected_sha, custom_tokens)
    else:
        render_cask(
            source_contract,
            output,
            repository,
            tag,
            source_sha,
            source_path,
            delivery_name,
            expected_sha,
        )
    if not output.is_file() or output.stat().st_size == 0:
        fail("renderer did not create a non-empty tap delivery")
    rendered = output.read_text(encoding="utf-8")
    if "{{" in rendered or re.search(r"__[A-Z0-9_]+__", rendered):
        fail("rendered tap delivery contains an unresolved source placeholder")
    syntax = subprocess.run(["ruby", "-c", str(output)], check=False, text=True, capture_output=True)
    if syntax.returncode != 0:
        fail(f"rendered tap delivery is not valid Ruby: {syntax.stderr.strip()}")
    files = [path for path in staging.rglob("*") if path.is_file()]
    if files != [output]:
        fail("tap staging must contain exactly one rendered delivery file")

    github_output = required_env("GITHUB_OUTPUT")
    with open(github_output, "a", encoding="utf-8") as handle:
        handle.write(f"staging-dir={staging}\n")
        handle.write(f"file={output.relative_to(staging)}\n")
    print(f"verified public release {release_id} ({tag}) at {source_sha}")
    print(f"rendered {output.relative_to(staging)} from {source_path}")


if __name__ == "__main__":
    main()
