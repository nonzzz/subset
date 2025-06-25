const std = @import("std");
const reader = @import("../byte_read.zig");

pub const Table = struct {
    const Self = @This();

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

    pub fn parse(byte_reader: *reader.ByteReader) !Self {
        if (byte_reader.buffer.len < 36) {
            return Error.InvalidHheaTable;
        }

        const major_version = try byte_reader.read_u16_be();
        const minor_version = try byte_reader.read_u16_be();
        const ascender = try byte_reader.read_i16_be();
        const descender = try byte_reader.read_i16_be();
        const line_gap = try byte_reader.read_i16_be();
        const advance_width_max = try byte_reader.read_u16_be();
        const min_left_side_bearing = try byte_reader.read_i16_be();
        const min_right_side_bearing = try byte_reader.read_i16_be();
        const x_max_extent = try byte_reader.read_i16_be();
        const caret_slope_rise = try byte_reader.read_i16_be();
        const caret_slope_run = try byte_reader.read_i16_be();
        const caret_offset = try byte_reader.read_i16_be();

        const reserved1 = try byte_reader.read_i16_be();
        const reserved2 = try byte_reader.read_i16_be();
        const reserved3 = try byte_reader.read_i16_be();
        const reserved4 = try byte_reader.read_i16_be();

        const metric_data_format = try byte_reader.read_i16_be();
        const number_of_hmetrics = try byte_reader.read_u16_be();

        return Self{
            .major_version = major_version,
            .minor_version = minor_version,
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .advance_width_max = advance_width_max,
            .min_left_side_bearing = min_left_side_bearing,
            .min_right_side_bearing = min_right_side_bearing,
            .x_max_extent = x_max_extent,
            .caret_slope_rise = caret_slope_rise,
            .caret_slope_run = caret_slope_run,
            .caret_offset = caret_offset,
            .reserved1 = reserved1,
            .reserved2 = reserved2,
            .reserved3 = reserved3,
            .reserved4 = reserved4,
            .metric_data_format = metric_data_format,
            .number_of_hmetrics = number_of_hmetrics,
        };
    }
};

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
    const hhea_table = try Table.parse(&byte_reader);
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
