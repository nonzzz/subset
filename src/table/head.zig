const std = @import("std");
const reader = @import("../byte_read.zig");

pub const Table = struct {
    const Self = @This();
    major_version: u16,
    minor_version: u16,
    font_revision: u32,
    checksum_adjustment: u32,
    magic_number: u32,
    flags: u16,
    units_per_em: u16,
    created: i64,
    modified: i64,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    mac_style: u16,
    lowest_rec_ppem: u16,
    font_direction_hint: i16,
    index_to_loc_format: i16,
    glyph_data_format: i16,

    pub fn parse(byte_reader: *reader.ByteReader) !Self {
        const major_version = try byte_reader.read_u16_be();
        const minor_version = try byte_reader.read_u16_be();
        const font_revision = try byte_reader.read_u32_be();
        const checksum_adjustment = try byte_reader.read_u32_be();
        const magic_number = try byte_reader.read_u32_be();
        const flags = try byte_reader.read_u16_be();
        const units_per_em = try byte_reader.read_u16_be();
        const created = try byte_reader.read_i64_be();
        const modified = try byte_reader.read_i64_be();
        const x_min = try byte_reader.read_i16_be();
        const y_min = try byte_reader.read_i16_be();
        const x_max = try byte_reader.read_i16_be();
        const y_max = try byte_reader.read_i16_be();
        const mac_style = try byte_reader.read_u16_be();
        const lowest_rec_ppem = try byte_reader.read_u16_be();
        const font_direction_hint = try byte_reader.read_i16_be();
        const index_to_loc_format = try byte_reader.read_i16_be();
        const glyph_data_format = try byte_reader.read_i16_be();

        return Table{
            .major_version = major_version,
            .minor_version = minor_version,
            .font_revision = font_revision,
            .checksum_adjustment = checksum_adjustment,
            .magic_number = magic_number,
            .flags = flags,
            .units_per_em = units_per_em,
            .created = created,
            .modified = modified,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
            .mac_style = mac_style,
            .lowest_rec_ppem = lowest_rec_ppem,
            .font_direction_hint = font_direction_hint,
            .index_to_loc_format = index_to_loc_format,
            .glyph_data_format = glyph_data_format,
        };
    }
};
