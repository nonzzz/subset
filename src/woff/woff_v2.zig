const std = @import("std");
const brotli = @import("brotli");

test "brotli round-trip encode/decode" {
    const allocator = std.testing.allocator;
    const input = "hello, world! this is a test for brotli encoder/decoder.";

    var encoder = try brotli.Encoder.init(allocator, .{});
    defer encoder.deinit();
    const compressed = try encoder.encode(input);

    var decoder = try brotli.Decoder.init(allocator, .{});
    defer decoder.deinit();
    const decompressed = try decoder.decode(compressed);

    try std.testing.expectEqualStrings(input, decompressed);

    allocator.free(compressed);
    allocator.free(decompressed);
}
