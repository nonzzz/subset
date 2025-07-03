const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;
const Error = @import("./errors.zig").Error;

const Allocator = std.mem.Allocator;

const Self = @This();

pub const PlatformID = enum(u16) {
    unicode = 0,
    macintosh = 1,
    iso = 2,
    microsoft = 3,

    pub fn from_u16(value: u16) PlatformID {
        return @enumFromInt(value);
    }
};

pub const EncodingID = struct {
    pub const Unicode = enum(u16) {
        unicode_1_0 = 0,
        unicode_1_1 = 1,
        iso_10646 = 2,
        unicode_2_0_bmp = 3,
        unicode_2_0_full = 4,
        unicode_variation = 5,
        unicode_full = 6,
    };

    pub const Microsoft = enum(u16) {
        symbol = 0,
        unicode_bmp = 1,
        shift_jis = 2,
        prc = 3,
        big5 = 4,
        wansung = 5,
        johab = 6,
        unicode_full = 10,
    };
};

pub const CmapFormat = union(enum) {
    format0: Format0,
    format2: Format2,
    format4: Format4,
    format6: Format6,
    format10: Format10,
    format12: Format12,
    format13: Format13,
    format14: Format14,

    pub fn deinit(self: *CmapFormat, allocator: Allocator) void {
        switch (self.*) {
            .format0 => |*fmt| fmt.deinit(allocator),
            .format2 => |*fmt| fmt.deinit(allocator),
            .format4 => |*fmt| fmt.deinit(allocator),
            .format6 => |*fmt| fmt.deinit(allocator),
            .format10 => |*fmt| fmt.deinit(allocator),
            .format12 => |*fmt| fmt.deinit(allocator),
            .format13 => |*fmt| fmt.deinit(allocator),
            .format14 => |*fmt| fmt.deinit(allocator),
        }
    }

    pub fn get_glyph_index(self: CmapFormat, codepoint: u32) ?u16 {
        return switch (self) {
            .format0 => |fmt| fmt.get_glyph_index(codepoint),
            .format2 => |fmt| fmt.get_glyph_index(codepoint),
            .format4 => |fmt| fmt.get_glyph_index(codepoint),
            .format6 => |fmt| fmt.get_glyph_index(codepoint),
            .format10 => |fmt| fmt.get_glyph_index(codepoint),
            .format12 => |fmt| fmt.get_glyph_index(codepoint),
            .format13 => |fmt| fmt.get_glyph_index(codepoint),
            .format14 => |fmt| fmt.get_glyph_index(codepoint),
        };
    }
};

pub const Format0 = struct {
    length: u16,
    language: u16,
    glyph_id_array: [256]u8,

    pub fn deinit(self: *Format0, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn get_glyph_index(self: Format0, codepoint: u32) ?u16 {
        if (codepoint > 255) return null;
        return self.glyph_id_array[@intCast(codepoint)];
    }
};

pub const Format2 = struct {
    length: u16,
    language: u16,
    sub_header_keys: [256]u16,
    sub_headers: []SubHeader,
    glyph_index_array: []u16,

    pub const SubHeader = struct {
        first_code: u16,
        entry_count: u16,
        id_delta: i16,
        id_range_offset: u16,
    };

    pub fn deinit(self: *Format2, allocator: Allocator) void {
        allocator.free(self.sub_headers);
        allocator.free(self.glyph_index_array);
    }

    pub fn get_glyph_index(self: Format2, codepoint: u32) ?u16 {
        const high_byte = (codepoint >> 8) & 0xFF;
        const low_byte = codepoint & 0xFF;

        const sub_header_index = self.sub_header_keys[high_byte] / 8;

        if (sub_header_index == 0) {
            if (codepoint > 255) return null;
            return if (low_byte < self.sub_headers[0].entry_count)
                self.glyph_index_array[low_byte]
            else
                null;
        } else {
            if (sub_header_index >= self.sub_headers.len) return null;
            const sub_header = self.sub_headers[sub_header_index];

            if (low_byte < sub_header.first_code or
                low_byte >= sub_header.first_code + sub_header.entry_count)
            {
                return null;
            }

            const index = sub_header.id_range_offset / 2 +
                (low_byte - sub_header.first_code) +
                sub_header_index - self.sub_headers.len;

            if (index >= self.glyph_index_array.len) return null;
            const glyph_id = self.glyph_index_array[index];

            if (glyph_id == 0) {
                return null;
            } else {
                const result = @as(i32, glyph_id) + @as(i32, sub_header.id_delta);
                return @intCast(result & 0xFFFF);
            }
        }
    }
};

pub const Format4 = struct {
    length: u16,
    language: u16,
    seg_count_x2: u16,
    search_range: u16,
    entry_selector: u16,
    range_shift: u16,
    end_code: []u16,
    start_code: []u16,
    id_delta: []i16,
    id_range_offset: []u16,
    glyph_id_array: []u16,

    pub fn deinit(self: *Format4, allocator: Allocator) void {
        allocator.free(self.end_code);
        allocator.free(self.start_code);
        allocator.free(self.id_delta);
        allocator.free(self.id_range_offset);
        allocator.free(self.glyph_id_array);
    }

    pub fn get_glyph_index(self: Format4, codepoint: u32) ?u16 {
        if (codepoint > 0xFFFF) return null;
        const code: u16 = @intCast(codepoint);

        const seg_count = self.seg_count_x2 / 2;

        var left: usize = 0;
        var right: usize = seg_count - 1;

        while (left <= right) {
            const mid = (left + right) / 2;
            if (code <= self.end_code[mid]) {
                if (code >= self.start_code[mid]) {
                    if (self.id_range_offset[mid] == 0) {
                        const result = @as(i32, code) + @as(i32, self.id_delta[mid]);
                        return @intCast(result & 0xFFFF);
                    } else {
                        const offset = self.id_range_offset[mid] / 2 +
                            (code - self.start_code[mid]) +
                            mid - seg_count;

                        if (offset >= self.glyph_id_array.len) return null;
                        const glyph_id = self.glyph_id_array[offset];

                        if (glyph_id == 0) {
                            return null;
                        } else {
                            const result = @as(i32, glyph_id) + @as(i32, self.id_delta[mid]);
                            return @intCast(result & 0xFFFF);
                        }
                    }
                }
                right = mid - 1;
            } else {
                left = mid + 1;
            }
        }

        return null;
    }
};

pub const Format6 = struct {
    length: u16,
    language: u16,
    first_code: u16,
    entry_count: u16,
    glyph_id_array: []u16,

    pub fn deinit(self: *Format6, allocator: Allocator) void {
        allocator.free(self.glyph_id_array);
    }

    pub fn get_glyph_index(self: Format6, codepoint: u32) ?u16 {
        if (codepoint > 0xFFFF) return null;
        const code: u16 = @intCast(codepoint);

        if (code < self.first_code or code >= self.first_code + self.entry_count) {
            return null;
        }

        const index = code - self.first_code;
        return self.glyph_id_array[index];
    }
};

pub const Format10 = struct {
    reserved: u16,
    length: u32,
    language: u32,
    start_char_code: u32,
    num_chars: u32,
    glyphs: []u16,

    pub fn deinit(self: *Format10, allocator: Allocator) void {
        allocator.free(self.glyphs);
    }

    pub fn get_glyph_index(self: Format10, codepoint: u32) ?u16 {
        if (codepoint < self.start_char_code or
            codepoint >= self.start_char_code + self.num_chars)
        {
            return null;
        }

        const index = codepoint - self.start_char_code;
        return self.glyphs[index];
    }
};

pub const Format12 = struct {
    reserved: u16,
    length: u32,
    language: u32,
    num_groups: u32,
    groups: []SequentialMapGroup,

    pub const SequentialMapGroup = struct {
        start_char_code: u32,
        end_char_code: u32,
        start_glyph_id: u32,
    };

    pub fn deinit(self: *Format12, allocator: Allocator) void {
        allocator.free(self.groups);
    }

    pub fn get_glyph_index(self: Format12, codepoint: u32) ?u16 {
        var left: usize = 0;
        var right: usize = self.groups.len;

        while (left < right) {
            const mid = (left + right) / 2;
            const group = self.groups[mid];

            if (codepoint < group.start_char_code) {
                right = mid;
            } else if (codepoint > group.end_char_code) {
                left = mid + 1;
            } else {
                const glyph_id = group.start_glyph_id + (codepoint - group.start_char_code);
                return if (glyph_id > 0xFFFF) null else @intCast(glyph_id);
            }
        }

        return null;
    }
};

pub const Format13 = struct {
    reserved: u16,
    length: u32,
    language: u32,
    num_groups: u32,
    groups: []ConstantMapGroup,

    pub const ConstantMapGroup = struct {
        start_char_code: u32,
        end_char_code: u32,
        glyph_id: u32,
    };

    pub fn deinit(self: *Format13, allocator: Allocator) void {
        allocator.free(self.groups);
    }

    pub fn get_glyph_index(self: Format13, codepoint: u32) ?u16 {
        var left: usize = 0;
        var right: usize = self.groups.len;

        while (left < right) {
            const mid = (left + right) / 2;
            const group = self.groups[mid];

            if (codepoint < group.start_char_code) {
                right = mid;
            } else if (codepoint > group.end_char_code) {
                left = mid + 1;
            } else {
                return if (group.glyph_id > 0xFFFF) null else @intCast(group.glyph_id);
            }
        }

        return null;
    }
};

pub const Format14 = struct {
    length: u32,
    num_var_selector_records: u32,
    var_selector_records: []VariationSelector,

    pub const VariationSelector = struct {
        var_selector: u32,
        default_uvs_offset: u32,
        non_default_uvs_offset: u32,
    };

    pub const UnicodeValueRange = struct {
        start_unicode_value: u32,
        additional_count: u8,
    };

    pub const UVSMapping = struct {
        unicode_value: u32,
        glyph_id: u16,
    };

    pub fn deinit(self: *Format14, allocator: Allocator) void {
        allocator.free(self.var_selector_records);
    }

    pub fn get_glyph_index(self: Format14, codepoint: u32) ?u16 {
        _ = self;
        _ = codepoint;
        return null;
    }
};

pub const EncodingRecord = struct {
    platform_id: PlatformID,
    encoding_id: u16,
    subtable_offset: u32,
};

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

version: u16,
num_tables: u16,
encoding_records: []EncodingRecord,
subtables: []CmapFormat,

fn parse(ptr: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(ptr));

    self.version = try self.byte_reader.read_u16_be();
    self.num_tables = try self.byte_reader.read_u16_be();

    var encoding_records = try self.allocator.alloc(EncodingRecord, self.num_tables);
    errdefer self.allocator.free(encoding_records);

    for (0..self.num_tables) |i| {
        const platform_id = PlatformID.from_u16(try self.byte_reader.read_u16_be());
        const encoding_id = try self.byte_reader.read_u16_be();
        const subtable_offset = try self.byte_reader.read_u32_be();

        encoding_records[i] = EncodingRecord{
            .platform_id = platform_id,
            .encoding_id = encoding_id,
            .subtable_offset = subtable_offset,
        };
    }

    var subtables = try self.allocator.alloc(CmapFormat, self.num_tables);
    errdefer {
        for (0..subtables.len) |i| {
            subtables[i].deinit(self.allocator);
        }
        self.allocator.free(subtables);
    }

    const table_start = self.byte_reader.current_offset() - 4 - self.num_tables * 8;

    for (0..self.num_tables) |i| {
        try self.byte_reader.seek_to(table_start + encoding_records[i].subtable_offset);
        subtables[i] = try self.parse_subtable();
    }

    self.encoding_records = encoding_records;
    self.subtables = subtables;
}

fn parse_subtable(self: *Self) !CmapFormat {
    const format = try self.byte_reader.read_u16_be();

    return switch (format) {
        0 => CmapFormat{ .format0 = try self.parse_format0() },
        2 => CmapFormat{ .format2 = try self.parse_format2() },
        4 => CmapFormat{ .format4 = try self.parse_format4() },
        6 => CmapFormat{ .format6 = try self.parse_format6() },
        10 => CmapFormat{ .format10 = try self.parse_format10() },
        12 => CmapFormat{ .format12 = try self.parse_format12() },
        13 => CmapFormat{ .format13 = try self.parse_format13() },
        14 => CmapFormat{ .format14 = try self.parse_format14() },
        else => return Error.UnsupportedCmapFormat,
    };
}

fn parse_format0(self: *Self) !Format0 {
    const length = try self.byte_reader.read_u16_be();
    const language = try self.byte_reader.read_u16_be();

    var glyph_id_array: [256]u8 = undefined;
    for (0..256) |i| {
        glyph_id_array[i] = try self.byte_reader.read_u8();
    }

    return Format0{
        .length = length,
        .language = language,
        .glyph_id_array = glyph_id_array,
    };
}

fn parse_format2(self: *Self) !Format2 {
    const length = try self.byte_reader.read_u16_be();
    const language = try self.byte_reader.read_u16_be();

    var sub_header_keys: [256]u16 = undefined;
    var max_sub_header_index: u16 = 0;

    for (0..256) |i| {
        sub_header_keys[i] = try self.byte_reader.read_u16_be();
        if (sub_header_keys[i] > max_sub_header_index) {
            max_sub_header_index = sub_header_keys[i];
        }
    }

    const num_sub_headers = (max_sub_header_index / 8) + 1;
    var sub_headers = try self.allocator.alloc(Format2.SubHeader, num_sub_headers);
    errdefer self.allocator.free(sub_headers);

    for (0..num_sub_headers) |i| {
        sub_headers[i] = Format2.SubHeader{
            .first_code = try self.byte_reader.read_u16_be(),
            .entry_count = try self.byte_reader.read_u16_be(),
            .id_delta = try self.byte_reader.read_i16_be(),
            .id_range_offset = try self.byte_reader.read_u16_be(),
        };
    }

    const glyph_array_size = (length - 6 - 512 - num_sub_headers * 8) / 2;
    var glyph_index_array = try self.allocator.alloc(u16, glyph_array_size);
    errdefer self.allocator.free(glyph_index_array);

    for (0..glyph_array_size) |i| {
        glyph_index_array[i] = try self.byte_reader.read_u16_be();
    }

    return Format2{
        .length = length,
        .language = language,
        .sub_header_keys = sub_header_keys,
        .sub_headers = sub_headers,
        .glyph_index_array = glyph_index_array,
    };
}

fn parse_format4(self: *Self) !Format4 {
    const length = try self.byte_reader.read_u16_be();
    const language = try self.byte_reader.read_u16_be();
    const seg_count_x2 = try self.byte_reader.read_u16_be();
    const search_range = try self.byte_reader.read_u16_be();
    const entry_selector = try self.byte_reader.read_u16_be();
    const range_shift = try self.byte_reader.read_u16_be();

    const seg_count = seg_count_x2 / 2;

    var end_code = try self.allocator.alloc(u16, seg_count);
    errdefer self.allocator.free(end_code);

    for (0..seg_count) |i| {
        end_code[i] = try self.byte_reader.read_u16_be();
    }

    _ = try self.byte_reader.read_u16_be();

    var start_code = try self.allocator.alloc(u16, seg_count);
    errdefer self.allocator.free(start_code);

    for (0..seg_count) |i| {
        start_code[i] = try self.byte_reader.read_u16_be();
    }

    var id_delta = try self.allocator.alloc(i16, seg_count);
    errdefer self.allocator.free(id_delta);

    for (0..seg_count) |i| {
        id_delta[i] = try self.byte_reader.read_i16_be();
    }

    var id_range_offset = try self.allocator.alloc(u16, seg_count);
    errdefer self.allocator.free(id_range_offset);

    for (0..seg_count) |i| {
        id_range_offset[i] = try self.byte_reader.read_u16_be();
    }

    const glyph_array_size = (length - 16 - seg_count * 8) / 2;
    var glyph_id_array = try self.allocator.alloc(u16, glyph_array_size);
    errdefer self.allocator.free(glyph_id_array);

    for (0..glyph_array_size) |i| {
        glyph_id_array[i] = try self.byte_reader.read_u16_be();
    }

    return Format4{
        .length = length,
        .language = language,
        .seg_count_x2 = seg_count_x2,
        .search_range = search_range,
        .entry_selector = entry_selector,
        .range_shift = range_shift,
        .end_code = end_code,
        .start_code = start_code,
        .id_delta = id_delta,
        .id_range_offset = id_range_offset,
        .glyph_id_array = glyph_id_array,
    };
}

fn parse_format6(self: *Self) !Format6 {
    const length = try self.byte_reader.read_u16_be();
    const language = try self.byte_reader.read_u16_be();
    const first_code = try self.byte_reader.read_u16_be();
    const entry_count = try self.byte_reader.read_u16_be();

    var glyph_id_array = try self.allocator.alloc(u16, entry_count);
    errdefer self.allocator.free(glyph_id_array);

    for (0..entry_count) |i| {
        glyph_id_array[i] = try self.byte_reader.read_u16_be();
    }

    return Format6{
        .length = length,
        .language = language,
        .first_code = first_code,
        .entry_count = entry_count,
        .glyph_id_array = glyph_id_array,
    };
}

fn parse_format10(self: *Self) !Format10 {
    const reserved = try self.byte_reader.read_u16_be();
    const length = try self.byte_reader.read_u32_be();
    const language = try self.byte_reader.read_u32_be();
    const start_char_code = try self.byte_reader.read_u32_be();
    const num_chars = try self.byte_reader.read_u32_be();

    var glyphs = try self.allocator.alloc(u16, num_chars);
    errdefer self.allocator.free(glyphs);

    for (0..num_chars) |i| {
        glyphs[i] = try self.byte_reader.read_u16_be();
    }

    return Format10{
        .reserved = reserved,
        .length = length,
        .language = language,
        .start_char_code = start_char_code,
        .num_chars = num_chars,
        .glyphs = glyphs,
    };
}

fn parse_format12(self: *Self) !Format12 {
    const reserved = try self.byte_reader.read_u16_be();
    const length = try self.byte_reader.read_u32_be();
    const language = try self.byte_reader.read_u32_be();
    const num_groups = try self.byte_reader.read_u32_be();

    var groups = try self.allocator.alloc(Format12.SequentialMapGroup, num_groups);
    errdefer self.allocator.free(groups);

    for (0..num_groups) |i| {
        groups[i] = Format12.SequentialMapGroup{
            .start_char_code = try self.byte_reader.read_u32_be(),
            .end_char_code = try self.byte_reader.read_u32_be(),
            .start_glyph_id = try self.byte_reader.read_u32_be(),
        };
    }

    return Format12{
        .reserved = reserved,
        .length = length,
        .language = language,
        .num_groups = num_groups,
        .groups = groups,
    };
}

fn parse_format13(self: *Self) !Format13 {
    const reserved = try self.byte_reader.read_u16_be();
    const length = try self.byte_reader.read_u32_be();
    const language = try self.byte_reader.read_u32_be();
    const num_groups = try self.byte_reader.read_u32_be();

    var groups = try self.allocator.alloc(Format13.ConstantMapGroup, num_groups);
    errdefer self.allocator.free(groups);

    for (0..num_groups) |i| {
        groups[i] = Format13.ConstantMapGroup{
            .start_char_code = try self.byte_reader.read_u32_be(),
            .end_char_code = try self.byte_reader.read_u32_be(),
            .glyph_id = try self.byte_reader.read_u32_be(),
        };
    }

    return Format13{
        .reserved = reserved,
        .length = length,
        .language = language,
        .num_groups = num_groups,
        .groups = groups,
    };
}

fn parse_format14(self: *Self) !Format14 {
    const length = try self.byte_reader.read_u32_be();
    const num_var_selector_records = try self.byte_reader.read_u32_be();

    var var_selector_records = try self.allocator.alloc(Format14.VariationSelector, num_var_selector_records);
    errdefer self.allocator.free(var_selector_records);

    for (0..num_var_selector_records) |i| {
        const vs_byte1 = try self.byte_reader.read_u8();
        const vs_byte2 = try self.byte_reader.read_u8();
        const vs_byte3 = try self.byte_reader.read_u8();
        const var_selector = (@as(u32, vs_byte1) << 16) | (@as(u32, vs_byte2) << 8) | vs_byte3;

        var_selector_records[i] = Format14.VariationSelector{
            .var_selector = var_selector,
            .default_uvs_offset = try self.byte_reader.read_u32_be(),
            .non_default_uvs_offset = try self.byte_reader.read_u32_be(),
        };
    }

    return Format14{
        .length = length,
        .num_var_selector_records = num_var_selector_records,
        .var_selector_records = var_selector_records,
    };
}

fn deinit(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));

    if (self.encoding_records.len > 0) {
        self.allocator.free(self.encoding_records);
    }

    for (0..self.subtables.len) |i| {
        self.subtables[i].deinit(self.allocator);
    }

    if (self.subtables.len > 0) {
        self.allocator.free(self.subtables);
    }

    self.allocator.destroy(self);
}

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.byte_reader = byte_reader;
    self.parsed_tables = parsed_tables;
    self.version = 0;
    self.num_tables = 0;
    self.encoding_records = &.{};
    self.subtables = &.{};

    return Table{
        .ptr = self,
        .vtable = &.{ .parse = parse, .deinit = deinit },
    };
}

pub fn get_glyph_index(self: *Self, codepoint: u32) ?u16 {
    for (0..self.num_tables) |i| {
        const record = self.encoding_records[i];
        if (record.platform_id == .microsoft and record.encoding_id == 1) {
            return self.subtables[i].get_glyph_index(codepoint);
        }
    }

    for (0..self.num_tables) |i| {
        const record = self.encoding_records[i];
        if (record.platform_id == .microsoft and record.encoding_id == 10) {
            return self.subtables[i].get_glyph_index(codepoint);
        }
    }

    for (0..self.num_tables) |i| {
        const record = self.encoding_records[i];
        if (record.platform_id == .unicode) {
            return self.subtables[i].get_glyph_index(codepoint);
        }
    }

    return null;
}

pub fn get_best_subtable(self: *Self) ?*CmapFormat {
    for (0..self.num_tables) |i| {
        const record = self.encoding_records[i];
        if (record.platform_id == .microsoft and record.encoding_id == 1) {
            return &self.subtables[i];
        }
    }

    for (0..self.num_tables) |i| {
        const record = self.encoding_records[i];
        if (record.platform_id == .microsoft and record.encoding_id == 10) {
            return &self.subtables[i];
        }
    }

    for (0..self.num_tables) |i| {
        const record = self.encoding_records[i];
        if (record.platform_id == .unicode) {
            return &self.subtables[i];
        }
    }

    return null;
}
