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

    v1_data: ?V1 = null,

    // string_data: []u8,

    const Error = error{
        InvalidNameTableVersion,
    };

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
        fn deinit(self: *V1, allocator: Allocator) void {
            allocator.free(self.lang_tag_record);
        }
    };

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.v1_data) |*v1| {
            v1.deinit(self.allocator);
        }
        self.allocator.free(self.name_records);
        self.allocator.destroy(self);
    }

    pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader) !Table {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = undefined;
        self.allocator = allocator;
        self.byte_reader = byte_reader;
        self.v1_data = null;

        return Table{
            .ptr = self,
            .vtable = &.{ .parse = parse, .deinit = deinit },
        };
    }

    fn parse(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const version = try self.byte_reader.read_u16_be();
        if (version != 0x0000 and version != 0x0001) {
            return Self.Error.InvalidNameTableVersion;
        }
        self.version = version;
        self.count = try self.byte_reader.read_u16_be();
        self.storage_offset = try self.byte_reader.read_u16_be();

        const name_records = try self.allocator.alloc(NameRecord, self.count);
        errdefer self.allocator.free(name_records);
        for (name_records) |*record| {
            inline for (std.meta.fields(NameRecord)) |field| {
                @field(record, field.name) = try self.byte_reader.read_u16_be();
            }
        }
        self.name_records = name_records;

        if (self.version == 0x0001) {
            self.v1_data = try self.parse_v1();
        }
    }

    fn parse_v1(self: *Self) !V1 {
        const lang_tag_count = try self.byte_reader.read_u16_be();
        const lang_tag_record = try self.allocator.alloc(LangTagRecord, lang_tag_count);
        errdefer self.allocator.free(lang_tag_record);
        for (lang_tag_record) |*record| {
            inline for (std.meta.fields(LangTagRecord)) |field| {
                @field(record, field.name) = try self.byte_reader.read_u16_be();
            }
        }
        return V1{
            .lang_tag_count = lang_tag_count,
            .lang_tag_record = lang_tag_record,
        };
    }
};

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader) !Table {
    return NameTable.init(allocator, byte_reader);
}
