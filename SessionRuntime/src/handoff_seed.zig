// 实时交接的画面种子文件：给不会随信封发送画面快照的 v1 旧服务补 VT 状态。
//
// `server upgrade` 在请求交接之前，以只读观察者身份从旧服务取每个终端的完整快照，写到
// 状态目录的 `handoff-seed/<terminalID>.seed`。接管的新服务收到 v1 信封时读取这些文件重建
// VT，用完整体删除。文件头带旧服务 epoch：只有发出这份信封的那个旧服务实例的种子才会被采用，
// 上一次失败的升级留下的旧种子不会被误用。
const std = @import("std");

const dir_name = "handoff-seed";
const magic = "ASHS";
const format_version: u8 = 1;
// magic(4) + version(1) + epoch(36) + length(4)
const header_len = 4 + 1 + 36 + 4;

/// 种子上限与信封内快照一致。
pub const max_bytes: usize = @import("handoff.zig").max_snapshot_bytes;

/// 原子写入一个终端的种子：先写临时文件再改名，权限 0600，目录 0700。
pub fn write(state_dir: std.fs.Dir, epoch: []const u8, terminal_id: [36]u8, bytes: []const u8) !void {
    if (epoch.len != 36) return error.InvalidEpoch;
    if (bytes.len > max_bytes) return error.SeedTooLarge;
    std.posix.mkdirat(state_dir.fd, dir_name, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try state_dir.openDir(dir_name, .{ .no_follow = true });
    defer dir.close();
    var final_name: [36 + 5]u8 = undefined;
    var staging_name: [36 + 9]u8 = undefined;
    _ = try std.fmt.bufPrint(&final_name, "{s}.seed", .{terminal_id});
    _ = try std.fmt.bufPrint(&staging_name, "{s}.seed.tmp", .{terminal_id});
    {
        var file = try dir.createFile(&staging_name, .{ .mode = 0o600, .truncate = true, .exclusive = false });
        defer file.close();
        var header: [header_len]u8 = undefined;
        @memcpy(header[0..4], magic);
        header[4] = format_version;
        @memcpy(header[5..41], epoch);
        std.mem.writeInt(u32, header[41..45], @intCast(bytes.len), .big);
        try file.writeAll(&header);
        try file.writeAll(bytes);
        try file.sync();
    }
    try dir.rename(&staging_name, &final_name);
}

/// 读取一个终端的种子；文件不存在、格式不对或不是 `epoch` 那个旧服务的种子时返回 null。
pub fn read(allocator: std.mem.Allocator, state_dir: std.fs.Dir, epoch: []const u8, terminal_id: []const u8) !?[]u8 {
    if (epoch.len != 36 or terminal_id.len != 36) return null;
    var dir = state_dir.openDir(dir_name, .{ .no_follow = true }) catch return null;
    defer dir.close();
    var name: [36 + 5]u8 = undefined;
    _ = try std.fmt.bufPrint(&name, "{s}.seed", .{terminal_id});
    var file = dir.openFile(&name, .{}) catch return null;
    defer file.close();
    var header: [header_len]u8 = undefined;
    if ((file.readAll(&header) catch return null) != header_len) return null;
    if (!std.mem.eql(u8, header[0..4], magic) or header[4] != format_version) return null;
    if (!std.mem.eql(u8, header[5..41], epoch)) return null;
    const length = std.mem.readInt(u32, header[41..45], .big);
    if (length > max_bytes) return null;
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    if ((file.readAll(bytes) catch return null) != length) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

/// 删除全部种子。接管完成或升级失败后调用；目录不存在不算错误。
pub fn clear(state_dir: std.fs.Dir) void {
    state_dir.deleteTree(dir_name) catch {};
}

test "seed round-trips only for the matching old-service epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const epoch = "11111111-1111-4111-8111-111111111111";
    const other = "22222222-2222-4222-8222-222222222222";
    const id = "33333333-3333-4333-8333-333333333333".*;
    try write(tmp.dir, epoch, id, "\x1bcHELLO");
    const found = (try read(std.testing.allocator, tmp.dir, epoch, &id)).?;
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings("\x1bcHELLO", found);
    try std.testing.expect((try read(std.testing.allocator, tmp.dir, other, &id)) == null);
    clear(tmp.dir);
    try std.testing.expect((try read(std.testing.allocator, tmp.dir, epoch, &id)) == null);
}
