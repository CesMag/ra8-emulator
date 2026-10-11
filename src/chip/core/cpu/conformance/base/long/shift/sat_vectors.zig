//! Conformance vectors for the decode group `long.shift.sat` (RA8EMU-280):
//! UQSHL, URSHR, SRSHR and SQSHL by an immediate and UQRSHL and SQRSHR by a
//! register (T1), the single-register RdaHi = 1111 corner of the long
//! shifts. Expected values are worked from the Arm ARM (DDI0553) with exact
//! integers: rounding right shifts add 1 << (n - 1) first, saturating left
//! shifts clamp to the unsigned or signed 32-bit range and set Q (sticky),
//! an encoded immediate of 0 is 32, and the register forms read the signed
//! bottom byte of Rm (negative reverses the direction). NZCV never change.
//! Rda of SP or PC, Rm of SP, PC or Rda, hw2 bit 15 in the immediate form,
//! a set hw2[7:6] or types 01 and 11 in the register form are unclaimed.
const vector = @import("../../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;
/// The flags after a clamp: N and C with Q set.
pub const flags_q: u32 = 0xA800_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// APSR.Q before the instruction.
    q: bool = false,
    /// Rda, then Rm (register forms only) before the instruction.
    a: u32 = 0,
    rm: u32 = 0,
};

/// Whether the group claims the encoding, then Rda and NZCVQ after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "long_shift_sat";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rda r1; the register forms use Rm r2.
const rda1 = 0xEA51;
const uqshl: u16 = 0;
const urshr: u16 = 1;
const srshr: u16 = 2;
const sqshl: u16 = 3;
const uqrshl = 0x2F0D;
const sqrshr = 0x2F2D;

/// hw2 of the immediate form `kind` by `amount` (32 encodes as 0).
fn enc(kind: u16, amount: u16) u16 {
    const a = amount & 0x1F;
    return ((a >> 2) << 12) | 0x0F00 | ((a & 3) << 6) | (kind << 4) | 0xF;
}

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn imm(name: []const u8, kind: u16, amount: u16, a: u32, rd: u32, sat: bool) V {
    const input: In = .{ .hw1 = rda1, .hw2 = enc(kind, amount), .a = a };
    return vec(name, input, .{ .rd = rd, .flags = if (sat) flags_q else flags });
}

fn reg(name: []const u8, hw2: u16, rm: u32, a: u32, rd: u32, sat: bool) V {
    const input: In = .{ .hw1 = rda1, .hw2 = hw2, .a = a, .rm = rm };
    return vec(name, input, .{ .rd = rd, .flags = if (sat) flags_q else flags });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    imm("uqshl #4 in range", uqshl, 4, 0x0FFF_FFFF, 0xFFFF_FFF0, false),
    imm("uqshl #4 saturates", uqshl, 4, 0x1000_0000, 0xFFFF_FFFF, true),
    imm("uqshl #32 of zero", uqshl, 32, 0, 0, false),
    imm("uqshl #32 of one saturates", uqshl, 32, 1, 0xFFFF_FFFF, true),
    imm("urshr #1 rounds up", urshr, 1, 3, 2, false),
    imm("urshr #4 rounds a half up", urshr, 4, 0x18, 2, false),
    imm("urshr #4 rounds below a half down", urshr, 4, 0x17, 1, false),
    imm("urshr #32 of the top bit", urshr, 32, 0x8000_0000, 1, false),
    imm("urshr #32 below the top bit", urshr, 32, 0x7FFF_FFFF, 0, false),
    imm("urshr #1 of all ones does not wrap", urshr, 1, 0xFFFF_FFFF, 0x8000_0000, false),
    imm("srshr #1 of -3", srshr, 1, 0xFFFF_FFFD, 0xFFFF_FFFF, false),
    imm("srshr #2 of -6", srshr, 2, 0xFFFF_FFFA, 0xFFFF_FFFF, false),
    imm("srshr #2 of 5", srshr, 2, 5, 1, false),
    imm("srshr #32 of the most negative", srshr, 32, 0x8000_0000, 0, false),
    imm("srshr #32 of the most positive", srshr, 32, 0x7FFF_FFFF, 0, false),
    imm("sqshl #1 in range", sqshl, 1, 0x3FFF_FFFF, 0x7FFF_FFFE, false),
    imm("sqshl #1 saturates high", sqshl, 1, 0x4000_0000, 0x7FFF_FFFF, true),
    imm("sqshl #1 reaches the most negative", sqshl, 1, 0xC000_0000, 0x8000_0000, false),
    imm("sqshl #1 saturates low", sqshl, 1, 0xBFFF_FFFF, 0x8000_0000, true),
    imm("sqshl #31 of one saturates", sqshl, 31, 1, 0x7FFF_FFFF, true),
    imm("sqshl #31 of -1 fits", sqshl, 31, 0xFFFF_FFFF, 0x8000_0000, false),
    reg("uqrshl +4 in range", uqrshl, 4, 0x0FFF_FFFF, 0xFFFF_FFF0, false),
    reg("uqrshl +1 saturates", uqrshl, 1, 0x8000_0000, 0xFFFF_FFFF, true),
    reg("uqrshl -1 rounds right", uqrshl, 0xFF, 3, 2, false),
    reg("uqrshl -32 keeps the rounded top bit", uqrshl, 0xE0, 0x8000_0000, 1, false),
    reg("uqrshl -33 empties", uqrshl, 0xDF, 0xFFFF_FFFF, 0, false),
    reg("uqrshl +32 of zero", uqrshl, 32, 0, 0, false),
    reg("uqrshl +127 of one saturates", uqrshl, 127, 1, 0xFFFF_FFFF, true),
    reg("uqrshl by 0 leaves Rda", uqrshl, 0, 0x1234, 0x1234, false),
    reg("uqrshl reads only the bottom byte of Rm", uqrshl, 0x104, 1, 0x10, false),
    reg("sqrshr +1 rounds 3 up", sqrshr, 1, 3, 2, false),
    reg("sqrshr +1 of -3", sqrshr, 1, 0xFFFF_FFFD, 0xFFFF_FFFF, false),
    reg("sqrshr +32 of the most positive", sqrshr, 32, 0x7FFF_FFFF, 0, false),
    reg("sqrshr -1 saturates high", sqrshr, 0xFF, 0x4000_0000, 0x7FFF_FFFF, true),
    reg("sqrshr -1 reaches the most negative", sqrshr, 0xFF, 0xC000_0000, 0x8000_0000, false),
    reg("sqrshr by 0 leaves Rda", sqrshr, 0, 0x1234, 0x1234, false),
    reg("sqrshr -128 of the most negative saturates", sqrshr, 0x80, 0x8000_0000, 0x8000_0000, true),
    vec("Q is sticky", .{ .hw1 = rda1, .hw2 = enc(urshr, 1), .q = true, .a = 4 }, .{ .rd = 2, .flags = flags_q }),
    vec("uqshl #1 on r12", .{ .hw1 = 0xEA5C, .hw2 = enc(uqshl, 1), .a = 0x21 }, .{ .rd = 0x42 }),
    bad("Rda of sp is unclaimed", 0xEA5D, enc(uqshl, 1)),
    bad("Rda of pc is unclaimed", 0xEA5F, enc(uqshl, 1)),
    bad("Rm of sp is unclaimed", rda1, 0xDF0D),
    bad("Rm of pc is unclaimed", rda1, 0xFF0D),
    bad("Rm equal to Rda is unclaimed", rda1, 0x1F0D),
    bad("hw2 bit 15 in the immediate form is unclaimed", rda1, 0x8000 | enc(uqshl, 1)),
    bad("hw2[6] in the register form is unclaimed", rda1, 0x2F4D),
    bad("type 01 in the register form is unclaimed", rda1, 0x2F1D),
    bad("type 11 in the register form is unclaimed", rda1, 0x2F3D),
    bad("an RdaHi field other than 1111 is unclaimed", rda1, 0x2E0D),
    bad("hw2[3:0] of 1110 is unclaimed", rda1, 0x2F0E),
    vec("the 16-bit space is unclaimed", .{ .hw1 = rda1, .hw2 = enc(uqshl, 1), .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
