//! Tests for src/chip/periph/npu/npu_vela_conv.zig. The end-to-end case is a
//! per-channel int8 1x1 CONV_2D (8 in, 6 out, 4x4, IFM zero point -5, OFM
//! zero point 7) compiled by Vela 3.12.0 for the Ethos-U55-256. Its scale
//! records and weight stream are the bytes Vela put in the model's flash
//! tensor; the expected OFM is TFLite Micro's double-rounding arithmetic
//! on the original float model, and tflite-runtime agrees on every byte of
//! it.
const std = @import("std");
const ra8 = @import("ra8");
const npu_vela = ra8.chip.periph.npu_vela;
const conv = npu_vela.conv;

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

const scales = bytes("d605000000e823385327d10a000000df8793742870f6ffffff255fee73264405000000335b42432626fbffffffb6555d" ++
    "6128f7000000000175c74e2600000000");
const weight_stream = bytes("680150f11d2c98615f4f1fff6e4e1e5eed5cccbbab7bcb8a4a2a9a491908d8b75717571656d80030d8f7f8a6c00b4afc" ++
    "a60780113f1eed57008003710d42a47e6b53c98183d437004070830d9652fb7a00000200fffff33f80ffffffffffffff");
const ifm_bytes = bytes("cd47e21bf735d896cb211e7bbeec729c33756a2d64b2412c017e58b57b5adf3248b8c2aff674e3d76cf08f2743f07280" ++
    "5dc24cf82642651b23ee8db09d489cafb939cfff2e0dfbe271b34babfa24cac6ab83c3b1266b8636e71476e69e5163c3" ++
    "1522a18385251e781935f793d61730d1a06bba84e8832898cfd638612d10ba29");
const ofm_bytes = bytes("e116e403f4134a0a800cf28b3aece3db0cc1d4146ca0f63abf197f1217ede6db7f043680170c50e71780c31c3849063a" ++
    "ec0530d8fa49db230732248ebe2f4bf7017f272fcee2e78b1e047f00eb7fef0a70e302f4eef54fcd00561f1e8020fd14");

const params = conv.Params{
    .ifm = .{ .height = 4, .width = 4, .depth = 8 },
    .ofm = .{ .height = 4, .width = 4, .depth = 6 },
    .kernel_height = 1,
    .kernel_width = 1,
    .ifm_zero_point = -5,
    .ofm_zero_point = 7,
};

test "a Vela-compiled 1x1 convolution gives TFLite Micro's output" {
    const gpa = std.testing.allocator;
    const stream = try npu_vela.weights.decode(gpa, &weight_stream);
    defer gpa.free(stream);
    // Vela's command stream sets KERNEL_STRIDE b2 (part-kernel-first) and
    // an OFM block depth of 8 for this op.
    const layout = npu_vela.order.Layout{ .ofm_depth = 6, .kernel_height = 1, .kernel_width = 1, .ifm_depth = 8, .ofm_block_depth = 8, .traversal = .part_kernel_first };
    var ohwi: [48]i16 = undefined;
    try npu_vela.order.unpack(layout, stream, &ohwi);
    var ofm: [96]i8 = undefined;
    try conv.run(params, @ptrCast(&ifm_bytes), &ohwi, &scales, &ofm);
    try std.testing.expectEqualSlices(u8, &ofm_bytes, @ptrCast(&ofm));
}

/// One channel, scale 1.0 (2^30 with shift 30), no bias: the OFM is the
/// raw accumulator plus the zero point, so padding and stride show plainly.
fn unitRecord() [10]u8 {
    var r = @as([10]u8, @splat(0));
    std.mem.writeInt(u32, r[5..9], 1 << 30, .little);
    r[9] = 30;
    return r;
}

test "padded taps read the zero point and add nothing" {
    const record = unitRecord();
    const p = conv.Params{
        .ifm = .{ .height = 2, .width = 2, .depth = 1 },
        .ofm = .{ .height = 2, .width = 2, .depth = 1 },
        .kernel_height = 2,
        .kernel_width = 2,
        .pad_top = 1,
        .pad_left = 1,
        .ifm_zero_point = 1,
        .ofm_zero_point = 0,
    };
    const ifm = [_]i8{ 2, 3, 4, 5 };
    const weights = [_]i16{ 1, 1, 1, 1 };
    var ofm: [4]i8 = undefined;
    try conv.run(p, &ifm, &weights, &record, &ofm);
    // Each output sums the (ifm - 1) values its 2x2 window covers.
    try std.testing.expectEqualSlices(i8, &.{ 1, 3, 4, 10 }, &ofm);
}

test "stride skips IFM pixels and the activation range clamps" {
    const record = unitRecord();
    var p = conv.Params{
        .ifm = .{ .height = 1, .width = 4, .depth = 1 },
        .ofm = .{ .height = 1, .width = 2, .depth = 1 },
        .kernel_height = 1,
        .kernel_width = 1,
        .stride_x = 2,
        .ifm_zero_point = 0,
        .ofm_zero_point = 0,
    };
    const ifm = [_]i8{ 10, 99, -20, 99 };
    var ofm: [2]i8 = undefined;
    try conv.run(p, &ifm, &.{3}, &record, &ofm);
    try std.testing.expectEqualSlices(i8, &.{ 30, -60 }, &ofm);
    p.activation_min = -10;
    p.activation_max = 20;
    try conv.run(p, &ifm, &.{3}, &record, &ofm);
    try std.testing.expectEqualSlices(i8, &.{ 20, -10 }, &ofm);
}

test "mismatched buffers and missing records are refused" {
    var ofm: [96]i8 = undefined;
    const ohwi = @as([48]i16, @splat(0));
    try std.testing.expectError(error.BadShape, conv.run(params, @ptrCast(ifm_bytes[0..127]), &ohwi, &scales, &ofm));
    try std.testing.expectError(error.MissingRecord, conv.run(params, @ptrCast(&ifm_bytes), &ohwi, scales[0..50], &ofm));
}

test "a depthwise conv sums each channel only into its own OFM channel" {
    var records: [20]u8 = undefined;
    const unit = unitRecord();
    @memcpy(records[0..10], &unit);
    @memcpy(records[10..20], &unit);
    const p = conv.Params{
        .ifm = .{ .height = 1, .width = 2, .depth = 2 },
        .ofm = .{ .height = 1, .width = 1, .depth = 2 },
        .kernel_height = 1,
        .kernel_width = 2,
        .ifm_zero_point = 0,
        .ofm_zero_point = 0,
        .depthwise = true,
    };
    // Pixels (1, 2) and (2, 3); channel 0 weights (3, 4), channel 1 (5, 6).
    const ifm = [_]i8{ 1, 2, 2, 3 };
    const weights = [_]i16{ 3, 4, 5, 6 };
    var ofm: [2]i8 = undefined;
    try conv.run(p, &ifm, &weights, &records, &ofm);
    try std.testing.expectEqualSlices(i8, &.{ 1 * 3 + 2 * 4, 2 * 5 + 3 * 6 }, &ofm);
}

test "a depthwise conv needs as many OFM channels as IFM channels" {
    const record = unitRecord();
    const p = conv.Params{
        .ifm = .{ .height = 1, .width = 1, .depth = 2 },
        .ofm = .{ .height = 1, .width = 1, .depth = 1 },
        .kernel_height = 1,
        .kernel_width = 1,
        .ifm_zero_point = 0,
        .ofm_zero_point = 0,
        .depthwise = true,
    };
    var ofm: [1]i8 = undefined;
    try std.testing.expectError(error.BadShape, conv.run(p, &.{ 1, 2 }, &.{1}, &record, &ofm));
}
