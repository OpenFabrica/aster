//! 在 PTY 输出里识别服务端负责应答的终端查询。
//!
//! 受管终端的权威 VT 在服务端：查询的应答必须由服务端按输出顺序写回 PTY，客户端不能
//! 再答一遍。这里识别两类查询：libghostty-vt 自己会应答的 CSI 查询（DA、DSR、DECRQM、
//! XTVERSION、kitty 键盘查询），以及它不应答、由服务端用客户端主题色补答的颜色查询
//! （OSC 10/11/12 与 CSI ? 996 n，见 `client_colors.zig`）。
//!
//! 两个用途共用一个分词器：`stripQueries` 把这些查询从交给客户端的增量里删掉；
//! `Session` 跨读流式扫描，在每个颜色查询结束处插入应答。
const std = @import("std");

pub const Kind = enum {
    /// libghostty-vt 已经写回了应答。
    answered,
    /// OSC 10/11/12 颜色查询，服务端按客户端主题色补答。
    color,
    /// CSI ? 996 n 配色（深/浅）查询，服务端按背景亮度补答。
    color_scheme,
};

/// 一个完整的查询。`start` 是起始 ESC 在本次传入缓冲区里的下标；序列跨缓冲区开始时
/// 它没有意义（流式调用方不使用它）。`end` 是终止字节之后的位置。
pub const Found = struct {
    start: usize,
    end: usize,
    kind: Kind,
    /// OSC 颜色查询的首个编号（10/11/12）与 `?` 个数：`10;?;?` 依次查询 10 与 11。
    code: u32 = 0,
    count: u8 = 0,
    /// 请求以 ST 结束（否则 BEL）；应答沿用同一种结束符。
    string_terminator: bool = false,
};

/// 与 VT 解析器同样划分转义序列边界，只认出上述查询，其余序列原样略过。
pub const Tokenizer = struct {
    state: enum { ground, escape, csi, osc, string, string_escape } = .ground,
    /// ESC 之后的 `\` 结束的是 OSC（需判定查询）还是其它控制串。
    string_is_osc: bool = false,
    sequence_start: usize = 0,
    /// 控制串里遇到的 ESC 的位置；串被打断时它成为新序列的起点。
    sequence_start_of_escape: usize = 0,
    parameters: [16]u8 = undefined,
    parameter_len: usize = 0,
    /// CSI 未夹带控制字符、参数未超长。
    csi_clean: bool = false,
    osc_code: u32 = 0,
    osc_header: bool = false,
    /// OSC 编号是 10/11/12，且载荷至今只有 `?` 与 `;`。
    osc_query: bool = false,
    osc_marks: u8 = 0,

    /// 从 `bytes[from..]` 继续扫描，返回下一个完整查询；扫完仍没有时返回 null。
    /// 解析状态跨调用保留，所以一个查询可以跨两次读完成。
    pub fn next(self: *Tokenizer, bytes: []const u8, from: usize) ?Found {
        var index = from;
        while (index < bytes.len) : (index += 1) {
            const byte = bytes[index];
            if (byte == 0x18 or byte == 0x1a) {
                self.state = .ground;
                continue;
            }
            switch (self.state) {
                .ground => if (byte == 0x1b) self.beginEscape(index),
                .escape => self.escapeByte(byte, index),
                .csi => if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = .ground;
                    if (self.csi_clean) if (classify(self.parameters[0..self.parameter_len], byte)) |kind|
                        return .{ .start = self.sequence_start, .end = index + 1, .kind = kind };
                } else if (byte == 0x1b) {
                    self.beginEscape(index);
                } else if (byte >= 0x20 and byte <= 0x3f and self.parameter_len < self.parameters.len) {
                    self.parameters[self.parameter_len] = byte;
                    self.parameter_len += 1;
                } else {
                    self.csi_clean = false;
                },
                .osc => if (byte == 7) {
                    self.state = .ground;
                    if (self.oscQuery()) return self.colorQuery(index + 1, false);
                } else if (byte == 0x1b) {
                    self.state = .string_escape;
                    self.string_is_osc = true;
                    self.sequence_start_of_escape = index;
                } else self.oscByte(byte),
                .string => if (byte == 0x1b) {
                    self.state = .string_escape;
                    self.string_is_osc = false;
                    self.sequence_start_of_escape = index;
                },
                .string_escape => if (byte == '\\') {
                    self.state = .ground;
                    if (self.string_is_osc and self.oscQuery()) return self.colorQuery(index + 1, true);
                } else {
                    // ESC 后不是 `\`：串被打断，ESC 开启新转义，这个字节是它的第二个字节。
                    self.beginEscape(self.sequence_start_of_escape);
                    self.escapeByte(byte, index);
                },
            }
        }
        return null;
    }

    fn beginEscape(self: *Tokenizer, index: usize) void {
        self.state = .escape;
        self.sequence_start = index;
    }

    fn escapeByte(self: *Tokenizer, byte: u8, index: usize) void {
        switch (byte) {
            '[' => {
                self.state = .csi;
                self.parameter_len = 0;
                self.csi_clean = true;
            },
            ']' => {
                self.state = .osc;
                self.osc_code = 0;
                self.osc_header = true;
                self.osc_query = false;
                self.osc_marks = 0;
            },
            'P', '_', '^', 'X' => self.state = .string,
            0x1b => self.beginEscape(index),
            else => self.state = .ground,
        }
    }

    fn oscByte(self: *Tokenizer, byte: u8) void {
        if (self.osc_header) {
            if (byte == ';') {
                self.osc_header = false;
                self.osc_query = self.osc_code >= 10 and self.osc_code <= 12;
            } else if (byte >= '0' and byte <= '9' and self.osc_code < 10000) {
                self.osc_code = self.osc_code * 10 + byte - '0';
            } else {
                self.osc_header = false;
            }
        } else if (self.osc_query) {
            if (byte == '?') {
                self.osc_marks +|= 1;
            } else if (byte != ';') {
                // 载荷里出现颜色值：这是设色，不是查询。
                self.osc_query = false;
            }
        }
    }

    fn oscQuery(self: *const Tokenizer) bool {
        return !self.osc_header and self.osc_query and self.osc_marks != 0;
    }

    fn colorQuery(self: *const Tokenizer, end: usize, string_terminator: bool) Found {
        return .{ .start = self.sequence_start, .end = end, .kind = .color, .code = self.osc_code, .count = self.osc_marks, .string_terminator = string_terminator };
    }
};

/// 识别 CSI 查询；`parameters` 含参数与中间字节（0x20–0x3f）。
fn classify(parameters: []const u8, final: u8) ?Kind {
    const eql = std.mem.eql;
    const answered = switch (final) {
        // DA1 / DA2 / DA3
        'c' => eql(u8, parameters, "") or eql(u8, parameters, "0") or eql(u8, parameters, ">") or
            eql(u8, parameters, ">0") or eql(u8, parameters, "=") or eql(u8, parameters, "=0"),
        'n' => {
            if (eql(u8, parameters, "?996")) return .color_scheme;
            // DSR：运行状态与光标位置
            return if (eql(u8, parameters, "5") or eql(u8, parameters, "6")) .answered else null;
        },
        // DECRQM（ANSI 与 DEC 私有模式）
        'p' => decrqm(parameters),
        // XTVERSION
        'q' => eql(u8, parameters, ">") or eql(u8, parameters, ">0"),
        // kitty 键盘协议查询
        'u' => eql(u8, parameters, "?"),
        else => false,
    };
    return if (answered) .answered else null;
}

fn decrqm(parameters: []const u8) bool {
    if (parameters.len < 2 or parameters[parameters.len - 1] != '$') return false;
    const digits = if (parameters[0] == '?') parameters[1 .. parameters.len - 1] else parameters[0 .. parameters.len - 1];
    if (digits.len == 0) return false;
    for (digits) |digit| if (digit < '0' or digit > '9') return false;
    return true;
}

/// 把服务端负责应答的查询从一段增量里删掉，返回删后长度。
///
/// 这些查询没有可见效果，应答也由服务端写回；原样留在增量里会让整块退回全量快照，
/// 客户端若收到还会再答一遍。快照以 RIS 开头，客户端 Ghostty 复位时会按 mode 2031
/// 报一次配色，Claude Code 收到后再发「OSC 11 + DA1」，于是形成每秒上百次的快照重绘。
/// `bytes` 必须从 ground 态开始；末尾未完成的序列原样保留，留给 `consumeSplit` 当尾巴。
pub fn stripQueries(bytes: []u8) usize {
    var tokenizer: Tokenizer = .{};
    var read: usize = 0;
    var written: usize = 0;
    while (tokenizer.next(bytes, read)) |found| {
        const kept = bytes[read..found.start];
        std.mem.copyForwards(u8, bytes[written..][0..kept.len], kept);
        written += kept.len;
        read = found.end;
    }
    const rest = bytes[read..];
    std.mem.copyForwards(u8, bytes[written..][0..rest.len], rest);
    return written + rest.len;
}

test "server-answered and color queries are stripped while drawing stays" {
    const cases = [_][2][]const u8{
        .{ "\x1b]11;?\x07\x1b[c", "" },
        .{ "a\x1b[6nb\x1b[>0q\x1b[?2026$p\x1b[?u\x1b[>c\x1b[?996n\x1b]10;?;?\x1b\\c", "abc" },
        .{ "\x1b[31mred\x1b[0m", "\x1b[31mred\x1b[0m" },
        // OSC / DCS 载荷里的 `[c` 不是查询；设色不是查询。
        .{ "\x1b]0;x[c\x07\x1bP[c\x1b\\\x1b]11;rgb:ff/ff/ff\x07", "\x1b]0;x[c\x07\x1bP[c\x1b\\\x1b]11;rgb:ff/ff/ff\x07" },
        // 末尾未完成的查询留给 consumeSplit 当尾巴。
        .{ "ok\x1b[", "ok\x1b[" },
        // 同名 final 的非查询不动：DECSCUSR、kitty 键盘推入、设模式、OSC 4 查询（未接管）。
        .{ "\x1b[2 q\x1b[>1u\x1b[?2004h\x1b]4;1;?\x07", "\x1b[2 q\x1b[>1u\x1b[?2004h\x1b]4;1;?\x07" },
        // 被 ESC 打断的 OSC 之后紧跟的查询仍被识别。
        .{ "\x1b]0;t\x1b[cz", "\x1b]0;tz" },
    };
    for (cases) |case| {
        var buffer: [128]u8 = undefined;
        @memcpy(buffer[0..case[0].len], case[0]);
        const kept = stripQueries(buffer[0..case[0].len]);
        try std.testing.expectEqualStrings(case[1], buffer[0..kept]);
    }
}

test "streaming tokenizer finds a color query split across reads" {
    var tokenizer: Tokenizer = .{};
    try std.testing.expect(tokenizer.next("x\x1b]1", 0) == null);
    const found = tokenizer.next("1;?\x1b\\y\x1b[?996n", 0).?;
    try std.testing.expectEqual(Kind.color, found.kind);
    try std.testing.expectEqual(@as(u32, 11), found.code);
    try std.testing.expectEqual(@as(u8, 1), found.count);
    try std.testing.expect(found.string_terminator);
    try std.testing.expectEqual(@as(usize, 5), found.end);
    const scheme = tokenizer.next("1;?\x1b\\y\x1b[?996n", found.end).?;
    try std.testing.expectEqual(Kind.color_scheme, scheme.kind);
    try std.testing.expectEqual(@as(usize, 6), scheme.start);
}
