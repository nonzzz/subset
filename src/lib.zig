const std = @import("std");
const mod = @import("./parser.zig");
const table = @import("./table/mod.zig");
const Table = @import("./table.zig");

const byte_writer = @import("./byte_writer.zig");
const ByteWriter = byte_writer.ByteWriter;

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
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        try self.selected_glyphs.put(0, {});

        var glyph_set = std.AutoHashMap(u16, void).init(self.allocator);
        defer glyph_set.deinit();

        const selected_glyphs = try self.get_selected_glyphs();
        defer self.allocator.free(selected_glyphs);
        for (selected_glyphs) |glyph_id| {
            try self.collect_glyph_ids(glyph_id, &glyph_set);
        }

        const glyph_ids = try self.allocator.alloc(u16, glyph_set.count());
        defer self.allocator.free(glyph_ids);
        var iter = glyph_set.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            glyph_ids[i] = entry.key_ptr.*;
            i += 1;
        }
        std.sort.heap(u16, glyph_ids, {}, std.sort.asc(u16));

        const post_buffer = try self.generate_post_subset(glyph_ids);
        const hhea_buffer = try self.generate_hhea_subset(glyph_ids);
        const maxp_buffer = try self.generate_maxp_subset(glyph_ids);
        const cmap_buffer = try self.generate_cmap_subset(glyph_ids);
        const head_buffer = try self.generate_head_subset(glyph_ids);

        defer {
            self.allocator.free(post_buffer);
            self.allocator.free(hhea_buffer);
            self.allocator.free(maxp_buffer);
            self.allocator.free(cmap_buffer);
            self.allocator.free(head_buffer);
        }

        const name_buffer = self.generate_name_subset();
        _ = name_buffer; // autofix
        return try buffer.toOwnedSlice();
    }

    fn collect_glyph_ids(self: *Self, glyph_id: u16, glyph_set: *std.AutoHashMap(u16, void)) !void {
        if (glyph_set.contains(glyph_id)) return;
        try glyph_set.put(glyph_id, {});
        const glyf_table = self.parser.parsed_tables.glyf.?;
        const glyf = glyf_table.cast(table.Glyf);
        const loca_table = self.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);

        const glyph_offset = loca.get_glyph_offset(glyph_id) orelse return;
        var parsed_glyph = try glyf.parse_glyph(glyph_offset);

        switch (parsed_glyph) {
            .simple => {},
            .composite => |composite_glyph| {
                for (composite_glyph.components) |component| {
                    try self.collect_glyph_ids(component.glyph_index, glyph_set);
                }
            },
        }
        defer parsed_glyph.deinit();
    }

    fn generate_post_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        var post_table = self.parser.parsed_tables.post.?;
        const post = post_table.cast(table.Post);

        var buffer = ByteWriter(u8).init(self.allocator);

        errdefer buffer.deinit();

        try buffer.write(u32, post.version, .big);
        try buffer.write(i32, post.italic_angle, .big);
        try buffer.write(i16, post.underline_position, .big);
        try buffer.write(i16, post.underline_thickness, .big);
        try buffer.write(u32, post.is_fixed_pitch, .big);

        if (post.v2_data) |_| {
            try buffer.write(u16, @intCast(glyph_ids.len), .big);

            var has_custom_names = false;
            for (glyph_ids) |glyph_id| {
                if (post.get_glyph_index(glyph_id)) |glyph_index| {
                    try buffer.write(u16, glyph_index, .big);
                    if (glyph_index >= 258) {
                        has_custom_names = true;
                    }
                }
            }
            if (has_custom_names) {
                for (glyph_ids) |glyph_id| {
                    if (post.get_glyph_index(glyph_id)) |glyph_index| {
                        if (glyph_index >= 258) {
                            if (post.get_glyph_name(glyph_id)) |glyph_name| {
                                try buffer.write_u8(@intCast(glyph_name.len));
                                try buffer.write_bytes(glyph_name);
                            }
                        }
                    }
                }
            }
        }

        return buffer.to_owned_slice();
    }

    fn generate_hhea_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        const hhea_table = self.parser.parsed_tables.hhea.?;
        const hhea = hhea_table.cast(table.Hhea);
        const glyf_table = self.parser.parsed_tables.glyf.?;
        const glyf = glyf_table.cast(table.Glyf);
        const loca_table = self.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);

        var buffer = ByteWriter(u8).init(self.allocator);

        try buffer.write(u16, hhea.major_version, .big);
        try buffer.write(u16, hhea.minor_version, .big);
        try buffer.write(i16, hhea.ascender, .big);
        try buffer.write(i16, hhea.descender, .big);
        try buffer.write(i16, hhea.line_gap, .big);

        var advance_width_max: u16 = 0;
        var min_left_side_bearing: i16 = 0;
        var min_right_side_bearing: i16 = 0;
        var x_max_extent: i16 = 0;
        for (glyph_ids) |glyph_id| {
            const glyph_info = try self.get_glyph_info(glyph_id) orelse continue;
            advance_width_max = @max(advance_width_max, glyph_info.advance_width);
            min_left_side_bearing = @min(min_left_side_bearing, glyph_info.left_side_bearing);

            if (loca.get_glyph_offset(glyph_id)) |glyph_offset| {
                if (glyf.parse_glyph(glyph_offset)) |parsed_glyph| {
                    const glyph_bounds = switch (parsed_glyph) {
                        .simple => |simple| simple.header,
                        .composite => |composite| composite.header,
                    };
                    defer parsed_glyph.deinit();

                    const right_side_bearing = @as(i16, @intCast(glyph_info.advance_width)) - glyph_bounds.x_max;
                    min_right_side_bearing = @min(min_right_side_bearing, right_side_bearing);
                    x_max_extent = @max(x_max_extent, glyph_bounds.x_max);
                } else |_| {
                    continue;
                }
            }
        }
        if (advance_width_max == 0) {
            advance_width_max = hhea.advance_width_max;
        }

        if (min_left_side_bearing == 0) {
            min_left_side_bearing = hhea.min_left_side_bearing;
        }
        if (min_right_side_bearing == 0) {
            min_right_side_bearing = hhea.min_right_side_bearing;
        }
        if (hhea.x_max_extent == 0) {
            hhea.x_max_extent = hhea.x_max_extent;
        }

        try buffer.write(u16, advance_width_max, .big);
        try buffer.write(i16, min_left_side_bearing, .big);
        try buffer.write(i16, min_right_side_bearing, .big);
        try buffer.write(i16, x_max_extent, .big);

        try buffer.write(i16, hhea.caret_slope_rise, .big);
        try buffer.write(i16, hhea.caret_slope_run, .big);
        try buffer.write(i16, hhea.caret_offset, .big);
        try buffer.write(i16, hhea.reserved1, .big);
        try buffer.write(i16, hhea.reserved2, .big);
        try buffer.write(i16, hhea.reserved3, .big);
        try buffer.write(i16, hhea.reserved4, .big);
        try buffer.write(i16, hhea.metric_data_format, .big);

        try buffer.write(u16, @intCast(glyph_ids.len), .big);

        errdefer buffer.deinit();

        return buffer.to_owned_slice();
    }

    fn generate_head_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        const head_table = self.parser.parsed_tables.head orelse return error.MissingHeadTable;
        const head = head_table.cast(table.Head);

        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        try buffer.write(u32, head.major_version, .big);
        try buffer.write(u32, head.minor_version, .big);
        try buffer.write(u32, head.font_revision, .big);

        // Placeholder, will be calculated later (checkSumAdjustment)
        try buffer.write(u32, 0, .big);
        try buffer.write(u32, head.magic_number, .big);
        try buffer.write(u16, head.flags, .big);
        try buffer.write(u16, head.units_per_em, .big);
        try buffer.write(i64, head.created, .big);
        try buffer.write(i64, head.modified, .big);

        var x_min: i16 = 0;
        var x_max: i16 = 0;
        var y_min: i16 = 0;
        var y_max: i16 = 0;

        var has_valid_bounds = false;

        const glyf_table = self.parser.parsed_tables.glyf.?;
        const glyf = glyf_table.cast(table.Glyf);
        const loca_table = self.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);

        for (glyph_ids) |glyph_id| {
            if (loca.get_glyph_offset(glyph_id)) |glyph_offset| {
                if (glyf.parse_glyph(glyph_offset)) |parsed_glyph| {
                    defer parsed_glyph.deinit();
                    const glyph_bounds = switch (parsed_glyph) {
                        .simple => |simple| simple.header,
                        .composite => |composite| composite.header,
                    };
                    if (glyph_bounds.x_min != glyph_bounds.x_max or
                        glyph_bounds.y_min != glyph_bounds.y_max)
                    {
                        x_min = @min(x_min, glyph_bounds.x_min);
                        y_min = @min(y_min, glyph_bounds.y_min);
                        x_max = @max(x_max, glyph_bounds.x_max);
                        y_max = @max(y_max, glyph_bounds.y_max);
                        has_valid_bounds = true;
                    }
                } else |_| {
                    continue;
                }
            }
        }

        if (!has_valid_bounds) {
            x_min = head.x_min;
            y_min = head.y_min;
            x_max = head.x_max;
            y_max = head.y_max;
        }

        try buffer.write(i16, x_min, .big);
        try buffer.write(i16, y_min, .big);
        try buffer.write(i16, x_max, .big);
        try buffer.write(i16, y_max, .big);

        try buffer.write(u16, head.mac_style.to_u16(), .big);
        try buffer.write(u16, head.lowest_rec_ppem, .big);
        try buffer.write(i16, head.font_direction_hint, .big);

        var index_to_loc_format: i16 = head.index_to_loc_format;
        var max_offset: u32 = 0;
        for (glyph_ids) |glyph_id| {
            if (loca.get_glyph_offset(glyph_id)) |offset| {
                max_offset = @max(max_offset, offset);
            }
        }
        if (max_offset > 0x1FFFE) {
            index_to_loc_format = 1;
        } else {
            index_to_loc_format = 0;
        }

        try buffer.write(i16, index_to_loc_format, .big);
        try buffer.write(i16, head.glyph_data_format, .big);

        return buffer.to_owned_slice();
    }

    fn generate_name_subset(self: *Self) []const u8 {
        var name_pos: usize = 0;

        for (self.parser.table_records.items, 0..) |record, i| {
            if (record.tag == .name) {
                name_pos = i;
                break;
            }
        }

        const name_table_offset = self.parser.table_records.items[name_pos].offset;
        const name_table_size = self.parser.table_records.items[name_pos].length;

        const name_table = self.parser.buffer[name_table_offset .. name_table_offset + name_table_size];

        return name_table;
    }

    fn generate_maxp_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        const maxp_table = self.parser.parsed_tables.maxp orelse return error.MissingMaxpTable;
        const maxp = maxp_table.cast(table.Maxp);

        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        try buffer.write(u32, maxp.version, .big);
        try buffer.write(u16, @intCast(glyph_ids.len), .big);

        if (maxp.version == 0x00010000) {
            const glyf_table = self.parser.parsed_tables.glyf orelse return error.MissingGlyfTable;
            const glyf = glyf_table.cast(table.Glyf);
            const loca_table = self.parser.parsed_tables.loca orelse return error.MissingLocaTable;
            const loca = loca_table.cast(table.Loca);

            var max_points: u16 = 0;
            var max_contours: u16 = 0;
            var max_composite_points: u16 = 0;
            var max_composite_contours: u16 = 0;

            for (glyph_ids) |glyph_id| {
                if (loca.get_glyph_offset(glyph_id)) |glyph_offset| {
                    if (glyf.parse_glyph(glyph_offset)) |parsed_glyph| {
                        defer parsed_glyph.deinit();

                        switch (parsed_glyph) {
                            .simple => |simple| {
                                if (simple.x_coordinates.len > 0) {
                                    max_points = @max(max_points, @as(u16, @intCast(simple.x_coordinates.len)));
                                    max_contours = @max(max_contours, @as(u16, @intCast(simple.end_pts_of_contours.len)));
                                }
                            },
                            .composite => |composite| {
                                max_composite_points = @max(max_composite_points, @as(u16, @intCast(composite.components.len)));
                                max_composite_contours = @max(max_composite_contours, @as(u16, @intCast(composite.components.len)));
                            },
                        }
                    } else |_| {
                        continue;
                    }
                }
            }

            try buffer.write(u16, max_points, .big);
            try buffer.write(u16, max_contours, .big);
            try buffer.write(u16, max_composite_points, .big);
            try buffer.write(u16, max_composite_contours, .big);

            try buffer.write(u16, maxp.max_zones orelse 2, .big);
            try buffer.write(u16, maxp.max_twilight_points orelse 0, .big);
            try buffer.write(u16, maxp.max_storage orelse 0, .big);
            try buffer.write(u16, maxp.max_function_defs orelse 0, .big);
            try buffer.write(u16, maxp.max_instruction_defs orelse 0, .big);
            try buffer.write(u16, maxp.max_stack_elements orelse 0, .big);
            try buffer.write(u16, maxp.max_size_of_instructions orelse 0, .big);
            try buffer.write(u16, maxp.max_component_elements orelse 0, .big);
            try buffer.write(u16, maxp.max_component_depth orelse 0, .big);
        }

        return buffer.to_owned_slice();
    }

    fn generate_cmap_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        _ = glyph_ids; // autofix
        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        return buffer.to_owned_slice();
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

test "create subset from file" {
    const allocator = std.testing.allocator;
    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "Caveat-VariableFont_wght.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);
    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);
    // 绪方理奈
    // \u{00C1}
    const subset = try create_subset_from_file(allocator, font_file_path, "A");
    defer allocator.free(subset);
    std.debug.print("origianal len {d}", .{file_content.len});
    std.debug.print("Subset created with {any} bytes len {d}.\n", .{ subset, subset.len });
}
