#!/bin/sh
# 系统状态条：本机 CPU、内存、磁盘与网络（Aster bar 协议）。只用系统自带命令，不需要 python。
# 约定见 docs/developer/tools-and-plugins.md「内置系统状态条」。

# stdin 的上下文用不到；读完避免写端 SIGPIPE。
cat >/dev/null
export LC_ALL=C

now=$(date +%s)
cpus=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
memsize=$(sysctl -n hw.memsize 2>/dev/null || echo 0)

# CPU：所有进程 %cpu 之和（每核 100%）除以逻辑核数。ps 的 %cpu 是近期衰减平均，够状态条用，且不用像 top 那样采样等待。
cpu=$(ps -A -o %cpu= | awk -v n="$cpus" '{ s += $1 } END { v = s / (n > 0 ? n : 1); if (v > 100) v = 100; printf "%d", v + 0.5 }')

# 内存：按活动监视器的「已使用内存」= App 内存（匿名页 − 可清除页）+ 联动内存 + 被压缩，单位字节。
memory=$(vm_stat | awk '
  /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") page = $(i + 1) }
  { value = $NF; sub(/\.$/, "", value) }
  /^Anonymous pages/ { anon = value }
  /^Pages purgeable/ { purgeable = value }
  /^Pages wired down/ { wired = value }
  /^Pages occupied by compressor/ { compressed = value }
  END { app = anon - purgeable; if (app < 0) app = 0; printf "%.0f %.0f %.0f", app * page, wired * page, compressed * page }')

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

awk -v locale="$ASTER_LOCALE" -v cpus="$cpus" -v cpu="$cpu" -v total="$memsize" -v memory="$memory" \
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
BEGIN {
  gib = 1024 * 1024 * 1024
  items = item("cpu", "CPU " cpu "%", "cpu", cpu >= 80 ? "warning" : "",
    t("所有进程的 CPU 占用之和 ÷ " cpus " 个逻辑核", "Sum of all processes’ CPU usage ÷ " cpus " logical cores"))

  split(memory, m, " ")
  used = m[1] + m[2] + m[3]
  if (total > 0) {
    items = items "," item("memory", sprintf(t("内存 %.1f/%dG", "mem %.1f/%dG"), used / gib, total / gib + 0.5),
      "memorychip", used / total >= 0.9 ? "warning" : "",
      sprintf(t("已使用 %s：App %s · 联动 %s · 被压缩 %s", "Used %s: app %s · wired %s · compressed %s"),
        human(used, 1024), human(m[1], 1024), human(m[2], 1024), human(m[3], 1024)))
  }

  split(disk, d, " ")
  if (d[1] > 0) {
    free = d[2] / d[1]
    items = items "," item("disk", t("磁盘 余 ", "disk ") human(d[2], 1000) t("", " free"), "internaldrive",
      free < 0.05 ? "error" : (free < 0.1 ? "warning" : ""),
      sprintf(t("数据卷共 %s，已用 %d%%（可用空间不含可清除部分）", "Data volume %s, %d%% used (available space excludes purgeable)"),
        human(d[1], 1000), (1 - free) * 100 + 0.5))
  }

  if (down != "-") {
    items = items "," item("network", "↓" human(down, 1000) "/s ↑" human(up, 1000) "/s", "network", "",
      sprintf(t("Wi-Fi / 以太网最近 %d 秒的平均速率", "Wi-Fi / Ethernet average over the last %d s"), interval))
  }
  # 刚存下网速基准时 5 秒后再跑一次，网速尽快出现；之后按清单的 10 秒间隔。没有数据目录就不显示网速，也不加快。
  printf "{\"items\":[%s]%s}\n", items, (down == "-" && state != "" ? ",\"ttl\":5" : "")
}'
