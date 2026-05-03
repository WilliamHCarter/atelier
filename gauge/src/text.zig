const std = @import("std");
const ansi = @import("ansi.zig");
const grapheme_mod = @import("grapheme.zig");
const width_mod = @import("width.zig");

pub const Error = error{
    BufferTooSmall,
    LineCapacityExceeded,
};

pub const WrappedLine = struct {
    bytes: []const u8,
    width: u32,
};

const BreakPoint = struct {
    start: u32,
    end: u32,
    width_before: u32,
    width_after: u32,
};

/// Returns the number of terminal rows occupied by bytes.
///
/// ANSI escape sequences are ignored, so newlines inside OSC payloads do not
/// create rows. Empty input occupies zero rows.
pub fn height(bytes: []const u8) u32 {
    std.debug.assert(bytes.len <= std.math.maxInt(u32)); // precondition: length fits in u32

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

    std.debug.assert(rows >= 1); // postcondition: non-empty input has at least one row
    std.debug.assert(rows <= bytes.len + 1); // postcondition: one row per LF plus initial row
    return rows;
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
    std.debug.assert(bytes.len <= std.math.maxInt(u32)); // precondition: length fits in u32
    std.debug.assert(ellipsis.len <= std.math.maxInt(u32)); // precondition: length fits in u32

    const ellipsis_width = width_mod.width(ellipsis);
    const source_width = width_mod.width(bytes);
    if (source_width <= max_width) {
        if (buf.len < bytes.len) return error.BufferTooSmall;
        @memcpy(buf[0..bytes.len], bytes);
        std.debug.assert(bytes.len <= buf.len); // postcondition: copy fits caller buffer
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

    std.debug.assert(width_mod.width(buf[0..dst]) <= max_width); // postcondition: bounded width
    std.debug.assert(dst <= buf.len); // postcondition: output fits caller buffer
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
    std.debug.assert(bytes.len <= std.math.maxInt(u32)); // precondition: length fits in u32
    std.debug.assert(max_width > 0); // precondition: caller chooses a non-zero column limit

    var ctx = WrapContext{
        .bytes = bytes,
        .max_width = max_width,
        .lines = lines,
    };
    try ctx.run();

    std.debug.assert(ctx.count <= lines.len); // postcondition: line count fits output storage
    std.debug.assert(ctx.i <= bytes.len); // postcondition: scan never overruns input
    return lines[0..ctx.count];
}

const WrapContext = struct {
    bytes: []const u8,
    max_width: u32,
    lines: []WrappedLine,
    count: u32 = 0,
    i: u32 = 0,
    line_start: u32 = 0,
    line_width: u32 = 0,
    last_break: ?BreakPoint = null,
    trim_break_spaces: bool = false,

    fn run(self: *WrapContext) Error!void {
        std.debug.assert(self.max_width > 0); // precondition: max width is usable
        std.debug.assert(self.bytes.len <= std.math.maxInt(u32)); // precondition: bounded input

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

        std.debug.assert(self.i <= self.bytes.len); // postcondition: scanner remains in bounds
        std.debug.assert(self.count <= self.lines.len); // postcondition: output remains bounded
    }

    fn skipAnsi(self: *WrapContext) bool {
        std.debug.assert(self.i < self.bytes.len); // precondition: caller checks bounds
        if (self.bytes[self.i] != 0x1b) return false;

        const seq_len = ansi.escapeSequenceLen(self.bytes, self.i);
        if (seq_len == 0) return false;
        self.i += seq_len;

        std.debug.assert(self.i <= self.bytes.len); // postcondition: ANSI skip stays in bounds
        return true;
    }

    fn emitHardBreak(self: *WrapContext) Error!void {
        std.debug.assert(self.i < self.bytes.len); // precondition: newline byte is in bounds
        std.debug.assert(self.bytes[self.i] == '\n'); // precondition: hard break is at LF

        try self.emitLine(self.line_start, self.i, self.line_width);
        self.i += 1;
        self.line_start = self.i;
        self.line_width = 0;
        self.last_break = null;
        self.trim_break_spaces = false;

        std.debug.assert(self.line_start <= self.bytes.len); // postcondition: next line starts in bounds
    }

    fn emitSoftBreak(
        self: *WrapContext,
        grapheme_len: u32,
        grapheme_width: u8,
    ) Error!void {
        std.debug.assert(grapheme_len > 0); // precondition: grapheme advances scanner
        std.debug.assert(grapheme_width <= 2); // precondition: Gauge widths are 0, 1, or 2

        if (self.last_break) |break_point| {
            if (break_point.start > self.line_start) {
                try self.emitLine(self.line_start, break_point.start, break_point.width_before);
                self.line_start = break_point.end;
                std.debug.assert(self.line_width >= break_point.width_after);
                self.line_width -= break_point.width_after;
                self.last_break = null;
                self.trim_break_spaces = true;
                return;
            }
        }

        if (isBreakSpace(self.bytes[self.i .. self.i + grapheme_len])) {
            try self.emitLine(self.line_start, self.i, self.line_width);
            self.i += grapheme_len;
            self.line_start = self.i;
            self.line_width = 0;
            self.last_break = null;
            self.trim_break_spaces = true;
            return;
        }

        if (self.i == self.line_start) {
            try self.emitLine(self.line_start, self.i + grapheme_len, grapheme_width);
            self.i += grapheme_len;
            self.line_start = self.i;
            self.line_width = 0;
            self.last_break = null;
            self.trim_break_spaces = false;
            return;
        }

        try self.emitLine(self.line_start, self.i, self.line_width);
        self.line_start = self.i;
        self.line_width = 0;
        self.last_break = null;
        self.trim_break_spaces = false;

        std.debug.assert(self.line_start <= self.bytes.len); // postcondition: next line starts in bounds
    }

    fn recordBreakIfSpace(self: *WrapContext, grapheme_len: u32, grapheme_width: u8) void {
        std.debug.assert(grapheme_len > 0); // precondition: grapheme advances scanner
        std.debug.assert(grapheme_width <= 2); // precondition: Gauge widths are 0, 1, or 2
        const grapheme = self.bytes[self.i .. self.i + grapheme_len];
        if (!isBreakSpace(grapheme)) return;

        self.last_break = .{
            .start = self.i,
            .end = self.i + grapheme_len,
            .width_before = self.line_width - grapheme_width,
            .width_after = self.line_width,
        };

        std.debug.assert(self.last_break.?.end <= self.bytes.len); // postcondition: break is in bounds
    }

    fn emitLine(self: *WrapContext, start: u32, end: u32, line_width: u32) Error!void {
        std.debug.assert(start <= end); // precondition: valid slice bounds
        std.debug.assert(end <= self.bytes.len); // precondition: slice is within source
        if (self.count >= self.lines.len) return error.LineCapacityExceeded;

        self.lines[self.count] = .{
            .bytes = self.bytes[start..end],
            .width = line_width,
        };
        self.count += 1;

        std.debug.assert(self.count <= self.lines.len); // postcondition: output remains bounded
    }
};

fn isBreakSpace(bytes: []const u8) bool {
    std.debug.assert(bytes.len > 0); // precondition: grapheme slices are non-empty
    std.debug.assert(bytes.len <= std.math.maxInt(u32)); // precondition: length fits in u32
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
