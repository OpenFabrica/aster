#!/bin/sh
# Codex 速率条入口：这个 Pane 没跑 Codex 时直接输出空列表，不启动 Python；
# 跑着时挑一个真的 python3 执行同目录的 codexbar.py。约定见 docs/developer/tools-and-plugins.md「界面扩展」。

# Pane 不是 Codex：隐藏这一段。先读完 stdin，避免写端 SIGPIPE。
if [ "$ASTER_AGENT" != "codex" ]; then
  cat >/dev/null
  echo '{"items":[],"ttl":600}'
  exit 0
fi

script="$(dirname "$0")/codexbar.py"
# -B：不写 __pycache__，插件在签名的 App 包里。
for python in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  [ -x "$python" ] && exec "$python" -B "$script"
done
# 没装 Command Line Tools 时 /usr/bin/python3 只是会弹安装框的占位程序，不能直接调用。
if xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/python3 ]; then
  exec /usr/bin/python3 -B "$script"
fi

cat >/dev/null
case "$ASTER_LOCALE" in
  zh*) text="需要 python3" ; tip="安装 Xcode 命令行工具（xcode-select --install）或 Homebrew 的 python 后自动显示" ;;
  *) text="python3 required" ; tip="Install the Xcode Command Line Tools (xcode-select --install) or Homebrew python" ;;
esac
printf '{"items":[{"id":"python","text":"%s","icon":"exclamationmark.triangle","color":"warning","tooltip":"%s"}],"ttl":3600}\n' "$text" "$tip"
