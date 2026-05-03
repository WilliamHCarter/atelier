pub const east_asian_width = @import("tables/east_asian_width.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
