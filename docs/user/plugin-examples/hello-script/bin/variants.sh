#!/bin/sh
# 示例 list 脚本：把输入变成几种写法，每种一项。
# stdout 必须是 {"items":[{"title":…,"subtitle":…,"value":…}]}：title 必填；value 是选中后复制或预填的内容，缺省等于 title。
# 输入变化时 Aster 会 300 ms 去抖后重跑，旧进程直接取消；list 缺省超时 3 秒，所以脚本要快。
set -eu

input=$(cat)
[ -n "$input" ] || input=${ASTER_QUERY-}
[ -n "$input" ] || input='Hello, Aster'

# 转成 JSON 字符串内容：删掉换行等控制字符（保留制表符），再转义反斜杠、双引号和制表符。
json_string() {
  printf '%s' "$1" | tr -d '\000-\010\012-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

# 输出一项；第三个参数可选，作为 value。
item() {
  if [ $# -ge 3 ]; then
    printf '{"title":"%s","subtitle":"%s","value":"%s"}' "$(json_string "$1")" "$(json_string "$2")" "$(json_string "$3")"
  else
    printf '{"title":"%s","subtitle":"%s"}' "$(json_string "$1")" "$(json_string "$2")"
  fi
}

# ASTER_LOCALE 是 Aster 的界面语言（如 zh-Hans、en），脚本可以据此选择文案。
case "${ASTER_LOCALE-en}" in
  zh*) upper_label='大写'; lower_label='小写'; reversed_label='倒序'; count_label='字符数'; count_title='共 %s 个字符' ;;
  *) upper_label='Uppercase'; lower_label='Lowercase'; reversed_label='Reversed'; count_label='Characters'; count_title='%s characters' ;;
esac

count=$(printf '%s' "$input" | wc -m | tr -d ' ')

printf '{"items":['
item "$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')" "$upper_label"
printf ','
item "$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')" "$lower_label"
printf ','
item "$(printf '%s' "$input" | rev)" "$reversed_label"
printf ','
# shellcheck disable=SC2059 # 文案模板来自上面的 case，只有一个 %s
item "$(printf "$count_title" "$count")" "$count_label" "$count"
printf ']}\n'
