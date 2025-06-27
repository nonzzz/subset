// https://learn.microsoft.com/en-us/typography/opentype/spec/otff#data-types

pub const head = @import("./head.zig");
pub const hhea = @import("./hhea.zig");
pub const maxp = @import("./maxp.zig");
pub const os2 = @import("./os2.zig");
pub const post = @import("./post.zig");
pub const name = @import("./name.zig");
const cmap = @import("./cmap.zig");
const hmtx = @import("./hmtx.zig");

test {
    _ = head;
    _ = hhea;
    _ = maxp;
    _ = os2;
    _ = post;
    _ = name;
    _ = cmap;
    _ = hmtx;
}
