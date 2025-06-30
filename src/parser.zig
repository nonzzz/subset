const std = @import("std");
const reader = @import("./byte_read.zig");
const table = @import("./table/mod.zig");
const Table = @import("./table.zig");

const fs = std.fs;
const Allocator = std.mem.Allocator;

// https://learn.microsoft.com/en-us/typography/opentype/spec/otff#required-tables
pub const TableTag = enum(u32) {
    // Required tables
    cmap = std.mem.readInt(u32, "cmap", .big),
    head = std.mem.readInt(u32, "head", .big),
    hhea = std.mem.readInt(u32, "hhea", .big),
    hmtx = std.mem.readInt(u32, "hmtx", .big),
    maxp = std.mem.readInt(u32, "maxp", .big),
    name = std.mem.readInt(u32, "name", .big),
    os2 = std.mem.readInt(u32, "OS/2", .big),
    post = std.mem.readInt(u32, "post", .big),

    // TTF
    cvt = std.mem.readInt(u32, "cvt ", .big),
    fpgm = std.mem.readInt(u32, "fpgm", .big),
    glyf = std.mem.readInt(u32, "glyf", .big),
    loca = std.mem.readInt(u32, "loca", .big),
    prep = std.mem.readInt(u32, "prep", .big),
    gasp = std.mem.readInt(u32, "gasp", .big),

    // OTF
    cff = std.mem.readInt(u32, "CFF ", .big),
    CFF2 = std.mem.readInt(u32, "CFF2", .big),
    vorg = std.mem.readInt(u32, "VORG", .big),

    gsub = std.mem.readInt(u32, "GSUB", .big),
    gpos = std.mem.readInt(u32, "GPOS", .big),
    gdef = std.mem.readInt(u32, "GDEF", .big),

    // unknow or unsupported tags can be added here
    _,
    pub inline fn from_bytes(bytes: [4]u8) TableTag {
        const value = std.mem.readInt(u32, &bytes, .big);
        return @enumFromInt(value);
    }

    pub inline fn to_str(self: TableTag) [4]u8 {
        const value = @intFromEnum(self);
        var result: [4]u8 = undefined;
        std.mem.writeInt(u32, &result, value, .big);
        return result;
    }

    pub inline fn is_required(self: TableTag) bool {
        return switch (self) {
            .cmap, .head, .hhea, .hmtx, .maxp, .name, .os2, .post => true,
            else => false,
        };
    }

    pub inline fn is_glyph_data(self: TableTag) bool {
        return switch (self) {
            .glyf, .loca, .cvt, .fpgm, .prep => true,
            else => false,
        };
    }

    pub inline fn get_required_deps(self: TableTag) []const TableTag {
        return switch (self) {
            .head, .hhea, .maxp, .cmap, .name, .os2, .post => &.{},
            .hmtx => &.{ .hhea, .maxp },
            .loca => &.{ .head, .maxp },
            .glyf => &.{ .head, .maxp, .loca },
            else => &.{},
        };
    }

    pub inline fn to_tag_bit(self: TableTag) u64 {
        const bit_pos: u6 = switch (self) {
            .head => 0,
            .hhea => 1,
            .maxp => 2,
            .cmap => 3,
            .name => 4,
            .os2 => 5,
            .post => 6,
            .hmtx => 7,
            .loca => 8,
            .glyf => 9,
            else => @intCast((@intFromEnum(self) % 54) + 10),
        };
        return @as(u64, 1) << bit_pos;
    }
};

pub const ParsedTables = struct {
    const Self = @This();
    head: ?Table = null,
    hhea: ?Table = null,
    maxp: ?Table = null,
    os2: ?Table = null,
    post: ?Table = null,
    name: ?Table = null,
    hmtx: ?Table = null,
    cmap: ?Table = null,

    pub inline fn is_parsed(self: *Self, tag: TableTag) bool {
        return switch (tag) {
            .head => self.head != null,
            .hhea => self.hhea != null,
            .maxp => self.maxp != null,
            .os2 => self.os2 != null,
            .post => self.post != null,
            .name => self.name != null,
            .hmtx => self.hmtx != null,
            .cmap => self.cmap != null,
            else => false,
        };
    }

    pub fn deinit(self: *Self) void {
        inline for (std.meta.fields(Self)) |field| {
            if (field.type == ?Table) {
                if (@field(self, field.name)) |tab| {
                    tab.deinit();
                }
            }
        }
    }

    pub fn get_head(self: *const Self) ?*table.head.HeadTable {
        if (self.head) |head_table| {
            return head_table.cast(table.head.HeadTable);
        }
        return null;
    }

    pub fn get_hhea(self: *const Self) ?*table.hhea.HheaTable {
        if (self.hhea) |hhea_table| {
            return hhea_table.cast(table.hhea.HheaTable);
        }
        return null;
    }

    pub fn get_maxp(self: *const Self) ?*table.maxp.MaxpTable {
        if (self.maxp) |maxp_table| {
            return maxp_table.cast(table.maxp.MaxpTable);
        }
        return null;
    }

    pub fn get_os2(self: *const Self) ?*table.os2.Os2Table {
        if (self.os2) |os2_table| {
            return os2_table.cast(table.os2.Os2Table);
        }
        return null;
    }
    pub fn get_post(self: *const Self) ?*table.post.PostTable {
        if (self.post) |post_table| {
            return post_table.cast(table.post.PostTable);
        }
        return null;
    }

    pub fn get_name(self: *const Self) ?*table.name.NameTable {
        if (self.name) |name_table| {
            return name_table.cast(table.name.NameTable);
        }
        return null;
    }
};

pub const TableRecord = struct {
    tag: TableTag,
    checksum: u32,
    offset: u32,
    length: u32,
};

pub const Parser = struct {
    const Self = @This();
    buffer: []const u8,
    allocator: Allocator,
    reader: reader.ByteReader,

    table_records: std.ArrayList(TableRecord),
    parsed_tables: ParsedTables,

    parsing_flags: u64 = 0,
    parsed_flags: u64 = 0,

    pub const Error = error{
        InvalidInputBuffer,
        MissingRequiredDependency,
        CircularDependency,
    };

    pub fn init(allocator: Allocator, buffer: []const u8) !Self {
        return Self{
            .buffer = buffer,
            .allocator = allocator,
            .reader = reader.ByteReader.init(buffer),
            .parsed_tables = ParsedTables{},
            .table_records = std.ArrayList(TableRecord).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.table_records.deinit();
        self.parsed_tables.deinit();
    }

    pub fn parse(self: *Self) !void {
        _ = try self.reader.read_u32_be();
        const num_tables = try self.reader.read_u16_be();
        try self.reader.skip(6);
        try self.table_records.ensureTotalCapacity(num_tables);
        for (0..num_tables) |_| {
            const tag_bytes = try self.reader.read_tag();
            const tag = TableTag.from_bytes(tag_bytes);
            const checksum = try self.reader.read_u32_be();
            const offset = try self.reader.read_u32_be();
            const length = try self.reader.read_u32_be();

            self.table_records.appendAssumeCapacity(TableRecord{
                .tag = tag,
                .checksum = checksum,
                .offset = offset,
                .length = length,
            });
        }

        try self.parse_tables();
    }

    fn parse_tables(self: *Self) !void {
        for (self.table_records.items) |record| {
            if (!self.parsed_tables.is_parsed(record.tag)) {
                try self.parse_table_recursive(record.tag);
            }
        }
    }

    fn parse_table(self: *Self, tag: TableTag, record: TableRecord) !void {
        try self.reader.seek_to(record.offset);

        switch (tag) {
            .cmap => {
                var cmap_table = try table.cmap.init(self.allocator, &self.reader, &self.parsed_tables);
                try cmap_table.parse();
                self.parsed_tables.cmap = cmap_table;
            },
            .head => {
                var head_table = try table.head.init(self.allocator, &self.reader, &self.parsed_tables);
                try head_table.parse();
                self.parsed_tables.head = head_table;
            },
            .hhea => {
                var hhea_table = try table.hhea.init(self.allocator, &self.reader, &self.parsed_tables);
                try hhea_table.parse();
                self.parsed_tables.hhea = hhea_table;
            },
            .maxp => {
                var maxp_table = try table.maxp.init(self.allocator, &self.reader, &self.parsed_tables);
                try maxp_table.parse();
                self.parsed_tables.maxp = maxp_table;
            },
            .name => {
                var name_table = try table.name.init(self.allocator, &self.reader, &self.parsed_tables);
                try name_table.parse();
                self.parsed_tables.name = name_table;
            },
            .os2 => {
                var os2_table = try table.os2.init(self.allocator, &self.reader, &self.parsed_tables);
                try os2_table.parse();
                self.parsed_tables.os2 = os2_table;
            },
            .post => {
                var post_table = try table.post.init(self.allocator, &self.reader, &self.parsed_tables);
                try post_table.parse();
                self.parsed_tables.post = post_table;
            },
            .hmtx => {
                var hmtx_table = try table.hmtx.init(self.allocator, &self.reader, &self.parsed_tables);
                try hmtx_table.parse();
                self.parsed_tables.hmtx = hmtx_table;
            },
            else => {
                // TODO: Implement parsing for other tables
            },
        }
    }

    fn parse_table_recursive(self: *Self, tag: TableTag) !void {
        const tag_bit = tag.to_tag_bit();

        if (self.parsed_flags & tag_bit != 0) return;
        if (self.parsing_flags & tag_bit != 0) return error.CircularDependency;
        self.parsing_flags |= tag_bit;

        defer {
            self.parsing_flags &= ~tag_bit;
        }

        const deps = tag.get_required_deps();

        for (deps) |dep_tag| {
            const dep_record = self.find_table_record(dep_tag);
            if (dep_record == null) {
                if (dep_tag.is_required()) {
                    return error.MissingRequiredDependency;
                }
                continue;
            }
            try self.parse_table_recursive(dep_tag);
        }
        if (self.find_table_record(tag)) |record| {
            try self.parse_table(tag, record);
        }
        self.parsed_flags |= tag_bit;
    }

    inline fn find_table_record(self: *Self, tag: TableTag) ?TableRecord {
        for (self.table_records.items) |record| {
            if (record.tag == tag) return record;
        }
        return null;
    }
};

test "Parser" {
    const allocator = std.testing.allocator;
    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "sub5.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);
    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);
    var parser = try Parser.init(allocator, file_content);
    defer parser.deinit();
    try parser.parse();

    if (parser.parsed_tables.get_head()) |head_data| {
        std.debug.print("Head table version: {}.{}\n", .{ head_data.major_version, head_data.minor_version });
        std.debug.print("Units per EM: {}\n", .{head_data.units_per_em});
    }

    if (parser.parsed_tables.get_maxp()) |maxp_data| {
        std.debug.print("MAXP version: 0x{X}\n", .{maxp_data.version});
        std.debug.print("Number of glyphs: {}\n", .{maxp_data.num_glyphs});
        std.debug.print("Is TTF: {}\n", .{maxp_data.is_ttf()});
        std.debug.print("Is CFF: {}\n", .{maxp_data.is_cff()});
    }

    if (parser.parsed_tables.get_hhea()) |hhea_data| {
        std.debug.print("HHEA ascender: {}\n", .{hhea_data.ascender});
        std.debug.print("HHEA descender: {}\n", .{hhea_data.descender});
        std.debug.print("Number of HMetrics: {}\n", .{hhea_data.number_of_hmetrics});
    }

    if (parser.parsed_tables.get_name()) |name_table| {
        std.debug.print("Name table version: {}\n", .{name_table.version});
        std.debug.print("Number of name records: {}\n", .{name_table.count});
        for (name_table.name_records) |record| {
            std.debug.print("Name Record: platform_id: {}, encoding_id: {}, language_id: {}, name_id: {}, length: {}, offset: {}\n", .{
                record.platform_id,
                record.encoding_id,
                record.language_id,
                record.name_id,
                record.length,
                record.string_offset,
            });
            std.debug.print("{s}\n", .{name_table.get_by_name_id(record.name_id) orelse "N/A"});
        }
    }
}
