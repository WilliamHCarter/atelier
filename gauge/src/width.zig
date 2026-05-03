const std = @import("std");
const tables = @import("tables.zig");
const eaw = tables.east_asian_width;
const zw = tables.zero_width;

/// East Asian Ambiguous characters default to narrow (1 column).
/// Named constant rather than a magic literal — see gauge-research.md §Lessons Learned #3.
pub const east_asian_ambiguous_width: u8 = 1;

/// Returns the display width of a single Unicode codepoint in terminal columns.
///
/// Priority order (matches rivo/uniseg §runeWidth priority):
///   1. C0/C1 control characters              → 0
///   2. Zero-width table hit (Mn, Me, ZWJ…)   → 0
///   3. Wide (W) or Fullwidth (F) table hit    → 2
///   4. Default                                → 1
///
/// NOTE: This does not account for grapheme cluster context. ZWJ sequences,
/// VS-16 presentation variants, and skin-tone modifiers require cluster-level
/// measurement (Phase 3). Use graphemeWidth() for fully correct results.
pub fn codepointWidth(cp: u21) u8 {
    // 1. C0 controls (U+0000–U+001F) and C1 controls (U+007F–U+009F)
    if (cp <= 0x001F or (cp >= 0x007F and cp <= 0x009F)) return 0;

    // 2. Zero-width: combining marks, ZWJ, ZWNJ, variation selectors, etc.
    if (binarySearchZw(cp)) return 0;

    // 3. Wide or Fullwidth per East Asian Width property
    if (binarySearchEaw(cp)) return 2;

    // 4. Default: narrow (includes East Asian Ambiguous at width 1)
    return 1;
}

/// Binary-search the EAW table. Returns true if cp is Wide or Fullwidth.
fn binarySearchEaw(cp: u21) bool {
    const t = eaw.table;
    var lo: u32 = 0;
    var hi: u32 = @intCast(t.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < t[mid].first) {
            hi = mid;
        } else if (cp > t[mid].last) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Binary-search the zero-width table. Returns true if cp has display width 0.
fn binarySearchZw(cp: u21) bool {
    const t = zw.table;
    var lo: u32 = 0;
    var hi: u32 = @intCast(t.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < t[mid].first) {
            hi = mid;
        } else if (cp > t[mid].last) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
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
