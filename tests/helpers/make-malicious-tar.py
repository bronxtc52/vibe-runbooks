#!/usr/bin/env python3
"""Build deterministic hostile tar fixtures for bootstrap rejection tests."""

from __future__ import annotations

import gzip
import io
import sys
import tarfile
from pathlib import Path


def add_dir(archive: tarfile.TarFile, name: str) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = 0
    archive.addfile(info)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: make-malicious-tar.py KIND OUTPUT VERSION")
    kind, output, version = sys.argv[1:]
    root = f"vibe-mac-{version}"
    with Path(output).open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                add_dir(archive, root)
                if kind == "traversal":
                    info = tarfile.TarInfo(f"{root}/../../escape")
                    payload = b"escape\n"
                    info.size = len(payload)
                    info.mode = 0o600
                    info.mtime = 0
                    archive.addfile(info, io.BytesIO(payload))
                elif kind == "absolute":
                    info = tarfile.TarInfo("/tmp/vibe-mac-escape")
                    payload = b"escape\n"
                    info.size = len(payload)
                    info.mode = 0o600
                    info.mtime = 0
                    archive.addfile(info, io.BytesIO(payload))
                elif kind == "hardlink":
                    info = tarfile.TarInfo(f"{root}/hardlink")
                    info.type = tarfile.LNKTYPE
                    info.linkname = f"{root}/install.sh"
                    info.mode = 0o700
                    info.mtime = 0
                    archive.addfile(info)
                else:
                    raise SystemExit(f"unknown kind: {kind}")


if __name__ == "__main__":
    main()
