//! Conformance vectors for the decode group `mve.bitwise` (RA8EMU-630):
//! VAND, VBIC (register), VORR (register), VORN and VEOR T1. Expected values
//! are worked from the Arm ARM (DDI0553) pseudocode: each result is the
//! bitwise op of Qn and Qm over all 128 bits. Results merge byte by byte
//! under the VPT mask, the loop tail and the beats EPSR.ECI marks done.
//! U with sz != 0, D/N/M set and fixed bits flipped are left unclaimed.
const vector = @import("../../vector.zig");
const mve_int = @import("int/vectors.zig");

pub const In = mve_int.In;
pub const Out = mve_int.Out;

const V = vector.Vector(In, Out);
const group = "mve_bitwise";
pub const none = mve_int.none;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

const qd: u128 = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF;
const qn: u128 = 0x12345678_FFFFFFFF_80000000_7FFFFFFF;
const qm: u128 = 0x87654321_00000002_80000000_00000001;

fn on(hw1: u16, hw2: u16) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .qd = qd, .qn = qn, .qm = qm };
}

pub const all = ops ++ predicated ++ unclaimed;

const ops = [_]V{
    vec("vand q0, q1, q2", on(0xEF02, 0x0154), .{ .qd = 0x02244220_00000002_80000000_00000001 }),
    vec("vbic q0, q1, q2", on(0xEF12, 0x0154), .{ .qd = 0x10101458_FFFFFFFD_00000000_7FFFFFFE }),
    vec("vorr q0, q1, q2", on(0xEF22, 0x0154), .{ .qd = 0x97755779_FFFFFFFF_80000000_7FFFFFFF }),
    vec("vorn q0, q1, q2", on(0xEF32, 0x0154), .{ .qd = 0x7ABEFEFE_FFFFFFFF_FFFFFFFF_FFFFFFFF }),
    vec("veor q0, q1, q2", on(0xFF02, 0x0154), .{ .qd = 0x95511559_FFFFFFFD_00000000_7FFFFFFE }),
    vec("vmov q4, q1 copies", .{ .hw1 = 0xEF22, .hw2 = 0x8152, .qd = qd, .qn = qn, .qm = qn }, .{ .qd = qn }),
    vec("veor q7, q6, q6 clears", .{ .hw1 = 0xFF0C, .hw2 = 0xE15C, .qd = qd, .qn = qn, .qm = qn }, .{ .qd = 0 }),
};

const predicated = [_]V{
    vec("vpt p0 0xff00 writes the high half and ends the block", .{ .hw1 = 0xFF02, .hw2 = 0x0154, .qd = qd, .qn = qn, .qm = qm, .vpr = 0x0088FF00 }, .{ .qd = 0x95511559_FFFFFFFD_01234567_89ABCDEF, .vpr = 0x0000FF00 }),
    vec("the loop tail writes the first bytes", .{ .hw1 = 0xEF22, .hw2 = 0x0154, .qd = qd, .qn = qn, .qm = qm, .ltpsize = 0, .lr = 5 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234500_7FFFFFFF }),
    vec("eci a0a1a2b0 hands beat 0 of the next instruction on", .{ .hw1 = 0xEF02, .hw2 = 0x0154, .qd = qd, .qn = qn, .qm = qm, .it = 0x50 }, .{ .qd = 0x02244220_CAFEF00D_01234567_89ABCDEF, .it = 0x10 }),
};

const unclaimed = [_]V{
    vec("u with sz 01 is unclaimed", .{ .hw1 = 0xFF12, .hw2 = 0x0154 }, none),
    vec("u with sz 10 is unclaimed", .{ .hw1 = 0xFF22, .hw2 = 0x0154 }, none),
    vec("u with sz 11 is unclaimed", .{ .hw1 = 0xFF32, .hw2 = 0x0154 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEF62, .hw2 = 0x0154 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEF23, .hw2 = 0x0154 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x01D4 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0174 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0155 }, none),
    vec("hw2[4] clear is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0144 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF22, .hw2 = 0x0154, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
