const std = @import("std");

pub const Error = error{
    BufferTooSmall,
    InputTooLarge,
};

/// Scans bytes starting at index i, which must point to the byte after ESC (0x1b).
/// Returns the index of the first byte past the escape sequence, or i if not recognized.
/// Handles: CSI sequences (\x1b[...final), OSC sequences (\x1b]...ST or BEL),
/// and simple two-byte Fe sequences (\x1b followed by 0x40–0x5F excluding '[' and ']').
pub fn skipEscapeSequence(bytes: []const u8, i: u32) u32 {
    std.debug.assert(i <= bytes.len); // precondition: i is a valid offset into bytes
    if (i >= bytes.len) return i;

    switch (bytes[i]) {
        // CSI: \x1b[ ... <final byte 0x40–0x7E>
        '[' => {
            var j = i + 1;
            while (j < bytes.len) : (j += 1) {
                const b = bytes[j];
                // Parameter bytes: 0x30–0x3F, intermediate: 0x20–0x2F, final: 0x40–0x7E
                if (b >= 0x40 and b <= 0x7E) return j + 1;
                // Anything else that isn't a valid CSI byte: bail
                if (b < 0x20 or b > 0x7E) return i;
            }
            return i; // unterminated — don't skip
        },
        // OSC: \x1b] ... ST (\x1b\\) or BEL (\x07)
        ']' => {
            var j = i + 1;
            while (j < bytes.len) : (j += 1) {
                const b = bytes[j];
                if (b == 0x07) return j + 1; // BEL terminator
                if (b == 0x1b and j + 1 < bytes.len and bytes[j + 1] == '\\') return j + 2; // ST
            }
            return i; // unterminated — don't skip
        },
        // Simple Fe sequences: ESC followed by 0x40–0x5F (e.g. ESC M = reverse index)
        // '[' (0x5B) and ']' (0x5D) are handled above; exclude them from this range.
        0x40...0x5A, 0x5C, 0x5E...0x5F => return i + 1,
        else => return i,
    }

    // postcondition is enforced at each return site: result >= i (we never go backward)
}

/// Returns the number of bytes occupied by any ANSI escape sequence starting at
/// bytes[i] (which must be 0x1b). Returns 0 if not a recognized sequence.
pub fn escapeSequenceLen(bytes: []const u8, i: u32) u32 {
    std.debug.assert(i < bytes.len); // precondition: i is within bounds
    std.debug.assert(bytes[i] == 0x1b); // precondition: caller verified ESC byte
    const end = skipEscapeSequence(bytes, i + 1);
    std.debug.assert(end >= i + 1); // postcondition: end is at or past the byte after ESC
    // If skipEscapeSequence returned i+1 unchanged, no sequence was recognized.
    return if (end > i + 1) end - i else 0;
}

/// Copies bytes into buf, stripping all ANSI escape sequences.
/// Returns a slice of buf containing the stripped result.
/// buf must be at least bytes.len bytes long (stripped output is always <= input).
pub fn stripAnsiIntoBuf(bytes: []const u8, buf: []u8) Error![]u8 {
    if (bytes.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (buf.len < bytes.len) return error.BufferTooSmall;

    var src: u32 = 0;
    var dst: u32 = 0;
    while (src < bytes.len) {
        if (bytes[src] == 0x1b) {
            const seq_len = escapeSequenceLen(bytes, src);
            if (seq_len > 0) {
                src += seq_len;
                continue;
            }
        }
        buf[dst] = bytes[src];
        dst += 1;
        src += 1;
    }
    std.debug.assert(dst <= src); // postcondition: output is never longer than input
    return buf[0..dst];
}

/// Allocates and returns a copy of bytes with all ANSI escape sequences removed.
/// Caller owns the returned slice and must free it with allocator.free().
pub fn stripAnsi(allocator: std.mem.Allocator, bytes: []const u8) (std.mem.Allocator.Error || Error)![]u8 {
    if (bytes.len > std.math.maxInt(u32)) return error.InputTooLarge;

    // Stripped output is always <= input length; allocate input length to avoid a pre-scan.
    const buf = try allocator.alloc(u8, bytes.len);
    const stripped = try stripAnsiIntoBuf(bytes, buf);
    // Resize to exact length to avoid wasting memory.
    const result = allocator.realloc(buf, stripped.len) catch |err| {
        allocator.free(buf);
        return err;
    };
    std.debug.assert(result.len <= bytes.len); // postcondition: output no longer than input
    return result;
}

const testing = std.testing;

test "skipEscapeSequence: CSI SGR reset" {
    const seq = "[0m";
    try testing.expectEqual(@as(u32, 3), skipEscapeSequence(seq, 0));
}

test "skipEscapeSequence: CSI color sequence" {
    const seq = "[31m";
    try testing.expectEqual(@as(u32, 4), skipEscapeSequence(seq, 0));
}

test "skipEscapeSequence: CSI multi-param" {
    const seq = "[1;32m";
    try testing.expectEqual(@as(u32, 6), skipEscapeSequence(seq, 0));
}

test "skipEscapeSequence: OSC with BEL terminator" {
    const seq = "]0;title\x07";
    try testing.expectEqual(@as(u32, seq.len), skipEscapeSequence(seq, 0));
}

test "skipEscapeSequence: OSC with ST terminator" {
    const seq = "]0;title\x1b\\";
    try testing.expectEqual(@as(u32, seq.len), skipEscapeSequence(seq, 0));
}

test "stripAnsiIntoBuf: removes SGR sequence" {
    var buf: [64]u8 = undefined;
    const result = try stripAnsiIntoBuf("\x1b[31mHello\x1b[0m", &buf);
    try testing.expectEqualStrings("Hello", result);
}

test "stripAnsiIntoBuf: plain text unchanged" {
    var buf: [64]u8 = undefined;
    const result = try stripAnsiIntoBuf("Hello", &buf);
    try testing.expectEqualStrings("Hello", result);
}

test "stripAnsiIntoBuf: OSC hyperlink stripped" {
    var buf: [128]u8 = undefined;
    const input = "\x1b]8;;https://example.com\x1b\\click\x1b]8;;\x1b\\";
    const result = try stripAnsiIntoBuf(input, &buf);
    try testing.expectEqualStrings("click", result);
}

test "stripAnsiIntoBuf: reports small buffer" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, stripAnsiIntoBuf("Hello", &buf));
}

test "stripAnsi: allocating version" {
    const result = try stripAnsi(testing.allocator, "\x1b[1;32mGreen\x1b[0m");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Green", result);
}

test "stripAnsi: frees input-sized buffer when shrink realloc fails" {
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    const allocator = failing_allocator.allocator();

    try testing.expectError(error.OutOfMemory, stripAnsi(allocator, "\x1b[1;32mGreen\x1b[0m"));
    try testing.expectEqual(failing_allocator.allocated_bytes, failing_allocator.freed_bytes);
}
