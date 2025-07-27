const std = @import("std");

const Allocator = std.mem.Allocator;

const Table = @This();

ptr: *anyopaque,

vtable: *const VTable,

pub const VTable = struct {
    /// Parse table data
    parse: *const fn (*anyopaque) anyerror!void,
    /// Free the table and its resources.
    deinit: *const fn (*anyopaque) void,
};

pub fn parse(self: Table) anyerror!void {
    return self.vtable.parse(self.ptr);
}

pub fn deinit(self: Table) void {
    self.vtable.deinit(self.ptr);
}

/// Type-safe cast to specific table type
pub fn cast(self: Table, comptime T: type) *T {
    return @ptrCast(@alignCast(self.ptr));
}
