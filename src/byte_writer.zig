const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Endianness = enum {
    little,
    big,
};

pub fn ByteWriter(comptime BackingType: type) type {
    return struct {
        const Self = @This();

        buffer: ArrayList(BackingType),

        pub fn init(allocator: Allocator) Self {
            return Self{
                .buffer = ArrayList(BackingType).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn write(self: *Self, comptime T: type, value: T, endianness: Endianness) !void {
            const bytes = switch (endianness) {
                .little => std.mem.asBytes(&std.mem.nativeToLittle(T, value)),
                .big => std.mem.asBytes(&std.mem.nativeToBig(T, value)),
            };

            for (bytes.*) |byte| {
                try self.buffer.append(@intCast(byte));
            }
        }

        pub fn write_u8(self: *Self, value: u8) !void {
            try self.buffer.append(@intCast(value));
        }

        pub fn write_u16(self: *Self, value: u16, endianness: Endianness) !void {
            try self.write(u16, value, endianness);
        }

        pub fn write_u32(self: *Self, value: u32, endianness: Endianness) !void {
            try self.write(u32, value, endianness);
        }

        pub fn write_u64(self: *Self, value: u64, endianness: Endianness) !void {
            try self.write(u64, value, endianness);
        }

        pub fn write_i8(self: *Self, value: i8) !void {
            try self.buffer.append(@bitCast(value));
        }

        pub fn write_i16(self: *Self, value: i16, endianness: Endianness) !void {
            try self.write(i16, value, endianness);
        }

        pub fn write_i32(self: *Self, value: i32, endianness: Endianness) !void {
            try self.write(i32, value, endianness);
        }

        pub fn write_i64(self: *Self, value: i64, endianness: Endianness) !void {
            try self.write(i64, value, endianness);
        }

        pub fn write_bytes(self: *Self, bytes: []const u8) !void {
            for (bytes) |byte| {
                try self.buffer.append(@intCast(byte));
            }
        }

        pub fn to_slice(self: *const Self) []const BackingType {
            return self.buffer.items;
        }

        pub fn to_owned_slice(self: *Self) ![]BackingType {
            return self.buffer.toOwnedSlice();
        }

        pub fn clear(self: *Self) void {
            self.buffer.clearRetainingCapacity();
        }

        pub fn len(self: *const Self) usize {
            return self.buffer.items.len;
        }
    };
}

test "ByteWriter basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var writer = ByteWriter(u8).init(allocator);
    defer writer.deinit();

    try writer.write_u8(0x42);
    try writer.write_u16(0x1234, .little);
    try writer.write_u32(0xDEADBEEF, .big);
    try writer.write_i16(-1000, .little);

    const result = writer.to_slice();

    try testing.expect(result.len > 0);
    try testing.expect(result[0] == 0x42);
}

test "ByteWriter with different backing types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var writer32 = ByteWriter(u32).init(allocator);
    defer writer32.deinit();

    try writer32.write(u16, 0x1234, .little);
    try testing.expect(writer32.len() == 2);
}
