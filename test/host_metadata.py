"""Host metadata is independent of environment spelling and executable argv[0]."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="ecl-host-metadata-") as temporary:
    root = Path(temporary).resolve()
    binary = root / "bin" / "ecl"
    binary.parent.mkdir()
    shutil.copy2(sys.argv[1], binary)
    caller = root / "caller λ"
    caller.mkdir()
    environment = dict(os.environ, PWD="/unrelated", PATH="/absent")

    def run(program):
        result = subprocess.run(
            ["misleading-argv-zero", program], executable=binary,
            cwd=caller, env=environment, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=15,
        )
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    assert run("host.cwd json.emit io.prin") == json.dumps(str(caller), ensure_ascii=False)
    assert run("host.executable json.emit io.prin") == json.dumps(str(binary))
    (caller / "map").write_text("{'format 1 'local \"local\" 'scopes {\"local\" {'root \".\" 'visible [] 'sources [] 'artifacts []}}}")
    assert run("{'args [\"check-map\" \"map\"] 'timeout-ms 5000} 'executable host.executable put proc.run 'term at 'code at") == "0"

print("public host process metadata: passed")
