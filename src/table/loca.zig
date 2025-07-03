const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;
const Error = @import("./errors.zig").Error;

const Maxp = @import("./maxp.zig");
const Head = @import("./head.zig");
const Cmap = @import("./cmap.zig");

const Allocator = std.mem.Allocator;

const Self = @This();

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

offsets: []u32,

fn parse(ptr: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    const head_table = self.parsed_tables.head orelse return Error.MissingHeadTable;
    const head = head_table.cast(Head);

    const maxp_table = self.parsed_tables.maxp orelse return Error.MissingMaxpTable;
    const maxp = maxp_table.cast(Maxp);

    const is_short_format = head.index_to_loc_format == 0;

    const num_glyphs = maxp.num_glyphs;

    var offsets = try self.allocator.alloc(u32, num_glyphs + 1);
    errdefer self.allocator.free(offsets);

    if (!is_short_format) {
        for (0..num_glyphs + 1) |i| {
            offsets[i] = try self.byte_reader.read_u32_be();
        }
    } else {
        for (0..num_glyphs + 1) |i| {
            offsets[i] = @as(u32, try self.byte_reader.read_u16_be()) * 2;
        }
    }
    self.offsets = offsets;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.allocator.free(self.offsets);
    self.allocator.destroy(self);
}

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = undefined;
    self.allocator = allocator;
    self.byte_reader = byte_reader;
    self.parsed_tables = parsed_tables;
    self.offsets = &[_]u32{};

    return Table{
        .ptr = self,
        .vtable = &.{ .parse = parse, .deinit = deinit },
    };
}

pub fn get_glyph_offset(self: *Self, glyph_id: u16) ?u32 {
    if (glyph_id >= self.offsets.len - 1) return null;
    return self.offsets[glyph_id];
}

pub fn get_glyph_length(self: *Self, glyph_id: u16) ?u32 {
    if (glyph_id >= self.offsets.len - 1) return null;
    const start = self.offsets[glyph_id];
    const end = self.offsets[glyph_id + 1];
    return if (end > start) end - start else null;
}

pub fn has_glyph_data(self: *Self, glyph_id: u16) bool {
    return self.get_glyph_length(glyph_id) != null;
}
