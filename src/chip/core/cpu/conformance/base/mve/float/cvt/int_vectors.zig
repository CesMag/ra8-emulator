//! Conformance vectors for the decode group `mve_float_cvt_int`
//! (RA8EMU-278): VCVT between F32 and 32-bit integers and between F16 and
//! 16-bit integers, both ways, and VCVTA/N/P/M float to integer. Expected
//! values are worked from the Arm ARM (DDI0553) FPToFixed and FixedToFP
//! pseudocode under StandardFPSCRValue. Float to integer rounds toward
//! zero (VCVT) or by the encoded mode (ties away, nearest even, toward
//! +inf, toward -inf); a NaN gives 0 with IOC, an infinity or out-of-range
//! value saturates with IOC and no IXC, an inexact result raises IXC, an
//! F32 denormal reads as zero with IDC, and with FZ16 an F16 subnormal
//! reads as zero with no flag. Integer to float rounds to nearest even
//! with IXC, and a 16-bit value past 65520 overflows F16 to infinity with
//! OFC and IXC. A lane runs when any byte is predicated (VPT, loop tail,
//! EPSR.ECI), bytes merge under the mask, and its flags count only when
//! its first byte is. Qd is written before Qm. Sizes 00 and 11, Q8 and
//! above, flipped fixed bits and the 16-bit space are unclaimed.
const vector = @import("../../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qd: u128 = 0,
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
const group = "mve_float_cvt_int";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = to_int ++ from_int ++ predicated ++ unclaimed;

const to_int = [_]V{
    vec("vcvt.s32.f32 toward zero, halves", .{ .hw1 = 0xFFBB, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0xFFFFFFFF_00000003_FFFFFFFE_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvta.s32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x0042, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0xFFFFFFFE_00000004_FFFFFFFD_00000003, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvtn.s32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x0142, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0xFFFFFFFE_00000004_FFFFFFFE_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvtp.s32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x0242, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0xFFFFFFFF_00000004_FFFFFFFE_00000003, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvtm.s32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x0342, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0xFFFFFFFE_00000003_FFFFFFFD_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 saturation", .{ .hw1 = 0xFFBB, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4F800000_CF000001_4F000000_BF19999A }, .{ .qd = 0x7FFFFFFF_80000000_7FFFFFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtn.s32.f32 saturation", .{ .hw1 = 0xFFBB, .hw2 = 0x0142, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4F800000_CF000001_4F000000_BF19999A }, .{ .qd = 0x7FFFFFFF_80000000_7FFFFFFF_FFFFFFFF, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 nans, infinity and a flushed denormal", .{ .hw1 = 0xFFBB, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x80000123_7F800000_FF800001_7FC00000 }, .{ .qd = 0x00000000_7FFFFFFF_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 exact and inexact values", .{ .hw1 = 0xFFBB, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x3E800000_47F12060_80000000_3F800000 }, .{ .qd = 0x00000000_0001E240_00000000_00000001, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 toward zero, halves", .{ .hw1 = 0xFFBB, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0x00000000_00000003_00000000_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvta.u32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x00C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0x00000000_00000004_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtn.u32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x01C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0x00000000_00000004_00000000_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtp.u32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x02C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0x00000000_00000004_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtm.u32.f32 halves", .{ .hw1 = 0xFFBB, .hw2 = 0x03C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0x00000000_00000003_00000000_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 saturation", .{ .hw1 = 0xFFBB, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4F800000_CF000001_4F000000_BF19999A }, .{ .qd = 0xFFFFFFFF_00000000_80000000_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtn.u32.f32 saturation", .{ .hw1 = 0xFFBB, .hw2 = 0x01C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4F800000_CF000001_4F000000_BF19999A }, .{ .qd = 0xFFFFFFFF_00000000_80000000_00000000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 nans, infinity and a flushed denormal", .{ .hw1 = 0xFFBB, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x80000123_7F800000_FF800001_7FC00000 }, .{ .qd = 0x00000000_FFFFFFFF_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 exact and inexact values", .{ .hw1 = 0xFFBB, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x3E800000_47F12060_80000000_3F800000 }, .{ .qd = 0x00000000_0001E240_00000000_00000001, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvta.s16.f16 halves and the extremes", .{ .hw1 = 0xFFB7, .hw2 = 0x0042, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100 }, .{ .qd = 0x80007FFF_FFFF0001_FFFE0004_FFFD0003, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtn.s16.f16 halves and the extremes", .{ .hw1 = 0xFFB7, .hw2 = 0x0142, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100 }, .{ .qd = 0x80007FFF_00000000_FFFE0004_FFFE0002, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtp.s16.f16 halves and the extremes", .{ .hw1 = 0xFFB7, .hw2 = 0x0242, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100 }, .{ .qd = 0x80007FFF_00000001_FFFF0004_FFFE0003, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtm.s16.f16 halves and the extremes", .{ .hw1 = 0xFFB7, .hw2 = 0x0342, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100 }, .{ .qd = 0x80007FFF_FFFF0000_FFFE0003_FFFD0002, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 toward zero, halves and the extremes", .{ .hw1 = 0xFFB7, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100 }, .{ .qd = 0x80007FFF_00000000_FFFF0003_FFFE0002, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u16.f16 toward zero, halves and the extremes", .{ .hw1 = 0xFFB7, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100 }, .{ .qd = 0x0000FFE0_00000000_00000003_00000002, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvta.u16.f16 halves and the extremes", .{ .hw1 = 0xFFB7, .hw2 = 0x00C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFBFF7BFF_B8003800_BE004300_C1004100 }, .{ .qd = 0x0000FFE0_00000001_00000004_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 nans, infinities, a subnormal, 16-bit saturation", .{ .hw1 = 0xFFB7, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00 }, .{ .qd = 0x80007FFF_00010000_80007FFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u16.f16 nans, infinities, a subnormal, 16-bit saturation", .{ .hw1 = 0xFFB7, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00 }, .{ .qd = 0x00009C40_00010000_0000FFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvtp.s16.f16 with fz16 flushes the subnormal without idc", .{ .hw1 = 0xFFB7, .hw2 = 0x0242, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00, .fpscr = 0x000C0000 }, .{ .qd = 0x80007FFF_00020000_80007FFF_00000000, .fpscr = 0x000C0011, .vpr = 0x00000000 }),
};

const from_int = [_]V{
    vec("vcvt.f32.s32 ordinary and rounded integers", .{ .hw1 = 0xFFBB, .hw2 = 0x0642, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_01000001_FFFFFFFF_00000001 }, .{ .qd = 0x4F000000_4B800000_BF800000_3F800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.s32 the top bit and ties to even", .{ .hw1 = 0xFFBB, .hw2 = 0x0642, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000000_00000003_01000003_80000000 }, .{ .qd = 0x00000000_40400000_4B800002_CF000000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.s16 ordinary and rounded integers", .{ .hw1 = 0xFFB7, .hw2 = 0x0642, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000003_10018000_7FFF0801_FFFF0001 }, .{ .qd = 0x00004200_6C00F800_78006800_BC003C00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.s16 the overflow edge", .{ .hw1 = 0xFFB7, .hw2 = 0x0642, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x04000803_03E8FFFE_8001FFF1_FFEFFFFF }, .{ .qd = 0x64006802_63D0C000_F800CB80_CC40BC00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 ordinary and rounded integers", .{ .hw1 = 0xFFBB, .hw2 = 0x06C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_01000001_FFFFFFFF_00000001 }, .{ .qd = 0x4F000000_4B800000_4F800000_3F800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 the top bit and ties to even", .{ .hw1 = 0xFFBB, .hw2 = 0x06C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000000_00000003_01000003_80000000 }, .{ .qd = 0x00000000_40400000_4B800002_4F000000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.u16 ordinary and rounded integers", .{ .hw1 = 0xFFB7, .hw2 = 0x06C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000003_10018000_7FFF0801_FFFF0001 }, .{ .qd = 0x00004200_6C007800_78006800_7C003C00, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcvt.f16.u16 the overflow edge", .{ .hw1 = 0xFFB7, .hw2 = 0x06C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x04000803_03E8FFFE_8001FFF1_FFEFFFFF }, .{ .qd = 0x64006802_63D07C00_78007C00_7BFF7C00, .fpscr = 0x00040014, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps lanes 1 and 3", .{ .hw1 = 0xFFBB, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x80000123_7F800000_FF800001_7FC00000, .vpr = 0x00880F0F }, .{ .qd = 0x11112222_7FFFFFFF_55556666_00000000, .fpscr = 0x00040001, .vpr = 0x00000F0F }),
    vec("a lane with byte 0 off is written but its flags drop", .{ .hw1 = 0xFFBB, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x80000123_7F800000_FF800001_7FC00000, .vpr = 0x0088EEEE }, .{ .qd = 0x00000022_FFFFFF44_00000066_00000088, .fpscr = 0x00040000, .vpr = 0x0000EEEE }),
    vec("f16 lanes count flags from their low byte", .{ .hw1 = 0xFFB7, .hw2 = 0x0742, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00, .vpr = 0x0088AAAA }, .{ .qd = 0x80117F22_00330044_80557F66_00770088, .fpscr = 0x00040000, .vpr = 0x0000AAAA }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xFFB7, .hw2 = 0x07C2, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xF8E278E2_3E000001_FC007C00_7C017E00, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x11112222_33334444_5555FFFF_00000000, .fpscr = 0x00010001, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xFFBB, .hw2 = 0x0142, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4F800000_CF000001_4F000000_BF19999A, .it = 0x20 }, .{ .qd = 0x7FFFFFFF_80000000_55556666_77778888, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xFFBB, .hw2 = 0x0642, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_01000001_FFFFFFFF_00000001, .fpscr = 0x03C40001 }, .{ .qd = 0x4F000000_4B800000_BF800000_3F800000, .fpscr = 0x03C40011, .vpr = 0x00000000 }),
    vec("qd equal to qm converts in place", .{ .hw1 = 0xFFBB, .hw2 = 0x8348, .qm = 0xBFC00000_40600000_C0200000_40200000 }, .{ .qd = 0xFFFFFFFE_00000003_FFFFFFFD_00000002, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("q7 from q6", .{ .hw1 = 0xFFB7, .hw2 = 0xE6CC, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x04000803_03E8FFFE_8001FFF1_FFEFFFFF }, .{ .qd = 0x64006802_63D07C00_78007C00_7BFF7C00, .fpscr = 0x00040014, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("size 00 is unclaimed", .{ .hw1 = 0xFFB3, .hw2 = 0x0740 }, none),
    vec("size 11 is unclaimed", .{ .hw1 = 0xFFBF, .hw2 = 0x0740 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFFFB, .hw2 = 0x0740 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0760 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0741 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0750 }, none),
    vec("hw2 bit 6 clear is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0700 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x1740 }, none),
    vec("hw2[11:9] = 111 matches neither layout", .{ .hw1 = 0xFFBB, .hw2 = 0x0E40 }, none),
    vec("hw2[11:9] = 010 matches neither layout", .{ .hw1 = 0xFFBB, .hw2 = 0x0440 }, none),
    vec("hw1[1:0] other than 11 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0740 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0740, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
