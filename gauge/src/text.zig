const std = @import("std");
const ansi = @import("ansi.zig");
const grapheme_mod = @import("grapheme.zig");
const width_mod = @import("width.zig");

pub const Error = error{
    BufferTooSmall,
    InputTooLarge,
    InvalidWidth,
    LineCapacityExceeded,
};

pub const WrappedLine = struct {
    bytes: []const u8,
    width: u32,
};

pub const TextSize = struct {
    width: u32,
    height: u32,
};

const BreakPoint = struct {
    start: u32,
    end: u32,
    width_before: u32,
    width_after: u32,
};

const WrapMode = enum { wrap, text_size };

fn WrapContext(comptime mode: WrapMode) type {
    const Output = switch (mode) {
        .wrap => struct {
            lines: []WrappedLine,
        },
        .text_size => struct {
            max_line_width: u32 = 0,
        },
    };

    return struct {
        const Self = @This();

        bytes: []const u8,
        max_width: u32,
        out: Output,
        count: u32 = 0,
        i: u32 = 0,
        line_start: u32 = 0,
        line_width: u32 = 0,
        last_break: ?BreakPoint = null,
        trim_break_spaces: bool = false,

        fn setLineState(
            self: *Self,
            start: u32,
            width: u32,
            last_break: ?BreakPoint,
            trim_break_spaces: bool,
        ) void {
            self.line_start = start;
            self.line_width = width;
            self.last_break = last_break;
            self.trim_break_spaces = trim_break_spaces;
        }

        fn run(self: *Self) Error!void {
            std.debug.assert(self.max_width > 0);
            std.debug.assert(self.bytes.len <= std.math.maxInt(u32));

            while (self.i < self.bytes.len) {
                if (self.skipAnsi()) continue;
                if (self.bytes[self.i] == '\n') {
                    try self.emitHardBreak();
                    continue;
                }

                const result = grapheme_mod.step(self.bytes[self.i..]) orelse break;
                const grapheme_len: u32 = @intCast(result.grapheme.bytes.len);
                if (self.trim_break_spaces and self.i == self.line_start and isBreakSpace(result.grapheme.bytes)) {
                    self.i += grapheme_len;
                    self.line_start = self.i;
                    continue;
                }
                self.trim_break_spaces = false;

                if (self.line_width + result.grapheme.width > self.max_width) {
                    try self.emitSoftBreak(grapheme_len, result.grapheme.width);
                    continue;
                }

                self.line_width += result.grapheme.width;
                self.recordBreakIfSpace(grapheme_len, result.grapheme.width);
                self.i += grapheme_len;
            }

            if (self.line_start < self.bytes.len) {
                try self.emitLine(self.line_start, @intCast(self.bytes.len), self.line_width);
            }

            std.debug.assert(self.i <= self.bytes.len);
            switch (mode) {
                .wrap => std.debug.assert(self.count <= self.out.lines.len),
                .text_size => {},
            }
        }

        fn skipAnsi(self: *Self) bool {
            std.debug.assert(self.i < self.bytes.len);
            if (self.bytes[self.i] != 0x1b) return false;

            const seq_len = ansi.escapeSequenceLen(self.bytes, self.i);
            if (seq_len == 0) return false;
            self.i += seq_len;

            std.debug.assert(self.i <= self.bytes.len);
            return true;
        }

        fn emitHardBreak(self: *Self) Error!void {
            std.debug.assert(self.i < self.bytes.len);
            std.debug.assert(self.bytes[self.i] == '\n');

            try self.emitLine(self.line_start, self.i, self.line_width);
            self.i += 1;
            self.setLineState(self.i, 0, null, false);

            std.debug.assert(self.line_start <= self.bytes.len);
        }

        fn emitSoftBreak(self: *Self, grapheme_len: u32, grapheme_width: u8) Error!void {
            std.debug.assert(grapheme_len > 0);
            std.debug.assert(grapheme_width <= 2);

            if (self.last_break) |break_point| {
                if (break_point.start > self.line_start) {
                    try self.emitLine(self.line_start, break_point.start, break_point.width_before);
                    std.debug.assert(self.line_width >= break_point.width_after);
                    self.setLineState(
                        break_point.end,
                        self.line_width - break_point.width_after,
                        null,
                        true,
                    );
                    return;
                }
            }

            if (isBreakSpace(self.bytes[self.i .. self.i + grapheme_len])) {
                try self.emitLine(self.line_start, self.i, self.line_width);
                self.i += grapheme_len;
                self.setLineState(self.i, 0, null, true);
                return;
            }

            if (self.i == self.line_start) {
                try self.emitLine(self.line_start, self.i + grapheme_len, grapheme_width);
                self.i += grapheme_len;
                self.setLineState(self.i, 0, null, false);
                return;
            }

            try self.emitLine(self.line_start, self.i, self.line_width);
            self.setLineState(self.i, 0, null, false);

            std.debug.assert(self.line_start <= self.bytes.len);
        }

        fn recordBreakIfSpace(self: *Self, grapheme_len: u32, grapheme_width: u8) void {
            std.debug.assert(grapheme_len > 0);
            std.debug.assert(grapheme_width <= 2);
            const grapheme = self.bytes[self.i .. self.i + grapheme_len];
            if (!isBreakSpace(grapheme)) return;

            self.last_break = .{
                .start = self.i,
                .end = self.i + grapheme_len,
                .width_before = self.line_width - grapheme_width,
                .width_after = self.line_width,
            };

            std.debug.assert(self.last_break.?.end <= self.bytes.len);
        }

        fn emitLine(self: *Self, start: u32, end: u32, lw: u32) Error!void {
            std.debug.assert(start <= end);
            std.debug.assert(end <= self.bytes.len);
            switch (mode) {
                .wrap => {
                    if (self.count >= self.out.lines.len) return error.LineCapacityExceeded;
                    self.out.lines[self.count] = .{
                        .bytes = self.bytes[start..end],
                        .width = lw,
                    };
                    self.count += 1;
                    std.debug.assert(self.count <= self.out.lines.len);
                },
                .text_size => {
                    if (lw > self.out.max_line_width) self.out.max_line_width = lw;
                    self.count += 1;
                },
            }
        }
    };
}

/// Returns the number of terminal rows occupied by bytes.
///
/// ANSI escape sequences are ignored, so newlines inside OSC payloads do not
/// create rows. Empty input occupies zero rows.
pub fn height(bytes: []const u8) u32 {
    std.debug.assert(bytes.len <= std.math.maxInt(u32));

    if (bytes.len == 0) return 0;

    var rows: u32 = 1;
    var i: u32 = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            const seq_len = ansi.escapeSequenceLen(bytes, i);
            if (seq_len > 0) {
                i += seq_len;
                continue;
            }
        }
        if (bytes[i] == '\n') rows += 1;
        i += 1;
    }

    std.debug.assert(rows >= 1);
    std.debug.assert(rows <= bytes.len + 1);
    return rows;
}

/// Returns the display width and line count of bytes when wrapped to max_width
/// columns. Consistent with wrap: word boundaries are preferred, grapheme
/// clusters are never split, and ANSI escape sequences contribute zero width.
/// max_width must be greater than zero.
pub fn textSize(bytes: []const u8, max_width: u32) Error!TextSize {
    if (bytes.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (max_width == 0) return error.InvalidWidth;

    if (bytes.len == 0) return .{ .width = 0, .height = 0 };

    var ctx = WrapContext(.text_size){
        .bytes = bytes,
        .max_width = max_width,
        .out = .{},
    };
    ctx.run() catch unreachable;

    std.debug.assert(ctx.count >= 1);
    std.debug.assert(ctx.i <= bytes.len);
    return .{ .width = ctx.out.max_line_width, .height = ctx.count };
}

/// Copies bytes into buf, truncated to max_width columns with ellipsis appended
/// when truncation is required. Returns the written slice of buf.
///
/// Width is measured at grapheme-cluster granularity and ANSI escape sequences
/// in the retained prefix are copied without contributing columns.
pub fn truncateIntoBuf(
    bytes: []const u8,
    max_width: u32,
    ellipsis: []const u8,
    buf: []u8,
) Error![]const u8 {
    if (bytes.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (ellipsis.len > std.math.maxInt(u32)) return error.InputTooLarge;

    const ellipsis_width = width_mod.width(ellipsis);
    const source_width = width_mod.width(bytes);
    if (source_width <= max_width) {
        if (buf.len < bytes.len) return error.BufferTooSmall;
        @memcpy(buf[0..bytes.len], bytes);
        std.debug.assert(bytes.len <= buf.len);
        return buf[0..bytes.len];
    }

    if (max_width == 0 or ellipsis_width > max_width) {
        std.debug.assert(max_width == 0 or ellipsis_width > max_width);
        return buf[0..0];
    }

    var src: u32 = 0;
    var dst: u32 = 0;
    var used_width: u32 = 0;
    while (src < bytes.len) {
        if (bytes[src] == 0x1b) {
            const seq_len = ansi.escapeSequenceLen(bytes, src);
            if (seq_len > 0) {
                if (dst + seq_len > buf.len) return error.BufferTooSmall;
                @memcpy(buf[dst .. dst + seq_len], bytes[src .. src + seq_len]);
                src += seq_len;
                dst += seq_len;
                continue;
            }
        }

        const result = grapheme_mod.step(bytes[src..]) orelse break;
        const grapheme_len: u32 = @intCast(result.grapheme.bytes.len);
        if (used_width + result.grapheme.width + ellipsis_width > max_width) break;
        if (dst + grapheme_len > buf.len) return error.BufferTooSmall;

        @memcpy(buf[dst .. dst + grapheme_len], bytes[src .. src + grapheme_len]);
        src += grapheme_len;
        dst += grapheme_len;
        used_width += result.grapheme.width;
    }

    if (dst + ellipsis.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[dst .. dst + ellipsis.len], ellipsis);
    dst += @intCast(ellipsis.len);

    std.debug.assert(width_mod.width(buf[0..dst]) <= max_width);
    std.debug.assert(dst <= buf.len);
    return buf[0..dst];
}

/// Wraps bytes into caller-provided line storage.
///
/// Lines are slices into the original input. ASCII spaces and tabs are preferred
/// breakpoints and are trimmed from the end of the previous line. Newlines force
/// a line break and are not included in returned slices.
pub fn wrap(
    bytes: []const u8,
    max_width: u32,
    lines: []WrappedLine,
) Error![]WrappedLine {
    if (bytes.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (max_width == 0) return error.InvalidWidth;

    var ctx = WrapContext(.wrap){
        .bytes = bytes,
        .max_width = max_width,
        .out = .{ .lines = lines },
    };
    try ctx.run();

    std.debug.assert(ctx.count <= lines.len);
    std.debug.assert(ctx.i <= bytes.len);
    return lines[0..ctx.count];
}

fn isBreakSpace(bytes: []const u8) bool {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(bytes.len <= std.math.maxInt(u32));
    return bytes.len == 1 and (bytes[0] == ' ' or bytes[0] == '\t');
}

const testing = std.testing;

test "height: counts rows and ignores ANSI payloads" {
    try testing.expectEqual(@as(u32, 0), height(""));
    try testing.expectEqual(@as(u32, 1), height("one"));
    try testing.expectEqual(@as(u32, 2), height("one\ntwo"));
    try testing.expectEqual(@as(u32, 1), height("\x1b]0;one\ntwo\x07visible"));
}

test "truncateIntoBuf: keeps fitting text unchanged" {
    var buf: [32]u8 = undefined;
    const out = try truncateIntoBuf("hello", 5, "...", &buf);
    try testing.expectEqualStrings("hello", out);
}

test "truncateIntoBuf: truncates at grapheme boundary" {
    var buf: [32]u8 = undefined;
    const out = try truncateIntoBuf("hello world", 8, "...", &buf);
    try testing.expectEqualStrings("hello...", out);
    try testing.expectEqual(@as(u32, 8), width_mod.width(out));
}

test "truncateIntoBuf: preserves wide grapheme budget" {
    var buf: [32]u8 = undefined;
    const out = try truncateIntoBuf("你好世界", 5, "...", &buf);
    try testing.expectEqualStrings("你...", out);
    try testing.expectEqual(@as(u32, 5), width_mod.width(out));
}

test "truncateIntoBuf: copies ANSI escapes without adding width" {
    var buf: [64]u8 = undefined;
    const out = try truncateIntoBuf("\x1b[31mhello world", 8, "...", &buf);
    try testing.expectEqualStrings("\x1b[31mhello...", out);
    try testing.expectEqual(@as(u32, 8), width_mod.width(out));
}

test "wrap: wraps on word boundary" {
    var lines_buf: [4]WrappedLine = undefined;
    const lines = try wrap("hello world", 5, &lines_buf);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("hello", lines[0].bytes);
    try testing.expectEqualStrings("world", lines[1].bytes);
    try testing.expectEqual(@as(u32, 5), lines[0].width);
    try testing.expectEqual(@as(u32, 5), lines[1].width);
}

test "wrap: trims repeated separator spaces after soft break" {
    var lines_buf: [4]WrappedLine = undefined;
    const lines = try wrap("hello  world", 5, &lines_buf);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("hello", lines[0].bytes);
    try testing.expectEqualStrings("world", lines[1].bytes);
}

test "wrap: preserves carried text when later separator overflows" {
    var lines_buf: [3]WrappedLine = undefined;
    const lines = try wrap("hello world again", 11, &lines_buf);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("hello", lines[0].bytes);
    try testing.expectEqualStrings("world again", lines[1].bytes);
    try testing.expectEqual(@as(u32, 5), lines[0].width);
    try testing.expectEqual(@as(u32, 11), lines[1].width);
}

test "wrap: empty input returns no lines" {
    var lines_buf: [1]WrappedLine = undefined;
    const lines = try wrap("", 5, &lines_buf);
    try testing.expectEqual(@as(usize, 0), lines.len);
}

test "wrap: hard newlines create lines" {
    var lines_buf: [4]WrappedLine = undefined;
    const lines = try wrap("a\nb", 10, &lines_buf);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("a", lines[0].bytes);
    try testing.expectEqualStrings("b", lines[1].bytes);
}

test "wrap: keeps grapheme clusters intact" {
    var lines_buf: [4]WrappedLine = undefined;
    const lines = try wrap("你好吗", 4, &lines_buf);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("你好", lines[0].bytes);
    try testing.expectEqualStrings("吗", lines[1].bytes);
}

test "wrap: ignores ANSI width" {
    var lines_buf: [4]WrappedLine = undefined;
    const lines = try wrap("\x1b[31mhello world", 5, &lines_buf);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("\x1b[31mhello", lines[0].bytes);
    try testing.expectEqualStrings("world", lines[1].bytes);
}

test "wrap: rejects zero width" {
    var lines_buf: [4]WrappedLine = undefined;
    try testing.expectError(error.InvalidWidth, wrap("hello", 0, &lines_buf));
}

test "textSize: empty input" {
    try testing.expectEqual(TextSize{ .width = 0, .height = 0 }, try textSize("", 80));
}

test "textSize: single line fits" {
    try testing.expectEqual(TextSize{ .width = 5, .height = 1 }, try textSize("hello", 80));
}

test "textSize: wide characters" {
    try testing.expectEqual(TextSize{ .width = 4, .height = 1 }, try textSize("你好", 80));
}

test "textSize: wraps and reports max width" {
    const size = try textSize("hello world", 5);
    try testing.expectEqual(@as(u32, 5), size.width);
    try testing.expectEqual(@as(u32, 2), size.height);
}

test "textSize: hard newline creates second line" {
    try testing.expectEqual(TextSize{ .width = 1, .height = 2 }, try textSize("a\nb", 80));
}

test "textSize: ANSI sequences contribute zero width" {
    try testing.expectEqual(TextSize{ .width = 5, .height = 1 }, try textSize("\x1b[31mhello\x1b[0m", 80));
}

test "textSize: consistent with wrap line count and max width" {
    var lines_buf: [8]WrappedLine = undefined;
    const text = "你好吗";
    const max_w: u32 = 4;
    const lines = try wrap(text, max_w, &lines_buf);
    const size = try textSize(text, max_w);

    try testing.expectEqual(@as(u32, @intCast(lines.len)), size.height);
    var max_w_seen: u32 = 0;
    for (lines) |line| {
        if (line.width > max_w_seen) max_w_seen = line.width;
    }
    try testing.expectEqual(max_w_seen, size.width);
}

test "textSize: rejects zero width" {
    try testing.expectError(error.InvalidWidth, textSize("hello", 0));
}
