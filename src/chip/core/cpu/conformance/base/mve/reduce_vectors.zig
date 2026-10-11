//! Conformance vectors for the decode group `mve_reduce` (RA8EMU-632):
//! VADDV{A}, VADDLV{A}, VMLADAV{A}{X}, VMLSDAV{A}{X}, VMLALDAV{A}{X} and
//! VMLSLDAV{A}{X}. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: every active element e of Qm (sign-extended unless .U) adds
//! in, times Qn[e] (or Qn[e^1] for X) for the multiply forms, with odd-e
//! products subtracted for VMLSDAV; the A forms start from Rda (or the
//! RdaHi:RdaLo pair), the others from zero, and the exact sum wraps to the
//! destination. Active means the VPT element mask, the loop tail and the
//! beats EPSR.ECI leaves; the block then advances. Qm is Q1, Qn is Q2.
const vector = @import("../../vector.zig");

/// Words FE02FF7F, FFFF0001, 80000000, 7FFFFFFF.
pub const qm_value: u128 = 0x7FFFFFFF_80000000_FFFF0001_FE02FF7F;
/// Words 05FF0204, 00020003, FFFFFFFE, 00000003.
pub const qn_value: u128 = 0x00000003_FFFFFFFE_00020003_05FF0204;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qm: u128 = qm_value,
    qn: u128 = qn_value,
    rda: u32 = 0,
    rda_hi: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    rda: u32,
    rda_hi: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_reduce";
pub const none: Out = .{ .claimed = false, .rda = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = addv ++ dual ++ long ++ predicated ++ unclaimed;

const addv = [_]V{
    vec("vaddv.s8 r0, q1", .{ .hw1 = 0xEEF1, .hw2 = 0x0F02 }, .{ .rda = 0x79 }),
    vec("vaddv.u8 r0, q1", .{ .hw1 = 0xFEF1, .hw2 = 0x0F02 }, .{ .rda = 0x879 }),
    vec("vaddv.s16 r0, q1", .{ .hw1 = 0xEEF5, .hw2 = 0x0F02 }, .{ .rda = 0xFFFF_FD7F }),
    vec("vaddv.u32 r0, q1", .{ .hw1 = 0xFEF9, .hw2 = 0x0F02 }, .{ .rda = 0xFE01_FF7F }),
    vec("vaddva.u32 r0, q1 adds rda", .{ .hw1 = 0xFEF9, .hw2 = 0x0F22, .rda = 0x10 }, .{ .rda = 0xFE01_FF8F }),
    vec("vaddv.s32 lr, q1", .{ .hw1 = 0xEEF9, .hw2 = 0xEF02 }, .{ .rda = 0xFE01_FF7F }),
    vec("vaddv.s8 ignores rda", .{ .hw1 = 0xEEF1, .hw2 = 0x0F02, .rda = 0x1234 }, .{ .rda = 0x79 }),
    vec("vaddlv.s32 r0, r1, q1", .{ .hw1 = 0xEE89, .hw2 = 0x0F02 }, .{ .rda = 0xFE01_FF7F, .rda_hi = 0xFFFF_FFFF }),
    vec("vaddlva.u32 r0, r1, q1 carries", .{ .hw1 = 0xFE89, .hw2 = 0x0F22, .rda = 1, .rda_hi = 0xFFFF_FFFF }, .{ .rda = 0xFE01_FF80, .rda_hi = 1 }),
    vec("vaddlv.s32 r12, r11, q1", .{ .hw1 = 0xEED9, .hw2 = 0xCF02 }, .{ .rda = 0xFE01_FF7F, .rda_hi = 0xFFFF_FFFF }),
};

const dual = [_]V{
    vec("vmladav.s8 r0, q2, q1", .{ .hw1 = 0xEEF4, .hw2 = 0x0F02 }, .{ .rda = 0x26C }),
    vec("vmladav.u8 r0, q2, q1", .{ .hw1 = 0xFEF4, .hw2 = 0x0F02 }, .{ .rda = 0x8F6C }),
    vec("vmladav.s16 r0, q2, q1", .{ .hw1 = 0xEEF4, .hw2 = 0x0E02 }, .{ .rda = 0xFFF3_89F8 }),
    vec("vmladav.s32 r0, q2, q1", .{ .hw1 = 0xEEF5, .hw2 = 0x0E02 }, .{ .rda = 0x788A_FBFC }),
    vec("vmladav.u16 r0, q2, q1", .{ .hw1 = 0xFEF4, .hw2 = 0x0E02 }, .{ .rda = 0x87FA_89F8 }),
    vec("vmladava.s32 r0, q2, q1 adds rda", .{ .hw1 = 0xEEF5, .hw2 = 0x0E22, .rda = 5 }, .{ .rda = 0x788A_FC01 }),
    vec("vmladavx.s16 exchanges qn pairs", .{ .hw1 = 0xEEF4, .hw2 = 0x1E02 }, .{ .rda = 0xFFFB_7685 }),
    vec("vmlsdav.s16 subtracts odd lanes", .{ .hw1 = 0xEEF4, .hw2 = 0x0E03 }, .{ .rda = 0x000A_6E00 }),
    vec("vmlsdava.s8 r0, q2, q1", .{ .hw1 = 0xFEF4, .hw2 = 0x0E23, .rda = 1 }, .{ .rda = 0x185 }),
    vec("vmlsdavx.s32 r0, q2, q1", .{ .hw1 = 0xEEF5, .hw2 = 0x1E03 }, .{ .rda = 0x750B_FC77 }),
};

const long = [_]V{
    vec("vmlaldav.s16 r0, r1, q2, q1", .{ .hw1 = 0xEE84, .hw2 = 0x0E02 }, .{ .rda = 0xFFF3_89F8, .rda_hi = 0xFFFF_FFFF }),
    vec("vmlaldav.u32 r0, r1, q2, q1", .{ .hw1 = 0xFE85, .hw2 = 0x0E02 }, .{ .rda = 0x788A_FBFC, .rda_hi = 0x85F5_15FB }),
    vec("vmlaldava.s32 adds the pair", .{ .hw1 = 0xEE85, .hw2 = 0x0E22, .rda_hi = 0x100 }, .{ .rda = 0x788A_FBFC, .rda_hi = 0xFFF4_14F6 }),
    vec("vmlaldav.s32 ignores the pair", .{ .hw1 = 0xEE85, .hw2 = 0x0E02, .rda_hi = 0x55 }, .{ .rda = 0x788A_FBFC, .rda_hi = 0xFFF4_13F6 }),
    vec("vmlsldavx.s16 r0, r1, q2, q1", .{ .hw1 = 0xEE84, .hw2 = 0x1E03 }, .{ .rda = 0xFFFE_7E81, .rda_hi = 0xFFFF_FFFF }),
};

const predicated = [_]V{
    vec("vpt p0 0x000f adds word 0 only", .{ .hw1 = 0xEEF9, .hw2 = 0x0F02, .vpr = 0x0088_000F }, .{ .rda = 0xFE02_FF7F, .vpr = 0x0000_000F }),
    vec("vpt p0 0x000f multiplies word 0 only", .{ .hw1 = 0xEEF5, .hw2 = 0x0E02, .vpr = 0x0088_000F }, .{ .rda = 0xF88B_FBFC, .vpr = 0x0000_000F }),
    vec("the loop tail adds word 0 only", .{ .hw1 = 0xFEF9, .hw2 = 0x0F02, .ltpsize = 2, .lr = 1 }, .{ .rda = 0xFE02_FF7F }),
    vec("eci a0a1 adds beats 2 and 3", .{ .hw1 = 0xFEF9, .hw2 = 0x0F22, .rda = 7, .it = 0x20 }, .{ .rda = 6 }),
};

const unclaimed = [_]V{
    vec("vaddv size 11 is unclaimed", .{ .hw1 = 0xEEFD, .hw2 = 0x0F02 }, none),
    vec("vaddv with x is unclaimed", .{ .hw1 = 0xEEF1, .hw2 = 0x1F02 }, none),
    vec("vaddv with hw2[0] is unclaimed", .{ .hw1 = 0xEEF1, .hw2 = 0x0F03 }, none),
    vec("hw1 low 0b0011 with b8 is unclaimed", .{ .hw1 = 0xEEF3, .hw2 = 0x0F02 }, none),
    vec("8-bit vmladav with sub is unclaimed", .{ .hw1 = 0xEEF4, .hw2 = 0x0F03 }, none),
    vec("u with x is unclaimed", .{ .hw1 = 0xFEF4, .hw2 = 0x1E02 }, none),
    vec("u with a 32-bit sub is unclaimed", .{ .hw1 = 0xFEF5, .hw2 = 0x0E03 }, none),
    vec("rdahi = sp is unclaimed", .{ .hw1 = 0xEEE4, .hw2 = 0x0E02 }, none),
    vec("the vrmlaldavh space is unclaimed", .{ .hw1 = 0xEE88, .hw2 = 0x0F02 }, none),
    vec("u with a long sub is unclaimed", .{ .hw1 = 0xFE84, .hw2 = 0x0E03 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEEF4, .hw2 = 0x0E12 }, none),
    vec("hw2[6] set is unclaimed", .{ .hw1 = 0xEEF4, .hw2 = 0x0E42 }, none),
    vec("hw2[9] clear is unclaimed", .{ .hw1 = 0xEEF4, .hw2 = 0x0C02 }, none),
    vec("hw1[7] clear is unclaimed", .{ .hw1 = 0xEE74, .hw2 = 0x0E02 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEF4, .hw2 = 0x0E02, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
