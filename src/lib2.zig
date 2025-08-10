const std = @import("std");
pub const parser = @import("parser.zig");
pub const table = @import("table/mod.zig");
const byte_writer = @import("byte_writer.zig");
const Table = table.Table;

const Allocator = std.mem.Allocator;

const Parser = parser.Parser;

const Writer = byte_writer.ByteWriter;

const AutoHashMap = std.AutoHashMap;

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
            .r = null,
            .s = null,
        };
    }

    pub fn reader(self: *Self) !*Reader {
        if (self.r) |r| {
            return @constCast(r);
        }
        const r = try self.allocator.create(Reader);
        r.* = Reader.init(self);
        errdefer self.allocator.destroy(r);
        self.r = r;
        return r;
    }

    pub fn subsetter(self: *Self) !*Subsetter {
        if (self.s) |s| {
            return @constCast(s);
        }
        const s = try self.allocator.create(Subsetter);
        s.* = try Subsetter.init(self);
        errdefer self.allocator.destroy(s);
        self.s = s;
        return s;
    }

    pub fn deinit(self: *Self) void {
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

pub const BoundingBox = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,

    pub fn empty() BoundingBox {
        return BoundingBox{
            .x_min = 0,
            .y_min = 0,
            .x_max = 0,
            .y_max = 0,
        };
    }

    pub fn width(self: BoundingBox) u16 {
        return @intCast(self.x_max - self.x_min);
    }

    pub fn height(self: BoundingBox) u16 {
        return @intCast(self.y_max - self.y_min);
    }
};

pub const Glyph = struct {
    id: u16 = 0,
    advance_width: u16 = 0,
    left_side_bearing: i16 = 0,
    data: []const u8 = &[_]u8{},
    bbox: BoundingBox = BoundingBox.empty(),
    has_outline: bool = false,
    _initialized: bool = false,

    pub fn is_empty(self: *const Glyph) bool {
        return !self._initialized;
    }

    pub fn mark_as_done(self: *Glyph) void {
        self._initialized = true;
    }
};

const Reader = struct {
    const Self = @This();

    t: *ttf,
    allocator: Allocator,
    glyph_cache: AutoHashMap(u32, Glyph),

    pub fn init(t: *ttf) Reader {
        return Self{
            .t = t,
            .allocator = t.allocator,
            .glyph_cache = AutoHashMap(u32, Glyph).init(t.allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.glyph_cache.deinit();
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

    pub fn get_glyph_id(self: *Self, code_point: u32) !u16 {
        if (self.glyph_cache.get(code_point)) |glyph| {
            return glyph.id;
        }
        const cmap_table = self.t.parser.parsed_tables.cmap.?;
        const cmap = cmap_table.cast(table.Cmap);
        const gid = cmap.get_glyph_index(code_point).?;
        try self.glyph_cache.put(code_point, Glyph{
            .id = gid,
        });
        return gid;
    }

    pub fn get_glyph_info(self: *Self, code_point: u32) !Glyph {
        if (self.glyph_cache.get(code_point)) |glyph| {
            if (!glyph.is_empty()) {
                return glyph;
            }
        }

        const gid = try self.get_glyph_id(code_point);

        const hmtx_table = self.t.parser.parsed_tables.hmtx.?;
        const hmtx = hmtx_table.cast(table.Hmtx);
        const metrics = hmtx.get_metrics(gid);

        const bbox = blk: {
            const loca_table = self.t.parser.parsed_tables.loca.?;
            const loca = loca_table.cast(table.Loca);
            const glyf_table = self.t.parser.parsed_tables.glyf.?;
            const glyf = glyf_table.cast(table.Glyf);
            const offset = loca.get_glyph_offset(gid).?;
            const parsed_glyf = try glyf.parse_glyph(offset);
            defer parsed_glyf.deinit();
            const header = parsed_glyf.get_header();
            break :blk BoundingBox{
                .x_min = header.x_min,
                .y_min = header.y_min,
                .x_max = header.x_max,
                .y_max = header.y_max,
            };
        };

        const has_outline = blk: {
            const loca_table = self.t.parser.parsed_tables.loca.?;
            const loca = loca_table.cast(table.Loca);
            break :blk loca.has_glyph_data(gid);
        };
        var glyh = Glyph{
            .id = gid,
            .advance_width = metrics.advance_width,
            .left_side_bearing = metrics.left_side_bearing,
            .has_outline = has_outline,
            .bbox = bbox,
        };
        glyh.mark_as_done();
        try self.glyph_cache.put(code_point, glyh);

        return glyh;
    }
};

const Subsetter = struct {
    t: *ttf,
    r: *Reader,
    allocator: Allocator,
    const Self = @This();

    pub fn init(t: *ttf) Subsetter {
        return Self{
            .t = t,
            .allocator = t.allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        _ = self; // autofix

    }

    pub fn build_subset(self: *Self) ![]u8 {
        var buffer = Writer(u8).init(self.allocator);
        errdefer buffer.deinit();
    }
};

test "ttf.zig" {
    const fs = std.fs;
    const allocator = std.testing.allocator;
    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "sub5.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);
    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);
    var font = try ttf.init(allocator, file_content);
    defer font.deinit();
    var reader = try font.reader();
    const code_point: u32 = 'a';
    const e = try reader.get_glyph_info(code_point);
    std.debug.print("glyph: {any}\n", .{e});
}
