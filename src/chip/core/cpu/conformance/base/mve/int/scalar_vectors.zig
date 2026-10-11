//! Conformance vectors for the decode group `mve_int_scalar` (RA8EMU-278):
//! the vector-by-scalar VADD, VSUB, VMUL, VBRSR, VQ{R}DMULH, VQADD, VQSUB,
//! VHADD and VHSUB. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode with Rm's low esize bits in every lane (VBRSR takes Rm[7:0]
//! as a bit count). Results merge byte by byte under the VPT mask, the loop
//! tail and EPSR.ECI; FPSCR.QC is set only by a saturating element whose
//! first byte is active. Qd and Qn are written in that order first. Size
//! 11, Rm of SP or PC, encodings from the other half, N, D or hw2[4] set,
//! VMLA's encoding and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qd: u128 = 0,
    qn: u128 = 0,
    rm: u32 = 0,
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
const group = "mve_int_scalar";
pub const none: Out = .{ .claimed = false, .qd = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = modulo ++ saturating ++ predicated ++ unclaimed;

const modulo = [_]V{
    vec("vadd.i8 wraps", .{ .hw1 = 0xEE03, .hw2 = 0x0F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x181 }, .{ .qd = 0x7F83BD02_FF2BD681_719141C1_82800100 }),
    vec("vadd.i32 q0, q1, r2", .{ .hw1 = 0xEE23, .hw2 = 0x0F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1 }, .{ .qd = 0x00000004_00000000_80000001_80000000 }),
    vec("vadd u set changes nothing", .{ .hw1 = 0xFE23, .hw2 = 0x0F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1 }, .{ .qd = 0x00000004_00000000_80000001_80000000 }),
    vec("vsub.i16 q0, q1, r2", .{ .hw1 = 0xEE13, .hw2 = 0x1F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x20002 }, .{ .qd = 0xEDC91232_BFFE3FFE_FFFFFFFD_7FFE7FFD }),
    vec("vmul.i32 wraps", .{ .hw1 = 0xEE23, .hw2 = 0x1E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x3 }, .{ .qd = 0x00000009_FFFFFFFD_80000000_7FFFFFFD }),
    vec("vmul.i8 by the low byte", .{ .hw1 = 0xEE03, .hw2 = 0x1E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0xFF03 }, .{ .qd = 0xFA06B483_7AFEFF00_D03040C0_03FD807D }),
    vec("vbrsr.8 keeps all 8 bits", .{ .hw1 = 0xFE03, .hw2 = 0x1E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x8 }, .{ .qd = 0x7F403C81_7E55AA00_0F080302_80FF01FE }),
    vec("vbrsr.16 keeps 5 bits", .{ .hw1 = 0xFE13, .hw2 = 0x1E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x5 }, .{ .qd = 0x001A0005_00000000_0010001F_0000001F }),
    vec("vbrsr.32 of zero bits is zero", .{ .hw1 = 0xFE23, .hw2 = 0x1E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x100 }, .{ .qd = 0x00000000_00000000_00000000_00000000 }),
    vec("vbrsr.32 past the width keeps all", .{ .hw1 = 0xFE23, .hw2 = 0x1E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x28 }, .{ .qd = 0xC0000000_FFFFFFFF_00000001_FFFFFFFE }),
    vec("vqdmulh.s16 0x8000 by 0x8000 saturates", .{ .hw1 = 0xEE13, .hw2 = 0x0E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x8000 }, .{ .qd = 0x1235EDCC_4000C000_FFFF0001_7FFF8001, .qc = 1 }),
    vec("vqdmulh.s32 by 2", .{ .hw1 = 0xEE23, .hw2 = 0x0E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x40000000 }, .{ .qd = 0x00000001_FFFFFFFF_C0000000_3FFFFFFF }),
    vec("vqrdmulh.s16 rounds", .{ .hw1 = 0xFE13, .hw2 = 0x0E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x3FFF }, .{ .qd = 0xF6E6091A_E0012000_00000000_C0013FFF }),
    vec("vqrdmulh.s8 by -128 saturates", .{ .hw1 = 0xFE03, .hw2 = 0x0E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x80 }, .{ .qd = 0x02FEC47F_8256AB00_10F040C0_FF017F81, .qc = 1 }),
};

const saturating = [_]V{
    vec("vqadd.s8 saturates both ways", .{ .hw1 = 0xEE02, .hw2 = 0x0F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x40 }, .{ .qd = 0x3E427CC1_7FEA7F40_3050007F_413FC07F, .qc = 1 }),
    vec("vqadd.u16 saturates at 0xffff", .{ .hw1 = 0xFE12, .hw2 = 0x0F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x8000 }, .{ .qd = 0xFFFF9234_FFFFC000_8001FFFF_FFFFFFFF, .qc = 1 }),
    vec("vqadd.u32 without saturation", .{ .hw1 = 0xFE22, .hw2 = 0x0F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000004_00000003_00000002_00000001, .rm = 0x5 }, .{ .qd = 0x00000009_00000008_00000007_00000006 }),
    vec("vqsub.s32 saturates", .{ .hw1 = 0xEE22, .hw2 = 0x1F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1 }, .{ .qd = 0x00000002_FFFFFFFE_80000000_7FFFFFFE, .qc = 1 }),
    vec("vqsub.u8 floors at zero", .{ .hw1 = 0xFE02, .hw2 = 0x1F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x10 }, .{ .qd = 0xEE002C71_6E9A4500_E000B030_00EF706F, .qc = 1 }),
    vec("vhadd.s8 halves toward minus infinity", .{ .hw1 = 0xEE02, .hw2 = 0x0F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0xFF }, .{ .qd = 0xFE001DC0_3ED42AFF_F707DF1F_00FFBF3F }),
    vec("vhadd.u32 keeps the carry", .{ .hw1 = 0xFE22, .hw2 = 0x0F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0xFFFFFFFF }, .{ .qd = 0x80000001_FFFFFFFF_BFFFFFFF_BFFFFFFF }),
    vec("vhsub.s16", .{ .hw1 = 0xEE12, .hw2 = 0x1F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x7FFF }, .{ .qd = 0xB6E6C91A_A000E000_C001C000_80000000 }),
    vec("vhsub.u8", .{ .hw1 = 0xFE02, .hw2 = 0x1F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x80 }, .{ .qd = 0x3FC1DE00_FF15EAC0_38C820E0_C03F00FF }),
    vec("vadd.i16 q7, q6, r12", .{ .hw1 = 0xEE1D, .hw2 = 0xEF4C, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x7 }, .{ .qd = 0xEDD2123B_C0074007_00080006_80078006 }),
    vec("qd = qn", .{ .hw1 = 0xEE23, .hw2 = 0x2F4E, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1 }, .{ .qd = 0x00000004_00000000_80000001_80000000 }),
};

const predicated = [_]V{
    vec("vpt p0 0x00ff keeps qd above", .{ .hw1 = 0xEE23, .hw2 = 0x0F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1, .vpr = 0x008800FF }, .{ .qd = 0xDEADBEEF_CAFEF00D_80000001_80000000, .vpr = 0x000000FF }),
    vec("saturation in an inactive lane leaves qc", .{ .hw1 = 0xEE22, .hw2 = 0x0F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1, .vpr = 0x0088FF00 }, .{ .qd = 0x00000004_00000000_01234567_89ABCDEF, .vpr = 0x0000FF00 }),
    vec("saturation in an active lane sets qc", .{ .hw1 = 0xEE22, .hw2 = 0x0F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1, .vpr = 0x008800FF }, .{ .qd = 0xDEADBEEF_CAFEF00D_80000001_7FFFFFFF, .vpr = 0x000000FF, .qc = 1 }),
    vec("qc already set stays set", .{ .hw1 = 0xFE22, .hw2 = 0x0F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000004_00000003_00000002_00000001, .rm = 0x5, .qc = 1 }, .{ .qd = 0x00000009_00000008_00000007_00000006, .qc = 1 }),
    vec("the loop tail stops vqadd qc", .{ .hw1 = 0xEE22, .hw2 = 0x0F62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000003_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1, .ltpsize = 2, .lr = 0 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF }),
    vec("the loop tail writes the first lanes", .{ .hw1 = 0xEE13, .hw2 = 0x0F42, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x1, .ltpsize = 1, .lr = 3 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01230000_80018000 }),
    vec("eci a0 skips beat 0", .{ .hw1 = 0xEE03, .hw2 = 0x1E62, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x3, .it = 0x10 }, .{ .qd = 0xFA06B483_7AFEFF00_D03040C0_89ABCDEF }),
};

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F42 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F4D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F4F }, none),
    vec("vmul tail in the saturating half", .{ .hw1 = 0xEE22, .hw2 = 0x1E62 }, none),
    vec("vqadd tail in the modulo half", .{ .hw1 = 0xEE23, .hw2 = 0x0F62 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0FC2 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F52 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEE63, .hw2 = 0x0F42 }, none),
    vec("vmla is not vadd", .{ .hw1 = 0xEE23, .hw2 = 0x0E42 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F42, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
