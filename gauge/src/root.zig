//! Gauge: Unicode text measurement for terminal display.
//! Unicode 16.0 | Zig 0.14 | Zero dependencies.

const tables = @import("tables.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

const testing = @import("std").testing;

test "EAW table: CJK Unified Ideograph is wide" {
    // U+4E00 '一' — CJK Unified Ideographs block
    try testing.expect(inEawTable(0x4E00, .wide));
}

test "EAW table: fullwidth exclamation mark is fullwidth" {
    // U+FF01 '！'
    try testing.expect(inEawTable(0xFF01, .fullwidth));
}

test "EAW table: ASCII 'A' is not in wide/fullwidth table" {
    try testing.expect(!inEawTable(0x0041, .wide));
    try testing.expect(!inEawTable(0x0041, .fullwidth));
}

test "EAW table: Hangul syllable is wide" {
    // U+AC00 '가'
    try testing.expect(inEawTable(0xAC00, .wide));
}

fn inEawTable(cp: u21, expected_width: tables.east_asian_width.Width) bool {
    for (tables.east_asian_width.table) |range| {
        if (cp >= range.first and cp <= range.last) {
            return range.width == expected_width;
        }
    }
    return false;
}

fn inZeroWidthTable(cp: u21) bool {
    for (tables.zero_width.table) |range| {
        if (cp >= range.first and cp <= range.last) return true;
        if (cp < range.first) return false;
    }
    return false;
}

test "zero-width table: combining grave accent" {
    // U+0300 COMBINING GRAVE ACCENT
    try testing.expect(inZeroWidthTable(0x0300));
}

test "zero-width table: ZWJ" {
    // U+200D ZERO WIDTH JOINER
    try testing.expect(inZeroWidthTable(0x200D));
}

test "zero-width table: variation selector VS-16" {
    // U+FE0F VARIATION SELECTOR-16
    try testing.expect(inZeroWidthTable(0xFE0F));
}

test "zero-width table: ASCII 'A' is not zero-width" {
    try testing.expect(!inZeroWidthTable(0x0041));
}

test "zero-width table: soft hyphen" {
    // U+00AD SOFT HYPHEN
    try testing.expect(inZeroWidthTable(0x00AD));
}

test "zero-width table: BOM" {
    // U+FEFF BYTE ORDER MARK / ZWNBSP
    try testing.expect(inZeroWidthTable(0xFEFF));
}
