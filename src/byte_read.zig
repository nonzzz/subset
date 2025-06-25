const std = @import("std");
const builtin = @import("builtin");

// https://learn.microsoft.com/en-us/typography/opentype/spec/otff#data-types

pub const ByteReaderError = error{
    BufferTooSmall,
    InvalidOffset,
};

pub const ByteReader = struct {
    const Self = @This();
    buffer: []const u8,
    offset: usize = 0,
    pub fn init(buffer: []const u8) Self {
        return Self{
            .buffer = buffer,
        };
    }
    pub fn seek_to(self: *Self, offset: usize) ByteReaderError!void {
        if (offset >= self.buffer.len) {
            return ByteReaderError.InvalidOffset;
        }
        self.offset = offset;
    }

    pub fn skip(self: *Self, bytes: usize) ByteReaderError!void {
        if (self.offset + bytes > self.buffer.len) {
            return ByteReaderError.BufferTooSmall;
        }
        self.offset += bytes;
    }

    pub fn read_i8(self: *Self) ByteReaderError!i8 {
        const value = try self.read_u8();
        return @bitCast(value);
    }

    pub fn read_u8(self: *Self) ByteReaderError!u8 {
        if (self.offset + 1 > self.buffer.len) {
            return ByteReaderError.BufferTooSmall;
        }
        const value = self.buffer[self.offset];
        self.offset += 1;
        return value;
    }

    pub fn read_u16_be(self: *Self) ByteReaderError!u16 {
        if (self.offset + 2 > self.buffer.len) {
            return ByteReaderError.BufferTooSmall;
        }
        const bytes = self.buffer[self.offset .. self.offset + 2];
        self.offset += 2;
        return std.mem.readInt(u16, bytes[0..2], .big);
    }

    pub fn read_u32_be(self: *Self) ByteReaderError!u32 {
        if (self.offset + 4 > self.buffer.len) {
            return ByteReaderError.BufferTooSmall;
        }
        const bytes = self.buffer[self.offset .. self.offset + 4];
        self.offset += 4;
        return std.mem.readInt(u32, bytes[0..4], .big);
    }

    pub fn read_i16_be(self: *Self) ByteReaderError!i16 {
        const value = try self.read_u16_be();
        return @bitCast(value);
    }

    pub fn read_i32_be(self: *Self) ByteReaderError!i32 {
        const value = try self.read_u32_be();
        return @bitCast(value);
    }

    pub fn read_i64_be(self: *Self) ByteReaderError!i64 {
        if (self.offset + 8 > self.buffer.len) {
            return ByteReaderError.BufferTooSmall;
        }
        const bytes = self.buffer[self.offset .. self.offset + 8];
        self.offset += 8;
        return std.mem.readInt(i64, bytes[0..8], .big);
    }

    pub fn read_bytes(self: *Self, len: usize) ByteReaderError![]const u8 {
        if (self.offset + len > self.buffer.len) {
            return ByteReaderError.BufferTooSmall;
        }
        const bytes = self.buffer[self.offset .. self.offset + len];
        self.offset += len;
        return bytes;
    }

    pub fn read_tag(self: *Self) ByteReaderError![4]u8 {
        const bytes = try self.read_bytes(4);
        return bytes[0..4].*;
    }

    pub fn remaining(self: Self) usize {
        return self.buffer.len - self.offset;
    }

    pub fn current_offset(self: Self) usize {
        return self.offset;
    }
};

const TEST_DATA = if (builtin.is_test) [_]u8{
    0x00, 0x01, 0x02, 0x03,
    0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0A, 0x0B,
    0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x12, 0x13,
    0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1A, 0x1B,
    0x1C, 0x1D, 0x1E, 0x1F,
} else [_]u8{};

test "ByteReader - basic integer reads" {
    var reader = ByteReader.init(&TEST_DATA);

    try std.testing.expectEqual(@as(u8, 0x00), try reader.read_u8());
    try std.testing.expectEqual(@as(u16, 0x0102), try reader.read_u16_be());
    try std.testing.expectEqual(@as(u32, 0x03040506), try reader.read_u32_be());

    try reader.seek_to(0);
    _ = try reader.read_u8();

    try std.testing.expectEqual(@as(i16, 0x0102), try reader.read_i16_be());
    try std.testing.expectEqual(@as(i32, 0x03040506), try reader.read_i32_be());

    try reader.seek_to(0);
    try std.testing.expectEqual(@as(i64, 0x0001020304050607), try reader.read_i64_be());
}

test "ByteReader - bytes and tag reads" {
    var reader = ByteReader.init(&TEST_DATA);

    try reader.skip(8);

    const bytes = try reader.read_bytes(3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x09, 0x0A }, bytes);

    const tag = try reader.read_tag();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0B, 0x0C, 0x0D, 0x0E }, &tag);
}

test "ByteReader - navigation and positioning" {
    var reader = ByteReader.init(&TEST_DATA);

    try std.testing.expectEqual(@as(usize, 0), reader.current_offset());
    try std.testing.expectEqual(@as(usize, TEST_DATA.len), reader.remaining());

    try reader.skip(4);
    try std.testing.expectEqual(@as(usize, 4), reader.current_offset());
    try std.testing.expectEqual(@as(usize, TEST_DATA.len - 4), reader.remaining());

    try reader.seek_to(2);
    try std.testing.expectEqual(@as(usize, 2), reader.current_offset());
    try std.testing.expectEqual(@as(usize, TEST_DATA.len - 2), reader.remaining());

    try reader.skip(2);
    try std.testing.expectEqual(@as(usize, 4), reader.current_offset());
    try std.testing.expectEqual(@as(usize, TEST_DATA.len - 4), reader.remaining());

    try reader.seek_to(0);
    try std.testing.expectEqual(@as(usize, 0), reader.current_offset());
    try std.testing.expectEqual(@as(usize, TEST_DATA.len), reader.remaining());

    try reader.skip(TEST_DATA.len);
    try std.testing.expectEqual(@as(usize, TEST_DATA.len), reader.current_offset());
    try std.testing.expectEqual(@as(usize, 0), reader.remaining());
}

test "ByteReader - error conditions" {
    var reader = ByteReader.init(TEST_DATA[0..4]);
    try reader.skip(3);
    try std.testing.expectError(ByteReaderError.BufferTooSmall, reader.read_u16_be());

    try std.testing.expectError(ByteReaderError.InvalidOffset, reader.seek_to(10));
}

test "ByteReader - sequential mixed reads" {
    var reader = ByteReader.init(&TEST_DATA);

    const version = try reader.read_u32_be();
    try std.testing.expectEqual(@as(u32, 0x00010203), version);

    const num_tables = try reader.read_u16_be();
    try std.testing.expectEqual(@as(u16, 0x0405), num_tables);

    const search_range = try reader.read_u16_be();
    try std.testing.expectEqual(@as(u16, 0x0607), search_range);

    try reader.skip(2);

    const table_tag = try reader.read_tag();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x0B, 0x0C, 0x0D }, &table_tag);

    try std.testing.expectEqual(@as(usize, 14), reader.current_offset());
}
