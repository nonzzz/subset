const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;

const Allocator = std.mem.Allocator;

const Self = @This();

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

major_version: u16,
minor_version: u16,
ascender: i16,
descender: i16,
line_gap: i16,
advance_width_max: u16,
min_left_side_bearing: i16,
min_right_side_bearing: i16,
x_max_extent: i16,
caret_slope_rise: i16,
caret_slope_run: i16,
caret_offset: i16,
reserved1: i16,
reserved2: i16,
reserved3: i16,
reserved4: i16,
metric_data_format: i16,
number_of_hmetrics: u16,

const Error = error{
    InvalidHheaTable,
};

pub fn parse(ptr: *anyopaque) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.byte_reader.buffer.len < 36) {
        return Error.InvalidHheaTable;
    }

    self.major_version = try self.byte_reader.read_u16_be();
    self.minor_version = try self.byte_reader.read_u16_be();
    self.ascender = try self.byte_reader.read_i16_be();
    self.descender = try self.byte_reader.read_i16_be();
    self.line_gap = try self.byte_reader.read_i16_be();
    self.advance_width_max = try self.byte_reader.read_u16_be();
    self.min_left_side_bearing = try self.byte_reader.read_i16_be();
    self.min_right_side_bearing = try self.byte_reader.read_i16_be();
    self.x_max_extent = try self.byte_reader.read_i16_be();
    self.caret_slope_rise = try self.byte_reader.read_i16_be();
    self.caret_slope_run = try self.byte_reader.read_i16_be();
    self.caret_offset = try self.byte_reader.read_i16_be();

    self.reserved1 = try self.byte_reader.read_i16_be();
    self.reserved2 = try self.byte_reader.read_i16_be();
    self.reserved3 = try self.byte_reader.read_i16_be();
    self.reserved4 = try self.byte_reader.read_i16_be();

    self.metric_data_format = try self.byte_reader.read_i16_be();
    self.number_of_hmetrics = try self.byte_reader.read_u16_be();
}

fn deinit(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = undefined;
    self.allocator = allocator;
    self.byte_reader = byte_reader;
    self.parsed_tables = parsed_tables;

    return Table{
        .ptr = self,
        .vtable = &.{ .parse = parse, .deinit = deinit },
    };
}

test "Hhea Table Parsing" {
    const hhea_buffer = &[_]u8{
        0x00, 0x01, // major_version
        0x00, 0x00, // minor_version
        0x00, 0x20, // ascender
        0xFF, 0xE0, // descender
        0x00, 0x10, // line_gap
        0x00, 0x80, // advance_width_max
        0x00, 0x08, // min_left_side_bearing
        0x00, 0x08, // min_right_side_bearing
        0x00, 0x40, // x_max_extent
        0x00, 0x01, // caret_slope_rise
        0x00, 0x01, // caret_slope_run
        0x00, 0x00, // caret_offset
        0x00, 0x00, // reserved1
        0x00, 0x00, // reserved2
        0x00, 0x00, // reserved3
        0x00, 0x00, // reserved4
        0x00, 0x01, // metric_data_format
        0x00, 0x02, // number_of_hmetrics
    };
    var byte_reader = reader.ByteReader.init(hhea_buffer);
    var dummy_parsed_tables: ParsedTables = undefined;
    var table = try init(std.testing.allocator, &byte_reader, &dummy_parsed_tables);
    defer table.deinit();
    try table.parse();
    const hhea_table = table.cast(Self);

    try std.testing.expect(hhea_table.major_version == 1);
    try std.testing.expect(hhea_table.minor_version == 0);
    try std.testing.expect(hhea_table.ascender == 32);
    try std.testing.expect(hhea_table.descender == -32);
    try std.testing.expect(hhea_table.line_gap == 16);
    try std.testing.expect(hhea_table.advance_width_max == 128);
    try std.testing.expect(hhea_table.min_left_side_bearing == 8);
    try std.testing.expect(hhea_table.min_right_side_bearing == 8);
    try std.testing.expect(hhea_table.x_max_extent == 64);
    try std.testing.expect(hhea_table.caret_slope_rise == 1);
    try std.testing.expect(hhea_table.caret_slope_run == 1);
    try std.testing.expect(hhea_table.caret_offset == 0);
    try std.testing.expect(hhea_table.reserved1 == 0);
    try std.testing.expect(hhea_table.reserved2 == 0);
    try std.testing.expect(hhea_table.reserved3 == 0);
    try std.testing.expect(hhea_table.reserved4 == 0);
    try std.testing.expect(hhea_table.metric_data_format == 1);
    try std.testing.expect(hhea_table.number_of_hmetrics == 2);
}
