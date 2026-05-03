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
