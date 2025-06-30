const std = @import("std");
const reader = @import("../byte_read.zig");
const Table = @import("../table.zig");
const ParsedTables = @import("../parser.zig").ParsedTables;

const Allocator = std.mem.Allocator;

pub const HtmxTable = struct {
    const Self = @This();

    allocator: Allocator,
    byte_reader: *reader.ByteReader,
    parsed_tables: *ParsedTables,

    fn parse(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
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
};

pub fn init(allocator: Allocator, byte_reader: *reader.ByteReader, parsed_tables: *ParsedTables) !Table {
    return HtmxTable.init(allocator, byte_reader, parsed_tables);
}
