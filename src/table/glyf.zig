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

pub const GlyphHeader = struct {
    number_of_contours: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,

    pub fn is_simple(self: GlyphHeader) bool {
        return self.number_of_contours >= 0;
    }

    pub fn is_composite(self: GlyphHeader) bool {
        return self.number_of_contours < 0;
    }
};

pub const SimpleGlyph = struct {
    header: GlyphHeader,
    end_pts_of_contours: []u16,
    instructions: []u8,
    flags: []u8,
    x_coordinates: []i16,
    y_coordinates: []i16,

    pub fn deinit(self: *SimpleGlyph, allocator: Allocator) void {
        allocator.free(self.end_pts_of_contours);
        allocator.free(self.instructions);
        allocator.free(self.flags);
        allocator.free(self.x_coordinates);
        allocator.free(self.y_coordinates);
    }
};

pub const ParsedGlyph = union(enum) {
    simple: SimpleGlyph,

    pub fn deinit(self: *ParsedGlyph, allocator: Allocator) void {
        switch (self.*) {
            .simple => |*simple| simple.deinit(allocator),
        }
    }

    pub fn get_header(self: ParsedGlyph) GlyphHeader {
        return switch (self) {
            .simple => |simple| simple.header,
        };
    }
};

allocator: Allocator,
byte_reader: *reader.ByteReader,
parsed_tables: *ParsedTables,

table_offset: usize,

fn parse(ptr: *anyopaque) !void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.table_offset = self.byte_reader.current_offset();
}

fn deinit(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = undefined;
    self.allocator = allocator;
    self.byte_reader = byte_reader;
    self.parsed_tables = parsed_tables;

    return Table{
        .ptr = self,
        .vtable = &.{ .parse = parse, .deinit = deinit },
    };
}

fn parse_simple_glyph(self: *Self, glyph_header: GlyphHeader) void {
    var end_pts_of_contours = try self.allocator.alloc(u16, glyph_header.number_of_contours);
    errdefer self.allocator.free(end_pts_of_contours);
    for (0..glyph_header.number_of_contours) |i| {
        end_pts_of_contours[i] = try self.byte_reader.read_u16_be();
    }
    const instruction_length = try self.byte_reader.read_u16_be();

    var instructions = try self.allocator.alloc(u8, instruction_length);
    errdefer self.allocator.free(instructions);
    for (0..instruction_length) |i| {
        instructions[i] = try self.byte_reader.read_u8();
    }
    // The number of points is determined by the last entry in the endPtsOfContours array
    const variable = if (glyph_header.number_of_contours > 0) end_pts_of_contours[glyph_header.number_of_contours - 1] + 1 else 0;

    var flags = try self.allocator.alloc(u8, variable);
    errdefer self.allocator.free(flags);

    var flag_index: usize = 0;
    while (flag_index < variable) {
        const flag = try self.byte_reader.read_u8();
        flags[flag_index] = flag;

        flag_index += 1;

        if ((flag & 0x08) != 0 and flag_index < variable) {
            const repeat_count = try self.byte_reader.read_u8();
            for (0..repeat_count) |_| {
                if (flag_index >= variable) break;
                flags[flag_index] = flag;
                flag_index += 1;
            }
        }
    }

    var x_coordinates = try self.allocator.alloc(i16, variable);
    errdefer self.allocator.free(x_coordinates);

    var current_x: i16 = 0;
    for (0..variable) |i| {
        const flag = flags[i];
        if ((flag & 0x02) != 0) {
            const delta = try self.byte_reader.read_u8();
            if ((flag & 0x10) != 0) {
                current_x += @intCast(delta);
            } else {
                current_x -= @intCast(delta);
            }
        } else if ((flag & 0x10) == 0) {
            const delta = try self.byte_reader.read_i16_be();
            current_x += delta;
        }
        x_coordinates[i] = current_x;
    }

    var y_coordinates = try self.allocator.alloc(i16, variable);
    errdefer self.allocator.free(y_coordinates);

    var current_y: i16 = 0;
    for (0..variable) |i| {
        const flag = flags[i];
        if ((flag & 0x04) != 0) {
            const delta = try self.byte_reader.read_u8();
            if ((flag & 0x20) != 0) {
                current_y += @intCast(delta);
            } else {
                current_y -= @intCast(delta);
            }
        } else if ((flag & 0x20) == 0) {
            const delta = try self.byte_reader.read_i16_be();
            current_y += delta;
        }
        y_coordinates[i] = current_y;
    }

    return SimpleGlyph{
        .header = glyph_header,
        .end_pts_of_contours = end_pts_of_contours,
        .instructions = instructions,
        .flags = flags,
        .x_coordinates = x_coordinates,
        .y_coordinates = y_coordinates,
    };
}

// fn parse_composite_glyph(self: *Self, glyph_header: GlyphHeader, glyph_length: u32) void {
//     _ = self;
// }

pub fn parse_glyph(self: *Self, glyph_offset: u32) !void {
    try self.byte_reader.seek_to(self.table_offset + glyph_offset);

    const glyph_header = GlyphHeader{
        .number_of_contours = try self.byte_reader.read_i16_be(),
        .x_min = try self.byte_reader.read_i16_be(),
        .y_min = try self.byte_reader.read_i16_be(),
        .x_max = try self.byte_reader.read_i16_be(),
        .y_max = try self.byte_reader.read_i16_be(),
    };

    if (glyph_header.is_simple()) {
        const simple = try parse_simple_glyph(self, glyph_header);
        return ParsedGlyph{ .simple = simple };
    } else if (glyph_header.is_composite()) {
        // parse_composite_glyph(self, glyph_header);
    } else {
        return Error.InvalidGlyfTable;
    }
}
