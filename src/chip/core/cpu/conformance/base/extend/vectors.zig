//! Conformance vectors for the decode group `extend` (RA8EMU-279): 16-bit
//! SXTH, SXTB, UXTH and UXTB (T1). Each expected value is worked from the
//! Arm ARM (DDI0553): SignExtend or ZeroExtend of Rm<15:0> or Rm<7:0> with
//! no rotation, and NZCV untouched.
const vector = @import("../../vector.zig");

/// The instruction, the value in Rm ([5:3]) and NZCV beforehand.
pub const In = struct {
    hw1: u16,
    rm: u32,
    nzcv: u4 = 0,
};

/// Rd ([2:0]) and NZCV afterwards.
pub const Out = struct {
    rd: u32,
    nzcv: u4,
};

const V = vector.Vector(In, Out);
const group = "extend";

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("sxth r0, r1: negative halfword", .{ .hw1 = 0xB208, .rm = 0x0000_8001 }, .{ .rd = 0xFFFF_8001, .nzcv = 0 }),
    vec("sxth r0, r1: top half dropped", .{ .hw1 = 0xB208, .rm = 0xABCD_7FFF, .nzcv = 0xF }, .{ .rd = 0x0000_7FFF, .nzcv = 0xF }),
    vec("sxtb r0, r1: negative byte", .{ .hw1 = 0xB248, .rm = 0x0000_0080 }, .{ .rd = 0xFFFF_FF80, .nzcv = 0 }),
    vec("sxtb r0, r1: positive byte", .{ .hw1 = 0xB248, .rm = 0xFFFF_FF7F }, .{ .rd = 0x0000_007F, .nzcv = 0 }),
    vec("uxth r0, r1", .{ .hw1 = 0xB288, .rm = 0xFFFF_8001, .nzcv = 0x8 }, .{ .rd = 0x0000_8001, .nzcv = 0x8 }),
    vec("uxtb r0, r1", .{ .hw1 = 0xB2C8, .rm = 0xFFFF_FF80 }, .{ .rd = 0x0000_0080, .nzcv = 0 }),
    vec("sxtb r1, r1: Rd is Rm", .{ .hw1 = 0xB249, .rm = 0x0000_00FF }, .{ .rd = 0xFFFF_FFFF, .nzcv = 0 }),
};

pub const covered = vector.encodingsOf(In, Out, &all);
