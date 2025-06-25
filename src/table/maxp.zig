const std = @import("std");
const reader = @import("../byte_read.zig");

// CFF or CFF2 must using version0.5. TTF must using version 1.0

pub const Table = struct {
    const Self = @This();

    version: u32,
    num_glyphs: u16,

    // For TTF
    max_points: ?u16 = null,
    max_contours: ?u16 = null,
    max_composite_points: ?u16 = null,
    max_composite_contours: ?u16 = null,
    max_zones: ?u16 = null,
    max_twilight_points: ?u16 = null,
    max_storage: ?u16 = null,
    max_function_defs: ?u16 = null,
    max_instruction_defs: ?u16 = null,
    max_stack_elements: ?u16 = null,
    max_size_of_instructions: ?u16 = null,
    max_component_elements: ?u16 = null,
    max_component_depth: ?u16 = null,

    const Error = error{
        InvalidMaxpVersion,
    };

    pub fn parse(byte_reader: *reader.ByteReader) !Self {
        const version = try byte_reader.read_u32_be();
        const num_glyphs = try byte_reader.read_u16_be();

        var table = Self{
            .version = version,
            .num_glyphs = num_glyphs,
        };

        switch (version) {
            0x00005000 => {},
            0x00010000 => {
                table.max_points = try byte_reader.read_u16_be();
                table.max_contours = try byte_reader.read_u16_be();
                table.max_composite_points = try byte_reader.read_u16_be();
                table.max_composite_contours = try byte_reader.read_u16_be();
                table.max_zones = try byte_reader.read_u16_be();
                table.max_twilight_points = try byte_reader.read_u16_be();
                table.max_storage = try byte_reader.read_u16_be();
                table.max_function_defs = try byte_reader.read_u16_be();
                table.max_instruction_defs = try byte_reader.read_u16_be();
                table.max_stack_elements = try byte_reader.read_u16_be();
                table.max_size_of_instructions = try byte_reader.read_u16_be();
                table.max_component_elements = try byte_reader.read_u16_be();
                table.max_component_depth = try byte_reader.read_u16_be();
            },
            else => {
                return error.InvalidMaxpVersion;
            },
        }
        return table;
    }
    pub fn is_ttf(self: *const Self) bool {
        return self.version == 0x00010000;
    }

    pub fn is_cff(self: *const Self) bool {
        return self.version == 0x00005000;
    }
};

test "parse maxp table version 0.5" {
    const buffer = &[_]u8{
        0x00, 0x00, 0x50, 0x00, // version = 0x00005000 (0.5 in Fixed point)
        0x00, 0x01, // num_glyphs = 1
    };
    var byte_reader = reader.ByteReader.init(buffer);
    const table = try Table.parse(&byte_reader);
    try std.testing.expect(table.version == 0x00005000);
    try std.testing.expect(table.num_glyphs == 1);
}

test "parse maxp table version 1.0" {
    const buffer = &[_]u8{
        0x00, 0x01, 0x00, 0x00, // version
        0x00, 0x02, // num_glyphs
        0x00, 0x10, // max_points
        0x00, 0x05, // max_contours
        0x00, 0x08, // max_composite_points
        0x00, 0x04, // max_composite_contours
        0x00, 0x02, // max_zones
        0x00, 0x03, // max_twilight_points
        0x00, 0x01, // max_storage
        0x00, 0x02, // max_function_defs
        0x00, 0x01, // max_instruction_defs
        0x00, 0x04, // max_stack_elements
        0x00, 0x08, // max_size_of_instructions
        0x00, 0x02, // max_component_elements
        0x00, 0x03, // max_component_depth
    };
    var byte_reader = reader.ByteReader.init(buffer);
    const table = try Table.parse(&byte_reader);
    try std.testing.expect(table.version == 0x00010000);
    try std.testing.expect(table.num_glyphs == 2);
    try std.testing.expect(table.max_points.? == 16);
}
