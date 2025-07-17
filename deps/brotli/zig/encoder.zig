const Encoder = @This();
const log = std.log.scoped(.brotli_encoder);

// https://datatracker.ietf.org/doc/html/rfc7932#section-9.2
// 3 represent the ISLAST and ISEMPTY bits
// of the Meta-Block Header
pub const streamEnd = [1]u8{3};

allocator: std.mem.Allocator,
settings: Settings,
state: ?*c.BrotliEncoderState = null,
total_output_size: usize = 0,
stream_output_size: usize = 0,

pub const Settings = struct {
    quality: c_int = c.BROTLI_DEFAULT_QUALITY,
    window: c_int = c.BROTLI_DEFAULT_WINDOW,
    large_window: bool = false,
    mode: Mode = .text,
    process: Process = .one_shot,
};

pub const Mode = enum(c_uint) {
    generic = c.BROTLI_MODE_GENERIC,
    text = c.BROTLI_MODE_TEXT,
    font = c.BROTLI_MODE_FONT,
};

pub const Process = enum(u2) {
    one_shot,
    stream,
};

pub const Operation = enum(c_uint) {
    process = c.BROTLI_OPERATION_PROCESS,
    flush = c.BROTLI_OPERATION_FLUSH,
    finish = c.BROTLI_OPERATION_FINISH,
    emit_meta = c.BROTLI_OPERATION_EMIT_METADATA,
};

pub const EncodeError = error{
    CannotCreateInstance,
    CannotSetParameter,
    GeneralError,
};

/// Encoder init
pub fn init(allocator: std.mem.Allocator, settings: Settings) !Encoder {
    var enc = Encoder{
        .allocator = allocator,
        .settings = settings,
    };

    enc.settings.quality = switch (settings.quality) {
        c.BROTLI_MIN_QUALITY...c.BROTLI_MAX_QUALITY => settings.quality,
        else => c.BROTLI_MAX_QUALITY,
    };

    enc.settings.window = switch (settings.window) {
        c.BROTLI_MIN_WINDOW_BITS...c.BROTLI_LARGE_MAX_WINDOW_BITS => settings.window,
        0...c.BROTLI_MIN_WINDOW_BITS - 1 => c.BROTLI_MIN_WINDOW_BITS,
        else => c.BROTLI_LARGE_MAX_WINDOW_BITS,
    };

    enc.settings.large_window = enc.settings.window > c.BROTLI_MAX_WINDOW_BITS;

    if (settings.process == .stream) {
        enc.state = c.BrotliEncoderCreateInstance(null, null, null);
        if (enc.state == null) {
            log.err("Failed to create Brotli encoder instance", .{});
            return EncodeError.CannotCreateInstance;
        }

        if (c.BROTLI_TRUE != c.BrotliEncoderSetParameter(enc.state, c.BROTLI_PARAM_QUALITY, @intCast(enc.settings.quality))) {
            log.err("Could not set encoding quality.", .{});
            return EncodeError.CannotSetParameter;
        }

        if (c.BROTLI_TRUE != c.BrotliEncoderSetParameter(enc.state, c.BROTLI_PARAM_LGWIN, @intCast(enc.settings.window))) {
            log.err("Could not set encoding window.", .{});
            return EncodeError.CannotSetParameter;
        }

        if (c.BROTLI_TRUE != c.BrotliEncoderSetParameter(enc.state, c.BROTLI_PARAM_MODE, @intFromEnum(enc.settings.mode))) {
            log.err("Could not set encoding mode.", .{});
            return EncodeError.CannotSetParameter;
        }

        if (enc.settings.large_window)
            if (c.BROTLI_TRUE != c.BrotliEncoderSetParameter(enc.state, c.BROTLI_PARAM_LARGE_WINDOW, @intCast(c.BROTLI_TRUE))) {
                log.err("Could not set encoding large window.", .{});
                return EncodeError.CannotSetParameter;
            };
    }

    return enc;
}

pub fn deinit(self: Encoder) void {
    defer c.BrotliEncoderDestroyInstance(self.state);
}

/// Encoder encode string
pub fn encode(self: *Encoder, input: []const u8) ![]const u8 {
    const max_size: usize = c.BrotliEncoderMaxCompressedSize(input.len);
    var buf = try self.allocator.alloc(u8, max_size);
    defer self.allocator.free(buf);

    const result = switch (self.settings.process) {
        .one_shot => self.encodeOneShot(input, &buf) catch c.BROTLI_FALSE,
        .stream => r: {
            if (input.len > 0)
                break :r self.encodeStream(input, &buf) catch c.BROTLI_FALSE
            else
                return self.allocator.dupe(u8, input);
        },
    };

    if (result == c.BROTLI_TRUE)
        return self.allocator.dupe(u8, buf[0..self.stream_output_size])
    else {
        log.err("Could not encode:\n{s}", .{input});
        return EncodeError.GeneralError;
    }
}

fn encodeOneShot(self: *Encoder, input: []const u8, output: *[]u8) !c_int {
    var enc_size = output.len;

    // fn BrotliEncoderCompress(
    //     quality: c_int,
    //     lgwin: c_int,
    //     mode: BrotliEncoderMode,
    //     input_size: usize,
    //     input_buffer: [*c]const u8,
    //     encoded_size: [*c]usize,
    //     encoded_buffer: [*c]u8,
    // ) c_int;
    const result = c.BrotliEncoderCompress(
        self.settings.quality,
        self.settings.window,
        @intFromEnum(self.settings.mode),
        input.len,
        input.ptr,
        @ptrCast(&enc_size),
        output.ptr,
    );

    self.stream_output_size = enc_size;
    self.total_output_size = enc_size;
    return result;
}

/// Encoder encode Stream
fn encodeStream(self: *Encoder, input: []const u8, output: *const []u8) !c_int {
    var enc_left = output.len;
    var result = c.BROTLI_TRUE;

    if (enc_left == 0) {
        log.err("Output buffer needs at least one byte.", .{});
        return c.BROTLI_FALSE;
    }

    var available_in: usize = input.len;
    var next_in: [*c]const u8 = input.ptr;
    var next_out: [*c]const u8 = output.ptr;
    var total_out: usize = 0;

    // fn BrotliEncoderCompressStream(
    //     state: ?*BrotliEncoderState,
    //     op: BrotliEncoderOperation,
    //     available_in: [*c]usize,
    //     next_in: [*c][*c]const u8,
    //     available_out: [*c]usize,
    //     next_out: [*c][*c]u8,
    //     total_out: [*c]usize,
    // ) c_int;
    result = c.BrotliEncoderCompressStream(
        self.state,
        c.BROTLI_OPERATION_FLUSH,
        @ptrCast(&available_in),
        @ptrCast(&next_in),
        @ptrCast(&enc_left),
        @ptrCast(&next_out),
        @ptrCast(&total_out),
    );

    self.stream_output_size = output.len - enc_left;
    self.total_output_size = total_out;

    return result;
}

const std = @import("std");
pub const c = @cImport({
    @cInclude("brotli/encode.h");
    @cInclude("brotli/decode.h");
});
