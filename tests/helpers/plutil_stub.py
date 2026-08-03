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

    if args[0] == "-convert":
        if len(args) < 6 or args[1] != "json" or "-o" not in args:
            die("unsupported convert operation")
        output_index = args.index("-o") + 1
        if output_index >= len(args):
            die("missing output path")
        output_path = args[output_index]
        data = load(Path(args[-1]))
        converted = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
        if output_path == "/dev/null":
            return
        if output_path == "-":
            print(converted)
            return
        Path(output_path).write_text(converted + "\n", encoding="utf-8")
        return

    if args[0] == "-extract":
        keypath = args[1]
        output_format = args[2]
        if output_format not in {"json", "raw"}:
            die("unsupported extract format")
        path = Path(args[-1])
        data = load(path)
        parent, key = walk(data, keypath)
        if key not in parent:
            die("missing key")
        value = parent[key]
        if "-expect" in args:
            expected_index = args.index("-expect") + 1
            if expected_index >= len(args):
                die("missing expected type")
            expected = args[expected_index]
            expected_types = {
                "array": list,
                "bool": bool,
                "dictionary": dict,
                "integer": int,
                "string": str,
            }
            if expected not in expected_types:
                die("unsupported expected type")
            if not isinstance(value, expected_types[expected]) or (
                expected == "integer" and isinstance(value, bool)
            ):
                die("unexpected type")
        if output_format == "json":
            print(json.dumps(value, separators=(",", ":"), ensure_ascii=False))
        elif isinstance(value, dict):
            print("\n".join(value))
        elif isinstance(value, list):
            print(len(value))
        elif isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, (str, int, float)):
            print(value)
        else:
            print(json.dumps(value, separators=(",", ":")))
        return

    if args[0] in {"-replace", "-insert"}:
        if os.environ.get("PLUTIL_STUB_FAIL_REPLACE") == "1":
            die("injected replace failure")
        operation = args[0]
        keypath = args[1]
        value_type = args[2]
        value = args[3]
        path = Path(args[-1])
        data = load(path)
        parent, key = walk(data, keypath)
        if operation == "-replace" and key not in parent:
            die("missing key")
        if operation == "-insert" and key in parent:
            die("key already exists")
        if value_type == "-string":
            parent[key] = value
        elif value_type == "-integer":
            parent[key] = int(value)
        elif value_type == "-bool":
            parent[key] = value.lower() in {"yes", "true", "1"}
        elif value_type == "-json":
            parent[key] = json.loads(value)
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
