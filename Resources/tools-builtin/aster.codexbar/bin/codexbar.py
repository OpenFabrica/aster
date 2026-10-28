#!/usr/bin/env python3
"""Codex 速率条：读这个 Pane 绑定的 Codex 会话记录，输出模型、状态、token 速率与累计（Aster bar 协议）。

会话记录是 `$CODEX_HOME/sessions/年/月/日/rollout-<时间>-<id>.jsonl`。只读文件尾部，大会话也便宜。
"""
import datetime as dt
import json
import os
import sys
import time
from pathlib import Path

# 超过这么久没有内容活动的会话不再显示。
IDLE_SECONDS = 60 * 60
# 按会话 ID 找文件时先看最近几天的日期目录，找不到再全量搜索。
LOOKBACK_DAYS = 7
# 尾部读取从 64 KiB 起倍增，最多读到 8 MiB。
TAIL_START = 65536
TAIL_LIMIT = 8 * 1024 * 1024

ZH = (os.environ.get("ASTER_LOCALE") or "").startswith("zh")


def t(zh, en):
    """按界面语言选文案：脚本输出不经过 Aster 的翻译表。"""
    return zh if ZH else en


def emit(items, ttl):
    """输出 bar 协议 JSON 并退出。"""
    print(json.dumps({"items": items, "ttl": ttl}, ensure_ascii=False))
    sys.exit(0)


def timestamp(value):
    """ISO 时间串转秒；解析不了返回 None。"""
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def decode(line):
    """解析一行 JSONL；坏行当空对象。"""
    try:
        obj = json.loads(line)
        return obj if isinstance(obj, dict) else {}
    except (ValueError, UnicodeDecodeError):
        return {}


def compact(number):
    """token 数缩写成 1.2k / 3.4M。"""
    for divisor, suffix in ((1e9, "G"), (1e6, "M"), (1e3, "k")):
        if number >= divisor:
            return f"{number / divisor:.1f}{suffix}"
    return str(round(number))


class Monitor:
    """按事件顺序折叠会话状态：模型、思考等级、累计用量和最近一个用量区间。"""

    def __init__(self):
        self.total = None
        self.previous_time = None
        self.last = None
        self.active = False
        self.activity_at = 0
        self.model = "-"
        self.effort = "-"

    def settings(self, values):
        """取会话自己记录的设置；全局配置可能描述的是别的会话。"""
        if isinstance(values.get("model"), str):
            self.model = values["model"]
        for key in ("effort", "reasoning_effort", "model_reasoning_effort"):
            if key in values:
                self.effort = values[key] if isinstance(values[key], str) else t("默认", "default")
                break

    def event(self, obj):
        """吃一条记录。"""
        payload = obj.get("payload")
        if not isinstance(payload, dict):
            return
        kind = payload.get("type")
        at = timestamp(obj.get("timestamp"))
        if obj.get("type") == "turn_context":
            self.settings(payload)
        elif obj.get("type") == "event_msg" and kind == "thread_settings_applied":
            if isinstance(payload.get("thread_settings"), dict):
                self.settings(payload["thread_settings"])
        # 内容与工具往来才算活动；配置和重复的用量通知不能让废弃的会话一直显示。
        content = (obj.get("type") == "response_item" and kind in (
            "message", "reasoning", "function_call", "function_call_output",
            "custom_tool_call", "custom_tool_call_output", "tool_search_call", "tool_search_output",
        )) or (obj.get("type") == "event_msg" and kind in ("user_message", "agent_message", "agent_reasoning"))
        if content:
            self.active = True
            if at is not None:
                self.activity_at = max(self.activity_at, at)
        if obj.get("type") != "event_msg":
            return
        if kind == "task_started":
            self.active = True
            if at is not None:
                self.activity_at = max(self.activity_at, at)
            self.previous_time = at
            self.last = None
        elif kind in ("task_complete", "turn_aborted"):
            self.active = False
        elif kind == "token_count":
            self.usage(payload.get("info"), at)

    def usage(self, info, at):
        """累计用量事件：和上一次的差值除以间隔就是这个区间的平均速率。"""
        total = info.get("total_token_usage") if isinstance(info, dict) else None
        if not isinstance(total, dict):
            return
        try:
            values = (int(total["input_tokens"]), int(total["output_tokens"]))
        except (KeyError, ValueError, TypeError):
            return
        # 重复的记账事件不能改变测量区间。
        if values == self.total:
            return
        if at is not None:
            self.activity_at = max(self.activity_at, at)
        if self.total is not None and at is not None and self.previous_time is not None:
            seconds = at - self.previous_time
            delta = tuple(a - b for a, b in zip(values, self.total))
            if seconds > 0 and min(delta) >= 0:
                self.last = (delta, seconds)
            elif min(delta) < 0:
                self.last = None
        self.total = values
        if at is not None:
            self.previous_time = at


def first_line(path):
    """会话首行（session_meta）的 payload；读不了返回空字典。"""
    try:
        with path.open("rb") as stream:
            payload = decode(stream.readline()).get("payload")
    except OSError:
        return {}
    return payload if isinstance(payload, dict) else {}


def day_directories(root):
    """最近几天的日期目录，新的在前。"""
    today = dt.date.today()
    for offset in range(LOOKBACK_DAYS):
        day = today - dt.timedelta(days=offset)
        yield root / f"{day.year:04d}" / f"{day.month:02d}" / f"{day.day:02d}"


def find_by_id(root, session_id):
    """按会话 ID 找记录文件：文件名以 ID 结尾。"""
    suffix = f"-{session_id}.jsonl"
    for directory in day_directories(root):
        try:
            for path in directory.iterdir():
                if path.name.endswith(suffix):
                    return path
        except OSError:
            continue
    return next(iter(sorted(root.glob(f"**/*{suffix}"))), None)


def find_by_cwd(root, cwd, now):
    """没绑定会话 ID 时的回退：这个目录里最近修改的顶层会话。"""
    best = None
    for directory in day_directories(root):
        try:
            paths = [p for p in directory.iterdir() if p.suffix == ".jsonl"]
        except OSError:
            continue
        for path in paths:
            try:
                modified = path.stat().st_mtime
            except OSError:
                continue
            if modified < now - IDLE_SECONDS or (best and modified <= best[0]):
                continue
            meta = first_line(path)
            source = meta.get("source")
            if meta.get("parent_thread_id") or (isinstance(source, dict) and "subagent" in source):
                continue
            recorded = meta.get("cwd")
            if isinstance(recorded, str) and os.path.realpath(recorded) == cwd:
                best = (modified, path)
    return best[1] if best else None


def read_tail(path):
    """从尾部往前读，直到拿到设置、两次用量与任务状态，或者读到文件头 / 上限。"""
    with path.open("rb") as stream:
        stream.seek(0, 2)
        end = stream.tell()
        size = min(end, TAIL_START)
        while True:
            start = end - size
            stream.seek(start)
            if start:
                stream.readline()  # 丢掉被截断的半行
            lines = [decode(line) for line in stream.read(end - stream.tell()).splitlines() if line.strip()]
            kinds = [obj.get("payload", {}).get("type") for obj in lines
                     if obj.get("type") == "event_msg" and isinstance(obj.get("payload"), dict)]
            has_settings = "thread_settings_applied" in kinds or any(obj.get("type") == "turn_context" for obj in lines)
            enough = has_settings and kinds.count("token_count") >= 2 and (
                {"task_started", "task_complete", "turn_aborted"} & set(kinds))
            if start == 0 or enough or size >= TAIL_LIMIT:
                return lines
            size = min(end, size * 2)


def main():
    """找这个 Pane 的 Codex 会话，输出一行摘要。"""
    try:
        context = json.load(sys.stdin).get("context") or {}
    except ValueError:
        context = {}
    agent = context.get("agent") or {}
    if agent.get("provider") != "codex" or context.get("isRemote"):
        emit([], 600)

    root = Path(os.environ.get("CODEX_HOME") or "~/.codex").expanduser() / "sessions"
    now = time.time()
    session_id = agent.get("sessionID")
    path = find_by_id(root, session_id) if session_id else None
    cwd = os.environ.get("ASTER_CWD") or context.get("workingDirectory")
    if path is None and cwd:
        path = find_by_cwd(root, os.path.realpath(cwd), now)
    if path is None:
        emit([], 30)

    monitor = Monitor()
    try:
        for obj in read_tail(path):
            monitor.event(obj)
    except OSError:
        emit([], 30)
    if now - monitor.activity_at > IDLE_SECONDS:
        emit([], 60)

    session_id = session_id or first_line(path).get("id") or path.stem
    state = agent.get("state")
    running = state == "processing" if state else monitor.active
    if state == "awaitingInput":
        status, color = t("等待确认", "Needs input"), "error"
    elif running:
        status, color = t("进行中", "Working"), "warning"
    else:
        status, color = t("待输入", "Idle"), "secondary"

    items = [{
        "id": "model",
        "text": f"{monitor.model} · {monitor.effort}",
        "icon": "cpu",
        "tooltip": t(f"Codex 会话 {session_id}（点击复制 ID）", f"Codex session {session_id} (click to copy the ID)"),
        "onClick": {"type": "copy", "text": session_id},
    }, {"id": "status", "text": status, "color": color}]
    if monitor.last:
        (inp, out), seconds = monitor.last
        items.append({
            "id": "rate",
            "text": t(f"入 {compact(inp / seconds)}/s · 出 {compact(out / seconds)}/s",
                      f"in {compact(inp / seconds)}/s · out {compact(out / seconds)}/s"),
            "icon": "speedometer",
            "color": "accent",
            "tooltip": t(f"最近一个用量区间 {seconds:.1f}s 的平均速率，不是逐秒实时速率",
                         f"Average over the latest {seconds:.1f}s usage interval, not a per-second live rate"),
        })
    if monitor.total:
        items.append({
            "id": "total",
            "text": t(f"累计 {compact(monitor.total[0])} / {compact(monitor.total[1])}",
                      f"total {compact(monitor.total[0])} / {compact(monitor.total[1])}"),
            "color": "secondary",
            "tooltip": t("累计输入 / 输出 token（输入含缓存）", "Total input / output tokens (input includes cache)"),
        })
    items.append({"id": "refresh", "icon": "arrow.clockwise", "tooltip": t("立即刷新", "Refresh now"),
                  "onClick": {"type": "refresh"}})
    # 进行中按最短间隔刷新，空闲时放慢。
    emit(items, 5 if running else 30)


if __name__ == "__main__":
    main()
