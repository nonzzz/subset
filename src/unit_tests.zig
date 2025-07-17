comptime {
    _ = @import("parser.zig");
    _ = @import("byte_read.zig");
    _ = @import("table/mod.zig");
    _ = @import("./lib.zig");
    _ = @import("./byte_writer.zig");
    _ = @import("./woff/woff_v1.zig");
    _ = @import("./woff/woff_v2.zig");
}
