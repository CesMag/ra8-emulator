//! Conformance vectors for the decode group `fp_move` (RA8EMU-278): VMOV
//! between core registers and the FP bank (T1). Expected values are worked
//! from the Arm ARM (DDI0553): bits move unchanged; Sn is Vn:N, a pair
//! starts at Vm:M, Dm is M:Vm and D[m] = R[t2]:R[t], so Rt is the low word
//! (S2m) and Rt2 the high word. VMOV.F16 moves the low halfword with zeros
//! above. SP or PC as a core register, the pair from S31, D16 and up, two
//! equal destination core registers, other hw2[11:8] values and the 16-bit
//! space are left unclaimed. Only the group's own decode runs here; the FP
//! enable check sits in fp_gate.
const vector = @import("../../vector.zig");

/// Every vector starts from Ri = 0xA5A5_0000 | i * 0x1111 and
/// Si = 0x5A00_0000 | i * 0x0101.
pub fn coreAt(i: u4) u32 {
    return 0xA5A5_0000 | @as(u32, i) * 0x1111;
}
pub fn bankAt(i: u5) u32 {
    return 0x5A00_0000 | @as(u32, i) * 0x0101;
}

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The S register reported as `s_a`; `s_b` is the one above it.
    watch: u5 = 0,
};

/// Whether the group claims the encoding, R1, R2, S[watch] and S[watch+1]
/// after.
pub const Out = struct {
    claimed: bool = true,
    r1: u32 = coreAt(1),
    r2: u32 = coreAt(2),
    s_a: u32,
    s_b: u32,
};

const V = vector.Vector(In, Out);
const group = "fp_move";
pub const none: Out = .{ .claimed = false, .r1 = 0, .r2 = 0, .s_a = 0, .s_b = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

const r1 = coreAt(1);
const r2 = coreAt(2);

pub const all = single ++ half ++ pair ++ double ++ unclaimed;

const single = [_]V{
    vec("vmov s0, r1", .{ .hw1 = 0xEE00, .hw2 = 0x1A10 }, .{ .s_a = r1, .s_b = bankAt(1) }),
    vec("vmov r1, s0", .{ .hw1 = 0xEE10, .hw2 = 0x1A10 }, .{ .r1 = bankAt(0), .s_a = bankAt(0), .s_b = bankAt(1) }),
    vec("vmov s1, r1 takes N as the low bit", .{ .hw1 = 0xEE00, .hw2 = 0x1A90 }, .{ .s_a = bankAt(0), .s_b = r1 }),
    vec("vmov r1, s31", .{ .hw1 = 0xEE1F, .hw2 = 0x1A90, .watch = 30 }, .{ .r1 = bankAt(31), .s_a = bankAt(30), .s_b = bankAt(31) }),
    vec("vmov s30, r1", .{ .hw1 = 0xEE0F, .hw2 = 0x1A10, .watch = 30 }, .{ .s_a = r1, .s_b = bankAt(31) }),
    vec("vmov r2, s2", .{ .hw1 = 0xEE11, .hw2 = 0x2A10, .watch = 2 }, .{ .r2 = bankAt(2), .s_a = bankAt(2), .s_b = bankAt(3) }),
};

const half = [_]V{
    vec("vmov.f16 s0, r1 keeps the low half", .{ .hw1 = 0xEE00, .hw2 = 0x1910 }, .{ .s_a = r1 & 0xFFFF, .s_b = bankAt(1) }),
    vec("vmov.f16 r1, s3 keeps the low half", .{ .hw1 = 0xEE11, .hw2 = 0x1990, .watch = 3 }, .{ .r1 = bankAt(3) & 0xFFFF, .s_a = bankAt(3), .s_b = bankAt(4) }),
};

const pair = [_]V{
    vec("vmov s0, s1, r1, r2", .{ .hw1 = 0xEC42, .hw2 = 0x1A10 }, .{ .s_a = r1, .s_b = r2 }),
    vec("vmov r1, r2, s0, s1", .{ .hw1 = 0xEC52, .hw2 = 0x1A10 }, .{ .r1 = bankAt(0), .r2 = bankAt(1), .s_a = bankAt(0), .s_b = bankAt(1) }),
    vec("vmov s3, s4, r1, r2 takes M as the low bit", .{ .hw1 = 0xEC42, .hw2 = 0x1A31, .watch = 3 }, .{ .s_a = r1, .s_b = r2 }),
    vec("vmov r1, r2, s30, s31", .{ .hw1 = 0xEC52, .hw2 = 0x1A1F, .watch = 30 }, .{ .r1 = bankAt(30), .r2 = bankAt(31), .s_a = bankAt(30), .s_b = bankAt(31) }),
    vec("vmov s0, s1, r1, r1 writes both", .{ .hw1 = 0xEC41, .hw2 = 0x1A10 }, .{ .s_a = r1, .s_b = r1 }),
};

const double = [_]V{
    vec("vmov d0, r1, r2 puts rt low", .{ .hw1 = 0xEC42, .hw2 = 0x1B10 }, .{ .s_a = r1, .s_b = r2 }),
    vec("vmov r1, r2, d0 reads low then high", .{ .hw1 = 0xEC52, .hw2 = 0x1B10 }, .{ .r1 = bankAt(0), .r2 = bankAt(1), .s_a = bankAt(0), .s_b = bankAt(1) }),
    vec("vmov d15, r1, r2", .{ .hw1 = 0xEC42, .hw2 = 0x1B1F, .watch = 30 }, .{ .s_a = r1, .s_b = r2 }),
    vec("vmov r1, r2, d7", .{ .hw1 = 0xEC52, .hw2 = 0x1B17, .watch = 14 }, .{ .r1 = bankAt(14), .r2 = bankAt(15), .s_a = bankAt(14), .s_b = bankAt(15) }),
};

const unclaimed = [_]V{
    bad("vmov s0, sp is unclaimed", 0xEE00, 0xDA10),
    bad("vmov pc, s0 is unclaimed", 0xEE10, 0xFA10),
    bad("vmov s0, s1, r1, sp is unclaimed", 0xEC4D, 0x1A10),
    bad("vmov r1, r1, s0, s1 is unclaimed", 0xEC51, 0x1A10),
    bad("the pair from s31 is unclaimed", 0xEC42, 0x1A3F),
    bad("vmov d16, r1, r2 is unclaimed", 0xEC42, 0x1B30),
    bad("single with hw2[11:8] = 1011 is unclaimed", 0xEE00, 0x1B10),
    bad("single with hw2[11:8] = 1000 is unclaimed", 0xEE00, 0x1810),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE00, .hw2 = 0x1A10, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
