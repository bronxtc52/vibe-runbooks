#!/usr/bin/env python3
"""Small test adapter for the macOS plutil operations used by vibe-mac."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(str(exc))


def walk(data: object, keypath: str) -> tuple[dict[str, object], str]:
    parts = keypath.split(".")
    if not parts or any(not part for part in parts):
        die("invalid key path")
    current = data
    for part in parts[:-1]:
        if not isinstance(current, dict) or part not in current:
            die("missing key")
        current = current[part]
    if not isinstance(current, dict):
        die("parent is not a dictionary")
    return current, parts[-1]


def main() -> None:
    args = sys.argv[1:]
    if not args:
        die("missing arguments")

    if args[0] == "-lint":
        load(Path(args[-1]))
        return

    if args[0] == "-extract":
        keypath = args[1]
        path = Path(args[-1])
        data = load(path)
        parent, key = walk(data, keypath)
        if key not in parent:
            die("missing key")
        value = parent[key]
        if isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, (str, int, float)):
            print(value)
        else:
            print(json.dumps(value, separators=(",", ":")))
        return

    if args[0] == "-replace":
        if os.environ.get("PLUTIL_STUB_FAIL_REPLACE") == "1":
            die("injected replace failure")
        keypath = args[1]
        value_type = args[2]
        value = args[3]
        path = Path(args[-1])
        data = load(path)
        parent, key = walk(data, keypath)
        if key not in parent:
            die("missing key")
        if value_type == "-string":
            parent[key] = value
        elif value_type == "-integer":
            parent[key] = int(value)
        elif value_type == "-bool":
            parent[key] = value.lower() in {"yes", "true", "1"}
        else:
            die("unsupported type")
        path.write_text(
            json.dumps(data, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        return

    die("unsupported operation")


if __name__ == "__main__":
    main()
