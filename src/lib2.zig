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

const TableRecord = parser.TableRecord;

const Subsetter = struct {
    t: *ttf,
    r: *Reader,
    allocator: Allocator,
    main_buffer: Writer(u8),
    table_infos: std.ArrayList(TableRecord),

    const Self = @This();

    const Builder = struct {
        tag: parser.TableTag,
        build_fn: *const fn (*Subsetter, []u16) anyerror!void,
        required: bool = true,
        condition_fn: ?*const fn (*Subsetter) bool = null,
    };

    const ALL_TABLES = [_]Builder{
        .{ .tag = .head, .build_fn = build_head_table },
        .{ .tag = .hhea, .build_fn = build_hhea_table },
        .{ .tag = .hmtx, .build_fn = build_hmtx_table },
        .{ .tag = .maxp, .build_fn = build_maxp_table },
        .{ .tag = .cmap, .build_fn = build_cmap_table },
        .{ .tag = .name, .build_fn = build_name_table },
        .{ .tag = .glyf, .build_fn = build_glyf_table },
        .{ .tag = .loca, .build_fn = build_loca_table },
        .{ .tag = .post, .build_fn = build_post_table },
        .{ .tag = .os2, .build_fn = build_os2_table },
    };

    pub fn init(t: *ttf) !Subsetter {
        return Self{
            .t = t,
            .r = try t.reader(),
            .allocator = t.allocator,
            .main_buffer = Writer(u8).init(t.allocator),
            .table_infos = std.ArrayList(TableRecord).init(t.allocator),
        };
    }
    pub fn deinit(self: *Self) void {
        self.main_buffer.deinit();
        self.table_infos.deinit();
    }

    pub fn build_subset(self: *Self, options: BuildSubsetterOptions) ![]const u8 {
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

        const b = try self.build_complete_font(glyph_ids);
        return b;
    }

    inline fn build_complete_font(self: *Self, glyph_ids: []u16) ![]u8 {
        var tables_to_build = std.ArrayList(Builder).init(self.allocator);
        defer tables_to_build.deinit();

        for (ALL_TABLES) |table_builder| {
            const should_build = table_builder.required or
                (table_builder.condition_fn != null and table_builder.condition_fn.?(self));

            if (should_build) {
                try tables_to_build.append(table_builder);
            }
        }

        std.sort.heap(Builder, tables_to_build.items, {}, struct {
            fn lessThan(_: void, a: Builder, b: Builder) bool {
                return std.mem.order(u8, &a.tag.to_str(), &b.tag.to_str()) == .lt;
            }
        }.lessThan);

        const num_tables: u16 = @intCast(ALL_TABLES.len);
        const sfnt_header_size: u16 = 12;
        const table_record_size = 16 * num_tables;
        const headers_size = sfnt_header_size + table_record_size;

        const zero_buffer = try self.allocator.alloc(u8, headers_size);
        defer self.allocator.free(zero_buffer);
        @memset(zero_buffer, 0);
        try self.main_buffer.write_bytes(zero_buffer);

        for (tables_to_build.items) |table_builder| {
            try table_builder.build_fn(self, glyph_ids);
        }
        try self.write_sfnt_header();

        const font_data = try self.main_buffer.to_owned_slice();
        try self.update_head_checksum_adjustment(font_data);

        return font_data;
    }

    fn update_head_checksum_adjustment(self: *Self, font_data: []u8) !void {
        var head_offset: ?u32 = null;
        for (self.table_infos.items) |table_info| {
            if (table_info.tag == .head) {
                head_offset = table_info.offset;
                break;
            }
        }

        if (head_offset == null) return;

        const adjustment_offset = head_offset.? + 8;

        std.mem.writeInt(u32, font_data[adjustment_offset .. adjustment_offset + 4][0..4], 0, .big);

        const font_checksum = calculate_checksum(font_data);

        const checksum_adjustment = 0xB1B0AFBA -% font_checksum;

        std.mem.writeInt(u32, font_data[adjustment_offset .. adjustment_offset + 4][0..4], checksum_adjustment, .big);
    }

    fn pad_to_alignment(self: *Self) !void {
        const current_len = self.main_buffer.len();
        const remainder = current_len % 4;
        if (remainder != 0) {
            const padding = 4 - remainder;
            for (0..padding) |_| {
                try self.main_buffer.write_u8(0);
            }
        }
    }

    fn calculate_checksum(data: []const u8) u32 {
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

    fn write_sfnt_header(self: *Self) !void {
        std.debug.assert(self.table_infos.items.len >= 1);
        std.sort.heap(TableRecord, self.table_infos.items, {}, struct {
            fn lessThan(_: void, a: TableRecord, b: TableRecord) bool {
                return @intFromEnum(a.tag) < @intFromEnum(b.tag);
            }
        }.lessThan);

        const num_tables: u16 = @intCast(self.table_infos.items.len);

        var search_range: u16 = 16;
        var entry_selector: u16 = 0;
        while (search_range <= num_tables) {
            search_range *= 2;
            entry_selector += 1;
        }
        search_range /= 2;
        const range_shift: u16 = num_tables * 16 - search_range;

        const buffer = self.main_buffer.buffer.items;

        std.mem.writeInt(u32, @ptrCast(buffer[0..4]), 0x00010000, .big);
        std.mem.writeInt(u16, @ptrCast(buffer[4..6]), num_tables, .big);
        std.mem.writeInt(u16, @ptrCast(buffer[6..8]), search_range, .big);
        std.mem.writeInt(u16, @ptrCast(buffer[8..10]), @intCast(entry_selector), .big);
        std.mem.writeInt(u16, @ptrCast(buffer[10..12]), range_shift, .big);

        var record_offset: usize = 12;
        for (self.table_infos.items) |table_info| {
            const start = record_offset;
            std.mem.writeInt(u32, @ptrCast(buffer[start .. start + 4]), @intFromEnum(table_info.tag), .big);
            std.mem.writeInt(u32, @ptrCast(buffer[start + 4 .. start + 8]), table_info.checksum, .big);
            std.mem.writeInt(u32, @ptrCast(buffer[start + 8 .. start + 12]), table_info.offset, .big);
            std.mem.writeInt(u32, @ptrCast(buffer[start + 12 .. start + 16]), table_info.length, .big);
            record_offset += 16;
        }
    }
    fn get_default_binary_data(self: *Self, tag: parser.TableTag, end_position: ?usize) []const u8 {
        const record = self.t.parser.find_table_record(tag).?;
        const len = if (end_position) |pos| record.offset + pos else record.offset + record.length;
        const table_data = self.t.parser.buffer[record.offset..len];
        return table_data;
    }

    fn build_head_table(self: *Self, glyph_ids: []u16) !void {
        const start_offset: u32 = @intCast(self.main_buffer.len());
        const head_table = self.t.parser.parsed_tables.head.?;
        const head = head_table.cast(table.Head);

        try self.main_buffer.write(u16, head.major_version, .big);
        try self.main_buffer.write(u16, head.minor_version, .big);
        try self.main_buffer.write(u32, head.font_revision, .big);

        try self.main_buffer.write(u32, 0, .big);

        try self.main_buffer.write(u32, 0x5F0F3CF5, .big);
        try self.main_buffer.write(u16, head.flags, .big);
        try self.main_buffer.write(u16, head.units_per_em, .big);
        try self.main_buffer.write(i64, head.created, .big);
        try self.main_buffer.write(i64, head.modified, .big);

        var x_min: i16 = 32767;
        var y_min: i16 = 32767;
        var x_max: i16 = -32768;
        var y_max: i16 = -32768;
        var has_valid_bounds = false;

        for (glyph_ids) |glyph_id| {
            const glyph_info = try self.r.get_glyph_info(glyph_id);
            if (glyph_info.has_outline) {
                if (!has_valid_bounds) {
                    x_min = glyph_info.bbox.x_min;
                    y_min = glyph_info.bbox.y_min;
                    x_max = glyph_info.bbox.x_max;
                    y_max = glyph_info.bbox.y_max;
                    has_valid_bounds = true;
                } else {
                    x_min = @min(x_min, glyph_info.bbox.x_min);
                    y_min = @min(y_min, glyph_info.bbox.y_min);
                    x_max = @max(x_max, glyph_info.bbox.x_max);
                    y_max = @max(y_max, glyph_info.bbox.y_max);
                }
            }
        }

        if (!has_valid_bounds) {
            x_min = head.x_min;
            y_min = head.y_min;
            x_max = head.x_max;
            y_max = head.y_max;
        }

        try self.main_buffer.write(i16, x_min, .big);
        try self.main_buffer.write(i16, y_min, .big);
        try self.main_buffer.write(i16, x_max, .big);
        try self.main_buffer.write(i16, y_max, .big);

        try self.main_buffer.write(u16, head.mac_style.to_u16(), .big);
        try self.main_buffer.write(u16, head.lowest_rec_ppem, .big);
        try self.main_buffer.write(i16, head.font_direction_hint, .big);
        try self.main_buffer.write(i16, head.index_to_loc_format, .big);
        try self.main_buffer.write(i16, head.glyph_data_format, .big);

        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .head,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn build_os2_table(self: *Self, glyph_ids: []u16) !void {
        const start_offset: u32 = @intCast(self.main_buffer.len());
        const os2_table = self.t.parser.parsed_tables.os2.?;
        const os2 = os2_table.cast(table.Os2);

        try self.main_buffer.write(u16, os2.version.to_u16(), .big);

        var avg_char_width: i16 = 0;
        if (glyph_ids.len > 0) {
            var total_width: u32 = 0;
            var count: u32 = 0;

            for (glyph_ids) |glyph_id| {
                const glyph_info = try self.r.get_glyph_info(glyph_id);
                total_width += glyph_info.advance_width;
                count += 1;
            }

            if (count > 0) {
                avg_char_width = @intCast(total_width / count);
            } else if (os2.v0_data) |v0| {
                avg_char_width = v0.x_avg_char_width;
            }
        } else if (os2.v0_data) |v0| {
            avg_char_width = v0.x_avg_char_width;
        }

        try self.main_buffer.write(i16, avg_char_width, .big);

        const v0 = os2.v0_data.?;

        try self.main_buffer.write(u16, v0.us_weight_class, .big);
        try self.main_buffer.write(u16, v0.us_width_class, .big);
        try self.main_buffer.write(u16, v0.fs_type, .big);
        try self.main_buffer.write(i16, v0.y_subscript_x_size, .big);
        try self.main_buffer.write(i16, v0.y_subscript_y_size, .big);
        try self.main_buffer.write(i16, v0.y_subscript_x_offset, .big);
        try self.main_buffer.write(i16, v0.y_subscript_y_offset, .big);
        try self.main_buffer.write(i16, v0.y_superscript_x_size, .big);
        try self.main_buffer.write(i16, v0.y_superscript_y_size, .big);
        try self.main_buffer.write(i16, v0.y_superscript_x_offset, .big);
        try self.main_buffer.write(i16, v0.y_superscript_y_offset, .big);
        try self.main_buffer.write(i16, v0.y_strikeout_size, .big);
        try self.main_buffer.write(i16, v0.y_strikeout_position, .big);
        try self.main_buffer.write(i16, v0.s_family_class, .big);

        try self.main_buffer.write_bytes(&v0.panose);

        var unicode_ranges: [4]u32 = [_]u32{0} ** 4;

        var code_point_iter = self.r.code_point_cache.iterator();
        while (code_point_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const cached_glyph_ids = entry.value_ptr.*;

            var in_subset = false;
            for (cached_glyph_ids) |cached_glyph_id| {
                for (glyph_ids) |subset_glyph_id| {
                    if (subset_glyph_id == cached_glyph_id) {
                        in_subset = true;
                        break;
                    }
                }
                if (in_subset) break;
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

        try self.main_buffer.write(u32, unicode_ranges[0], .big);
        try self.main_buffer.write(u32, unicode_ranges[1], .big);
        try self.main_buffer.write(u32, unicode_ranges[2], .big);
        try self.main_buffer.write(u32, unicode_ranges[3], .big);

        try self.main_buffer.write_bytes(&v0.ach_vend_id);
        try self.main_buffer.write(u16, v0.fs_selection, .big);

        var first_char_index: u16 = 0xFFFF;
        var last_char_index: u16 = 0;

        code_point_iter = self.r.code_point_cache.iterator();
        while (code_point_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const cached_glyph_ids = entry.value_ptr.*;

            var in_subset = false;
            for (cached_glyph_ids) |cached_glyph_id| {
                for (glyph_ids) |subset_glyph_id| {
                    if (subset_glyph_id == cached_glyph_id) {
                        in_subset = true;
                        break;
                    }
                }
                if (in_subset) break;
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

        try self.main_buffer.write(u16, first_char_index, .big);
        try self.main_buffer.write(u16, last_char_index, .big);
        try self.main_buffer.write(i16, v0.s_typo_ascender, .big);
        try self.main_buffer.write(i16, v0.s_typo_descender, .big);
        try self.main_buffer.write(i16, v0.s_typo_line_gap, .big);
        try self.main_buffer.write(u16, v0.us_win_ascent, .big);
        try self.main_buffer.write(u16, v0.us_win_descent, .big);

        if (os2.version.to_u16() >= 1) {
            if (os2.v1_data) |v1| {
                try self.main_buffer.write(u32, v1.ul_code_page_range1, .big);
                try self.main_buffer.write(u32, v1.ul_code_page_range2, .big);
            } else {
                try self.main_buffer.write(u32, 0, .big);
                try self.main_buffer.write(u32, 0, .big);
            }
        }

        if (os2.version.to_u16() >= 2) {
            if (os2.v2_data) |v2| {
                try self.main_buffer.write(i16, v2.sx_height, .big);
                try self.main_buffer.write(i16, v2.s_cap_height, .big);
                try self.main_buffer.write(u16, v2.us_default_char, .big);
                try self.main_buffer.write(u16, v2.us_break_char, .big);
                try self.main_buffer.write(u16, v2.us_max_context, .big);
            } else {
                try self.main_buffer.write(i16, 0, .big);
                try self.main_buffer.write(i16, 0, .big);
                try self.main_buffer.write(u16, 0, .big);
                try self.main_buffer.write(u16, 32, .big);
                try self.main_buffer.write(u16, 0, .big);
            }
        }

        if (os2.version.to_u16() >= 5) {
            if (os2.v5_data) |v5| {
                try self.main_buffer.write(u16, v5.us_lower_optical_point_size, .big);
                try self.main_buffer.write(u16, v5.us_upper_optical_point_size, .big);
            } else {
                try self.main_buffer.write(u16, 0, .big);
                try self.main_buffer.write(u16, 0xFFFF, .big);
            }
        }

        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .os2,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn build_name_table(self: *Self, glyph_ids: []u16) !void {
        std.debug.assert(glyph_ids.len >= 1);
        const start_offset: u32 = @intCast(self.main_buffer.len());

        const table_data = self.get_default_binary_data(.name, null);
        try self.main_buffer.write_bytes(table_data);

        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .name,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn build_maxp_table(self: *Self, glyph_ids: []u16) !void {
        const start_offset: u32 = @intCast(self.main_buffer.len());
        const maxp_table = self.t.parser.parsed_tables.maxp.?;
        const maxp = maxp_table.cast(table.Maxp);
        try self.main_buffer.write(u32, maxp.version, .big);
        try self.main_buffer.write(u16, @intCast(glyph_ids.len), .big);

        if (maxp.version == 0x00010000) {
            const loca_table = self.t.parser.parsed_tables.loca.?;
            const loca = loca_table.cast(table.Loca);
            const glyf_table = self.t.parser.parsed_tables.glyf.?;
            const glyf = glyf_table.cast(table.Glyf);

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

            const full_maxp_data = self.get_default_binary_data(.maxp, null);
            const offset = 6 + (4 * 2);
            const rest_data = full_maxp_data[offset..];

            try self.main_buffer.write(u16, max_points, .big);
            try self.main_buffer.write(u16, max_contours, .big);
            try self.main_buffer.write(u16, max_composite_points, .big);
            try self.main_buffer.write(u16, max_composite_contours, .big);
            try self.main_buffer.write_bytes(rest_data);
        }
        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;
        try self.table_infos.append(TableRecord{
            .tag = .maxp,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn build_loca_table(self: *Self, glyph_ids: []u16) !void {
        const glyf_info = blk: {
            for (self.table_infos.items) |info| {
                if (info.tag == .glyf) {
                    break :blk info;
                }
            }
            return error.MissingRequiredDependency;
        };
        const glyf_data = self.main_buffer.buffer.items[glyf_info.offset .. glyf_info.offset + glyf_info.length];
        const max_offset: u32 = @intCast(glyf_data.len);
        const is_short_format = max_offset <= 0x1FFFE;
        const start_offset: u32 = @intCast(self.main_buffer.len());
        var current_offset: u32 = 0;
        const loca_table = self.t.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);
        for (glyph_ids) |glyph_id| {
            if (is_short_format) {
                try self.main_buffer.write(u16, @intCast(current_offset / 2), .big);
            } else {
                try self.main_buffer.write(u32, current_offset, .big);
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
            try self.main_buffer.write(u16, @intCast(current_offset / 2), .big);
        } else {
            try self.main_buffer.write(u32, current_offset, .big);
        }

        try self.pad_to_alignment();
        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .loca,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn build_glyf_table(self: *Self, glyph_ids: []u16) !void {
        const start_offset: u32 = @intCast(self.main_buffer.len());
        const glyf_table = self.t.parser.parsed_tables.glyf.?;
        const loca_table = self.t.parser.parsed_tables.loca.?;
        const glyf = glyf_table.cast(table.Glyf);
        const loca = loca_table.cast(table.Loca);

        var glyph_id_mapping = AutoHashMap(u16, u16).init(self.allocator);
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
                                try write_glyph_header(&self.main_buffer, simple.header);
                                for (simple.end_pts_of_contours) |end_pt| {
                                    try self.main_buffer.write(u16, end_pt, .big);
                                }
                                try self.main_buffer.write(u16, @intCast(simple.instructions.len), .big);
                                try self.main_buffer.write_bytes(simple.instructions);
                                var i: usize = 0;
                                const flags = simple.flags;
                                while (i < flags.len) {
                                    const flag = flags[i];
                                    try self.main_buffer.write_u8(flag);

                                    if ((flag & 0x08) != 0) {
                                        var repeat_count: u8 = 0;
                                        var j = i + 1;
                                        while (j < flags.len and j < i + 256 and flags[j] == flag) {
                                            repeat_count += 1;
                                            j += 1;
                                        }
                                        if (repeat_count > 0) {
                                            try self.main_buffer.write_u8(repeat_count);
                                            i = j;
                                            continue;
                                        }
                                    }
                                    i += 1;
                                }

                                var prev_x: i16 = 0;
                                for (simple.x_coordinates, 0..) |x, idx| {
                                    const flag = flags[idx];
                                    const delta = x - prev_x;

                                    if ((flag & 0x02) != 0) {
                                        try self.main_buffer.write_u8(@intCast(@abs(delta)));
                                    } else if ((flag & 0x10) == 0) {
                                        try self.main_buffer.write(i16, delta, .big);
                                    }
                                    prev_x = x;
                                }

                                var prev_y: i16 = 0;
                                for (simple.y_coordinates, 0..) |y, idx| {
                                    const flag = flags[idx];
                                    const delta = y - prev_y;

                                    if ((flag & 0x04) != 0) {
                                        try self.main_buffer.write_u8(@intCast(@abs(delta)));
                                    } else if ((flag & 0x20) == 0) {
                                        try self.main_buffer.write(i16, delta, .big);
                                    }
                                    prev_y = y;
                                }
                            },
                            .composite => |composite| {
                                try write_glyph_header(&self.main_buffer, composite.header);
                                for (composite.components, 0..) |component, i| {
                                    const is_last = (i == composite.components.len - 1);
                                    var flags = component.flags;

                                    if (is_last) {
                                        flags &= ~@as(u16, 0x0020);
                                    } else {
                                        flags |= 0x0020;
                                    }

                                    try self.main_buffer.write(u16, flags, .big);

                                    const new_glyph_index = glyph_id_mapping.get(component.glyph_index) orelse component.glyph_index;
                                    try self.main_buffer.write(u16, new_glyph_index, .big);

                                    if ((flags & 0x0001) != 0) {
                                        try self.main_buffer.write(i16, @intCast(component.arg1), .big);
                                        try self.main_buffer.write(i16, @intCast(component.arg2), .big);
                                    } else {
                                        try self.main_buffer.write_u8(@bitCast(@as(i8, @intCast(component.arg1))));
                                        try self.main_buffer.write_u8(@bitCast(@as(i8, @intCast(component.arg2))));
                                    }

                                    switch (component.transform) {
                                        .scale => |scale| {
                                            const scale_raw: i16 = @intFromFloat(scale.scale * 16384.0);
                                            try self.main_buffer.write(i16, scale_raw, .big);
                                        },
                                        .xy_scale => |xy_scale| {
                                            const x_scale_raw: i16 = @intFromFloat(xy_scale.x_scale * 16384.0);
                                            const y_scale_raw: i16 = @intFromFloat(xy_scale.y_scale * 16384.0);
                                            try self.main_buffer.write(i16, x_scale_raw, .big);
                                            try self.main_buffer.write(i16, y_scale_raw, .big);
                                        },
                                        .matrix => |matrix| {
                                            const xx_raw: i16 = @intFromFloat(matrix.xx * 16384.0);
                                            const xy_raw: i16 = @intFromFloat(matrix.xy * 16384.0);
                                            const yx_raw: i16 = @intFromFloat(matrix.yx * 16384.0);
                                            const yy_raw: i16 = @intFromFloat(matrix.yy * 16384.0);
                                            try self.main_buffer.write(i16, xx_raw, .big);
                                            try self.main_buffer.write(i16, xy_raw, .big);
                                            try self.main_buffer.write(i16, yx_raw, .big);
                                            try self.main_buffer.write(i16, yy_raw, .big);
                                        },
                                        .none => {},
                                    }
                                }

                                if (composite.instructions.len > 0) {
                                    try self.main_buffer.write(u16, @intCast(composite.instructions.len), .big);
                                    try self.main_buffer.write_bytes(composite.instructions);
                                }
                            },
                        }
                    } else |_| {
                        continue;
                    }
                }
            }
            try self.pad_to_alignment();
        }
        try self.pad_to_alignment();
        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .glyf,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn write_glyph_header(buffer: *Writer(u8), header: table.Glyf.GlyphHeader) !void {
        try buffer.write(i16, header.number_of_contours, .big);
        try buffer.write(i16, header.x_min, .big);
        try buffer.write(i16, header.y_min, .big);
        try buffer.write(i16, header.x_max, .big);
        try buffer.write(i16, header.y_max, .big);
    }

    fn build_cmap_table(self: *Self, glyph_ids: []u16) !void {
        const start_offset: u32 = @intCast(self.main_buffer.len());

        var codepoint_to_new_glyph = AutoHashMap(u32, u16).init(self.allocator);
        defer codepoint_to_new_glyph.deinit();

        var glyph_id_mapping = AutoHashMap(u16, u16).init(self.allocator);
        defer glyph_id_mapping.deinit();

        for (glyph_ids, 0..) |glyph_id, new_index| {
            try glyph_id_mapping.put(glyph_id, @intCast(new_index));
        }

        var code_point_iter = self.r.code_point_cache.iterator();
        while (code_point_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            const old_glyph_ids = entry.value_ptr.*;

            for (old_glyph_ids) |old_glyph_id| {
                if (glyph_id_mapping.get(old_glyph_id)) |new_glyph_id| {
                    try codepoint_to_new_glyph.put(codepoint, new_glyph_id);
                    break;
                }
            }
        }

        if (codepoint_to_new_glyph.count() == 0) {
            try self.create_minimal_cmap();
            return;
        }

        var has_high_codepoints = false;
        var max_codepoint: u32 = 0;
        var codepoint_iter = codepoint_to_new_glyph.iterator();
        while (codepoint_iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            max_codepoint = @max(max_codepoint, codepoint);
            if (codepoint > 0xFFFF) {
                has_high_codepoints = true;
            }
        }

        try self.main_buffer.write(u16, 0, .big);

        if (has_high_codepoints) {
            try self.main_buffer.write(u16, 2, .big);

            try self.main_buffer.write(u16, 3, .big);
            try self.main_buffer.write(u16, 1, .big);
            try self.main_buffer.write(u32, 20, .big);

            try self.main_buffer.write(u16, 3, .big);
            try self.main_buffer.write(u16, 10, .big);
            const format12_offset = try self.calculate_format4_size(codepoint_to_new_glyph, false) + 20;
            try self.main_buffer.write(u32, format12_offset, .big);

            try self.generate_format4_subtable(codepoint_to_new_glyph, false);

            try self.generate_format12_subtable(codepoint_to_new_glyph);
        } else {
            try self.main_buffer.write(u16, 1, .big);

            try self.main_buffer.write(u16, 3, .big);
            try self.main_buffer.write(u16, 1, .big);
            try self.main_buffer.write(u32, 12, .big);

            try self.generate_format4_subtable(codepoint_to_new_glyph, true);
        }

        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .cmap,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn create_minimal_cmap(self: *Self) !void {
        try self.main_buffer.write(u16, 0, .big);
        try self.main_buffer.write(u16, 1, .big);

        try self.main_buffer.write(u16, 3, .big);
        try self.main_buffer.write(u16, 1, .big);
        try self.main_buffer.write(u32, 12, .big);

        try self.main_buffer.write(u16, 4, .big);
        try self.main_buffer.write(u16, 32, .big);
        try self.main_buffer.write(u16, 0, .big);
        try self.main_buffer.write(u16, 4, .big);
        try self.main_buffer.write(u16, 4, .big);
        try self.main_buffer.write(u16, 1, .big);
        try self.main_buffer.write(u16, 0, .big);

        try self.main_buffer.write(u16, 0xFFFF, .big);
        try self.main_buffer.write(u16, 0xFFFF, .big);

        try self.main_buffer.write(u16, 0, .big);

        try self.main_buffer.write(u16, 0xFFFF, .big);
        try self.main_buffer.write(u16, 0xFFFF, .big);

        try self.main_buffer.write(i16, 1, .big);
        try self.main_buffer.write(i16, 1, .big);

        try self.main_buffer.write(u16, 0, .big);
        try self.main_buffer.write(u16, 0, .big);
    }

    fn calculate_format4_size(self: *Self, codepoint_to_glyph: AutoHashMap(u32, u16), include_all: bool) !u32 {
        var codepoints = std.ArrayList(u32).init(self.allocator);
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

        var segments = std.ArrayList(struct { start: u16, end: u16 }).init(self.allocator);
        defer segments.deinit();

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

    fn generate_format4_subtable(self: *Self, codepoint_to_glyph: AutoHashMap(u32, u16), include_all: bool) !void {
        var codepoints = std.ArrayList(u32).init(self.allocator);
        defer codepoints.deinit();

        var iter = codepoint_to_glyph.iterator();
        while (iter.next()) |entry| {
            const codepoint = entry.key_ptr.*;
            if (include_all or codepoint <= 0xFFFF) {
                try codepoints.append(codepoint);
            }
        }

        if (codepoints.items.len == 0) {
            try self.create_minimal_format4_subtable();
            return;
        }

        std.sort.heap(u32, codepoints.items, {}, std.sort.asc(u32));

        var segments = std.ArrayList(struct { start: u16, end: u16, glyph_id: u16 }).init(self.allocator);
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

        try self.main_buffer.write(u16, 4, .big);
        try self.main_buffer.write(u16, length, .big);
        try self.main_buffer.write(u16, 0, .big);
        try self.main_buffer.write(u16, seg_count_x2, .big);
        try self.main_buffer.write(u16, search_range, .big);
        try self.main_buffer.write(u16, entry_selector, .big);
        try self.main_buffer.write(u16, range_shift, .big);

        for (segments.items) |segment| {
            try self.main_buffer.write(u16, segment.end, .big);
        }
        try self.main_buffer.write(u16, 0xFFFF, .big);

        try self.main_buffer.write(u16, 0, .big);

        for (segments.items) |segment| {
            try self.main_buffer.write(u16, segment.start, .big);
        }
        try self.main_buffer.write(u16, 0xFFFF, .big);

        for (segments.items) |segment| {
            const id_delta: i16 = @intCast(@as(i32, segment.glyph_id) - @as(i32, segment.start));
            try self.main_buffer.write(i16, id_delta, .big);
        }
        try self.main_buffer.write(i16, 1, .big);

        for (0..seg_count) |_| {
            try self.main_buffer.write(u16, 0, .big);
        }
    }

    fn create_minimal_format4_subtable(self: *Self) !void {
        try self.main_buffer.write(u16, 4, .big);
        try self.main_buffer.write(u16, 32, .big);
        try self.main_buffer.write(u16, 0, .big);
        try self.main_buffer.write(u16, 4, .big);
        try self.main_buffer.write(u16, 4, .big);
        try self.main_buffer.write(u16, 1, .big);
        try self.main_buffer.write(u16, 0, .big);

        try self.main_buffer.write(u16, 0xFFFF, .big);
        try self.main_buffer.write(u16, 0xFFFF, .big);

        try self.main_buffer.write(u16, 0, .big);

        try self.main_buffer.write(u16, 0xFFFF, .big);
        try self.main_buffer.write(u16, 0xFFFF, .big);

        try self.main_buffer.write(i16, 1, .big);
        try self.main_buffer.write(i16, 1, .big);

        try self.main_buffer.write(u16, 0, .big);
        try self.main_buffer.write(u16, 0, .big);
    }

    fn generate_format12_subtable(self: *Self, codepoint_to_glyph: AutoHashMap(u32, u16)) !void {
        var codepoints = std.ArrayList(u32).init(self.allocator);
        defer codepoints.deinit();

        var iter = codepoint_to_glyph.iterator();
        while (iter.next()) |entry| {
            try codepoints.append(entry.key_ptr.*);
        }

        std.sort.heap(u32, codepoints.items, {}, std.sort.asc(u32));

        var groups = std.ArrayList(struct { start: u32, end: u32, glyph_id: u32 }).init(self.allocator);
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

        try self.main_buffer.write(u16, 12, .big);
        try self.main_buffer.write(u16, 0, .big);
        try self.main_buffer.write(u32, length, .big);
        try self.main_buffer.write(u32, 0, .big);
        try self.main_buffer.write(u32, @intCast(groups.items.len), .big);

        for (groups.items) |group| {
            try self.main_buffer.write(u32, group.start, .big);
            try self.main_buffer.write(u32, group.end, .big);
            try self.main_buffer.write(u32, group.glyph_id, .big);
        }
    }
    fn build_hmtx_table(self: *Self, glyph_ids: []u16) !void {
        const start_offset: u32 = @intCast(self.main_buffer.len());
        const hmtx_table = self.t.parser.parsed_tables.hmtx.?;
        const hmtx = hmtx_table.cast(table.Hmtx);

        for (glyph_ids) |gid| {
            const metrics = hmtx.get_metrics(gid);
            try self.main_buffer.write(u16, metrics.advance_width, .big);
            try self.main_buffer.write(i16, metrics.left_side_bearing, .big);
        }
        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;
        try self.table_infos.append(TableRecord{
            .tag = .hmtx,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn build_post_table(self: *Self, glyph_ids: []u16) !void {
        std.debug.assert(glyph_ids.len >= 1);
        var post_table = self.t.parser.parsed_tables.post.?;
        const post = post_table.cast(table.Post);
        const start_offset: u32 = @intCast(self.main_buffer.len());

        const table_data = self.get_default_binary_data(.post, 32);

        try self.main_buffer.write_bytes(table_data);

        if (post.v2_data) |_| {
            try self.main_buffer.write(u16, @intCast(glyph_ids.len), .big);
            var has_custom_names = false;
            for (glyph_ids) |gid| {
                if (post.get_glyph_index(gid)) |glyph_index| {
                    try self.main_buffer.write(u16, glyph_index, .big);
                    if (glyph_index >= 258) {
                        has_custom_names = true;
                    }
                }
            }
            if (has_custom_names) {
                for (glyph_ids) |gid| {
                    if (post.get_glyph_index(gid)) |glyph_index| {
                        if (glyph_index >= 258) {
                            if (post.get_glyph_name(gid)) |glyph_name| {
                                try self.main_buffer.write_u8(@intCast(glyph_name.len));
                                try self.main_buffer.write_bytes(glyph_name);
                            }
                        }
                    }
                }
            }
        }

        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .post,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }

    fn build_hhea_table(self: *Self, glyph_ids: []u16) !void {
        const start_offset: u32 = @intCast(self.main_buffer.len());
        const hhea_table = self.t.parser.parsed_tables.hhea.?;
        const hhea = hhea_table.cast(table.Hhea);
        const glyf_table = self.t.parser.parsed_tables.glyf.?;
        const glyf = glyf_table.cast(table.Glyf);
        const loca_table = self.t.parser.parsed_tables.loca.?;
        const loca = loca_table.cast(table.Loca);
        const table_data = self.get_default_binary_data(.hhea, null);
        var advance_width_max: u16 = 0;
        var min_left_side_bearing: i16 = 0;
        var min_right_side_bearing: i16 = 0;
        var x_max_extent: i16 = 0;
        for (glyph_ids) |glyph_id| {
            const glyph_info = try self.r.get_glyph_info(glyph_id);
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

        try self.main_buffer.write_bytes(table_data[0..10]);
        try self.main_buffer.write(u16, advance_width_max, .big);
        try self.main_buffer.write(i16, min_left_side_bearing, .big);
        try self.main_buffer.write(i16, min_right_side_bearing, .big);
        try self.main_buffer.write(i16, x_max_extent, .big);

        if (table_data.len > 18) {
            try self.main_buffer.write_bytes(table_data[18 .. table_data.len - 2]);
            try self.main_buffer.write(u16, @intCast(glyph_ids.len), .big);
        }
        try self.pad_to_alignment();

        const end_offset: u32 = @intCast(self.main_buffer.len());
        const table_length = end_offset - start_offset;

        try self.table_infos.append(TableRecord{
            .tag = .hhea,
            .offset = start_offset,
            .length = table_length,
            .checksum = calculate_checksum(self.main_buffer.buffer.items[start_offset..end_offset]),
        });
    }
};

test "ttf.zig" {
    const fs = std.fs;
    const allocator = std.testing.allocator;
    // LXGWBright-Light.ttf
    // Caveat-VariableFont_wght.ttf
    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "LXGWBright-Light.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);
    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);
    var font = try ttf.init(allocator, file_content);
    defer font.deinit();
    var subbsetter = try font.subsetter();
    // const input_text = &[_]u8{ 0xC5, 0x84 };
    const input_text = "绪方理奈";
    std.debug.print("{s}\n", .{input_text});
    const result = try subbsetter.build_subset(BuildSubsetterOptions{ .input_text = input_text });
    defer allocator.free(result);

    try std.fs.cwd().writeFile(std.fs.Dir.WriteFileOptions{
        .sub_path = "./output.ttf",
        .data = result,
    });
}
