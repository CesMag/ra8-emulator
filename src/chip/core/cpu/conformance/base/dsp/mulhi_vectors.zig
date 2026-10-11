//! Conformance vectors for the decode group `dsp_mulhi` (RA8EMU-280):
//! SMMUL/SMMLA (0xFB50) and SMMLS (0xFB60), T1, with and without R.
//! Expected values are worked from the Arm ARM (DDI0553): Rd is bits 63:32
//! of (Ra << 32) +/- Rn * Rm, signed, plus 0x8000_0000 when R rounds; Ra =
//! 1111 on 0xFB50 is SMMUL. None of them touches NZCV, Q or GE. SP or PC in
//! Rd, Rn or Rm, Ra = SP, Ra = 1111 on 0xFB60 and a set hw2[7:5] are left
//! unclaimed.
const vector = @import("../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;
/// N and C with Q set, for the vector that holds Q going in.
pub const flags_q: u32 = 0xA800_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// APSR.Q before the instruction.
    q: bool = false,
    /// Ra, Rn, then Rm before the instruction, written in that order.
    a: u32 = 0,
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and NZCVQ after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "dsp_mulhi";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 values carry Rd r0 and Rm r2, with Ra r3 or 1111.
const mla = 0xFB51;
const mls = 0xFB61;
const mul = 0xF002;
const mul_r = 0xF012;
const acc = 0x3002;
const acc_r = 0x3012;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn top(name: []const u8, hw1: u16, hw2: u16, a: u32, n: u32, m: u32, rd: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .a = a, .n = n, .m = m }, .{ .rd = rd });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    top("smmul keeps the top word", mla, mul, 0, 0x4000_0000, 4, 1),
    top("smmul of a small negative product", mla, mul, 0, 0xFFFF_FFFF, 1, 0xFFFF_FFFF),
    top("smmul truncates bit 31", mla, mul, 0, 0x0001_0000, 0x8000, 0),
    top("smmulr rounds bit 31 up", mla, mul_r, 0, 0x0001_0000, 0x8000, 1),
    top("smmul of the most negative squared", mla, mul, 0, 0x8000_0000, 0x8000_0000, 0x4000_0000),
    top("smmul mixed signs", mla, mul, 0, 0x7FFF_FFFF, 0x8000_0000, 0xC000_0000),
    top("smmulr mixed signs", mla, mul_r, 0, 0x7FFF_FFFF, 0x8000_0000, 0xC000_0001),
    top("smmla adds Ra to the top word", mla, acc, 5, 0x0002_0000, 0x0001_0000, 7),
    top("smmla wraps the top word", mla, acc, 0x7FFF_FFFF, 0x4000_0000, 4, 0x8000_0000),
    top("smmlar rounds", mla, acc_r, 0, 0x0001_0000, 0x8000, 1),
    top("smmlar of -1 * -1 + Ra -1", mla, acc_r, 0xFFFF_FFFF, 0xFFFF_FFFF, 1, 0xFFFF_FFFF),
    top("smmla mixed operands", mla, acc, 0x1234_5678, 0x9ABC_DEF0, 0x0FED_CBA9, 0x0BE7_57D3),
    top("smmls subtracts from Ra", mls, acc, 10, 0x0002_0000, 0x0001_0000, 8),
    top("smmls borrows from Ra", mls, acc, 1, 0x0001_0000, 0x8000, 0),
    top("smmlsr rounds the borrow", mls, acc_r, 1, 0x0001_0000, 0x8000, 1),
    top("smmls below zero", mls, acc, 0, 1, 1, 0xFFFF_FFFF),
    top("smmls wraps the top word", mls, acc, 0x8000_0000, 0x4000_0000, 4, 0x7FFF_FFFF),
    top("smmlsr mixed operands", mls, acc_r, 0x1234_5678, 0x9ABC_DEF0, 0x0FED_CBA9, 0x1881_551D),
    vec("Q and the flags are untouched", .{ .hw1 = mla, .hw2 = mul, .q = true, .n = 0x4000_0000, .m = 8 }, .{ .rd = 2, .flags = flags_q }),
    vec("smmla r12, lr, r4, r5", .{ .hw1 = 0xFB5E, .hw2 = 0x5C04, .a = 1, .n = 0x10, .m = 0x10 }, .{ .rd = 1 }),
    vec("smmul r1, r1, r1 reads before writing", .{ .hw1 = mla, .hw2 = 0xF101, .n = 0x0001_0000, .m = 0x0001_0000 }, .{ .rd = 1 }),
    bad("Rd of sp is unclaimed", mla, 0xFD02),
    bad("Rd of pc is unclaimed", mls, 0x3F02),
    bad("Rn of sp is unclaimed", 0xFB5D, mul),
    bad("Rn of pc is unclaimed", 0xFB6F, acc),
    bad("Rm of sp is unclaimed", mla, 0xF00D),
    bad("Rm of pc is unclaimed", mls, 0x300F),
    bad("Ra of sp is unclaimed", mla, 0xD002),
    bad("smmls without an accumulator is unclaimed", mls, mul),
    bad("hw2[5] set is unclaimed", mla, 0xF022),
    bad("hw2[6] set is unclaimed", mla, 0xF042),
    bad("hw2[7] set is unclaimed", mls, 0x3082),
    vec("the 16-bit space is unclaimed", .{ .hw1 = mla, .hw2 = mul, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
