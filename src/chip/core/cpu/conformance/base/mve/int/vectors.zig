//! Conformance vectors for the decode group `mve_int` (RA8EMU-278): VADD,
//! VSUB and VMUL (vector, integer) at i8, i16 and i32. Expected values are
//! worked from the Arm ARM (DDI0553) pseudocode: each element is the low
//! esize bits of the sum, difference or product. Results merge byte by
//! byte under the VPT mask, the loop tail and the beats EPSR.ECI marks
//! done; ECI A0A1A2B0 leaves ECI A0 for the next instruction. Qd, Qn and Qm are written in that order before the instruction
//! runs. Size 11, VMUL with U set, fixed bits flipped, VQDMULH's encoding
//! and the 16-bit space are left unclaimed.
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
const group = "mve_int";
pub const none: Out = .{ .claimed = false, .qd = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = arithmetic ++ predicated ++ unclaimed;

const arithmetic = [_]V{
    vec("vadd.i8 wraps", .{ .hw1 = 0xEF02, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF028001 }, .{ .qd = 0xFC01BB02_812AD533_01200080_00010080 }),
    vec("vsub.i8 wraps", .{ .hw1 = 0xFF02, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF028001 }, .{ .qd = 0x0003BD00_7B2AD5CD_DF008000_02FD007E }),
    vec("vmul.i8 keeps the low half", .{ .hw1 = 0xEF02, .hw2 = 0x0954, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF028001 }, .{ .qd = 0x04FEC401_7A008000_F0000000_FFFE007F }),
    vec("vadd.i16 wraps", .{ .hw1 = 0xEF12, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80000001 }, .{ .qd = 0x6DCB68AC_00008000_00000001_00008000 }),
    vec("vsub.i16 wraps", .{ .hw1 = 0xFF12, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80000001 }, .{ .qd = 0x6DCBBBBC_80000000_0002FFFD_00007FFE }),
    vec("vmul.i16 keeps the low half", .{ .hw1 = 0xEF12, .hw2 = 0x0954, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80000001 }, .{ .qd = 0x80000060_00000000_FFFFFFFE_00007FFF }),
    vec("vadd.i32 wraps", .{ .hw1 = 0xEF22, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_00000001 }, .{ .qd = 0x99999999_00000001_00000000_80000000 }),
    vec("vsub.i32 wraps", .{ .hw1 = 0xFF22, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_00000001 }, .{ .qd = 0x8ACF1357_FFFFFFFD_00000000_7FFFFFFE }),
    vec("vmul.i32 keeps the low half", .{ .hw1 = 0xEF22, .hw2 = 0x0954, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_00000001 }, .{ .qd = 0x70B88D78_FFFFFFFE_00000000_7FFFFFFF }),
    vec("vadd.i32 q7, q6, q5", .{ .hw1 = 0xEF2C, .hw2 = 0xE84A, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_00000001 }, .{ .qd = 0x99999999_00000001_00000000_80000000 }),
    vec("qd = qn = qm doubles", .{ .hw1 = 0xEF18, .hw2 = 0x8848, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF }, .{ .qd = 0x00000000_00000000_00000000_00000000 }),
    vec("vsub of a register from itself is zero", .{ .hw1 = 0xFF06, .hw2 = 0x0846, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F }, .{ .qd = 0x00000000_00000000_00000000_00000000 }),
};

const predicated = [_]V{
    vec("vpt p0 0xff00 writes the high half and ends the block", .{ .hw1 = 0xEF22, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_00000001, .vpr = 0x0088FF00 }, .{ .qd = 0x99999999_00000001_01234567_89ABCDEF, .vpr = 0x0000FF00 }),
    vec("vpt p0 0x3333 predicates halves", .{ .hw1 = 0xEF12, .hw2 = 0x0954, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF, .qm = 0x80005678_40004000_FFFF0002_80000001, .vpr = 0x00883333 }, .{ .qd = 0xDEAD0060_CAFE0000_0123FFFE_89AB7FFF, .vpr = 0x00003333 }),
    vec("the loop tail writes the first bytes", .{ .hw1 = 0xFF02, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F, .qm = 0xFEFF7F81_03808033_11104040_FF028001, .ltpsize = 0, .lr = 5 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234500_02FD007E }),
    vec("lr past the vector writes everything", .{ .hw1 = 0xEF22, .hw2 = 0x0954, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_00000001, .ltpsize = 2, .lr = 9 }, .{ .qd = 0x70B88D78_FFFFFFFE_00000000_7FFFFFFF }),
    vec("eci a0a1a2b0 hands beat 0 of the next instruction on", .{ .hw1 = 0xEF22, .hw2 = 0x0844, .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF, .qn = 0x12345678_FFFFFFFF_80000000_7FFFFFFF, .qm = 0x87654321_00000002_80000000_00000001, .it = 0x50 }, .{ .qd = 0x99999999_CAFEF00D_01234567_89ABCDEF, .it = 0x10 }),
};

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEF32, .hw2 = 0x0844 }, none),
    vec("vmul with u set is unclaimed", .{ .hw1 = 0xFF22, .hw2 = 0x0954 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEF62, .hw2 = 0x0844 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEF23, .hw2 = 0x0844 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x08C4 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0864 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0845 }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x1844 }, none),
    vec("vqdmulh is not vadd", .{ .hw1 = 0xEF22, .hw2 = 0x0B44 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0844, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
