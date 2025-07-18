const std = @import("std");

const Allocator = std.mem.Allocator;

const Woff = @This();

ptr: *anyopaque,

vtable: *const VTable,

pub const VTable = struct {
    as_woff: *const fn (*anyopaque) anyerror![]u8,
};

pub fn as_woff(self: Woff) anyerror![]u8 {
    return self.vtable.as_woff(self.ptr);
}

pub fn cast(self: Woff, comptime T: type) *T {
    return @ptrCast(@alignCast(self.ptr));
}

pub const Compressor = *const fn (allocator: Allocator, data: []const u8) anyerror![]u8;

pub const Error = error{
    InvalidSfntVersion,
    CompressionFailed,
};
