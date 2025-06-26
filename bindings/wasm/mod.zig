const std = @import("std");
const ttf = @import("ttf");

var gpa = std.heap.wasm_allocator;

export fn parse_ttf_font(ptr: [*]const u8, len: u32) ?*ttf.Parser {
    const data_slice = ptr[0..len];

    const parser = gpa.create(ttf.Parser) catch return null;
    parser.* = ttf.Parser.init(gpa, data_slice) catch {
        gpa.destroy(parser);
        return null;
    };

    parser.parse() catch {
        parser.deinit();
        gpa.destroy(parser);
        return null;
    };

    return parser;
}

export fn destroy_parser(parser_ptr: ?*ttf.Parser) void {
    if (parser_ptr) |parser| {
        parser.deinit();
        gpa.destroy(parser);
    }
}

export fn get_num_tables(parser_ptr: ?*ttf.Parser) u32 {
    if (parser_ptr) |parser| {
        return @intCast(parser.table_records.items.len);
    }
    return 0;
}

export fn get_table_tag(parser_ptr: ?*ttf.Parser, index: u32) u32 {
    if (parser_ptr) |parser| {
        if (index < parser.table_records.items.len) {
            return @intFromEnum(parser.table_records.items[index].tag);
        }
    }
    return 0;
}

export fn has_head_table(parser_ptr: ?*ttf.Parser) bool {
    if (parser_ptr) |parser| {
        return parser.parsed_tables.head != null;
    }
    return false;
}

export fn get_head_info(parser_ptr: ?*ttf.Parser, info_ptr: [*]u32) bool {
    if (parser_ptr) |parser| {
        if (parser.parsed_tables.get_head()) |head| {
            info_ptr[0] = head.major_version;
            info_ptr[1] = head.minor_version;
            info_ptr[2] = head.units_per_em;
            info_ptr[3] = head.flags;
            info_ptr[4] = @bitCast(head.magic_number);
            return true;
        }
    }
    return false;
}

export fn has_maxp_table(parser_ptr: ?*ttf.Parser) bool {
    if (parser_ptr) |parser| {
        return parser.parsed_tables.maxp != null;
    }
    return false;
}

export fn get_maxp_info(parser_ptr: ?*ttf.Parser, info_ptr: [*]u32) bool {
    if (parser_ptr) |parser| {
        if (parser.parsed_tables.get_maxp()) |maxp| {
            info_ptr[0] = maxp.version;
            info_ptr[1] = maxp.num_glyphs;
            info_ptr[2] = if (maxp.is_ttf()) 1 else 0;
            info_ptr[3] = if (maxp.is_cff()) 1 else 0;
            return true;
        }
    }
    return false;
}

export fn has_hhea_table(parser_ptr: ?*ttf.Parser) bool {
    if (parser_ptr) |parser| {
        return parser.parsed_tables.hhea != null;
    }
    return false;
}

export fn get_hhea_info(parser_ptr: ?*ttf.Parser, info_ptr: [*]i32) bool {
    if (parser_ptr) |parser| {
        if (parser.parsed_tables.get_hhea()) |hhea| {
            info_ptr[0] = hhea.ascender;
            info_ptr[1] = hhea.descender;
            info_ptr[2] = hhea.line_gap;
            info_ptr[3] = hhea.advance_width_max;
            info_ptr[4] = hhea.number_of_hmetrics;
            return true;
        }
    }
    return false;
}

export fn get_mac_style_info(parser_ptr: ?*ttf.Parser, style_ptr: [*]u32) bool {
    if (parser_ptr) |parser| {
        if (parser.parsed_tables.get_head()) |head| {
            style_ptr[0] = if (head.mac_style.is_bold()) 1 else 0;
            style_ptr[1] = if (head.mac_style.is_italic()) 1 else 0;
            style_ptr[2] = if (head.mac_style.has_any_style()) 1 else 0;
            style_ptr[3] = head.mac_style.to_u16();
            return true;
        }
    }
    return false;
}

export fn allocate_memory(size: u32) ?[*]u8 {
    const slice = gpa.alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn free_memory(ptr: [*]u8, size: u32) void {
    const slice = ptr[0..size];
    gpa.free(slice);
}
