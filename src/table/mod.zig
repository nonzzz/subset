// https://learn.microsoft.com/en-us/typography/opentype/spec/otff#data-types

pub const Head = @import("./head.zig");
pub const Hhea = @import("./hhea.zig");
pub const Maxp = @import("./maxp.zig");
pub const Os2 = @import("./os2.zig");
pub const Post = @import("./post.zig");
pub const Name = @import("./name.zig");
pub const Cmap = @import("./cmap.zig");
pub const Hmtx = @import("./hmtx.zig");
pub const Loca = @import("./loca.zig");

test {
    _ = Head;
    _ = Hhea;
    _ = Maxp;
    _ = Os2;
    _ = Post;
    _ = Name;
    _ = Cmap;
    _ = Hmtx;
    _ = Loca;
}
