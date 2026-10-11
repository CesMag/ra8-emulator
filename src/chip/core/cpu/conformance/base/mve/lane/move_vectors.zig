//! Conformance vectors for the decode group `mve.lane.move` (RA8EMU-278):
//! VMOV.<size> Qd[x], Rt and VMOV.<dt> Rt, Qn[x]. Expected values are worked
//! from the Arm ARM (DDI0553) scalar-move pseudocode: the lane is Dd[x],
//! with opc1:opc2 giving byte (1xxx), half (0xx1) or word (0x00) and the
//! index; reads sign-extend unless U is set. The moves are not predicated
//! and leave a VPT block alone, and a lane in a beat EPSR.ECI marks done
//! is not moved (QEMU's mve_skip_vmov). Byte k of Si starts as
//! {C4, D3, E2, F1}[k] + i (mod 256), so low registers read negative and
//! S16 up mix signs. `q` is the Q register holding the lane and `rt` is Rt
//! afterwards. U with a word, opc1:opc2 = 0x10, D or N set, Rt of SP or
//! PC, other fixed bits and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

const base = [4]u8{ 0xC4, 0xD3, 0xE2, 0xF1 };

/// Si's starting value.
pub fn bankAt(i: u5) u32 {
    var w: u32 = 0;
    for (base, 0..) |b, k| w |= @as(u32, b +% @as(u8, i)) << @intCast(8 * k);
    return w;
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
    rt: u32 = 0x1234_5678,
    vpr: u32 = 0,
    it: u8 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    q: u128,
    rt: u32 = 0x1234_5678,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_lane_move";
pub const none: Out = .{ .claimed = false, .q = 0, .rt = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = to_core ++ to_lane ++ beats ++ unclaimed;

const to_core = [_]V{
    vec("vmov.32 r0, q0[0]", .{ .hw1 = 0xEE10, .hw2 = 0x0B10 }, .{ .q = qAt(0), .rt = 0xF1E2_D3C4 }),
    vec("vmov.32 r1, q0[3] through d1[1]", .{ .hw1 = 0xEE31, .hw2 = 0x1B10 }, .{ .q = qAt(0), .rt = 0xF4E5_D6C7 }),
    vec("vmov.s16 r2, q1[5] sign-extends", .{ .hw1 = 0xEE13, .hw2 = 0x2B70 }, .{ .q = qAt(1), .rt = 0xFFFF_F7E8 }),
    vec("vmov.u16 r2, q1[5] zero-extends", .{ .hw1 = 0xEE93, .hw2 = 0x2B70 }, .{ .q = qAt(1), .rt = 0x0000_F7E8 }),
    vec("vmov.s8 r3, q4[15] of a positive byte", .{ .hw1 = 0xEE79, .hw2 = 0x3B70 }, .{ .q = qAt(4), .rt = 0x0000_0004 }),
    vec("vmov.s8 r4, q4[0] sign-extends", .{ .hw1 = 0xEE58, .hw2 = 0x4B10 }, .{ .q = qAt(4), .rt = 0xFFFF_FFD4 }),
    vec("vmov.u8 r4, q4[0] zero-extends", .{ .hw1 = 0xEED8, .hw2 = 0x4B10 }, .{ .q = qAt(4), .rt = 0x0000_00D4 }),
    vec("vmov.s16 lr, q4[1] of a positive half", .{ .hw1 = 0xEE18, .hw2 = 0xEB70 }, .{ .q = qAt(4), .rt = 0x0000_01F2 }),
};

const to_lane = [_]V{
    vec("vmov.32 q0[2], r5", .{ .hw1 = 0xEE01, .hw2 = 0x5B10 }, .{ .q = 0xF4E5D6C7_12345678_F2E3D4C5_F1E2D3C4 }),
    vec("vmov.16 q7[7], r6 takes the low half", .{ .hw1 = 0xEE2F, .hw2 = 0x6B70, .rt = 0xABCD_1234 }, .{ .q = 0x1234F2E3_0F00F1E2_0EFFF0E1_0DFEEFE0, .rt = 0xABCD_1234 }),
    vec("vmov.8 q2[9], r7 takes the low byte", .{ .hw1 = 0xEE45, .hw2 = 0x7B30, .rt = 0xFFFF_FF99 }, .{ .q = 0xFCEDDECF_FBEC99CE_FAEBDCCD_F9EADBCC, .rt = 0xFFFF_FF99 }),
    vec("vmov.32 q0[0], r12", .{ .hw1 = 0xEE00, .hw2 = 0xCB10, .rt = 0 }, .{ .q = 0xF4E5D6C7_F3E4D5C6_F2E3D4C5_00000000, .rt = 0 }),
};

const beats = [_]V{
    vec("eci a0 skips a lane in beat 0", .{ .hw1 = 0xEE00, .hw2 = 0x5B10, .it = 0x10 }, .{ .q = qAt(0) }),
    vec("eci a0a1 still moves a lane in beat 2", .{ .hw1 = 0xEE01, .hw2 = 0x5B10, .it = 0x20 }, .{ .q = 0xF4E5D6C7_12345678_F2E3D4C5_F1E2D3C4 }),
    vec("eci a0 leaves rt when reading beat 0", .{ .hw1 = 0xEE10, .hw2 = 0x0B10, .it = 0x10 }, .{ .q = qAt(0) }),
    vec("eci a0a1a2 still reads beat 3", .{ .hw1 = 0xEE31, .hw2 = 0x1B10, .it = 0x40 }, .{ .q = qAt(0), .rt = 0xF4E5_D6C7 }),
    vec("a vpt block is neither applied nor advanced", .{ .hw1 = 0xEE10, .hw2 = 0x0B10, .vpr = 0x0088_0000 }, .{ .q = qAt(0), .rt = 0xF1E2_D3C4, .vpr = 0x0088_0000 }),
};

const unclaimed = [_]V{
    vec("u with a word is unclaimed", .{ .hw1 = 0xEE90, .hw2 = 0x0B10 }, none),
    vec("opc1:opc2 = 0:10 is unclaimed", .{ .hw1 = 0xEE10, .hw2 = 0x0B50 }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEE10, .hw2 = 0x0B90 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEE80, .hw2 = 0x0B10 }, none),
    vec("rt = sp is unclaimed", .{ .hw1 = 0xEE10, .hw2 = 0xDB10 }, none),
    vec("rt = pc is unclaimed", .{ .hw1 = 0xEE00, .hw2 = 0xFB10 }, none),
    vec("hw2[11:8] = 1010 is unclaimed", .{ .hw1 = 0xEE10, .hw2 = 0x0A10 }, none),
    vec("hw2[4] clear is unclaimed", .{ .hw1 = 0xEE10, .hw2 = 0x0B00 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE10, .hw2 = 0x0B10, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
