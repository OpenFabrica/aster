#!/bin/sh
# 示例 text 脚本：把输入原样转成大写。
# 输入先读 stdin（清单写了 "stdin": "text"，Aster 写入输入文本原文，写完关闭）；
# stdin 为空时退回 ASTER_QUERY（启动器搜索框里的文字）。
# stdout 就是结果，Aster 会去掉末尾的一个换行；退出码非 0 时 Aster 显示 stderr。
set -eu

input=$(cat)
if [ -z "$input" ]; then
  input=${ASTER_QUERY-}
fi

printf '%s\n' "$input" | tr '[:lower:]' '[:upper:]'
