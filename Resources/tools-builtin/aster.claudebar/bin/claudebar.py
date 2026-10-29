#!/usr/bin/env python3
"""Claude Code 速率条：读这个 Pane 绑定的 Claude Code 会话记录，输出模型、状态、输入 / 输出速率、上下文与累计（Aster bar 协议）。

会话记录是 `$CLAUDE_CONFIG_DIR/projects/<编码目录>/<session-id>.jsonl`。累计值按偏移量增量统计，
进度存在 `$ASTER_PLUGIN_DATA/sessions/<id>.json`，每次只读新增的行。
"""
import datetime as dt
import json
import os
import re
import sys
import time
from pathlib import Path

# 超过这么久没有写入的会话不再显示。
IDLE_SECONDS = 60 * 60
# 没有数据目录（无法增量）时最多读尾部这么多字节。
TAIL_LIMIT = 8 * 1024 * 1024
# 进度文件版本；结构变了就整份重算。
CACHE_VERSION = 2
SESSION_ID = re.compile(r"^[0-9A-Za-z_-]{1,128}$")
# Claude Code 写的顶层 timestamp 紧跟在 uuid 后面，优先认这个位置，工具结果里嵌套的 timestamp 不会被误取；
# 键顺序不同的记录退回第一个 timestamp。
TIMESTAMP = re.compile(rb'"uuid":"[^"]*","timestamp":"([^"]+)"')
ANY_TIMESTAMP = re.compile(rb'"timestamp":"([^"]+)"')

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


def compact(number):
    """token 数缩写成 1.2k / 3.4M。"""
    for divisor, suffix in ((1e9, "G"), (1e6, "M"), (1e3, "k")):
        if number >= divisor:
            return f"{number / divisor:.1f}{suffix}"
    return str(round(number))


def project_directory_name(cwd):
    """Claude Code 的项目目录名：路径里非字母数字的字符都换成 `-`。"""
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def find_session(projects, session_id, cwd, now):
    """优先按 Pane 绑定的会话 ID 找；没绑定时回退到该目录最近写入的会话。"""
    if session_id and SESSION_ID.match(session_id):
        if cwd:
            direct = projects / project_directory_name(cwd) / f"{session_id}.jsonl"
            if direct.is_file():
                return direct
        return next(iter(projects.glob(f"*/{session_id}.jsonl")), None)
    if not cwd:
        return None
    best = None
    try:
        paths = [p for p in (projects / project_directory_name(cwd)).iterdir() if p.suffix == ".jsonl"]
    except OSError:
        return None
    for path in paths:
        try:
            modified = path.stat().st_mtime
        except OSError:
            continue
        if modified >= now - IDLE_SECONDS and (best is None or modified > best[0]):
            best = (modified, path)
    return best[1] if best else None


class Tally:
    """增量统计：累计输入 / 输出、最近一条回复的输入 / 输出与用时、最近一次请求的上下文大小。

    「输入」指新处理的输入（`input_tokens` + `cache_creation_input_tokens`）；缓存读取每次请求都会把整个上下文
    再读一遍，当成输入速率会大得离谱，所以单独累计、只放进提示。

    同一条回复的多个内容块各写一行、带同一个 `message.id`，用量以最后一行为准，
    所以按「连续相同 id」合并；回复的起点是它第一行之前那一行的时间（用户输入或工具结果）。
    """

    FIELDS = ("output_total", "input_total", "cache_read_total", "message_id", "message_output",
              "message_input", "message_cache_read", "message_start", "message_end",
              "context", "model", "effort", "previous_at", "updated_at")

    def __init__(self, saved=None):
        saved = saved or {}
        self.output_total = 0
        self.input_total = 0
        self.cache_read_total = 0
        self.message_id = None
        self.message_output = 0
        self.message_input = 0
        self.message_cache_read = 0
        self.message_start = None
        self.message_end = None
        self.context = 0
        self.model = "-"
        self.effort = None
        self.previous_at = None
        self.updated_at = 0
        for key in self.FIELDS:
            if key in saved:
                setattr(self, key, saved[key])

    def snapshot(self):
        """可写进进度文件的字典。"""
        return {key: getattr(self, key) for key in self.FIELDS}

    def line(self, raw):
        """吃一行原始记录。只完整解析助手回复行，其它行用正则只取时间，大会话也快。"""
        match = TIMESTAMP.search(raw) or ANY_TIMESTAMP.search(raw)
        at = timestamp(match.group(1).decode("ascii", "replace")) if match else None
        if b'"type":"assistant"' in raw:
            at = self.assistant(raw) or at
        if at is not None:
            self.previous_at = at
            self.updated_at = max(self.updated_at, at)

    def assistant(self, raw):
        """一行助手回复：合并同一条回复的多个内容块。返回这一行的时间（不是回复行返回 None）。"""
        try:
            obj = json.loads(raw)
        except ValueError:
            return None
        # 子代理的往来不算这个会话自己的回复。
        if not isinstance(obj, dict) or obj.get("isSidechain") or obj.get("type") != "assistant":
            return None
        at = timestamp(obj.get("timestamp"))
        message = obj.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if not isinstance(usage, dict):
            return at
        try:
            output = int(usage.get("output_tokens") or 0)
            new_input = (int(usage.get("input_tokens") or 0)
                         + int(usage.get("cache_creation_input_tokens") or 0))
            cache_read = int(usage.get("cache_read_input_tokens") or 0)
            context = sum(int(usage.get(key) or 0) for key in
                          ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
        except (TypeError, ValueError):
            return at
        identifier = message.get("id")
        if identifier and identifier == self.message_id:
            self.output_total += output - self.message_output
            self.input_total += new_input - self.message_input
            self.cache_read_total += cache_read - self.message_cache_read
        else:
            self.output_total += output
            self.input_total += new_input
            self.cache_read_total += cache_read
            self.message_id = identifier
            self.message_start = self.previous_at
        self.message_output = output
        self.message_input = new_input
        self.message_cache_read = cache_read
        self.message_end = at
        if context:
            self.context = context
        if isinstance(message.get("model"), str) and not message["model"].startswith("<"):
            self.model = message["model"]
        if isinstance(obj.get("effort"), str):
            self.effort = obj["effort"]
        return at

    def rate(self):
        """最近一条回复的（输入速率, 输出速率, 用时）；算不出返回 None。"""
        if self.message_start is None or self.message_end is None:
            return None
        seconds = self.message_end - self.message_start
        if seconds < 0.5 or self.message_output <= 0:
            return None
        return self.message_input / seconds, self.message_output / seconds, seconds


def read_complete_lines(path, offset):
    """从偏移量读到最后一个完整行；返回行列表与新偏移量（不越过末尾的半行）。"""
    with path.open("rb") as stream:
        stream.seek(offset)
        data = stream.read()
    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    return data[:end].split(b"\n"), offset + end + 1


def load_tally(path, session_id):
    """读进度、补上新增的行、写回进度。没有数据目录时只统计尾部。"""
    size = path.stat().st_size
    data_dir = os.environ.get("ASTER_PLUGIN_DATA")
    cache = Path(data_dir) / "sessions" / f"{session_id}.json" if data_dir else None
    saved = None
    if cache:
        try:
            saved = json.loads(cache.read_text())
        except (OSError, ValueError):
            saved = None
    # 文件变小（被改写）或进度版本不对就从头算。
    if not isinstance(saved, dict) or saved.get("version") != CACHE_VERSION or saved.get("offset", 0) > size:
        saved = None
    tally = Tally(saved.get("tally") if saved else None)
    offset = saved["offset"] if saved else (0 if cache else max(0, size - TAIL_LIMIT))
    lines, new_offset = read_complete_lines(path, offset)
    if offset and not saved:
        lines = lines[1:]  # 尾部模式：第一行可能被截断
    for raw in lines:
        if raw:
            tally.line(raw)
    if cache and new_offset != offset:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True)
            temporary = cache.with_suffix(".tmp")
            temporary.write_text(json.dumps({"version": CACHE_VERSION, "offset": new_offset,
                                             "tally": tally.snapshot()}))
            os.replace(temporary, cache)
        except OSError:
            pass  # 写不了进度只是下次多读一些，不影响这次的显示
    return tally


def main():
    """找这个 Pane 的 Claude Code 会话，输出一行摘要。"""
    try:
        context = json.load(sys.stdin).get("context") or {}
    except ValueError:
        context = {}
    agent = context.get("agent") or {}
    if agent.get("provider") != "claudeCode" or context.get("isRemote"):
        emit([], 600)

    projects = Path(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude").expanduser() / "projects"
    now = time.time()
    cwd = os.environ.get("ASTER_CWD") or context.get("workingDirectory")
    path = find_session(projects, agent.get("sessionID"), cwd, now)
    if path is None:
        emit([], 30)
    session_id = path.stem
    try:
        tally = load_tally(path, session_id)
    except OSError:
        emit([], 30)
    if now - tally.updated_at > IDLE_SECONDS or tally.message_id is None:
        emit([], 60)

    state = agent.get("state")
    if state == "awaitingInput":
        status, color = t("等待确认", "Needs input"), "error"
    elif state == "processing":
        status, color = t("进行中", "Working"), "warning"
    else:
        status, color = t("待输入", "Idle"), "secondary"

    model = tally.model[len("claude-"):] if tally.model.startswith("claude-") else tally.model
    items = [{
        "id": "model",
        "text": f"{model} · {tally.effort}" if tally.effort else model,
        "icon": "cpu",
        "tooltip": t(f"Claude Code 会话 {session_id}（点击复制 ID）",
                     f"Claude Code session {session_id} (click to copy the ID)"),
        "onClick": {"type": "copy", "text": session_id},
    }, {"id": "status", "text": status, "color": color}]
    rate = tally.rate()
    if rate:
        input_rate, output_rate, seconds = rate
        items.append({
            "id": "rate",
            "text": t(f"入 {compact(input_rate)}/s · 出 {compact(output_rate)}/s",
                      f"in {compact(input_rate)}/s · out {compact(output_rate)}/s"),
            "icon": "speedometer",
            "color": "accent",
            "tooltip": t(
                f"最近一条回复：新输入 {tally.message_input} token（另读缓存 {compact(tally.message_cache_read)}），"
                f"输出 {tally.message_output} token，用时 {seconds:.1f}s（含思考与工具调用的生成）",
                f"Latest reply: {tally.message_input} new input tokens (plus {compact(tally.message_cache_read)} "
                f"read from cache), {tally.message_output} output tokens in {seconds:.1f}s"),
        })
    if tally.context:
        items.append({
            "id": "context",
            "text": t(f"上下文 {compact(tally.context)}", f"context {compact(tally.context)}"),
            "color": "secondary",
            "tooltip": t("最近一次请求的输入 token（含缓存读写）", "Input tokens of the latest request (including cache)"),
        })
    items.append({
        "id": "total",
        "text": t(f"累计 {compact(tally.input_total)} / {compact(tally.output_total)}",
                  f"total {compact(tally.input_total)} / {compact(tally.output_total)}"),
        "color": "secondary",
        "tooltip": t(
            f"这个会话累计新输入 / 输出 token（不含子代理）；另读缓存 {compact(tally.cache_read_total)}",
            f"Total new input / output tokens of this session (excluding subagents); "
            f"plus {compact(tally.cache_read_total)} read from cache"),
    })
    items.append({"id": "refresh", "icon": "arrow.clockwise", "tooltip": t("立即刷新", "Refresh now"),
                  "onClick": {"type": "refresh"}})
    # 进行中按最短间隔刷新，空闲时放慢。
    emit(items, 5 if state == "processing" else 30)


if __name__ == "__main__":
    main()
