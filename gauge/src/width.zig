const std = @import("std");
const tables = @import("tables.zig");

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
/// Invalid UTF-8 sequences are skipped (no crash, no panic).
/// ANSI escape sequences are NOT stripped — use width() after strip_ansi() for styled text
/// (Phase 2), or use graphemeWidth() for full grapheme-cluster-correct measurement (Phase 3).
pub fn width(bytes: []const u8) u32 {
    std.debug.assert(bytes.len <= std.math.maxInt(u32)); // precondition: length fits in u32

    var total: u32 = 0;
    var i: u32 = 0;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        const end = i + seq_len;
        if (end > @as(u32, @intCast(bytes.len))) break;
        const cp = std.unicode.utf8Decode(bytes[i..end]) catch {
            i += seq_len;
            continue;
        };
        total += codepointWidth(cp);
        i = end;
    }

    // Each UTF-8 byte contributes at most 1 column (ASCII) or 2 columns for multi-byte
    // sequences that are at least 2 bytes long, so total can never exceed byte count.
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
