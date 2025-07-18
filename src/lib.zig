const std = @import("std");
const mod = @import("./parser.zig");
const table = @import("./table/mod.zig");
const Table = @import("./table.zig");
pub const woff = @import("./woff/mod.zig");

const byte_writer = @import("./byte_writer.zig");
const ByteWriter = byte_writer.ByteWriter;

const Parser = mod.Parser;
const TableTag = mod.TableTag;
const fs = std.fs;
const Allocator = std.mem.Allocator;

const TableRecord = struct {
    tag: TableTag,
    checksum: u32,
    offset: u32,
    length: u32,
    data: []const u8,
};

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

    pub fn generate_subset(self: *Self, modified_time: ?i64) ![]u8 {
        var buffer = ByteWriter(u8).init(self.allocator);
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

        const glyf_buffer = try self.generate_glyf_subset(glyph_ids);
        const loca_buffer = try self.generate_loca_subset(glyph_ids, glyf_buffer);
        const cmap_buffer = try self.generate_cmap_subset(glyph_ids);
        const head_buffer = try self.generate_head_subset(glyph_ids, modified_time);
        const hhea_buffer = try self.generate_hhea_subset(glyph_ids);
        const hmtx_buffer = try self.generate_hmtx_subset(glyph_ids);
        const maxp_buffer = try self.generate_maxp_subset(glyph_ids);
        const name_buffer = self.generate_name_subset();
        const os2_buffer = try self.generate_os2_subset(glyph_ids);
        const post_buffer = try self.generate_post_subset(glyph_ids);

        defer {
            self.allocator.free(glyf_buffer);
            self.allocator.free(loca_buffer);
            self.allocator.free(cmap_buffer);
            self.allocator.free(head_buffer);
            self.allocator.free(hhea_buffer);
            self.allocator.free(hmtx_buffer);
            self.allocator.free(maxp_buffer);
            self.allocator.free(os2_buffer);
            self.allocator.free(post_buffer);
        }

        var tables = std.ArrayList(TableRecord).init(self.allocator);
        defer tables.deinit();

        const table_tags = [_]TableTag{ .cmap, .glyf, .head, .hhea, .hmtx, .loca, .maxp, .name, .os2, .post };
        const table_buffers = [_][]const u8{
            cmap_buffer,
            glyf_buffer,
            head_buffer,
            hhea_buffer,
            hmtx_buffer,
            loca_buffer,
            maxp_buffer,
            name_buffer,
            os2_buffer,
            post_buffer,
        };

        for (table_tags, 0..) |tag, pos| {
            try tables.append(write_table(tag, table_buffers[pos]));
        }

        std.sort.heap(TableRecord, tables.items, {}, struct {
            fn lessThan(_: void, a: TableRecord, b: TableRecord) bool {
                return std.mem.order(u8, &a.tag.to_str(), &b.tag.to_str()) == .lt;
            }
        }.lessThan);

        const num_tables: u16 = @intCast(tables.items.len);

        var search_range: u16 = 16;
        var entry_selector: u16 = 0;
        while (search_range <= num_tables) {
            search_range *= 2;
            entry_selector += 1;
        }
        search_range /= 2;
        const range_shift: u16 = num_tables * 16 - search_range;

        try buffer.write(u32, 0x00010000, .big);
        try buffer.write(u16, num_tables, .big);
        try buffer.write(u16, search_range, .big);
        try buffer.write(u16, entry_selector, .big);
        try buffer.write(u16, range_shift, .big);

        var current_offset: u32 = 12 + @as(u32, num_tables) * 16;

        for (tables.items) |*table_record| {
            current_offset = (current_offset + 3) & ~@as(u32, 3);
            table_record.offset = current_offset;
            table_record.checksum = calculate_table_checksum(table_record.data);
            current_offset += table_record.length;
        }

        for (tables.items) |table_record| {
            for (table_record.tag.to_str()) |byte| {
                try buffer.write(u8, byte, .big);
            }
            try buffer.write(u32, table_record.checksum, .big);
            try buffer.write(u32, table_record.offset, .big);
            try buffer.write(u32, table_record.length, .big);
        }

        for (tables.items) |table_record| {
            while (buffer.len() % 4 != 0) {
                try buffer.write_u8(0);
            }

            try buffer.write_bytes(table_record.data);
        }

        while (buffer.len() % 4 != 0) {
            try buffer.write_u8(0);
        }

        const font_data = try buffer.to_owned_slice();

        try update_head_checksum_adjustment(font_data, tables.items);

        return font_data;
    }

    fn calculate_table_checksum(data: []const u8) u32 {
        var checksum: u32 = 0;
        var i: usize = 0;

        while (i + 3 < data.len) {
            const word = (@as(u32, data[i]) << 24) |
                (@as(u32, data[i + 1]) << 16) |
                (@as(u32, data[i + 2]) << 8) |
                (@as(u32, data[i + 3]));
            checksum = checksum +% word;
            i += 4;
        }

        if (i < data.len) {
            var word: u32 = 0;
            var shift: u5 = 24;
            while (i < data.len) {
                word |= @as(u32, data[i]) << shift;
                shift -= 8;
                i += 1;
            }
            checksum = checksum +% word;
        }

        return checksum;
    }

    fn update_head_checksum_adjustment(font_data: []u8, tables: []TableRecord) !void {
        var head_offset: ?u32 = null;
        for (tables) |table_record| {
            if (table_record.tag == .head) {
                head_offset = table_record.offset;
                break;
            }
        }

        if (head_offset == null) return;

        const adjustment_offset = head_offset.? + 8;
        std.mem.writeInt(u32, font_data[adjustment_offset .. adjustment_offset + 4][0..4], 0, .big);

        const font_checksum = calculate_table_checksum(font_data);

        const checksum_adjustment = 0xB1B0AFBA -% font_checksum;

        std.mem.writeInt(u32, font_data[adjustment_offset .. adjustment_offset + 4][0..4], checksum_adjustment, .big);
    }

    fn generate_loca_subset(self: *Self, glyph_ids: []u16, glyf_data: []const u8) ![]u8 {
        const max_offset: u32 = @intCast(glyf_data.len);
        const is_short_format = max_offset <= 0x1FFFE;

        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        var current_offset: u32 = 0;

        const loca_table = self.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);

        for (glyph_ids) |glyph_id| {
            if (is_short_format) {
                try buffer.write(u16, @intCast(current_offset / 2), .big);
            } else {
                try buffer.write(u32, current_offset, .big);
            }

            if (loca.get_glyph_offset(glyph_id)) |glyph_offset| {
                const loca_offsets = loca.offsets;
                const next_offset = if (glyph_id + 1 < loca_offsets.len)
                    loca_offsets[glyph_id + 1]
                else
                    glyph_offset;

                const glyph_length = if (next_offset > glyph_offset)
                    next_offset - glyph_offset
                else
                    0;

                current_offset += glyph_length;

                current_offset = (current_offset + 3) & ~@as(u32, 3);
            }
        }

        if (is_short_format) {
            try buffer.write(u16, @intCast(current_offset / 2), .big);
        } else {
            try buffer.write(u32, current_offset, .big);
        }

        return buffer.to_owned_slice();
    }

    fn generate_glyf_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        const glyf_table = self.parser.parsed_tables.glyf orelse return error.MissingGlyfTable;
        const glyf = glyf_table.cast(table.Glyf);
        const loca_table = self.parser.parsed_tables.loca orelse return error.MissingLocaTable;
        const loca = loca_table.cast(table.Loca);

        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        var glyph_id_mapping = std.HashMap(u16, u16, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage).init(self.allocator);
        defer glyph_id_mapping.deinit();

        for (glyph_ids, 0..) |glyph_id, new_id| {
            try glyph_id_mapping.put(glyph_id, @intCast(new_id));
        }

        for (glyph_ids) |glyph_id| {
            if (loca.get_glyph_offset(glyph_id)) |glyph_offset| {
                const loca_offsets = loca.offsets;
                const next_offset = if (glyph_id + 1 < loca_offsets.len)
                    loca_offsets[glyph_id + 1]
                else
                    glyph_offset;

                const glyph_length = if (next_offset > glyph_offset)
                    next_offset - glyph_offset
                else
                    0;

                if (glyph_length > 0) {
                    if (glyf.parse_glyph(glyph_offset)) |parsed_glyph| {
                        defer parsed_glyph.deinit();

                        switch (parsed_glyph) {
                            .simple => |simple| {
                                try write_glyph_header(&buffer, simple.header);
                                try write_simple_glyph_data(&buffer, simple);
                            },
                            .composite => |composite| {
                                try write_glyph_header(&buffer, composite.header);
                                try write_composite_glyph_data(&buffer, composite, &glyph_id_mapping);
                            },
                        }
                    } else |_| {
                        continue;
                    }
                }
            }

            while (buffer.len() % 4 != 0) {
                try buffer.write_u8(0);
            }
        }

        return buffer.to_owned_slice();
    }

    fn write_composite_glyph_data(
        buffer: *ByteWriter(u8),
        composite: table.Glyf.CompositeGlyph,
        glyph_id_mapping: *std.HashMap(u16, u16, std.hash_map.AutoContext(u16), std.hash_map.default_max_load_percentage),
    ) !void {
        for (composite.components, 0..) |component, i| {
            const is_last = (i == composite.components.len - 1);
            var flags = component.flags;

            if (is_last) {
                flags &= ~@as(u16, 0x0020);
            } else {
                flags |= 0x0020;
            }

            try buffer.write(u16, flags, .big);

            const new_glyph_index = glyph_id_mapping.get(component.glyph_index) orelse component.glyph_index;
            try buffer.write(u16, new_glyph_index, .big);

            if ((flags & 0x0001) != 0) {
                try buffer.write(i16, @intCast(component.arg1), .big);
                try buffer.write(i16, @intCast(component.arg2), .big);
            } else {
                try buffer.write_u8(@bitCast(@as(i8, @intCast(component.arg1))));
                try buffer.write_u8(@bitCast(@as(i8, @intCast(component.arg2))));
            }

            switch (component.transform) {
                .scale => |scale| {
                    const scale_raw: i16 = @intFromFloat(scale.scale * 16384.0);
                    try buffer.write(i16, scale_raw, .big);
                },
                .xy_scale => |xy_scale| {
                    const x_scale_raw: i16 = @intFromFloat(xy_scale.x_scale * 16384.0);
                    const y_scale_raw: i16 = @intFromFloat(xy_scale.y_scale * 16384.0);
                    try buffer.write(i16, x_scale_raw, .big);
                    try buffer.write(i16, y_scale_raw, .big);
                },
                .matrix => |matrix| {
                    const xx_raw: i16 = @intFromFloat(matrix.xx * 16384.0);
                    const xy_raw: i16 = @intFromFloat(matrix.xy * 16384.0);
                    const yx_raw: i16 = @intFromFloat(matrix.yx * 16384.0);
                    const yy_raw: i16 = @intFromFloat(matrix.yy * 16384.0);
                    try buffer.write(i16, xx_raw, .big);
                    try buffer.write(i16, xy_raw, .big);
                    try buffer.write(i16, yx_raw, .big);
                    try buffer.write(i16, yy_raw, .big);
                },
                .none => {},
            }
        }

        if (composite.instructions.len > 0) {
            try buffer.write(u16, @intCast(composite.instructions.len), .big);
            try buffer.write_bytes(composite.instructions);
        }
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

    fn generate_cmap_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        var codepoint_to_glyph = std.AutoHashMap(u32, u16).init(self.allocator);
        defer codepoint_to_glyph.deinit();

        var glyph_id_mapping = std.AutoHashMap(u16, u16).init(self.allocator);
        defer glyph_id_mapping.deinit();

        for (glyph_ids, 0..) |glyph_id, i| {
            try glyph_id_mapping.put(glyph_id, @intCast(i));
        }

        var glyph_cache_iter = self.glyph_cache.iterator();
        while (glyph_cache_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const original_glyph_id = entry.value_ptr.*;

            if (glyph_id_mapping.get(original_glyph_id)) |new_glyph_id| {
                try codepoint_to_glyph.put(codepoint, new_glyph_id);
            }
        }

        if (codepoint_to_glyph.count() == 0) {
            return try create_minimal_cmap(&buffer);
        }

        var has_high_codepoints = false;
        var max_codepoint: u32 = 0;
        var codepoint_iter = codepoint_to_glyph.iterator();
        while (codepoint_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            max_codepoint = @max(max_codepoint, codepoint);
            if (codepoint > 0xFFFF) {
                has_high_codepoints = true;
            }
        }

        try buffer.write(u16, 0, .big);

        if (has_high_codepoints) {
            try buffer.write(u16, 2, .big);

            try buffer.write(u16, 3, .big);
            try buffer.write(u16, 1, .big);
            try buffer.write(u32, 20, .big);

            try buffer.write(u16, 3, .big);
            try buffer.write(u16, 10, .big);
            const format12_offset = try calculate_format4_size(codepoint_to_glyph, false) + 20;
            try buffer.write(u32, format12_offset, .big);

            try generate_format4_subtable(&buffer, codepoint_to_glyph, false);

            try generate_format12_subtable(&buffer, codepoint_to_glyph);
        } else {
            try buffer.write(u16, 1, .big);

            try buffer.write(u16, 3, .big);
            try buffer.write(u16, 1, .big);
            try buffer.write(u32, 12, .big);

            try generate_format4_subtable(&buffer, codepoint_to_glyph, true);
        }

        return buffer.to_owned_slice();
    }
    fn create_minimal_cmap(buffer: *ByteWriter(u8)) ![]u8 {
        try buffer.write(u16, 0, .big);
        try buffer.write(u16, 1, .big);

        try buffer.write(u16, 3, .big);
        try buffer.write(u16, 1, .big);
        try buffer.write(u32, 12, .big);

        try buffer.write(u16, 4, .big);
        try buffer.write(u16, 32, .big);
        try buffer.write(u16, 0, .big);
        try buffer.write(u16, 4, .big);
        try buffer.write(u16, 4, .big);
        try buffer.write(u16, 1, .big);
        try buffer.write(u16, 0, .big);

        try buffer.write(u16, 0xFFFF, .big);
        try buffer.write(u16, 0xFFFF, .big);
        try buffer.write(u16, 0, .big);
        try buffer.write(u16, 0xFFFF, .big);
        try buffer.write(u16, 0xFFFF, .big);
        try buffer.write(i16, 1, .big);
        try buffer.write(i16, 1, .big);
        try buffer.write(u16, 0, .big);
        try buffer.write(u16, 0, .big);

        return buffer.to_owned_slice();
    }

    fn write_table(tag: TableTag, data: []const u8) TableRecord {
        return TableRecord{
            .tag = tag,
            .checksum = 0,
            .offset = 0,
            .length = @intCast(data.len),
            .data = data,
        };
    }

    fn calculate_format4_size(codepoint_to_glyph: std.AutoHashMap(u32, u16), include_all: bool) !u32 {
        var segments = std.ArrayList(struct { start: u16, end: u16 }).init(codepoint_to_glyph.allocator);
        defer segments.deinit();

        var codepoints = std.ArrayList(u32).init(codepoint_to_glyph.allocator);
        defer codepoints.deinit();

        var iter = codepoint_to_glyph.iterator();
        while (iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            if (include_all or codepoint <= 0xFFFF) {
                try codepoints.append(codepoint);
            }
        }

        if (codepoints.items.len == 0) {
            return 32;
        }

        std.sort.heap(u32, codepoints.items, {}, std.sort.asc(u32));

        var current_start: u16 = @intCast(codepoints.items[0]);
        var current_end: u16 = current_start;

        for (codepoints.items[1..]) |cp| {
            const cp16: u16 = @intCast(cp);
            if (cp16 == current_end + 1) {
                current_end = cp16;
            } else {
                try segments.append(.{ .start = current_start, .end = current_end });
                current_start = cp16;
                current_end = cp16;
            }
        }
        try segments.append(.{ .start = current_start, .end = current_end });

        const seg_count = segments.items.len + 1;
        return @intCast(16 + seg_count * 8);
    }

    fn generate_format4_subtable(buffer: *ByteWriter(u8), codepoint_to_glyph: std.AutoHashMap(u32, u16), include_all: bool) !void {
        var codepoints = std.ArrayList(u32).init(codepoint_to_glyph.allocator);
        defer codepoints.deinit();

        var iter = codepoint_to_glyph.iterator();
        while (iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            if (include_all or codepoint <= 0xFFFF) {
                try codepoints.append(codepoint);
            }
        }

        if (codepoints.items.len == 0) {
            try buffer.write(u16, 4, .big);
            try buffer.write(u16, 32, .big);
            try buffer.write(u16, 0, .big);
            try buffer.write(u16, 4, .big);
            try buffer.write(u16, 4, .big);
            try buffer.write(u16, 1, .big);
            try buffer.write(u16, 0, .big);

            try buffer.write(u16, 0xFFFF, .big);
            try buffer.write(u16, 0xFFFF, .big);

            try buffer.write(u16, 0, .big);

            try buffer.write(u16, 0xFFFF, .big);
            try buffer.write(u16, 0xFFFF, .big);

            try buffer.write(i16, 1, .big);
            try buffer.write(i16, 1, .big);

            try buffer.write(u16, 0, .big);
            try buffer.write(u16, 0, .big);
            return;
        }

        std.sort.heap(u32, codepoints.items, {}, std.sort.asc(u32));

        var segments = std.ArrayList(struct { start: u16, end: u16, glyph_id: u16 }).init(codepoint_to_glyph.allocator);
        defer segments.deinit();

        var current_start: u16 = @intCast(codepoints.items[0]);
        var current_end: u16 = current_start;
        var start_glyph_id = codepoint_to_glyph.get(codepoints.items[0]).?;

        for (codepoints.items[1..]) |cp| {
            const cp16: u16 = @intCast(cp);
            const glyph_id = codepoint_to_glyph.get(cp).?;

            if (cp16 == current_end + 1 and glyph_id == start_glyph_id + (current_end - current_start + 1)) {
                current_end = cp16;
            } else {
                try segments.append(.{ .start = current_start, .end = current_end, .glyph_id = start_glyph_id });
                current_start = cp16;
                current_end = cp16;
                start_glyph_id = glyph_id;
            }
        }
        try segments.append(.{ .start = current_start, .end = current_end, .glyph_id = start_glyph_id });

        const seg_count = segments.items.len + 1;
        const seg_count_x2: u16 = @intCast(seg_count * 2);

        var search_range: u16 = 2;
        var entry_selector: u16 = 0;
        while (search_range <= seg_count) {
            search_range *= 2;
            entry_selector += 1;
        }
        search_range /= 2;
        const range_shift: u16 = seg_count_x2 - search_range;

        const length: u16 = @intCast(16 + seg_count * 8);

        try buffer.write(u16, 4, .big);
        try buffer.write(u16, length, .big);
        try buffer.write(u16, 0, .big);
        try buffer.write(u16, seg_count_x2, .big);
        try buffer.write(u16, search_range, .big);
        try buffer.write(u16, entry_selector, .big);
        try buffer.write(u16, range_shift, .big);

        for (segments.items) |segment| {
            try buffer.write(u16, segment.end, .big);
        }
        try buffer.write(u16, 0xFFFF, .big);

        try buffer.write(u16, 0, .big);

        for (segments.items) |segment| {
            try buffer.write(u16, segment.start, .big);
        }
        try buffer.write(u16, 0xFFFF, .big);

        for (segments.items) |segment| {
            const id_delta: i16 = @intCast(@as(i32, segment.glyph_id) - @as(i32, segment.start));
            try buffer.write(i16, id_delta, .big);
        }
        try buffer.write(i16, 1, .big);

        for (0..seg_count) |_| {
            try buffer.write(u16, 0, .big);
        }
    }

    fn generate_format12_subtable(buffer: *ByteWriter(u8), codepoint_to_glyph: std.AutoHashMap(u32, u16)) !void {
        var codepoints = std.ArrayList(u32).init(codepoint_to_glyph.allocator);
        defer codepoints.deinit();

        var iter = codepoint_to_glyph.iterator();
        while (iter.next()) |entry| {
            try codepoints.append(entry.key_ptr.*);
        }

        std.sort.heap(u32, codepoints.items, {}, std.sort.asc(u32));

        var groups = std.ArrayList(struct { start: u32, end: u32, glyph_id: u32 }).init(codepoint_to_glyph.allocator);
        defer groups.deinit();

        if (codepoints.items.len > 0) {
            var current_start = codepoints.items[0];
            var current_end = current_start;
            var start_glyph_id = codepoint_to_glyph.get(current_start).?;

            for (codepoints.items[1..]) |cp| {
                const glyph_id = codepoint_to_glyph.get(cp).?;

                if (cp == current_end + 1 and glyph_id == start_glyph_id + (current_end - current_start + 1)) {
                    current_end = cp;
                } else {
                    try groups.append(.{ .start = current_start, .end = current_end, .glyph_id = start_glyph_id });
                    current_start = cp;
                    current_end = cp;
                    start_glyph_id = glyph_id;
                }
            }
            try groups.append(.{ .start = current_start, .end = current_end, .glyph_id = start_glyph_id });
        }

        const length: u32 = 16 + @as(u32, @intCast(groups.items.len)) * 12;

        try buffer.write(u16, 12, .big);
        try buffer.write(u16, 0, .big);
        try buffer.write(u32, length, .big);
        try buffer.write(u32, 0, .big);
        try buffer.write(u32, @intCast(groups.items.len), .big);

        for (groups.items) |group| {
            try buffer.write(u32, group.start, .big);
            try buffer.write(u32, group.end, .big);
            try buffer.write(u32, group.glyph_id, .big);
        }
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
        try buffer.write(u32, post.min_mem_type42, .big);
        try buffer.write(u32, post.max_mem_type42, .big);
        try buffer.write(u32, post.min_mem_type1, .big);
        try buffer.write(u32, post.max_mem_type1, .big);

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

    fn generate_os2_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        const os2_table = self.parser.parsed_tables.os2.?;
        const os2 = os2_table.cast(table.Os2);

        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        try buffer.write(u16, os2.version.to_u16(), .big);

        var avg_char_width: i16 = 0;
        if (glyph_ids.len > 0) {
            var total_width: u32 = 0;
            var count: u32 = 0;

            for (glyph_ids) |glyph_id| {
                if (try self.get_glyph_info(glyph_id)) |glyph_info| {
                    total_width += glyph_info.advance_width;
                    count += 1;
                }
            }

            if (count > 0) {
                avg_char_width = @intCast(total_width / count);
            } else if (os2.v0_data) |v0| {
                avg_char_width = v0.x_avg_char_width;
            }
        } else if (os2.v0_data) |v0| {
            avg_char_width = v0.x_avg_char_width;
        }

        try buffer.write(i16, avg_char_width, .big);

        const v0 = os2.v0_data.?;

        try buffer.write(u16, v0.us_weight_class, .big);
        try buffer.write(u16, v0.us_width_class, .big);

        try buffer.write(u16, v0.fs_type, .big);

        try buffer.write(i16, v0.y_subscript_x_size, .big);
        try buffer.write(i16, v0.y_subscript_y_size, .big);
        try buffer.write(i16, v0.y_subscript_x_offset, .big);
        try buffer.write(i16, v0.y_subscript_y_offset, .big);

        try buffer.write(i16, v0.y_superscript_x_size, .big);
        try buffer.write(i16, v0.y_superscript_y_size, .big);
        try buffer.write(i16, v0.y_superscript_x_offset, .big);
        try buffer.write(i16, v0.y_superscript_y_offset, .big);

        try buffer.write(i16, v0.y_strikeout_size, .big);
        try buffer.write(i16, v0.y_strikeout_position, .big);

        try buffer.write(i16, v0.s_family_class, .big);

        try buffer.write_bytes(&v0.panose);

        var unicode_ranges: [4]u32 = [_]u32{0} ** 4;

        var glyph_cache_iter = self.glyph_cache.iterator();
        while (glyph_cache_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const glyph_id = entry.value_ptr.*;

            var in_subset = false;
            for (glyph_ids) |subset_glyph_id| {
                if (subset_glyph_id == glyph_id) {
                    in_subset = true;
                    break;
                }
            }

            if (in_subset) {
                if (codepoint <= 0x007F) {
                    unicode_ranges[0] |= 1 << 0;
                } else if (codepoint <= 0x00FF) {
                    unicode_ranges[0] |= 1 << 1;
                } else if (codepoint <= 0x017F) {
                    unicode_ranges[0] |= 1 << 2;
                } else if (codepoint <= 0x024F) {
                    unicode_ranges[0] |= 1 << 3;
                }
            }
        }

        try buffer.write(u32, unicode_ranges[0], .big);
        try buffer.write(u32, unicode_ranges[1], .big);
        try buffer.write(u32, unicode_ranges[2], .big);
        try buffer.write(u32, unicode_ranges[3], .big);

        try buffer.write_bytes(&v0.ach_vend_id);

        try buffer.write(u16, v0.fs_selection, .big);

        var first_char_index: u16 = 0xFFFF;
        var last_char_index: u16 = 0;

        glyph_cache_iter = self.glyph_cache.iterator();
        while (glyph_cache_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const glyph_id = entry.value_ptr.*;

            var in_subset = false;
            for (glyph_ids) |subset_glyph_id| {
                if (subset_glyph_id == glyph_id) {
                    in_subset = true;
                    break;
                }
            }

            if (in_subset and codepoint <= 0xFFFF) {
                const cp16: u16 = @intCast(codepoint);
                first_char_index = @min(first_char_index, cp16);
                last_char_index = @max(last_char_index, cp16);
            }
        }

        if (first_char_index == 0xFFFF) {
            first_char_index = v0.us_first_char_index;
            last_char_index = v0.us_last_char_index;
        }

        try buffer.write(u16, first_char_index, .big);
        try buffer.write(u16, last_char_index, .big);

        try buffer.write(i16, v0.s_typo_ascender, .big);
        try buffer.write(i16, v0.s_typo_descender, .big);
        try buffer.write(i16, v0.s_typo_line_gap, .big);
        try buffer.write(u16, v0.us_win_ascent, .big);
        try buffer.write(u16, v0.us_win_descent, .big);

        if (os2.version.to_u16() >= 1) {
            if (os2.v1_data) |v1| {
                try buffer.write(u32, v1.ul_code_page_range1, .big);
                try buffer.write(u32, v1.ul_code_page_range2, .big);
            } else {
                try buffer.write(u32, 0, .big);
                try buffer.write(u32, 0, .big);
            }
        }

        if (os2.version.to_u16() >= 2) {
            if (os2.v2_data) |v2| {
                try buffer.write(i16, v2.sx_height, .big);
                try buffer.write(i16, v2.s_cap_height, .big);
                try buffer.write(u16, v2.us_default_char, .big);
                try buffer.write(u16, v2.us_break_char, .big);
                try buffer.write(u16, v2.us_max_context, .big);
            } else {
                try buffer.write(i16, 0, .big);
                try buffer.write(i16, 0, .big);
                try buffer.write(u16, 0, .big);
                try buffer.write(u16, 32, .big);
                try buffer.write(u16, 0, .big);
            }
        }

        if (os2.version.to_u16() >= 5) {
            if (os2.v5_data) |v5| {
                try buffer.write(u16, v5.us_lower_optical_point_size, .big);
                try buffer.write(u16, v5.us_upper_optical_point_size, .big);
            } else {
                try buffer.write(u16, 0, .big);
                try buffer.write(u16, 0xFFFF, .big);
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
                    const glyph_bounds = parsed_glyph.get_header();
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

    fn generate_head_subset(self: *Self, glyph_ids: []u16, modified_time: ?i64) ![]u8 {
        const head_table = self.parser.parsed_tables.head orelse return error.MissingHeadTable;
        const head = head_table.cast(table.Head);

        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        try buffer.write(u16, head.major_version, .big);
        try buffer.write(u16, head.minor_version, .big);
        try buffer.write(u32, head.font_revision, .big);

        try buffer.write(u32, 0, .big);

        try buffer.write(u32, 0x5F0F3CF5, .big);

        try buffer.write(u16, head.flags, .big);
        try buffer.write(u16, head.units_per_em, .big);
        try buffer.write(i64, head.created, .big);

        const mod_time = modified_time orelse head.modified;
        try buffer.write(i64, mod_time, .big);

        var x_min: i16 = 32767;
        var y_min: i16 = 32767;
        var x_max: i16 = -32768;
        var y_max: i16 = -32768;
        var has_valid_bounds = false;

        const glyf_table = self.parser.parsed_tables.glyf.?;
        const glyf = glyf_table.cast(table.Glyf);
        const loca_table = self.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);

        for (glyph_ids) |glyph_id| {
            if (loca.get_glyph_offset(glyph_id)) |glyph_offset| {
                if (glyf.parse_glyph(glyph_offset)) |parsed_glyph| {
                    defer parsed_glyph.deinit();

                    const glyph_bounds = parsed_glyph.get_header();

                    if (glyph_bounds.number_of_contours != 0 or
                        (glyph_bounds.x_min != glyph_bounds.x_max and glyph_bounds.y_min != glyph_bounds.y_max))
                    {
                        if (!has_valid_bounds) {
                            x_min = glyph_bounds.x_min;
                            y_min = glyph_bounds.y_min;
                            x_max = glyph_bounds.x_max;
                            y_max = glyph_bounds.y_max;
                            has_valid_bounds = true;
                        } else {
                            x_min = @min(x_min, glyph_bounds.x_min);
                            y_min = @min(y_min, glyph_bounds.y_min);
                            x_max = @max(x_max, glyph_bounds.x_max);
                            y_max = @max(y_max, glyph_bounds.y_max);
                        }
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

        var index_to_loc_format: i16 = 0;

        var estimated_glyf_size: u32 = 0;
        for (glyph_ids) |glyph_id| {
            if (loca.get_glyph_offset(glyph_id)) |glyph_offset| {
                const loca_offsets = loca.offsets;
                const next_offset = if (glyph_id + 1 < loca_offsets.len)
                    loca_offsets[glyph_id + 1]
                else
                    glyph_offset;

                const glyph_length = if (next_offset > glyph_offset)
                    next_offset - glyph_offset
                else
                    0;

                estimated_glyf_size += glyph_length;

                estimated_glyf_size = (estimated_glyf_size + 3) & ~@as(u32, 3);
            }
        }

        if (estimated_glyf_size > 0x1FFFE) {
            index_to_loc_format = 1;
        }

        try buffer.write(i16, index_to_loc_format, .big);
        try buffer.write(i16, 0, .big);

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
        const maxp_table = self.parser.parsed_tables.maxp.?;
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

    fn generate_hmtx_subset(self: *Self, glyph_ids: []u16) ![]u8 {
        var buffer = ByteWriter(u8).init(self.allocator);
        errdefer buffer.deinit();

        const hmtx_table = self.parser.parsed_tables.hmtx.?;
        const hmtx = hmtx_table.cast(table.Hmtx);

        for (glyph_ids) |glyph_id| {
            const metrics = hmtx.get_metrics(glyph_id);
            try buffer.write(u16, metrics.advance_width, .big);
            try buffer.write(i16, metrics.left_side_bearing, .big);
        }

        return try buffer.to_owned_slice();
    }

    fn write_glyph_header(buffer: *ByteWriter(u8), header: table.Glyf.GlyphHeader) !void {
        try buffer.write(i16, header.number_of_contours, .big);
        try buffer.write(i16, header.x_min, .big);
        try buffer.write(i16, header.y_min, .big);
        try buffer.write(i16, header.x_max, .big);
        try buffer.write(i16, header.y_max, .big);
    }

    fn write_simple_glyph_data(buffer: *ByteWriter(u8), simple: table.Glyf.SimpleGlyph) !void {
        for (simple.end_pts_of_contours) |end_pt| {
            try buffer.write(u16, end_pt, .big);
        }

        try buffer.write(u16, @intCast(simple.instructions.len), .big);
        try buffer.write_bytes(simple.instructions);

        try encode_coordinates(buffer, simple.flags, simple.x_coordinates, simple.y_coordinates);
    }

    fn encode_coordinates(buffer: *ByteWriter(u8), flags: []u8, x_coords: []i16, y_coords: []i16) !void {
        var i: usize = 0;
        while (i < flags.len) {
            const flag = flags[i];
            try buffer.write_u8(flag);

            if ((flag & 0x08) != 0) {
                var repeat_count: u8 = 0;
                var j = i + 1;
                while (j < flags.len and j < i + 256 and flags[j] == flag) {
                    repeat_count += 1;
                    j += 1;
                }
                if (repeat_count > 0) {
                    try buffer.write_u8(repeat_count);
                    i = j;
                    continue;
                }
            }
            i += 1;
        }

        var prev_x: i16 = 0;
        for (x_coords, 0..) |x, idx| {
            const flag = flags[idx];
            const delta = x - prev_x;

            if ((flag & 0x02) != 0) {
                try buffer.write_u8(@intCast(@abs(delta)));
            } else if ((flag & 0x10) == 0) {
                try buffer.write(i16, delta, .big);
            }
            prev_x = x;
        }

        var prev_y: i16 = 0;
        for (y_coords, 0..) |y, idx| {
            const flag = flags[idx];
            const delta = y - prev_y;

            if ((flag & 0x04) != 0) {
                try buffer.write_u8(@intCast(@abs(delta)));
            } else if ((flag & 0x20) == 0) {
                try buffer.write(i16, delta, .big);
            }
            prev_y = y;
        }
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

pub fn create_subset_from_buffer(allocator: Allocator, font_data: []const u8, text: []const u8, modified_time: ?i64) ![]u8 {
    var subset = try Subset.init(allocator, font_data);
    defer subset.deinit();

    try subset.add_text(text);
    return subset.generate_subset(modified_time);
}

pub fn get_font_info_from_file(allocator: Allocator, font_path: []const u8) !FontReader {
    const font_data = try std.fs.cwd().readFileAlloc(allocator, font_path, std.math.maxInt(usize));

    return FontReader.init(allocator, font_data);
}

pub fn get_font_info_from_buffer(allocator: Allocator, font_data: []const u8) !FontReader {
    return FontReader.init(allocator, font_data);
}
