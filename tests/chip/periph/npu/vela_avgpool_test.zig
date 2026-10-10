//! Tests for src/chip/periph/npu/vela_avgpool.zig: unpadded and padded int8
//! AVERAGE pooling, from the per-element arithmetic up to real Vela 3.12.0 streams
//! run through the runner.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu_vela;
const avgpool = vela.avgpool;

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

fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "a window sum divides by the kernel size, rounding half away from zero" {
    // Vela's quantise_pooling_scale(4) is 0x80000001 with shift 33.
    try std.testing.expectEqual(@as(i32, 3), avgpool.average(10, 0x8000_0001, 33, .double, 0, -128, 127));
    try std.testing.expectEqual(@as(i32, -3), avgpool.average(-10, 0x8000_0001, 33, .double, 0, -128, 127));
    try std.testing.expectEqual(@as(i32, 2), avgpool.average(9, 0x8000_0001, 33, .double, 0, -128, 127));
    try std.testing.expectEqual(@as(i32, 7), avgpool.average(10, 0x8000_0001, 33, .double, 4, -128, 127));
    try std.testing.expectEqual(@as(i32, 5), avgpool.average(100, 0x8000_0001, 33, .double, 0, -128, 5));
}

/// Real Vela 3.12.0 streams (ethos-u55-256) for TFLite AVERAGE_POOL_2D,
/// int8, VALID padding, scale 0.05 zero point -3 (Vela writes both zero
/// points as 0), IFM at region 1 offset 0. The words after the 32-byte
/// driver header, as Vela emitted them. 4x4x8 by 2x2 at stride 2 into
/// 2x2x8 (OFM_SCALE 0x80000001, shift 33):
const vela_avg_2x2 = [_]u32{
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0003010B, 0x0003010C, 0x0003010A,
    0x00070104, 0x00004006, 0x00000001, 0x00004005, 0x00000020, 0x00004004,
    0x00000008, 0x00000109, 0x00010105, 0x00000107, 0x00000100, 0x00000101,
    0x00000103, 0x00000102, 0x0001011F, 0x00004010, 0x00000080, 0x00004011,
    0x00000000, 0x00004012, 0x00000000, 0x00004013, 0x00000000, 0x0001011B,
    0x0001011C, 0x0001011A, 0x00010112, 0x00010111, 0x00070113, 0x00004016,
    0x00000001, 0x00004015, 0x00000010, 0x00004014, 0x00000008, 0x00000118,
    0x01010114, 0x00010121, 0x00010120, 0x00030122, 0x00000125, 0xFF800126,
    0x007F0127, 0x00010116, 0x00010115, 0x00070117, 0x000A010D, 0x001E012D,
    0x00000124, 0x00214024, 0x80000001, 0x0000012F, 0x00010005, 0xFFFF0000,
};
const ifm_2x2 = hexBytes("0067b8930cc5bf1fa36f4d9544214e46bc02f53f396112ff034b468e1f3aa94549916e9abfe3c4d35fc0d2577681bcae" ++
    "d8231ffa8300b02ed38e743b1c273166511f787d58ff0638a88b22c233ac460be3f2a2b1bef6b0a1f4f3d9744502d1f3" ++
    "01fb62bf7913c7a88a9962fd17a2fc2dfe1dc1f7d5b36de6ba71e22f5f4f2aa6");
/// TFLite Micro's output; tflite-runtime agrees on every byte.
const ofm_2x2 = hexBytes("130a11c621d2e3f9daff3401fe31e736e1cf58ff47d80406e41dc7130efe06c8");

/// 5x5x8 by 3x3 at stride 1 into 3x3x8 (OFM_SCALE 0xE38E38E5, shift 35).
const vela_avg_3x3 = [_]u32{
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0004010B, 0x0004010C, 0x0004010A,
    0x00070104, 0x00004006, 0x00000001, 0x00004005, 0x00000028, 0x00004004,
    0x00000008, 0x00000109, 0x00010105, 0x00000107, 0x00000100, 0x00000101,
    0x00000103, 0x00000102, 0x0001011F, 0x00004010, 0x000000D0, 0x00004011,
    0x00000000, 0x00004012, 0x00000000, 0x00004013, 0x00000000, 0x0002011B,
    0x0002011C, 0x0002011A, 0x00020112, 0x00020111, 0x00070113, 0x00004016,
    0x00000001, 0x00004015, 0x00000018, 0x00004014, 0x00000008, 0x00000118,
    0x01010114, 0x00020121, 0x00020120, 0x00000122, 0x00000125, 0xFF800126,
    0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x000A010D, 0x001E012D,
    0x00000124, 0x00234024, 0xE38E38E5, 0x0000012F, 0x00010005, 0xFFFF0000,
};
const ifm_3x3 = hexBytes("0067b8930cc5bf1fa36f4d9544214e46bc02f53f396112ff034b468e1f3aa94549916e9abfe3c4d35fc0d2577681bcae" ++
    "d8231ffa8300b02ed38e743b1c273166511f787d58ff0638a88b22c233ac460be3f2a2b1bef6b0a1f4f3d9744502d1f3" ++
    "01fb62bf7913c7a88a9962fd17a2fc2dfe1dc1f7d5b36de6ba71e22f5f4f2aa67d7826dc94e02de0ce99243e3bc45bfe" ++
    "d96e091e0766f9b3a2ec492d9fd42a051996cd1ea2f4d5677fe5e106b71f5a3133d5171a36c88785736c0547d9d59f83" ++
    "ac0526f1ec14c8da");
const ofm_3x3 = hexBytes("eb0507fb1fffe4fde0023e082811f220eedd40f420f8050efdfb0c1515f6f4e4f5fb381f12fd0004d9e03a141aea2103" ++
    "13f7fa0c06fcf7e016051a170df1f4d7e8fe231007e6f5d0");

/// Padded AVERAGE pool from Vela 3.12.0 (ethos-u55-256): 1x5x5x8 int8, 3x3 kernel, stride 2, SAME: one pad on every side, so the
/// corner windows hold 4 taps and the edge windows 6. Out 1x3x3x8.
/// Vela emits it with IFM_PAD 1/1/1/1, no OFM_SCALE and OFM_PRECISION
/// 0x0001 (global scale off); IFM at 0x000, OFM at 0x0D0.
const vela_avg_same_5x5 = [_]u32{
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0004010B, 0x0004010C, 0x0004010A,
    0x00070104, 0x00004006, 0x00000001, 0x00004005, 0x00000028, 0x00004004,
    0x00000008, 0x00000109, 0x00010105, 0x00000107, 0x00010100, 0x00010101,
    0x00010103, 0x00010102, 0x0001011F, 0x00004010, 0x000000D0, 0x00004011,
    0x00000000, 0x00004012, 0x00000000, 0x00004013, 0x00000000, 0x0002011B,
    0x0002011C, 0x0002011A, 0x00020112, 0x00020111, 0x00070113, 0x00004016,
    0x00000001, 0x00004015, 0x00000018, 0x00004014, 0x00000008, 0x00000118,
    0x00010114, 0x00020121, 0x00020120, 0x00030122, 0x00000125, 0xFF800126,
    0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x000A010D, 0x001E012D,
    0x00000124, 0x0000012F, 0x00010005, 0xFFFF0000,
};
const ifm_same_5x5 = hexBytes("0067b8930cc5bf1fa36f4d9544214e46bc02f53f396112ff034b468e1f3aa94549916e9abfe3c4d35fc0d2577681bcae" ++
    "d8231ffa8300b02ed38e743b1c273166511f787d58ff0638a88b22c233ac460be3f2a2b1bef6b0a1f4f3d9744502d1f3" ++
    "01fb62bf7913c7a88a9962fd17a2fc2dfe1dc1f7d5b36de6ba71e22f5f4f2aa67d7826dc94e02de0ce99243e3bc45bfe" ++
    "d96e091e0766f9b3a2ec492d9fd42a051996cd1ea2f4d5677fe5e106b71f5a3133d5171a36c88785736c0547d9d59f83" ++
    "ac0526f1ec14c8da");
/// TensorFlow Lite's reference: each window sum over in-bounds taps,
/// divided by their count, a half rounded away from zero. tflite-runtime
/// agrees on every byte.
const ofm_same_5x5 = hexBytes("f62efdde12dade10e51743031926fd3911e154da1af2ee170c1ee916fdf1e1d4f5fb381f12fd0004d5f42d1505df2402" ++
    "3419ed0cd3112208371c0d1beff600cce6331f21db09e2c5");

/// Padded AVERAGE pool from Vela 3.12.0 (ethos-u55-256): 1x4x4x8 int8, 3x3 kernel, stride 1, SAME: one pad on every side.
/// Out 1x4x4x8.
/// Vela emits it with IFM_PAD 1/1/1/1, no OFM_SCALE and OFM_PRECISION
/// 0x0001 (global scale off); IFM at 0x000, OFM at 0x080.
const vela_avg_same_4x4 = [_]u32{
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0003010B, 0x0003010C, 0x0003010A,
    0x00070104, 0x00004006, 0x00000001, 0x00004005, 0x00000020, 0x00004004,
    0x00000008, 0x00000109, 0x00010105, 0x00000107, 0x00010100, 0x00010101,
    0x00010103, 0x00010102, 0x0001011F, 0x00004010, 0x00000080, 0x00004011,
    0x00000000, 0x00004012, 0x00000000, 0x00004013, 0x00000000, 0x0003011B,
    0x0003011C, 0x0003011A, 0x00030112, 0x00030111, 0x00070113, 0x00004016,
    0x00000001, 0x00004015, 0x00000020, 0x00004014, 0x00000008, 0x00000118,
    0x00010114, 0x00020121, 0x00020120, 0x00000122, 0x00000125, 0xFF800126,
    0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x000A010D, 0x001E012D,
    0x00000124, 0x0000012F, 0x00010005, 0xFFFF0000,
};
const ifm_same_4x4 = hexBytes("0067b8930cc5bf1fa36f4d9544214e46bc02f53f396112ff034b468e1f3aa94549916e9abfe3c4d35fc0d2577681bcae" ++
    "d8231ffa8300b02ed38e743b1c273166511f787d58ff0638a88b22c233ac460be3f2a2b1bef6b0a1f4f3d9744502d1f3" ++
    "01fb62bf7913c7a88a9962fd17a2fc2dfe1dc1f7d5b36de6ba71e22f5f4f2aa6");
/// TensorFlow Lite's reference: each window sum over in-bounds taps,
/// divided by their count, a half rounded away from zero. tflite-runtime
/// agrees on every byte.
const ofm_same_4x4 = hexBytes("130a11c621d2e3f9fa0d0fe30bf2e203e70828fd1e11f122daff3401fe31e7360bf825e42dd3f907f8fd11eb0fececff" ++
    "e1f50ffb1a01f00ce0fb0c07ff1fda1207c245fd38cbedeffddd20f30bd3eeecdee4011111e2fff5df06f315f906fff3" ++
    "e1cf58ff47d80406e6e220f01dd707f0cbeef00216e10fe4e41dc7130efe06c8");

fn runVela(words: []const u32, ifm: []const u8, ofm_at: usize, ofm: []const u8) !void {
    var memory = Memory{};
    @memcpy(memory.bytes[0..ifm.len], ifm);
    const regions: vela.dma.Regions = @splat(0);
    const result = try vela.runner.run(&memory, &regions, words);
    try std.testing.expectEqual(@as(u64, ofm.len), result.elements);
    try std.testing.expectEqualSlices(u8, ofm, memory.bytes[ofm_at..][0..ofm.len]);
}

test "a Vela-compiled unpadded average pool writes TFLite Micro's output" {
    try runVela(&vela_avg_2x2, &ifm_2x2, 0x00000080, &ofm_2x2);
    try runVela(&vela_avg_3x3, &ifm_3x3, 0x000000D0, &ofm_3x3);
}

fn withWord(index: usize, word: u32) [vela_avg_2x2.len]u32 {
    var words = vela_avg_2x2;
    words[index] = word;
    return words;
}

test "a padded window divides by its in-bounds taps, rounding half away from zero" {
    try std.testing.expectEqual(@as(i32, 3), avgpool.divide(10, 4, -128, 127));
    try std.testing.expectEqual(@as(i32, -3), avgpool.divide(-10, 4, -128, 127));
    try std.testing.expectEqual(@as(i32, 2), avgpool.divide(11, 6, -128, 127));
    try std.testing.expectEqual(@as(i32, -5), avgpool.divide(-9, 2, -128, 127));
}

test "a Vela-compiled SAME average pool writes TFLite's output" {
    try runVela(&vela_avg_same_5x5, &ifm_same_5x5, 0x000000D0, &ofm_same_5x5);
    try runVela(&vela_avg_same_4x4, &ifm_same_4x4, 0x00000080, &ofm_same_4x4);
}

test "a padded average pool outside Vela's form or the TRM limits is not modelled" {
    var memory = Memory{};
    const regions: vela.dma.Regions = @splat(0);
    var words = vela_avg_same_4x4;
    const prec = std.mem.indexOfScalar(u32, &words, 0x00010114).?; // OFM_PRECISION, global scale off
    words[prec] = 0x01010114;
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
    words = vela_avg_same_4x4;
    const top = std.mem.indexOfScalar(u32, &words, 0x00010100).?; // IFM_PAD_TOP 1
    words[top] = 0x00040100;
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
    words = vela_avg_same_4x4;
    const zp = std.mem.indexOfScalar(u32, &words, 0x00000109).?; // IFM_ZERO_POINT 0
    words[zp] = 0x00050109;
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
}

test "padded-with-scale, per-channel or activated average pools are not modelled" {
    var memory = Memory{};
    const regions: vela.dma.Regions = @splat(0);
    const index = std.mem.indexOfScalar(u32, &vela_avg_2x2, 0x00000100).?; // IFM_PAD_TOP 0
    var words = withWord(index, 0x00010100);
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
    words = withWord(std.mem.indexOfScalar(u32, &vela_avg_2x2, 0x01010114).?, 0x00010114);
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
    words = withWord(std.mem.indexOfScalar(u32, &vela_avg_2x2, 0x00000125).?, 0x00030125);
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
}
