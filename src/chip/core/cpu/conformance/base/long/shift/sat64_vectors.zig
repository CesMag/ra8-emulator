//! Conformance vectors for the decode group `long_shift_sat64`
//! (RA8EMU-280): UQSHLL, URSHRL, SRSHRL and SQSHLL by an immediate and
//! UQRSHLL and SQRSHRL by a register (T1), saturating at 64 bits or, with
//! the sat bit, 48. Expected values are worked from the Arm ARM (DDI0553)
//! with exact integers: rounding right shifts add 1 << (n - 1) first, a
//! clamp sets Q (sticky), an encoded immediate of 0 is 32, the register
//! forms read the signed bottom byte of Rm, and a 48-bit result is zero- or
//! sign-extended into the pair. NZCV never change. RdaHi of SP or 1111, hw2
//! bit 8 clear, hw2 bit 15 in the immediate form, hw2 bit 6 or types 01 and
//! 11 in the register form, and Rm of SP, PC, RdaLo or RdaHi are unclaimed.
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
    /// RdaHi:RdaLo, then Rm (register forms only) before the instruction.
    a: u64 = 0,
    rm: u32 = 0,
};

/// Whether the group claims the encoding, then RdaHi:RdaLo and NZCVQ after.
pub const Out = struct {
    claimed: bool = true,
    rd: u64 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "long_shift_sat64";
const none: Out = .{ .claimed = false, .flags = 0 };
const ones: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// RdaLo r0, RdaHi r1; the register forms use Rm r2.
const pair0 = 0xEA51;
const uqshll: u16 = 0;
const urshrl: u16 = 1;
const srshrl: u16 = 2;
const sqshll: u16 = 3;
const uqrshll = 0x210D;
const sqrshrl = 0x212D;
const sat48: u16 = 0x0080;

/// hw2 of the immediate form `kind` by `amount` on r0:r1 (32 encodes as 0).
fn enc(kind: u16, amount: u16) u16 {
    const a = amount & 0x1F;
    return ((a >> 2) << 12) | 0x0100 | ((a & 3) << 6) | (kind << 4) | 0xF;
}

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn imm(name: []const u8, kind: u16, amount: u16, a: u64, rd: u64, sat: bool) V {
    const input: In = .{ .hw1 = pair0, .hw2 = enc(kind, amount), .a = a };
    return vec(name, input, .{ .rd = rd, .flags = if (sat) flags_q else flags });
}

fn reg(name: []const u8, hw2: u16, rm: u32, a: u64, rd: u64, sat: bool) V {
    const input: In = .{ .hw1 = pair0, .hw2 = hw2, .a = a, .rm = rm };
    return vec(name, input, .{ .rd = rd, .flags = if (sat) flags_q else flags });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = immediates ++ registers ++ narrow ++ unclaimed;

const immediates = [_]V{
    imm("uqshll #4 in range", uqshll, 4, 0x0FFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFF0, false),
    imm("uqshll #4 saturates", uqshll, 4, 0x1000_0000_0000_0000, ones, true),
    imm("uqshll #32 moves RdaLo up", uqshll, 32, 0xFFFF_FFFF, 0xFFFF_FFFF_0000_0000, false),
    imm("uqshll #32 saturates", uqshll, 32, 0x1_0000_0000, ones, true),
    imm("urshrl #1 rounds up", urshrl, 1, 3, 2, false),
    imm("urshrl #32 rounds a half up across the halves", urshrl, 32, 0x1_8000_0000, 2, false),
    imm("urshrl #1 of all ones does not wrap", urshrl, 1, ones, 0x8000_0000_0000_0000, false),
    imm("srshrl #1 of -3", srshrl, 1, ones - 2, ones, false),
    imm("srshrl #32 rounds -2^31 to zero", srshrl, 32, 0xFFFF_FFFF_8000_0000, 0, false),
    imm("srshrl #32 of the most negative", srshrl, 32, 0x8000_0000_0000_0000, 0xFFFF_FFFF_8000_0000, false),
    imm("sqshll #1 in range", sqshll, 1, 0x3FFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFE, false),
    imm("sqshll #1 saturates high", sqshll, 1, 0x4000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, true),
    imm("sqshll #1 saturates low", sqshll, 1, 0xBFFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, true),
    imm("sqshll #32 of -1 fits", sqshll, 32, ones, 0xFFFF_FFFF_0000_0000, false),
    vec("Q is sticky", .{ .hw1 = pair0, .hw2 = enc(urshrl, 1), .q = true, .a = 4 }, .{ .rd = 2, .flags = flags_q }),
    vec("uqshll #1 on r10:r11", .{ .hw1 = 0xEA5B, .hw2 = 0x0B4F, .a = 0x21 }, .{ .rd = 0x42 }),
};

const registers = [_]V{
    reg("uqrshll +8 in range", uqrshll, 8, 0xFF, 0xFF00, false),
    reg("uqrshll +1 saturates", uqrshll, 1, 0x8000_0000_0000_0000, ones, true),
    reg("uqrshll -1 rounds right", uqrshll, 0xFF, 3, 2, false),
    reg("uqrshll -64 keeps the rounded top bit", uqrshll, 0xC0, 0x8000_0000_0000_0000, 1, false),
    reg("uqrshll -65 empties", uqrshll, 0xBF, ones, 0, false),
    reg("uqrshll +127 of one saturates", uqrshll, 127, 1, ones, true),
    reg("uqrshll +64 of zero", uqrshll, 64, 0, 0, false),
    reg("uqrshll by 0 leaves the pair", uqrshll, 0x100, 0x1_2345_6789, 0x1_2345_6789, false),
    reg("sqrshrl +1 of -3", sqrshrl, 1, ones - 2, ones, false),
    reg("sqrshrl -1 saturates high", sqrshrl, 0xFF, 0x4000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, true),
    reg("sqrshrl +64 of the most positive", sqrshrl, 64, 0x7FFF_FFFF_FFFF_FFFF, 0, false),
    reg("sqrshrl -128 of the most negative saturates", sqrshrl, 0x80, 0x8000_0000_0000_0000, 0x8000_0000_0000_0000, true),
};

const narrow = [_]V{
    reg("uqrshll sat48 +4 in range", uqrshll | sat48, 4, 0x0FFF_FFFF_FFFF, 0xFFFF_FFFF_FFF0, false),
    reg("uqrshll sat48 +4 saturates", uqrshll | sat48, 4, 0x1000_0000_0000, 0xFFFF_FFFF_FFFF, true),
    reg("uqrshll sat48 by 0 clamps a wide pair", uqrshll | sat48, 0, 0x1_0000_0000_0000, 0xFFFF_FFFF_FFFF, true),
    reg("uqrshll sat48 -1 still too wide", uqrshll | sat48, 0xFF, 0x3_0000_0000_0000, 0xFFFF_FFFF_FFFF, true),
    reg("sqrshrl sat48 -4 in range", sqrshrl | sat48, 0xFC, 0x07FF_FFFF_FFFF, 0x7FFF_FFFF_FFF0, false),
    reg("sqrshrl sat48 -1 saturates high", sqrshrl | sat48, 0xFF, 0x4000_0000_0000, 0x7FFF_FFFF_FFFF, true),
    reg("sqrshrl sat48 -1 reaches the 48-bit minimum", sqrshrl | sat48, 0xFF, 0xFFFF_C000_0000_0000, 0xFFFF_8000_0000_0000, false),
    reg("sqrshrl sat48 +1 of -3", sqrshrl | sat48, 1, ones - 2, ones, false),
    reg("sqrshrl sat48 by 0 clamps and sign-extends", sqrshrl | sat48, 0, 0x8000_0000_0000_0000, 0xFFFF_8000_0000_0000, true),
};

const unclaimed = [_]V{
    bad("RdaHi of sp is unclaimed", pair0, 0x0D4F),
    bad("RdaHi of 1111 is unclaimed", pair0, 0x0F4F),
    bad("hw2 bit 8 clear is unclaimed", pair0, 0x004F),
    bad("hw2 bit 15 in the immediate form is unclaimed", pair0, 0x8000 | enc(uqshll, 1)),
    bad("hw2 bit 6 in the register form is unclaimed", pair0, 0x214D),
    bad("type 01 in the register form is unclaimed", pair0, 0x211D),
    bad("type 11 in the register form is unclaimed", pair0, 0x213D),
    bad("Rm of sp is unclaimed", pair0, 0xD10D),
    bad("Rm of pc is unclaimed", pair0, 0xF10D),
    bad("Rm equal to RdaLo is unclaimed", pair0, 0x010D),
    bad("Rm equal to RdaHi is unclaimed", pair0, 0x110D),
    bad("hw1 bit 0 clear belongs to the plain long shifts", 0xEA50, enc(uqshll, 1)),
    vec("the 16-bit space is unclaimed", .{ .hw1 = pair0, .hw2 = enc(uqshll, 1), .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
