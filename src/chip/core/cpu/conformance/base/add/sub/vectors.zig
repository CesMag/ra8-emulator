//! Conformance vectors for the decode group `add_sub` (RA8EMU-279): 16-bit
//! ADD and SUB with a register or a 3-bit immediate, and MOV, CMP, ADD and
//! SUB with an 8-bit immediate. Each expected value is worked from
//! AddWithCarry() in the Arm ARM (DDI0553): SUB is x + NOT(y) + 1, so C is
//! NOT borrow; MOV sets N and Z only; CMP sets flags even in an IT block
//! and the rest leave them alone there.
const vector = @import("../../../vector.zig");

/// The instruction, the value in Rn (Rdn for the 8-bit immediate forms),
/// the value in Rm, and NZCV and ITSTATE beforehand. Rd is r0 or Rdn.
pub const In = struct {
    hw1: u16,
    rn: u32,
    rm: u32 = 0,
    nzcv: u4 = 0,
    it: u8 = 0,
};

/// Rd and NZCV afterwards.
pub const Out = struct {
    rd: u32,
    nzcv: u4,
};

const V = vector.Vector(In, Out);
const group = "add_sub";

const n: u4 = 0b1000;
const z: u4 = 0b0100;
const c: u4 = 0b0010;
const v: u4 = 0b0001;

pub const all = [_]V{
    .{ .encoding = group, .name = "adds r0, r1, r2: signed overflow", .input = .{ .hw1 = 0x1888, .rn = 0x7FFF_FFFF, .rm = 1 }, .expect = .{ .rd = 0x8000_0000, .nzcv = n | v } },
    .{ .encoding = group, .name = "adds r0, r1, r2: unsigned wrap", .input = .{ .hw1 = 0x1888, .rn = 0xFFFF_FFFF, .rm = 1 }, .expect = .{ .rd = 0, .nzcv = z | c } },
    .{ .encoding = group, .name = "adds r0, r1, r2: both", .input = .{ .hw1 = 0x1888, .rn = 0x8000_0000, .rm = 0x8000_0000 }, .expect = .{ .rd = 0, .nzcv = z | c | v } },
    .{ .encoding = group, .name = "adds r1, r1, r2: Rd is Rn", .input = .{ .hw1 = 0x1889, .rn = 1, .rm = 2, .nzcv = n | z | c | v }, .expect = .{ .rd = 3, .nzcv = 0 } },
    .{ .encoding = group, .name = "subs r0, r1, r2: equal sets Z and C", .input = .{ .hw1 = 0x1A88, .rn = 5, .rm = 5 }, .expect = .{ .rd = 0, .nzcv = z | c } },
    .{ .encoding = group, .name = "subs r0, r1, r2: borrow clears C", .input = .{ .hw1 = 0x1A88, .rn = 0, .rm = 1, .nzcv = c }, .expect = .{ .rd = 0xFFFF_FFFF, .nzcv = n } },
    .{ .encoding = group, .name = "subs r0, r1, r2: signed overflow", .input = .{ .hw1 = 0x1A88, .rn = 0x8000_0000, .rm = 1 }, .expect = .{ .rd = 0x7FFF_FFFF, .nzcv = c | v } },
    .{ .encoding = group, .name = "adds r0, r1, #7: carry out", .input = .{ .hw1 = 0x1DC8, .rn = 0xFFFF_FFFA }, .expect = .{ .rd = 1, .nzcv = c } },
    .{ .encoding = group, .name = "subs r0, r1, #1: from zero", .input = .{ .hw1 = 0x1E48, .rn = 0 }, .expect = .{ .rd = 0xFFFF_FFFF, .nzcv = n } },
    .{ .encoding = group, .name = "movs r0, #0x80: C and V kept", .input = .{ .hw1 = 0x2080, .rn = 0x1234_5678, .nzcv = n | z | c | v }, .expect = .{ .rd = 0x80, .nzcv = c | v } },
    .{ .encoding = group, .name = "movs r0, #0: Z set", .input = .{ .hw1 = 0x2000, .rn = 7, .nzcv = n }, .expect = .{ .rd = 0, .nzcv = z } },
    .{ .encoding = group, .name = "cmp r0, #1: equal, Rdn untouched", .input = .{ .hw1 = 0x2801, .rn = 1 }, .expect = .{ .rd = 1, .nzcv = z | c } },
    .{ .encoding = group, .name = "cmp r0, #2 in an IT block still sets flags", .input = .{ .hw1 = 0x2802, .rn = 1, .nzcv = z, .it = 0x08 }, .expect = .{ .rd = 1, .nzcv = n } },
    .{ .encoding = group, .name = "adds r0, #0xFF: wraps to zero", .input = .{ .hw1 = 0x30FF, .rn = 0xFFFF_FF01 }, .expect = .{ .rd = 0, .nzcv = z | c } },
    .{ .encoding = group, .name = "subs r0, #1: signed overflow", .input = .{ .hw1 = 0x3801, .rn = 0x8000_0000 }, .expect = .{ .rd = 0x7FFF_FFFF, .nzcv = c | v } },
    .{ .encoding = group, .name = "adds r3, #1 targets Rdn", .input = .{ .hw1 = 0x3301, .rn = 41 }, .expect = .{ .rd = 42, .nzcv = 0 } },
    .{ .encoding = group, .name = "add in an IT block leaves NZCV", .input = .{ .hw1 = 0x1888, .rn = 0x7FFF_FFFF, .rm = 1, .nzcv = z, .it = 0x08 }, .expect = .{ .rd = 0x8000_0000, .nzcv = z } },
    .{ .encoding = group, .name = "mov imm8 in an IT block leaves NZCV", .input = .{ .hw1 = 0x2000, .rn = 7, .nzcv = n | v, .it = 0x08 }, .expect = .{ .rd = 0, .nzcv = n | v } },
};

pub const covered = vector.encodingsOf(In, Out, &all);
