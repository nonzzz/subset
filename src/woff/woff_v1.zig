const std = @import("std");
const reader = @import("../byte_read.zig");
const mod = @import("../parser.zig");
const Allocator = std.mem.Allocator;
const Head = @import("../table/head.zig");
const byte_writer = @import("../byte_writer.zig");

const zlib = std.compress.zlib;
const fs = std.fs;

const Parser = mod.Parser;
const ByteWriter = byte_writer.ByteWriter;

// https://www.w3.org/TR/WOFF/

pub const Woff = struct {
    const Self = @This();

    allocator: Allocator,
    parser: *Parser,
    compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,

    pub const Error = error{
        InvalidSfntVersion,
        CompressionFailed,
    };
    pub const TableRecord = struct {
        tag: mod.TableTag,
        offset: u32,
        comp_length: u32,
        orig_length: u32,
        orig_checksum: u32,
        compressed_data: []const u8,
    };

    pub fn init(
        allocator: Allocator,
        parser: *Parser,
        compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,
    ) Self {
        return Self{
            .allocator = allocator,
            .parser = parser,
            .compressor = compressor,
        };
    }

    pub fn as_woff(self: *Self) ![]u8 {
        var buffer = ByteWriter(u8).init(self.allocator);

        try self.parser.reader.seek_to(0);

        const sfnt = try self.parser.reader.read_u32_be();

        if (sfnt != 0x00010000) {
            return error.InvalidSfntVersion;
        }

        const num_tables = try self.parser.reader.read_u16_be();

        var woff_tables = std.ArrayList(TableRecord).init(self.allocator);
        defer {
            for (woff_tables.items) |rec| {
                self.allocator.free(rec.compressed_data);
            }
            woff_tables.deinit();
        }

        var total_sfnt_size: u32 = 12 + num_tables * 16;

        var total_compressed_size: u32 = 0;

        for (self.parser.table_records.items) |table_record| {
            const start = table_record.offset;
            const end = start + table_record.length;
            const table_data = self.parser.buffer[start..end];
            const compressed_data = try self.compressor(self.allocator, table_data);

            const use_compressed = compressed_data.len < table_data.len;
            const final_data = if (use_compressed) compressed_data else table_data;
            const comp_length: u32 = @intCast(final_data.len);
            const orig_length: u32 = table_record.length;

            const stored_data = if (use_compressed) compressed_data else blk: {
                const copy = try self.allocator.dupe(u8, table_data);
                self.allocator.free(compressed_data);
                break :blk copy;
            };

            try woff_tables.append(TableRecord{
                .tag = table_record.tag,
                .offset = 0,
                .comp_length = comp_length,
                .orig_length = orig_length,
                .orig_checksum = table_record.checksum,
                .compressed_data = stored_data,
            });
            total_compressed_size += comp_length;
            total_compressed_size = (total_compressed_size + 3) & ~@as(u32, 3);
            total_sfnt_size += orig_length;
            total_sfnt_size = (total_sfnt_size + 3) & ~@as(u32, 3);
        }
        const woff_header_size: u32 = 44;
        const table_directory_size: u32 = num_tables * 20;
        const total_size = woff_header_size + table_directory_size + total_compressed_size;

        // woff header
        try buffer.write(u32, 0x774F4646, .big);
        try buffer.write(u32, sfnt, .big);
        try buffer.write(u32, total_size, .big);
        try buffer.write(u16, num_tables, .big);
        try buffer.write(u16, 0, .big);

        try buffer.write(u32, total_sfnt_size, .big);

        if (self.parser.parsed_tables.get_table(.head)) |head_table| {
            const head = head_table.cast(Head);
            try buffer.write(u16, head.major_version, .big);
            try buffer.write(u16, head.minor_version, .big);
        } else {
            try buffer.write(u16, 0, .big);
            try buffer.write(u16, 1, .big);
        }

        try buffer.write(u32, 0, .big);
        try buffer.write(u32, 0, .big);
        try buffer.write(u32, 0, .big);

        try buffer.write(u32, 0, .big);
        try buffer.write(u32, 0, .big);

        var current_offset: u32 = woff_header_size + table_directory_size;
        for (woff_tables.items) |*woff_table| {
            woff_table.offset = current_offset;

            const tag_u32 = woff_table.tag.to_str();
            for (tag_u32) |byte| {
                try buffer.write(u8, byte, .big);
            }
            try buffer.write(u32, woff_table.offset, .big);
            try buffer.write(u32, woff_table.comp_length, .big);
            try buffer.write(u32, woff_table.orig_length, .big);
            try buffer.write(u32, woff_table.orig_checksum, .big);

            current_offset += woff_table.comp_length;
            current_offset = (current_offset + 3) & ~@as(u32, 3);
        }

        for (woff_tables.items) |woff_table| {
            try buffer.write_bytes(woff_table.compressed_data);

            const padding_size = (4 - (woff_table.comp_length % 4)) % 4;
            for (0..padding_size) |_| {
                try buffer.write_u8(0);
            }
        }

        return buffer.to_owned_slice();
    }
};

pub fn ttf_to_woff_v1(
    allocator: Allocator,
    data: []u8,
    compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,
) ![]u8 {
    var parser = try Parser.init(allocator, data);
    defer parser.deinit();
    try parser.parse();
    var woff = Woff.init(allocator, &parser, compressor);
    return woff.as_woff();
}

pub fn ttf_woff_v1_with_parser(
    allocator: Allocator,
    parser: *Parser,
    compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,
) ![]u8 {
    var woff = Woff.init(allocator, parser, compressor);
    return woff.as_woff();
}

// Mock compressor for testing purposes
fn mock_compressor(allocator: Allocator, data: []const u8) ![]u8 {
    var compressed_data = std.ArrayList(u8).init(allocator);
    defer compressed_data.deinit();

    var input_stream = std.io.fixedBufferStream(data);
    const output_writer = compressed_data.writer();
    try zlib.compress(input_stream.reader(), output_writer, .{});
    const compressed_slice = try compressed_data.toOwnedSlice();
    return compressed_slice;
}

test "woff " {
    const allocator = std.testing.allocator;

    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "LXGWBright-Light.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);

    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);

    var parser = try Parser.init(allocator, file_content);
    defer parser.deinit();
    try parser.parse();

    const woff_data = try ttf_woff_v1_with_parser(allocator, &parser, mock_compressor);
    defer allocator.free(woff_data);

    try std.testing.expect(woff_data.len >= 44);

    const magic = std.mem.readInt(u32, woff_data[0..4], .big);
    try std.testing.expectEqual(@as(u32, 0x774F4646), magic);

    const sfnt_version = std.mem.readInt(u32, woff_data[4..8], .big);
    const total_size = std.mem.readInt(u32, woff_data[8..12], .big);
    const num_tables = std.mem.readInt(u16, woff_data[12..14], .big);
    const reserved = std.mem.readInt(u16, woff_data[14..16], .big);
    const total_sfnt_size = std.mem.readInt(u32, woff_data[16..20], .big);

    try std.testing.expectEqual(@as(u32, 0x00010000), sfnt_version);
    try std.testing.expectEqual(@as(u32, @intCast(woff_data.len)), total_size);
    try std.testing.expectEqual(@as(u16, 0), reserved);
    try std.testing.expect(num_tables > 0);
    try std.testing.expect(total_sfnt_size > 0);

    const table_dir_start: u32 = 44;
    const table_dir_size = num_tables * 20;
    try std.testing.expect(woff_data.len >= table_dir_start + table_dir_size);
}
