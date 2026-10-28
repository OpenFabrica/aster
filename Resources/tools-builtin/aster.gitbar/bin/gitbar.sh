#!/bin/sh
# Git 状态条：读取活动 Pane 的工作目录，向 stdout 输出 Aster bar 协议的 JSON 项目列表。
# 约定见 docs/developer/tools-and-plugins.md「界面扩展」。仅依赖 POSIX sh、git、sed、grep。

EMPTY='{"items":[],"ttl":600}'

# stdin 是 Aster 传来的上下文 JSON；远端标签没有本地 cwd，隐藏整条。先读完再判断，避免写端 SIGPIPE。
input=$(cat)
case "$input" in
  *'"isRemote":true'* | *'"isRemote": true'*) echo "$EMPTY"; exit 0 ;;
esac
if [ -z "$ASTER_CWD" ] || [ ! -d "$ASTER_CWD" ]; then
  echo "$EMPTY"
  exit 0
fi

# 只读查询：不拿索引锁，避免和用户正在跑的 git 命令互相卡住。非仓库或 git 失败一律按「无内容」处理。
status=$(GIT_OPTIONAL_LOCKS=0 git -C "$ASTER_CWD" status --porcelain=v2 --branch 2>/dev/null) || {
  echo "$EMPTY"
  exit 0
}

# 转义成 JSON 字符串内容：先处理反斜杠，再处理双引号。
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

head_name=$(printf '%s\n' "$status" | sed -n 's/^# branch\.head //p')
oid=$(printf '%s\n' "$status" | sed -n 's/^# branch\.oid //p')
ab=$(printf '%s\n' "$status" | sed -n 's/^# branch\.ab //p')

# detached HEAD 没有分支名：显示 HEAD@短 SHA。
if [ "$head_name" = "(detached)" ]; then
  head_name="HEAD@$(printf '%s' "$oid" | cut -c1-7)"
fi
[ -n "$head_name" ] || { echo "$EMPTY"; exit 0; }

# branch.ab 形如「+2 -1」；没有上游时这一行不存在。
ahead=0
behind=0
if [ -n "$ab" ]; then
  ahead=${ab%% *}
  ahead=${ahead#+}
  behind=${ab##* }
  behind=${behind#-}
fi
# 已跟踪的改动（1/2/u 开头）加未跟踪文件（? 开头）；忽略项（!）默认不会出现。
dirty=$(printf '%s\n' "$status" | grep -c '^[12u?] ')

# 提示文案跟随界面语言：脚本输出不经过 Aster 的翻译表。
case "$ASTER_LOCALE" in
  zh*) branch_tip="分支" ; dirty_tip="$dirty 个文件有改动" ; refresh_tip="刷新" ;;
  *) branch_tip="Branch" ; dirty_tip="$dirty files changed" ; refresh_tip="Refresh" ;;
esac

name=$(json_escape "$head_name")
items="{\"id\":\"branch\",\"text\":\"$name\",\"icon\":\"arrow.triangle.branch\",\"tooltip\":\"$branch_tip $name\",\"onClick\":{\"type\":\"copy\",\"text\":\"$name\"}}"
if [ "$ahead" -gt 0 ] 2>/dev/null; then
  items="$items,{\"id\":\"ahead\",\"text\":\"↑$ahead\",\"onClick\":{\"type\":\"terminal\",\"text\":\"git push\",\"mode\":\"insert\"}}"
fi
if [ "$behind" -gt 0 ] 2>/dev/null; then
  items="$items,{\"id\":\"behind\",\"text\":\"↓$behind\",\"onClick\":{\"type\":\"terminal\",\"text\":\"git pull --ff-only\",\"mode\":\"insert\"}}"
fi
if [ "$dirty" -gt 0 ]; then
  items="$items,{\"id\":\"dirty\",\"text\":\"●$dirty\",\"color\":\"warning\",\"tooltip\":\"$dirty_tip\"}"
fi
items="$items,{\"id\":\"refresh\",\"icon\":\"arrow.clockwise\",\"tooltip\":\"$refresh_tip\",\"onClick\":{\"type\":\"refresh\"}}"

printf '{"items":[%s]}\n' "$items"
