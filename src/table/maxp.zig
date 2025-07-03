const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;

const Allocator = std.mem.Allocator;

// CFF or CFF2 must using version0.5. TTF must using version 1.0

const Self = @This();

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

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

fn parse(ptr: *anyopaque) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    const version = try self.byte_reader.read_u32_be();
    const num_glyphs = try self.byte_reader.read_u16_be();

    self.version = version;
    self.num_glyphs = num_glyphs;

    switch (version) {
        0x00005000 => {},
        0x00010000 => {
            self.max_points = try self.byte_reader.read_u16_be();
            self.max_contours = try self.byte_reader.read_u16_be();
            self.max_composite_points = try self.byte_reader.read_u16_be();
            self.max_composite_contours = try self.byte_reader.read_u16_be();
            self.max_zones = try self.byte_reader.read_u16_be();
            self.max_twilight_points = try self.byte_reader.read_u16_be();
            self.max_storage = try self.byte_reader.read_u16_be();
            self.max_function_defs = try self.byte_reader.read_u16_be();
            self.max_instruction_defs = try self.byte_reader.read_u16_be();
            self.max_stack_elements = try self.byte_reader.read_u16_be();
            self.max_size_of_instructions = try self.byte_reader.read_u16_be();
            self.max_component_elements = try self.byte_reader.read_u16_be();
            self.max_component_depth = try self.byte_reader.read_u16_be();
        },
        else => {
            return error.InvalidMaxpVersion;
        },
    }
}

pub fn is_ttf(self: *Self) bool {
    return self.version == 0x00010000;
}

pub fn is_cff(self: *Self) bool {
    return self.version == 0x00005000;
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
test "parse maxp table version 0.5" {
    const buffer = &[_]u8{
        0x00, 0x00, 0x50, 0x00, // version = 0x00005000 (0.5 in Fixed point)
        0x00, 0x01, // num_glyphs = 1
    };
    var byte_reader = reader.ByteReader.init(buffer);

    var dummy_parsed_tables: ParsedTables = undefined;
    var table = try init(std.testing.allocator, &byte_reader, &dummy_parsed_tables);
    defer table.deinit();
    try table.parse();

    var maxp_data = table.cast(Self);
    try std.testing.expect(maxp_data.version == 0x00005000);
    try std.testing.expect(maxp_data.num_glyphs == 1);
    try std.testing.expect(maxp_data.is_cff());
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
    var dummy_parsed_tables: ParsedTables = undefined;
    var table = try init(std.testing.allocator, &byte_reader, &dummy_parsed_tables);
    defer table.deinit();
    try table.parse();
    const maxp_table = table.cast(Self);
    try std.testing.expect(maxp_table.version == 0x00010000);
    try std.testing.expect(maxp_table.num_glyphs == 2);
    try std.testing.expect(maxp_table.max_points.? == 16);
}
