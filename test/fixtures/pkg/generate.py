#!/usr/bin/env python3
"""Regenerate deterministic source-package fixtures."""

from __future__ import annotations

import gzip
import hashlib
import io
from pathlib import Path
import tarfile


ROOT = Path(__file__).parent
MANIFEST = (
    b"{'format 1 'name \"a\" 'version \"1.0.0\" "
    b"'exports {\"a\" [\"**/*\"]} 'requires {}}\n"
)


def archive(source: bytes) -> bytes:
    tar_bytes = io.BytesIO()
    with tarfile.open(fileobj=tar_bytes, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in (("a.ecl", source), ("ecl.pkg", MANIFEST)):
            info = tarfile.TarInfo(name)
            info.mode = 0o644
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=0) as stream:
        stream.write(tar_bytes.getvalue())
    return compressed.getvalue()


def main() -> None:
    fixtures = {
        "valid.tgz.hex": archive(b"(() 'noop def) 'a @defm\n"),
        "runtime-valid.tgz.hex": archive(b"((42) 'answer def) 'a @defm\n"),
    }
    for name, payload in fixtures.items():
        (ROOT / name).write_text(payload.hex() + "\n", encoding="ascii")
        print(f"{name} sha256-{hashlib.sha256(payload).hexdigest()}")


if __name__ == "__main__":
    main()
