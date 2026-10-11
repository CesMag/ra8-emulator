//! Conformance vectors for the decode group `mve_float` (RA8EMU-278):
//! vector VADD, VSUB, VMUL and VABD on F32 and F16 lanes. Expected values
//! are worked from the Arm ARM (DDI0553) FPAdd, FPSub, FPMul and FPAbs of
//! FPSub pseudocode under StandardFPSCRValue (round to nearest even, DN and
//! FZ set, FZ16 kept). An F32 denormal operand reads as zero with IDC and a
//! tiny F32 result flushes to zero with UFC; with FZ16 an F16 subnormal
//! reads as zero with no flag. NaNs give the default NaN (IOC if signalling
//! or invalid); an exact zero difference is +0; overflow gives infinity
//! with OFC and IXC. A lane runs when any of its bytes is predicated (VPT,
//! loop tail, EPSR.ECI), bytes merge under the mask, and its flags count
//! only when its first byte is. Qd, Qn and Qm are written in that order.
//! The two unused U/op/x combinations, Q8 and above, flipped fixed bits
//! and the 16-bit space are unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qd: u128 = 0,
    qn: u128 = 0,
    qm: u128 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    qd: u128,
    fpscr: u32,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_float";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = lanes ++ predicated ++ unclaimed;

const lanes = [_]V{
    vec("vadd.f32 ordinary values and rounding", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0xC0800000_3ECCCCCD_BFC00000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f32 overflow, underflow and infinity times zero", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0x3F800000_7F800000_7149F2CA_7149F2CA, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f32 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7F800000_1EBCE508_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vadd.f32 exact cancellation and zero signs", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x3E800000_BF000000_40800000_40A00000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vadd.f32 near the top of the range", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0xB9800000_40000800_3F800800_40000800, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vadd.f32 equal and nearly equal lanes, with a flushed tiny difference", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xC0600000_00800000_BF800000_3F800000, .qm = 0xC0600000_00800001_3F800000_3F800000 }, .{ .qd = 0xC0E00000_01000000_00000000_40000000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f16 ordinary values, overflow and subnormals", .{ .hw1 = 0xEF12, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x7C00B800_251F60B0_C4003666_BE004480, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f16 infinities, nans and subnormals", .{ .hw1 = 0xEF12, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x18196440_44003800_7E007E00_BC007C00, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vsub.f32 ordinary values and rounding", .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x41200000_BE4CCCCE_C0200000_BFC00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f32 overflow, underflow and infinity times zero", .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0xBF800000_7F800000_7149F2CA_7149F2CA, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f32 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vsub.f32 exact cancellation and zero signs", .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0xBE800000_3FC00000_C0800000_BF800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vsub.f32 near the top of the range", .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0x40000400_00000000_BF800800_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vsub.f32 equal and nearly equal lanes, with a flushed tiny difference", .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xC0600000_00800000_BF800000_3F800000, .qm = 0xC0600000_00800001_3F800000_3F800000 }, .{ .qd = 0x00000000_80000000_C0000000_00000000, .fpscr = 0x00040008, .vpr = 0x00000000 }),
    vec("vsub.f16 ordinary values, overflow and subnormals", .{ .hw1 = 0xEF32, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0xFC00B800_00000000_4900B267_C100BE00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f16 infinities, nans and subnormals", .{ .hw1 = 0xEF32, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x00006380_C400B800_7E007E00_3C007C00, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vmul.f32 ordinary values and rounding", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0xC1A80000_3CF5C290_BF800000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vmul.f32 overflow, underflow and infinity times zero", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0x00000000_7FC00000_BF800000_7F800000, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vmul.f32 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7FC00000_00000000_7FC00000_7FC00000, .fpscr = 0x00040089, .vpr = 0x00000000 }),
    vec("vmul.f32 exact cancellation and zero signs", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x80000000_BF000000_00000000_40C00000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vmul.f32 near the top of the range", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0xBF800800_3F801000_00000000_3F801000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vmul.f32 equal and nearly equal lanes, with a flushed tiny difference", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xC0600000_00800000_BF800000_3F800000, .qm = 0xC0600000_00800001_3F800000_3F800000 }, .{ .qd = 0x41440000_00000000_BF800000_3F800000, .fpscr = 0x00040008, .vpr = 0x00000000 }),
    vec("vmul.f16 ordinary values, overflow and subnormals", .{ .hw1 = 0xFF12, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x7C008000_068E7C00_CD4027AE_BC004480, .fpscr = 0x0004001C, .vpr = 0x00000000 }),
    vec("vmul.f16 infinities, nans and subnormals", .{ .hw1 = 0xFF12, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x00117C00_80000008_7E007E00_80007C00, .fpscr = 0x0004001D, .vpr = 0x00000000 }),
    vec("vabd.f32 ordinary values and rounding", .{ .hw1 = 0xFF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x41200000_3E4CCCCE_40200000_3FC00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vabd.f32 overflow, underflow and infinity times zero", .{ .hw1 = 0xFF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0x3F800000_7F800000_7149F2CA_7149F2CA, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vabd.f32 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xFF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7F800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vabd.f32 exact cancellation and zero signs", .{ .hw1 = 0xFF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x3E800000_3FC00000_40800000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vabd.f32 near the top of the range", .{ .hw1 = 0xFF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0x40000400_00000000_3F800800_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vabd.f32 equal and nearly equal lanes, with a flushed tiny difference", .{ .hw1 = 0xFF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xC0600000_00800000_BF800000_3F800000, .qm = 0xC0600000_00800001_3F800000_3F800000 }, .{ .qd = 0x00000000_00000000_40000000_00000000, .fpscr = 0x00040008, .vpr = 0x00000000 }),
    vec("vabd.f16 ordinary values, overflow and subnormals", .{ .hw1 = 0xFF32, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x7C003800_00000000_49003267_41003E00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vabd.f16 infinities, nans and subnormals", .{ .hw1 = 0xFF32, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x00006380_44003800_7E007E00_3C007C00, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vadd.f16 with fz16 flushes subnormals", .{ .hw1 = 0xEF12, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .fpscr = 0x000C0000 }, .{ .qd = 0x18196440_44003800_7E007E00_BC007C00, .fpscr = 0x000C0001, .vpr = 0x00000000 }),
    vec("vabd.f16 with fz16 flushes subnormals", .{ .hw1 = 0xFF32, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200, .fpscr = 0x000C0000 }, .{ .qd = 0x7C003800_00000000_49003267_41003E00, .fpscr = 0x000C0000, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000, .fpscr = 0x03C40010 }, .{ .qd = 0xC1A80000_3CF5C290_BF800000_40900000, .fpscr = 0x03C40010, .vpr = 0x00000000 }),
    vec("qn equal to qm squares each lane", .{ .hw1 = 0xFF08, .hw2 = 0x0D58, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vsub with qn equal to qm gives +0 or the default nan", .{ .hw1 = 0xEF28, .hw2 = 0x0D48, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("qd equal to qm overwrites its own operand", .{ .hw1 = 0xFF26, .hw2 = 0xAD4A, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000 }, .{ .qd = 0x40400000_3DCCCCCD_40000000_3FC00000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("q7 from q6 and q5 at f16", .{ .hw1 = 0xEF3C, .hw2 = 0xED4A, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0xFC00B800_00000000_4900B267_C100BE00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps lanes 2 and 3", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000, .vpr = 0x0088FF00 }, .{ .qd = 0x7F800000_1EBCE508_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x0000FF00 }),
    vec("a lane predicated past its first byte runs without its flags", .{ .hw1 = 0xFF02, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9, .vpr = 0x0088E0E0 }, .{ .qd = 0x00000022_33334444_BF800066_77778888, .fpscr = 0x00040000, .vpr = 0x0000E0E0 }),
    vec("odd f16 lanes predicated", .{ .hw1 = 0xFF32, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .vpr = 0x0088CCCC }, .{ .qd = 0x00002222_44004444_7E006666_3C008888, .fpscr = 0x00040001, .vpr = 0x0000CCCC }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xEF32, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x11112222_33334444_5555B267_C100BE00, .fpscr = 0x00010000, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xEF22, .hw2 = 0x0D44, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9, .it = 0x20 }, .{ .qd = 0xBF800000_7F800000_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("eci a0a1a2 runs only beat 3", .{ .hw1 = 0xFF12, .hw2 = 0x0D54, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .it = 0x40 }, .{ .qd = 0x00117C00_33334444_55556666_77778888, .fpscr = 0x0004001C, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("u set with op clear and x clear is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0D44 }, none),
    vec("x set on vadd is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D54 }, none),
    vec("x set on vabd is unclaimed", .{ .hw1 = 0xFF22, .hw2 = 0x0D54 }, none),
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xEF03, .hw2 = 0x0D44 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEF42, .hw2 = 0x0D44 }, none),
    vec("hw1 bit 7 set is unclaimed", .{ .hw1 = 0xEF82, .hw2 = 0x0D44 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0DC4 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D64 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x1D44 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D45 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D44, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
