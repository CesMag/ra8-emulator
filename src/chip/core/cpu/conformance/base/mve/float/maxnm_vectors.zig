//! Conformance vectors for the decode group `mve.float.maxnm` (RA8EMU-278):
//! VMAXNM and VMINNM on F32 and F16 lanes. Expected values are worked from
//! the Arm ARM (DDI0553) pseudocode: FPMaxNum and FPMinNum under
//! StandardFPSCRValue, so DN and FZ are set whatever FPSCR holds (an F32
//! denormal reads as zero and raises IDC; FZ16 is left clear here, so F16
//! denormals stay). A lone quiet NaN loses to the number, two quiet NaNs or
//! any signalling NaN give the default NaN, and a signalling NaN raises IOC.
//! -0 is below +0. A lane is computed when any of its bytes is in the mask
//! (VPT, loop tail, EPSR.ECI), its flags count only when its first byte is,
//! and the result merges byte by byte. Qd, Qn and Qm are written in that
//! order. D, N or M set, flipped fixed bits and the 16-bit space are left
//! unclaimed.
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
const group = "mve_float_maxnm";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vmaxnm.f32 mixed", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0x40200000_7FC00001_80000000_3F800000, .qm = 0x7FC00001_BF800000_00000000_40200000 }, .{ .qd = 0x40200000_BF800000_00000000_40200000, .fpscr = 0x00040000 }),
    vec("vminnm.f32 mixed", .{ .hw1 = 0xFF22, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0x40200000_7FC00001_80000000_3F800000, .qm = 0x7FC00001_BF800000_00000000_40200000 }, .{ .qd = 0x40200000_BF800000_80000000_3F800000, .fpscr = 0x00040000 }),
    vec("vmaxnm.f32 snan, infinities and denormals", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000 }, .{ .qd = 0x80000000_00000000_7F800000_7FC00000, .fpscr = 0x00040081 }),
    vec("vminnm.f32 snan, infinities and denormals", .{ .hw1 = 0xFF22, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000 }, .{ .qd = 0x80000000_BF800000_FF800000_7FC00000, .fpscr = 0x00040081 }),
    vec("vmaxnm.f32 quiet nans, extremes and a flushed denormal", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0xFF800000_00800000_7F7FFFFF_7FC00001, .qm = 0x3F800000_00000001_FF7FFFFF_7FC00001 }, .{ .qd = 0x3F800000_00800000_7F7FFFFF_7FC00000, .fpscr = 0x00040080 }),
    vec("vminnm.f32 quiet nans, extremes and a flushed denormal", .{ .hw1 = 0xFF22, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0xFF800000_00800000_7F7FFFFF_7FC00001, .qm = 0x3F800000_00000001_FF7FFFFF_7FC00001 }, .{ .qd = 0xFF800000_00000000_FF7FFFFF_7FC00000, .fpscr = 0x00040080 }),
    vec("vmaxnm.f16 mixed", .{ .hw1 = 0xFF12, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0xBC007BFF_0001FC00_41007E01_80003C00, .qm = 0x0000FBFF_80017C00_7E01BC00_00004100 }, .{ .qd = 0x00007BFF_00017C00_4100BC00_00004100, .fpscr = 0x00040000 }),
    vec("vminnm.f16 mixed", .{ .hw1 = 0xFF32, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0xBC007BFF_0001FC00_41007E01_80003C00, .qm = 0x0000FBFF_80017C00_7E01BC00_00004100 }, .{ .qd = 0xBC00FBFF_8001FC00_4100BC00_80003C00, .fpscr = 0x00040000 }),
    vec("vmaxnm.f16 snan, quiet nans and denormals kept", .{ .hw1 = 0xFF12, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0x7C003C00_80000200_C0003555_7E017C01, .qm = 0x7C003C00_80000100_C0013556_7E013C00 }, .{ .qd = 0x7C003C00_80000200_C0003556_7E007E00, .fpscr = 0x00040001 }),
    vec("vminnm.f16 snan, quiet nans and denormals kept", .{ .hw1 = 0xFF32, .hw2 = 0x0F54, .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A, .qn = 0x7C003C00_80000200_C0003555_7E017C01, .qm = 0x7C003C00_80000100_C0013556_7E013C00 }, .{ .qd = 0x7C003C00_80000100_C0013555_7E007E00, .fpscr = 0x00040001 }),
    vec("vmaxnm.f32 q7, q6, q5", .{ .hw1 = 0xFF0C, .hw2 = 0xEF5A, .qn = 0x40200000_7FC00001_80000000_3F800000, .qm = 0x7FC00001_BF800000_00000000_40200000 }, .{ .qd = 0x40200000_BF800000_00000000_40200000, .fpscr = 0x00040000 }),
    vec("vminnm.f32 qd = qn", .{ .hw1 = 0xFF26, .hw2 = 0x6F58, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000 }, .{ .qd = 0x80000000_BF800000_FF800000_7FC00000, .fpscr = 0x00040081 }),
    vec("fpscr fz and dn clear still flush and give the default nan", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000, .fpscr = 0x00040000 }, .{ .qd = 0x80000000_00000000_7F800000_7FC00000, .fpscr = 0x00040081 }),
    vec("flags add to the cumulative bits already set", .{ .hw1 = 0xFF22, .hw2 = 0x0F54, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000, .fpscr = 0x00040010 }, .{ .qd = 0x80000000_BF800000_FF800000_7FC00000, .fpscr = 0x00040091 }),
};

const predicated = [_]V{
    vec("vpt p0 0x0f0e computes lane 0 but drops its flags", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .qd = 0x11111111_22222222_33333333_44444444, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000, .vpr = 0x00880F0E }, .{ .qd = 0x11111111_00000000_33333333_7FC00044, .fpscr = 0x00040080, .vpr = 0x00000F0E }),
    vec("vpt p0 0x00f1 keeps lane 0 flags", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .qd = 0x11111111_22222222_33333333_44444444, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000, .vpr = 0x008800F1 }, .{ .qd = 0x11111111_22222222_7F800000_44444400, .fpscr = 0x00040001, .vpr = 0x000000F1 }),
    vec("the loop tail drops lanes 2 and 3", .{ .hw1 = 0xFF22, .hw2 = 0x0F54, .qd = 0x11111111_22222222_33333333_44444444, .qn = 0x7F800001_00000001_40000000_3F800000, .qm = 0x80000000_BF800000_FF800000_3F800000, .lr = 2, .fpscr = 0x00020000 }, .{ .qd = 0x11111111_22222222_FF800000_3F800000, .fpscr = 0x00020000 }),
    vec("the f16 loop tail at ltpsize 1", .{ .hw1 = 0xFF12, .hw2 = 0x0F54, .qd = 0x11111111_22222222_33333333_44444444, .qn = 0x7C003C00_80000200_C0003555_7E017C01, .qm = 0x7C003C00_80000100_C0013556_7E013C00, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x11111111_22222222_33333556_7E007E00, .fpscr = 0x00010001 }),
    vec("eci a0a1 keeps the done lanes and their flags", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .qd = 0x11111111_22222222_33333333_44444444, .qn = 0x80400000_00000001_7F800000_7F800001, .qm = 0x80000000_BF800000_FF800000_3F800000, .it = 0x20 }, .{ .qd = 0x80000000_00000000_33333333_44444444, .fpscr = 0x00040080 }),
};

const unclaimed = [_]V{
    vec("d set is unclaimed", .{ .hw1 = 0xFF42, .hw2 = 0x0F54 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0FD4 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0F74 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0F55 }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x1F54 }, none),
    vec("hw2[4] clear is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0F44 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xFF03, .hw2 = 0x0F54 }, none),
    vec("hw1[12] clear is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0F54 }, none),
    vec("hw2[11:8] other than 1111 is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0E54 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFF02, .hw2 = 0x0F54, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
