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
    allocator: Allocator,

    pub fn deinit(self: *const SimpleGlyph) void {
        self.allocator.free(self.end_pts_of_contours);
        self.allocator.free(self.instructions);
        self.allocator.free(self.flags);
        self.allocator.free(self.x_coordinates);
        self.allocator.free(self.y_coordinates);
    }
};

pub const ComponentTransform = union(enum) {
    none,
    scale: struct { scale: f32 },
    xy_scale: struct { x_scale: f32, y_scale: f32 },
    matrix: struct { xx: f32, xy: f32, yx: f32, yy: f32 },
};

pub const CompositeComponent = struct {
    flags: u16,
    glyph_index: u16,
    arg1: i32,
    arg2: i32,
    transform: ComponentTransform,

    pub fn has_more_components(self: CompositeComponent) bool {
        return (self.flags & 0x0020) != 0;
    }

    pub fn args_are_words(self: CompositeComponent) bool {
        return (self.flags & 0x0001) != 0;
    }

    pub fn args_are_xy_values(self: CompositeComponent) bool {
        return (self.flags & 0x0002) != 0;
    }

    pub fn has_instructions(self: CompositeComponent) bool {
        return (self.flags & 0x0100) != 0;
    }
};

pub const CompositeGlyph = struct {
    header: GlyphHeader,
    components: []CompositeComponent,
    instructions: []u8,
    allocator: Allocator,

    pub fn deinit(self: *const CompositeGlyph) void {
        self.allocator.free(self.components);
        self.allocator.free(self.instructions);
    }
};

pub const ParsedGlyph = union(enum) {
    simple: SimpleGlyph,
    composite: CompositeGlyph,

    pub fn deinit(self: *const ParsedGlyph) void {
        switch (self.*) {
            .simple => |*simple| simple.deinit(),
            .composite => |*composite| composite.deinit(),
        }
    }

    pub fn get_header(self: ParsedGlyph) GlyphHeader {
        return switch (self) {
            .simple => |simple| simple.header,
            .composite => |composite| composite.header,
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

fn parse_simple_glyph(self: *Self, glyph_header: GlyphHeader) !SimpleGlyph {
    if (glyph_header.number_of_contours < 0)
        return Error.InvalidGlyfTable;
    const count: usize = @intCast(glyph_header.number_of_contours);
    var end_pts_of_contours = try self.allocator.alloc(u16, count);
    errdefer self.allocator.free(end_pts_of_contours);
    for (0..count) |i| {
        end_pts_of_contours[i] = try self.byte_reader.read_u16_be();
    }
    const instruction_length = try self.byte_reader.read_u16_be();

    var instructions = try self.allocator.alloc(u8, instruction_length);
    errdefer self.allocator.free(instructions);
    for (0..instruction_length) |i| {
        instructions[i] = try self.byte_reader.read_u8();
    }

    const variable = if (count > 0) end_pts_of_contours[count - 1] + 1 else 0;

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
        .allocator = self.allocator,
    };
}

fn parse_composite_glyph(self: *Self, glyph_header: GlyphHeader) !CompositeGlyph {
    var components = std.ArrayList(CompositeComponent).init(self.allocator);
    errdefer components.deinit();

    var has_more_components = true;

    while (has_more_components) {
        const flags = try self.byte_reader.read_u16_be();
        const glyph_index = try self.byte_reader.read_u16_be();

        var arg1: i32 = 0;
        var arg2: i32 = 0;

        if ((flags & 0x0001) != 0) {
            arg1 = try self.byte_reader.read_i16_be();
            arg2 = try self.byte_reader.read_i16_be();
        } else {
            arg1 = @as(i8, @bitCast(try self.byte_reader.read_u8()));
            arg2 = @as(i8, @bitCast(try self.byte_reader.read_u8()));
        }

        // https://learn.microsoft.com/en-us/typography/opentype/spec/glyf#composite-glyph-description

        const transform = if ((flags & 0x0008) != 0) blk: {
            const scale_raw = try self.byte_reader.read_i16_be();
            const scale = @as(f32, @floatFromInt(scale_raw)) / 16384.0;
            break :blk ComponentTransform{ .scale = .{ .scale = scale } };
        } else if ((flags & 0x0040) != 0) blk: {
            const x_scale_raw = try self.byte_reader.read_i16_be();
            const y_scale_raw = try self.byte_reader.read_i16_be();
            const x_scale = @as(f32, @floatFromInt(x_scale_raw)) / 16384.0;
            const y_scale = @as(f32, @floatFromInt(y_scale_raw)) / 16384.0;
            break :blk ComponentTransform{ .xy_scale = .{ .x_scale = x_scale, .y_scale = y_scale } };
        } else if ((flags & 0x0080) != 0) blk: {
            const xx_raw = try self.byte_reader.read_i16_be();
            const xy_raw = try self.byte_reader.read_i16_be();
            const yx_raw = try self.byte_reader.read_i16_be();
            const yy_raw = try self.byte_reader.read_i16_be();
            const xx = @as(f32, @floatFromInt(xx_raw)) / 16384.0;
            const xy = @as(f32, @floatFromInt(xy_raw)) / 16384.0;
            const yx = @as(f32, @floatFromInt(yx_raw)) / 16384.0;
            const yy = @as(f32, @floatFromInt(yy_raw)) / 16384.0;
            break :blk ComponentTransform{ .matrix = .{ .xx = xx, .xy = xy, .yx = yx, .yy = yy } };
        } else ComponentTransform.none;

        const component = CompositeComponent{
            .flags = flags,
            .glyph_index = glyph_index,
            .arg1 = arg1,
            .arg2 = arg2,
            .transform = transform,
        };

        try components.append(component);

        has_more_components = (flags & 0x0020) != 0;
    }

    var instructions: []u8 = &.{};

    if (components.items.len > 0) {
        const last_component = components.items[components.items.len - 1];
        if ((last_component.flags & 0x0100) != 0) {
            const instruction_length = try self.byte_reader.read_u16_be();
            instructions = try self.allocator.alloc(u8, instruction_length);
            errdefer self.allocator.free(instructions);

            for (0..instruction_length) |i| {
                instructions[i] = try self.byte_reader.read_u8();
            }
        }
    }

    return CompositeGlyph{
        .header = glyph_header,
        .components = try components.toOwnedSlice(),
        .instructions = instructions,
        .allocator = self.allocator,
    };
}

pub fn parse_glyph(self: *Self, glyph_offset: u32) !ParsedGlyph {
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
        const composite = try self.parse_composite_glyph(glyph_header);
        return ParsedGlyph{ .composite = composite };
    } else {
        return Error.InvalidGlyfTable;
    }
}
