//! Tests for src/chip/periph/npu/vela_addr.zig: element addresses and the
//! PRECISION register formats, checked against Vela's get_address.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu_vela;
const addr = vela.addr;

const int8_nhwc = addr.Format{ .signed = true, .size = 1, .layout = .nhwc };

test "IFM precision decodes sign, size and layout" {
    // Vela: int8 NHWC is 1; int16 NHCWB16 is 1 | 1<<2 | 1<<6.
    try std.testing.expectEqual(int8_nhwc, addr.ifmFormat(1).?);
    try std.testing.expectEqual(addr.Format{ .signed = true, .size = 2, .layout = .nhcwb16 }, addr.ifmFormat(0x45).?);
    try std.testing.expectEqual(@as(?addr.Format, null), addr.ifmFormat(3 << 2));
}

test "OFM precision keeps size in bits [2:1] and rounding in [15:14]" {
    // uint8, global scale bit 8, natural rounding.
    const param: u16 = 0 | (1 << 8) | (2 << 14);
    try std.testing.expectEqual(addr.Format{ .signed = false, .size = 1, .layout = .nhwc }, addr.ofmFormat(param).?);
    try std.testing.expectEqual(@as(u2, 2), addr.rounding(param));
    try std.testing.expectEqual(@as(u32, 4), addr.ofmFormat(2 << 1).?.size);
}

test "an NHWC int8 map in one tile walks depth, then width, then height" {
    // Shape 4x8x16: Vela's strides are c 1, x 16, y 128.
    const map = vela.fm.Map{ .width0_m1 = 7, .height0_m1 = 3, .height1_m1 = 3, .depth_m1 = 15 };
    const stride = vela.quant.Stride{ .x = 16, .y = 128, .c = 1 };
    const tiles = [4]u64{ 0x100, 0, 0, 0 };
    try std.testing.expectEqual(@as(u64, 0x100), addr.address(tiles, map, stride, int8_nhwc, 0, 0, 0));
    try std.testing.expectEqual(@as(u64, 0x100 + 5), addr.address(tiles, map, stride, int8_nhwc, 0, 0, 5));
    try std.testing.expectEqual(@as(u64, 0x100 + 2 * 128 + 3 * 16 + 7), addr.address(tiles, map, stride, int8_nhwc, 2, 3, 7));
}

test "NHCWB16 steps x by one brick and channel blocks by STRIDE_C" {
    // Shape 2x4x32 int8: Vela gives stride_x 16, stride_c 64, stride_y 128.
    const format = addr.Format{ .signed = true, .size = 1, .layout = .nhcwb16 };
    const map = vela.fm.Map{ .width0_m1 = 3, .height0_m1 = 1, .height1_m1 = 1, .depth_m1 = 31 };
    const stride = vela.quant.Stride{ .x = 16, .y = 128, .c = 64 };
    const tiles = [4]u64{ 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u64, 1 * 128 + 2 * 16 + 1 * 64 + 3), addr.address(tiles, map, stride, format, 1, 2, 19));
}

test "coordinates past WIDTH0 and HEIGHT0 move to the other tiles" {
    const map = vela.fm.Map{ .width0_m1 = 1, .height0_m1 = 1, .height1_m1 = 0, .depth_m1 = 0 };
    const stride = vela.quant.Stride{ .x = 1, .y = 10, .c = 1 };
    const tiles = [4]u64{ 0x000, 0x100, 0x200, 0x300 };
    try std.testing.expectEqual(@as(u64, 0x200 + 10 + 1), addr.address(tiles, map, stride, int8_nhwc, 3, 1, 0));
    try std.testing.expectEqual(@as(u64, 0x100 + 1), addr.address(tiles, map, stride, int8_nhwc, 0, 3, 0));
    try std.testing.expectEqual(@as(u64, 0x300 + 1), addr.address(tiles, map, stride, int8_nhwc, 1, 3, 0));
}

test "the reserved format values 2 and 3 in bits [7:6] are refused" {
    try std.testing.expectEqual(@as(?addr.Format, null), addr.ifmFormat(1 | (2 << 6)));
    try std.testing.expectEqual(@as(?addr.Format, null), addr.ofmFormat(1 | (3 << 6)));
    try std.testing.expectEqual(addr.Layout.nhcwb16, addr.ofmFormat(1 | (1 << 6)).?.layout);
}
