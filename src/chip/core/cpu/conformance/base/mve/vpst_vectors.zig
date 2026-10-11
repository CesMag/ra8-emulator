//! Conformance vectors for the decode group `mve.vpst` (RA8EMU-278).
//! Expected values are worked from the Arm ARM (DDI0553) VPST pseudocode:
//! the 4-bit mask M:hw2[15:13] goes into VPR.MASK01 and VPR.MASK23 and P0
//! is left as it stands. Resumed from an exception (EPSR.ECI), MASK01 is
//! written on beat 1 and MASK23 on beat 3, so a beat already done keeps
//! its old mask, and the instruction retires its ECI state. `vpr` packs
//! P0 in bits 15:0, MASK01 in 19:16 and MASK23 in 23:20; `it` is the IT
//! byte (ECI in its high nibble). A zero mask, other hw2[12:0] or hw1
//! values and the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

pub const In = struct {
    hw1: u16 = 0xFE31,
    hw2: u16,
    size: u8 = 4,
    vpr: u32 = 0x0000_00FF,
    it: u8 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    vpr: u32,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_vpst";
pub const none: Out = .{ .claimed = false, .vpr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = masks ++ resumed ++ unclaimed;

const masks = [_]V{
    vec("vpst mask 1000 (t)", .{ .hw1 = 0xFE71, .hw2 = 0x0F4D }, .{ .vpr = 0x0088_00FF }),
    vec("vpst mask 0100 (tt)", .{ .hw2 = 0x8F4D }, .{ .vpr = 0x0044_00FF }),
    vec("vpst mask 0010", .{ .hw2 = 0x4F4D }, .{ .vpr = 0x0022_00FF }),
    vec("vpst mask 0001 (four instructions)", .{ .hw2 = 0x2F4D }, .{ .vpr = 0x0011_00FF }),
    vec("vpst mask 1100", .{ .hw1 = 0xFE71, .hw2 = 0x8F4D }, .{ .vpr = 0x00CC_00FF }),
    vec("vpst mask 1111", .{ .hw1 = 0xFE71, .hw2 = 0xEF4D }, .{ .vpr = 0x00FF_00FF }),
    vec("vpst leaves p0 alone", .{ .hw2 = 0x4F4D, .vpr = 0x0000_ABCD }, .{ .vpr = 0x0022_ABCD }),
    vec("vpst replaces an open block's masks", .{ .hw1 = 0xFE71, .hw2 = 0x0F4D, .vpr = 0x0022_1234 }, .{ .vpr = 0x0088_1234 }),
};

const resumed = [_]V{
    vec("eci a0 still writes both masks", .{ .hw1 = 0xFE71, .hw2 = 0x0F4D, .vpr = 0x0055_00FF, .it = 0x10 }, .{ .vpr = 0x0088_00FF }),
    vec("eci a0a1 keeps mask01", .{ .hw1 = 0xFE71, .hw2 = 0x0F4D, .vpr = 0x0055_00FF, .it = 0x20 }, .{ .vpr = 0x0085_00FF }),
    vec("eci a0a1a2 keeps mask01", .{ .hw1 = 0xFE71, .hw2 = 0x0F4D, .vpr = 0x0055_00FF, .it = 0x40 }, .{ .vpr = 0x0085_00FF }),
};

const unclaimed = [_]V{
    vec("a zero mask is unclaimed", .{ .hw2 = 0x0F4D }, none),
    vec("hw2[12:0] 0x0f4c is unclaimed", .{ .hw2 = 0x8F4C }, none),
    vec("hw2[12:0] 0x0f0d is unclaimed", .{ .hw2 = 0x8F0D }, none),
    vec("hw1 0xfe30 is unclaimed", .{ .hw1 = 0xFE30, .hw2 = 0x8F4D }, none),
    vec("hw1 0xee31 is unclaimed", .{ .hw1 = 0xEE31, .hw2 = 0x8F4D }, none),
    vec("the 16-bit space is unclaimed", .{ .hw2 = 0x8F4D, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
