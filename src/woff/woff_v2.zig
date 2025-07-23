const brotli = @import("brotli");
const std = @import("std");
const byte_reader = @import("../byte_read.zig");
const mod = @import("../parser.zig");
const Head = @import("../table/head.zig");
const byte_writer = @import("../byte_writer.zig");
const Impl = @import("./impl.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const Parser = mod.Parser;
const ByteWriter = byte_writer.ByteWriter;

fn write_uint_base_128(buffer: *ByteWriter(u8), value: u32) !void {
    if (value < 0x80) {
        try buffer.write(u8, @intCast(value), .big);
        return;
    }

    var val = value;
    var bytes: [5]u8 = undefined;
    var count: u8 = 0;

    while (val >= 0x80) {
        bytes[count] = @intCast((val & 0x7F) | 0x80);
        val >>= 7;
        count += 1;
    }
    bytes[count] = @intCast(val);
    count += 1;

    var i: u8 = count;
    while (i > 0) {
        i -= 1;
        try buffer.write(u8, bytes[i], .big);
    }
}

/// SPEC: https://www.w3.org/TR/WOFF2/
///
/// Note This implementation isn't do fully optimized for WOFF2
///
/// To keep simple to implement, we don't use flags and other features
pub const Woff = struct {
    const Self = @This();

    allocator: Allocator,
    parser: *Parser,
    compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,

    pub const TableRecord = struct {
        flags: u8,
        tag: mod.TableTag,

        len: u32,
        start: u32,
        end: u32,
    };

    pub fn init(
        allocator: Allocator,
        parser: *Parser,
        compressor: *const fn (allocator: Allocator, data: []const u8) anyerror![]u8,
    ) Impl {
        const self = allocator.create(Self) catch unreachable;
        self.* = Self{
            .allocator = allocator,
            .parser = parser,
            .compressor = compressor,
        };
        return Impl{
            .ptr = self,
            .vtable = &.{
                .as_woff = as_woff,
            },
        };
    }

    fn as_woff(ptr: *anyopaque) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        defer self.allocator.destroy(self);
        var buffer = ByteWriter(u8).init(self.allocator);
        try self.parser.reader.seek_to(0);

        const sfnt = try self.parser.reader.read_u32_be();
        if (sfnt != 0x00010000) {
            return error.InvalidSfntVersion;
        }

        const num_tables = try self.parser.reader.read_u16_be();

        var woff2_tables = std.ArrayList(TableRecord).init(self.allocator);
        defer woff2_tables.deinit();

        var total_sfnt_size: u32 = 12 + num_tables * 16;
        for (self.parser.table_records.items) |table_record| {
            const start = table_record.offset;
            const end = start + table_record.length;
            const orig_length: u32 = table_record.length;

            try woff2_tables.append(TableRecord{
                .flags = 0,
                .tag = table_record.tag,
                .len = orig_length,
                .start = start,
                .end = end,
            });
        }
        std.mem.sort(
            TableRecord,
            woff2_tables.items,
            {},
            struct {
                fn less_than(_: void, lhs: TableRecord, rhs: TableRecord) bool {
                    return lhs.start < rhs.start;
                }
            }.less_than,
        );

        // const min_start = woff2_tables.items[0].start;
        // const max_end = woff2_tables.items[woff2_tables.items.len - 1].end;
        // const total_table_buffer = self.parser.buffer[min_start..max_end];
        // const compressed_data = try self.compressor(self.allocator, total_table_buffer);
        var table_data = std.ArrayList(u8).init(self.allocator);
        defer table_data.deinit();

        for (woff2_tables.items) |table| {
            const data = self.parser.buffer[table.start..table.end];
            try table_data.appendSlice(data);
        }

        const compressed_data = try self.compressor(self.allocator, table_data.items);

        defer self.allocator.free(compressed_data);
        total_sfnt_size += @intCast(table_data.items.len);
        // add padding to align to 4 bytes
        total_sfnt_size = (total_sfnt_size + 3) & ~@as(u32, 3);

        const compressed_data_len: u32 = @intCast(compressed_data.len);

        const woff2_header_size: u32 = 48;

        var total_size = woff2_header_size + compressed_data_len;

        // woff2 header
        try buffer.write(u32, 0x774F4632, .big);
        try buffer.write(u32, sfnt, .big);
        const woff2_length_start_offset: u32 = @intCast(buffer.len());
        try buffer.write(u32, 0, .big);
        try buffer.write(u16, num_tables, .big);
        try buffer.write(u16, 0, .big);
        try buffer.write(u32, total_sfnt_size, .big);
        try buffer.write(u32, compressed_data_len, .big);

        if (self.parser.parsed_tables.get_table(.head)) |head_table| {
            const head = head_table.cast(Head);
            try buffer.write(u16, head.major_version, .big);
            try buffer.write(u16, head.minor_version, .big);
        } else {
            try buffer.write(u16, 1, .big);
            try buffer.write(u16, 0, .big);
        }

        try buffer.write(u32, 0, .big);
        try buffer.write(u32, 0, .big);
        try buffer.write(u32, 0, .big);

        try buffer.write(u32, 0, .big);
        try buffer.write(u32, 0, .big);

        for (woff2_tables.items) |table| {
            const last_start: u32 = @intCast(buffer.len());
            try buffer.write(u8, table.flags, .big);
            try buffer.write_bytes(&table.tag.to_str());
            try write_uint_base_128(&buffer, table.len);
            try write_uint_base_128(&buffer, table.len);
            const last_end: u32 = @intCast(buffer.len());
            total_size += last_end - last_start;
        }

        try buffer.write_bytes(compressed_data);

        const cloned_slice = try buffer.to_owned_slice();
        const woff2_length_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, total_size));
        @memcpy(cloned_slice[woff2_length_start_offset .. woff2_length_start_offset + 4], &woff2_length_bytes);

        return cloned_slice;
    }
};

pub fn ttf_to_woff_v2(allocator: Allocator, data: []u8, compressor: Impl.Compressor) ![]u8 {
    var parser = try Parser.init(allocator, data);
    defer parser.deinit();
    try parser.parse();
    var woff = Woff.init(allocator, &parser, compressor);
    return woff.as_woff();
}

pub fn ttf_woff_v2_with_parser(allocator: Allocator, parser: *Parser, compressor: Impl.Compressor) ![]u8 {
    var woff = Woff.init(allocator, parser, compressor);
    return woff.as_woff();
}

// brotli mock
fn mock_compressor(allocator: Allocator, data: []const u8) ![]u8 {
    var encoder = try brotli.Encoder.init(allocator, .{ .quality = 4, .mode = .font });
    defer encoder.deinit();
    const compressed = try encoder.encode(data);
    return @constCast(compressed);
}

test "woff v2" {
    const allocator = std.testing.allocator;
    const font_file_path = fs.path.join(allocator, &.{ "./", "fonts", "LXGWBright-Light.ttf" }) catch unreachable;
    defer allocator.free(font_file_path);

    const file_content = try fs.cwd().readFileAlloc(allocator, font_file_path, std.math.maxInt(usize));
    defer allocator.free(file_content);

    var parser = try Parser.init(allocator, file_content);
    defer parser.deinit();
    try parser.parse();

    const woff_data = try ttf_woff_v2_with_parser(allocator, &parser, mock_compressor);
    defer allocator.free(woff_data);
    try fs.cwd().writeFile(fs.Dir.WriteFileOptions{
        .sub_path = "test.woff2",
        .data = woff_data,
    });
}
