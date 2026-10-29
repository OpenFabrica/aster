#!/usr/bin/env bash
# 构建系统状态条的传感器读取器 aster-sensors（C，温度与风扇），输出到插件的 bin 目录。
# 通用二进制（arm64 + x86_64）；用法：scripts/build-sysbar-sensors.sh [输出目录]
# 默认输出到仓库里的 Resources/tools-builtin/aster.sysbar/bin（开发时直接用；该文件已 gitignore），
# build-app.sh 传入包内的 tools-builtin/aster.sysbar/bin。脚本没找到它时状态条只是不显示温度与风扇。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$PROJECT_DIR/Resources/tools-builtin/aster.sysbar/bin}"

mkdir -p "$OUT_DIR"
clang -O2 -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework IOKit -framework CoreFoundation \
  -o "$OUT_DIR/aster-sensors" "$PROJECT_DIR/scripts/sysbar-sensors.c"
echo "aster-sensors -> $OUT_DIR/aster-sensors"
