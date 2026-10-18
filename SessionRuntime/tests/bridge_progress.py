"""OSC 7 与进度同批到达时，显示桥必须保留目录和客户端回滚历史。

使用独立的测试服务与 PTY 显示桥。连续进度更新不能产生 RIS 全量快照，
否则 GUI 客户端的滚动位置会被重置。
"""
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

from terminal_attach import Host
from terminal_service import Client, TIMEOUT, success


def read_until(host, marker):
    output = bytearray()
    deadline = time.monotonic() + TIMEOUT
    while marker not in output:
        remaining = deadline - time.monotonic()
        assert remaining > 0, f"missing marker: {bytes(output[-512:])!r}"
        assert select.select([host.master], [], [], remaining)[0], "bridge timeout"
        output.extend(os.read(host.master, 65536))
        assert len(output) < 4 * 1024 * 1024, "unbounded bridge output"
    return bytes(output)


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-progress-", dir="/tmp") as parent:
        Path(parent).chmod(0o700)
        server = subprocess.Popen(
            [binary, "server", "serve", parent, "session"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        control, host = None, None
        try:
            control = Client(Path(parent) / "session/control.sock", server)
            # 一次写入复现提示符目录上报与 TUI 进度落到同一批输出。
            script = (
                "stty -echo; printf 'READY\\n'; "
                "while IFS= read -r value; do "
                "printf '\\033]7;file://localhost/tmp/mailez\\007"
                "\\033]9;4;1;50\\007PROGRESS_DONE\\n'; done")
            created = success(control.call("terminal.create", {
                "cwd": parent, "argv": ["/bin/sh", "-c", script]}))
            host = Host(binary, parent, created["terminalID"])
            read_until(host, b"READY")
            for _ in range(3):
                host.write(b"progress\n")
                output = read_until(host, b"PROGRESS_DONE")
                assert b"\x1b]7;file://localhost/tmp/mailez" in output, \
                    f"cwd report lost in display bridge: {output[:160]!r}"
                assert b"\x1bc" not in output, \
                    "progress forced RIS snapshot, resetting client scrollback"
                assert b"\x1b]9;4;1;50\x07" in output, "progress report lost"
            print("bridge progress: cwd and progress preserved; no scrollback reset", flush=True)
        finally:
            if host is not None:
                host.close()
            if control is not None:
                try:
                    control.call("server.stop")
                finally:
                    control.close()
            if server.poll() is None:
                server.terminate()
            server.communicate(timeout=TIMEOUT)


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
