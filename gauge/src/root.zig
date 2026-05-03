//! Gauge: Unicode text measurement for terminal display.
//! Unicode 16.0 | Zig 0.14 | Zero dependencies.

pub const codepointWidth = @import("width.zig").codepointWidth;
pub const width = @import("width.zig").width;
pub const stripAnsi = @import("ansi.zig").stripAnsi;
pub const stripAnsiIntoBuf = @import("ansi.zig").stripAnsiIntoBuf;
pub const Grapheme = @import("grapheme.zig").Grapheme;
pub const GraphemeIterator = @import("grapheme.zig").GraphemeIterator;
pub const graphemes = @import("grapheme.zig").graphemes;
pub const step = @import("grapheme.zig").step;
pub const height = @import("text.zig").height;
pub const truncateIntoBuf = @import("text.zig").truncateIntoBuf;
pub const wrap = @import("text.zig").wrap;
pub const WrappedLine = @import("text.zig").WrappedLine;

test {
    @import("std").testing.refAllDecls(@This());
}
