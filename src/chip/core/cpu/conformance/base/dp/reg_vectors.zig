//! Conformance vectors for the decode group `dp.reg` (RA8EMU-279): the
//! 16-bit data-processing register block, AND to MVN (T1). Each expected
//! value is worked from the Arm ARM (DDI0553): Shift_C() with the amount
//! taken from Rm[7:0] (zero keeps C, LSL/LSR by 32 carry out bit 0/31 and
//! past 32 carry nothing, ROR by a multiple of 32 carries bit 31),
//! AddWithCarry() for ADC, SBC, RSB, CMP and CMN, logical ops and MUL
//! keeping C and V, and TST/CMP/CMN setting flags even in an IT block.
const vector = @import("../../vector.zig");

/// The instruction, the values in Rdn ([2:0]) and Rm ([5:3]), and NZCV and
/// ITSTATE beforehand.
pub const In = struct {
    hw1: u16,
    rdn: u32,
    rm: u32,
    nzcv: u4 = 0,
    it: u8 = 0,
};

/// Rdn and NZCV afterwards.
pub const Out = struct {
    rd: u32,
    nzcv: u4,
};

const V = vector.Vector(In, Out);
const group = "dp_reg";

const n: u4 = 0b1000;
const z: u4 = 0b0100;
const c: u4 = 0b0010;
const v: u4 = 0b0001;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("ands keeps C and V", .{ .hw1 = 0x4008, .rdn = 0xF0F0_F0F0, .rm = 0x8000_00FF, .nzcv = c | v }, .{ .rd = 0x8000_00F0, .nzcv = n | c | v }),
    vec("ands to zero", .{ .hw1 = 0x4008, .rdn = 0x0F, .rm = 0xF0, .nzcv = n }, .{ .rd = 0, .nzcv = z }),
    vec("eors", .{ .hw1 = 0x4048, .rdn = 0xFFFF_0000, .rm = 0xFFFF_FFFF }, .{ .rd = 0x0000_FFFF, .nzcv = 0 }),
    vec("lsls by Rm[7:0] = 0 keeps C", .{ .hw1 = 0x4088, .rdn = 0x8000_0000, .rm = 0x100, .nzcv = c }, .{ .rd = 0x8000_0000, .nzcv = n | c }),
    vec("lsls by 1", .{ .hw1 = 0x4088, .rdn = 0x8000_0001, .rm = 1 }, .{ .rd = 2, .nzcv = c }),
    vec("lsls by 32 carries bit 0", .{ .hw1 = 0x4088, .rdn = 1, .rm = 32 }, .{ .rd = 0, .nzcv = z | c }),
    vec("lsls by 33 carries nothing", .{ .hw1 = 0x4088, .rdn = 0xFFFF_FFFF, .rm = 33, .nzcv = c }, .{ .rd = 0, .nzcv = z }),
    vec("lsrs by 32 carries bit 31", .{ .hw1 = 0x40C8, .rdn = 0x8000_0000, .rm = 32 }, .{ .rd = 0, .nzcv = z | c }),
    vec("lsrs by 4", .{ .hw1 = 0x40C8, .rdn = 0xF8, .rm = 4 }, .{ .rd = 0xF, .nzcv = c }),
    vec("asrs by 40 fills with the sign", .{ .hw1 = 0x4108, .rdn = 0x8000_0000, .rm = 40 }, .{ .rd = 0xFFFF_FFFF, .nzcv = n | c }),
    vec("asrs by Rm[7:0] = 0 keeps C clear", .{ .hw1 = 0x4108, .rdn = 0x8000_0000, .rm = 0x100 }, .{ .rd = 0x8000_0000, .nzcv = n }),
    vec("adcs carries in and out", .{ .hw1 = 0x4148, .rdn = 0xFFFF_FFFF, .rm = 0, .nzcv = c }, .{ .rd = 0, .nzcv = z | c }),
    vec("adcs overflows", .{ .hw1 = 0x4148, .rdn = 0x7FFF_FFFF, .rm = 0, .nzcv = c }, .{ .rd = 0x8000_0000, .nzcv = n | v }),
    vec("sbcs with C clear borrows one more", .{ .hw1 = 0x4188, .rdn = 5, .rm = 5 }, .{ .rd = 0xFFFF_FFFF, .nzcv = n }),
    vec("sbcs with C set", .{ .hw1 = 0x4188, .rdn = 5, .rm = 5, .nzcv = c }, .{ .rd = 0, .nzcv = z | c }),
    vec("rors by 4", .{ .hw1 = 0x41C8, .rdn = 0x18, .rm = 4 }, .{ .rd = 0x8000_0001, .nzcv = n | c }),
    vec("rors by 32 carries bit 31", .{ .hw1 = 0x41C8, .rdn = 0x8000_0000, .rm = 32 }, .{ .rd = 0x8000_0000, .nzcv = n | c }),
    vec("tst in an IT block sets flags, Rdn kept", .{ .hw1 = 0x4208, .rdn = 0x0F, .rm = 0xF0, .nzcv = c, .it = 0x08 }, .{ .rd = 0x0F, .nzcv = z | c }),
    vec("rsbs r0, r1, #0 of one", .{ .hw1 = 0x4248, .rdn = 0x1234, .rm = 1 }, .{ .rd = 0xFFFF_FFFF, .nzcv = n }),
    vec("rsbs r0, r1, #0 of zero", .{ .hw1 = 0x4248, .rdn = 0x1234, .rm = 0 }, .{ .rd = 0, .nzcv = z | c }),
    vec("cmp lower", .{ .hw1 = 0x4288, .rdn = 1, .rm = 2 }, .{ .rd = 1, .nzcv = n }),
    vec("cmp in an IT block sets flags", .{ .hw1 = 0x4288, .rdn = 2, .rm = 2, .it = 0x08 }, .{ .rd = 2, .nzcv = z | c }),
    vec("cmn wraps", .{ .hw1 = 0x42C8, .rdn = 0xFFFF_FFFF, .rm = 1 }, .{ .rd = 0xFFFF_FFFF, .nzcv = z | c }),
    vec("orrs", .{ .hw1 = 0x4308, .rdn = 0xF0, .rm = 0x0F }, .{ .rd = 0xFF, .nzcv = 0 }),
    vec("muls keeps C and V", .{ .hw1 = 0x4348, .rdn = 0x1_0000, .rm = 0x1_0000, .nzcv = c | v }, .{ .rd = 0, .nzcv = z | c | v }),
    vec("muls low 32 bits", .{ .hw1 = 0x4348, .rdn = 3, .rm = 0xFFFF_FFFF }, .{ .rd = 0xFFFF_FFFD, .nzcv = n }),
    vec("bics", .{ .hw1 = 0x4388, .rdn = 0xFF, .rm = 0x0F }, .{ .rd = 0xF0, .nzcv = 0 }),
    vec("mvns", .{ .hw1 = 0x43C8, .rdn = 0x1234, .rm = 0 }, .{ .rd = 0xFFFF_FFFF, .nzcv = n }),
    vec("eor in an IT block leaves NZCV", .{ .hw1 = 0x4048, .rdn = 0xFFFF_0000, .rm = 0xFFFF_FFFF, .nzcv = z, .it = 0x08 }, .{ .rd = 0x0000_FFFF, .nzcv = z }),
};

pub const covered = vector.encodingsOf(In, Out, &all);
