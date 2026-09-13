"""Validate maps through the public CLI, without constructing a project Session."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


with tempfile.TemporaryDirectory(prefix="ecl-module-maps-") as temporary:
    root = Path(temporary)
    binary = root / "bin" / "ecl"
    binary.parent.mkdir()
    shutil.copy2(sys.argv[1], binary)

    def run(*arguments, input_text=""):
        return subprocess.run(
            [str(binary), *arguments], cwd=root, input=input_text,
            capture_output=True, text=True, timeout=10,
        )

    # Neither a corrupt caller map nor a broken lock enters validation.
    (root / "ecl.modules").write_text("broken")
    (root / "ecl.pkg").write_text("broken")
    (root / "ecl.lock").write_text("broken")
    maps = root / "maps"
    maps.mkdir()
    (maps / "src").mkdir()
    complete = (
        "{'format 1 'local \"local\" 'scopes {\"local\" "
        "{'root \".\" 'visible [] 'sources [\"src/*.ecl\"] 'artifacts []}}}"
    )
    (maps / "complete").write_text(complete)
    # A source with observable side effects is inspected, never executed.
    (maps / "src" / "entry.ecl").write_text(
        "'cwd \"executed\" \"bad\" fs.create-text [] () 'localmod @defm"
    )
    (maps / "reference").write_text("{'format 1 'map \"complete\"}")
    for path in ["maps/complete", "maps/reference"]:
        result = run("check-map", path)
        assert result.returncode == 0, result.stderr
        assert result.stdout == "", repr(result.stdout)
    assert not (root / "executed").exists()

    # A not-yet-published document uses its eventual path as the relative base.
    candidate = complete.replace("'root \".\"", "'root \"..\"")
    result = run("check-map", "--document", "maps/future/ecl.modules", "-", input_text=candidate)
    assert result.returncode == 0, result.stderr
    assert not (maps / "future").exists()
    assert not (root / "executed").exists()
    result = run("check-map", "--document", "maps/future/ecl.modules", "-", input_text="broken")
    assert result.returncode == 1 and "invalid module map" in result.stderr
    reference = "{'format 1 'map \"complete\"}"
    result = run("check-map", "--document", "maps/unpublished", "-", input_text=reference)
    assert result.returncode == 0, result.stderr
    result = run("check-map", "--document", "maps/unpublished", "-", input_text=reference.replace("complete", "reference"))
    assert result.returncode == 1 and "invalid module map" in result.stderr
    result = run("check-map", "--document", "maps/unpublished", "-", input_text=" " * (16 * 1024 * 1024 + 1))
    assert result.returncode == 1 and "bounded module map input" in result.stderr

    # Validation discovers new sources with the same rules as startup.
    duplicate = maps / "src" / "duplicate.ecl"
    duplicate.write_text("[] () 'localmod @defm")
    result = run("check-map", "maps/complete")
    assert result.returncode == 1 and "invalid module map" in result.stderr
    duplicate.unlink()

    (maps / "chain").write_text("{'format 1 'map \"reference\"}")
    for path in ["maps/chain", "ecl.modules", "missing"]:
        result = run("check-map", path)
        assert result.returncode == 1 and "invalid module map" in result.stderr
    for arguments in [(), ("maps/complete", "extra"), ("-",), ("--document", "maps/new")]:
        result = run("check-map", *arguments)
        assert result.returncode == 1 and "usage:" in result.stderr

    # Builtin precedence and explicit-map independence also apply here.
    app = root / "share" / "ecl" / "apps" / "check-map"
    app.mkdir(parents=True)
    (app / "application.json").write_text(json.dumps({"format": 999}))
    result = run("--module-map", "missing", "check-map", "maps/complete")
    assert result.returncode == 0, result.stderr

    # Relative source roots survive relocation of the containing document.
    maps.rename(root / "moved")
    result = run("check-map", "moved/reference")
    assert result.returncode == 0, result.stderr

print("public module map validation: passed")
