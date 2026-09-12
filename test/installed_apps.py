"""Exercise installation-only dispatch through a relocated executable."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def run(executable, cwd, *args, input_text="", environ=None):
    return subprocess.run(
        [str(executable), *args], cwd=cwd, input=input_text,
        capture_output=True, text=True, timeout=10, env=environ,
    )


with tempfile.TemporaryDirectory(prefix="ecl-installed-apps-") as temporary:
    root = Path(temporary)
    prefix = root / "distribution"
    binary = prefix / "bin" / "ecl"
    binary.parent.mkdir(parents=True)
    shutil.copy2(sys.argv[1], binary)
    app = prefix / "share" / "ecl" / "apps" / "fixture"
    app.mkdir(parents=True)
    descriptor = {"format": 1, "entry": "main.ecl", "module_map": "ecl.modules"}
    (app / "application.json").write_text(json.dumps(descriptor))
    (app / "ecl.modules").write_text(
        "{'format 1 'local \"app\" 'scopes {\"app\" "
        "{'root \".\" 'visible [] 'sources [\"*.ecl\"] 'artifacts []}}}"
    )
    (app / "library.ecl").write_text("[] ((42) 'answer def) 'appfixture @defm")
    (app / "main.ecl").write_text(
        "appfixture.answer str io.prin args str io.prin "
        "'cwd \"sentinel\" fs.read-text io.prin"
    )
    caller = root / "caller"
    caller.mkdir()
    (caller / "sentinel").write_text("caller directory")
    (caller / "ecl.modules").write_text("broken project map")
    (caller / "appfixture.ecl").write_text("[] ((999) 'answer def) 'appfixture @defm")
    result = run(binary, caller, "fixture", "one", "two")
    assert result.returncode == 0, result.stderr
    assert result.stdout == '42("one" "two")caller directory', repr(result.stdout)
    # An explicit caller map also cannot replace the application's own map.
    result = run(binary, caller, "--module-map", "missing", "fixture", "three")
    assert result.returncode == 0, result.stderr
    assert '42("three")' in result.stdout, result.stdout

    # Standard input stays available as program data.
    (app / "main.ecl").write_text("io.stdin io.prin")
    result = run(binary, caller, "fixture", input_text="input bytes")
    assert result.returncode == 0, result.stderr
    assert result.stdout == 'input bytes', repr(result.stdout)

    # The installation is relocatable as one directory.
    moved = root / "moved"
    prefix.rename(moved)
    binary = moved / "bin" / "ecl"
    app = moved / "share" / "ecl" / "apps" / "fixture"
    result = run(binary, caller, "fixture", input_text="moved")
    assert result.returncode == 0, result.stderr
    assert result.stdout == 'moved', repr(result.stdout)

    (app / "main.ecl").write_text('"APP_FIXTURE_TOKEN" getenv io.prin')
    result = run(binary, caller, "fixture", environ=dict(os.environ, APP_FIXTURE_TOKEN="inherited"))
    assert result.returncode == 0, result.stderr
    assert result.stdout == "inherited", repr(result.stdout)

    # Installed names are not discovered in the caller's project or PATH.
    (caller / "ecl.modules").unlink()
    fake = caller / "share" / "ecl" / "apps" / "unregistered"
    fake.mkdir(parents=True)
    shutil.copy2(app / "application.json", fake / "application.json")
    path_bin = caller / "path-bin"
    path_bin.mkdir()
    (path_bin / "unregistered").write_text("#!/bin/sh\necho forbidden\n")
    (path_bin / "unregistered").chmod(0o755)
    environment = dict(os.environ, PATH=str(path_bin))
    result = run(binary, caller, "unregistered", environ=environment)
    assert result.returncode != 0
    assert "forbidden" not in result.stdout

    for invalid in [dict(descriptor, format=2), dict(descriptor, entry="../escape.ecl"),
                    dict(descriptor, module_map="/outside"), dict(descriptor, extra=True)]:
        (app / "application.json").write_text(json.dumps(invalid))
        result = run(binary, caller, "fixture")
        assert result.returncode != 0
        assert "invalid installed application descriptor" in result.stderr

    # Built-in commands retain precedence over installed application names.
    shutil.copytree(app, app.parent / "test")
    result = run(binary, caller, "test")
    assert "invalid installed application descriptor" not in result.stderr

print("installed application dispatch: passed")
