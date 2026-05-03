pub const east_asian_width = @import("tables/east_asian_width.zig");
pub const zero_width = @import("tables/zero_width.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
