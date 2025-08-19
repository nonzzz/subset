const std = @import("std");
pub const parser = @import("parser.zig");
pub const table = @import("table/mod.zig");
const byte_writer = @import("byte_writer.zig");
const Table = table.Table;

const Allocator = std.mem.Allocator;

const Parser = parser.Parser;

const UTF8 = std.unicode.Utf8View;

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

const GlyphInfo = struct {
    bbox: BoundingBox,
    is_composite: bool,
};

pub const Glyph = struct {
    id: u16 = 0,
    advance_width: u16 = 0,
    left_side_bearing: i16 = 0,
    is_composite: bool = false,
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

pub const BuildSubsetterOptions = struct {
    modified_time: ?i64 = null,
    input_text: []const u8 = &[_]u8{},
};

const Reader = struct {
    const Self = @This();

    t: *ttf,
    allocator: Allocator,
    code_point_cache: AutoHashMap(u32, []u16),
    glyph_cache: AutoHashMap(u16, Glyph),

    pub fn init(t: *ttf) Reader {
        return Self{
            .t = t,
            .allocator = t.allocator,
            .code_point_cache = AutoHashMap(u32, []u16).init(t.allocator),
            .glyph_cache = AutoHashMap(u16, Glyph).init(t.allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var code_point_iter = self.code_point_cache.iterator();
        while (code_point_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.code_point_cache.deinit();
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

    pub fn get_glyph_ids_by_code_point(self: *Self, code_point: u32) ![]u16 {
        if (self.code_point_cache.get(code_point)) |glyph_ids| {
            return glyph_ids;
        }

        const cmap_table = self.t.parser.parsed_tables.cmap.?;
        const cmap = cmap_table.cast(table.Cmap);
        const gid = cmap.get_glyph_index(code_point).?;

        const main_glyph = try self.get_glyph_info(gid);

        var glyph_ids = std.ArrayList(u16).init(self.allocator);
        errdefer glyph_ids.deinit();

        try glyph_ids.append(gid);

        if (main_glyph.is_composite) {
            try self.collect_composite_glyph_ids(gid, &glyph_ids);
        }

        const result = try glyph_ids.toOwnedSlice();
        try self.code_point_cache.put(code_point, result);
        return result;
    }

    pub fn get_glyph_info(self: *Self, gid: u16) !Glyph {
        if (self.glyph_cache.get(gid)) |glyph| {
            return glyph;
        }

        const hmtx_table = self.t.parser.parsed_tables.hmtx.?;
        const hmtx = hmtx_table.cast(table.Hmtx);
        const metrics = hmtx.get_metrics(gid);

        const loca_table = self.t.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);
        const has_outline = loca.has_glyph_data(gid);

        const glyph_info = if (has_outline) info: {
            const glyf_table = self.t.parser.parsed_tables.glyf.?;
            const glyf = glyf_table.cast(table.Glyf);
            const offset = loca.get_glyph_offset(gid).?;
            const parsed_glyf = try glyf.parse_glyph(offset);
            defer parsed_glyf.deinit();
            const header = parsed_glyf.get_header();
            const bbox = BoundingBox{
                .x_min = header.x_min,
                .y_min = header.y_min,
                .x_max = header.x_max,
                .y_max = header.y_max,
            };
            const is_composite = header.is_composite();
            break :info GlyphInfo{
                .bbox = bbox,
                .is_composite = is_composite,
            };
        } else GlyphInfo{
            .bbox = BoundingBox.empty(),
            .is_composite = false,
        };
        var glyph = Glyph{
            .id = gid,
            .advance_width = metrics.advance_width,
            .left_side_bearing = metrics.left_side_bearing,
            .has_outline = has_outline,
            .bbox = glyph_info.bbox,
            .is_composite = glyph_info.is_composite,
        };
        glyph.mark_as_done();

        try self.glyph_cache.put(gid, glyph);

        return glyph;
    }

    fn collect_composite_glyph_ids(self: *Self, gid: u16, glyph_ids: *std.ArrayList(u16)) !void {
        const glyf_table = self.t.parser.parsed_tables.glyf.?;
        const glyf = glyf_table.cast(table.Glyf);
        const loca_table = self.t.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);

        const glyph_offset = loca.get_glyph_offset(gid).?;
        var parsed_glyph = try glyf.parse_glyph(glyph_offset);
        defer parsed_glyph.deinit();

        switch (parsed_glyph) {
            .simple => {},
            .composite => |composite_glyph| {
                for (composite_glyph.components) |component| {
                    const component_gid = component.glyph_index;

                    var already_exists = false;
                    for (glyph_ids.items) |existing_gid| {
                        if (existing_gid == component_gid) {
                            already_exists = true;
                            break;
                        }
                    }

                    if (!already_exists) {
                        try glyph_ids.append(component_gid);

                        const component_glyph = try self.get_glyph_info(component_gid);
                        if (component_glyph.is_composite) {
                            try self.collect_composite_glyph_ids(component_gid, glyph_ids);
                        }
                    }
                }
            },
        }
    }
};

const Subsetter = struct {
    t: *ttf,
    r: *Reader,
    allocator: Allocator,
    const Self = @This();

    pub fn init(t: *ttf) !Subsetter {
        return Self{
            .t = t,
            .r = try t.reader(),
            .allocator = t.allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        _ = self; // autofix

    }

    pub fn build_subset(self: *Self, options: BuildSubsetterOptions) !void {
        var buffer = Writer(u8).init(self.allocator);
        errdefer buffer.deinit();
        var required_glyphs = AutoHashMap(u16, Glyph).init(self.allocator);
        defer required_glyphs.deinit();

        const notdef_glyph = try self.r.get_glyph_info(0);
        try required_glyphs.put(0, notdef_glyph);

        var utf8_view = try UTF8.init(options.input_text);
        var iterator = utf8_view.iterator();

        while (iterator.nextCodepoint()) |codepoint| {
            const glyph_ids = try self.r.get_glyph_ids_by_code_point(codepoint);

            for (glyph_ids) |gid| {
                if (!required_glyphs.contains(gid)) {
                    const glyph = try self.r.get_glyph_info(gid);
                    try required_glyphs.put(gid, glyph);
                }
            }
        }

        var glyph_ids = try self.allocator.alloc(u16, required_glyphs.count());
        defer self.allocator.free(glyph_ids);

        var iter = required_glyphs.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            glyph_ids[i] = entry.key_ptr.*;
            i += 1;
        }
        std.sort.heap(u16, glyph_ids, {}, std.sort.asc(u16));

        // const b = try self.build_post_table(glyph_ids);
        // defer self.allocator.free(b);
    }

    fn get_default_binary_data(self: *Self, tag: parser.TableTag, end_position: ?usize) []const u8 {
        const record = self.t.parser.find_table_record(tag).?;
        const len = if (end_position) |pos| record.offset + pos else record.offset + record.length;
        const table_data = self.t.parser.buffer[record.offset..len];
        return table_data;
    }

    fn build_name_table(self: *Self) []const u8 {
        return self.get_default_binary_data(.name, null);
    }

    // fn build_post_table(self: *Self, glyph_ids: []u16) ![]u8 {
    //     var post_table = self.t.parser.parsed_tables.post.?;
    //     const post = post_table.cast(table.Post);

    //     var buffer = Writer(u8).init(self.allocator);

    //     errdefer buffer.deinit();

    //     // const table_data = self.get_default_binary_data(.post, 32);

    //     // try buffer.write_bytes(table_data);

    //     if (post.v2_data) |_| {
    //         try buffer.write(u16, @intCast(glyph_ids.len), .big);

    //         // var has_custom_names = false;
    //         // for (glyph_ids) |glyph_id| {
    //         //     if (post.get_glyph_index(glyph_id)) |glyph_index| {
    //         //         try buffer.write(u16, glyph_index, .big);
    //         //         if (glyph_index >= 258) {
    //         //             has_custom_names = true;
    //         //         }
    //         //     }
    //         // }
    //         // if (has_custom_names) {
    //         //     for (glyph_ids) |glyph_id| {
    //         //         if (post.get_glyph_index(glyph_id)) |glyph_index| {
    //         //             if (glyph_index >= 258) {
    //         //                 if (post.get_glyph_name(glyph_id)) |glyph_name| {
    //         //                     try buffer.write_u8(@intCast(glyph_name.len));
    //         //                     try buffer.write_bytes(glyph_name);
    //         //                 }
    //         //             }
    //         //         }
    //         //     }
    //         // }
    //         // var has_custom_names = false;
    //         // _ = has_custom_names; // autofix

    //         // for (glyph_ids) |glyph_id| {
    //         //     _ = glyph_id; // autofix
    //         //     //
    //         // }
    //         // std.debug.print("{any}\n", .{post.v2_data.?});
    //     }

    //     return buffer.to_owned_slice();
    // }
};

test "ttf.zig" {
    const fs = std.fs;
    const allocator = std.testing.allocator;
    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "Caveat-VariableFont_wght.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);
    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);
    var font = try ttf.init(allocator, file_content);
    defer font.deinit();
    var subbsetter = try font.subsetter();
    const input_text = &[_]u8{ 0xC5, 0x84 };
    std.debug.print("{s}\n", .{input_text});
    try subbsetter.build_subset(BuildSubsetterOptions{ .input_text = input_text });
    // var reader = try font.reader();
    // const code_point: u32 = 'a';
    // const e = try reader.get_glyph_info(code_point);
    // std.debug.print("glyph: {any}\n", .{e});
}
