//! Conformance vectors for the decode group `extend_b16` (RA8EMU-280):
//! SXTB16/SXTAB16 and UXTB16/UXTAB16 (T1). Expected values are worked from
//! the Arm ARM (DDI0553): Rm is rotated right by 0, 8, 16 or 24, bytes 0
//! and 2 are sign- or zero-extended into the halfwords of Rd, and the A
//! forms add each halfword of Rn modulo 2^16 per lane (Rn = PC is the plain
//! form). No flags change. SP or PC in Rd or Rm, Rn of SP, a wrong
//! hw2[15:12] or hw2[7:6] and SXTAB are left unclaimed.
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
const group = "extend_b16";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Plain forms (Rn = PC) and accumulating forms with Rn r1; hw2 values
/// carry Rd r0, the rotation and Rm r2.
const sxtb16 = 0xFA2F;
const uxtb16 = 0xFA3F;
const sxtab16 = 0xFA21;
const uxtab16 = 0xFA31;
const ror0 = 0xF082;
const ror8 = 0xF092;
const ror16 = 0xF0A2;
const ror24 = 0xF0B2;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ext(name: []const u8, hw1: u16, hw2: u16, n: u32, m: u32, rd: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .n = n, .m = m }, .{ .rd = rd });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    ext("sxtb16 sign-extends bytes 0 and 2", sxtb16, ror0, 0, 0x0080_007F, 0xFF80_007F),
    ext("uxtb16 zero-extends bytes 0 and 2", uxtb16, ror0, 0, 0x0080_007F, 0x0080_007F),
    ext("uxtb16 drops bytes 1 and 3", uxtb16, ror0, 0, 0xAABB_CCDD, 0x00BB_00DD),
    ext("sxtb16 ror #8", sxtb16, ror8, 0, 0x1122_3344, 0x0011_0033),
    ext("uxtb16 ror #16", uxtb16, ror16, 0, 0x1122_3344, 0x0044_0022),
    ext("sxtb16 ror #24", sxtb16, ror24, 0, 0x8000_FF00, 0xFFFF_FF80),
    ext("sxtab16 adds each halfword of Rn", sxtab16, ror0, 0x0001_0002, 0x0003_0004, 0x0004_0006),
    ext("sxtab16 adds negative bytes", sxtab16, ror0, 0x0010_0010, 0x00FF_00FF, 0x000F_000F),
    ext("uxtab16 lanes wrap without carrying", uxtab16, ror0, 0xFFFF_FFFF, 0x0001_0001, 0),
    ext("uxtab16 ror #8", uxtab16, ror8, 0x1000_2000, 0x1122_3344, 0x1011_2033),
    vec("sxtab16 r12, lr, r4", .{ .hw1 = 0xFA2E, .hw2 = 0xFC84, .n = 0x0100_0100, .m = 0x00FE_0002 }, .{ .rd = 0x00FE_0102 }),
    vec("uxtab16 r1, r1, r1 reads before writing", .{ .hw1 = uxtab16, .hw2 = 0xF181, .n = 0x0002_0003, .m = 0x0002_0003 }, .{ .rd = 0x0004_0006 }),
    bad("Rd of sp is unclaimed", sxtb16, 0xFD82),
    bad("Rd of pc is unclaimed", uxtb16, 0xFF82),
    bad("Rm of sp is unclaimed", sxtab16, 0xF08D),
    bad("Rm of pc is unclaimed", uxtab16, 0xF08F),
    bad("Rn of sp is unclaimed", 0xFA2D, ror0),
    bad("hw2[7:6] of 11 is unclaimed", sxtb16, 0xF0C2),
    bad("hw2[7:6] of 00 is unclaimed", sxtb16, 0xF002),
    bad("a wrong hw2[15:12] is unclaimed", uxtb16, 0xE082),
    bad("sxtab belongs to extend_wide", 0xFA41, ror0),
    vec("the 16-bit space is unclaimed", .{ .hw1 = sxtb16, .hw2 = ror0, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
