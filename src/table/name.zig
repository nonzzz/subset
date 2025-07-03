const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;

// https://learn.microsoft.com/en-us/typography/opentype/spec/name

const Allocator = std.mem.Allocator;

const Self = @This();

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

version: u16,
count: u16,
storage_offset: u16,

name_records: []NameRecord,

v1_data: ?V1 = null,

string_data: []u8,

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
    self.allocator.free(self.string_data);
    self.allocator.destroy(self);
}

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = undefined;
    self.allocator = allocator;
    self.byte_reader = byte_reader;
    self.parsed_tables = parsed_tables;
    self.v1_data = null;

    return Table{
        .ptr = self,
        .vtable = &.{ .parse = parse, .deinit = deinit },
    };
}

fn parse(ptr: *anyopaque) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    const begin_offset = self.byte_reader.current_offset();
    const version = try self.byte_reader.read_u16_be();
    if (version != 0x0000 and version != 0x0001) {
        return error.InvalidNameTableVersion;
    }
    self.version = version;
    self.count = try self.byte_reader.read_u16_be();
    self.storage_offset = try self.byte_reader.read_u16_be();

    const name_records = try self.allocator.alloc(NameRecord, self.count);
    errdefer self.allocator.free(name_records);
    const next_offset = begin_offset + self.storage_offset;
    var sb = std.ArrayList(u8).init(self.allocator);
    errdefer sb.deinit();
    for (name_records, 1..) |*record, start| {
        inline for (std.meta.fields(NameRecord)) |field| {
            @field(record, field.name) = try self.byte_reader.read_u16_be();
        }
        const string_offset = begin_offset + record.string_offset + self.storage_offset;
        const string_length = record.length;
        if (string_length > 0) {
            try self.byte_reader.seek_to(string_offset);
            const str = try self.byte_reader.read_bytes(string_length);

            errdefer self.allocator.free(str);
            try sb.appendSlice(str);
        }
        try self.byte_reader.seek_to(begin_offset + 6 + start * 12);
    }
    self.name_records = name_records;
    try self.byte_reader.seek_to(next_offset);
    if (self.version == 0x0001) {
        self.v1_data = try self.parse_v1();
    }
    self.string_data = try sb.toOwnedSlice();
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
pub fn get_by_name_id(self: *Self, name_id: u16) ?[]const u8 {
    var offset: usize = 0;
    for (self.name_records) |record| {
        if (record.length > 0) {
            if (record.name_id == name_id) {
                return self.string_data[offset .. offset + record.length];
            }
            offset += record.length;
        }
    }
    return null;
}

test "parse name table" {
    const allocator = std.testing.allocator;

    const buffer = &[_]u8{
        0x00, 0x00, // version
        0x00, 0x0A, // count = 10
        0x00, 0x7E, // storage_offset = 126 (6 + 10*12)
        // copyright
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x00,
        0x00, 0x07,
        0x00, 0x00,
        // fontFamily
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x01,
        0x00, 0x08,
        0x00, 0x07,
        // fontSubfamily
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x02,
        0x00, 0x07,
        0x00, 0x0F,
        // fullName
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x04,
        0x00, 0x10,
        0x00, 0x16,
        // license
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x0D,
        0x00, 0x05,
        0x00, 0x26,
        // postScriptName
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x06,
        0x00, 0x0F,
        0x00, 0x2B,
        // preferredFamily
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x10,
        0x00, 0x08,
        0x00, 0x3A,
        // preferredSubfamily
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x11,
        0x00, 0x07,
        0x00, 0x42,
        // uniqueID
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x03,
        0x00, 0x1a,
        0x00, 0x49,
        // version
        0x00, 0x03,
        0x00, 0x01,
        0x04, 0x09,
        0x00, 0x05,
        0x00, 0x0D,
        0x00, 0x63,
        // string storage (offset 0x7E)
        // "Tao Qin"
        0x54, 0x61,
        0x6F, 0x20,
        0x51, 0x69,
        0x6E,
        // "opentype"
        0x6F,
        0x70, 0x65,
        0x6E, 0x74,
        0x79, 0x70,
        0x65,
        // "Regular"
        0x52,
        0x65, 0x67,
        0x75, 0x6C,
        0x61, 0x72,
        // "New Font Regular"
        0x4E, 0x65,
        0x77, 0x20,
        0x46, 0x6F,
        0x6E, 0x74,
        0x20, 0x52,
        0x65, 0x67,
        0x75, 0x6C,
        0x61, 0x72,
        // "Kanno"
        0x4B, 0x61,
        0x6E, 0x6E,
        0x6F,
        // "NewFont-Regular"
        0x4E,
        0x65, 0x77,
        0x46, 0x6F,
        0x6E, 0x74,
        0x2D, 0x52,
        0x65, 0x67,
        0x75, 0x6C,
        0x61, 0x72,
        // "opentype"
        0x6F, 0x70,
        0x65, 0x6E,
        0x74, 0x79,
        0x70, 0x65,
        // "Regular"
        0x52, 0x65,
        0x67, 0x75,
        0x6C, 0x61,
        0x72,
        // "1.000;UKWN;NewFont-Regular"
        0x31,
        0x2E, 0x30,
        0x30, 0x30,
        0x3B, 0x55,
        0x4B, 0x57,
        0x4E, 0x3B,
        0x4E, 0x65,
        0x77, 0x46,
        0x6F, 0x6E,
        0x74, 0x2D,
        0x52, 0x65,
        0x67, 0x75,
        0x6C, 0x61,
        0x72,
        // "Version 1.000"
        0x56,
        0x65, 0x72,
        0x73, 0x69,
        0x6F, 0x6E,
        0x20, 0x31,
        0x2E, 0x30,
        0x30, 0x30,
    };
    var byte_reader = reader.ByteReader.init(buffer);
    var dummy_parsed_tables: ParsedTables = undefined;
    var table = try init(allocator, &byte_reader, &dummy_parsed_tables);
    try table.parse();
    defer table.deinit();
    const name_table = table.cast(Self);
    try std.testing.expect(name_table.version == 0x0000);

    try std.testing.expectEqualStrings("Tao Qin", name_table.get_by_name_id(0).?);
    try std.testing.expectEqualStrings("opentype", name_table.get_by_name_id(1).?);
    try std.testing.expectEqualStrings("Regular", name_table.get_by_name_id(2).?);
    try std.testing.expectEqualStrings("1.000;UKWN;NewFont-Regular", name_table.get_by_name_id(3).?);
    try std.testing.expectEqualStrings("New Font Regular", name_table.get_by_name_id(4).?);
    try std.testing.expectEqualStrings("Version 1.000", name_table.get_by_name_id(5).?);
    try std.testing.expectEqualStrings("Kanno", name_table.get_by_name_id(13).?);
    try std.testing.expectEqualStrings("opentype", name_table.get_by_name_id(16).?);
    try std.testing.expectEqualStrings("Regular", name_table.get_by_name_id(17).?);
}
