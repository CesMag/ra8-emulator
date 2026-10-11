//! Conformance vectors for the decode group `dsp_dual` (RA8EMU-280):
//! SMUAD/SMLAD (0xFB20) and SMUSD/SMLSD (0xFB40), T1, with and without X.
//! Expected values are worked from the Arm ARM (DDI0553): the bottom and top
//! signed halfwords of Rn times those of Rm (swapped by X), the two products
//! added or subtracted, plus Ra; Ra = 1111 selects the plain forms. Q is set
//! (and sticky) when the whole sum does not fit 32 signed bits, judged once
//! on the full sum; NZCV are untouched. SP or PC in Rd, Rn or Rm, Ra = SP
//! and a set hw2[7:5] are left unclaimed.
const vector = @import("../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;
/// The flags after an overflow: N and C with Q set.
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
const group = "dsp_dual";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 values carry Rd r0 and Rm r2, with Ra r3 or 1111.
const add = 0xFB21;
const sub = 0xFB41;
const mul = 0xF002;
const mul_x = 0xF012;
const acc = 0x3002;
const acc_x = 0x3012;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// `ovf` is whether the sum leaves 32 signed bits and sets Q.
fn dual(name: []const u8, hw1: u16, hw2: u16, a: u32, n: u32, m: u32, rd: u32, ovf: bool) V {
    const input: In = .{ .hw1 = hw1, .hw2 = hw2, .a = a, .n = n, .m = m };
    return vec(name, input, .{ .rd = rd, .flags = if (ovf) flags_q else flags });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    dual("smuad adds the matching products", add, mul, 0, 0x0003_0002, 0x0005_0004, 23, false),
    dual("smuadx swaps the halves of Rm", add, mul_x, 0, 0x0003_0002, 0x0005_0004, 22, false),
    dual("smuad of negative halves", add, mul, 0, 0xFFFF_FFFE, 0x0003_0004, 0xFFFF_FFF5, false),
    dual("smuad of two -32768 squares sets Q", add, mul, 0, 0x8000_8000, 0x8000_8000, 0x8000_0000, true),
    dual("smlad adds Ra", add, acc, 100, 0x0003_0002, 0x0005_0004, 123, false),
    dual("smlad overflowing high sets Q", add, acc, 0x7FFF_FFFF, 1, 1, 0x8000_0000, true),
    dual("smlad overflowing low sets Q", add, acc, 0x8000_0000, 0x0000_FFFF, 1, 0x7FFF_FFFF, true),
    dual("smlad judges overflow on the whole sum", add, acc, 0xFFFF_FFFF, 0x8000_8000, 0x8000_8000, 0x7FFF_FFFF, false),
    dual("smlad with X", add, acc_x, 1, 0x0003_0002, 0x0005_0004, 23, false),
    dual("smusd subtracts the top product", sub, mul, 0, 0x0003_0002, 0x0005_0004, 0xFFFF_FFF9, false),
    dual("smusdx swaps the halves of Rm", sub, mul_x, 0, 0x0003_0002, 0x0005_0004, 0xFFFF_FFFE, false),
    dual("smusd at the extremes still fits", sub, mul, 0, 0x8000_8000, 0x7FFF_8000, 0x7FFF_8000, false),
    dual("smlsd adds Ra", sub, acc, 10, 0x0003_0002, 0x0005_0004, 3, false),
    dual("smlsdx adds Ra", sub, acc_x, 0, 0x0003_0002, 0x0005_0004, 0xFFFF_FFFE, false),
    dual("smlsd overflow sets Q", sub, acc, 0x7FFF_FFFF, 1, 1, 0x8000_0000, true),
    vec("Q is sticky", .{ .hw1 = add, .hw2 = mul, .q = true, .n = 0x0001_0001, .m = 0x0001_0001 }, .{ .rd = 2, .flags = flags_q }),
    vec("smlad r12, lr, r4, r5", .{ .hw1 = 0xFB2E, .hw2 = 0x5C04, .a = 1, .n = 0x0001_0001, .m = 0x0002_0002 }, .{ .rd = 5 }),
    vec("smuad r1, r1, r1 reads before writing", .{ .hw1 = add, .hw2 = 0xF101, .n = 0x0002_0003, .m = 0x0002_0003 }, .{ .rd = 13 }),
    bad("Rd of sp is unclaimed", add, 0xFD02),
    bad("Rd of pc is unclaimed", sub, 0x3F02),
    bad("Rn of sp is unclaimed", 0xFB2D, mul),
    bad("Rn of pc is unclaimed", 0xFB4F, acc),
    bad("Rm of sp is unclaimed", add, 0xF00D),
    bad("Rm of pc is unclaimed", sub, 0x300F),
    bad("Ra of sp is unclaimed", add, 0xD002),
    bad("hw2[5] set is unclaimed", add, 0xF022),
    bad("hw2[6] set is unclaimed", sub, 0xF042),
    bad("hw2[7] set is unclaimed", sub, 0x3082),
    bad("smlawb belongs to dsp_mul16", 0xFB31, acc),
    vec("the 16-bit space is unclaimed", .{ .hw1 = add, .hw2 = mul, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
