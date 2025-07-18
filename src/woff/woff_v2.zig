const brotli = @import("brotli");
const std = @import("std");
const reader = @import("../byte_read.zig");
const mod = @import("../parser.zig");
const Head = @import("../table/head.zig");
const byte_writer = @import("../byte_writer.zig");
const Impl = @import("./impl.zig");

const Allocator = std.mem.Allocator;

const Parser = mod.Parser;
const ByteWriter = byte_writer.ByteWriter;

// https://www.w3.org/TR/WOFF2/
pub const Woff = struct {
    const Self = @This();

    allocator: Allocator,
    parser: *Parser,
    compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,

    pub fn init(
        allocator: Allocator,
        parser: *Parser,
        compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,
    ) Impl {
        const self = allocator.create(Self) catch unreachable;
        self.* = Self{
            .allocator = allocator,
            .parser = parser,
            .compressor = compressor,
        };
        return Impl{
            .ptr = self,
            .vtable = &.{
                .as_woff = as_woff,
            },
        };
    }

    fn as_woff(ptr: *anyopaque) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        defer self.allocator.destroy(self);
        var buffer = ByteWriter(u8).init(self.allocator);
        try buffer.write(u8, 1, .big);

        return buffer.to_owned_slice();
    }
};

pub fn ttf_to_woff_v2(allocator: Allocator, data: []u8, compressor: Impl.Compressor) ![]u8 {
    var parser = try Parser.init(allocator, data);
    defer parser.deinit();
    try parser.parse();
    var woff = Woff.init(allocator, &parser, compressor);
    return woff.as_woff();
}

pub fn ttf_woff_v2_with_parser(allocator: Allocator, parser: *Parser, compressor: Impl.Compressor) ![]u8 {
    var woff = Woff.init(allocator, parser, compressor);
    return woff.as_woff();
}

// brotli mock
fn mock_compressor(allocator: Allocator, data: []const u8) anyerror![]u8 {
    var encoder = try brotli.Encoder.init(allocator, .{});
    defer encoder.deinit();
    const compressed = try encoder.encode(data);
    return compressed;
}
