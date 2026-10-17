#!/usr/bin/env bash
# 原生构建 macOS 版 aster-session（本机后台受管终端服务），输出到 SwiftPM 的 release 目录，
# 供 build-app.sh 复制进 Contents/MacOS/。没有它，打包版的 Local 受管模式（关窗口不杀进程、
# 冷恢复、Agent 原生恢复）整个不可用。
#
# libghostty-vt（.build/vt-host）只跟锁定的 ghostty revision 与补丁集有关，产物键不变时复用；
# ASTER_SESSION_RUNTIME_REBUILD_VT=1 强制重建。
#
# 用法：scripts/build-session-runtime.sh [输出目录]   默认 .build/release
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/SessionRuntime"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
OUT_DIR="${1:-$BUILD_DIR/release}"
ZIG="${ZIG:-$(brew --prefix zig@0.15 2>/dev/null || true)/bin/zig}"
if [[ ! -x "$ZIG" ]]; then ZIG="$(command -v zig || true)"; fi
if [[ -z "$ZIG" || "$("$ZIG" version)" != "0.15.2" ]]; then
  echo "error: Zig 0.15.2 is required to build aster-session (brew install zig@0.15)" >&2
  exit 1
fi

vt_prefix="$RUNTIME_DIR/.build/vt-host"
# 头文件也要检查：构建中途失败可能只装好了静态库，只看 .a 会一直跳过重建、链接时找不到 vt.h。
# 补丁集变化（产物键不符）也必须重建，否则新补丁不会进入 aster-session。
vt_key="$("$RUNTIME_DIR/scripts/build-vt.sh" --key)"
if [[ "${ASTER_SESSION_RUNTIME_REBUILD_VT:-0}" == "1" || ! -f "$vt_prefix/lib/libghostty-vt.a" ||
      ! -f "$vt_prefix/include/ghostty/vt.h" ||
      "$(cat "$vt_prefix/.aster-vt-key" 2>/dev/null)" != "$vt_key" ]]; then
  echo "== aster-session: building libghostty-vt (native)"
  (cd "$RUNTIME_DIR" && PATH="$(dirname "$ZIG"):$PATH" scripts/build-vt.sh native)
fi

# 构建号 = 运行时源码（含未提交改动）加 VT 产物键的摘要。App 启动时拿它和运行中的服务比较，
# 不一样就是升级前留下的旧服务。只看源码、不看二进制：重新签名或只改 App 不会让它变化，
# 也就不会无谓地提示重启。不在 git 工作区里时为空，App 不做比较。
build_id="$(
  cd "$RUNTIME_DIR" &&
    { git ls-files -z -co --exclude-standard 2>/dev/null | LC_ALL=C sort -z |
        xargs -0 /usr/bin/shasum -a 256 2>/dev/null || true; echo "$vt_key"; } |
    /usr/bin/shasum -a 256 | /usr/bin/cut -c1-16
)"
git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || build_id=""

echo "== aster-session: building native binary (build ${build_id:-none})"
stage="$RUNTIME_DIR/.build/service-native"
rm -rf "$stage"
(cd "$RUNTIME_DIR" && "$ZIG" build -Doptimize=ReleaseSafe -Dvt-prefix="$vt_prefix" -Dbuild-id="$build_id" --prefix "$stage")
[[ -f "$stage/bin/aster-session" ]] || { echo "error: aster-session not produced" >&2; exit 1; }
"$stage/bin/aster-session" --version >/dev/null

mkdir -p "$OUT_DIR"
cp "$stage/bin/aster-session" "$OUT_DIR/aster-session"
chmod 755 "$OUT_DIR/aster-session"
echo "$OUT_DIR/aster-session"
