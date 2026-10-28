#!/usr/bin/env python3
# 示例 bar 脚本：输出当前时间和活动 Pane 所在文件夹名。
# stdin 是 Aster 传来的上下文 JSON；stdout 必须是 {"items": [...]}，Aster 原生绘制这些项目。
# 没有本地目录（例如远端标签）时输出空项目列表，整条状态条隐藏。
import json
import os
import sys
import time


def main():
    # 上下文里 isRemote 为 true 时没有本地 cwd，直接隐藏。
    try:
        context = json.load(sys.stdin).get("context", {})
    except ValueError:
        context = {}
    cwd = os.environ.get("ASTER_CWD")
    if not cwd or context.get("isRemote"):
        print(json.dumps({"items": []}))
        return

    folder = os.path.basename(cwd.rstrip("/")) or "/"
    now = time.strftime("%H:%M")
    items = [
        {"id": "folder", "text": folder, "icon": "folder", "tooltip": cwd,
         "onClick": {"type": "copy", "text": cwd}},
        {"id": "time", "text": now, "icon": "clock", "color": "secondary"},
    ]
    print(json.dumps({"items": items}, ensure_ascii=False))


main()
