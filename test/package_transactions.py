"""Public application recovery across separate root lock and map writes."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
app_map = str(Path("apps/pkg/ecl.modules").resolve())
old_lock = "{'format 2 'root \"project\" 'packages {} 'requires {\"project\" {}}}\n"
new_lock = "{'format 2 'root \"project\" 'packages {} 'requires {}}\n"
manifest = "{'format 2 'name \"project\" 'version \"0.1.0\" 'requires {}}\n"
generation = "a" * 64
reference = "{'format 1 'map \".ecl/generations/" + generation + "/ecl.modules\"}\n"
previous_generation = "b" * 64
old_map = "{'format 1 'map \".ecl/generations/" + previous_generation + "/ecl.modules\"}\n"
complete_map = "{'format 1 'local \"local\" 'scopes {\"local\" {'root \".\" 'visible [] 'sources [\"*.ecl\"] 'artifacts []}}}\n"


def invoke(root, body, success=True):
    program = (
        json.dumps(str(root)) + " fs.open-dir 'project set "
        'project ".ecl/mutation.lock" fs.lock '
        + body + " port.close"
    )
    result = subprocess.run(
        [binary, "--module-map", app_map, program], cwd=root,
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
    )
    assert (result.returncode == 0) == success, result.stderr
    return result


def prepare(root):
    invoke(root, "project " + json.dumps(generation) + " " + json.dumps(new_lock)
           + " (pop pop) pkg.transaction.prepare")


def recover(root, success=True):
    return invoke(root, "project (pop pop) pkg.transaction.recover", success)


def runnable(root, expected):
    result = subprocess.run(
        [binary, "fixture.value str io.prin"], cwd=root,
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == str(expected), result.stdout


def initialize(root):
    for identifier, lock, answer in ((previous_generation, old_lock, 7), (generation, new_lock, 9)):
        directory = root / ".ecl/generations" / identifier
        directory.mkdir(parents=True)
        (directory / "ecl.lock").write_text(lock)
        (directory / "ecl.modules").write_text(complete_map)
        (directory / "fixture.ecl").write_text(f"[] (({answer}) 'value def) 'fixture @defm")
    (root / "ecl.pkg").write_text(manifest)
    (root / "ecl.lock").write_text(old_lock)
    (root / "ecl.modules").write_text(old_map)


with tempfile.TemporaryDirectory(prefix="ecl-package-transactions-") as temporary:
    for boundary in ("prepared", "lock", "map", "retired"):
        root = Path(temporary) / boundary
        candidate = root / ".ecl/generations" / generation
        initialize(root)
        prepare(root)
        assert (root / "ecl.lock").read_text() == old_lock
        assert (root / "ecl.modules").read_text() == old_map
        if boundary in ("lock", "map", "retired"):
            (root / "ecl.lock").write_text(new_lock)
        if boundary in ("map", "retired"):
            (root / "ecl.modules").write_text(reference)
        if boundary == "retired":
            (root / ".ecl/publication.ecl").unlink()
        runnable(root, 9 if boundary in ("map", "retired") else 7)
        recover(root)
        recover(root)
        assert (root / "ecl.lock").read_text() == new_lock
        assert (root / "ecl.modules").read_text() == reference
        assert not (root / ".ecl/publication.ecl").exists()
        assert (candidate / "ecl.lock").read_text() == new_lock
        assert (root / ".ecl/generations" / previous_generation / "ecl.lock").read_text() == old_lock
        runnable(root, 9)

    for conflict in ("ecl.pkg", "ecl.lock", "ecl.modules", "snapshot", "record"):
        root = Path(temporary) / conflict
        candidate = root / ".ecl/generations" / generation
        initialize(root)
        prepare(root)
        changed = candidate / "ecl.lock" if conflict == "snapshot" else (
            root / ".ecl/publication.ecl" if conflict == "record" else root / conflict
        )
        changed.write_text("unrelated edit")
        before = [(root / name).read_bytes() for name in ("ecl.pkg", "ecl.lock", "ecl.modules")]
        recover(root, success=False)
        assert changed.read_text() == "unrelated edit"
        assert before == [(root / name).read_bytes() for name in ("ecl.pkg", "ecl.lock", "ecl.modules")]
        assert (root / ".ecl/publication.ecl").exists()

    root = Path(temporary) / "initial"
    initialize(root)
    (root / "ecl.lock").unlink()
    (root / "ecl.modules").unlink()
    prepare(root)
    recover(root)
    runnable(root, 9)

    root = Path(temporary) / "validation"
    initialize(root)
    prepare(root)
    invoke(root, "project (pop pop 'domain error.new raise) pkg.transaction.recover", success=False)
    assert (root / "ecl.lock").read_text() == old_lock
    assert (root / "ecl.modules").read_text() == old_map
    recover(root)

print("package publication recovery: passed")
