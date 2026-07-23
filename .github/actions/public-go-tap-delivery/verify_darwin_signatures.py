#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unicodedata


TEAM_ID = "SXKCTF23Q2"
MAX_EXPANDED_BYTES = 1024 * 1024 * 1024
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
DARWIN_PAYLOAD_RE = re.compile(r"(?:^|[-_])darwin[-_](amd64|arm64|universal)(\.tar\.gz)?$")
DARWIN_LOOKING_RE = re.compile(r"(?:^|[-_])darwin(?:[-_.]|$)", re.IGNORECASE)


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def is_macho(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(4) in MACHO_MAGICS


def safe_extract_tar(archive: Path, destination: Path) -> list[Path]:
    destination.mkdir()
    files: list[Path] = []
    seen: set[PurePosixPath] = set()
    seen_platform_paths: set[str] = set()
    expanded = 0
    try:
        bundle = tarfile.open(archive, mode="r:gz")
    except (tarfile.TarError, OSError) as exc:
        fail(f"Darwin archive {archive.name!r} is not a valid tar.gz: {exc}")
    with bundle:
        for member in bundle.getmembers():
            raw_name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
            raw_parts = raw_name.split("/")
            if (
                not raw_name
                or raw_name.startswith("/")
                or "\\" in raw_name
                or any(part in ("", ".", "..") for part in raw_parts)
            ):
                fail(f"Darwin archive {archive.name!r} contains unsafe path {member.name!r}")
            relative = PurePosixPath(*raw_parts)
            if relative in seen:
                fail(f"Darwin archive {archive.name!r} repeats path {member.name!r}")
            seen.add(relative)
            platform_path = unicodedata.normalize("NFD", relative.as_posix()).casefold()
            if platform_path in seen_platform_paths:
                fail(f"Darwin archive {archive.name!r} contains platform-aliased path {member.name!r}")
            seen_platform_paths.add(platform_path)
            if member.isdir():
                (destination / Path(*relative.parts)).mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                fail(f"Darwin archive {archive.name!r} contains non-regular entry {member.name!r}")
            expanded += member.size
            if expanded > MAX_EXPANDED_BYTES:
                fail(f"Darwin archive {archive.name!r} exceeds the expanded-size limit")
            target = destination / Path(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            if source is None:
                fail(f"Darwin archive {archive.name!r} could not read {member.name!r}")
            with source, target.open("wb") as handle:
                shutil.copyfileobj(source, handle)
            os.chmod(target, member.mode & 0o777)
            files.append(target)
    return files


def command(*args: str) -> str:
    result = subprocess.run(args, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        fail(f"command {' '.join(args[:3])} failed: {detail}")
    return result.stdout + result.stderr


def verify_macho(path: Path, expected_arch: str) -> None:
    command("codesign", "--verify", "--deep", "--strict", "--verbose=4", str(path))
    details = command("codesign", "-d", "--verbose=4", str(path))
    if not re.search(rf"^TeamIdentifier={re.escape(TEAM_ID)}$", details, re.MULTILINE):
        fail(f"Mach-O {path.name!r} is not signed by TeamIdentifier {TEAM_ID}")
    authorities = re.findall(r"^Authority=(.+)$", details, re.MULTILINE)
    if not any(value.startswith("Developer ID Application:") and f"({TEAM_ID})" in value for value in authorities):
        fail(f"Mach-O {path.name!r} has no embedded Developer ID Application authority for {TEAM_ID}")
    if not re.search(r"\bflags=.*\bruntime\b", details):
        fail(f"Mach-O {path.name!r} does not enable hardened runtime")
    actual_arches = command("lipo", "-archs", str(path)).strip().split()
    wanted = {"x86_64", "arm64"} if expected_arch == "universal" else {
        "x86_64" if expected_arch == "amd64" else "arm64"
    }
    if set(actual_arches) != wanted or len(actual_arches) != len(wanted):
        fail(f"Mach-O {path.name!r} architectures {actual_arches} do not equal expected {sorted(wanted)}")


def verify_archive(archive: Path, expected_arch: str) -> None:
    with tempfile.TemporaryDirectory(prefix="public-go-tap-darwin-") as raw:
        files = safe_extract_tar(archive, Path(raw) / "contents")
        macho_files = [path for path in files if is_macho(path)]
        if not macho_files:
            fail(f"Darwin archive {archive.name!r} contains no Mach-O payload")
        for path in files:
            if path not in macho_files and path.stat().st_mode & 0o111:
                fail(f"Darwin archive {archive.name!r} contains executable non-Mach-O payload {path.name!r}")
        for path in macho_files:
            verify_macho(path, expected_arch)


def verify_release_assets(asset_dir: Path, expected_sha: dict[str, str]) -> None:
    if sys.platform != "darwin":
        fail("Darwin signature verification requires a macOS runner")
    targets: dict[str, dict[str, str]] = {"amd64": {}, "arm64": {}, "universal": {}}
    for name in expected_sha:
        match = DARWIN_PAYLOAD_RE.search(name)
        if match:
            arch = match.group(1)
            kind = match.group(2) or "bare"
            if kind in targets[arch]:
                fail(f"multiple Darwin {arch} {kind} delivery payloads are forbidden")
            targets[arch][kind] = name
        elif DARWIN_LOOKING_RE.search(name):
            fail(f"unsupported Darwin-looking public asset {name!r}")

    archive_shapes = {arch for arch, payloads in targets.items() if ".tar.gz" in payloads}
    if archive_shapes not in ({"universal"}, {"amd64", "arm64"}):
        fail(f"Darwin tar.gz delivery payloads do not cover both architectures exactly: {sorted(archive_shapes)}")
    bare_shapes = {arch for arch, payloads in targets.items() if "bare" in payloads}
    if bare_shapes and bare_shapes not in ({"universal"}, {"amd64", "arm64"}):
        fail(f"bare Darwin delivery payloads do not cover both architectures exactly: {sorted(bare_shapes)}")

    for arch, payloads in targets.items():
        for kind, name in payloads.items():
            path = asset_dir / name
            if kind == ".tar.gz":
                verify_archive(path, arch)
            else:
                if not is_macho(path):
                    fail(f"bare Darwin asset {name!r} is not a Mach-O payload")
                verify_macho(path, arch)
