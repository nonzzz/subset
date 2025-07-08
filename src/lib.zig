const std = @import("std");
const mod = @import("./parser.zig");
const table = @import("./table/mod.zig");
const Table = @import("./table.zig");

const Parser = mod.Parser;
const TableTag = mod.TableTag;
const fs = std.fs;
const Allocator = std.mem.Allocator;

pub const GlyphInfo = struct {
    glyph_id: u16,
    codepoint: u32,
    advance_width: u16,
    left_side_bearing: i16,
    has_outline: bool,
};

pub const FontMetrics = struct {
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

pub const Subset = struct {
    const Self = @This();

    allocator: Allocator,
    parser: Parser,

    glyph_cache: std.HashMap(u32, u16, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),

    selected_glyphs: std.HashMap(u16, void, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage),

    glyph_info_cache: std.HashMap(u16, GlyphInfo, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage),

    font_metrics: ?FontMetrics = null,

    pub fn init(allocator: Allocator, font_data: []const u8) !Self {
        var parser = try Parser.init(allocator, font_data);
        try parser.parse();

        return Self{
            .allocator = allocator,
            .parser = parser,
            .glyph_cache = std.HashMap(u32, u16, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .selected_glyphs = std.HashMap(u16, void, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage).init(allocator),
            .glyph_info_cache = std.HashMap(u16, GlyphInfo, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.glyph_cache.deinit();
        self.selected_glyphs.deinit();
        self.glyph_info_cache.deinit();
        self.parser.deinit();
    }

    pub fn add_text(self: *Self, text: []const u8) !void {
        var utf8_view = std.unicode.Utf8View.init(text) catch return;
        var iterator = utf8_view.iterator();

        while (iterator.nextCodepoint()) |codepoint| {
            try self.add_character(codepoint);
        }
    }

    pub fn add_character(self: *Self, codepoint: u32) !void {
        const glyph_id = try self.get_glyph_id(codepoint);
        if (glyph_id != 0) {
            try self.selected_glyphs.put(glyph_id, {});
        }
    }

    pub fn get_glyph_id(self: *Self, codepoint: u32) !u16 {
        if (self.glyph_cache.get(codepoint)) |glyph_id| {
            return glyph_id;
        }

        const cmap_table = self.parser.parsed_tables.cmap orelse return 0;
        const cmap = cmap_table.cast(table.Cmap);
        const glyph_id = cmap.get_glyph_index(codepoint) orelse 0;

        try self.glyph_cache.put(codepoint, glyph_id);
        return glyph_id;
    }

    pub fn get_glyph_info(self: *Self, glyph_id: u16) !?GlyphInfo {
        if (self.glyph_info_cache.get(glyph_id)) |info| {
            return info;
        }

        var codepoint: u32 = 0;
        var iterator = self.glyph_cache.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == glyph_id) {
                codepoint = entry.key_ptr.*;
                break;
            }
        }

        const hmtx_table = self.parser.parsed_tables.hmtx orelse return null;
        const hmtx = hmtx_table.cast(table.Hmtx);
        const metrics = hmtx.get_metrics(glyph_id);

        var has_outline = false;
        if (self.parser.parsed_tables.loca) |loca_table| {
            const loca = loca_table.cast(table.Loca);
            has_outline = loca.has_glyph_data(glyph_id);
        }

        const info = GlyphInfo{
            .glyph_id = glyph_id,
            .codepoint = codepoint,
            .advance_width = metrics.advance_width,
            .left_side_bearing = metrics.left_side_bearing,
            .has_outline = has_outline,
        };

        try self.glyph_info_cache.put(glyph_id, info);
        return info;
    }

    pub fn get_font_metrics(self: *Self) !FontMetrics {
        if (self.font_metrics) |metrics| {
            return metrics;
        }

        const hhea_table = self.parser.parsed_tables.hhea orelse return error.MissingHheaTable;
        const hhea = hhea_table.cast(table.Hhea);

        const head_table = self.parser.parsed_tables.head orelse return error.MissingHeadTable;
        const head = head_table.cast(table.Head);

        const metrics = FontMetrics{
            .ascender = hhea.ascender,
            .descender = hhea.descender,
            .line_gap = hhea.line_gap,
            .advance_width_max = hhea.advance_width_max,
            .units_per_em = head.units_per_em,
            .x_min = head.x_min,
            .y_min = head.y_min,
            .x_max = head.x_max,
            .y_max = head.y_max,
        };

        self.font_metrics = metrics;
        return metrics;
    }

    pub fn get_glyph_name(self: *Self, glyph_id: u16) ?[]const u8 {
        const post_table = self.parser.parsed_tables.post orelse return null;
        const post = post_table.cast(table.Post);
        return post.get_glyph_name(glyph_id);
    }

    pub fn get_selected_glyphs(self: *Self) ![]u16 {
        const result = try self.allocator.alloc(u16, self.selected_glyphs.count());
        var i: usize = 0;
        var iterator = self.selected_glyphs.iterator();
        while (iterator.next()) |entry| {
            result[i] = entry.key_ptr.*;
            i += 1;
        }
        return result;
    }

    pub fn clear_selection(self: *Self) void {
        self.selected_glyphs.clearRetainingCapacity();
    }

    pub fn has_glyph(self: *Self, glyph_id: u16) bool {
        return self.selected_glyphs.contains(glyph_id);
    }

    pub fn generate_subset(self: *Self) ![]u8 {
        const selected_glyphs = try self.get_selected_glyphs();
        defer self.allocator.free(selected_glyphs);

        var glyph_set = std.HashMap(u16, void, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage).init(self.allocator);
        defer glyph_set.deinit();

        // .notdef
        try glyph_set.put(0, {});
        for (selected_glyphs) |glyph_id| {
            try glyph_set.put(glyph_id, {});
        }

        var new_glyphs = std.ArrayList(u16).init(self.allocator);
        defer new_glyphs.deinit();

        var glyph_iterator = glyph_set.iterator();
        while (glyph_iterator.next()) |entry| {
            try new_glyphs.append(entry.key_ptr.*);
        }

        std.sort.heap(u16, new_glyphs.items, {}, std.sort.asc(u16));

        var glyph_id_map = std.HashMap(u16, u16, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage).init(self.allocator);
        defer glyph_id_map.deinit();

        for (new_glyphs.items, 0..) |old_glyph_id, new_index| {
            try glyph_id_map.put(old_glyph_id, @intCast(new_index));
        }

        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        // https://learn.microsoft.com/en-us/typography/opentype/spec/otff#organization-of-an-opentype-font
        // copy head info
        try self.parser.reader.seek_to(0);

        const all_table_tags = [_]mod.TableTag{
            .head, .hhea, .maxp, .os2, .cmap, .name, .post, .hmtx, .loca, .glyf,
        };
        const table_count: u16 = all_table_tags.len;
        try buffer.appendSlice(&std.mem.toBytes(try self.parser.reader.read_u32_be()));
        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, all_table_tags.len)));

        const search_range = (@as(u16, 1) << @intCast(std.math.log2(table_count))) * 16;
        const entry_selector = std.math.log2(search_range / 16);
        const range_shift = table_count * 16 - search_range;

        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, search_range)));
        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(entry_selector))));
        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, range_shift)));

        // tableRecords
        // I'm not sure the table records is a sortable array, but we can using the parsed offset to sort us new tables.
        const TagWithOffset = struct {
            tag: mod.TableTag,
            offset: u32,
        };
        var tags_with_offsets = std.ArrayList(TagWithOffset).init(self.allocator);
        defer tags_with_offsets.deinit();

        for (all_table_tags) |tag| {
            for (self.parser.table_records.items) |table_record| {
                if (table_record.tag == tag) {
                    try tags_with_offsets.append(TagWithOffset{
                        .tag = tag,
                        .offset = table_record.offset,
                    });
                    break;
                }
            }
        }

        std.sort.heap(TagWithOffset, tags_with_offsets.items, {}, struct {
            fn lessThan(context: void, a: TagWithOffset, b: TagWithOffset) bool {
                _ = context;
                return a.offset < b.offset;
            }
        }.lessThan);

        for (tags_with_offsets.items) |sorted_record| {
            if (self.parser.parsed_tables.get_table(sorted_record.tag)) |table_data| {
                try write_table_record_typed(&buffer, sorted_record.tag, &table_data);
            } else {
                continue;
            }
        }

        return try buffer.toOwnedSlice();
    }
};

pub const FontReader = struct {
    const Self = @This();

    subset: Subset,

    pub fn init(allocator: Allocator, font_data: []const u8) !Self {
        const subset = try Subset.init(allocator, font_data);
        return Self{ .subset = subset };
    }

    pub fn deinit(self: *Self) void {
        self.subset.deinit();
    }

    pub fn get_glyph_id_for_codepoint(self: *Self, codepoint: u32) !u16 {
        return self.subset.get_glyph_id(codepoint);
    }

    pub fn get_glyph_info(self: *Self, glyph_id: u16) !?GlyphInfo {
        return self.subset.get_glyph_info(glyph_id);
    }

    pub fn get_font_metrics(self: *Self) !FontMetrics {
        return self.subset.get_font_metrics();
    }

    pub fn get_glyph_name(self: *Self, glyph_id: u16) ?[]const u8 {
        return self.subset.get_glyph_name(glyph_id);
    }

    pub fn get_font_name(self: *Self, name_id: u16) ?[]const u8 {
        const name_table = self.subset.parser.parsed_tables.name orelse return null;
        const name = name_table.cast(table.Name);
        return name.get_by_name_id(name_id);
    }

    pub fn is_monospace(self: *Self) bool {
        const post_table = self.subset.parser.parsed_tables.post orelse return false;
        const post = post_table.cast(table.Post);
        return post.is_monospace();
    }

    pub fn get_num_glyphs(self: *Self) u16 {
        const maxp_table = self.subset.parser.parsed_tables.maxp orelse return 0;
        const maxp = maxp_table.cast(table.Maxp);
        return maxp.num_glyphs;
    }
};

pub fn create_subset_from_file(allocator: Allocator, font_path: []const u8, text: []const u8) ![]u8 {
    const font_data = try std.fs.cwd().readFileAlloc(allocator, font_path, std.math.maxInt(usize));
    defer allocator.free(font_data);

    return create_subset_from_buffer(allocator, font_data, text);
}

pub fn create_subset_from_buffer(allocator: Allocator, font_data: []const u8, text: []const u8) ![]u8 {
    var subset = try Subset.init(allocator, font_data);
    defer subset.deinit();

    try subset.add_text(text);
    return subset.generate_subset();
}

pub fn get_font_info_from_file(allocator: Allocator, font_path: []const u8) !FontReader {
    const font_data = try std.fs.cwd().readFileAlloc(allocator, font_path, std.math.maxInt(usize));

    return FontReader.init(allocator, font_data);
}

pub fn get_font_info_from_buffer(allocator: Allocator, font_data: []const u8) !FontReader {
    return FontReader.init(allocator, font_data);
}

pub fn write_table_records(buffer: *std.ArrayList(u8), comptime cast_tag: type, table_data: *const Table) !void {
    const cast_table = table_data.cast(cast_tag);
    inline for (std.meta.fields(@TypeOf(cast_table.*))) |field| {
        const field_value = @field(cast_table, field.name);

        switch (field.type) {
            u16 => try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, field_value))),
            u32 => try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, field_value))),
            i16 => try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i16, field_value))),
            i32 => try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i32, field_value))),
            i64 => try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(i64, field_value))),
            table.Head.MacStyle => try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, field_value.to_u16()))),
            else => {
                continue;
            },
        }
    }
}

fn getTableType(comptime tag: mod.TableTag) type {
    return switch (tag) {
        .head => table.Head,
        .hhea => table.Hhea,
        .maxp => table.Maxp,
        .os2 => table.Os2,
        .cmap => table.Cmap,
        .name => table.Name,
        .post => table.Post,
        .hmtx => table.Hmtx,
        .loca => table.Loca,
        .glyf => table.Glyf,
    };
}

pub fn write_table_record_typed(buffer: *std.ArrayList(u8), tag: mod.TableTag, table_data: *const Table) !void {
    switch (tag) {
        .head => try write_table_records(buffer, table.Head, table_data),
        .hhea => try write_table_records(buffer, table.Hhea, table_data),
        .maxp => try write_table_records(buffer, table.Maxp, table_data),
        .os2 => try write_table_records(buffer, table.Os2, table_data),
        .cmap => try write_table_records(buffer, table.Cmap, table_data),
        .name => try write_table_records(buffer, table.Name, table_data),
        .post => try write_table_records(buffer, table.Post, table_data),
        .hmtx => try write_table_records(buffer, table.Hmtx, table_data),
        .loca => try write_table_records(buffer, table.Loca, table_data),
        .glyf => try write_table_records(buffer, table.Glyf, table_data),
        else => {
            // Unsupported table type, skip writing
            return;
        },
    }
}

test "create subset from file" {
    const allocator = std.testing.allocator;
    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "LXGWBright-Light.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);
    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);
    const subset = try create_subset_from_file(allocator, font_file_path, "绪方理奈");
    defer allocator.free(subset);
    std.debug.print("origianal len {d}", .{file_content.len});
    std.debug.print("Subset created with {any} bytes len {d}.\n", .{ subset, subset.len });
}
