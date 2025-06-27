const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");

const Allocator = std.mem.Allocator;

pub const NameTable = struct {
    const Self = @This();

    allocator: Allocator,
    byte_reader: *reader.ByteReader,

    version: u16,
    count: u16,
    storage_offset: u16,

    name_records: []NameRecord,

    pub const NameRecord = struct {
        platform_id: u16,
        encoding_id: u16,
        language_id: u16,
        name_id: u16,
        length: u16,
        string_offset: u16,
    };

    pub const LangTagRecord = struct {
        length: u16,
        lang_tag_offset: u16,
    };

    pub const V1 = struct {
        lang_tag_count: u16,
        lang_tag_record: []LangTagRecord,
    };

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader) !Table {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.allocator = allocator;
        self.byte_reader = byte_reader;

        return Table{
            .ptr = self,
            .vtable = &.{ .parse = parse, .deinit = deinit },
        };
    }

    fn parse(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
    }
};

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader) !Table {
    return NameTable.init(allocator, byte_reader);
}
