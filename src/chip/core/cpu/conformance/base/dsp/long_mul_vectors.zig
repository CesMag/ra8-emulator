//! Conformance vectors for the decode group `dsp_long_mul` (RA8EMU-280):
//! SMLAL<x><y>, SMLALD{X} (0xFBC0) and SMLSLD{X} (0xFBD0), T1. Expected
//! values are worked from the Arm ARM (DDI0553): the signed halfword product
//! (or the sum or difference of the two dual products, Rm's halves swapped
//! by X) is added to RdHi:RdLo, wrapping at 64 bits; no flags change and Q
//! is never set. SP or PC anywhere, RdLo == RdHi, SMLAL itself and the
//! unallocated hw2[7:4] rows are left unclaimed.
const vector = @import("../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// RdLo, RdHi, Rn, then Rm before the instruction, written in that order.
    lo: u32 = 0,
    hi: u32 = 0,
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
const group = "dsp_long_mul";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 values carry RdLo r3, RdHi r4 and Rm r2.
const add = 0xFBC1;
const sub = 0xFBD1;
const bb = 0x3482;
const bt = 0x3492;
const tb = 0x34A2;
const tt = 0x34B2;
const dual = 0x34C2;
const dual_x = 0x34D2;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn acc(name: []const u8, hw1: u16, hw2: u16, hi: u32, lo: u32, n: u32, m: u32, out_hi: u32, out_lo: u32) V {
    const input: In = .{ .hw1 = hw1, .hw2 = hw2, .lo = lo, .hi = hi, .n = n, .m = m };
    return vec(name, input, .{ .lo = out_lo, .hi = out_hi });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    acc("smlalbb sign-extends a negative product", add, bb, 0, 0, 3, 0x0000_FFFE, 0xFFFF_FFFF, 0xFFFF_FFFA),
    acc("smlalbt takes the top of Rm", add, bt, 0, 1, 5, 0x0007_0000, 0, 0x24),
    acc("smlaltb takes the top of Rn", add, tb, 0, 0, 0xFFFF_0000, 9, 0xFFFF_FFFF, 0xFFFF_FFF7),
    acc("smlaltt of -32768 squared", add, tt, 0, 0, 0x8000_0000, 0x8000_0000, 0, 0x4000_0000),
    acc("smlalbb carries into RdHi", add, bb, 0, 0xFFFF_FFFF, 1, 1, 1, 0),
    acc("smlalbb borrows from RdHi", add, bb, 1, 0, 0xFFFF, 1, 0, 0xFFFF_FFFF),
    acc("smlalbb wraps at 64 bits", add, bb, 0xFFFF_FFFF, 0xFFFF_FFFF, 1, 1, 0, 0),
    acc("smlald adds both products", add, dual, 0, 0, 0x0003_0002, 0x0005_0004, 0, 23),
    acc("smlaldx swaps the halves of Rm", add, dual_x, 0, 0, 0x0003_0002, 0x0005_0004, 0, 22),
    acc("smlald wraps with no Q", add, dual, 0x7FFF_FFFF, 0xFFFF_FFFF, 0x8000_8000, 0x8000_8000, 0x8000_0000, 0x7FFF_FFFF),
    acc("smlsld subtracts the top product", sub, dual, 0, 10, 0x0003_0002, 0x0005_0004, 0, 3),
    acc("smlsldx goes below zero", sub, dual_x, 0, 0, 0x0003_0002, 0x0005_0004, 0xFFFF_FFFF, 0xFFFF_FFFE),
    acc("smlsld at the extremes", sub, dual, 1, 0, 0x8000_8000, 0x7FFF_8000, 1, 0x7FFF_8000),
    vec("Rn may be RdLo and is read first", .{ .hw1 = 0xFBC3, .hw2 = bb, .lo = 2, .n = 2, .m = 3 }, .{ .lo = 8, .hi = 0 }),
    vec("smlalbb r12, lr, r5, r6", .{ .hw1 = 0xFBC5, .hw2 = 0xCE86, .lo = 1, .hi = 2, .n = 4, .m = 5 }, .{ .lo = 21, .hi = 2 }),
    bad("RdLo == RdHi is unclaimed", add, 0x3382),
    bad("RdLo of sp is unclaimed", add, 0xD482),
    bad("RdHi of pc is unclaimed", sub, 0x3FC2),
    bad("Rn of sp is unclaimed", 0xFBCD, bb),
    bad("Rn of pc is unclaimed", 0xFBDF, dual),
    bad("Rm of sp is unclaimed", add, 0x348D),
    bad("Rm of pc is unclaimed", add, 0x34CF),
    bad("smlal belongs to long_mul", add, 0x3402),
    bad("hw2[7:4] 0110 is unclaimed", add, 0x3462),
    bad("hw2[7:4] 1110 is unclaimed", add, 0x34E2),
    bad("no halfword form on 0xFBD0", sub, bb),
    bad("hw2[7:4] 1110 on 0xFBD0 is unclaimed", sub, 0x34E2),
    vec("the 16-bit space is unclaimed", .{ .hw1 = add, .hw2 = bb, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
