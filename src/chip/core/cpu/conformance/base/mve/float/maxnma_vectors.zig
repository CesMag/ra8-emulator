//! Conformance vectors for the decode group `mve_float_maxnma` (RA8EMU-278):
//! VMAXNMA and VMINNMA on F32 and F16 lanes, Qd = maxnum(|Qd|, |Qm|) or
//! minnum. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: both operands lose their sign bit, then FPMaxNum or
//! FPMinNum runs under StandardFPSCRValue, so DN and FZ are set whatever
//! FPSCR holds (an F32 denormal reads as zero and raises IDC; FZ16 is left
//! clear here, so F16 denormals stay). A lone quiet NaN loses to the
//! number, two quiet NaNs or any signalling NaN give the default NaN, and
//! a signalling NaN raises IOC. A lane is computed when any of its bytes is
//! in the mask (VPT, loop tail, EPSR.ECI), its flags count only when its
//! first byte is, and the result merges byte by byte. Qd then Qm is
//! written. D or M set, VCVTB's neighbouring space, flipped fixed bits and
//! the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

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
const group = "mve_float_maxnma";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vmaxnma.f32 negatives and a lone nan", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .qd = 0xC0200000_7FC00001_80000000_BF800000, .qm = 0xFFC00001_BF800000_00000000_40200000 }, .{ .qd = 0x40200000_3F800000_00000000_40200000, .fpscr = 0x00040000 }),
    vec("vminnma.f32 negatives and a lone nan", .{ .hw1 = 0xEE3F, .hw2 = 0x1E85, .qd = 0xC0200000_7FC00001_80000000_BF800000, .qm = 0xFFC00001_BF800000_00000000_40200000 }, .{ .qd = 0x40200000_3F800000_00000000_3F800000, .fpscr = 0x00040000 }),
    vec("vmaxnma.f32 snan, infinities and denormals", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .qd = 0x80400000_00000001_FF800000_7F800001, .qm = 0x80000000_BF800000_7F800000_BF800000 }, .{ .qd = 0x00000000_3F800000_7F800000_7FC00000, .fpscr = 0x00040081 }),
    vec("vminnma.f32 snan, infinities and denormals", .{ .hw1 = 0xEE3F, .hw2 = 0x1E85, .qd = 0x80400000_00000001_FF800000_7F800001, .qm = 0x80000000_BF800000_7F800000_BF800000 }, .{ .qd = 0x00000000_00000000_7F800000_7FC00000, .fpscr = 0x00040081 }),
    vec("vmaxnma.f32 extremes by magnitude", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .qd = 0x40000000_C0000000_80800000_FF7FFFFF, .qm = 0xC0000001_3FFFFFFF_00000001_7F7FFFFF }, .{ .qd = 0x40000001_40000000_00800000_7F7FFFFF, .fpscr = 0x00040080 }),
    vec("vminnma.f32 extremes by magnitude", .{ .hw1 = 0xEE3F, .hw2 = 0x1E85, .qd = 0x40000000_C0000000_80800000_FF7FFFFF, .qm = 0xC0000001_3FFFFFFF_00000001_7F7FFFFF }, .{ .qd = 0x40000000_3FFFFFFF_00000000_7F7FFFFF, .fpscr = 0x00040080 }),
    vec("vmaxnma.f16 negatives and a lone nan", .{ .hw1 = 0xFE3F, .hw2 = 0x0E85, .qd = 0xBC007BFF_8001FC00_C1007E01_8000BC00, .qm = 0x3C00FBFF_00027C00_7E01BC00_00004100 }, .{ .qd = 0x3C007BFF_00027C00_41003C00_00004100, .fpscr = 0x00040000 }),
    vec("vminnma.f16 negatives and a lone nan", .{ .hw1 = 0xFE3F, .hw2 = 0x1E85, .qd = 0xBC007BFF_8001FC00_C1007E01_8000BC00, .qm = 0x3C00FBFF_00027C00_7E01BC00_00004100 }, .{ .qd = 0x3C007BFF_00017C00_41003C00_00003C00, .fpscr = 0x00040000 }),
    vec("vmaxnma.f16 snan, quiet nans and denormals kept", .{ .hw1 = 0xFE3F, .hw2 = 0x0E85, .qd = 0xFC00BC00_80000200_C000B555_FE017C01, .qm = 0x7C003C00_00008100_40013556_7E013C00 }, .{ .qd = 0x7C003C00_00000200_40013556_7E007E00, .fpscr = 0x00040001 }),
    vec("vminnma.f16 snan, quiet nans and denormals kept", .{ .hw1 = 0xFE3F, .hw2 = 0x1E85, .qd = 0xFC00BC00_80000200_C000B555_FE017C01, .qm = 0x7C003C00_00008100_40013556_7E013C00 }, .{ .qd = 0x7C003C00_00000100_40003555_7E007E00, .fpscr = 0x00040001 }),
    vec("vmaxnma.f32 q7, q5", .{ .hw1 = 0xEE3F, .hw2 = 0xEE8B, .qd = 0xC0200000_7FC00001_80000000_BF800000, .qm = 0xFFC00001_BF800000_00000000_40200000 }, .{ .qd = 0x40200000_3F800000_00000000_40200000, .fpscr = 0x00040000 }),
    vec("vminnma.f16 qd = qm takes its own magnitude", .{ .hw1 = 0xFE3F, .hw2 = 0x7E87, .qd = 0xBC007BFF_8001FC00_C1007E01_8000BC00 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000 }),
    vec("fpscr fz and dn clear still flush and give the default nan", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .qd = 0x80400000_00000001_FF800000_7F800001, .qm = 0x80000000_BF800000_7F800000_BF800000 }, .{ .qd = 0x00000000_3F800000_7F800000_7FC00000, .fpscr = 0x00040081 }),
    vec("flags add to the cumulative bits already set", .{ .hw1 = 0xEE3F, .hw2 = 0x1E85, .qd = 0x80400000_00000001_FF800000_7F800001, .qm = 0x80000000_BF800000_7F800000_BF800000, .fpscr = 0x00040010 }, .{ .qd = 0x00000000_00000000_7F800000_7FC00000, .fpscr = 0x00040091 }),
};

const predicated = [_]V{
    vec("vpt p0 0x0f0e computes lane 0 but drops its flags", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .qd = 0x80400000_00000001_FF800000_7F800001, .qm = 0x80000000_BF800000_7F800000_BF800000, .vpr = 0x00880F0E }, .{ .qd = 0x80400000_3F800000_FF800000_7FC00001, .fpscr = 0x00040080, .vpr = 0x00000F0E }),
    vec("vpt p0 0x00f1 keeps lane 0 flags", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .qd = 0x80400000_00000001_FF800000_7F800001, .qm = 0x80000000_BF800000_7F800000_BF800000, .vpr = 0x008800F1 }, .{ .qd = 0x80400000_00000001_7F800000_7F800000, .fpscr = 0x00040001, .vpr = 0x000000F1 }),
    vec("the loop tail drops lanes 2 and 3", .{ .hw1 = 0xEE3F, .hw2 = 0x1E85, .qd = 0x7F800001_00000001_40000000_BF800000, .qm = 0x80000000_BF800000_7F800000_BF800000, .lr = 2, .fpscr = 0x00020000 }, .{ .qd = 0x7F800001_00000001_40000000_3F800000, .fpscr = 0x00020000 }),
    vec("the f16 loop tail at ltpsize 1", .{ .hw1 = 0xFE3F, .hw2 = 0x0E85, .qd = 0xFC00BC00_80000200_C000B555_FE017C01, .qm = 0x7C003C00_00008100_40013556_7E013C00, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0xFC00BC00_80000200_C0003556_7E007E00, .fpscr = 0x00010001 }),
    vec("eci a0a1 keeps the done lanes and their flags", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .qd = 0x80400000_00000001_FF800000_7F800001, .qm = 0x80000000_BF800000_7F800000_BF800000, .it = 0x20 }, .{ .qd = 0x00000000_3F800000_FF800000_7F800001, .fpscr = 0x00040080 }),
};

const unclaimed = [_]V{
    vec("d set is unclaimed", .{ .hw1 = 0xEE7F, .hw2 = 0x0E85 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0EA5 }, none),
    vec("hw2 bit 7 clear is vcvtb, not this group", .{ .hw1 = 0xEE3F, .hw2 = 0x0E05 }, none),
    vec("hw2[0] clear is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E84 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E95 }, none),
    vec("hw2[11:8] other than 1110 is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0F85 }, none),
    vec("hw1[3:0] other than 1111 is unclaimed", .{ .hw1 = 0xEE3E, .hw2 = 0x0E85 }, none),
    vec("hw1[5:4] other than 11 is unclaimed", .{ .hw1 = 0xEE2F, .hw2 = 0x0E85 }, none),
    vec("hw1[15:13] other than 111 is unclaimed", .{ .hw1 = 0xCE3F, .hw2 = 0x0E85 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E85, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
