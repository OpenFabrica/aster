#!/bin/sh
# 系统状态条：本机 CPU、GPU、温度、风扇、内存、磁盘、网络与电池（Aster bar 协议）。
# 只用系统自带命令，不需要 python；温度与风扇由同目录的 aster-sensors 读取，缺了就不显示这两项。
# 约定见 docs/developer/tools-and-plugins.md「内置系统状态条」。

# stdin 的上下文用不到；读完避免写端 SIGPIPE。
cat >/dev/null
export LC_ALL=C

now=$(date +%s)
here=$(cd "$(dirname "$0")" && pwd)
cpus=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
memsize=$(sysctl -n hw.memsize 2>/dev/null || echo 0)

# CPU：所有进程 %cpu 之和（每核 100%）除以逻辑核数。ps 的 %cpu 是近期衰减平均，够状态条用，且不用像 top 那样采样等待。
# 同一次 ps（-r 按 CPU 降序）顺带取最耗 CPU 的 3 个进程给提示用：进程名可能带空格，只去掉目录；
# 引号、反斜杠与控制字符会破坏 JSON，`|` 是下面切分用的分隔符，一并去掉。
cpuinfo=$(ps -A -r -o %cpu=,comm= | awk -v n="$cpus" '
  { s += $1 }
  NR <= 3 && $1 > 0 {
    name = substr($0, index($0, $2)); sub(/^.*\//, "", name); gsub(/[\001-\037"\\|]/, "", name)
    top = top (top == "" ? "" : ", ") name " " $1 "%"
  }
  END { v = s / (n > 0 ? n : 1); if (v > 100) v = 100; printf "%d|%s", v + 0.5, top }')
cpu=${cpuinfo%%|*}
top=${cpuinfo#*|}

# GPU：IOAccelerator 的设备占用率，多块 GPU 取最高；没有这个字段就不显示。
gpu=$(ioreg -r -d 1 -w0 -c IOAccelerator 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' \
  | awk -F= '{ if ($2 + 0 > m) m = $2 + 0; found = 1 } END { if (found) print m + 0 }')

# 温度与风扇：aster-sensors 每行 `键=值`，压成一行传给 awk（macOS 的 awk -v 不接受换行）。
sensors=""
[ -x "$here/aster-sensors" ] && sensors=$("$here/aster-sensors" 2>/dev/null | tr '\n' ' ')

# 内存：按活动监视器的「已使用内存」= App 内存（匿名页 − 可清除页）+ 联动内存 + 被压缩，单位字节。
memory=$(vm_stat | awk '
  /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") page = $(i + 1) }
  { value = $NF; sub(/\.$/, "", value) }
  /^Anonymous pages/ { anon = value }
  /^Pages purgeable/ { purgeable = value }
  /^Pages wired down/ { wired = value }
  /^Pages occupied by compressor/ { compressed = value }
  END { app = anon - purgeable; if (app < 0) app = 0; printf "%.0f %.0f %.0f", app * page, wired * page, compressed * page }')

# 内存压力（1 正常 / 2 警告 / 4 严重）与交换区已用字节：压力比「用了多少」更能说明内存是不是真的紧。
pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)
swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '{
  for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i + 2); unit = substr(v, length(v)); sub(/[A-Z]$/, "", v) }
  mult = unit == "G" ? 1073741824 : (unit == "K" ? 1024 : 1048576)
  printf "%.0f", v * mult }')

# 电池：pmset 的 InternalBattery 行，输出「电量 状态 剩余时间」。状态：d 放电、c 充电、f 已充满、a 接电源但不充电；
# 台式机没有这一行，什么都不输出，电池项就不显示。剩余时间还在估算时为 -。
battery=$(pmset -g batt 2>/dev/null | awk '/InternalBattery/ {
  if (!match($0, /[0-9]+%/)) exit
  pct = substr($0, RSTART, RLENGTH - 1)
  state = "a"
  if ($0 ~ /discharging/) state = "d"
  else if ($0 ~ /not charging/) state = "a"
  else if ($0 ~ /charged/) state = "f"
  else if ($0 ~ /charging|finishing charge/) state = "c"
  time = match($0, /[0-9]+:[0-9]+ remaining/) ? substr($0, RSTART, RLENGTH - 10) : "-"
  printf "%s %s %s", pct, state, time }')

# 磁盘：APFS 的用户数据在数据卷；老系统退回根卷。可用空间不含「可清除」部分，比访达显示的略少。
volume=/System/Volumes/Data
[ -d "$volume" ] || volume=/
disk=$(df -Pk "$volume" | awk 'NR == 2 { printf "%.0f %.0f", $2 * 1024, $4 * 1024 }')

# 网络：只累计在线的 en 接口（Wi-Fi / 以太网）。VPN 的 utun 流量也经过 en，再算会重复。
# 只认 <Link#> 行：同一接口的地址行重复同一组计数。从行尾数列，没有 MAC 地址的行列数不同也不错位。
network=$(netstat -ibn | awk '$1 ~ /^en[0-9]+$/ && $3 ~ /^<Link#/ { rx += $(NF - 4); tx += $(NF - 1) } END { printf "%.0f %.0f", rx, tx }')

# 网速要两次采样：上次的计数（时间 收 发 下行 上行 间隔）存在插件数据目录，各窗口共用。
# 两次间隔不足 2 秒（多个窗口刚跑过）时沿用上次算出的速率，不改基准；计数变小（接口重置）时这次不显示。
state=""
[ -n "$ASTER_PLUGIN_DATA" ] && state="$ASTER_PLUGIN_DATA/network.state"
previous=""
[ -n "$state" ] && previous=$(cat "$state" 2>/dev/null)
rates=$(echo "$now $network $previous" | awk '{
  now = $1; rx = $2; tx = $3
  if (NF < 9) { print "- - 0 write"; exit }
  elapsed = now - $4
  if (elapsed < 2) { print $7, $8, $9, "keep"; exit }
  if (rx < $5 || tx < $6) { print "- - 0 write"; exit }
  printf "%.0f %.0f %d write\n", (rx - $5) / elapsed, (tx - $6) / elapsed, elapsed
}')
set -- $rates
down=$1 up=$2 interval=$3
if [ -n "$state" ] && [ "$4" = "write" ]; then
  mkdir -p "$ASTER_PLUGIN_DATA" 2>/dev/null
  # 先写临时文件再改名：多个窗口同时跑时不会读到半份。
  echo "$now $network $down $up $interval" > "$state.$$" 2>/dev/null && mv -f "$state.$$" "$state" 2>/dev/null
fi

awk -v locale="$ASTER_LOCALE" -v cpus="$cpus" -v cpu="$cpu" -v top="$top" -v gpu="$gpu" -v sensors="$sensors" \
  -v total="$memsize" -v memory="$memory" -v pressure="$pressure" -v swap="$swap" -v battery="$battery" \
  -v disk="$disk" -v down="$down" -v up="$up" -v interval="$interval" -v state="$state" '
# 按界面语言选文案：脚本输出不经过 Aster 的翻译表。
function t(zh, en) { return locale ~ /^zh/ ? zh : en }
# 字节数缩写：base 取 1000（磁盘、网速，和访达一致）或 1024（内存，和活动监视器一致）。
function human(bytes, base,    units, i) {
  split("k M G T", units, " ")
  if (bytes < base) return sprintf("%dB", bytes)
  for (i = 1; i <= 4 && bytes >= base; i++) bytes /= base
  return sprintf(bytes >= 100 ? "%d%s" : "%.1f%s", bytes, units[i - 1])
}
function item(id, text, icon, color, tooltip) {
  return sprintf("{\"id\":\"%s\",\"text\":\"%s\",\"icon\":\"%s\"%s,\"tooltip\":\"%s\"}", id, text, icon,
    color == "" ? "" : ",\"color\":\"" color "\"", tooltip)
}
# 往项目列表末尾追加一项（自动补逗号）。
function add(entry) { items = items (items == "" ? "" : ",") entry }
BEGIN {
  gib = 1024 * 1024 * 1024
  # aster-sensors 的 `键=值` 行（空格分隔）读进 sensor 数组。
  n = split(sensors, pairs, " ")
  for (i = 1; i <= n; i++) { split(pairs[i], kv, "="); sensor[kv[1]] = kv[2] + 0; has[kv[1]] = 1 }

  # macOS 的 awk 不允许表达式中间换行，长表达式先拆成变量。
  detail = t("所有进程的 CPU 占用之和 ÷ " cpus " 个逻辑核", "Sum of all processes’ CPU usage ÷ " cpus " logical cores")
  if (top != "") detail = detail t("。最耗 CPU：", ". Top: ") top
  add(item("cpu", "CPU " cpu "%", "cpu", cpu >= 80 ? "warning" : "", detail))

  if (gpu != "") {
    add(item("gpu", "GPU " gpu "%", "display", "", t("GPU 设备占用率（多块 GPU 取最高）", "GPU device utilization (highest if several)")))
  }

  if (has["temp_soc"]) {
    temp = sensor["temp_soc"]
    detail = sprintf(t("芯片最热核心 %d°C", "Hottest chip core %d°C"), temp + 0.5)
    if (has["temp_battery"]) detail = detail sprintf(t(" · 电池 %d°C", " · battery %d°C"), sensor["temp_battery"] + 0.5)
    if (has["temp_nand"]) detail = detail sprintf(t(" · 闪存 %d°C", " · flash %d°C"), sensor["temp_nand"] + 0.5)
    add(item("temperature", sprintf(t("温度 %d°C", "temp %d°C"), temp + 0.5), "thermometer.medium",
      temp >= 100 ? "error" : (temp >= 90 ? "warning" : ""), detail))
  }

  fans = sensor["fans"]
  if (has["fans"] && fans > 0) {
    fastest = 0; ratio = 0; detail = ""
    for (i = 0; i < fans; i++) {
      rpm = sensor["fan" i]; max = sensor["fan" i "_max"]
      if (rpm > fastest) fastest = rpm
      if (max > 0 && rpm / max > ratio) ratio = rpm / max
      detail = detail (detail == "" ? "" : " · ") sprintf(t("风扇 %d：%d", "Fan %d: %d"), i + 1, rpm) (max > 0 ? sprintf(" / %d", max) : "") " rpm"
    }
    add(item("fan", fastest > 0 ? sprintf(t("风扇 %drpm", "fan %drpm"), fastest) : t("风扇 停转", "fan idle"), "fanblades",
      ratio >= 0.9 ? "warning" : "", detail))
  }

  split(memory, m, " ")
  used = m[1] + m[2] + m[3]
  if (total > 0) {
    # 内存压力比占用比例更准：严重 → error，警告 → warning；占用 ≥ 90% 仍保留 warning。
    level = pressure >= 4 ? t("严重", "critical") : (pressure >= 2 ? t("警告", "warning") : t("正常", "normal"))
    add(item("memory", sprintf(t("内存 %.1f/%dG", "mem %.1f/%dG"), used / gib, total / gib + 0.5),
      "memorychip", pressure >= 4 ? "error" : (pressure >= 2 || used / total >= 0.9 ? "warning" : ""),
      sprintf(t("已使用 %s：App %s · 联动 %s · 被压缩 %s · 交换 %s · 内存压力%s", "Used %s: app %s · wired %s · compressed %s · swap %s · pressure %s"),
        human(used, 1024), human(m[1], 1024), human(m[2], 1024), human(m[3], 1024), human(swap + 0, 1024), level)))
  }

  split(disk, d, " ")
  if (d[1] > 0) {
    free = d[2] / d[1]
    add(item("disk", t("磁盘 余 ", "disk ") human(d[2], 1000) t("", " free"), "internaldrive",
      free < 0.05 ? "error" : (free < 0.1 ? "warning" : ""),
      sprintf(t("数据卷共 %s，已用 %d%%（可用空间不含可清除部分）", "Data volume %s, %d%% used (available space excludes purgeable)"),
        human(d[1], 1000), (1 - free) * 100 + 0.5)))
  }

  if (down != "-") {
    add(item("network", "↓" human(down, 1000) "/s ↑" human(up, 1000) "/s", "network", "",
      sprintf(t("Wi-Fi / 以太网最近 %d 秒的平均速率", "Wi-Fi / Ethernet average over the last %d s"), interval)))
  }

  # 电池：台式机没有，battery 为空就不显示。电量图标分五档；充电中用带闪电的符号。
  split(battery, b, " ")
  if (b[1] != "") {
    pct = b[1] + 0; mode = b[2]
    icon = pct >= 88 ? "battery.100" : (pct >= 63 ? "battery.75" : (pct >= 38 ? "battery.50" : (pct >= 13 ? "battery.25" : "battery.0")))
    if (mode == "c") icon = "battery.100.bolt"
    status = mode == "d" ? t("使用电池", "On battery") : (mode == "c" ? t("充电中", "Charging") : (mode == "f" ? t("已充满", "Charged") : t("已接电源，未在充电", "On AC, not charging")))
    if (b[3] != "-" && b[3] != "") status = status (mode == "d" ? t("，剩余 ", ", ") : t("，还需 ", ", ")) b[3] (mode == "d" ? t("", " remaining") : t("", " to full"))
    add(item("battery", sprintf(t("电池 %d%%", "bat %d%%"), pct), icon,
      mode == "d" ? (pct < 10 ? "error" : (pct < 20 ? "warning" : "")) : "", status))
  }

  # 刚存下网速基准时 5 秒后再跑一次，网速尽快出现；之后按清单的 10 秒间隔。没有数据目录就不显示网速，也不加快。
  printf "{\"items\":[%s]%s}\n", items, (down == "-" && state != "" ? ",\"ttl\":5" : "")
}'
