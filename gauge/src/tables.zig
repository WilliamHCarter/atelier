pub const east_asian_width = @import("tables/east_asian_width.zig");
pub const zero_width = @import("tables/zero_width.zig");
pub const grapheme_break = @import("tables/grapheme_break.zig");
pub const incb = @import("tables/incb.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
