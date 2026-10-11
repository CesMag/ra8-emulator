//! Conformance vectors for the decode group `extend_wide` (RA8EMU-280):
//! SXTH, UXTH, SXTB and UXTB (T2) and their accumulating forms SXTAH, UXTAH,
//! SXTAB and UXTAB (T1). Expected values are worked from the Arm ARM
//! (DDI0553): Rm rotated right by 0, 8, 16 or 24, the low halfword or byte
//! sign- or zero-extended, plus Rn for the A forms (wrapping), with no flag
//! changes. SP or PC in Rd or Rm, Rn of SP, the SXTB16/UXTB16 rows, a wrong
//! hw2[15:12] or hw2[7:6] and the misc_wide neighbours are left unclaimed.
const vector = @import("../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rn, then Rm, before the instruction.
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "extend_wide";
const none: Out = .{ .claimed = false, .flags = 0 };

/// The plain forms (Rn of PC) and the accumulating forms with Rn r1.
const sxth = 0xFA0F;
const uxth = 0xFA1F;
const sxtb = 0xFA4F;
const uxtb = 0xFA5F;
const sxtah = 0xFA01;
const uxtah = 0xFA11;
const sxtab = 0xFA41;
const uxtab = 0xFA51;
/// Rd r0 and Rm r2, rotated by 0, 8, 16 and 24.
const ror0 = 0xF082;
const ror8 = 0xF092;
const ror16 = 0xF0A2;
const ror24 = 0xF0B2;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw1: u16, hw2: u16, n: u32, m: u32) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .n = n, .m = m };
}

pub const all = [_]V{
    vec("sxth sign-extends", in(sxth, ror0, 0, 0x0000_8000), .{ .rd = 0xFFFF_8000 }),
    vec("sxth ror #16 of a negative halfword", in(sxth, ror16, 0, 0x8000_0000), .{ .rd = 0xFFFF_8000 }),
    vec("sxth ror #16 of a positive halfword", in(sxth, ror16, 0, 0x7FFF_0000), .{ .rd = 0x7FFF }),
    vec("uxth zero-extends", in(uxth, ror0, 0, 0xFFFF_8001), .{ .rd = 0x8001 }),
    vec("uxth ror #8", in(uxth, ror8, 0, 0x0012_3400), .{ .rd = 0x1234 }),
    vec("sxtb of a negative byte", in(sxtb, ror0, 0, 0x80), .{ .rd = 0xFFFF_FF80 }),
    vec("sxtb of a positive byte", in(sxtb, ror0, 0, 0x7F), .{ .rd = 0x7F }),
    vec("sxtb ror #24", in(sxtb, ror24, 0, 0x8000_0000), .{ .rd = 0xFFFF_FF80 }),
    vec("uxtb zero-extends", in(uxtb, ror0, 0, 0xFFFF_FFFE), .{ .rd = 0xFE }),
    vec("uxtb ror #8", in(uxtb, ror8, 0, 0x0000_AB00), .{ .rd = 0xAB }),
    vec("sxtah adds a negative halfword", in(sxtah, ror0, 0x10, 0xFFFF), .{ .rd = 0xF }),
    vec("uxtah adds an unsigned halfword", in(uxtah, ror0, 0x10, 0xFFFF), .{ .rd = 0x1_000F }),
    vec("sxtab adds a negative byte", in(sxtab, ror0, 0, 0x80), .{ .rd = 0xFFFF_FF80 }),
    vec("sxtab of -1 cancels 0x100 down to 0xff", in(sxtab, ror0, 0x100, 0xFF), .{ .rd = 0xFF }),
    vec("uxtab wraps", in(uxtab, ror0, 0xFFFF_FFFF, 1), .{ .rd = 0 }),
    vec("uxtab ror #16", in(uxtab, ror16, 1, 0x00FF_0000), .{ .rd = 0x100 }),
    vec("sxth r12, lr", in(sxth, 0xFC8E, 0, 0x1234), .{ .rd = 0x1234 }),
    vec("sxtab r1, r1, r1 reads before writing", in(sxtab, 0xF181, 0x10, 0x10), .{ .rd = 0x20 }),
    vec("Rd of sp is unclaimed", in(sxth, 0xFD82, 0, 0), none),
    vec("Rd of pc is unclaimed", in(sxth, 0xFF82, 0, 0), none),
    vec("Rm of sp is unclaimed", in(sxth, 0xF08D, 0, 0), none),
    vec("Rm of pc is unclaimed", in(sxth, 0xF08F, 0, 0), none),
    vec("Rn of sp is unclaimed", in(0xFA0D, ror0, 0, 0), none),
    vec("a clear hw2[7] is unclaimed", in(sxth, 0xF002, 0, 0), none),
    vec("a set hw2[6] is unclaimed", in(sxth, 0xF0C2, 0, 0), none),
    vec("a wrong hw2[15:12] is unclaimed", in(sxth, 0xE082, 0, 0), none),
    vec("sxtb16 is left to the DSP groups", in(0xFA2F, ror0, 0, 0), none),
    vec("uxtb16 is left to the DSP groups", in(0xFA3F, ror0, 0, 0), none),
    vec("rev belongs to misc_wide", in(0xFA91, 0xF081, 0, 0), none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = sxth, .hw2 = ror0, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
