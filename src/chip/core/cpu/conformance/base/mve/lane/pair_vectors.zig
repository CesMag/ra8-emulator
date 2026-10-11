//! Conformance vectors for the decode group `mve.lane.pair` (RA8EMU-278):
//! VMOV Qd[2+i], Qd[i], Rt, Rt2 and VMOV Rt, Rt2, Qd[2+i], Qd[i]. Expected
//! values follow the Arm ARM (DDI0553) pseudocode: Rt pairs with word lane
//! 2+i and Rt2 with lane i. Neither form is predicated or advances a VPT
//! block, and a lane in a beat EPSR.ECI marks done is not moved. Byte k of
//! Si starts as {C4, D3, E2, F1}[k] + i (mod 256); Rt starts 0x1111_1111
//! and Rt2 0x2222_2222 (Rt2 last when they are the same register). Rt or
//! Rt2 of SP or PC, the same register twice into the core, other fixed
//! bits and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

const base = [4]u8{ 0xC4, 0xD3, 0xE2, 0xF1 };

pub fn bankAt(i: u5) u32 {
    var w: u32 = 0;
    for (base, 0..) |b, k| w |= @as(u32, b +% @as(u8, i)) << @intCast(8 * k);
    return w;
}

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
    vpr: u32 = 0,
    it: u8 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    q: u128,
    rt: u32 = 0x1111_1111,
    rt2: u32 = 0x2222_2222,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_lane_pair";
pub const none: Out = .{ .claimed = false, .q = 0, .rt = 0, .rt2 = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = to_core ++ to_vector ++ beats ++ unclaimed;

const to_core = [_]V{
    vec("vmov r0, r1, q0[2], q0[0]", .{ .hw1 = 0xEC01, .hw2 = 0x0F00 }, .{ .q = qAt(0), .rt = 0xF3E4_D5C6, .rt2 = 0xF1E2_D3C4 }),
    vec("vmov r2, r3, q1[3], q1[1]", .{ .hw1 = 0xEC03, .hw2 = 0x2F12 }, .{ .q = qAt(1), .rt = 0xF8E9_DACB, .rt2 = 0xF6E7_D8C9 }),
    vec("vmov lr, r12, q7[2], q7[0]", .{ .hw1 = 0xEC0C, .hw2 = 0xEF0E }, .{ .q = qAt(7), .rt = 0x0F00_F1E2, .rt2 = 0x0DFE_EFE0 }),
};

const to_vector = [_]V{
    vec("vmov q0[2], q0[0], r0, r1", .{ .hw1 = 0xEC11, .hw2 = 0x0F00 }, .{ .q = 0xF4E5D6C7_11111111_F2E3D4C5_22222222 }),
    vec("vmov q7[3], q7[1], r5, r6", .{ .hw1 = 0xEC16, .hw2 = 0xEF15 }, .{ .q = 0x11111111_0F00F1E2_22222222_0DFEEFE0 }),
    vec("vmov q0[2], q0[0], r4, r4 writes r4 twice", .{ .hw1 = 0xEC14, .hw2 = 0x0F04 }, .{ .q = 0xF4E5D6C7_22222222_F2E3D4C5_22222222, .rt = 0x2222_2222 }),
};

const beats = [_]V{
    vec("eci a0 keeps lane 0 and writes lane 2", .{ .hw1 = 0xEC11, .hw2 = 0x0F00, .it = 0x10 }, .{ .q = 0xF4E5D6C7_11111111_F2E3D4C5_F1E2D3C4 }),
    vec("eci a0a1a2 writes lane 3 only", .{ .hw1 = 0xEC11, .hw2 = 0x0F10, .it = 0x40 }, .{ .q = 0x11111111_F3E4D5C6_F2E3D4C5_F1E2D3C4 }),
    vec("eci a0a1 reads lane 2 and leaves rt2", .{ .hw1 = 0xEC01, .hw2 = 0x0F00, .it = 0x20 }, .{ .q = qAt(0), .rt = 0xF3E4_D5C6 }),
    vec("a vpt block is neither applied nor advanced", .{ .hw1 = 0xEC01, .hw2 = 0x0F00, .vpr = 0x0088_0000 }, .{ .q = qAt(0), .rt = 0xF3E4_D5C6, .rt2 = 0xF1E2_D3C4, .vpr = 0x0088_0000 }),
};

const unclaimed = [_]V{
    vec("the same register twice into the core is unclaimed", .{ .hw1 = 0xEC00, .hw2 = 0x0F00 }, none),
    vec("rt = sp is unclaimed", .{ .hw1 = 0xEC01, .hw2 = 0x0F0D }, none),
    vec("rt2 = pc is unclaimed", .{ .hw1 = 0xEC0F, .hw2 = 0x0F00 }, none),
    vec("rt2 = sp into the vector is unclaimed", .{ .hw1 = 0xEC1D, .hw2 = 0x0F00 }, none),
    vec("hw1[5] set is unclaimed", .{ .hw1 = 0xEC21, .hw2 = 0x0F00 }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xEC01, .hw2 = 0x1F00 }, none),
    vec("hw2[5] set is unclaimed", .{ .hw1 = 0xEC01, .hw2 = 0x0F20 }, none),
    vec("hw2[11:8] = 1110 is unclaimed", .{ .hw1 = 0xEC01, .hw2 = 0x0E00 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEC01, .hw2 = 0x0F00, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
