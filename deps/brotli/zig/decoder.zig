const Decoder = @This();
const log = std.log.scoped(.brotli_decoder);

allocator: std.mem.Allocator,
state: ?*c.BrotliDecoderState = null,
total_output_size: usize = 0,
decoded_data: std.ArrayListUnmanaged(u8) = .empty,

pub const Settings = struct {
    use_large_window: bool = false,
};

pub const DecodeResult = enum(c_uint) {
    err = c.BROTLI_DECODER_RESULT_ERROR,
    success = c.BROTLI_DECODER_RESULT_SUCCESS,
    need_more_input = c.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT,
    need_more_output = c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT,
};

pub const DecodeError = error{
    CannotCreateInstance,
    CannotSetParameter,
    GeneralError,
};

fn getError(decoder: ?*c.BrotliDecoderState) [*c]const u8 {
    return c.BrotliDecoderErrorString(c.BrotliDecoderGetErrorCode(decoder));
}

/// Decoder init
pub fn init(allocator: std.mem.Allocator, settings: Settings) !Decoder {
    const dec = Decoder{
        .allocator = allocator,
        .state = c.BrotliDecoderCreateInstance(null, null, null),
    };

    if (dec.state == null) {
        log.err("Failed to create Brotli decoder instance", .{});
        return DecodeError.CannotCreateInstance;
    }

    if (settings.use_large_window)
        if (c.BROTLI_TRUE != c.BrotliDecoderSetParameter(dec.state, c.BROTLI_DECODER_PARAM_LARGE_WINDOW, @intCast(c.BROTLI_TRUE))) {
            log.err("Could not set encoding quality.", .{});
            return DecodeError.CannotSetParameter;
        };
    return dec;
}

pub fn deinit(self: Decoder) void {
    defer c.BrotliDecoderDestroyInstance(self.state);
}

/// Decoder decode one_shot/stream
pub fn decode(self: *Decoder, encoded: []const u8) ![]const u8 {
    // free the ArrayListUnmanaged at the end of the decoding
    defer {
        if (self.decoded_data.items.len > 0) {
            self.decoded_data.deinit(self.allocator);
            self.decoded_data = .empty;
        }
    }

    const input: []u8 = try self.allocator.dupe(u8, encoded);
    defer self.allocator.free(input);
    var buf_size: usize = @max(input.len * 8, 8);
    var buf = try self.allocator.alloc(u8, buf_size);
    defer self.allocator.free(buf);

    var enc_size: usize = input.len;
    var enc_buf: [*c]const u8 = input.ptr;
    var dec_left: usize = buf_size;
    var dec_buf: [*c]u8 = buf.ptr;
    var dec_total: usize = 0;

    var result = DecodeResult.need_more_output;

    while (result == .need_more_output) {
        // fn BrotliDecoderDecompressStream(
        //     state: ?*BrotliDecoderState,
        //     available_in: [*c]usize,
        //     next_in: [*c][*c]const u8,
        //     available_out: [*c]usize,
        //     next_out: [*c][*c]u8,
        //     total_out: [*c]usize,
        // ) BrotliDecoderResult;
        result = @enumFromInt(c.BrotliDecoderDecompressStream(
            self.state,
            &enc_size,
            @ptrCast(&enc_buf),
            &dec_left,
            @ptrCast(&dec_buf),
            &dec_total,
        ));

        const dec_size: usize = buf_size - dec_left;
        try self.decoded_data.appendSlice(self.allocator, buf[0..dec_size]);

        // check that we really got all the output before asking for more input
        if (dec_left == 0 and result == .need_more_input) result = .need_more_output;
        // log.info("result: {}", .{result});

        switch (result) {
            .need_more_input, .success => {
                // send the decoded buffer back even if more input is needed:
                // - for stream: it's normal since there is no FINISH flag
                // - for one_shot: FINISH flag might be missing but the whole input has alredy been provided
                self.total_output_size = dec_total;
                return self.decoded_data.toOwnedSlice(self.allocator);
            },
            .need_more_output => {
                // double the size of the buffer for output
                buf_size = buf_size * 2;
                self.allocator.free(buf);
                buf = try self.allocator.alloc(u8, buf_size);
                dec_left = buf_size;
                dec_buf = buf.ptr;
            },
            .err => {
                log.err("got decoding error: {s}", .{getError(self.state)});
                return DecodeError.GeneralError;
            },
        }
    }

    // should never reach that point
    unreachable;
}

const std = @import("std");
pub const c = @cImport({
    @cInclude("brotli/encode.h");
    @cInclude("brotli/decode.h");
});
