// `aster-session server upgrade`：把正在运行的旧服务实时交接给本二进制，终端进程不中断。
//
// 顺序：
// 1. 查旧服务状态。构建号与本二进制相同就什么都不做；不支持 `live_handoff` 直接报错。
// 2. 以只读观察者身份抓下每个运行中终端的完整画面，写成种子文件（handoff_seed.zig）。
//    v1 旧服务的交接信封不带画面，新服务靠种子重建 VT；v2 旧服务自带画面，种子被忽略。
// 3. 请求 `server.handoff`，指定交给本二进制（v1 旧服务忽略该参数，执行自身路径上的
//    二进制，App 替换后同样是新版）。旧服务经 SCM_RIGHTS 交出 PTY，收到确认后退出。
// 4. 等服务 epoch 变化，确认原来运行中的终端在新服务里仍在运行。
//
// 任何一步失败都清掉种子并报错；旧服务在确认之前失败会收回 PTY 继续运行，终端不受影响。
const std = @import("std");
const client = @import("service_client.zig");
const attach = @import("terminal_attach.zig");
const handoff_seed = @import("handoff_seed.zig");
const ids = @import("service_identity.zig");

/// 交接完成的等待上限：旧服务最多等确认 5 秒，新服务拿锁、接管再开始监听都在这之内。
const completion_timeout_ms: u64 = 20_000;

const Status = struct {
    epoch: []const u8,
    build: ?[]const u8,
    live_handoff: bool,
};

/// 执行升级并返回一行 JSON 结果（调用方持有）。
pub fn run(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, own_build: []const u8) ![]u8 {
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const info = try std.posix.fstat(parent.fd);
    if (info.uid != std.posix.geteuid() or info.mode & 0o077 != 0) return error.UnsafeStateParent;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const before = try status(arena, parent, name);
    if (before.build) |build| if (own_build.len != 0 and std.mem.eql(u8, build, own_build))
        return try std.json.Stringify.valueAlloc(allocator, .{ .type = "server_upgrade", .upgraded = false, .reason = "current", .serverEpoch = before.epoch }, .{});
    if (!before.live_handoff) return error.HandoffUnsupported;

    var state_dir = try parent.openDir(name, .{ .no_follow = true });
    defer state_dir.close();
    handoff_seed.clear(state_dir);
    errdefer handoff_seed.clear(state_dir);

    const running = try runningTerminals(arena, parent, name);
    var seeded: usize = 0;
    for (running) |terminal_id| {
        // 抓不到某个终端的画面不阻止交接：它会从空白 VT 开始，其余终端照常保留画面。
        const bytes = attach.captureSnapshot(arena, parent, name, terminal_id) catch continue;
        handoff_seed.write(state_dir, before.epoch, terminal_id[0..36].*, bytes) catch continue;
        seeded += 1;
    }

    try requestHandoff(arena, parent, name);

    var clock = try std.time.Timer.start();
    const after = while (clock.read() / std.time.ns_per_ms < completion_timeout_ms) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        const current = status(arena, parent, name) catch continue;
        if (!std.mem.eql(u8, current.epoch, before.epoch)) break current;
    } else return error.HandoffNotCompleted;

    // 新服务必须接管了原来所有运行中的终端；少一个都算失败，交给调用方处理。
    const adopted = try runningTerminals(arena, parent, name);
    for (running) |terminal_id| {
        const found = for (adopted) |candidate| {
            if (std.mem.eql(u8, candidate, terminal_id)) break true;
        } else false;
        if (!found) return error.HandoffLostTerminal;
    }
    return try std.json.Stringify.valueAlloc(allocator, .{
        .type = "server_upgrade",
        .upgraded = true,
        .previousEpoch = before.epoch,
        .serverEpoch = after.epoch,
        .build = after.build,
        .terminals = running.len,
        .seeded = seeded,
    }, .{});
}

/// 读服务的 epoch、构建号与是否支持实时交接。
fn status(arena: std.mem.Allocator, parent: std.fs.Dir, name: []const u8) !Status {
    const reply = try client.status(arena, parent, name, 3000);
    if (reply.is_error) return error.ServiceStatusFailed;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, reply.bytes, .{});
    const target = parsed.object.get("target") orelse return error.InvalidStatusReply;
    const epoch = target.object.get("serverEpoch") orelse return error.InvalidStatusReply;
    const result = parsed.object.get("result") orelse return error.InvalidStatusReply;
    var live_handoff = false;
    if (result.object.get("capabilities")) |capabilities| if (capabilities == .array) {
        for (capabilities.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, "live_handoff")) live_handoff = true;
        }
    };
    const build: ?[]const u8 = if (result.object.get("build")) |value| (if (value == .string) value.string else null) else null;
    if (epoch != .string) return error.InvalidStatusReply;
    return .{ .epoch = epoch.string, .build = build, .live_handoff = live_handoff };
}

/// 当前运行中终端的 ID。
fn runningTerminals(arena: std.mem.Allocator, parent: std.fs.Dir, name: []const u8) ![]const []const u8 {
    var owner = try attach.Client.connect(arena, parent, name, ids.uuidText(ids.newUUID()));
    defer owner.stream.close();
    const reply = try owner.rpc(.@"terminal.list", .{});
    const terminals = reply.value.result.object.get("terminals") orelse return error.InvalidTerminalReply;
    if (terminals != .array) return error.InvalidTerminalReply;
    var result: std.ArrayList([]const u8) = .empty;
    for (terminals.array.items) |terminal| {
        const state = terminal.object.get("state") orelse continue;
        const id = terminal.object.get("terminalID") orelse continue;
        if (state != .string or id != .string or id.string.len != 36) continue;
        if (std.mem.eql(u8, state.string, "running")) try result.append(arena, try arena.dupe(u8, id.string));
    }
    return result.items;
}

/// 请求旧服务开始交接。回复只表示「已接受」，结果要看 epoch 是否变化。
fn requestHandoff(arena: std.mem.Allocator, parent: std.fs.Dir, name: []const u8) !void {
    var owner = try attach.Client.connect(arena, parent, name, ids.uuidText(ids.newUUID()));
    defer owner.stream.close();
    // 显式指定交给本二进制。v1 旧服务不认这个参数，照旧执行自身路径上的二进制（App 替换后
    // 同样是新版）；v2 起按这里的路径执行，App 搬过安装位置也不会交给别的版本。
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_buf);
    const reply = try owner.rpc(.@"server.handoff", .{ .binary = self_path });
    const result = reply.value.result;
    const accepted = if (result == .object) result.object.get("accepted") else null;
    if (accepted == null or accepted.? != .bool or !accepted.?.bool) return error.HandoffRejected;
}
