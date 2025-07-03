const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;
const Error = @import("./errors.zig").Error;

const Allocator = std.mem.Allocator;

pub const Flags = packed struct {};

pub const MacStyle = packed struct {
    bold: bool,
    italic: bool,
    underline: bool,
    outline: bool,
    shadow: bool,
    condensed: bool,
    extended: bool,
    reserved: u9,

    pub fn is_bold(self: MacStyle) bool {
        return self.bold;
    }
    pub fn is_italic(self: MacStyle) bool {
        return self.italic;
    }
    pub fn has_any_style(self: MacStyle) bool {
        return self.bold or self.italic or self.underline or
            self.outline or self.shadow or self.condensed or self.extended;
    }
    pub fn to_u16(self: MacStyle) u16 {
        return @bitCast(self);
    }

    pub fn from_u16(value: u16) MacStyle {
        return @bitCast(value);
    }
};

const Self = @This();

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

major_version: u16,
minor_version: u16,
font_revision: u32,
checksum_adjustment: u32,
magic_number: u32,
flags: u16,
units_per_em: u16,
created: i64,
modified: i64,
x_min: i16,
y_min: i16,
x_max: i16,
y_max: i16,
mac_style: MacStyle,
lowest_rec_ppem: u16,
font_direction_hint: i16,
index_to_loc_format: i16,
glyph_data_format: i16,

fn parse(ptr: *anyopaque) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));

    if (self.byte_reader.buffer.len < 54) {
        return Error.InvalidHeadTable;
    }

    const major_version = try self.byte_reader.read_u16_be();
    const minor_version = try self.byte_reader.read_u16_be();
    const font_revision = try self.byte_reader.read_u32_be();
    const checksum_adjustment = try self.byte_reader.read_u32_be();
    const magic_number = try self.byte_reader.read_u32_be();
    const flags = try self.byte_reader.read_u16_be();
    const units_per_em = try self.byte_reader.read_u16_be();
    const created = try self.byte_reader.read_i64_be();
    const modified = try self.byte_reader.read_i64_be();
    const x_min = try self.byte_reader.read_i16_be();
    const y_min = try self.byte_reader.read_i16_be();
    const x_max = try self.byte_reader.read_i16_be();
    const y_max = try self.byte_reader.read_i16_be();
    const mac_style = try self.byte_reader.read_u16_be();
    const lowest_rec_ppem = try self.byte_reader.read_u16_be();
    const font_direction_hint = try self.byte_reader.read_i16_be();
    const index_to_loc_format = try self.byte_reader.read_i16_be();
    const glyph_data_format = try self.byte_reader.read_i16_be();

    self.major_version = major_version;
    self.minor_version = minor_version;
    self.font_revision = font_revision;
    self.checksum_adjustment = checksum_adjustment;
    self.magic_number = magic_number;
    self.flags = flags;
    self.units_per_em = units_per_em;
    self.created = created;
    self.modified = modified;
    self.x_min = x_min;
    self.y_min = y_min;
    self.x_max = x_max;
    self.y_max = y_max;
    self.mac_style = MacStyle.from_u16(mac_style);
    self.lowest_rec_ppem = lowest_rec_ppem;
    self.font_direction_hint = font_direction_hint;
    self.index_to_loc_format = index_to_loc_format;
    self.glyph_data_format = glyph_data_format;
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

test "MacStyle Parsing" {
    const style = MacStyle{
        .bold = true,
        .italic = false,
        .underline = true,
        .outline = false,
        .shadow = false,
        .condensed = false,
        .extended = false,
        .reserved = 0,
    };
    try std.testing.expect(@sizeOf(MacStyle) == 2);
    try std.testing.expect(style.is_bold() == true);
    try std.testing.expect(style.is_italic() == false);
    try std.testing.expect(style.has_any_style() == true);
    const style_u16 = style.to_u16();
    const parsed_style = MacStyle.from_u16(style_u16);
    try std.testing.expect(parsed_style.is_bold() == true);
    try std.testing.expect(parsed_style.is_italic() == false);
}

test "Head Table Parsing" {
    const head_buffer = &[_]u8{
        0x00, 0x01, // major_version 1.0
        0x00, 0x00, // minor_version 0.0
        0x00, 0x01, 0x00, 0x41, // font_revision 1.001
        0xB1, 0xB0, 0xAF, 0xBA, // checksum_adjustment
        0x5F, 0x0F, 0x3C, 0xF5, // magic_number
        0x00, 0x11, // flags
        0x03, 0xE8, // units_per_em 1000
        0x00, 0x00, 0x01, 0x8C, 0x22, 0x0C, 0xA0, 0x00, // timestamp created (2025-6-25)
        0x00, 0x00, 0x01, 0x8C, 0x22, 0x0C, 0xA0, 0x00, // timestamp modified
        0xFF, 0xCE, // x_min -50
        0xFF, 0x38, // y_min -200
        0x00, 0x32, // x_max 50
        0x00, 0xC8, // y_max 200
        0x00, 0x03, // mac_style (bold, italic)
        0x00, 0x08, // lowest_rec_ppem 8
        0x00, 0x02, // font_direction_hint 2
        0x00, 0x00, // index_to_loc_format 0
        0x00, 0x00, // glyph_data_format 0
    };
    var byte_reader = reader.ByteReader.init(head_buffer);

    var dummy_parsed_tables: ParsedTables = undefined;
    const table = try init(std.testing.allocator, &byte_reader, &dummy_parsed_tables);
    defer table.deinit();
    try table.parse();

    const head_table = table.cast(Self);
    try std.testing.expect(head_table.major_version == 1);
    try std.testing.expect(head_table.minor_version == 0);
    try std.testing.expect(head_table.font_revision == 0x00010041);
    try std.testing.expect(head_table.checksum_adjustment == 0xB1B0AFBA);
    try std.testing.expect(head_table.magic_number == 0x5F0F3CF5);
    try std.testing.expect(head_table.flags == 0x0011);
    try std.testing.expect(head_table.units_per_em == 1000);
    try std.testing.expect(head_table.x_min == -50);
    try std.testing.expect(head_table.y_min == -200);
    try std.testing.expect(head_table.x_max == 50);
    try std.testing.expect(head_table.y_max == 200);
    try std.testing.expect(head_table.lowest_rec_ppem == 8);
    try std.testing.expect(head_table.font_direction_hint == 2);
    try std.testing.expect(head_table.index_to_loc_format == 0);
    try std.testing.expect(head_table.created == 1701378301952);
    try std.testing.expect(head_table.modified == 0x18C220CA000);
    try std.testing.expect(head_table.glyph_data_format == 0);
    try std.testing.expect(head_table.mac_style.is_bold());
    try std.testing.expect(head_table.mac_style.is_italic());
    try std.testing.expect(!head_table.mac_style.underline);
    try std.testing.expect(head_table.mac_style.has_any_style());
}
