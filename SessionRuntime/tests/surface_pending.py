"""快照传输期间的连续绘制必须保留为增量，避免 TUI 反复全屏重置。"""
import base64
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from terminal_service import Client, eventually, success
from surface_service import transaction


def exercise(binary, mode):
    with tempfile.TemporaryDirectory(prefix="aster-pending-", dir="/tmp") as parent:
        root = Path(parent)
        with (root / "stderr").open("wb+") as diagnostics:
            server = subprocess.Popen(
                [binary, "server", "serve", parent, "session"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            clients = []
            try:
                control = Client(root / "session/control.sock", server)
                clients.append(control)
                program = '''import os, sys, tty
from pathlib import Path
tty.setraw(0)
for i in range(2000): os.write(1, (str(i).zfill(8) + "x" * 190 + "\\r\\n").encode())
Path("ready").touch()
while True:
    value = os.read(0, 1)
    os.write(1, b"\\r\\nUPDATE_" + value)
    if sys.argv[1] == "overflow": os.write(1, b"x" * 24000)
    if sys.argv[1] == "unsafe" and value == b"b": os.write(1, b"\\x1b]52;c;dGVzdA==\\x07")
    Path(value.decode()).touch()
'''
                created = success(control.call("terminal.create", {
                    "cwd": parent, "argv": [sys.executable, "-u", "-c", program, mode]}))
                eventually(lambda: (root / "ready").exists(), "initial history")
                attachment = success(control.call("terminal.attach", {
                    "terminalID": created["terminalID"]}))
                surface = Client(root / "session/control.sock", server, control.client_id)
                clients.append(surface)
                success(surface.call("surface.subscribe", {
                    "attachmentID": attachment["attachmentID"],
                    "geometry": {"rows": 24, "columns": 80}}))
                # 不读画面，让首份大快照仍在发送；源 PTY 同时产生多轮小增量。
                for letter in "abc":
                    success(control.call("terminal.control", {
                        "terminalID": created["terminalID"], "action": "input",
                        "data": base64.b64encode(letter.encode()).decode()}, attachment["lease"]))
                    eventually(lambda: (root / letter).exists(), "source drawing")
                    time.sleep(0.05)
                sequence, initial, delta = transaction(surface)
                assert not delta and len(initial) > 100_000, len(initial)
                sequence, update, delta = transaction(surface, sequence)
                assert delta == (mode == "safe"), (mode, "unexpected snapshot/delta fallback")
                assert b"UPDATE_a" in update and b"UPDATE_b" in update and b"UPDATE_c" in update
                assert b"\x1b]52;" not in update, "unsafe side effect escaped the snapshot boundary"
                print(f"PASS: in-flight drawing ({mode}) uses {'delta' if delta else 'snapshot'}")
            finally:
                for client in clients:
                    client.close()
                if server.poll() is None:
                    server.terminate()
                    server.wait(timeout=5)


if __name__ == "__main__":
    for mode in ("safe", "unsafe", "overflow"):
        exercise(str(Path(sys.argv[1]).resolve()), mode)
