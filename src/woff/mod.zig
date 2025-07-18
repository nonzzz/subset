pub const woff_v1 = @import("./woff_v1.zig");
// pub const woff_v2 = @import("./woff_v2.zig");
pub const woff_impl = @import("./impl.zig");

test {
    _ = woff_v1;
    // _ = woff_v2;
}
