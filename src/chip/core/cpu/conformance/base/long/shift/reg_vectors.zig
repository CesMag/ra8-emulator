//! Conformance vectors for the decode group `long_shift_reg` (RA8EMU-280):
//! LSLL and ASRL by a register (T1). Expected values are worked from the
//! Arm ARM (DDI0553): the amount is the signed bottom byte of Rm; LSLL
//! shifts left for a positive amount and logically right for a negative
//! one, ASRL arithmetically right for a positive amount and left for a
//! negative one, and 64 or more empties the pair (or fills it with the sign
//! for an arithmetic right shift). No flags change. Rm of SP, PC, RdaLo or
//! RdaHi, RdaHi = 1111, hw1 bit 0, types 01 and 11, a set hw2[7:6] and the
//! immediate forms are left unclaimed.
const vector = @import("../../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// RdaLo, RdaHi, then Rm before the instruction.
    lo: u32 = 0,
    hi: u32 = 0,
    rm: u32 = 0,
};

/// Whether the group claims the encoding, then RdaLo, RdaHi and NZCV after.
pub const Out = struct {
    claimed: bool = true,
    lo: u32 = 0,
    hi: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "long_shift_reg";
const none: Out = .{ .claimed = false, .flags = 0 };

/// RdaLo r0, RdaHi r1, Rm r2.
const lo0 = 0xEA50;
const lsll = 0x210D;
const asrl = 0x212D;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn sh(name: []const u8, hw2: u16, rm: u32, hi: u32, lo: u32, out_hi: u32, out_lo: u32) V {
    const input: In = .{ .hw1 = lo0, .hw2 = hw2, .lo = lo, .hi = hi, .rm = rm };
    return vec(name, input, .{ .lo = out_lo, .hi = out_hi });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    sh("lsll +1 carries into RdaHi", lsll, 1, 0, 0x8000_0000, 1, 0),
    sh("lsll +32 moves RdaLo up", lsll, 32, 0x1234, 0xDEAD_BEEF, 0xDEAD_BEEF, 0),
    sh("lsll +63 keeps one bit", lsll, 63, 0, 1, 0x8000_0000, 0),
    sh("lsll +64 empties the pair", lsll, 64, 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0),
    sh("lsll +127 empties the pair", lsll, 127, 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0),
    sh("lsll -1 shifts logically right", lsll, 0xFF, 0x8000_0000, 0, 0x4000_0000, 0),
    sh("lsll -32 moves RdaHi down", lsll, 0xE0, 0x8000_0001, 5, 0, 0x8000_0001),
    sh("lsll -128 empties the pair", lsll, 0x80, 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0),
    sh("lsll by 0 leaves the pair", lsll, 0, 0x1234_5678, 0x9ABC_DEF0, 0x1234_5678, 0x9ABC_DEF0),
    sh("lsll reads only the bottom byte of Rm", lsll, 0x0000_0101, 0, 1, 0, 2),
    sh("lsll ignores the top of a negative-looking Rm", lsll, 0xFFFF_FF04, 0, 1, 0, 0x10),
    sh("asrl +1 keeps the sign", asrl, 1, 0x8000_0000, 0, 0xC000_0000, 0),
    sh("asrl +32 fills with the sign", asrl, 32, 0x8000_0001, 0, 0xFFFF_FFFF, 0x8000_0001),
    sh("asrl +64 of a negative pair is all ones", asrl, 64, 0x8000_0000, 0, 0xFFFF_FFFF, 0xFFFF_FFFF),
    sh("asrl +127 of a positive pair is zero", asrl, 127, 0x7FFF_FFFF, 0xFFFF_FFFF, 0, 0),
    sh("asrl -1 shifts left", asrl, 0xFF, 0, 0x8000_0000, 1, 0),
    sh("asrl -64 empties the pair", asrl, 0xC0, 1, 1, 0, 0),
    sh("asrl -128 empties the pair", asrl, 0x80, 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0),
    sh("asrl by 0 leaves a negative pair", asrl, 0, 0x8000_0000, 7, 0x8000_0000, 7),
    vec("asrl on r10:r11 by r3", .{ .hw1 = 0xEA5A, .hw2 = 0x3B2D, .lo = 0, .hi = 0xF000_0000, .rm = 4 }, .{ .lo = 0, .hi = 0xFF00_0000 }),
    bad("Rm of sp is unclaimed", lo0, 0xD10D),
    bad("Rm of pc is unclaimed", lo0, 0xF10D),
    bad("Rm equal to RdaLo is unclaimed", lo0, 0x010D),
    bad("Rm equal to RdaHi is unclaimed", lo0, 0x110D),
    bad("RdaHi of 1111 belongs to the saturating shifts", lo0, 0x2F0D),
    bad("RdaHi SP is constrained unpredictable for LSLL", lo0, 0x2D0D),
    bad("RdaHi SP is constrained unpredictable for ASRL", lo0, 0x2D2D),
    bad("hw1 bit 0 set belongs to the 64-bit saturating shifts", 0xEA51, lsll),
    bad("type 01 is unclaimed", lo0, 0x211D),
    bad("type 11 is unclaimed", lo0, 0x213D),
    bad("hw2[6] set is unclaimed", lo0, 0x214D),
    bad("hw2[7] set is unclaimed", lo0, 0x218D),
    bad("the immediate form is unclaimed", lo0, 0x210F),
    vec("the 16-bit space is unclaimed", .{ .hw1 = lo0, .hw2 = lsll, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
