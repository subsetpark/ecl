"""Regenerate inert package-archive inputs for the ECL policy tests."""
import gzip
import io
from pathlib import Path
import tarfile

root = Path(__file__).parent
manifest = b'''{'format 2 'name "sample" 'version "1.0.0" 'sources ["src/**/*.ecl"] 'exports ["sample.api"] 'requires {}}'''
source = b'''"BAD" 'cwd "package-source-executed" fs.create-text [] ((7) 'value def) 'sample.api @defm [] () 'private.literal @defm ([] () 'nested @defm)'''
base = {"ecl.pkg": manifest, "src/api.ecl": source, "README.md": b"ordinary data\x00\xff"}
fixtures = {
    "valid": base,
    "missing-manifest": {"src/api.ecl": source},
    "missing-export": {**base, "src/api.ecl": b"[] () \"sample.api\" symbol @defm"},
    "duplicate-export": {**base, "src/again.ecl": b"[] () 'sample.api @defm"},
    "native": {**base, "lib/native.eclmod": b"arbitrary native payload"},
    "malformed-source": {**base, "src/api.ecl": b"("},
    "reserved": {**base, ".ecl-package.tgz": b"reserved"},
    "private-duplicates": {**base, "src/again.ecl": b"[] () 'private.literal @defm"},
    "symlink": base,
    "traversal": base,
}
for name, files in fixtures.items():
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for path, body in sorted(files.items()):
            member = tarfile.TarInfo(path)
            member.size = len(body)
            member.mode = 0o644
            archive.addfile(member, io.BytesIO(body))
        if name == "symlink":
            member = tarfile.TarInfo("src/link.ecl")
            member.type = tarfile.SYMTYPE
            member.linkname = "../../outside"
            archive.addfile(member)
        if name == "traversal":
            member = tarfile.TarInfo("../outside")
            member.size = 1
            archive.addfile(member, io.BytesIO(b"x"))
    (root / (name + ".tgz.hex")).write_text(gzip.compress(raw.getvalue(), mtime=0).hex() + "\n")
