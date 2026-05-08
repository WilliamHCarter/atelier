const std = @import("std");
const tables = @import("tables.zig");
const width_mod = @import("width.zig");

const Property = tables.grapheme_break.Property;

/// A single grapheme cluster — the smallest unit of text that a user perceives
/// as a single character. May span multiple Unicode codepoints.
pub const Grapheme = struct {
    /// Slice into the original string. No allocation; valid for the lifetime of the source.
    bytes: []const u8,
    /// Display width in terminal columns (0, 1, or 2).
    width: u8,
};

const StepResult = struct {
    grapheme: Grapheme,
    /// The remaining input after this grapheme cluster.
    rest: []const u8,
};

/// Returns the next grapheme cluster from bytes, or null if bytes is empty.
///
/// Implements UAX #29 §3 grapheme cluster boundary rules (Unicode 16.0).
/// Width is computed in a single pass alongside boundary detection.
/// Zero allocation — bytes and rest are slices into the caller's data.
pub fn step(bytes: []const u8) ?StepResult {
    std.debug.assert(bytes.len <= std.math.maxInt(u32));
    if (bytes.len == 0) return null;

    var i: u32 = 0;

    // Decode the first codepoint. Invalid UTF-8 → single-byte cluster, width 0.
    const first = decodeAt(bytes, i) orelse {
        return .{ .grapheme = .{ .bytes = bytes[0..1], .width = 0 }, .rest = bytes[1..] };
    };
    i += first.len;

    const first_prop = breakProperty(first.codepoint);
    var cluster_width: u8 = width_mod.codepointWidth(first.codepoint);
    // Regional Indicators (U+1F1E6-U+1F1FF) are Neutral in EastAsianWidth.txt but
    // display as 2-column emoji characters (flag halves or regional indicator letters).
    // Override here since correct width requires grapheme-level context (this file).
    if (first_prop == .regional_indicator) cluster_width = 2;

    // GB3: CR × LF — treat CRLF as a single cluster.
    if (first_prop == .cr) {
        if (i < bytes.len) {
            if (decodeAt(bytes, i)) |next| {
                if (breakProperty(next.codepoint) == .lf) i += next.len;
            }
        }
        return .{ .grapheme = .{ .bytes = bytes[0..i], .width = 0 }, .rest = bytes[i..] };
    }

    // GB4 (partial): Control and LF are always single-codepoint clusters.
    if (first_prop == .control or first_prop == .lf) {
        return .{ .grapheme = .{ .bytes = bytes[0..i], .width = 0 }, .rest = bytes[i..] };
    }

    // Extension loop: absorb codepoints that belong to this cluster per UAX #29.
    var prev_prop = first_prop;
    var is_ext_pic: bool = (first_prop == .extended_pictographic);
    var ext_pic_zwj: bool = false; // seen ZWJ in Extended_Pictographic context (GB11)
    var ri_count: u8 = if (first_prop == .regional_indicator) 1 else 0;
    var found_nonzero_width: bool = cluster_width > 0;
    // GB9c (Unicode 15.1+): Indic Conjunct Break state.
    // Track whether the cluster started with (or last joined via) an InCB=Consonant,
    // and whether at least one InCB=Linker (VIRAMA) has been seen since then.
    var incb_last_consonant: bool = incbIsConsonant(first.codepoint);
    var incb_has_linker: bool = false;

    while (i < bytes.len) {
        const next = decodeAt(bytes, i) orelse break; // invalid UTF-8 → end cluster
        const next_prop = breakProperty(next.codepoint);

        // GB9c: override the break decision for an InCB=Consonant when the cluster
        // has already seen Consonant + at least one Linker (VIRAMA).
        const next_is_consonant = incbIsConsonant(next.codepoint);
        const gb9c_no_break = next_is_consonant and incb_last_consonant and incb_has_linker;

        if (!gb9c_no_break and shouldBreak(prev_prop, next_prop, ext_pic_zwj, ri_count)) break;

        i += next.len;

        // Update cluster width: use the first non-zero-width codepoint's width.
        // VS-16 (U+FE0F) after a narrow Extended_Pictographic triggers emoji presentation (width 2).
        const next_width = width_mod.codepointWidth(next.codepoint);
        if (!found_nonzero_width and next_width > 0) {
            cluster_width = next_width;
            found_nonzero_width = true;
        }
        if (next.codepoint == 0xFE0F and is_ext_pic and cluster_width < 2) {
            // Variation Selector-16 makes a narrow Extended_Pictographic display as wide.
            cluster_width = 2;
        }

        // Advance extension state.
        switch (next_prop) {
            .zwj => if (is_ext_pic) {
                ext_pic_zwj = true;
            },
            .extended_pictographic => {
                // Only reachable here via GB11 (ext_pic_zwj was true).
                ext_pic_zwj = false;
                is_ext_pic = true;
            },
            .regional_indicator => {
                ri_count +|= 1; // saturating; cap at 255, more than enough
            },
            .extend, .spacing_mark => {
                // GB9 / GB9a: absorbed without changing ExtPic or RI context.
            },
            else => {
                is_ext_pic = false;
                ext_pic_zwj = false;
            },
        }

        // Advance GB9c InCB state.
        if (next_is_consonant) {
            // This Consonant joined via GB9c. It becomes the new chain base;
            // reset linker flag so the next Consonant must see another Linker.
            incb_last_consonant = true;
            incb_has_linker = false;
        } else if (incbIsLinker(next.codepoint)) {
            // A Linker (VIRAMA) enables GB9c for the next InCB=Consonant.
            incb_has_linker = true;
        } else if (next_prop != .extend and next_prop != .zwj and next_prop != .spacing_mark) {
            // Any non-extend character that is not InCB-tagged breaks the InCB chain.
            incb_last_consonant = false;
            incb_has_linker = false;
        }

        prev_prop = next_prop;
    }

    std.debug.assert(i > 0); // postcondition: always advances at least one byte
    std.debug.assert(i <= bytes.len); // postcondition: never overruns input
    return .{ .grapheme = .{ .bytes = bytes[0..i], .width = cluster_width }, .rest = bytes[i..] };
}

/// Iterator over grapheme clusters. Zero allocation; yields slices into the source string.
pub const GraphemeIterator = struct {
    bytes: []const u8,

    pub fn next(self: *GraphemeIterator) ?Grapheme {
        const result = step(self.bytes) orelse return null;
        self.bytes = result.rest;
        return result.grapheme;
    }
};

/// Returns an iterator over the grapheme clusters in bytes.
pub fn graphemes(bytes: []const u8) GraphemeIterator {
    return .{ .bytes = bytes };
}

// ---------------------------------------------------------------------------
// Break rules (UAX #29 §3, Unicode 16.0)
// ---------------------------------------------------------------------------

/// Returns true if there is a grapheme cluster boundary between prev and next.
/// Called from the extension loop — GB1/GB2 (sot/eot) are handled outside.
fn shouldBreak(
    prev: Property,
    next: Property,
    ext_pic_zwj: bool,
    ri_count: u8,
) bool {
    std.debug.assert(ri_count <= 255); // precondition: saturating counter is bounded

    // GB4: (Control | CR | LF) ÷ — already handled at start, but guard here too.
    if (prev == .control or prev == .cr or prev == .lf) return true;

    // GB5: ÷ (Control | CR | LF)
    if (next == .control or next == .cr or next == .lf) return true;

    // GB6: L × (L | V | LV | LVT)
    if (prev == .l and (next == .l or next == .v or next == .lv or next == .lvt)) return false;

    // GB7: (LV | V) × (V | T)
    if ((prev == .lv or prev == .v) and (next == .v or next == .t)) return false;

    // GB8: (LVT | T) × T
    if ((prev == .lvt or prev == .t) and next == .t) return false;

    // GB9: × (Extend | ZWJ)
    if (next == .extend or next == .zwj) return false;

    // GB9a: × SpacingMark
    if (next == .spacing_mark) return false;

    // GB9b: Prepend ×
    if (prev == .prepend) return false;

    // GB11: \p{Extended_Pictographic} Extend* ZWJ × \p{Extended_Pictographic}
    if (ext_pic_zwj and next == .extended_pictographic) return false;

    // GB12/13: (sot | [^RI]) (RI RI)* RI × RI
    // We always take one pair per cluster; break if ri_count is already even (pair complete).
    if (prev == .regional_indicator and next == .regional_indicator and ri_count % 2 == 1) return false;

    // GB999: otherwise break
    return true;
}

// ---------------------------------------------------------------------------
// Unicode property lookup
// ---------------------------------------------------------------------------

/// Returns true if codepoint has InCB=Consonant (Indic Conjunct Break consonant).
/// These are Consonants in Conjunct-Linking scripts; unlisted codepoints return false.
fn incbIsConsonant(codepoint: u21) bool {
    std.debug.assert(codepoint <= 0x10FFFF); // precondition: valid Unicode scalar value
    const table = tables.incb.consonant_table;
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
    return false; // postcondition: unlisted codepoints are not InCB=Consonant
}

/// Returns true if codepoint has InCB=Linker (VIRAMA-like character in a Conjunct-Linking script).
/// These are a subset of Extend; a Linker in the cluster enables GB9c for the next Consonant.
fn incbIsLinker(codepoint: u21) bool {
    std.debug.assert(codepoint <= 0x10FFFF); // precondition: valid Unicode scalar value
    const table = tables.incb.linker_table;
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
    return false; // postcondition: unlisted codepoints are not InCB=Linker
}

/// Binary-searches the grapheme break property table and returns the property
/// for codepoint, or .any if the codepoint is not listed.
fn breakProperty(codepoint: u21) Property {
    std.debug.assert(codepoint <= 0x10FFFF); // precondition: valid Unicode scalar value
    const table = tables.grapheme_break.table;
    var lo: u32 = 0;
    var hi: u32 = @intCast(table.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (codepoint < table[mid].first) {
            hi = mid;
        } else if (codepoint > table[mid].last) {
            lo = mid + 1;
        } else {
            return table[mid].property;
        }
    }
    return .any; // postcondition: unlisted codepoints are .any (Other)
}

// ---------------------------------------------------------------------------
// UTF-8 decode helper
// ---------------------------------------------------------------------------

const DecodeResult = struct { codepoint: u21, len: u8 };

fn decodeAt(bytes: []const u8, i: u32) ?DecodeResult {
    std.debug.assert(i <= bytes.len); // precondition: i is a valid offset
    if (i >= bytes.len) return null;
    const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return null;
    const end = i + seq_len;
    if (end > bytes.len) return null;
    const cp = std.unicode.utf8Decode(bytes[i..end]) catch return null;
    std.debug.assert(seq_len >= 1 and seq_len <= 4); // postcondition: valid UTF-8 length
    return .{ .codepoint = cp, .len = seq_len };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "graphemes: ASCII — each character is its own cluster" {
    var iter = graphemes("Hi!");
    const h = iter.next().?;
    try testing.expectEqualStrings("H", h.bytes);
    try testing.expectEqual(@as(u8, 1), h.width);
    const i = iter.next().?;
    try testing.expectEqualStrings("i", i.bytes);
    _ = iter.next().?; // '!'
    try testing.expect(iter.next() == null);
}

test "graphemes: combining mark stays with base character" {
    // 'A' + COMBINING GRAVE ACCENT (U+0300) = one cluster, width 1
    var iter = graphemes("A\xcc\x80");
    const g = iter.next().?;
    try testing.expectEqualStrings("A\xcc\x80", g.bytes);
    try testing.expectEqual(@as(u8, 1), g.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: CJK character is one cluster, width 2" {
    var iter = graphemes("你好");
    const ni = iter.next().?;
    try testing.expectEqual(@as(u8, 2), ni.width);
    const hao = iter.next().?;
    try testing.expectEqual(@as(u8, 2), hao.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: CRLF is one cluster" {
    var iter = graphemes("\r\n");
    const crlf = iter.next().?;
    try testing.expectEqualStrings("\r\n", crlf.bytes);
    try testing.expectEqual(@as(u8, 0), crlf.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: emoji ZWJ sequence is one cluster, width 2" {
    // 👨‍👩‍👧 = Man ZWJ Woman ZWJ Girl
    const family = "👨‍👩‍👧";
    var iter = graphemes(family);
    const g = iter.next().?;
    try testing.expectEqualStrings(family, g.bytes);
    try testing.expectEqual(@as(u8, 2), g.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: flag emoji (regional indicator pair) is one cluster" {
    // 🇺🇸 = RI(U) RI(S)
    const flag = "🇺🇸";
    var iter = graphemes(flag);
    const g = iter.next().?;
    try testing.expectEqualStrings(flag, g.bytes);
    try testing.expectEqual(@as(u8, 2), g.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: two flags are two clusters" {
    var iter = graphemes("🇺🇸🇫🇷");
    const us = iter.next().?;
    try testing.expectEqual(@as(u8, 2), us.width);
    const fr = iter.next().?;
    try testing.expectEqual(@as(u8, 2), fr.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: Hangul jamo sequence is one cluster" {
    // ᄀ (L) + ᅡ (V) + ᆷ (T)
    var iter = graphemes("\xe1\x84\x80\xe1\x85\xa1\xe1\x86\xb7");
    const g = iter.next().?;
    try testing.expectEqual(@as(usize, 9), g.bytes.len); // 3 × 3-byte sequences
    try testing.expectEqual(@as(u8, 2), g.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: skin tone modifier stays with base emoji" {
    // 👋🏽 = WAVING HAND (U+1F44B) + MEDIUM SKIN TONE (U+1F3FD)
    const wave = "👋🏽";
    var iter = graphemes(wave);
    const g = iter.next().?;
    try testing.expectEqualStrings(wave, g.bytes);
    try testing.expectEqual(@as(u8, 2), g.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: VS-16 makes narrow pictographic wide" {
    // ❤ (U+2764, narrow) + VS-16 (U+FE0F) → width 2
    const heart = "❤️";
    var iter = graphemes(heart);
    const g = iter.next().?;
    try testing.expectEqualStrings(heart, g.bytes);
    try testing.expectEqual(@as(u8, 2), g.width);
    try testing.expect(iter.next() == null);
}

test "graphemes: empty string" {
    var iter = graphemes("");
    try testing.expect(iter.next() == null);
}

// ---------------------------------------------------------------------------
// Unicode conformance tests — GraphemeBreakTest.txt (Unicode 16.0)
// ---------------------------------------------------------------------------
//
// Each line encodes a string as: ÷ CP1 [÷|×] CP2 [÷|×] ... ÷
// ÷ = cluster boundary, × = no boundary (within cluster).
// We encode the codepoints as UTF-8, run graphemes(), then verify that
// each cluster's byte span exactly matches one ÷-delimited group.

test "conformance: GraphemeBreakTest.txt (Unicode 16.0)" {
    const test_data = @embedFile("data/GraphemeBreakTest.txt");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var line_iter = std.mem.splitScalar(u8, test_data, '\n');
    var line_num: u32 = 0;
    var pass: u32 = 0;
    var fail: u32 = 0;

    while (line_iter.next()) |line| {
        line_num += 1;
        const trimmed = std.mem.trimRight(u8, line, &[_]u8{ '\r', ' ' });
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Strip trailing comment
        const data_part = if (std.mem.indexOf(u8, trimmed, "#")) |idx|
            std.mem.trimRight(u8, trimmed[0..idx], &[_]u8{ '\t', ' ' })
        else
            trimmed;

        // Parse: ÷ CP ÷|× CP ÷|× ... ÷
        // Tokens are separated by whitespace; symbols are ÷ (U+00F7, 2 bytes: 0xC3 0xB7)
        // and × (U+00D7, 2 bytes: 0xC3 0x97).
        var codepoints = std.ArrayList(u21).init(allocator);
        var cluster_ends = std.ArrayList(u32).init(allocator); // codepoint indices where clusters end
        defer codepoints.deinit();
        defer cluster_ends.deinit();

        var tok_iter = std.mem.tokenizeAny(u8, data_part, " \t");

        while (tok_iter.next()) |tok| {
            if (std.mem.eql(u8, tok, "\xc3\xb7")) { // ÷ — cluster boundary
                if (codepoints.items.len > 0) {
                    try cluster_ends.append(@intCast(codepoints.items.len));
                }
            } else if (std.mem.eql(u8, tok, "\xc3\x97")) { // × — no boundary
                // nothing to record; absence of cluster_ends entry means no break
            } else {
                // Hex codepoint
                const cp = std.fmt.parseInt(u21, tok, 16) catch continue;
                try codepoints.append(cp);
            }
        }
        if (cluster_ends.items.len == 0 or
            cluster_ends.items[cluster_ends.items.len - 1] != codepoints.items.len)
        {
            try cluster_ends.append(@intCast(codepoints.items.len));
        }

        if (codepoints.items.len == 0) continue;

        // Encode codepoints to UTF-8
        var utf8_buf = std.ArrayList(u8).init(allocator);
        defer utf8_buf.deinit();
        // Map codepoint index → byte offset
        var cp_byte_offsets = std.ArrayList(u32).init(allocator);
        defer cp_byte_offsets.deinit();

        for (codepoints.items) |cp| {
            try cp_byte_offsets.append(@intCast(utf8_buf.items.len));
            var seq: [4]u8 = undefined;
            const seq_len = std.unicode.utf8Encode(cp, &seq) catch continue;
            try utf8_buf.appendSlice(seq[0..seq_len]);
        }
        try cp_byte_offsets.append(@intCast(utf8_buf.items.len)); // sentinel

        // Run grapheme iterator and check cluster boundaries
        var g_iter = graphemes(utf8_buf.items);
        var cluster_idx: u32 = 0;
        var byte_pos: u32 = 0;
        var ok = true;

        while (g_iter.next()) |g| {
            if (cluster_idx >= cluster_ends.items.len) {
                ok = false;
                break;
            }
            const expected_end_cp = cluster_ends.items[cluster_idx];
            const expected_end_byte = cp_byte_offsets.items[expected_end_cp];
            const actual_end_byte = byte_pos + @as(u32, @intCast(g.bytes.len));
            if (actual_end_byte != expected_end_byte) {
                ok = false;
                break;
            }
            byte_pos = actual_end_byte;
            cluster_idx += 1;
        }
        if (cluster_idx != cluster_ends.items.len) ok = false;

        if (ok) {
            pass += 1;
        } else {
            fail += 1;
            std.debug.print("FAIL line {d}: {s}\n", .{ line_num, data_part });
        }
    }

    if (fail > 0) {
        std.debug.print("Conformance: {d} passed, {d} failed\n", .{ pass, fail });
    }
    try testing.expectEqual(@as(u32, 0), fail);
}
