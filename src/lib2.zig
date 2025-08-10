const std = @import("std");
pub const parser = @import("parser.zig");
pub const table = @import("table/mod.zig");
const byte_writer = @import("byte_writer.zig");
const Table = table.Table;

const Allocator = std.mem.Allocator;

const Parser = parser.Parser;

const Writer = byte_writer.ByteWriter;

pub const ttf = struct {
    const Self = @This();
    allocator: Allocator,
    parser: Parser,
    r: ?*Reader,
    s: ?*Subsetter,

    pub fn init(allocator: Allocator, font_data: []const u8) !Self {
        var p = try Parser.init(allocator, font_data);
        try p.parse();
        return Self{
            .allocator = allocator,
            .parser = p,
            .reader = null,
            .subsetter = null,
        };
    }

    pub fn reader(self: *Self) !*Reader {
        if (self.r) |r| {
            return r;
        }
        const r = try self.allocator.create(Reader);
        r.* = Reader.init(self);
        errdefer self.allocator.destroy(r);
        self.r = r;
        return r;
    }

    pub fn subsetter(self: *Self) !*Subsetter {
        if (self.s) |s| {
            return s;
        }
        const s = try self.allocator.create(Subsetter);
        s.* = try Subsetter.init(self);
        errdefer self.allocator.destroy(s);
        self.s = s;
        return s;
    }

    pub fn deinit(self: Self) void {
        if (self.r) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }

        if (self.s) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.parser.deinit();
    }
};

pub const FontMetrics = packed struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    advance_width_max: u16,
    units_per_em: u16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

const Reader = struct {
    t: *ttf,
    allocator: Allocator,
    const Self = @This();

    pub fn init(t: *ttf) Reader {
        return Reader{
            .t = t,
            .allocator = t.allocator,
        };
    }

    pub fn get_num_glyphs(self: *Self) u16 {
        const maxp_table = self.t.parser.parsed_tables.maxp.?;
        const maxp = maxp_table.cast(table.Maxp);
        return maxp.num_glyphs;
    }

    pub fn is_monospace(self: *Self) bool {
        const post_table = self.t.parser.parsed_tables.post.?;
        const post = post_table.cast(table.Post);
        return post.is_monospace();
    }

    pub fn get_font_name(self: *Self, name_id: u16) ?[]const u8 {
        const name_table = self.t.parser.parsed_tables.name.?;
        const name = name_table.cast(table.Name);
        return name.get_by_name_id(name_id);
    }

    pub fn get_font_metrics(self: *Self) FontMetrics {
        const hhead_table = self.t.parser.parsed_tables.hhea.?;
        const hhead = hhead_table.cast(table.Hhea);
        const head_table = self.t.parser.parsed_tables.head.?;
        const head = head_table.cast(table.Head);
        return FontMetrics{
            .ascender = hhead.ascender,
            .descender = hhead.descender,
            .line_gap = hhead.line_gap,
            .advance_width_max = hhead.advance_width_max,
            .units_per_em = head.units_per_em,
            .x_min = head.x_min,
            .y_min = head.y_min,
            .x_max = head.x_max,
            .y_max = head.y_max,
        };
    }
};

const Subsetter = struct {
    t: *ttf,
    r: *Reader,
    allocator: Allocator,
    const Self = @This();

    pub fn init(t: *ttf) Subsetter {
        return Subsetter{
            .t = t,
            .allocator = t.allocator,
        };
    }
    pub fn deinit(self: *Subsetter) void {
        _ = self; // autofix

    }

    pub fn build_subset(self: *Self) ![]u8 {
        var buffer = Writer(u8).init(self.allocator);
        errdefer buffer.deinit();
    }
};
