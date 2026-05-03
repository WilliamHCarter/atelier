//! Gauge: Unicode text measurement for terminal display.
//! Unicode 16.0 | Zig 0.14 | Zero dependencies.

pub const codepointWidth = @import("width.zig").codepointWidth;
pub const width = @import("width.zig").width;

test {
    @import("std").testing.refAllDecls(@This());
}
