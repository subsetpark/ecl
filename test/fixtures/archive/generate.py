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


def tar_payload(
    entries: list[tuple[tarfile.TarInfo, bytes]],
    format: int = tarfile.USTAR_FORMAT,
) -> bytes:
    tar_bytes = io.BytesIO()
    with tarfile.open(fileobj=tar_bytes, mode="w", format=format) as tar:
        for info, data in entries:
            tar.addfile(info, io.BytesIO(data) if info.type == tarfile.REGTYPE else None)
    return tar_bytes.getvalue()


def archive(
    entries: list[tuple[tarfile.TarInfo, bytes]],
    format: int = tarfile.USTAR_FORMAT,
) -> bytes:
    return compress(tar_payload(entries, format))


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
    (ROOT / name).write_text(encoded + "\n", encoding="ascii")


def fixtures() -> dict[str, bytes]:
    valid_entries = [
        (member("lib/", kind=tarfile.DIRTYPE), b""),
        (member("lib/main.ecl", b"42\n"), b"42\n"),
        (member("README.md", b"fixture\n"), b"fixture\n"),
    ]
    duplicate_info = member("same.ecl", b"one\n")
    duplicate_again = member("same.ecl", b"two\n")
    long_path = "pkg/" + "s" * 110 + ".ecl"
    long_info = member(long_path, b"long\n")
    malformed_tar = bytearray(tar_payload([(member("bad.ecl", b"x"), b"x")]))
    malformed_tar[0] ^= 1
    malformed_pax = bytearray(tar_payload([(long_info, b"long\n")], tarfile.PAX_FORMAT))
    assert malformed_pax[156] == ord("x")
    malformed_pax[512] = ord("0")
    return {
        "empty.tgz.hex": archive([]),
        "valid.tgz.hex": archive(valid_entries),
        "pax.tgz.hex": archive([(long_info, b"long\n")], tarfile.PAX_FORMAT),
        "gnu-long-name.tgz.hex": archive([(long_info, b"long\n")], tarfile.GNU_FORMAT),
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
        "malformed-tar.tgz.hex": compress(bytes(malformed_tar)),
        "malformed-pax.tgz.hex": compress(bytes(malformed_pax)),
        "malformed.tgz.hex": b"not a gzip stream",
    }
def main() -> None:
    for name, payload in fixtures().items():
        emit(name, payload)


if __name__ == "__main__":
    main()
