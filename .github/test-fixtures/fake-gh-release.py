#!/usr/bin/env python3
import json
import os
import shutil
import sys
import urllib.parse
from pathlib import Path


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(2)


state_dir = Path(os.environ["FAKE_GH_STATE"])
state_path = state_dir / "state.json"
scenario = os.environ["FAKE_GH_SCENARIO"]
state_dir.mkdir(parents=True, exist_ok=True)

if state_path.exists():
    state = json.loads(state_path.read_text())
else:
    state = {
        "list_calls": 0,
        "post_calls": 0,
        "releases": [],
        "assets": [],
        "next_asset_id": 1000,
    }


def save() -> None:
    state_path.write_text(json.dumps(state, sort_keys=True))


def emit(value: object) -> None:
    json.dump(value, sys.stdout)
    sys.stdout.write("\n")


def release(release_id: int, tag: str, prerelease: bool, draft: bool = True) -> dict:
    return {
        "id": release_id,
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "upload_url": (
            f"https://uploads.github.com/repos/example/project/releases/{release_id}/assets"
            "{?name,label}"
        ),
    }


if len(sys.argv) < 3 or sys.argv[1] != "api":
    die("fake gh only supports gh api")

method = "GET"
input_path = None
endpoint = None
i = 2
while i < len(sys.argv):
    arg = sys.argv[i]
    if arg in {"--method", "-X"}:
        i += 1
        method = sys.argv[i]
    elif arg == "--input":
        i += 1
        input_path = sys.argv[i]
    elif arg in {"-H", "--header"}:
        i += 1
    elif arg == "--paginate":
        pass
    elif arg.startswith("-"):
        die(f"unsupported fake gh option: {arg}")
    elif endpoint is None:
        endpoint = arg
    else:
        die("multiple fake gh endpoints")
    i += 1

if endpoint is None:
    die("fake gh endpoint is required")

releases_endpoint = "repos/example/project/releases"
if method == "GET" and endpoint == f"{releases_endpoint}?per_page=100":
    state["list_calls"] += 1
    save()
    if scenario == "delayed-list":
        emit([])
    elif scenario == "lost-response" and state["post_calls"] > 0 and state["list_calls"] == 2:
        emit([])
    else:
        emit(state["releases"])
    raise SystemExit(0)

if method == "POST" and endpoint == releases_endpoint:
    if input_path is None:
        die("create payload is missing")
    payload = json.loads(Path(input_path).read_text())
    state["post_calls"] += 1
    if scenario == "delayed-list":
        created = release(101, payload["tag_name"], payload["prerelease"])
        state["releases"] = [created]
        save()
        emit(created)
        raise SystemExit(0)
    if scenario == "ambiguous-response":
        state["releases"] = [release(106, payload["tag_name"], payload["prerelease"])]
        save()
        emit({"id": "not-numeric"})
        raise SystemExit(0)
    if scenario == "lost-response":
        state["releases"] = [release(102, payload["tag_name"], payload["prerelease"])]
    elif scenario == "duplicate":
        state["releases"] = [
            release(103, payload["tag_name"], payload["prerelease"]),
            release(104, payload["tag_name"], payload["prerelease"]),
        ]
    elif scenario == "public-conflict":
        state["releases"] = [
            release(105, payload["tag_name"], payload["prerelease"], draft=False)
        ]
    else:
        die(f"unsupported create scenario: {scenario}")
    save()
    raise SystemExit(1)

if endpoint.startswith(f"{releases_endpoint}/") and endpoint.endswith("/assets?per_page=100"):
    emit([{"id": asset["id"], "name": asset["name"]} for asset in state["assets"]])
    raise SystemExit(0)

asset_endpoint = f"{releases_endpoint}/assets/"
if endpoint.startswith(asset_endpoint):
    try:
        asset_id = int(endpoint.removeprefix(asset_endpoint))
    except ValueError:
        die(f"invalid asset endpoint: {endpoint}")
    for index, asset in enumerate(state["assets"]):
        if asset["id"] != asset_id:
            continue
        if method == "DELETE":
            Path(asset["path"]).unlink(missing_ok=True)
            state["assets"].pop(index)
            save()
            raise SystemExit(0)
        if method == "GET":
            sys.stdout.buffer.write(Path(asset["path"]).read_bytes())
            raise SystemExit(0)
    raise SystemExit(1)

if method == "GET" and endpoint.startswith(f"{releases_endpoint}/"):
    try:
        release_id = int(endpoint.rsplit("/", 1)[1])
    except ValueError:
        die(f"invalid release endpoint: {endpoint}")
    for item in state["releases"]:
        if item["id"] == release_id:
            emit(item)
            raise SystemExit(0)
    raise SystemExit(1)

if method == "POST" and endpoint.startswith("https://uploads.github.com/"):
    if input_path is None:
        die("upload input is missing")
    query = urllib.parse.parse_qs(urllib.parse.urlparse(endpoint).query)
    names = query.get("name", [])
    if len(names) != 1:
        die("upload name is missing or ambiguous")
    asset_id = state["next_asset_id"]
    state["next_asset_id"] += 1
    stored = state_dir / f"asset-{asset_id}"
    shutil.copyfile(input_path, stored)
    state["assets"].append({"id": asset_id, "name": names[0], "path": str(stored)})
    save()
    emit({"id": asset_id, "name": names[0]})
    raise SystemExit(0)

die(f"unsupported fake gh call: {method} {endpoint}")
