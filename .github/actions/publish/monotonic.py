import re
import sys
from pathlib import Path


def version(path: Path) -> tuple[int, int, int]:
    values = re.findall(r'^  version "(\d+)\.(\d+)\.(\d+)"$', path.read_text(), re.M)
    if len(values) != 1:
        raise ValueError(f"expected one numeric formula version in {path}")
    return tuple(map(int, values[0]))


if __name__ == "__main__":
    target, current = map(Path, sys.argv[1:])
    print("skip" if version(target) < version(current) else "advance")
