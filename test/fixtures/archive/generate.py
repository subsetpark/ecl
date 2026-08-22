#!/usr/bin/env python3
"""Regenerate the deterministic archive fixture corpus."""

from __future__ import annotations

import gzip
import io
from pathlib import Path
import tarfile


ROOT = Path(__file__).parent


def member(name: str, data: bytes = b"", kind: bytes = tarfile.REGTYPE) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.size = len(data) if kind == tarfile.REGTYPE else 0
    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
        info.linkname = "target"
    return info


def archive(entries: list[tuple[tarfile.TarInfo, bytes]]) -> bytes:
    tar_bytes = io.BytesIO()
    with tarfile.open(fileobj=tar_bytes, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for info, data in entries:
            tar.addfile(info, io.BytesIO(data) if info.type == tarfile.REGTYPE else None)
    return compress(tar_bytes.getvalue())


def compress(payload: bytes) -> bytes:
    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=0) as stream:
        stream.write(payload)
    return compressed.getvalue()


def oversized() -> bytes:
    info = member("too-large.bin")
    info.size = 1_073_741_825
    return compress(info.tobuf(format=tarfile.USTAR_FORMAT) + bytes(1024))


def emit(name: str, payload: bytes) -> None:
    encoded = payload.hex()
    text = "\n".join(encoded[index : index + 64] for index in range(0, len(encoded), 64))
    (ROOT / name).write_text(text + "\n", encoding="ascii")


def fixtures() -> dict[str, bytes]:
    valid_entries = [
        (member("lib/", kind=tarfile.DIRTYPE), b""),
        (member("lib/main.ecl", b"42\n"), b"42\n"),
        (member("README.md", b"fixture\n"), b"fixture\n"),
    ]
    duplicate_info = member("same.ecl", b"one\n")
    duplicate_again = member("same.ecl", b"two\n")
    return {
        "valid.tgz.hex": archive(valid_entries),
        "absolute-path.tgz.hex": archive([(member("/escape.ecl", b"x"), b"x")]),
        "parent-path.tgz.hex": archive([(member("../escape.ecl", b"x"), b"x")]),
        "symlink.tgz.hex": archive([(member("link", kind=tarfile.SYMTYPE), b"")]),
        "hardlink.tgz.hex": archive([(member("link", kind=tarfile.LNKTYPE), b"")]),
        "char-device.tgz.hex": archive([(member("device", kind=tarfile.CHRTYPE), b"")]),
        "block-device.tgz.hex": archive([(member("device", kind=tarfile.BLKTYPE), b"")]),
        "fifo.tgz.hex": archive([(member("pipe", kind=tarfile.FIFOTYPE), b"")]),
        "duplicate.tgz.hex": archive(
            [(duplicate_info, b"one\n"), (duplicate_again, b"two\n")]
        ),
        "oversized.tgz.hex": oversized(),
        "malformed.tgz.hex": b"not a gzip stream",
    }
def main() -> None:
    for name, payload in fixtures().items():
        emit(name, payload)


if __name__ == "__main__":
    main()
