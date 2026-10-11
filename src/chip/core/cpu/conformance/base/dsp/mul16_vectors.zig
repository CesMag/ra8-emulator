//! Conformance vectors for the decode group `dsp_mul16` (RA8EMU-280):
//! SMUL<x><y>/SMLA<x><y> (0xFB10) and SMULW<y>/SMLAW<y> (0xFB30), T1.
//! Expected values are worked from the Arm ARM (DDI0553): x and y pick the
//! bottom or top signed halfword; SMLA<x><y> adds Ra and SMLAW<y> forms
//! (Rn * Rm.y + (Ra << 16))[47:16]; Ra = 1111 selects the plain forms. An
//! accumulate that overflows 32 bits sets APSR.Q, which is sticky; NZCV are
//! untouched. SP or PC in Rd, Rn or Rm, Ra = SP, a set hw2[7:6] (0xFB10) or
//! hw2[7:5] (0xFB30) and MLA are left unclaimed.
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
const group = "dsp_mul16";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 values carry Rd r0 and Rm r2, with Ra r3 or 1111.
const xy = 0xFB11;
const w = 0xFB31;
const mul_bb = 0xF002;
const mul_bt = 0xF012;
const mul_tb = 0xF022;
const mul_tt = 0xF032;
const mla_bb = 0x3002;
const mla_tt = 0x3032;
const mla_wt = 0x3012;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// `ovf` is whether the accumulate overflows and sets Q.
fn mul(name: []const u8, hw1: u16, hw2: u16, a: u32, n: u32, m: u32, rd: u32, ovf: bool) V {
    const input: In = .{ .hw1 = hw1, .hw2 = hw2, .a = a, .n = n, .m = m };
    return vec(name, input, .{ .rd = rd, .flags = if (ovf) flags_q else flags });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    mul("smulbb of signed bottoms", xy, mul_bb, 0, 3, 0x0000_FFFE, 0xFFFF_FFFA, false),
    mul("smulbt takes the top of Rm", xy, mul_bt, 0, 5, 0x0007_0000, 0x23, false),
    mul("smultb takes the top of Rn", xy, mul_tb, 0, 0xFFFF_0000, 9, 0xFFFF_FFF7, false),
    mul("smultt of -32768 squared does not set Q", xy, mul_tt, 0, 0x8000_0000, 0x8000_0000, 0x4000_0000, false),
    mul("smlabb adds Ra", xy, mla_bb, 10, 3, 4, 22, false),
    mul("smlatt adds a negative Ra", xy, mla_tt, 0xFFFF_FFF0, 0x0002_0000, 0x0003_0000, 0xFFFF_FFF6, false),
    mul("smlabb overflowing high sets Q", xy, mla_bb, 0x4000_0000, 0x8000, 0x8000, 0x8000_0000, true),
    mul("smlabb overflowing low sets Q", xy, mla_bb, 0x8000_0000, 0x8000, 0x7FFF, 0x4000_8000, true),
    mul("smulwb keeps bits 47:16", w, mul_bb, 0, 0x0001_0000, 3, 3, false),
    mul("smulwt of the most negative Rn", w, mul_bt, 0, 0x8000_0000, 0x7FFF_0000, 0xC000_8000, false),
    mul("smulwb shifts arithmetically", w, mul_bb, 0, 0xFFFF_FFFF, 1, 0xFFFF_FFFF, false),
    mul("smlawb adds Ra at bit 16", w, mla_bb, 5, 0x0001_0000, 2, 7, false),
    mul("smlawt overflow sets Q", w, mla_wt, 0x7FFF_FFFF, 0x7FFF_FFFF, 0x7FFF_0000, 0xBFFF_7FFE, true),
    vec("Q is sticky", .{ .hw1 = xy, .hw2 = mul_bb, .q = true, .n = 2, .m = 3 }, .{ .rd = 6, .flags = flags_q }),
    vec("smlabb r12, lr, r4, r5", .{ .hw1 = 0xFB1E, .hw2 = 0x5C04, .a = 1, .n = 0x10, .m = 0x10 }, .{ .rd = 0x101 }),
    vec("smulbb r1, r1, r1 reads before writing", .{ .hw1 = xy, .hw2 = 0xF101, .n = 7, .m = 7 }, .{ .rd = 49 }),
    bad("Rd of sp is unclaimed", xy, 0xFD02),
    bad("Rd of pc is unclaimed", w, 0xFF02),
    bad("Rn of sp is unclaimed", 0xFB1D, mul_bb),
    bad("Rn of pc is unclaimed", 0xFB3F, mul_bb),
    bad("Rm of sp is unclaimed", xy, 0xF00D),
    bad("Rm of pc is unclaimed", w, 0xF00F),
    bad("Ra of sp is unclaimed", xy, 0xD002),
    bad("a set hw2[7:6] on 0xFB10 is unclaimed", xy, 0xF042),
    bad("a set hw2[5] on 0xFB30 is unclaimed", w, 0xF022),
    bad("mla belongs to mul_acc", 0xFB01, mla_bb),
    vec("the 16-bit space is unclaimed", .{ .hw1 = xy, .hw2 = mul_bb, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
