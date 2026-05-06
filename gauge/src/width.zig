const std = @import("std");
const tables = @import("tables.zig");
const ansi = @import("ansi.zig");
const grapheme_mod = @import("grapheme.zig");

/// East Asian Ambiguous characters default to narrow (1 column).
/// Named constant rather than a magic literal — see gauge-research.md §Lessons Learned #3.
pub const east_asian_ambiguous_width: u8 = 1;

/// Returns the display width of a single Unicode codepoint in terminal columns.
///
/// Priority order (matches rivo/uniseg §runeWidth priority):
///   1. ASCII printable fast path (0x20–0x7E)  → 1  (no table lookup)
///   2. C0/C1 control characters               → 0
///   3. Zero-width table hit (Mn, Me, ZWJ…)    → 0
///   4. Wide (W) or Fullwidth (F) table hit     → 2
///   5. Default                                 → 1
///
/// NOTE: This does not account for grapheme cluster context. ZWJ sequences,
/// VS-16 presentation variants, and skin-tone modifiers require cluster-level
/// measurement (Phase 3). Use graphemeWidth() for fully correct results.
pub fn codepointWidth(codepoint: u21) u8 {
    std.debug.assert(codepoint <= 0x10FFFF); // precondition: valid Unicode scalar value

    const result: u8 = blk: {
        // Fast path: ASCII printable characters cover the majority of terminal text.
        // No table lookup needed — ASCII is never wide and never zero-width.
        if (codepoint >= 0x20 and codepoint <= 0x7E) break :blk 1;

        // C0 controls (U+0000–U+001F) and C1 controls + DEL (U+007F–U+009F)
        if (codepoint <= 0x001F or (codepoint >= 0x007F and codepoint <= 0x009F)) break :blk 0;

        // Zero-width: combining marks, ZWJ, ZWNJ, variation selectors, etc.
        if (binarySearchRanges(tables.zero_width.Range, &tables.zero_width.table, codepoint)) break :blk 0;

        // Wide or Fullwidth per East Asian Width property
        if (binarySearchRanges(tables.east_asian_width.Range, &tables.east_asian_width.table, codepoint)) break :blk 2;

        break :blk 1;
    };

    std.debug.assert(result <= 2); // postcondition: Phase 1 widths are 0, 1, or 2
    return result;
}

/// Binary-searches a sorted range table. Returns true if codepoint falls within any range.
/// Comptime Range parameter allows one implementation to serve both table types.
fn binarySearchRanges(comptime Range: type, table: []const Range, codepoint: u21) bool {
    std.debug.assert(table.len > 0); // precondition: tables are never empty
    std.debug.assert(codepoint <= 0x10FFFF); // precondition: caller must validate codepoint
    var lo: u32 = 0;
    var hi: u32 = @intCast(table.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (codepoint < table[mid].first) {
            hi = mid;
        } else if (codepoint > table[mid].last) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Returns the total display width of a UTF-8 encoded string in terminal columns.
///
/// Measures at grapheme cluster granularity (UAX #29): ZWJ emoji sequences,
/// skin-tone variants, and VS-16 presentation selectors are handled correctly.
/// ANSI escape sequences are skipped in-place with no allocation.
/// Invalid UTF-8 bytes are skipped gracefully.
pub fn width(bytes: []const u8) u32 {
    std.debug.assert(bytes.len <= std.math.maxInt(u32)); // precondition: length fits in u32

    if (asciiWidth(bytes)) |ascii_width| return ascii_width;

    var total: u32 = 0;
    var i: u32 = 0;
    while (i < bytes.len) {
        // Skip ANSI escape sequences in-place — no allocation required.
        if (bytes[i] == 0x1b) {
            const seq_len = ansi.escapeSequenceLen(bytes, i);
            if (seq_len > 0) {
                i += seq_len;
                continue;
            }
        }
        // Advance one grapheme cluster and accumulate its display width.
        const result = grapheme_mod.step(bytes[i..]) orelse break;
        total += result.grapheme.width;
        i += @intCast(result.grapheme.bytes.len);
    }

    // Each UTF-8 byte contributes at most 1 column, so total never exceeds byte count.
    std.debug.assert(total <= bytes.len);
    return total;
}

/// Fast path for ASCII-only input, including ANSI escapes. Returns null as soon
/// as a non-ASCII byte appears so Unicode grapheme handling remains authoritative.
inline fn isAllAscii(x: u64) bool {
    return (x & 0x8080808080808080) == 0;
}

inline fn hasByte(x: u64, byte: u8) bool {
    const splat = @as(u64, @intCast(byte)) * 0x0101010101010101;
    const cmp = x ^ splat;
    return ((cmp -% 0x0101010101010101) & ~cmp & 0x8080808080808080) != 0;
}

inline fn printableWidth(b: u8) u32 {
    return @intFromBool(@as(u8, b -% 0x20) <= 0x5e);
}

fn asciiWidth(bytes: []const u8) ?u32 {
    std.debug.assert(bytes.len <= std.math.maxInt(u32));

    var total: u32 = 0;
    var i: u32 = 0;

    while (i < bytes.len) {
        if (i + 8 <= bytes.len) {
            const chunk: u64 = @bitCast(bytes[i..][0..8].*);
            if (isAllAscii(chunk) and !hasByte(chunk, 0x1b)) {
                inline for (0..8) |offset| {
                    total += printableWidth(bytes[i + offset]);
                }
                i += 8;
                continue;
            }
        }

        const byte = bytes[i];
        if (byte >= 0x80) return null;

        if (byte == 0x1b) {
            const seq_len = ansi.escapeSequenceLen(bytes, i);
            if (seq_len > 0) {
                i += seq_len;
                continue;
            }
        }

        total += printableWidth(byte);
        i += 1;
    }

    std.debug.assert(total <= bytes.len);
    return total;
}

const testing = std.testing;

test "codepointWidth: ASCII printable" {
    try testing.expectEqual(@as(u8, 1), codepointWidth(' '));
    try testing.expectEqual(@as(u8, 1), codepointWidth('A'));
    try testing.expectEqual(@as(u8, 1), codepointWidth('z'));
    try testing.expectEqual(@as(u8, 1), codepointWidth('~'));
}

test "codepointWidth: C0 controls" {
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x00)); // NUL
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x09)); // TAB
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x0A)); // LF
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x1F)); // last C0
}

test "codepointWidth: C1 controls and DEL" {
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x7F)); // DEL
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x80));
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x9F)); // last C1
}

test "codepointWidth: CJK Unified Ideographs" {
    try testing.expectEqual(@as(u8, 2), codepointWidth(0x4E00)); // '一'
    try testing.expectEqual(@as(u8, 2), codepointWidth(0x9FFF));
    try testing.expectEqual(@as(u8, 2), codepointWidth(0x6587)); // '文'
}

test "codepointWidth: Hangul syllables" {
    try testing.expectEqual(@as(u8, 2), codepointWidth(0xAC00)); // '가'
    try testing.expectEqual(@as(u8, 2), codepointWidth(0xD7A3)); // last Hangul
}

test "codepointWidth: fullwidth Latin" {
    try testing.expectEqual(@as(u8, 2), codepointWidth(0xFF01)); // '！'
    try testing.expectEqual(@as(u8, 2), codepointWidth(0xFF41)); // 'ａ'
}

test "codepointWidth: halfwidth Katakana" {
    try testing.expectEqual(@as(u8, 1), codepointWidth(0xFF65)); // halfwidth katakana middle dot
    try testing.expectEqual(@as(u8, 1), codepointWidth(0xFF9F)); // halfwidth katakana voiced iteration mark
}

test "codepointWidth: combining marks are zero-width" {
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x0300)); // COMBINING GRAVE ACCENT
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x0301)); // COMBINING ACUTE ACCENT
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x20D0)); // COMBINING LEFT HARPOON ABOVE (Me)
}

test "codepointWidth: ZWJ and ZWNJ" {
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x200D)); // ZWJ
    try testing.expectEqual(@as(u8, 0), codepointWidth(0x200C)); // ZWNJ
}

test "codepointWidth: variation selectors" {
    try testing.expectEqual(@as(u8, 0), codepointWidth(0xFE0F)); // VS-16 (emoji presentation)
    try testing.expectEqual(@as(u8, 0), codepointWidth(0xFE0E)); // VS-15 (text presentation)
}

test "codepointWidth: emoji (base, no ZWJ)" {
    // Without grapheme cluster context, emoji base codepoints are wide.
    try testing.expectEqual(@as(u8, 2), codepointWidth(0x1F600)); // 😀
    try testing.expectEqual(@as(u8, 2), codepointWidth(0x1F30D)); // 🌍
}

test "codepointWidth: Latin supplement stays narrow" {
    try testing.expectEqual(@as(u8, 1), codepointWidth(0x00C0)); // 'À' — East Asian Ambiguous → narrow
    try testing.expectEqual(@as(u8, 1), codepointWidth(0x00E9)); // 'é'
}

test "width: ASCII string" {
    try testing.expectEqual(@as(u32, 5), width("Hello"));
    try testing.expectEqual(@as(u32, 0), width(""));
}

test "width: CJK string" {
    try testing.expectEqual(@as(u32, 4), width("你好")); // 2 wide chars = 4
}

test "width: mixed ASCII and CJK" {
    try testing.expectEqual(@as(u32, 10), width("abc你好def")); // 3 + 4 + 3
}

test "width: emoji base codepoint" {
    // Pre-Phase 3: emoji measured per-codepoint, no cluster context.
    // 😀 (U+1F600) = 2 cols, space = 1, total 3.
    try testing.expectEqual(@as(u32, 3), width("😀 "));
}

test "width: combining mark does not add columns" {
    // 'A' + COMBINING GRAVE ACCENT: visually 'À' but two codepoints.
    // Per-codepoint: 1 + 0 = 1.
    try testing.expectEqual(@as(u32, 1), width("A\xcc\x80"));
}

test "width: invalid UTF-8 is skipped" {
    // Lone continuation byte and overlong sequence — should not crash.
    try testing.expectEqual(@as(u32, 0), width("\xFF\xFE"));
    try testing.expectEqual(@as(u32, 1), width("A\xFF"));
}

test "width: ANSI SGR sequences are ignored" {
    try testing.expectEqual(@as(u32, 5), width("\x1b[31mHello\x1b[0m"));
    try testing.expectEqual(@as(u32, 5), width("\x1b[1;32mHello\x1b[0m"));
}

test "width: ANSI OSC hyperlink is ignored" {
    const input = "\x1b]8;;https://example.com\x1b\\click\x1b]8;;\x1b\\";
    try testing.expectEqual(@as(u32, 5), width(input));
}

test "width: mixed styled and plain text" {
    // "\x1b[31m" + "你好" + "\x1b[0m" — only CJK contributes to width
    try testing.expectEqual(@as(u32, 4), width("\x1b[31m你好\x1b[0m"));
}

test "width: ASCII fast path keeps controls zero-width" {
    try testing.expectEqual(@as(u32, 2), width("A\nB"));
    try testing.expectEqual(@as(u32, 2), width("A\tB"));
    try testing.expectEqual(@as(u32, 2), width("A\x01B"));
}
