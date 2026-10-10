//! Tests for src/chip/periph/npu/npu_vela_mul.zig: int8 elementwise MUL, from
//! the per-element arithmetic up to a real Vela 3.12.0 stream run through
//! the runner.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu_vela;
const mul = vela.mul;

/// A flat 4 KiB memory at bus address 0x1000 that refuses everything else.
const Memory = struct {
    bytes: [4096]u8 = @splat(0),

    const base: u32 = 0x1000;

    fn slot(self: *Memory, address: u32, len: usize) error{Refused}![]u8 {
        if (address < base or address - base + len > self.bytes.len) return error.Refused;
        return self.bytes[address - base ..][0..len];
    }

    pub fn read(self: *Memory, address: u32, into: []u8) error{Refused}!void {
        @memcpy(into, try self.slot(address, into.len));
    }

    pub fn write(self: *Memory, address: u32, bytes: []const u8) error{Refused}!void {
        @memcpy(try self.slot(address, bytes.len), bytes);
    }
};

const regions: vela.dma.Regions = .{ 0x1000, 0x1800, 0, 0, 0, 0, 0, 0 };

fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "the product is scaled, offset by the OFM zero point and clamped" {
    // Scale 2^30 with shift 31 halves: 6 * 7 = 42, so 21, plus 5.
    try std.testing.expectEqual(@as(i32, 26), mul.product(6, 7, 1 << 30, 31, .double, 5, -128, 127));
    try std.testing.expectEqual(@as(i32, 10), mul.product(100, 100, 1 << 30, 30, .double, 0, -10, 10));
    try std.testing.expectEqual(@as(i32, -10), mul.product(-100, 100, 1 << 30, 30, .double, 0, -10, 10));
}

/// A real Vela 3.12.0 stream (ethos-u55-256): TFLite MUL, int8 1x4x4x8,
/// IFM scale 0.05 zero point -3, IFM2 scale 0.08 zero point 4, OFM scale
/// 0.11 zero point 7. OFM_SCALE is 0x4A790500 with shift 35 and
/// OFM_PRECISION 0x0101 (signed int8, global scale, TFL rounding). IFM at
/// region 1 offset 0x00, IFM2 at 0x80 and the OFM over the IFM. The 324
/// bytes after the 32-byte driver header, as Vela emitted them.
const vela_mul = [_]u32{
    0x00234024, 0x4A790500, 0x0001010F, 0x00004000, 0x00000000, 0x00004001,
    0x00000000, 0x00004002, 0x00000000, 0x00004003, 0x00000000, 0x0003010B,
    0x0003010C, 0x0003010A, 0x00070104, 0x00004006, 0x00000001, 0x00004005,
    0x00000020, 0x00004004, 0x00000008, 0xFFFD0109, 0x00010105, 0x00000107,
    0x0001011F, 0x00004010, 0x00000000, 0x00004011, 0x00000000, 0x00004012,
    0x00000000, 0x00004013, 0x00000000, 0x0003011B, 0x0003011C, 0x0003011A,
    0x00030112, 0x00030111, 0x00070113, 0x00004016, 0x00000001, 0x00004015,
    0x00000020, 0x00004014, 0x00000008, 0x00070118, 0x01010114, 0x00000125,
    0xFF800126, 0x007F0127, 0x00030116, 0x00030115, 0x00070117, 0x002E010D,
    0x002E012D, 0x000A018D, 0x00000124, 0x0001018F, 0x00004080, 0x00000080,
    0x00004081, 0x00000000, 0x00004082, 0x00000000, 0x00004083, 0x00000000,
    0x0003018B, 0x0003018C, 0x0003018A, 0x00004086, 0x00000001, 0x00004085,
    0x00000020, 0x00004084, 0x00000008, 0x00040189, 0x00010185, 0x00000180,
    0x0000012F, 0x00000006, 0xFFFF0000,
};

const ifm = hexBytes("2a9f51c22ae7967808a97e5b84a999d6e72d3b1df174dfe9e6707c6d1637e984174c9b660b065ab277ae3d582796310b" ++
    "7db4b8cd567a77c6362ed14427c9d8a5e64516f455c9afb6f07b0d255705129dcb693dd5194a8d67c5b4677aaa640c10" ++
    "f83917c7a139ddee77d397324fe25e34ba5902c52cb4d7d2b9ec7c3a28ef2531");
const ifm2 = hexBytes("ae7ea7bbe142a8fa6ceb621a4e9ee5d0eac6e31cf8b9bf8c808ac546762fb259a62d998dd6331a0ca8765bba4f93b255" ++
    "43ecd8f84a3710ae94f3094d0d18b867d45d2fc6004b9f22c89efac3a04034582aa73c34e1d369ae9f997999d3f64d9d" ++
    "da1b24538fec621e6b56765200d0e11053f9039e25b3f89511b832758a68cb52");
/// TFLite Micro's int8 MUL for those inputs; tflite-runtime agrees on every
/// byte.
const ofm = hexBytes("8080807fced57fda31537f52807f78511c9bbd230c80525e7580807f6f624380ae7d7f80f01651f180807f807a7f8030" ++
    "7f47751c7f7f3c7f80e9ff7f15e16d802f7f2e1bfa817fba238001a880182c80c2807fc1e38080807f7f7f807fd32fc0" ++
    "0f3925807fd39af97f8a807ffb3a8c1f80e2077f3f7f187fe7367f7f80d4b47f");

test "a Vela-compiled MUL writes TFLite Micro's output" {
    var memory = Memory{};
    @memcpy(memory.bytes[0x800..0x880], &ifm);
    @memcpy(memory.bytes[0x880..0x900], &ifm2);
    const result = try vela.runner.run(&memory, &regions, &vela_mul);
    try std.testing.expectEqual(@as(u64, 128), result.elements);
    try std.testing.expectEqualSlices(u8, &ofm, memory.bytes[0x800..0x880]);
}

test "a MUL with per-channel scale or an activation function is not modelled" {
    var memory = Memory{};
    var words = vela_mul;
    words[46] = 0x00010114; // OFM_PRECISION without b8 (global scale)
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
    words = vela_mul;
    words[47] = 0x00030125; // ACTIVATION tanh
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
}
