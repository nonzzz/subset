const std = @import("std");
const lib = @import("ttf");

var gpa = std.heap.wasm_allocator;

const SubsetHandle = opaque {};
const FontReaderHandle = opaque {};

pub const ErrorCode = enum(u32) {
    success = 0,
    invalid_pointer = 1,
    allocation_failed = 2,
    parse_failed = 3,
    invalid_utf8 = 4,
    missing_table = 5,
    out_of_bounds = 6,
};

export fn allocate_memory(size: u32) ?[*]u8 {
    const slice = gpa.alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn free_memory(ptr: [*]u8, size: u32) void {
    const slice = ptr[0..size];
    gpa.free(slice);
}

export fn load_font_from_buffer(ptr: [*]const u8, len: u32) ?*FontReaderHandle {
    const data_slice = ptr[0..len];

    const reader = gpa.create(lib.FontReader) catch return null;
    reader.* = lib.FontReader.init(gpa, data_slice) catch {
        gpa.destroy(reader);
        return null;
    };

    return @ptrCast(reader);
}

extern "env" fn host_read_file(path_ptr: [*]const u8, path_len: u32, out_ptr: *[*]u8, out_len: *u32) bool;

export fn load_font_from_file(path_ptr: [*]const u8, path_len: u32) ?*FontReaderHandle {
    var data_ptr: [*]u8 = undefined;
    var data_len: u32 = undefined;

    if (!host_read_file(path_ptr, path_len, &data_ptr, &data_len)) {
        return null;
    }

    const data_slice = data_ptr[0..data_len];
    const reader = gpa.create(lib.FontReader) catch {
        free_memory(data_ptr, data_len);
        return null;
    };

    reader.* = lib.FontReader.init(gpa, data_slice) catch {
        gpa.destroy(reader);
        free_memory(data_ptr, data_len);
        return null;
    };

    return @ptrCast(reader);
}

export fn destroy_font_reader(handle: ?*FontReaderHandle) void {
    if (handle) |h| {
        const reader: *lib.FontReader = @ptrCast(@alignCast(h));
        reader.deinit();
        gpa.destroy(reader);
    }
}

export fn create_subset_from_reader(reader_handle: ?*FontReaderHandle) ?*SubsetHandle {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return null));

    const subset = gpa.create(lib.Subset) catch return null;
    subset.* = lib.Subset.init(gpa, reader.subset.parser.buffer) catch {
        gpa.destroy(subset);
        return null;
    };

    return @ptrCast(subset);
}

export fn destroy_subset(handle: ?*SubsetHandle) void {
    if (handle) |h| {
        const subset: *lib.Subset = @ptrCast(@alignCast(h));
        subset.deinit();
        gpa.destroy(subset);
    }
}

export fn get_font_metrics(reader_handle: ?*FontReaderHandle, metrics_ptr: [*]i32) ErrorCode {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return .invalid_pointer));

    const metrics = reader.get_font_metrics() catch return .missing_table;

    metrics_ptr[0] = metrics.ascender;
    metrics_ptr[1] = metrics.descender;
    metrics_ptr[2] = metrics.line_gap;
    metrics_ptr[3] = @intCast(metrics.advance_width_max);
    metrics_ptr[4] = @intCast(metrics.units_per_em);
    metrics_ptr[5] = metrics.x_min;
    metrics_ptr[6] = metrics.y_min;
    metrics_ptr[7] = metrics.x_max;
    metrics_ptr[8] = metrics.y_max;

    return .success;
}

export fn get_num_glyphs(reader_handle: ?*FontReaderHandle) u32 {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return 0));
    return reader.get_num_glyphs();
}

export fn is_monospace(reader_handle: ?*FontReaderHandle) bool {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return false));
    return reader.is_monospace();
}

export fn get_glyph_id_for_codepoint(reader_handle: ?*FontReaderHandle, codepoint: u32) u32 {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return 0));
    return reader.get_glyph_id_for_codepoint(codepoint) catch 0;
}

export fn get_glyph_info(reader_handle: ?*FontReaderHandle, glyph_id: u16, info_ptr: [*]u32) ErrorCode {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return .invalid_pointer));

    const info = reader.get_glyph_info(glyph_id) catch return .parse_failed;
    if (info == null) return .out_of_bounds;

    const glyph_info = info.?;
    info_ptr[0] = glyph_info.glyph_id;
    info_ptr[1] = glyph_info.codepoint;
    info_ptr[2] = glyph_info.advance_width;
    info_ptr[3] = @bitCast(@as(i32, glyph_info.left_side_bearing));
    info_ptr[4] = if (glyph_info.has_outline) 1 else 0;

    return .success;
}

export fn get_font_name_length(reader_handle: ?*FontReaderHandle, name_id: u16) u32 {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return 0));
    const name = reader.get_font_name(name_id) orelse return 0;
    return @intCast(name.len);
}

export fn get_font_name(reader_handle: ?*FontReaderHandle, name_id: u16, buffer_ptr: [*]u8, buffer_len: u32) ErrorCode {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return .invalid_pointer));
    const name = reader.get_font_name(name_id) orelse return .out_of_bounds;

    if (buffer_len < name.len) return .out_of_bounds;

    @memcpy(buffer_ptr[0..name.len], name);
    return .success;
}

export fn get_glyph_name_length(reader_handle: ?*FontReaderHandle, glyph_id: u16) u32 {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return 0));
    const name = reader.get_glyph_name(glyph_id) orelse return 0;
    return @intCast(name.len);
}

export fn get_glyph_name(reader_handle: ?*FontReaderHandle, glyph_id: u16, buffer_ptr: [*]u8, buffer_len: u32) ErrorCode {
    const reader: *lib.FontReader = @ptrCast(@alignCast(reader_handle orelse return .invalid_pointer));
    const name = reader.get_glyph_name(glyph_id) orelse return .out_of_bounds;

    if (buffer_len < name.len) return .out_of_bounds;

    @memcpy(buffer_ptr[0..name.len], name);
    return .success;
}

export fn add_text_to_subset(subset_handle: ?*SubsetHandle, text_ptr: [*]const u8, text_len: u32) ErrorCode {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return .invalid_pointer));
    const text = text_ptr[0..text_len];

    subset.add_text(text) catch return .invalid_utf8;
    return .success;
}

export fn add_character_to_subset(subset_handle: ?*SubsetHandle, codepoint: u32) ErrorCode {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return .invalid_pointer));

    subset.add_character(codepoint) catch return .parse_failed;
    return .success;
}

export fn get_selected_glyphs_count(subset_handle: ?*SubsetHandle) u32 {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return 0));
    return @intCast(subset.selected_glyphs.count());
}

export fn get_selected_glyphs(subset_handle: ?*SubsetHandle, buffer_ptr: [*]u16, buffer_len: u32) ErrorCode {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return .invalid_pointer));

    const glyphs = subset.get_selected_glyphs() catch return .allocation_failed;
    defer subset.allocator.free(glyphs);

    if (buffer_len < glyphs.len) return .out_of_bounds;

    @memcpy(buffer_ptr[0..glyphs.len], glyphs);
    return .success;
}

export fn has_glyph_in_subset(subset_handle: ?*SubsetHandle, glyph_id: u16) bool {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return false));
    return subset.has_glyph(glyph_id);
}

export fn clear_subset_selection(subset_handle: ?*SubsetHandle) void {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return));
    subset.clear_selection();
}

export fn generate_subset_font(subset_handle: ?*SubsetHandle, output_ptr: *[*]u8, output_len: *u32) ErrorCode {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return .invalid_pointer));

    const font_data = subset.generate_subset() catch return .allocation_failed;

    output_ptr.* = font_data.ptr;
    output_len.* = @intCast(font_data.len);

    return .success;
}

export fn create_subset_from_text(font_ptr: [*]const u8, font_len: u32, text_ptr: [*]const u8, text_len: u32, output_ptr: *[*]u8, output_len: *u32) ErrorCode {
    const font_data = font_ptr[0..font_len];
    const text = text_ptr[0..text_len];

    const subset_data = lib.create_subset_from_buffer(gpa, font_data, text) catch return .allocation_failed;

    output_ptr.* = subset_data.ptr;
    output_len.* = @intCast(subset_data.len);

    return .success;
}

extern "env" fn host_write_file(path_ptr: [*]const u8, path_len: u32, data_ptr: [*]const u8, data_len: u32) bool;

export fn save_subset_to_file(subset_handle: ?*SubsetHandle, path_ptr: [*]const u8, path_len: u32) ErrorCode {
    const subset: *lib.Subset = @ptrCast(@alignCast(subset_handle orelse return .invalid_pointer));

    const font_data = subset.generate_subset() catch return .allocation_failed;
    defer subset.allocator.free(font_data);

    if (host_write_file(path_ptr, path_len, font_data.ptr, @intCast(font_data.len))) {
        return .success;
    } else {
        return .parse_failed;
    }
}

export fn get_error_message_length(error_code: ErrorCode) u32 {
    const message = switch (error_code) {
        .success => "Success",
        .invalid_pointer => "Invalid pointer",
        .allocation_failed => "Memory allocation failed",
        .parse_failed => "Font parsing failed",
        .invalid_utf8 => "Invalid UTF-8 text",
        .missing_table => "Required font table missing",
        .out_of_bounds => "Index out of bounds",
    };
    return @intCast(message.len);
}

export fn get_error_message(error_code: ErrorCode, buffer_ptr: [*]u8, buffer_len: u32) ErrorCode {
    const message = switch (error_code) {
        .success => "Success",
        .invalid_pointer => "Invalid pointer",
        .allocation_failed => "Memory allocation failed",
        .parse_failed => "Font parsing failed",
        .invalid_utf8 => "Invalid UTF-8 text",
        .missing_table => "Required font table missing",
        .out_of_bounds => "Index out of bounds",
    };

    if (buffer_len < message.len) return .out_of_bounds;

    @memcpy(buffer_ptr[0..message.len], message);
    return .success;
}
