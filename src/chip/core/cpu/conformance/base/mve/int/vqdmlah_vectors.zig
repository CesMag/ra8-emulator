//! Conformance vectors for the decode group `mve.int.vqdmlah` (RA8EMU-278):
//! VQDMLAH, VQRDMLAH, VQDMLASH and VQRDMLASH (vector by scalar) at 8, 16
//! and 32 bits. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: per element SignedSatQ((2*Qn*Rm + (Qda << esize) + round)
//! >> esize) for the AH forms and SignedSatQ((2*Qn*Qda + (Rm << esize) +
//! round) >> esize) for the ASH forms, round being 2^(esize-1) for the R
//! forms and Rm its signed low esize bits. FPSCR.QC is raised only when the
//! saturating element's first byte is active. Results merge byte by byte
//! under the VPT mask, the loop tail and EPSR.ECI. Qda and Qn are written
//! in that order. Size 11, Rm of SP or PC, U, D or N set, an unused form,
//! VMLA's encoding and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qda: u128 = 0,
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
    qda: u128,
    vpr: u32 = 0,
    it: u8 = 0,
    qc: u1 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_int_vqdmlah";
pub const none: Out = .{ .claimed = false, .qda = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vqdmlah.s8", .{ .hw1 = 0xEE02, .hw2 = 0x0E62, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x80 }, .{ .qda = 0x00FD4300_85D68033_21007F00_FE030082, .qc = 1 }),
    vec("vqdmlah.s8 by a small scalar", .{ .hw1 = 0xEE02, .hw2 = 0x0E62, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0xFFFFFF03 }, .{ .qda = 0xFDFF7F80_05808133_10103E41_FF018003, .qc = 1 }),
    vec("vqdmlah.s16", .{ .hw1 = 0xEE12, .hw2 = 0x0E62, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x4000 }, .{ .qda = 0x80005F92_20006000_FFFF0001_80004000, .qc = 1 }),
    vec("vqdmlah.s16 by a small scalar", .{ .hw1 = 0xEE12, .hw2 = 0x0E62, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0xFFFFFF03 }, .{ .qda = 0x80235654_407E3F81_FFFE0002_80FDFF04 }),
    vec("vqdmlah.s32", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x80000000 }, .{ .qda = 0x80000000_00000003_00000000_80000002, .qc = 1 }),
    vec("vqdmlah.s32 by a small scalar", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x3 }, .{ .qda = 0x87654321_00000001_80000000_00000003, .qc = 1 }),
    vec("vqrdmlah.s8", .{ .hw1 = 0xEE02, .hw2 = 0x0E42, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x80 }, .{ .qda = 0x00FD4300_85D68033_21007F00_FE030082, .qc = 1 }),
    vec("vqrdmlah.s8 by a small scalar", .{ .hw1 = 0xEE02, .hw2 = 0x0E42, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0xFFFFFF03 }, .{ .qda = 0xFEFF7F80_06808233_11103F42_FF028004, .qc = 1 }),
    vec("vqrdmlah.s16", .{ .hw1 = 0xEE12, .hw2 = 0x0E42, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x4000 }, .{ .qda = 0x80005F92_20006000_00000002_80004001, .qc = 1 }),
    vec("vqrdmlah.s16 by a small scalar", .{ .hw1 = 0xEE12, .hw2 = 0x0E42, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0xFFFFFF03 }, .{ .qda = 0x80245654_407F3F82_FFFF0002_80FDFF04 }),
    vec("vqrdmlah.s32", .{ .hw1 = 0xEE22, .hw2 = 0x0E42, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x80000000 }, .{ .qda = 0x80000000_00000003_00000000_80000002, .qc = 1 }),
    vec("vqrdmlah.s32 by a small scalar", .{ .hw1 = 0xEE22, .hw2 = 0x0E42, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x3 }, .{ .qda = 0x87654321_00000002_80000000_00000004, .qc = 1 }),
    vec("vqdmlash.s8", .{ .hw1 = 0xEE02, .hw2 = 0x1E62, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x80 }, .{ .qda = 0x8080BBFE_82D68080_808280A0_80800080, .qc = 1 }),
    vec("vqdmlash.s8 by a small scalar", .{ .hw1 = 0xEE02, .hw2 = 0x1E62, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0xFFFFFF03 }, .{ .qda = 0x03023E7F_0559AE03_0005E323_02027F03, .qc = 1 }),
    vec("vqdmlash.s16", .{ .hw1 = 0xEE12, .hw2 = 0x1E62, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x4000 }, .{ .qda = 0x52354C4C_20006000_3FFF3FFF_7FFF4000, .qc = 1 }),
    vec("vqdmlash.s16 by a small scalar", .{ .hw1 = 0xEE12, .hw2 = 0x1E62, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0xFFFFFF03 }, .{ .qda = 0x11380B4F_DF031F03_FF02FF02_7F03FF03 }),
    vec("vqdmlash.s32", .{ .hw1 = 0xEE22, .hw2 = 0x1E62, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x80000000 }, .{ .qda = 0x80000000_80000000_00000000_80000000, .qc = 1 }),
    vec("vqdmlash.s32 by a small scalar", .{ .hw1 = 0xEE22, .hw2 = 0x1E62, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x3 }, .{ .qda = 0xEED8ED1D_00000002_7FFFFFFF_00000003, .qc = 1 }),
    vec("vqrdmlash.s8", .{ .hw1 = 0xEE02, .hw2 = 0x1E42, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x80 }, .{ .qda = 0x8080BCFE_83D68080_808280A0_80800081, .qc = 1 }),
    vec("vqrdmlash.s8 by a small scalar", .{ .hw1 = 0xEE02, .hw2 = 0x1E42, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0xFFFFFF03 }, .{ .qda = 0x03033F7F_0659AE03_0105E323_03037F04, .qc = 1 }),
    vec("vqrdmlash.s16", .{ .hw1 = 0xEE12, .hw2 = 0x1E42, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x4000 }, .{ .qda = 0x52354C4C_20006000_40004000_7FFF4001, .qc = 1 }),
    vec("vqrdmlash.s16 by a small scalar", .{ .hw1 = 0xEE12, .hw2 = 0x1E42, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0xFFFFFF03 }, .{ .qda = 0x11380B4F_DF031F03_FF03FF03_7F03FF04 }),
    vec("vqrdmlash.s32", .{ .hw1 = 0xEE22, .hw2 = 0x1E42, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x80000000 }, .{ .qda = 0x80000000_80000000_00000000_80000001, .qc = 1 }),
    vec("vqrdmlash.s32 by a small scalar", .{ .hw1 = 0xEE22, .hw2 = 0x1E42, .qda = 0x87654321_00000002_80000000_00000001, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x3 }, .{ .qda = 0xEED8ED1E_00000003_7FFFFFFF_00000004, .qc = 1 }),
    vec("vqdmlah.s16 q7, q6, r12", .{ .hw1 = 0xEE1C, .hw2 = 0xEE6C, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x7FFF }, .{ .qda = 0x800068AB_00007FFF_FFFF0001_80007FFF, .qc = 1 }),
    vec("vqrdmlash.s32 qda = qn, lr", .{ .hw1 = 0xEE26, .hw2 = 0x7E4E, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .rm = 0x1234 }, .{ .qda = 0x0296DFEC_00001234_7FFFFFFF_7FFFFFFF, .qc = 1 }),
    vec("no saturation leaves qc", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .qda = 0x00000004_00000003_00000002_00000001, .qn = 0x00000004_00000003_00000002_00000001, .rm = 0x5 }, .{ .qda = 0x00000004_00000003_00000002_00000001 }),
    vec("qc already set stays set", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .qda = 0x00000004_00000003_00000002_00000001, .qn = 0x00000004_00000003_00000002_00000001, .rm = 0x5, .qc = 1 }, .{ .qda = 0x00000004_00000003_00000002_00000001, .qc = 1 }),
};

const predicated = [_]V{
    vec("vpt p0 0x00ff merges the low half", .{ .hw1 = 0xEE12, .hw2 = 0x0E42, .qda = 0x80005678_40004000_FFFF0002_80000001, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .rm = 0x4000, .vpr = 0x008800FF }, .{ .qda = 0x80005678_40004000_00000002_80004001, .vpr = 0x000000FF, .qc = 1 }),
    vec("saturation only in an inactive lane leaves qc", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .qda = 0x00000004_00000003_00000002_00000001, .qn = 0x00000003_00000002_00000001_80000000, .rm = 0x80000000, .vpr = 0x0088FFF0 }, .{ .qda = 0x00000001_00000001_00000001_00000001, .vpr = 0x0000FFF0 }),
    vec("saturation in an active lane sets qc", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .qda = 0x00000004_00000003_00000002_00000001, .qn = 0x00000003_00000002_00000001_80000000, .rm = 0x80000000, .vpr = 0x0088000F }, .{ .qda = 0x00000004_00000003_00000002_7FFFFFFF, .vpr = 0x0000000F, .qc = 1 }),
    vec("the loop tail stops qc", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .qda = 0x00000004_00000003_00000002_00000001, .qn = 0x00000003_00000002_80000000_00000001, .rm = 0x80000000, .ltpsize = 2, .lr = 1 }, .{ .qda = 0x00000004_00000003_00000002_00000000 }),
    vec("eci a0a1 keeps the done beats", .{ .hw1 = 0xEE02, .hw2 = 0x1E62, .qda = 0xFEFF7F81_03808033_11104040_FF028001, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .rm = 0x40, .it = 0x20 }, .{ .qda = 0x403F7B7F_427FEB40_11104040_FF028001, .qc = 1 }),
};

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0E62 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E6D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E6F }, none),
    vec("u set is unclaimed", .{ .hw1 = 0xFE22, .hw2 = 0x0E62 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEE62, .hw2 = 0x0E62 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0EE2 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E72 }, none),
    vec("bits 6:4 000 are unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E02 }, none),
    vec("vmla is not vqrdmlah", .{ .hw1 = 0xEE23, .hw2 = 0x0E42 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E62, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
