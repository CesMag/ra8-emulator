//! Conformance vectors for the decode group `long_mul` (RA8EMU-280): SMULL,
//! UMULL, SMLAL and UMLAL (T1). Expected values are worked from the Arm ARM
//! (DDI0553): RdHi:RdLo = Rn * Rm as a signed or unsigned 64-bit product,
//! or that product added to RdHi:RdLo modulo 2^64; none touch the flags.
//! SP or PC in any field and RdHi == RdLo are UNPREDICTABLE and left
//! unclaimed, as are UMAAL, the DSP long multiply-accumulates and SDIV.
const vector = @import("../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// RdLo and RdHi, then Rn and Rm, before the instruction.
    lo: u32 = 0x5555_5555,
    hi: u32 = 0xAAAA_AAAA,
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then RdLo, RdHi and NZCV after.
pub const Out = struct {
    claimed: bool = true,
    lo: u32 = 0,
    hi: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "long_mul";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Each instruction as RdLo r0, RdHi r1, Rn r2, Rm r3.
const smull = 0xFB82;
const umull = 0xFBA2;
const smlal = 0xFBC2;
const umlal = 0xFBE2;
const r0_r1_r3 = 0x0103;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn mul(hw1: u16, n: u32, m: u32) In {
    return .{ .hw1 = hw1, .hw2 = r0_r1_r3, .n = n, .m = m };
}

fn mla(hw1: u16, hi: u32, lo: u32, n: u32, m: u32) In {
    return .{ .hw1 = hw1, .hw2 = r0_r1_r3, .lo = lo, .hi = hi, .n = n, .m = m };
}

pub const all = [_]V{
    vec("umull 2 * 3 overwrites RdHi:RdLo", mul(umull, 2, 3), .{ .lo = 6 }),
    vec("umull all-ones squared", mul(umull, 0xFFFF_FFFF, 0xFFFF_FFFF), .{ .lo = 1, .hi = 0xFFFF_FFFE }),
    vec("smull -1 * -1", mul(smull, 0xFFFF_FFFF, 0xFFFF_FFFF), .{ .lo = 1, .hi = 0 }),
    vec("smull -2 * 3", mul(smull, 0xFFFF_FFFE, 3), .{ .lo = 0xFFFF_FFFA, .hi = 0xFFFF_FFFF }),
    vec("smull INT_MIN squared", mul(smull, 0x8000_0000, 0x8000_0000), .{ .lo = 0, .hi = 0x4000_0000 }),
    vec("smull INT_MIN * 1 sign-extends", mul(smull, 0x8000_0000, 1), .{ .lo = 0x8000_0000, .hi = 0xFFFF_FFFF }),
    vec("umull 0x80000000 * 1 zero-extends", mul(umull, 0x8000_0000, 1), .{ .lo = 0x8000_0000, .hi = 0 }),
    vec("umull of mixed bits", mul(umull, 0x1234_5678, 0x9ABC_DEF0), .{ .lo = 0x242D_2080, .hi = 0x0B00_EA4E }),
    vec("smull of mixed bits", mul(smull, 0x1234_5678, 0x9ABC_DEF0), .{ .lo = 0x242D_2080, .hi = 0xF8CC_93D6 }),
    vec("smlal carries from RdLo into RdHi", mla(smlal, 0, 0xFFFF_FFFF, 1, 1), .{ .lo = 0, .hi = 1 }),
    vec("smlal -1 * 1 onto zero", mla(smlal, 0, 0, 0xFFFF_FFFF, 1), .{ .lo = 0xFFFF_FFFF, .hi = 0xFFFF_FFFF }),
    vec("smlal 5 + -2 * 3", mla(smlal, 0, 5, 0xFFFF_FFFE, 3), .{ .lo = 0xFFFF_FFFF, .hi = 0xFFFF_FFFF }),
    vec("umlal wraps modulo 2^64", mla(umlal, 0xFFFF_FFFF, 0xFFFF_FFFF, 1, 1), .{ .lo = 0, .hi = 0 }),
    vec("umlal all-ones squared onto all-ones", mla(umlal, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF), .{ .lo = 0, .hi = 0xFFFF_FFFE }),
    vec("umlal 2 * 3 onto 1:0", mla(umlal, 1, 0, 2, 3), .{ .lo = 6, .hi = 1 }),
    vec("umull r12, lr, r4, r5", .{ .hw1 = 0xFBA4, .hw2 = 0xCE05, .n = 0x1_0000, .m = 0x1_0000 }, .{ .lo = 0, .hi = 1 }),
    vec("smull r0, r1, r0, r3 reads Rn before writing", .{ .hw1 = 0xFB80, .hw2 = r0_r1_r3, .n = 7, .m = 6 }, .{ .lo = 42, .hi = 0 }),
    vec("RdHi equal to RdLo is unclaimed", .{ .hw1 = umull, .hw2 = 0x1103 }, none),
    vec("RdLo of sp is unclaimed", .{ .hw1 = umull, .hw2 = 0xD103 }, none),
    vec("RdHi of pc is unclaimed", .{ .hw1 = smull, .hw2 = 0x0F03 }, none),
    vec("Rn of sp is unclaimed", .{ .hw1 = 0xFB8D, .hw2 = r0_r1_r3 }, none),
    vec("Rm of pc is unclaimed", .{ .hw1 = smlal, .hw2 = 0x010F }, none),
    vec("umaal belongs to umaal", .{ .hw1 = umlal, .hw2 = 0x0163 }, none),
    vec("smlalbb belongs to dsp_long_mul", .{ .hw1 = smlal, .hw2 = 0x0183 }, none),
    vec("sdiv belongs to divide", .{ .hw1 = 0xFB92, .hw2 = 0xF0F3 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = umull, .hw2 = r0_r1_r3, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
