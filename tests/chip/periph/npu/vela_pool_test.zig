//! Tests for src/chip/periph/npu/vela_pool.zig: MAX pooling.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu.vela;
const pool = vela.pool;

fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

const Memory = struct {
    bytes: [0x200]u8 = @splat(0),
    pub fn read(self: *@This(), at: u32, out: []u8) error{Refused}!void {
        if (at + out.len > self.bytes.len) return error.Refused;
        @memcpy(out, self.bytes[at..][0..out.len]);
    }
    pub fn write(self: *@This(), at: u32, data: []const u8) error{Refused}!void {
        if (at + data.len > self.bytes.len) return error.Refused;
        @memcpy(self.bytes[at..][0..data.len], data);
    }
};

test "the kernel registers land and the others are passed back" {
    var state = pool.State{};
    try std.testing.expectEqual(pool.Outcome.applied, pool.apply(&state, 0x120, 2));
    try std.testing.expectEqual(pool.Outcome.applied, pool.apply(&state, 0x121, 1));
    try std.testing.expectEqual(pool.Outcome.applied, pool.apply(&state, 0x122, 3));
    try std.testing.expectEqual(pool.Outcome.not_modelled, pool.apply(&state, 0x125, 0));
    try std.testing.expectEqual(pool.State{ .width_m1 = 2, .height_m1 = 1, .stride = 3 }, state);
}

test "KERNEL_STRIDE decodes the low and extension bits as Vela writes them" {
    try std.testing.expectEqual(pool.Step{ .x = 1, .y = 1 }, pool.step(0));
    try std.testing.expectEqual(pool.Step{ .x = 2, .y = 2 }, pool.step(3));
    try std.testing.expectEqual(pool.Step{ .x = 3, .y = 1 }, pool.step(1 << 6));
    try std.testing.expectEqual(pool.Step{ .x = 1, .y = 3 }, pool.step(1 << 9));
    // The TRM gives the extension field three bits; 1 to 3 is supported.
    try std.testing.expectEqual(pool.Step{ .x = 5, .y = 1 }, pool.step(2 << 6));
    try std.testing.expectEqual(pool.Step{ .x = 1, .y = 5 }, pool.step(2 << 9));
    // Block traversal (b2) changes the order of work, not the step.
    try std.testing.expectEqual(pool.Step{ .x = 2, .y = 1 }, pool.step(1 | 1 << 2));
}

/// A 1x3x1 int8 IFM pooled by a 1x2 kernel at stride 1 into a 1x2x1 OFM.
fn inputs() pool.Inputs {
    var maps = vela.fm.State{};
    maps.ifm = .{ .width0_m1 = 2, .depth_m1 = 0, .precision = 1 };
    maps.ofm = .{ .width0_m1 = 1, .depth_m1 = 0, .precision = 1 };
    maps.ofm_width_m1 = 1;
    const stride = vela.quant.Stride{ .x = 1, .y = 3, .c = 1 };
    const q = vela.quant.State{ .activation_min = 0xFF80, .activation_max = 0x007F, .ifm_stride = stride, .ofm_stride = stride };
    var bases: @FieldType(pool.Inputs, "bases") = .{};
    bases.ofm = .{ 0x100, 0, 0, 0 };
    return .{ .bases = bases, .maps = maps, .quant = q, .kernel = .{ .width_m1 = 1 } };
}

test "MAX pool slides the window and clamps to the activation range" {
    var memory = Memory{};
    for ([_]i8{ -7, 4, -2 }, 0..) |v, i| memory.bytes[i] = @bitCast(v);
    const regions: vela.dma.Regions = @splat(0);
    try std.testing.expectEqual(@as(u64, 2), try pool.run(&memory, &regions, pool.mode_max, inputs()));
    try std.testing.expectEqual(@as(i8, 4), @as(i8, @bitCast(memory.bytes[0x100])));
    try std.testing.expectEqual(@as(i8, 4), @as(i8, @bitCast(memory.bytes[0x101])));
    var clamped = inputs();
    clamped.quant.activation_max = 2;
    _ = try pool.run(&memory, &regions, pool.mode_max, clamped);
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(memory.bytes[0x100])));
}

test "padded positions take no part in the max" {
    var memory = Memory{};
    for ([_]i8{ -7, -4, -2 }, 0..) |v, i| memory.bytes[i] = @bitCast(v);
    const regions: vela.dma.Regions = @splat(0);
    var padded = inputs();
    padded.maps.ifm_pad.left = 1; // windows (pad, -7), (-7, -4), (-4, -2)
    padded.maps.ofm.width0_m1 = 2;
    padded.maps.ofm_width_m1 = 2;
    try std.testing.expectEqual(@as(u64, 3), try pool.run(&memory, &regions, pool.mode_max, padded));
    try std.testing.expectEqual(@as(i8, -7), @as(i8, @bitCast(memory.bytes[0x100])));
    try std.testing.expectEqual(@as(i8, -4), @as(i8, @bitCast(memory.bytes[0x101])));
    try std.testing.expectEqual(@as(i8, -2), @as(i8, @bitCast(memory.bytes[0x102])));
}

test "what the model cannot vouch for is refused, not guessed" {
    var memory = Memory{};
    const regions: vela.dma.Regions = @splat(0);
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, 1, inputs()));
    var padded = inputs();
    padded.maps.ifm_pad.left = pool.max_pad_before + 1;
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, padded));
    var blank = inputs();
    blank.maps.ifm_pad.left = 3; // the first window lies wholly in the padding
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, blank));
    var dilated = inputs();
    dilated.kernel.stride = 1 << 3;
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, dilated));
    var wide = inputs();
    wide.kernel.stride = 2 << 6; // x stride 5, past the TRM's 3
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, wide));
    var mixed = inputs();
    mixed.maps.ofm.zero_point = 5;
    try std.testing.expectError(error.OperatorNotModelled, pool.run(&memory, &regions, pool.mode_max, mixed));
    try std.testing.expectEqual(@as(u8, 0), memory.bytes[0x100]);
}

/// Real Vela 3.12.0 streams (ethos-u55-256) for TFLite MAX_POOL_2D, int8,
/// 3x3 kernel, stride 2, SAME padding, scale 0.05 zero point -3, with the
/// 256 bytes after the 32-byte driver header as Vela emitted them. The
/// 5x5x8 IFM pads one on every side into a 3x3x8 OFM at 0xD0; the 4x4x8
/// IFM pads bottom and right only into a 2x2x8 OFM. Both IFMs sit at
/// region 1 offset 0.
const vela_pad_5x5 = [_]u32{
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0004010B, 0x0004010C, 0x0004010A,
    0x00070104, 0x00004006, 0x00000001, 0x00004005, 0x00000028, 0x00004004,
    0x00000008, 0xFFFD0109, 0x00010105, 0x00000107, 0x00010100, 0x00010101,
    0x00010103, 0x00010102, 0x0001011F, 0x00004010, 0x000000D0, 0x00004011,
    0x00000000, 0x00004012, 0x00000000, 0x00004013, 0x00000000, 0x0002011B,
    0x0002011C, 0x0002011A, 0x00020112, 0x00020111, 0x00070113, 0x00004016,
    0x00000001, 0x00004015, 0x00000018, 0x00004014, 0x00000008, 0xFFFD0118,
    0x00010114, 0x00020121, 0x00020120, 0x00030122, 0x00000125, 0xFF800126,
    0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x000A010D, 0x001E012D,
    0x00000124, 0x0000012F, 0x00000005, 0xFFFF0000,
};
const ifm_5x5 = hexBytes("6c123b070843344f1002ec47104b4618c8e8092b032052579e3970071276fcf8ea4f445ddc21588ced8ecb9eea33e98b" ++
    "d7334feb6dde90a70d9baea0cf4759acb135c333ef055f753ddfac8984fee0b3889fd37e6cdb5b3162b54c83e5797339" ++
    "71353a5102d176ef50df425f20d0c5d7fc40621c2c0749a4dde2e0660398f74ff62dda9d734d8b00a5e8851fcfcb2e93" ++
    "37bb1dae8aea6603acbe5349f8dcac1c4c3194456ca8aacf5e5303348404cf6996bf99f230fde0ab2bb5f6226d80bde5" ++
    "9ccbbb4563f1976b");
/// TFLite Micro's output; tflite-runtime agrees on every byte.
const ofm_5x5 = hexBytes("6c334f476d4b464f103970476d765f753d4f705d12765f7562334f7e7379734f71354f5f737976755040625f2c076675" ++
    "5e530366734df7695e531d34734d666937cb53496df1666b");

const vela_pad_4x4 = [_]u32{
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0003010B, 0x0003010C, 0x0003010A,
    0x00070104, 0x00004006, 0x00000001, 0x00004005, 0x00000020, 0x00004004,
    0x00000008, 0xFFFD0109, 0x00010105, 0x00000107, 0x00000100, 0x00000101,
    0x00010103, 0x00010102, 0x0001011F, 0x00004010, 0x00000080, 0x00004011,
    0x00000000, 0x00004012, 0x00000000, 0x00004013, 0x00000000, 0x0001011B,
    0x0001011C, 0x0001011A, 0x00010112, 0x00010111, 0x00070113, 0x00004016,
    0x00000001, 0x00004015, 0x00000010, 0x00004014, 0x00000008, 0xFFFD0118,
    0x00010114, 0x00020121, 0x00020120, 0x00030122, 0x00000125, 0xFF800126,
    0x007F0127, 0x00010116, 0x00010115, 0x00070117, 0x000A010D, 0x001E012D,
    0x00000124, 0x0000012F, 0x00000005, 0xFFFF0000,
};
const ifm_4x4 = hexBytes("6c123b070843344f1002ec47104b4618c8e8092b032052579e3970071276fcf8ea4f445ddc21588ced8ecb9eea33e98b" ++
    "d7334feb6dde90a70d9baea0cf4759acb135c333ef055f753ddfac8984fee0b3889fd37e6cdb5b3162b54c83e5797339" ++
    "71353a5102d176ef50df425f20d0c5d7fc40621c2c0749a4dde2e0660398f74f");
const ofm_4x4 = hexBytes("6c4f4f7e6d4b5f756239707e6d7973577140627e6c0776756240627e6c79734f");

fn runVela(words: []const u32, ifm: []const u8, ofm_at: usize, ofm: []const u8) !void {
    var memory = Memory{};
    @memcpy(memory.bytes[0..ifm.len], ifm);
    const regions: vela.dma.Regions = @splat(0);
    const result = try vela.runner.run(&memory, &regions, words);
    try std.testing.expectEqual(@as(u64, ofm.len), result.elements);
    try std.testing.expectEqualSlices(u8, ofm, memory.bytes[ofm_at..][0..ofm.len]);
}

test "a Vela SAME-padded max pool writes TFLite Micro's output" {
    try runVela(&vela_pad_5x5, &ifm_5x5, 0xD0, &ofm_5x5);
    try runVela(&vela_pad_4x4, &ifm_4x4, 0x80, &ofm_4x4);
}
