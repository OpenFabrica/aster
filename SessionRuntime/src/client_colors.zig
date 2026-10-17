//! 客户端主题色：服务端据此应答 OSC 10/11/12 与 CSI ? 996 n。
//!
//! libghostty-vt 不应答颜色查询，以前受管终端里的程序（Claude Code、vim 等）永远收不到
//! 背景色，只能退回深色主题。转给客户端回答也不行：同一批探测里的 DA1 由服务端立刻
//! 应答，客户端的颜色应答绕一圈后才到，程序把 DA1 当作「应答结束」，照样判定没有回应。
//! 所以颜色必须由服务端按输出顺序应答。
//!
//! 颜色由本机 App 写进状态父目录的 `client-colors`（每行 `键=#rrggbb`，键为
//! foreground / background / cursor），切换主题时先写文件再更新界面。服务端每次应答前
//! 按修改时间重读。文件不存在（远端机器、旧版 App）时不应答，行为与以前一致。
const std = @import("std");
const query_scan = @import("query_scan.zig");

pub const file_name = "client-colors";
/// 文件只有三行，超过这个长度视为损坏。
const file_limit = 512;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// 与 Ghostty 一致按相对亮度判深浅。
    pub fn isDark(self: Rgb) bool {
        const luminance = 0.2126 * @as(f64, @floatFromInt(self.r)) + 0.7152 * @as(f64, @floatFromInt(self.g)) + 0.0722 * @as(f64, @floatFromInt(self.b));
        return luminance < 128;
    }
};

pub const Colors = struct {
    foreground: ?Rgb = null,
    background: ?Rgb = null,
    cursor: ?Rgb = null,

    /// 解析 `键=#rrggbb` 行；未知键与格式不对的行忽略。
    pub fn parse(text: []const u8) Colors {
        var colors: Colors = .{};
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..separator], " \t");
            const value = parseHex(std.mem.trim(u8, line[separator + 1 ..], " \t")) orelse continue;
            if (std.mem.eql(u8, key, "foreground")) colors.foreground = value else if (std.mem.eql(u8, key, "background")) colors.background = value else if (std.mem.eql(u8, key, "cursor")) colors.cursor = value;
        }
        return colors;
    }

    /// OSC 动态颜色编号对应的颜色；光标色缺省时与 Ghostty 一样回退到前景色。
    pub fn dynamic(self: Colors, code: u32) ?Rgb {
        return switch (code) {
            10 => self.foreground,
            11 => self.background,
            12 => self.cursor orelse self.foreground,
            else => null,
        };
    }

    /// 按查询生成应答，写入 `buffer` 并返回所用部分；不知道颜色时返回空串（不应答）。
    /// 格式与 Ghostty 默认的 16 位 `rgb:rrrr/gggg/bbbb` 一致，结束符沿用请求的。
    pub fn reply(self: Colors, found: query_scan.Found, buffer: []u8) []const u8 {
        switch (found.kind) {
            .answered => return "",
            .color_scheme => {
                const background = self.background orelse return "";
                return if (background.isDark()) "\x1b[?997;1n" else "\x1b[?997;2n";
            },
            .color => {
                const terminator: []const u8 = if (found.string_terminator) "\x1b\\" else "\x07";
                var used: usize = 0;
                for (0..found.count) |offset| {
                    const code = found.code + @as(u32, @intCast(offset));
                    const color = self.dynamic(code) orelse continue;
                    const written = std.fmt.bufPrint(buffer[used..], "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}{s}", .{
                        code, @as(u16, color.r) * 257, @as(u16, color.g) * 257, @as(u16, color.b) * 257, terminator,
                    }) catch break;
                    used += written.len;
                }
                return buffer[0..used];
            },
        }
    }
};

fn parseHex(text: []const u8) ?Rgb {
    if (text.len != 7 or text[0] != '#') return null;
    var bytes: [3]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[1..]) catch return null;
    return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2] };
}

/// 状态父目录里的 `client-colors`，按修改时间缓存。只在服务事件循环里使用。
pub const Source = struct {
    /// 借用的状态父目录，生命周期覆盖服务进程。
    dir: std.fs.Dir,
    cached: Colors = .{},
    mtime: i128 = 0,
    size: u64 = 0,
    loaded: bool = false,

    /// 当前颜色；文件不存在或读不出时返回空颜色。查询很少（每次启动或主题切换），
    /// 每次 stat 一下的开销可以忽略，换来主题切换后立即生效。
    pub fn current(self: *Source) Colors {
        const stat = self.dir.statFile(file_name) catch {
            self.loaded = false;
            self.cached = .{};
            return self.cached;
        };
        if (self.loaded and stat.mtime == self.mtime and stat.size == self.size) return self.cached;
        var buffer: [file_limit]u8 = undefined;
        const text = self.dir.readFile(file_name, &buffer) catch return .{};
        self.cached = Colors.parse(text);
        self.mtime = stat.mtime;
        self.size = stat.size;
        self.loaded = true;
        return self.cached;
    }
};

test "client colors parse lines and answer queries in Ghostty's format" {
    const colors = Colors.parse("foreground=#17703f\nbackground=#ffffff\nbogus\ncursor=#zz0000\n");
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b]11;rgb:ffff/ffff/ffff\x07", colors.reply(.{ .start = 0, .end = 0, .kind = .color, .code = 11, .count = 1 }, &buffer));
    // `10;?;?` 依次应答 10 与 11；光标色解析失败时回退到前景色。
    try std.testing.expectEqualStrings(
        "\x1b]10;rgb:1717/7070/3f3f\x1b\\\x1b]11;rgb:ffff/ffff/ffff\x1b\\",
        colors.reply(.{ .start = 0, .end = 0, .kind = .color, .code = 10, .count = 2, .string_terminator = true }, &buffer),
    );
    try std.testing.expectEqualStrings("\x1b]12;rgb:1717/7070/3f3f\x07", colors.reply(.{ .start = 0, .end = 0, .kind = .color, .code = 12, .count = 1 }, &buffer));
    try std.testing.expectEqualStrings("\x1b[?997;2n", colors.reply(.{ .start = 0, .end = 0, .kind = .color_scheme }, &buffer));
    try std.testing.expectEqualStrings("\x1b[?997;1n", Colors.parse("background=#1c1c1c").reply(.{ .start = 0, .end = 0, .kind = .color_scheme }, &buffer));
    // 不知道颜色就不应答，与没有客户端时一致。
    try std.testing.expectEqualStrings("", (Colors{}).reply(.{ .start = 0, .end = 0, .kind = .color, .code = 11, .count = 1 }, &buffer));
}

test "client colors source rereads the file after it changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: Source = .{ .dir = tmp.dir };
    try std.testing.expect(source.current().background == null);
    try tmp.dir.writeFile(.{ .sub_path = file_name, .data = "background=#ffffff\n" });
    try std.testing.expectEqual(@as(u8, 0xff), source.current().background.?.r);
    try tmp.dir.writeFile(.{ .sub_path = file_name, .data = "background=#000000\nforeground=#ffffff\n" });
    try std.testing.expectEqual(@as(u8, 0), source.current().background.?.r);
    try tmp.dir.deleteFile(file_name);
    try std.testing.expect(source.current().background == null);
}
