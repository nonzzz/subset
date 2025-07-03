const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;
const Error = @import("./errors.zig").Error;

const Maxp = @import("./maxp.zig");
const Hhea = @import("./hhea.zig");

const Allocator = std.mem.Allocator;

const Self = @This();

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,
h_metrics: []LongHorMetric,

left_side_bearings: []i16,

pub const LongHorMetric = packed struct {
    advance_width: u16,
    lsb: i16,
};

fn parse(ptr: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    const hhea_table = self.parsed_tables.hhea orelse return Error.MissingHheaTable;
    const maxp_table = self.parsed_tables.maxp orelse return Error.MissingMaxpTable;

    const hhea = hhea_table.cast(Hhea);
    const maxp = maxp_table.cast(Maxp);

    const number_of_hmetrics = hhea.number_of_hmetrics;
    const num_glyphs = maxp.num_glyphs;

    var h_metrics = try self.allocator.alloc(LongHorMetric, number_of_hmetrics);

    errdefer self.allocator.free(h_metrics);

    for (0..number_of_hmetrics) |i| {
        h_metrics[i] = LongHorMetric{
            .advance_width = try self.byte_reader.read_u16_be(),
            .lsb = try self.byte_reader.read_i16_be(),
        };
    }

    const left_side_bearings_len = if (num_glyphs > number_of_hmetrics) num_glyphs - number_of_hmetrics else 0;

    var left_side_bearings = try self.allocator.alloc(i16, left_side_bearings_len);

    errdefer self.allocator.free(left_side_bearings);

    for (0..left_side_bearings_len) |i| {
        left_side_bearings[i] = try self.byte_reader.read_i16_be();
    }
    self.h_metrics = h_metrics;
    self.left_side_bearings = left_side_bearings;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));

    self.allocator.free(self.h_metrics);
    self.allocator.free(self.left_side_bearings);
    self.allocator.destroy(self);
}

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.allocator = allocator;
    self.byte_reader = byte_reader;
    self.parsed_tables = parsed_tables;
    self.h_metrics = &[_]LongHorMetric{};
    self.left_side_bearings = &[_]i16{};

    return Table{
        .ptr = self,
        .vtable = &.{ .parse = parse, .deinit = deinit },
    };
}

pub fn get_advance_width(self: *Self, glyph_index: u16) void {
    _ = self;
    _ = glyph_index;
}

pub fn get_left_side_bearing(self: *Self, glyph_index: u16) void {
    _ = self;
    _ = glyph_index;
}

test "parse hmtx table" {
    const allocator = std.testing.allocator;
    var byte_reader = reader.ByteReader.init(&[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 });
    var dummy_parsed_tables = ParsedTables{
        .hhea = null,
        .maxp = null,
    };

    var hmtx_table = try init(allocator, &byte_reader, &dummy_parsed_tables);
    defer hmtx_table.deinit();

    hmtx_table.parse() catch |err| {
        try std.testing.expect(err == Error.MissingHheaTable);
        return;
    };
}
