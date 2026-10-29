#!/usr/bin/env bash
# Reproducible native P0 runtime verification; AppKit runs separately.
set -euo pipefail
runtime_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$runtime_dir/scripts/build-vt.sh" native
cd "$runtime_dir"
zig build -Dvt-prefix=.build/vt-host
zig build test-reactor test-startup test-pool test-workspace-store test-registry test-event-stream -Dvt-prefix=.build/vt-host --summary all
python3 tests/probe.py zig-out/bin/aster-session
python3 tests/handshake_gate.py zig-out/bin/aster-session
python3 tests/snapshot_gate.py zig-out/bin/aster-session
python3 tests/bridge_pty.py zig-out/bin/aster-session

python3 tests/graphics_service.py zig-out/bin/aster-session

python3 tests/delta_service.py zig-out/bin/aster-session
python3 tests/delta_gate.py zig-out/bin/aster-session

python3 tests/service_server.py zig-out/bin/aster-session

python3 tests/service_client.py zig-out/bin/aster-session

python3 tests/service_launch.py zig-out/bin/aster-session

python3 tests/service_stop.py zig-out/bin/aster-session

# 实时交接：同版本（v2 信封带画面）。设 ASTER_HANDOFF_OLD_BINARY 指向旧版发布包里的
# aster-session 时再跑一遍 v1 兼容路径（画面靠种子文件重建）。
python3 tests/live_handoff.py zig-out/bin/aster-session
if [[ -n "${ASTER_HANDOFF_OLD_BINARY:-}" ]]; then
  python3 tests/live_handoff.py zig-out/bin/aster-session "$ASTER_HANDOFF_OLD_BINARY"
fi

python3 tests/session_registry.py zig-out/bin/aster-session

python3 tests/workspace_transaction.py zig-out/bin/aster-session

python3 tests/event_stream.py zig-out/bin/aster-session
