//! Conformance vectors for the decode group `mve_vdup` (RA8EMU-278).
//! Expected values are worked from the Arm ARM (DDI0553) VDUP pseudocode:
//! every element of Qd takes the low 32, 16 or 8 bits of Rt (B:E = 00, 01,
//! 10), written byte by byte under the predicate in force (VPT P0, the
//! tail of a tail-predicated loop, and the beats EPSR.ECI leaves to run),
//! and the VPT block then advances. Q registers start as S[4n..4n+3] with
//! Si = 0x5A00_0001 + i * 0x0101. B:E = 11, Rt = SP or PC, other fixed
//! bits and the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

/// Si's starting value.
pub fn bankAt(i: u5) u32 {
    return 0x5A00_0001 + @as(u32, i) * 0x0101;
}

/// Qn's starting value.
pub fn qAt(n: u3) u128 {
    var q: u128 = 0;
    var k: u5 = 4;
    while (k > 0) : (k -= 1) q = q << 32 | bankAt(@as(u5, n) * 4 + (k - 1));
    return q;
}

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The value put in the Rt the encoding names.
    rt: u32 = 0x1234_5678,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    q: u128,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_vdup";
pub const none: Out = .{ .claimed = false, .q = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = sizes ++ predicated ++ unclaimed;

const sizes = [_]V{
    vec("vdup.32 q0, r1", .{ .hw1 = 0xEEA0, .hw2 = 0x1B10 }, .{ .q = 0x12345678_12345678_12345678_12345678 }),
    vec("vdup.16 q1, r2 takes the low half", .{ .hw1 = 0xEEA2, .hw2 = 0x2B30, .rt = 0xABCD_1234 }, .{ .q = 0x1234_1234_1234_1234_1234_1234_1234_1234 }),
    vec("vdup.8 q7, r0 takes the low byte", .{ .hw1 = 0xEEEE, .hw2 = 0x0B10, .rt = 0xFFFF_FFA5 }, .{ .q = 0xA5A5A5A5_A5A5A5A5_A5A5A5A5_A5A5A5A5 }),
    vec("vdup.32 q0, lr", .{ .hw1 = 0xEEA0, .hw2 = 0xEB10, .rt = 0x8000_0001 }, .{ .q = 0x80000001_80000001_80000001_80000001 }),
    vec("vdup.16 q3, r12", .{ .hw1 = 0xEEA6, .hw2 = 0xCB30, .rt = 0x0000_FFFF }, .{ .q = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF }),
};

const predicated = [_]V{
    vec("vpt p0 0x00ff writes the low beats and ends the block", .{ .hw1 = 0xEEA0, .hw2 = 0x1B10, .vpr = 0x0088_00FF }, .{ .q = 0x5A000304_5A000203_12345678_12345678, .vpr = 0x0000_00FF }),
    vec("vpt p0 0x5555 predicates byte by byte", .{ .hw1 = 0xEEE0, .hw2 = 0x0B10, .rt = 0xA5, .vpr = 0x0088_5555 }, .{ .q = 0x5AA503A5_5AA502A5_5AA501A5_5AA500A5, .vpr = 0x0000_5555 }),
    vec("vpt mask 1100 writes then inverts for the else", .{ .hw1 = 0xEEA0, .hw2 = 0x1B10, .vpr = 0x00CC_00FF }, .{ .q = 0x5A000304_5A000203_12345678_12345678, .vpr = 0x0088_FF00 }),
    vec("the loop tail leaves later elements", .{ .hw1 = 0xEEA0, .hw2 = 0x1B10, .ltpsize = 2, .lr = 1 }, .{ .q = 0x5A000304_5A000203_5A000102_12345678 }),
    vec("eci a0a1 keeps the done beats", .{ .hw1 = 0xEEA0, .hw2 = 0x1B10, .it = 0x20 }, .{ .q = 0x12345678_12345678_5A000102_5A000001 }),
};

const unclaimed = [_]V{
    vec("b:e = 11 is unclaimed", .{ .hw1 = 0xEEE0, .hw2 = 0x1B30 }, none),
    vec("rt = sp is unclaimed", .{ .hw1 = 0xEEA0, .hw2 = 0xDB10 }, none),
    vec("rt = pc is unclaimed", .{ .hw1 = 0xEEA0, .hw2 = 0xFB10 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEEA1, .hw2 = 0x1B10 }, none),
    vec("hw1[5] clear is unclaimed", .{ .hw1 = 0xEE80, .hw2 = 0x1B10 }, none),
    vec("hw2[4] clear is unclaimed", .{ .hw1 = 0xEEA0, .hw2 = 0x1B00 }, none),
    vec("hw2[11:8] = 1010 is unclaimed", .{ .hw1 = 0xEEA0, .hw2 = 0x1A10 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEA0, .hw2 = 0x1B10, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
