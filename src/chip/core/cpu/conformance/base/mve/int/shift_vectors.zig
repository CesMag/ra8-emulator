//! Conformance vectors for the decode group `mve_int_shift` (RA8EMU-278):
//! VSHL, VRSHL, VQSHL and VQRSHL (register), signed and unsigned at 8, 16
//! and 32 bits. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: each Qm element shifts by the signed bottom byte of the
//! matching Qn element, left for positive and arithmetic or logical right
//! for negative, the R forms adding 2^(-1-shift) first when shifting
//! right, the Q forms saturating to esize and raising FPSCR.QC only when
//! the saturating element's first byte is active, the others truncating.
//! Results merge byte by byte under the VPT mask, the loop tail and
//! EPSR.ECI. Qd, Qn and Qm are written in that order. Size 11, fixed bits
//! flipped, VHADD's encoding and the 16-bit space are left unclaimed.
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
const group = "mve_int_shift";
pub const none: Out = .{ .claimed = false, .qd = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = plain ++ saturating ++ predicated ++ unclaimed;

const plain = [_]V{
    vec("vshl.s8", .{ .hw1 = 0xEF02, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF00FA00_F801FF00_FF04E000_80FE00FE }),
    vec("vshl.u8", .{ .hw1 = 0xFF02, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF000A00_F8010100_00046000_80FE00FE }),
    vec("vshl.s16", .{ .hw1 = 0xEF12, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0xFFFF2340_F0000000_00008000_C000FFFE }),
    vec("vshl.u16", .{ .hw1 = 0xFF12, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0x00002340_30000000_00008000_4000FFFE }),
    vec("vshl.s32", .{ .hw1 = 0xEF22, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0xFFFFFFFF_80000000_C0000000_FFFFFFFE }),
    vec("vshl.s32 (second set)", .{ .hw1 = 0xEF22, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_00000000_01234567 }),
    vec("vshl.u32", .{ .hw1 = 0xFF22, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0x00000000_80000000_40000000_FFFFFFFE }),
    vec("vshl.u32 (second set)", .{ .hw1 = 0xFF22, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_00000000_01234567 }),
    vec("vrshl.s8", .{ .hw1 = 0xEF02, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF00FB00_F802FF00_0004E000_80FE00FE }),
    vec("vrshl.u8", .{ .hw1 = 0xFF02, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF000B00_F8020100_00046000_80FE00FE }),
    vec("vrshl.s16", .{ .hw1 = 0xEF12, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0x00002340_F0000001_00008000_C000FFFE }),
    vec("vrshl.u16", .{ .hw1 = 0xFF12, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0x00012340_30000001_00008000_4000FFFE }),
    vec("vrshl.s32", .{ .hw1 = 0xEF22, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0x00000000_80000000_C0000001_FFFFFFFE }),
    vec("vrshl.s32 (second set)", .{ .hw1 = 0xEF22, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_00000000_01234568 }),
    vec("vrshl.u32", .{ .hw1 = 0xFF22, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0x00000001_80000000_40000001_FFFFFFFE }),
    vec("vrshl.u32 (second set)", .{ .hw1 = 0xFF22, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_00000000_01234568 }),
    vec("vshl.s16 q7, q5, q6", .{ .hw1 = 0xEF1C, .hw2 = 0xE44A, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0xFFFF2340_F0000000_00008000_C000FFFE }),
    vec("vshl with qm = qn shifts each lane by itself", .{ .hw1 = 0xFF06, .hw2 = 0x0446, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x1110097F_80F8FEFF_07060504_03020100 }, .{ .qd = 0x00000000_00000000_00000000_00000000 }),
};

const saturating = [_]V{
    vec("vqshl.s8", .{ .hw1 = 0xEF02, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF00FA00_7F01FF7F_FF04E07F_7FFE807F, .qc = 1 }),
    vec("vqshl.u8", .{ .hw1 = 0xFF02, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF000A00_FF0101FF_000460FF_80FFFFFE, .qc = 1 }),
    vec("vqshl.s16", .{ .hw1 = 0xEF12, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0xFFFF7FFF_F0000000_7FFF8000_C0007FFF, .qc = 1 }),
    vec("vqshl.u16", .{ .hw1 = 0xFF12, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0x0000FFFF_30000000_FFFFFFFF_4000FFFE, .qc = 1 }),
    vec("vqshl.s32", .{ .hw1 = 0xEF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0xFFFFFFFF_7FFFFFFF_C0000000_7FFFFFFF, .qc = 1 }),
    vec("vqshl.s32 (second set)", .{ .hw1 = 0xEF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_80000000_01234567, .qc = 1 }),
    vec("vqshl.u32", .{ .hw1 = 0xFF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0x00000000_FFFFFFFF_40000000_FFFFFFFE, .qc = 1 }),
    vec("vqshl.u32 (second set)", .{ .hw1 = 0xFF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_FFFFFFFF_01234567, .qc = 1 }),
    vec("vqrshl.s8", .{ .hw1 = 0xEF02, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF00FB00_7F02FF7F_0004E07F_7FFE807F, .qc = 1 }),
    vec("vqrshl.u8", .{ .hw1 = 0xFF02, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F }, .{ .qd = 0xFF000B00_FF0201FF_000460FF_80FFFFFE, .qc = 1 }),
    vec("vqrshl.s16", .{ .hw1 = 0xEF12, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0x00007FFF_F0000001_7FFF8000_C0007FFF, .qc = 1 }),
    vec("vqrshl.u16", .{ .hw1 = 0xFF12, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF }, .{ .qd = 0x0001FFFF_30000001_FFFFFFFF_4000FFFE, .qc = 1 }),
    vec("vqrshl.s32", .{ .hw1 = 0xEF22, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0x00000000_7FFFFFFF_C0000001_7FFFFFFF, .qc = 1 }),
    vec("vqrshl.s32 (second set)", .{ .hw1 = 0xEF22, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_80000000_01234568, .qc = 1 }),
    vec("vqrshl.u32", .{ .hw1 = 0xFF22, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x000000E0_0000001F_000000FF_00000001, .qm = 0xFFFFFFFF_00000003_80000001_7FFFFFFF }, .{ .qd = 0x00000001_FFFFFFFF_40000001_FFFFFFFE, .qc = 1 }),
    vec("vqrshl.u32 (second set)", .{ .hw1 = 0xFF22, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000081_12345602_00000020_FFFFFFFC, .qm = 0x40000000_00000001_87654321_12345678 }, .{ .qd = 0x00000000_00000004_FFFFFFFF_01234568, .qc = 1 }),
    vec("vqshl without saturation leaves qc", .{ .hw1 = 0xEF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000004_00000003_00000002_00000001, .qm = 0x00000004_00000003_00000002_00000001 }, .{ .qd = 0x00000040_00000018_00000008_00000002 }),
    vec("qc already set stays set", .{ .hw1 = 0xEF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000004_00000003_00000002_00000001, .qm = 0x00000004_00000003_00000002_00000001, .qc = 1 }, .{ .qd = 0x00000040_00000018_00000008_00000002, .qc = 1 }),
};

const predicated = [_]V{
    vec("vpt p0 0x0ff0 merges the middle", .{ .hw1 = 0xEF12, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF, .vpr = 0x00880FF0 }, .{ .qd = 0xDEADBEEF_F0000001_00008000_89ABCDEF, .vpr = 0x00000FF0 }),
    vec("saturation only in an inactive lane leaves qc", .{ .hw1 = 0xEF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000001_00000001_00000001_00000004, .qm = 0x00000003_00000002_00000001_40000000, .vpr = 0x0088FFF0 }, .{ .qd = 0x00000006_00000004_00000002_89ABCDEF, .vpr = 0x0000FFF0 }),
    vec("saturation in an active lane sets qc", .{ .hw1 = 0xEF22, .hw2 = 0x0454, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000001_00000001_00000001_00000004, .qm = 0x00000003_00000002_00000001_40000000, .vpr = 0x0088000F }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_7FFFFFFF, .vpr = 0x0000000F, .qc = 1 }),
    vec("the loop tail stops vqrshl qc", .{ .hw1 = 0xFF22, .hw2 = 0x0554, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00000001_00000001_00000008_00000001, .qm = 0x00000003_00000002_FFFFFFFF_00000001, .ltpsize = 2, .lr = 1 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_00000002 }),
    vec("the loop tail writes the first lanes", .{ .hw1 = 0xEF02, .hw2 = 0x0444, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F8FC05_02FFF97F_80FEFF08_07010101, .qm = 0xFF02AA00_7E038155_F011C040_01FF807F, .ltpsize = 0, .lr = 7 }, .{ .qd = 0xDEADBEEF_CAFEF00D_0104E000_80FE00FE }),
    vec("eci a0a1 keeps the done beats", .{ .hw1 = 0xFF12, .hw2 = 0x0544, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x00F00004_00FE00F1_0110000F_00FF0001, .qm = 0xEDCB1234_C0004001_0001FFFF_80007FFF, .it = 0x20 }, .{ .qd = 0x00012340_30000001_01234567_89ABCDEF }),
};

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEF32, .hw2 = 0x0444 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEF62, .hw2 = 0x0444 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEF23, .hw2 = 0x0444 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x04C4 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0464 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0445 }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x1444 }, none),
    vec("hw2[6] clear is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0404 }, none),
    vec("vhadd is not vshl", .{ .hw1 = 0xEF22, .hw2 = 0x0044 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0444, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
