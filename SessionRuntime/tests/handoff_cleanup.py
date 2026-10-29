"""交接后的旧服务只释放自身资源，不清理已交出的进程或等待清理超时。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from terminal_service import Client, success


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-handoff-cleanup-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        with (root / "service.stderr").open("wb+") as diagnostics:
            old = subprocess.Popen(
                [binary, "server", "serve", parent, "session"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            try:
                client = Client(root / "session/control.sock", old)
                created = success(client.call("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sh", "-c", "while read value; do echo GOT-$value; done"],
                }))
                client.close()
                for generation in range(2):
                    started = time.monotonic()
                    result = subprocess.run(
                        [binary, "server", "upgrade", parent, "session", "--force"],
                        capture_output=True, text=True, timeout=15, check=True)
                    elapsed = (time.monotonic() - started) * 1000
                    assert json.loads(result.stdout)["upgraded"] is True
                    if generation == 0:
                        old.wait(timeout=5)
                        assert old.returncode == 0
                    listed = subprocess.run(
                        [binary, "terminal", "list", parent, "session"],
                        capture_output=True, text=True, check=True, timeout=5)
                    terminal = json.loads(listed.stdout)["result"]["terminals"][0]
                    assert terminal["pid"] == created["pid"] and terminal["state"] == "running"
                    os.kill(created["pid"], 0)
                    diagnostics.seek(0)
                    errors = diagnostics.read()
                    print(f"handoff {generation + 1}: {elapsed:.0f} ms, original PID preserved", flush=True)
                    assert b"pool cleanup incomplete" not in errors, errors.decode(errors="replace")
                    assert b"ProcessCleanupTimedOut" not in errors, errors.decode(errors="replace")
            finally:
                subprocess.run([binary, "server", "stop", parent, "session"],
                               capture_output=True, timeout=10)
                old.wait(timeout=5)
    print("PASS: handoff releases old ownership without process cleanup timeout")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
