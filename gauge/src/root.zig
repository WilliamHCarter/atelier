//! Gauge: Unicode text measurement for terminal display.
//! Unicode 16.0 | Zig 0.14 | Zero dependencies.

pub const codepointWidth = @import("width.zig").codepointWidth;
pub const width = @import("width.zig").width;
pub const stripAnsi = @import("ansi.zig").stripAnsi;
pub const stripAnsiIntoBuf = @import("ansi.zig").stripAnsiIntoBuf;

test {
    @import("std").testing.refAllDecls(@This());
}
