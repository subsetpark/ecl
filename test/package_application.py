"""Own the caller process and cache for the ECL package command acceptance."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
app_map = str(Path("apps/pkg/test/acceptance/command.modules").resolve())
with tempfile.TemporaryDirectory(prefix="ecl-package-application-") as temporary:
    root = Path(temporary)
    cache = root / "cache"
    cache.mkdir()
    result = subprocess.run(
        [binary, "--module-map", app_map, "test", "--runner", "pkg.test.command.run"],
        cwd=root, env={**os.environ, "ECL_CACHE": str(cache), "TMPDIR": temporary},
        stdin=subprocess.DEVNULL, timeout=240,
    )
    raise SystemExit(result.returncode)
