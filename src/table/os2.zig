const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");

const Allocator = std.mem.Allocator;

const Error = error{
    InvalidOs2Version,
};

// OS/2 is a complex table. Those getter functions are used to access the data

// https://learn.microsoft.com/en-us/typography/opentype/spec/os2#usweightclass

pub const WeightClass = enum(u16) {
    thin,
    extra_light,
    light,
    normal,
    medium,
    semi_bold,
    bold,
    extra_bold,
    black,
    other,
    pub fn to_num(self: WeightClass) u16 {
        return switch (self) {
            .thin => 100,
            .extra_light => 200,
            .light => 300,
            .normal => 400,
            .medium => 500,
            .semi_bold => 600,
            .bold => 700,
            .extra_bold => 800,
            .black => 900,
            .other => 0,
        };
    }

    pub fn from_raw(raw_weight: u16) WeightClass {
        return switch (raw_weight) {
            100 => .thin,
            200 => .extra_light,
            300 => .light,
            400 => .normal,
            500 => .medium,
            600 => .semi_bold,
            700 => .bold,
            800 => .extra_bold,
            900 => .black,
            else => .other,
        };
    }
};

pub const Version = enum(u16) {
    v0_5 = 0x0005,
    v0_4 = 0x0004,
    v0_3 = 0x0003,
    v0_2 = 0x0002,
    v0_1 = 0x0001,
    v0_0 = 0x0000,

    inline fn form_u16(b: u16) !Version {
        return std.meta.intToEnum(Version, b) catch {
            return error.InvalidOs2Version;
        };
    }
    inline fn to_u16(self: Version) u16 {
        return @intFromEnum(self);
    }
};

pub const Os2Table = struct {
    const Self = @This();

    allocator: Allocator,
    byte_reader: *reader.ByteReader,

    version: Version,

    v0_data: ?V0 = null,
    v1_data: ?V1 = null,
    v2_data: ?V2 = null,
    v3_data: ?V3 = null,
    v4_data: ?V4 = null,
    v5_data: ?V5 = null,

    const V0 = struct {
        x_avg_char_width: i16,
        us_weight_class: u16,
        us_width_class: u16,
        fs_type: u16,
        y_subscript_x_size: i16,
        y_subscript_y_size: i16,
        y_subscript_x_offset: i16,
        y_subscript_y_offset: i16,
        y_superscript_x_size: i16,
        y_superscript_y_size: i16,
        y_superscript_x_offset: i16,
        y_superscript_y_offset: i16,
        y_strikeout_size: i16,
        y_strikeout_position: i16,
        s_family_class: i16,
        panose: [10]u8,
        ul_unicode_range1: u32,
        ul_unicode_range2: u32,
        ul_unicode_range3: u32,
        ul_unicode_range4: u32,
        ach_vend_id: [4]u8,
        fs_selection: u16,
        us_first_char_index: u16,
        us_last_char_index: u16,
        s_typo_ascender: i16,
        s_typo_descender: i16,
        s_typo_line_gap: i16,
        us_win_ascent: u16,
        us_win_descent: u16,
    };

    const V1 = struct {
        ul_code_page_range1: u32,
        ul_code_page_range2: u32,
    };

    const V2 = struct {
        sx_height: i16,
        s_cap_height: i16,
        us_default_char: u16,
        us_break_char: u16,
        us_max_context: u16,
    };

    const V3 = struct {};

    const V4 = struct {};

    const V5 = struct {
        us_lower_optical_point_size: u16,
        us_upper_optical_point_size: u16,
    };

    fn parse(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.version = try Version.form_u16(try self.byte_reader.read_u16_be());

        const raw_version = self.version.to_u16();

        if (raw_version >= 0) {
            self.v0_data = try self.parse_v0();
        }

        if (raw_version >= 1) {
            self.v1_data = try self.parse_v1();
        }

        if (raw_version >= 2) {
            self.v2_data = try self.parse_v2();
        }

        if (raw_version >= 3) {
            self.v3_data = V3{};
        }

        if (raw_version >= 4) {
            self.v4_data = V4{};
        }

        if (raw_version >= 5) {
            self.v5_data = try self.parse_v5();
        }
    }

    fn parse_v0(self: *Self) !V0 {
        return V0{
            .x_avg_char_width = try self.byte_reader.read_i16_be(),
            .us_weight_class = try self.byte_reader.read_u16_be(),
            .us_width_class = try self.byte_reader.read_u16_be(),
            .fs_type = try self.byte_reader.read_u16_be(),
            .y_subscript_x_size = try self.byte_reader.read_i16_be(),
            .y_subscript_y_size = try self.byte_reader.read_i16_be(),
            .y_subscript_x_offset = try self.byte_reader.read_i16_be(),
            .y_subscript_y_offset = try self.byte_reader.read_i16_be(),
            .y_superscript_x_size = try self.byte_reader.read_i16_be(),
            .y_superscript_y_size = try self.byte_reader.read_i16_be(),
            .y_superscript_x_offset = try self.byte_reader.read_i16_be(),
            .y_superscript_y_offset = try self.byte_reader.read_i16_be(),
            .y_strikeout_size = try self.byte_reader.read_i16_be(),
            .y_strikeout_position = try self.byte_reader.read_i16_be(),
            .s_family_class = try self.byte_reader.read_i16_be(),
            .panose = @as([10]u8, (try self.byte_reader.read_bytes(10))[0..10].*),
            .ul_unicode_range1 = try self.byte_reader.read_u32_be(),
            .ul_unicode_range2 = try self.byte_reader.read_u32_be(),
            .ul_unicode_range3 = try self.byte_reader.read_u32_be(),
            .ul_unicode_range4 = try self.byte_reader.read_u32_be(),
            .ach_vend_id = @as([4]u8, (try self.byte_reader.read_bytes(4))[0..4].*),
            .fs_selection = try self.byte_reader.read_u16_be(),
            .us_first_char_index = try self.byte_reader.read_u16_be(),
            .us_last_char_index = try self.byte_reader.read_u16_be(),
            .s_typo_ascender = try self.byte_reader.read_i16_be(),
            .s_typo_descender = try self.byte_reader.read_i16_be(),
            .s_typo_line_gap = try self.byte_reader.read_i16_be(),
            .us_win_ascent = try self.byte_reader.read_u16_be(),
            .us_win_descent = try self.byte_reader.read_u16_be(),
        };
    }

    fn parse_v1(self: *Self) !V1 {
        return V1{
            .ul_code_page_range1 = try self.byte_reader.read_u32_be(),
            .ul_code_page_range2 = try self.byte_reader.read_u32_be(),
        };
    }

    fn parse_v2(self: *Self) !V2 {
        return V2{
            .sx_height = try self.byte_reader.read_i16_be(),
            .s_cap_height = try self.byte_reader.read_i16_be(),
            .us_default_char = try self.byte_reader.read_u16_be(),
            .us_break_char = try self.byte_reader.read_u16_be(),
            .us_max_context = try self.byte_reader.read_u16_be(),
        };
    }

    fn parse_v5(self: *Self) !V5 {
        return V5{
            .us_lower_optical_point_size = try self.byte_reader.read_u16_be(),
            .us_upper_optical_point_size = try self.byte_reader.read_u16_be(),
        };
    }

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

    fn get_weight_class(self: *Self) ?u16 {
        return if (self.v0_data) |data| data.us_weight_class else null;
    }

    fn get_width_class(self: *Self) ?u16 {
        return if (self.v0_data) |data| data.us_width_class else null;
    }

    pub fn get_fs_type(self: *Self) ?u16 {
        return if (self.v0_data) |data| data.fs_type else null;
    }

    pub fn get_typo_ascender(self: *Self) ?i16 {
        return if (self.v0_data) |data| data.s_typo_ascender else null;
    }

    pub fn get_typo_descender(self: *Self) ?i16 {
        return if (self.v0_data) |data| data.s_typo_descender else null;
    }

    pub fn get_typo_line_gap(self: *Self) ?i16 {
        return if (self.v0_data) |data| data.s_typo_line_gap else null;
    }

    pub fn get_win_ascent(self: *Self) ?u16 {
        return if (self.v0_data) |data| data.us_win_ascent else null;
    }

    pub fn get_win_descent(self: *Self) ?u16 {
        return if (self.v0_data) |data| data.us_win_descent else null;
    }

    pub fn get_x_height(self: *Self) ?i16 {
        return if (self.v2_data) |data| data.sx_height else null;
    }

    pub fn get_cap_height(self: *Self) ?i16 {
        return if (self.v2_data) |data| data.s_cap_height else null;
    }
};

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader) !Table {
    return Os2Table.init(allocator, byte_reader);
}

test "parse os2 table" {
    const allocator = std.testing.allocator;
    // Note: This data is fonts/sub5.ttf
    const buffer = &[_]u8{
        // Version 4
        0x00, 0x04,

        // V0 data (78 bytes)
        0x02, 0x4D, // xAvgCharWidth = 589
        0x01, 0x90, // usWeightClass = 400
        0x00, 0x05, // usWidthClass = 5
        0x00, 0x08, // fsType = 8
        0x02, 0x8A, // ySubscriptXSize = 650
        0x02, 0x58, // ySubscriptYSize = 600
        0x00, 0x00, // ySubscriptXOffset = 0
        0x00, 0x4B, // ySubscriptYOffset = 75
        0x02, 0x8A, // ySuperscriptXSize = 650
        0x02, 0x58, // ySuperscriptYSize = 600
        0x00, 0x00, // ySuperscriptXOffset = 0
        0x01, 0x5E, // ySuperscriptYOffset = 350
        0x00, 0x32, // yStrikeoutSize = 50
        0x00, 0xFA, // yStrikeoutPosition = 250
        0x00, 0x00, // sFamilyClass = 0

        // panose (10 bytes) - all zeros
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x03, // ulUnicodeRange1 = 3
        0x00, 0x00, 0x00, 0x00, // ulUnicodeRange2 = 0
        0x00, 0x00, 0x00, 0x00, // ulUnicodeRange3 = 0
        0x00, 0x00, 0x00, 0x00, // ulUnicodeRange4 = 0

        // achVendID (4 bytes) = "UKWN"
        0x55, 0x4B, 0x57, 0x4E, // "UKWN"
        0x00, 0xC0, // fsSelection = 192
        0x00, 0x20, // usFirstCharIndex = 32
        0x20, 0x44, // usLastCharIndex = 8260
        0x03, 0x20, // sTypoAscender = 800
        0xFF, 0x38, // sTypoDescender = -200 (two's complement)
        0x00, 0xC8, // sTypoLineGap = 200
        0x03, 0xE8, // usWinAscent = 1000
        0x00, 0xC8, // usWinDescent = 200

        // V1 data (8 bytes)
        0x00, 0x00, 0x00, 0x01, // ulCodePageRange1 = 1
        0x00, 0x00, 0x00, 0x00, // ulCodePageRange2 = 0

        // V2 data (10 bytes)
        0x01, 0xF4, // sxHeight = 500
        0x02, 0xBC, // sCapHeight = 700
        0x00, 0x00, // usDefaultChar = 0
        0x00, 0x20, // usBreakChar = 32
        0x00, 0x03, // usMaxContext = 3
    };
    var byte_reader = reader.ByteReader.init(buffer);
    const table = try Os2Table.init(allocator, &byte_reader);
    defer table.deinit();
    try table.parse();
    const os2_table = table.cast(Os2Table);
    try std.testing.expect(os2_table.version == .v0_4);

    if (os2_table.v0_data) |v0| {
        try std.testing.expectEqual(@as(i16, 589), v0.x_avg_char_width);
        try std.testing.expectEqual(@as(u16, 400), v0.us_weight_class);
        try std.testing.expectEqual(@as(u16, 5), v0.us_width_class);
        try std.testing.expectEqual(@as(u16, 8), v0.fs_type);
        try std.testing.expectEqual(@as(u16, 192), v0.fs_selection);
        try std.testing.expectEqual(@as(u16, 32), v0.us_first_char_index);
        try std.testing.expectEqual(@as(u16, 8260), v0.us_last_char_index);
        try std.testing.expectEqual(@as(i16, 800), v0.s_typo_ascender);
        try std.testing.expectEqual(@as(i16, -200), v0.s_typo_descender);
        try std.testing.expectEqual(@as(u16, 1000), v0.us_win_ascent);
        try std.testing.expectEqual(@as(u16, 200), v0.us_win_descent);

        try std.testing.expectEqualSlices(u8, "UKWN", &v0.ach_vend_id);

        const expected_panose = [_]u8{0} ** 10;
        try std.testing.expectEqualSlices(u8, &expected_panose, &v0.panose);
    }

    if (os2_table.v1_data) |v1| {
        try std.testing.expectEqual(@as(u32, 1), v1.ul_code_page_range1);
        try std.testing.expectEqual(@as(u32, 0), v1.ul_code_page_range2);
    }

    if (os2_table.v2_data) |v2| {
        try std.testing.expectEqual(@as(i16, 500), v2.sx_height);
        try std.testing.expectEqual(@as(i16, 700), v2.s_cap_height);
        try std.testing.expectEqual(@as(u16, 0), v2.us_default_char);
        try std.testing.expectEqual(@as(u16, 32), v2.us_break_char);
        try std.testing.expectEqual(@as(u16, 3), v2.us_max_context);
    }
}
