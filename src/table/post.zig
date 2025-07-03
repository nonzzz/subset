const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;

const Allocator = std.mem.Allocator;

// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6post.html
const STANDARD_NAMES = [_][]const u8{
    ".notdef",       ".null",         "nonmarkingreturn", "space",          "exclam",           "quotedbl",
    "numbersign",    "dollar",        "percent",          "ampersand",      "quotesingle",      "parenleft",
    "parenright",    "asterisk",      "plus",             "comma",          "hyphen",           "period",
    "slash",         "zero",          "one",              "two",            "three",            "four",
    "five",          "six",           "seven",            "eight",          "nine",             "colon",
    "semicolon",     "less",          "equal",            "greater",        "question",         "at",
    "A",             "B",             "C",                "D",              "E",                "F",
    "G",             "H",             "I",                "J",              "K",                "L",
    "M",             "N",             "O",                "P",              "Q",                "R",
    "S",             "T",             "U",                "V",              "W",                "X",
    "Y",             "Z",             "bracketleft",      "backslash",      "bracketright",     "asciicircum",
    "underscore",    "grave",         "a",                "b",              "c",                "d",
    "e",             "f",             "g",                "h",              "i",                "j",
    "k",             "l",             "m",                "n",              "o",                "p",
    "q",             "r",             "s",                "t",              "u",                "v",
    "w",             "x",             "y",                "z",              "braceleft",        "bar",
    "braceright",    "asciitilde",    "Adieresis",        "Aring",          "Ccedilla",         "Eacute",
    "Ntilde",        "Odieresis",     "Udieresis",        "aacute",         "agrave",           "acircumflex",
    "adieresis",     "atilde",        "aring",            "ccedilla",       "eacute",           "egrave",
    "ecircumflex",   "edieresis",     "iacute",           "igrave",         "icircumflex",      "idieresis",
    "ntilde",        "oacute",        "ograve",           "ocircumflex",    "odieresis",        "otilde",
    "uacute",        "ugrave",        "ucircumflex",      "udieresis",      "dagger",           "degree",
    "cent",          "sterling",      "section",          "bullet",         "paragraph",        "germandbls",
    "registered",    "copyright",     "trademark",        "acute",          "dieresis",         "notequal",
    "AE",            "Oslash",        "infinity",         "plusminus",      "lessequal",        "greaterequal",
    "yen",           "mu",            "partialdiff",      "summation",      "product",          "pi",
    "integral",      "ordfeminine",   "ordmasculine",     "Omega",          "ae",               "oslash",
    "questiondown",  "exclamdown",    "logicalnot",       "radical",        "florin",           "approxequal",
    "Delta",         "guillemotleft", "guillemotright",   "ellipsis",       "nonbreakingspace", "Agrave",
    "Atilde",        "Otilde",        "OE",               "oe",             "endash",           "emdash",
    "quotedblleft",  "quotedblright", "quoteleft",        "quoteright",     "divide",           "lozenge",
    "ydieresis",     "Ydieresis",     "fraction",         "currency",       "guilsinglleft",    "guilsinglright",
    "fi",            "fl",            "daggerdbl",        "periodcentered", "quotesinglbase",   "quotedblbase",
    "perthousand",   "Acircumflex",   "Ecircumflex",      "Aacute",         "Edieresis",        "Egrave",
    "Iacute",        "Icircumflex",   "Idieresis",        "Igrave",         "Oacute",           "Ocircumflex",
    "apple",         "Ograve",        "Uacute",           "Ucircumflex",    "Ugrave",           "dotlessi",
    "circumflex",    "tilde",         "macron",           "breve",          "dotaccent",        "ring",
    "cedilla",       "hungarumlaut",  "ogonek",           "caron",          "Lslash",           "lslash",
    "Scaron",        "scaron",        "Zcaron",           "zcaron",         "brokenbar",        "Eth",
    "eth",           "Yacute",        "yacute",           "Thorn",          "thorn",            "minus",
    "multiply",      "onesuperior",   "twosuperior",      "threesuperior",  "onehalf",          "onequarter",
    "threequarters", "franc",         "Gbreve",           "gbreve",         "Idotaccent",       "Scedilla",
    "scedilla",      "Cacute",        "cacute",           "Ccaron",         "ccaron",           "dcroat",
};

const Self = @This();

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

version: u32,
italic_angle: i32,
underline_position: i16,
underline_thickness: i16,
is_fixed_pitch: u32,
min_mem_type42: u32,
max_mem_type42: u32,
min_mem_type1: u32,
max_mem_type1: u32,

v2_data: ?V2 = null,

const V2 = struct {
    num_glyphs: u16,
    glyph_name_index: []u16,
    string_data: []u8,

    fn deinit(self: *V2, allocator: Allocator) void {
        allocator.free(self.glyph_name_index);
        if (self.string_data.len > 0) {
            allocator.free(self.string_data);
        }
    }
    fn get_name(self: *const V2, custom_index: u16) ?[]const u8 {
        var offset: usize = 0;
        var current_index: u16 = 0;

        while (offset < self.string_data.len and current_index < custom_index) {
            const length = self.string_data[offset];
            offset += 1 + length;
            current_index += 1;
        }

        if (offset >= self.string_data.len) return null;

        const length = self.string_data[offset];
        if (offset + 1 + length > self.string_data.len) return null;

        return self.string_data[offset + 1 .. offset + 1 + length];
    }
};

const Error = error{
    InvalidPostVersion,
    DeprecatedPostVersion25,
    OutOfMemory,
};

fn parse(ptr: *anyopaque) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));

    self.version = try self.byte_reader.read_u32_be();
    self.italic_angle = try self.byte_reader.read_i32_be();
    self.underline_position = try self.byte_reader.read_i16_be();
    self.underline_thickness = try self.byte_reader.read_i16_be();
    self.is_fixed_pitch = try self.byte_reader.read_u32_be();
    self.min_mem_type42 = try self.byte_reader.read_u32_be();
    self.max_mem_type42 = try self.byte_reader.read_u32_be();
    self.min_mem_type1 = try self.byte_reader.read_u32_be();
    self.max_mem_type1 = try self.byte_reader.read_u32_be();

    switch (self.version) {
        0x00010000, 0x00030000 => {},
        0x00020000 => {
            self.v2_data = try self.parse_v2();
        },
        0x00025000 => {
            return Error.DeprecatedPostVersion25;
        },
        else => {
            return Error.InvalidPostVersion;
        },
    }
}

fn parse_v2(self: *Self) !V2 {
    const num_glyphs = try self.byte_reader.read_u16_be();
    const glyph_name_index = try self.allocator.alloc(u16, num_glyphs);
    errdefer self.allocator.free(glyph_name_index);
    for (glyph_name_index) |*index| {
        index.* = try self.byte_reader.read_u16_be();
    }

    // glyph name index range is 0-257 standard macintosh names,
    // otherwise its a custom name index starting from 258 to 65535
    var max_custom_index: u16 = 0;
    var has_custom_names = false;
    for (glyph_name_index) |index| {
        if (index >= 258) {
            const custom_index = index - 258;
            max_custom_index = @max(max_custom_index, custom_index);
            has_custom_names = true;
        }
    }

    var string_data: []u8 = &.{};

    if (has_custom_names) {
        var string_list = std.ArrayList(u8).init(self.allocator);
        errdefer string_list.deinit();
        var custom_strings_read: u16 = 0;
        while (custom_strings_read <= max_custom_index) {
            const string_length = try self.byte_reader.read_u8();
            const string_bytes = try self.byte_reader.read_bytes(string_length);

            try string_list.append(string_length);
            try string_list.appendSlice(string_bytes);
            custom_strings_read += 1;
        }
        string_data = try string_list.toOwnedSlice();
    }

    return V2{
        .num_glyphs = num_glyphs,
        .glyph_name_index = glyph_name_index,
        .string_data = string_data,
    };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.v2_data) |*v2| {
        v2.deinit(self.allocator);
    }
    self.allocator.destroy(self);
}

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = undefined;
    self.allocator = allocator;
    self.byte_reader = byte_reader;
    self.parsed_tables = parsed_tables;
    self.v2_data = null;

    return Table{
        .ptr = self,
        .vtable = &.{ .parse = parse, .deinit = deinit },
    };
}

pub fn get_version(self: *Self) u32 {
    return self.version;
}

pub fn get_italic_angle(self: *Self) i32 {
    return self.italic_angle;
}

pub fn get_underline_position(self: *Self) i16 {
    return self.underline_position;
}

pub fn get_underline_thickness(self: *Self) i16 {
    return self.underline_thickness;
}

pub fn is_monospace(self: *Self) bool {
    return self.is_fixed_pitch != 0;
}

pub fn has_glyph_names(self: *Self) bool {
    return self.version == 0x00010000 or self.version == 0x00020000;
}

pub fn get_num_glyphs(self: *Self) ?u16 {
    return if (self.v2_data) |v2| v2.num_glyphs else null;
}

pub fn get_glyph_name(self: *Self, glyph_id: u16) ?[]const u8 {
    switch (self.version) {
        0x00010000 => {
            if (glyph_id < STANDARD_NAMES.len) {
                return STANDARD_NAMES[glyph_id];
            }
            return null;
        },
        0x00020000 => {
            if (self.v2_data) |v2| {
                if (glyph_id >= v2.num_glyphs) return null;

                const name_index = v2.glyph_name_index[glyph_id];
                if (name_index < 258) {
                    return STANDARD_NAMES[name_index];
                } else {
                    const custom_index = name_index - 258;
                    return v2.get_name(custom_index);
                }
            }
            return null;
        },
        else => return null,
    }
}

test "parse post table v1.0" {
    const allocator = std.testing.allocator;
    const buffer = &[_]u8{
        // Version 1.0
        0x00, 0x01, 0x00, 0x00,
        // italicAngle (Fixed 16.16) = 0
        0x00, 0x00, 0x00, 0x00,
        // underlinePosition = -100
        0xFF, 0x9C,
        // underlineThickness = 50
        0x00, 0x32,
        // isFixedPitch = 0 (proportional)
        0x00, 0x00, 0x00, 0x00,
        // minMemType42 = 0
        0x00, 0x00, 0x00, 0x00,
        // maxMemType42 = 0
        0x00, 0x00, 0x00, 0x00,
        // minMemType1 = 0
        0x00, 0x00, 0x00, 0x00,
        // maxMemType1 = 0
        0x00, 0x00, 0x00, 0x00,
    };

    var byte_reader = reader.ByteReader.init(buffer);
    var dummy_parsed_tables: ParsedTables = undefined;
    var table = try init(allocator, &byte_reader, &dummy_parsed_tables);
    defer table.deinit();

    try table.parse();
    const post_table = table.cast(Self);

    try std.testing.expectEqual(@as(u32, 0x00010000), post_table.get_version());
    try std.testing.expectEqual(@as(i16, -100), post_table.get_underline_position());
    try std.testing.expectEqual(@as(i16, 50), post_table.get_underline_thickness());
    try std.testing.expect(!post_table.is_monospace());
    try std.testing.expect(post_table.has_glyph_names());

    try std.testing.expectEqualSlices(u8, ".notdef", post_table.get_glyph_name(0).?);
}

test "parse post table v2.0" {
    const allocator = std.testing.allocator;
    const buffer = &[_]u8{
        // Version 2.0
        0x00, 0x02, 0x00, 0x00,
        // italicAngle (Fixed 16.16) = 0
        0x00, 0x00, 0x00, 0x00,
        // underlinePosition = -100
        0xFF, 0x9C,
        // underlineThickness = 50
        0x00, 0x32,
        // isFixedPitch = 0 (proportional)
        0x00, 0x00, 0x00, 0x00,
        // minMemType42 = 0
        0x00, 0x00, 0x00, 0x00,
        // maxMemType42 = 0
        0x00, 0x00, 0x00, 0x00,
        // minMemType1 = 0
        0x00, 0x00, 0x00, 0x00,
        // maxMemType1 = 0
        0x00, 0x00, 0x00, 0x00,

        // numberOfGlyphs = 4 (reduced from 5)
        0x00,
        0x04,

        // glyphNameIndex array (4 entries, removed custom2)
        0x00, 0x00, // 0 (.notdef)
        0x00, 0x03, // 3 (space)
        0x00, 0x24, // 36 (A)
        0x01, 0x02, // 258 (custom name index 0)

        // Custom string data (Pascal strings)
        // "custom1" (index 0, 258)
        0x07, 0x63,
        0x75, 0x73,
        0x74, 0x6F,
        0x6D, 0x31,
    };

    var byte_reader = reader.ByteReader.init(buffer);
    var dummy_parsed_tables: ParsedTables = undefined;
    var table = try init(allocator, &byte_reader, &dummy_parsed_tables);
    defer table.deinit();

    try table.parse();
    const post_table = table.cast(Self);

    try std.testing.expectEqual(@as(u32, 0x00020000), post_table.get_version());
    try std.testing.expectEqual(@as(i16, -100), post_table.get_underline_position());
    try std.testing.expectEqual(@as(i16, 50), post_table.get_underline_thickness());
    try std.testing.expectEqual(post_table.is_monospace(), false);
    try std.testing.expect(post_table.has_glyph_names());
    try std.testing.expectEqualSlices(u8, ".notdef", post_table.get_glyph_name(0).?);
    try std.testing.expectEqualSlices(u8, "space", post_table.get_glyph_name(1).?);
    try std.testing.expectEqualSlices(u8, "A", post_table.get_glyph_name(2).?);
    try std.testing.expectEqualSlices(u8, "custom1", post_table.get_glyph_name(3).?);
    try std.testing.expect(post_table.get_glyph_name(4) == null);
}

test "parse post table v2.5 deprecated" {
    const allocator = std.testing.allocator;
    const buffer = &[_]u8{
        // Version 2.5 (deprecated)
        0x00, 0x02, 0x50, 0x00,
        // ... rest of header
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0x9C, 0x00, 0x32,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };

    var byte_reader = reader.ByteReader.init(buffer);
    var dummy_parsed_tables: ParsedTables = undefined;
    var table = try init(allocator, &byte_reader, &dummy_parsed_tables);
    defer table.deinit();

    try std.testing.expectError(Error.DeprecatedPostVersion25, table.parse());
}
