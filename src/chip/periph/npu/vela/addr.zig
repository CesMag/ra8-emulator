//! Where element (y, x, c) of a feature map sits, as an offset inside the
//! map's region, and how the PRECISION registers say an element is stored.
//!
//! Follows Arm's Vela 3.12.0 (Apache-2.0) register_command_stream_util.py
//! `get_address` and register_command_stream_generator.py
//! `generate_ifm_precision` / `generate_ofm_precision`. A map is split into
//! up to four tiles: x past WIDTH0 moves to tile 1 (then tile 3 past
//! HEIGHT1), y past HEIGHT0 moves to tile 2. Channels are grouped in bricks
//! of 16.
const std = @import("std");
const fm = @import("fm.zig");
const quant = @import("quant.zig");

pub const Layout = enum { nhwc, nhcwb16 };

/// How one element is stored.
pub const Format = struct {
    signed: bool,
    /// Bytes per element: 1, 2 or 4.
    size: u32,
    layout: Layout,
};

pub const brick: u32 = 16;

fn sizeOf(precision: u2) ?u32 {
    return switch (precision) {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => null,
    };
}

/// PRECISION bits [7:6]: 0 NHWC, 1 NHCWB16; 2 and 3 are reserved.
fn layoutOf(param: u16) ?Layout {
    return switch (@as(u2, @truncate(param >> 6))) {
        0 => .nhwc,
        1 => .nhcwb16,
        else => null,
    };
}

/// Decode IFM_PRECISION or IFM2_PRECISION: signed bit 0, size bits [3:2],
/// format bits [7:6] (Ethos-U55 TRM 102420_0200_02, cmd0 0x105 and 0x185).
pub fn ifmFormat(param: u16) ?Format {
    const size = sizeOf(@truncate(param >> 2)) orelse return null;
    return .{ .signed = param & 1 != 0, .size = size, .layout = layoutOf(param) orelse return null };
}

/// Decode OFM_PRECISION: signed bit 0, size bits [2:1], format bits [7:6].
pub fn ofmFormat(param: u16) ?Format {
    const size = sizeOf(@truncate(param >> 1)) orelse return null;
    return .{ .signed = param & 1 != 0, .size = size, .layout = layoutOf(param) orelse return null };
}

/// OFM_PRECISION bits [15:14]: 0 TFL, 1 truncate, 2 natural.
pub fn rounding(param: u16) u2 {
    return @truncate(param >> 14);
}

/// The offset of element (y, x, c) inside the map's region.
pub fn address(tiles: [4]u64, map: fm.Map, stride: quant.Stride, format: Format, y: u32, x: u32, c: u32) u64 {
    var row = y;
    var col = x;
    var tile: usize = 0;
    if (col > map.width0_m1) {
        col -= @as(u32, map.width0_m1) + 1;
        tile = 1;
        if (row > map.height1_m1) {
            row -= @as(u32, map.height1_m1) + 1;
            tile += 2;
        }
    } else if (row > map.height0_m1) {
        row -= @as(u32, map.height0_m1) + 1;
        tile += 2;
    }
    const stride_c: u64 = if (format.layout == .nhwc) brick * format.size else stride.c;
    const stride_x: u64 = if (format.layout == .nhcwb16) brick * format.size else stride.x;
    return tiles[tile] + @as(u64, row) * stride.y + @as(u64, col) * stride_x +
        @as(u64, c / brick) * stride_c + @as(u64, c % brick) * format.size;
}
