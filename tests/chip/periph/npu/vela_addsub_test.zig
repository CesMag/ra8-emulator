//! Tests for src/chip/periph/npu/vela_addsub.zig: int8 elementwise ADD and
//! SUB, from the operand decode up to real Vela 3.12.0 streams run through
//! the runner. Each stream is 2x2x4 int8, IFM at region 1 offset 0x000,
//! IFM2 at 0x010 and the OFM written in place over the IFM. The expected
//! OFMs are TFLite Micro's arithmetic; tflite-runtime agrees on every byte.
const std = @import("std");
const ra8 = @import("ra8");
const vela = ra8.chip.periph.npu.vela;
const addsub = vela.addsub;

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

/// ADD, IFM scale 0.05 (zp -3), IFM2 0.08 (zp 4), OFM 0.11 (zp 7). The
/// scales differ, so Vela uses advanced scaling: IFM_PRECISION 0x0101
/// scales the IFM (the smaller scale) by OPA_SCALE 0x50000032 shift 12,
/// and OFM_SCALE is 0x5D1745B7 shift 50.
const vela_add_adv = [_]u32{
    0x000C4025, 0x50000032, 0x00004026, 0x00000000, 0x00324024, 0x5D1745B7,
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0001010B, 0x0001010C, 0x0001010A,
    0x00030104, 0x00004006, 0x00000001, 0x00004005, 0x00000008, 0x00004004,
    0x00000004, 0xFFFD0109, 0x01010105, 0x00000107, 0x0001011F, 0x00004010,
    0x00000000, 0x00004011, 0x00000000, 0x00004012, 0x00000000, 0x00004013,
    0x00000000, 0x0001011B, 0x0001011C, 0x0001011A, 0x00010112, 0x00010111,
    0x00030113, 0x00004016, 0x00000001, 0x00004015, 0x00000008, 0x00004014,
    0x00000004, 0x00070118, 0x01010114, 0x00000125, 0xFF800126, 0x007F0127,
    0x00010116, 0x00010115, 0x00070117, 0x002E010D, 0x002E012D, 0x000A018D,
    0x00000124, 0x0001018F, 0x00004080, 0x00000010, 0x00004081, 0x00000000,
    0x00004082, 0x00000000, 0x00004083, 0x00000000, 0x0001018B, 0x0001018C,
    0x0001018A, 0x00004086, 0x00000001, 0x00004085, 0x00000008, 0x00004084,
    0x00000004, 0x00040189, 0x00010185, 0x00000180, 0x0000012F, 0x00010006,
    0xFFFF0000,
};
const add_adv_a = hexBytes("e2716fced7c1d1b8524961b7e34ee23b");
const add_adv_b = hexBytes("89ebaffdb268f84a85a74b3f30e7e47d");
const add_adv_ofm = hexBytes("a12afdedba34ea1bd1e668121b17e37b");

/// SUB, IFM scale 0.08 (zp 4), IFM2 0.05 (zp -3), OFM 0.11 (zp 7). Here
/// IFM2 has the smaller scale, so IFM_PRECISION 0x0201 scales IFM2.
const vela_sub_adv = [_]u32{
    0x000C4025, 0x50000032, 0x00004026, 0x00000000, 0x00324024, 0x5D1745B7,
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0001010B, 0x0001010C, 0x0001010A,
    0x00030104, 0x00004006, 0x00000001, 0x00004005, 0x00000008, 0x00004004,
    0x00000004, 0x00040109, 0x02010105, 0x00000107, 0x0001011F, 0x00004010,
    0x00000000, 0x00004011, 0x00000000, 0x00004012, 0x00000000, 0x00004013,
    0x00000000, 0x0001011B, 0x0001011C, 0x0001011A, 0x00010112, 0x00010111,
    0x00030113, 0x00004016, 0x00000001, 0x00004015, 0x00000008, 0x00004014,
    0x00000004, 0x00070118, 0x01010114, 0x00000125, 0xFF800126, 0x007F0127,
    0x00010116, 0x00010115, 0x00070117, 0x002E010D, 0x002E012D, 0x000A018D,
    0x00000124, 0x0001018F, 0x00004080, 0x00000010, 0x00004081, 0x00000000,
    0x00004082, 0x00000000, 0x00004083, 0x00000000, 0x0001018B, 0x0001018C,
    0x0001018A, 0x00004086, 0x00000001, 0x00004085, 0x00000008, 0x00004084,
    0x00000004, 0xFFFD0189, 0x00010185, 0x00000180, 0x0000012F, 0x00020006,
    0xFFFF0000,
};
const sub_adv_a = hexBytes("761dc113f7054a81d80cbf7766e59b84");
const sub_adv_b = hexBytes("c5be69720b6590f9bd9daf94377b0090");
const sub_adv_ofm = hexBytes("7336a5ddf7d86baa0438f87f34b7b9db");

/// ADD, both inputs at scale 0.05 (zp 3 and -2), OFM 0.1 (zp 1). Equal
/// scales and an OFM scale with its low 12 bits clear, so Vela uses
/// simplified scaling: IFM_PRECISION 0x0001, OPA_SCALE and OPB_SCALE both
/// 0x8000 shift 0, OFM_SCALE 0x40000000 shift 46.
const vela_add_simple = [_]u32{
    0x00004025, 0x00008000, 0x00004026, 0x00008000, 0x002E4024, 0x40000000,
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0001010B, 0x0001010C, 0x0001010A,
    0x00030104, 0x00004006, 0x00000001, 0x00004005, 0x00000008, 0x00004004,
    0x00000004, 0x00030109, 0x00010105, 0x00000107, 0x0001011F, 0x00004010,
    0x00000000, 0x00004011, 0x00000000, 0x00004012, 0x00000000, 0x00004013,
    0x00000000, 0x0001011B, 0x0001011C, 0x0001011A, 0x00010112, 0x00010111,
    0x00030113, 0x00004016, 0x00000001, 0x00004015, 0x00000008, 0x00004014,
    0x00000004, 0x00010118, 0x01010114, 0x00000125, 0xFF800126, 0x007F0127,
    0x00010116, 0x00010115, 0x00070117, 0x002E010D, 0x002E012D, 0x000A018D,
    0x00000124, 0x0001018F, 0x00004080, 0x00000010, 0x00004081, 0x00000000,
    0x00004082, 0x00000000, 0x00004083, 0x00000000, 0x0001018B, 0x0001018C,
    0x0001018A, 0x00004086, 0x00000001, 0x00004085, 0x00000008, 0x00004084,
    0x00000004, 0xFFFE0189, 0x00010185, 0x00000180, 0x0000012F, 0x00010006,
    0xFFFF0000,
};
const add_simple_a = hexBytes("41822d384fd4046edd9aa12a4051b131");
const add_simple_b = hexBytes("3d7f4d4428ca7bcdaa199421e5aec947");
const add_simple_ofm = hexBytes("40013e3f3ccf401ec4da9b261300bd3d");

/// SUB at equal scales: both inputs 0.05 (zp 3 and -2), OFM 0.1 (zp 1),
/// simplified scaling as in the ADD above.
const vela_sub_simple = [_]u32{
    0x00004025, 0x00008000, 0x00004026, 0x00008000, 0x002E4024, 0x40000000,
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0001010B, 0x0001010C, 0x0001010A,
    0x00030104, 0x00004006, 0x00000001, 0x00004005, 0x00000008, 0x00004004,
    0x00000004, 0x00030109, 0x00010105, 0x00000107, 0x0001011F, 0x00004010,
    0x00000000, 0x00004011, 0x00000000, 0x00004012, 0x00000000, 0x00004013,
    0x00000000, 0x0001011B, 0x0001011C, 0x0001011A, 0x00010112, 0x00010111,
    0x00030113, 0x00004016, 0x00000001, 0x00004015, 0x00000008, 0x00004014,
    0x00000004, 0x00010118, 0x01010114, 0x00000125, 0xFF800126, 0x007F0127,
    0x00010116, 0x00010115, 0x00070117, 0x002E010D, 0x002E012D, 0x000A018D,
    0x00000124, 0x0001018F, 0x00004080, 0x00000010, 0x00004081, 0x00000000,
    0x00004082, 0x00000000, 0x00004083, 0x00000000, 0x0001018B, 0x0001018C,
    0x0001018A, 0x00004086, 0x00000001, 0x00004085, 0x00000008, 0x00004084,
    0x00000004, 0xFFFE0189, 0x00010185, 0x00000180, 0x0000012F, 0x00020006,
    0xFFFF0000,
};
const sub_simple_a = hexBytes("cfb8cd0401945a1342961df4cd2ae3a0");
const sub_simple_b = hexBytes("416d666e87f9c03653a4d1ac8144cfe2");
const sub_simple_ofm = hexBytes("c5a4b2c93ccc4cedf6f7252325f109dd");

/// SUB, IFM scale 0.02 (zp 10), IFM2 0.3 (zp -20), OFM 0.25 (zp 0): a 15x
/// scale ratio. IFM_PRECISION 0x0101 scales the IFM by OPA_SCALE
/// 0x444443FD shift 15; OFM_SCALE is 0x4CCCCD00 shift 49.
const vela_sub_adv_a = [_]u32{
    0x000F4025, 0x444443FD, 0x00004026, 0x00000000, 0x00314024, 0x4CCCCD00,
    0x0001010F, 0x00004000, 0x00000000, 0x00004001, 0x00000000, 0x00004002,
    0x00000000, 0x00004003, 0x00000000, 0x0001010B, 0x0001010C, 0x0001010A,
    0x00030104, 0x00004006, 0x00000001, 0x00004005, 0x00000008, 0x00004004,
    0x00000004, 0x000A0109, 0x01010105, 0x00000107, 0x0001011F, 0x00004010,
    0x00000000, 0x00004011, 0x00000000, 0x00004012, 0x00000000, 0x00004013,
    0x00000000, 0x0001011B, 0x0001011C, 0x0001011A, 0x00010112, 0x00010111,
    0x00030113, 0x00004016, 0x00000001, 0x00004015, 0x00000008, 0x00004014,
    0x00000004, 0x00000118, 0x01010114, 0x00000125, 0xFF800126, 0x007F0127,
    0x00010116, 0x00010115, 0x00070117, 0x002E010D, 0x002E012D, 0x000A018D,
    0x00000124, 0x0001018F, 0x00004080, 0x00000010, 0x00004081, 0x00000000,
    0x00004082, 0x00000000, 0x00004083, 0x00000000, 0x0001018B, 0x0001018C,
    0x0001018A, 0x00004086, 0x00000001, 0x00004085, 0x00000008, 0x00004084,
    0x00000004, 0xFFEC0189, 0x00010185, 0x00000180, 0x0000012F, 0x00020006,
    0xFFFF0000,
};
const sub_adv_a_a = hexBytes("76553a5eb8b747ba16fed64002349e72");
const sub_adv_a_b = hexBytes("489130fddad6e61a838aead73194fd78");
const sub_adv_a_ofm = hexBytes("9a73b2f20f140cc27f75fe1ead6de380");

fn replay(words: []const u32, a: []const u8, b: []const u8) !Memory {
    var memory = Memory{};
    @memcpy(memory.bytes[0x800..][0..a.len], a);
    @memcpy(memory.bytes[0x810..][0..b.len], b);
    const result = try vela.runner.run(&memory, &regions, words);
    try std.testing.expectEqual(@as(u64, 16), result.elements);
    return memory;
}

test "the IFM precision picks simplified or advanced operand scaling" {
    const s = addsub.Operands.decode(0x0001, vela.quant.Scale{ .scale = 0x8000 }, vela.quant.Scale{ .scale = 0x8000 }).?;
    try std.testing.expectEqual(@as(u32, 0x8000), s.simplified.b);
    const a = addsub.Operands.decode(0x0201, vela.quant.Scale{ .scale = 0x5000_0032, .shift = 12 }, vela.quant.Scale{}).?;
    try std.testing.expect(!a.advanced.scale_a);
    try std.testing.expectEqual(@as(u6, 32), a.advanced.shift);
}

test "operand scalings Vela never emits are not decoded" {
    try std.testing.expectEqual(@as(?addsub.Operands, null), addsub.Operands.decode(0x0301, vela.quant.Scale{ .scale = 1, .shift = 12 }, vela.quant.Scale{}));
    try std.testing.expectEqual(@as(?addsub.Operands, null), addsub.Operands.decode(0x0101, vela.quant.Scale{ .scale = 1, .shift = 10 }, vela.quant.Scale{}));
    try std.testing.expectEqual(@as(?addsub.Operands, null), addsub.Operands.decode(0x0001, vela.quant.Scale{ .scale = 1, .shift = 1 }, vela.quant.Scale{}));
}

test "an equal-scale ADD is the sum rescaled" {
    // 0x8000 * (3 + 4) = 0x38000; scale 2^30 shift 46 is 2^-16: 3.5 rounds to 4.
    const ops = addsub.Operands{ .simplified = .{ .a = 0x8000, .b = 0x8000 } };
    try std.testing.expectEqual(@as(i32, 5), addsub.element(addsub.mode_add, ops, 3, 4, 1 << 30, 46, .double, 1, -128, 127));
    try std.testing.expectEqual(@as(i32, 1), addsub.element(addsub.mode_sub, ops, 3, 3, 1 << 30, 46, .double, 1, -128, 127));
}

test "a Vela-compiled advanced ADD writes TFLite Micro's output" {
    const memory = try replay(&vela_add_adv, &add_adv_a, &add_adv_b);
    try std.testing.expectEqualSlices(u8, &add_adv_ofm, memory.bytes[0x800..][0..16]);
}

test "a Vela-compiled advanced SUB scaling IFM2 writes TFLite Micro's output" {
    const memory = try replay(&vela_sub_adv, &sub_adv_a, &sub_adv_b);
    try std.testing.expectEqualSlices(u8, &sub_adv_ofm, memory.bytes[0x800..][0..16]);
}

test "a Vela-compiled equal-scale ADD writes TFLite Micro's output" {
    const memory = try replay(&vela_add_simple, &add_simple_a, &add_simple_b);
    try std.testing.expectEqualSlices(u8, &add_simple_ofm, memory.bytes[0x800..][0..16]);
}

test "a Vela-compiled equal-scale SUB writes TFLite Micro's output" {
    const memory = try replay(&vela_sub_simple, &sub_simple_a, &sub_simple_b);
    try std.testing.expectEqualSlices(u8, &sub_simple_ofm, memory.bytes[0x800..][0..16]);
}

test "a Vela-compiled advanced SUB scaling the IFM writes TFLite Micro's output" {
    const memory = try replay(&vela_sub_adv_a, &sub_adv_a_a, &sub_adv_a_b);
    try std.testing.expectEqualSlices(u8, &sub_adv_a_ofm, memory.bytes[0x800..][0..16]);
}

test "an ADD with an activation function is not modelled" {
    var memory = Memory{};
    var words = vela_add_adv;
    words[51] = 0x00010125; // ACTIVATION: 1 instead of 0
    try std.testing.expectError(error.OperatorNotModelled, vela.runner.run(&memory, &regions, &words));
}
