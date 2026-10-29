"""Live handoff end to end: `server upgrade` replaces a running service without
ending its terminals.

Usage: live_handoff.py <new-binary> [<old-binary>]

The old service runs <old-binary> (default: <new-binary>) and is told through
ASTER_SESSION_BINARY to exec <new-binary> on handoff. With an older release as
<old-binary> this covers the v1 envelope path (screen restored from seed files);
with the same binary it covers the v2 path (screen carried in the envelope).

Every process and file belongs to this test; nothing touches the user's service.
"""
import json
import os
import pty
import select
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from terminal_service import Client, success  # noqa: E402

NEW = os.path.abspath(sys.argv[1])
OLD = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else NEW


class Alive:
    """Client() polls its process argument; the daemonized service has none."""

    def poll(self):
        return None


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")


def status(parent):
    out = subprocess.run([NEW, "server", "status", parent, "session"], capture_output=True, text=True, timeout=10)
    return json.loads(out.stdout)


def services(parent):
    # 新服务由旧服务按真实路径（/private/tmp/...）启动，只按唯一的目录名匹配。
    out = subprocess.run(["pgrep", "-f", f"server (start|serve) .*{os.path.basename(parent)} session"], capture_output=True, text=True)
    return [int(pid) for pid in out.stdout.split()]


def pty_session(argv, keys=b"", seconds=1.5):
    """Runs a bridge command in a PTY, optionally types keys, returns all output."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(argv[0], argv)
    output = b""
    deadline = time.monotonic() + seconds
    sent = False
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                output += os.read(fd, 65536)
            except OSError:
                break
        if keys and not sent and time.monotonic() > deadline - seconds + 0.8:
            os.write(fd, keys)
            sent = True
    os.write(fd, b"\x02q")  # Ctrl+B q: detach, never ends the terminal
    time.sleep(0.3)
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    os.close(fd)
    return output


def main():
    parent = tempfile.mkdtemp(prefix="aster-handoff-", dir="/tmp")
    os.chmod(parent, 0o700)
    counter = os.path.join(parent, "counter.txt")
    env = dict(os.environ, ASTER_SESSION_BINARY=NEW)
    subprocess.run([OLD, "server", "start", parent, "session"], check=True, capture_output=True, env=env, timeout=10)
    try:
        client = Client(os.path.join(parent, "session/control.sock"), Alive())
        old_epoch = client.target["serverEpoch"]
        echo = success(client.call("terminal.create", {"cwd": parent, "argv": [
            "/bin/sh", "-c", "for i in $(seq 1 120); do echo HIST-$i; done; while read l; do echo GOT-$l; done"]}))
        ticker = success(client.call("terminal.create", {"cwd": parent, "argv": [
            "/bin/sh", "-c", f"i=0; while :; do i=$((i+1)); echo $i >> {counter}; echo TICK-$i; sleep 0.1; done"]}))
        before = {t["terminalID"]: t for t in success(client.call("terminal.list"))["terminals"]}
        if OLD == NEW:
            # 新服务会接管全部 PTY：交接目标只能是当前用户或 root 的绝对路径可执行文件。
            for bad in ["relative/aster-session", counter, "/nonexistent/aster-session"]:
                rejected = client.call("server.handoff", {"binary": bad})
                check(rejected.get("error", {}).get("code") == "invalid_request", f"handoff binary {bad!r} rejected")
        client.close()
        time.sleep(1.0)

        out = subprocess.run([NEW, "server", "upgrade", parent, "session"] + (["--force"] if OLD == NEW else []),
                             capture_output=True, text=True, timeout=40)
        print("upgrade:", out.stdout.strip())
        result = json.loads(out.stdout)
        check(result.get("upgraded") is True, "server upgrade reports upgraded")
        check(result["previousEpoch"] == old_epoch and result["serverEpoch"] != old_epoch, "service epoch changed")
        check(result["terminals"] == 2, "both running terminals handed over")

        after_status = status(parent)
        check(after_status["target"]["serverEpoch"] == result["serverEpoch"], "status agrees with new epoch")
        check(len(services(parent)) == 1, "exactly one service process remains")

        client = Client(os.path.join(parent, "session/control.sock"), Alive())
        after = {t["terminalID"]: t for t in success(client.call("terminal.list"))["terminals"]}
        for terminal_id, entry in before.items():
            moved = after.get(terminal_id)
            check(moved is not None and moved["state"] == "running", f"terminal {terminal_id[:8]} still running")
            check(moved["pid"] == entry["pid"], f"terminal {terminal_id[:8]} keeps pid {entry['pid']}")
            check(moved["geometry"]["rows"] == entry["geometry"]["rows"] and
                  moved["geometry"]["columns"] == entry["geometry"]["columns"], "geometry preserved")
            os.kill(entry["pid"], 0)

        first = len(open(counter).read().split())
        time.sleep(1.0)
        check(len(open(counter).read().split()) > first + 5, "ticker output continues after handoff")

        screen = pty_session([NEW, "terminal", "observe", parent, "session", echo["terminalID"]])
        check(b"HIST-120" in screen, "screen content from before the handoff is restored")
        check(b"HIST-1\r" in screen or b"HIST-1\n" in screen, "scrollback from before the handoff is restored")

        typed = pty_session([NEW, "terminal", "attach", parent, "session", echo["terminalID"]], keys=b"after\r", seconds=2.5)
        check(b"GOT-after" in typed, "input reaches the adopted terminal")

        # 被接管过的终端（不再是服务的子进程）还能再交接一次。
        client.close()
        again = subprocess.run([NEW, "server", "upgrade", parent, "session", "--force"], capture_output=True, text=True, timeout=40)
        second = json.loads(again.stdout)
        check(second.get("upgraded") is True and second["previousEpoch"] == result["serverEpoch"], "adopted terminals hand over again")
        client = Client(os.path.join(parent, "session/control.sock"), Alive())
        listed = {t["terminalID"]: t for t in success(client.call("terminal.list"))["terminals"]}
        check(all(listed[i]["pid"] == before[i]["pid"] and listed[i]["state"] == "running" for i in before), "pids survive the second handoff")
        screen = pty_session([NEW, "terminal", "observe", parent, "session", echo["terminalID"]])
        check(b"GOT-after" in screen and b"HIST-120" in screen, "screen survives the second handoff")

        success(client.call("terminal.terminate", {"terminalID": ticker["terminalID"]}))
        deadline = time.monotonic() + 5
        state = None
        while time.monotonic() < deadline:
            listed = {t["terminalID"]: t for t in success(client.call("terminal.list"))["terminals"]}
            state = listed.get(ticker["terminalID"], {}).get("state")
            if state != "running":
                break
            time.sleep(0.1)
        check(state != "running", "terminating an adopted terminal ends it")
        client.close()
        check(not os.path.isdir(os.path.join(parent, "session/handoff-seed")), "seed files removed after takeover")
    finally:
        subprocess.run([NEW, "server", "stop", parent, "session"], capture_output=True, timeout=10)
        for pid in services(parent):
            os.kill(pid, 9)
    print("PASS: live handoff end to end")


if __name__ == "__main__":
    main()
