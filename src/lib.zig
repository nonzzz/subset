const std = @import("std");
const mod = @import("./parser.zig");

const Parser = mod.Parser;
const TableTag = mod.TableTag;

const Allocator = std.mem.Allocator;

pub const Subset = struct {
    const Self = @This();

    allocator: Allocator,
    parser: Parser,

    pub fn init(allocator: Allocator, font_data: []const u8) !Self {
        var parser = try Parser.init(allocator, font_data);
        try parser.parse();

        return Self{
            .allocator = allocator,
            .parser = parser,
        };
    }

    pub fn deinit(self: *Self) void {
        self.parser.deinit();
    }

    pub fn add_text(self: *Self, text: []const u8) !void {
        // todo
        _ = text;
        _ = self;
    }

    pub fn add_character(self: *Self, ch: u32) !void {
        _ = ch;
        _ = self;
    }

    pub fn generate_subset(self: *Self) !void {
        // todo
        _ = self;
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
