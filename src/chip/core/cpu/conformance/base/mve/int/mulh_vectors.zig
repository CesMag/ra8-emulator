//! Conformance vectors for the decode group `mve_int_mulh` (RA8EMU-278):
//! VMULH and VRMULH (signed and unsigned) and VQDMULH and VQRDMULH, all
//! vector by vector. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: the high half of each element product, rounded by adding
//! 2^(esize-1) for the R forms, and for the doubling forms twice the
//! product saturated to signed esize, raising FPSCR.QC only when the
//! saturating element's first byte is active. Results merge byte by byte
//! under the VPT mask, the loop tail and EPSR.ECI. Qd, Qn and Qm are
//! written in that order before the instruction runs. Size 11, fixed bits
//! flipped, one form's tail under the other's hw1, VMLA by scalar and the
//! 16-bit space are left unclaimed.
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
    ltpsize: u3 = 4,
    lr: u32 = 0,
    qc: u1 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    qd: u128,
    vpr: u32 = 0,
    it: u8 = 0,
    qc: u1 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_int_mulh";
pub const none: Out = .{ .claimed = false, .qd = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = high ++ doubling ++ predicated ++ unclaimed;

const high = [_]V{
    vec("vmulh.s8", .{ .hw1 = 0xEE03, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF02807F }, .{ .qd = 0x00FF1D3F_012BD500_FE01F010_FFFF403F }),
    vec("vmulh.u8", .{ .hw1 = 0xFE03, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF02807F }, .{ .qd = 0xFC011D41_01552A00_0F013010_0001403F }),
    vec("vrmulh.s8", .{ .hw1 = 0xEE03, .hw2 = 0x1E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF02807F }, .{ .qd = 0x00001E3F_012BD600_FF01F010_0000403F }),
    vec("vrmulh.u8", .{ .hw1 = 0xFE03, .hw2 = 0x1E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF02807F }, .{ .qd = 0xFC021E41_01552B00_10013010_0102403F }),
    vec("vmulh.s16", .{ .hw1 = 0xEE13, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80007FFF }, .{ .qd = 0x091A0626_F0001000_FFFFFFFF_40003FFF }),
    vec("vmulh.u16", .{ .hw1 = 0xFE13, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80007FFF }, .{ .qd = 0x76E50626_30001000_00000001_40003FFF }),
    vec("vrmulh.s16", .{ .hw1 = 0xEE13, .hw2 = 0x1E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80007FFF }, .{ .qd = 0x091B0626_F0001000_00000000_40003FFF }),
    vec("vrmulh.u16", .{ .hw1 = 0xFE13, .hw2 = 0x1E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80007FFF }, .{ .qd = 0x76E60626_30001000_00010002_40003FFF }),
    vec("vmulh.s32", .{ .hw1 = 0xEE23, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF }, .{ .qd = 0xF76C768D_FFFFFFFF_40000000_3FFFFFFF }),
    vec("vmulh.u32", .{ .hw1 = 0xFE23, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF }, .{ .qd = 0x09A0CD05_00000001_40000000_3FFFFFFF }),
    vec("vrmulh.s32", .{ .hw1 = 0xEE23, .hw2 = 0x1E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF }, .{ .qd = 0xF76C768D_00000000_40000000_3FFFFFFF }),
    vec("vrmulh.u32", .{ .hw1 = 0xFE23, .hw2 = 0x1E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF }, .{ .qd = 0x09A0CD05_00000002_40000000_3FFFFFFF }),
    vec("vmulh.s32 q7, q6, q5", .{ .hw1 = 0xEE2D, .hw2 = 0xEE0B, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF }, .{ .qd = 0xF76C768D_FFFFFFFF_40000000_3FFFFFFF }),
    vec("qd = qn = qm squares", .{ .hw1 = 0xEE17, .hw2 = 0x7E07, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF }, .{ .qd = 0x00000000_00000000_00000000_00000000 }),
};

const doubling = [_]V{
    vec("vqdmulh.s8 saturates the minimum squared", .{ .hw1 = 0xEF02, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF02807F }, .{ .qd = 0x00FF3B7E_0256AB00_FD02E020_FFFF7F7E, .qc = 1 }),
    vec("vqrdmulh.s8 rounds", .{ .hw1 = 0xFF02, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF02807F }, .{ .qd = 0x00003C7E_0356AB00_FE02E020_00007F7E, .qc = 1 }),
    vec("vqdmulh.s16 saturates the minimum squared", .{ .hw1 = 0xEF12, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80007FFF }, .{ .qd = 0x12350C4C_E0002000_FFFFFFFF_7FFF7FFE, .qc = 1 }),
    vec("vqrdmulh.s16 rounds", .{ .hw1 = 0xFF12, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80007FFF }, .{ .qd = 0x12350C4C_E0002000_00000000_7FFF7FFE, .qc = 1 }),
    vec("vqdmulh.s32 saturates the minimum squared", .{ .hw1 = 0xEF22, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF }, .{ .qd = 0xEED8ED1A_FFFFFFFF_7FFFFFFF_7FFFFFFE, .qc = 1 }),
    vec("vqrdmulh.s32 rounds", .{ .hw1 = 0xFF22, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF }, .{ .qd = 0xEED8ED1B_00000000_7FFFFFFF_7FFFFFFE, .qc = 1 }),
    vec("vqdmulh without saturation leaves qc", .{ .hw1 = 0xEF12, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00080007_00060005_00040003_00020001, .qm = 0x40004000_40004000_40004000_40004000 }, .{ .qd = 0x00040003_00030002_00020001_00010000 }),
    vec("qc already set stays set", .{ .hw1 = 0xEF12, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00080007_00060005_00040003_00020001, .qm = 0x40004000_40004000_40004000_40004000, .qc = 1 }, .{ .qd = 0x00040003_00030002_00020001_00010000, .qc = 1 }),
};

const predicated = [_]V{
    vec("vpt p0 0x00ff merges the low half", .{ .hw1 = 0xEE23, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_7FFFFFFF, .vpr = 0x008800FF }, .{ .qd = 0xDEADBEEF_CAFEF00D_40000000_3FFFFFFF, .vpr = 0x000000FF }),
    vec("saturation only in an inactive lane leaves qc", .{ .hw1 = 0xEF22, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_00000002_00000001_80000000, .qm = 0x00000003_00000002_00000001_80000000, .vpr = 0x0088FF00 }, .{ .qd = 0x00000000_00000000_01234567_89ABCDEF, .vpr = 0x0000FF00 }),
    vec("saturation in an active lane sets qc", .{ .hw1 = 0xEF22, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_00000002_00000001_80000000, .qm = 0x00000003_00000002_00000001_80000000, .vpr = 0x0088000F }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_7FFFFFFF, .vpr = 0x0000000F, .qc = 1 }),
    vec("the loop tail writes the first lanes", .{ .hw1 = 0xFE13, .hw2 = 0x1E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80007FFF, .ltpsize = 1, .lr = 3 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01230002_40003FFF }),
    vec("the loop tail stops qc", .{ .hw1 = 0xEF22, .hw2 = 0x0B44, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_00000002_80000000_00000001, .qm = 0x00000003_00000002_80000000_00000001, .ltpsize = 2, .lr = 1 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_00000000 }),
    vec("eci a0a1a2 keeps three beats", .{ .hw1 = 0xEE03, .hw2 = 0x0E05, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF02807F, .it = 0x40 }, .{ .qd = 0x00FF1D3F_CAFEF00D_01234567_89ABCDEF }),
};

const unclaimed = [_]V{
    vec("vmulh size 11 is unclaimed", .{ .hw1 = 0xEE31, .hw2 = 0x0E05 }, none),
    vec("vqdmulh size 11 is unclaimed", .{ .hw1 = 0xEF32, .hw2 = 0x0B44 }, none),
    vec("vmulh with hw2[0] clear is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E04 }, none),
    vec("vqdmulh with hw2[0] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0B45 }, none),
    vec("vmulh with n set is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E85 }, none),
    vec("vmulh with m set is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E25 }, none),
    vec("vqdmulh with m clear is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0B04 }, none),
    vec("vmulh with d set is unclaimed", .{ .hw1 = 0xEE61, .hw2 = 0x0E05 }, none),
    vec("vmulh tail under the vqdmulh hw1", .{ .hw1 = 0xEF22, .hw2 = 0x0E05 }, none),
    vec("vmla by scalar is not vmulh", .{ .hw1 = 0xEE23, .hw2 = 0x0E42 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE21, .hw2 = 0x0E05, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
