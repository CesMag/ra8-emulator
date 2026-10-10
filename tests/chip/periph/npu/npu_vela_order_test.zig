//! Tests for src/chip/periph/npu/npu_vela_order.zig. Every stream here came from
//! Vela 3.12.0's mlw_codec `reorder_encode` (Ethos-U55-256 micro-blocks, 8x8
//! sub-kernels, 8-bit IFM) fed the volume `pattern` builds, so decoding and
//! unpacking one must give that volume back.
const std = @import("std");
const ra8 = @import("ra8");
const npu_vela = ra8.chip.periph.npu_vela;
const order = npu_vela.order;

/// The test volume: each weight a function of its OHWI position.
fn pattern(o: usize, y: usize, x: usize, i: usize) i16 {
    return @as(i16, @intCast((o * 7 + y * 5 + x * 3 + i) % 19)) - 9;
}

fn expectRoundTrip(layout: order.Layout, comptime hex: []const u8, padded: usize) !void {
    const gpa = std.testing.allocator;
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    const stream = try npu_vela.weights.decode(gpa, &bytes);
    defer gpa.free(stream);
    try std.testing.expectEqual(padded, stream.len);
    try std.testing.expectEqual(padded, try order.paddedLength(layout));
    const got = try gpa.alloc(i16, layout.volume());
    defer gpa.free(got);
    try order.unpack(layout, stream, got);
    var n: usize = 0;
    for (0..layout.ofm_depth) |o| for (0..layout.kernel_height) |y| for (0..layout.kernel_width) |x| for (0..layout.ifm_depth) |i| {
        try std.testing.expectEqual(pattern(o, y, x, i), got[n]);
        n += 1;
    };
}

test "depth first, one block padded out to the micro-blocks" {
    const layout = order.Layout{ .ofm_depth = 2, .kernel_height = 1, .kernel_width = 1, .ifm_depth = 3, .ofm_block_depth = 8 };
    try expectRoundTrip(layout, "1800e44136e32b8301f0011d002005c0ff7fff3ffeffffffffffffffffffffff", 256);
}

test "depth first across two OFM blocks and a 3x3 kernel" {
    const layout = order.Layout{ .ofm_depth = 10, .kernel_height = 3, .kernel_width = 3, .ifm_depth = 4, .ofm_block_depth = 8 };
    try expectRoundTrip(layout, "e8006c11071b43668819553a44baf296a5c29368d50f1f3a90d79101f84864d2e8a313787880879d5cfeffffffffffff" ++
        "ffffffffffffffffffffffffffffffffff1f603781e5a200c1910180896672e801800008a0bd5c7420000880a9090c00" ++
        "2000bad43ff33a32f62e0801fccb405253c60f0001800220d04500021810c023c3039b6826879e0008e01fdacb450708" ++
        "e0ff018000a41a0023000250510090d7918144440880fc268dbea60ca000a18bff02f08f269ac9a103000c0878240000" ++
        "02200070682f171d20000265ef1f020220f08f904b0fecf80fa04b008c000800749181a426081480ba001204c0807af4" ++
        "0fc868a2991c0002f8470fede5a23f00020020005a2a80088000685dc0e103791d19004084f84fb4c840528000fe7f00" ++
        "08d505400004c0a0170060ca68a299200002e01c7a68af010220d067ff022080ff3edac9a5ff0020f074008220000200" ++
        "c0de450602022090bdf891054000ffa9d9037bc1e0ffc03af80302e07f2293dacb01ffff807df62f500005fea3682797" ++
        "f7ff039cc03f08e0ffff4089f08100f8efc83039f400feff03fe8910c0ffff4f150103e21f268d9e8b0002f8ff7fc02f" ++
        "4053ff9700f83f10194db4ff007f0220f08fff3f40fe032080ffff0ffeffffff", 4608);
}

test "depthwise pads each kernel to a multiple of four taps" {
    const layout = order.Layout{ .ofm_depth = 3, .kernel_height = 3, .kernel_width = 3, .ifm_depth = 1, .ofm_block_depth = 8, .traversal = .depthwise };
    try expectRoundTrip(layout, "c800480137236c091d3284746c29536c191f2faefdf89ae06966858f720cfce36b523c00f8d803340080088003f7ffff", 96);
}

test "part kernel first walks the taps inside each micro-block" {
    const layout = order.Layout{ .ofm_depth = 3, .kernel_height = 3, .kernel_width = 3, .ifm_depth = 5, .ofm_block_depth = 8, .traversal = .part_kernel_first };
    try expectRoundTrip(layout, "f1036c1117551913bec65642c710211d648310d43df80f20fc68771050ffbf7844dd5d20084436f84308e1f9ff414198" ++
        "da17844348e147a256c1cf68e8ff2784875910c2cf6e040f2ef7ff19107ea848c1479421786ec8ff23087fd005207c6a" ++
        "41183e1114f2ff7f772908eb1fd2501050fc3fb50529fc08f13fbd8c2030f0bf76370511219c03ff0740103577090010" ++
        "c200002b00fefde3ff63ffffffffffff", 768);
}

test "a kernel taller than eight rows splits into sub-kernels" {
    const layout = order.Layout{ .ofm_depth = 4, .kernel_height = 9, .kernel_width = 1, .ifm_depth = 2, .ofm_block_depth = 16 };
    try expectRoundTrip(layout, "23026c11376584cfb595d031850ca604cf0310f0fc3f0144e334b4008661fc4374ba40cbff03bc61fc1bc6ff3f400cff" ++
        "0bc3308cffd74f17d1ff7f80370c3cff4718c67f7d3110ddfd03fe1b3e8cffff031ee7471886ff0331e88e0efeff013e" ++
        "20e23fc330fe033addf13fc06f18c6bff1ff036efcdf30feff03fcffffffffff", 2304);
}

test "a stream of the wrong length is refused" {
    const layout = order.Layout{ .ofm_depth = 1, .kernel_height = 1, .kernel_width = 1, .ifm_depth = 1, .ofm_block_depth = 8 };
    var out: [1]i16 = undefined;
    const padded = try order.paddedLength(layout);
    const zeros = @as([300]i16, @splat(0));
    try std.testing.expectError(error.ShortStream, order.unpack(layout, zeros[0 .. padded - 1], &out));
    try std.testing.expectError(error.LongStream, order.unpack(layout, zeros[0 .. padded + 1], &out));
    try order.unpack(layout, zeros[0..padded], &out);
}

test "a volume buffer of the wrong size or an empty shape is refused" {
    const layout = order.Layout{ .ofm_depth = 1, .kernel_height = 1, .kernel_width = 1, .ifm_depth = 2, .ofm_block_depth = 8 };
    var out: [1]i16 = undefined;
    try std.testing.expectError(error.BadShape, order.unpack(layout, &.{}, &out));
    var empty = layout;
    empty.ofm_depth = 0;
    try std.testing.expectError(error.BadShape, order.paddedLength(empty));
}
