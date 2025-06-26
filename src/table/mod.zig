// https://learn.microsoft.com/en-us/typography/opentype/spec/otff#data-types

pub const head = @import("./head.zig");
pub const hhea = @import("./hhea.zig");
pub const maxp = @import("./maxp.zig");
pub const os2 = @import("./os2.zig");

test {
    _ = head;
    _ = hhea;
    _ = maxp;
    _ = os2;
}
