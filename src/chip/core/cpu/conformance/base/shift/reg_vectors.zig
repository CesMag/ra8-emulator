//! Conformance vectors for the decode group `shift_reg` (RA8EMU-280): LSL,
//! LSR, ASR and ROR by a register, 32-bit (T2). Expected values are worked
//! from the Arm ARM (DDI0553) Shift_C: the amount is Rm[7:0]; with S set N
//! and Z follow the result and C is the last bit shifted out, unchanged for
//! an amount of 0; V is never touched. LSL/LSR of 32 leave 0 with C the
//! last bit out, beyond 32 C is 0; ASR of 32 or more fills with the sign;
//! ROR uses the amount mod 32 and C is result[31]. SP or PC in any field is
//! UNPREDICTABLE and left unclaimed, as are the neighbouring spaces.
const vector = @import("../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rn and Rm before the instruction (Rm is written second).
    n: u32 = 0,
    m: u32 = 0,
    /// NZCV before the instruction: V alone unless a vector says otherwise.
    flags: u32 = v,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = v,
};

const V = vector.Vector(In, Out);
const group = "shift_reg";
const none: Out = .{ .claimed = false, .flags = 0 };

const n_bit: u32 = 0x8000_0000;
const z: u32 = 0x4000_0000;
const c: u32 = 0x2000_0000;
const v: u32 = 0x1000_0000;

/// The four shifts on r0, r1, r2, without and with S.
const lsl = 0xFA01;
const lsls = 0xFA11;
const lsr = 0xFA21;
const lsrs = 0xFA31;
const asr = 0xFA41;
const asrs = 0xFA51;
const ror = 0xFA61;
const rors = 0xFA71;
const r0_r2 = 0xF002;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw1: u16, n: u32, m: u32) In {
    return .{ .hw1 = hw1, .hw2 = r0_r2, .n = n, .m = m };
}

pub const all = [_]V{
    vec("lsl by 4", in(lsl, 1, 4), .{ .rd = 0x10 }),
    vec("lsl uses only Rm[7:0]", in(lsl, 1, 0x104), .{ .rd = 0x10 }),
    vec("lsls by 1 carries out bit 31", in(lsls, 0x8000_0001, 1), .{ .rd = 2, .flags = c | v }),
    vec("lsls by 32 leaves 0 and carries bit 0", in(lsls, 1, 32), .{ .rd = 0, .flags = z | c | v }),
    vec("lsls by 33 leaves 0 and clears C", in(lsls, 0xFFFF_FFFF, 33), .{ .rd = 0, .flags = z | v }),
    vec("lsls by 0 keeps C", .{ .hw1 = lsls, .hw2 = r0_r2, .n = 0x8000_0000, .flags = c | v }, .{ .rd = 0x8000_0000, .flags = n_bit | c | v }),
    vec("lsr by 4", in(lsr, 0x80, 4), .{ .rd = 8 }),
    vec("lsrs by 1 carries out bit 0", in(lsrs, 0x8000_0001, 1), .{ .rd = 0x4000_0000, .flags = c | v }),
    vec("lsrs by 32 carries bit 31", in(lsrs, 0x8000_0000, 32), .{ .rd = 0, .flags = z | c | v }),
    vec("lsrs by 200 leaves 0 and clears C", in(lsrs, 0xFFFF_FFFF, 200), .{ .rd = 0, .flags = z | v }),
    vec("asr keeps the sign", in(asr, 0x8000_0010, 4), .{ .rd = 0xF800_0001 }),
    vec("asrs by 4", in(asrs, 0x8000_0000, 4), .{ .rd = 0xF800_0000, .flags = n_bit | v }),
    vec("asrs by 32 fills with the sign", in(asrs, 0x8000_0000, 32), .{ .rd = 0xFFFF_FFFF, .flags = n_bit | c | v }),
    vec("asrs by 255 of a positive value", in(asrs, 0x7FFF_FFFF, 255), .{ .rd = 0, .flags = z | v }),
    vec("ror by 8", in(ror, 0x1234_5678, 8), .{ .rd = 0x7812_3456 }),
    vec("rors by 1 sets C from result[31]", in(rors, 1, 1), .{ .rd = 0x8000_0000, .flags = n_bit | c | v }),
    vec("rors by 32 keeps the value", in(rors, 0x8000_0001, 32), .{ .rd = 0x8000_0001, .flags = n_bit | c | v }),
    vec("rors by 36 rotates by 4", in(rors, 0xF0, 36), .{ .rd = 0x0F, .flags = v }),
    vec("lsl r12, lr, r3", .{ .hw1 = 0xFA0E, .hw2 = 0xFC03, .n = 3, .m = 2 }, .{ .rd = 12 }),
    vec("lsl r2, r1, r2 overwrites Rm", .{ .hw1 = lsl, .hw2 = 0xF202, .n = 1, .m = 3 }, .{ .rd = 8 }),
    vec("Rd of sp is unclaimed", .{ .hw1 = lsl, .hw2 = 0xFD02 }, none),
    vec("Rn of pc is unclaimed", .{ .hw1 = 0xFA0F, .hw2 = r0_r2 }, none),
    vec("Rm of sp is unclaimed", .{ .hw1 = lsl, .hw2 = 0xF00D }, none),
    vec("a nonzero hw2[7:4] is unclaimed", .{ .hw1 = lsl, .hw2 = 0xF082 }, none),
    vec("the parallel space is unclaimed", .{ .hw1 = 0xFA81, .hw2 = 0xF002 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = lsl, .hw2 = r0_r2, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
