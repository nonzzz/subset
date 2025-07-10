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

    // TTF
    loca: ?Table = null,
    glyf: ?Table = null,

    pub inline fn is_parsed(self: *Self, tag: TableTag) bool {
        inline for (std.meta.fields(Self)) |field| {
            if (field.type == ?Table) {
                if (@field(TableTag, field.name) == tag) {
                    return @field(self, field.name) != null;
                }
            }
        }
        return false;
    }

    pub inline fn get_table(self: *Self, tag: TableTag) ?Table {
        inline for (std.meta.fields(Self)) |field| {
            if (field.type == ?Table) {
                if (@field(TableTag, field.name) == tag) {
                    return @field(self, field.name);
                }
            }
        }
        return null;
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
    reader: *reader.ByteReader,

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
        const byte_reader = try allocator.create(reader.ByteReader);
        byte_reader.* = reader.ByteReader.init(buffer);

        return Self{
            .buffer = buffer,
            .allocator = allocator,
            .reader = byte_reader,
            .parsed_tables = ParsedTables{},
            .table_records = std.ArrayList(TableRecord).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.table_records.deinit();
        self.parsed_tables.deinit();
        self.allocator.destroy(self.reader);
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

    // Normally glyf tables should not be fully parsed.
    fn parse_table(self: *Self, tag: TableTag, record: TableRecord) !void {
        try self.reader.seek_to(record.offset);

        switch (tag) {
            .cmap => {
                var cmap_table = try table.Cmap.init(self.allocator, self.reader, &self.parsed_tables);
                try cmap_table.parse();
                self.parsed_tables.cmap = cmap_table;
            },
            .head => {
                var head_table = try table.Head.init(self.allocator, self.reader, &self.parsed_tables);
                try head_table.parse();
                self.parsed_tables.head = head_table;
            },
            .hhea => {
                var hhea_table = try table.Hhea.init(self.allocator, self.reader, &self.parsed_tables);
                try hhea_table.parse();
                self.parsed_tables.hhea = hhea_table;
            },
            .maxp => {
                var maxp_table = try table.Maxp.init(self.allocator, self.reader, &self.parsed_tables);
                try maxp_table.parse();
                self.parsed_tables.maxp = maxp_table;
            },
            .name => {
                var name_table = try table.Name.init(self.allocator, self.reader, &self.parsed_tables);
                try name_table.parse();
                self.parsed_tables.name = name_table;
            },
            .os2 => {
                var os2_table = try table.Os2.init(self.allocator, self.reader, &self.parsed_tables);
                try os2_table.parse();
                self.parsed_tables.os2 = os2_table;
            },
            .post => {
                var post_table = try table.Post.init(self.allocator, self.reader, &self.parsed_tables);
                try post_table.parse();
                self.parsed_tables.post = post_table;
            },
            .hmtx => {
                var hmtx_table = try table.Hmtx.init(self.allocator, self.reader, &self.parsed_tables);
                try hmtx_table.parse();
                self.parsed_tables.hmtx = hmtx_table;
            },
            .loca => {
                var loca_table = try table.Loca.init(self.allocator, self.reader, &self.parsed_tables);
                try loca_table.parse();
                self.parsed_tables.loca = loca_table;
            },
            .glyf => {
                var glyf_table = try table.Glyf.init(self.allocator, self.reader, &self.parsed_tables);
                try glyf_table.parse();
                self.parsed_tables.glyf = glyf_table;
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
    try std.testing.expect(true);
}
