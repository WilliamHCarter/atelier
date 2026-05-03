//! Gauge: Unicode text measurement for terminal display.
//! Unicode 16.0 | Zig 0.14 | Zero dependencies.

const tables = @import("tables.zig");
pub const codepointWidth = @import("width.zig").codepointWidth;

test {
    @import("std").testing.refAllDecls(@This());
}
