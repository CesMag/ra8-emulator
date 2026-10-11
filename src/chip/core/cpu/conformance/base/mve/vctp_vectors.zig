//! Conformance vectors for the decode group `mve_vctp` (RA8EMU-278).
//! Expected values are worked from the Arm ARM (DDI0553) VCTP pseudocode:
//! P0 gets the first Rn elements of 8 << size bits set (all of them once
//! Rn reaches the elements per vector, Rn unsigned), ANDed with the
//! predicate in force (VPT P0 and the tail of a tail-predicated loop),
//! only on the beats this instruction runs; bytes of beats EPSR.ECI says
//! already ran keep their P0 bit. VPT then advances: a mask above 0b1000
//! inverts that beat pair's P0 bits, and each mask shifts left. `vpr`
//! packs P0 [15:0], MASK01 [19:16] and MASK23 [23:20]; `it` is the IT
//! byte (ECI in its high nibble). Rn = SP or PC, other hw2 or hw1 bits
//! and the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16 = 0xE801,
    size: u8 = 4,
    /// The value put in the Rn the encoding names.
    rn: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    vpr: u32,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_vctp";
pub const none: Out = .{ .claimed = false, .vpr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = sizes ++ predicated ++ unclaimed;

const sizes = [_]V{
    vec("vctp.8 r0 = 5", .{ .hw1 = 0xF000, .rn = 5 }, .{ .vpr = 0x0000_001F }),
    vec("vctp.8 r0 = 0 clears p0", .{ .hw1 = 0xF000, .rn = 0, .vpr = 0x0000_FFFF }, .{ .vpr = 0 }),
    vec("vctp.8 r0 = 16 sets every byte", .{ .hw1 = 0xF000, .rn = 16 }, .{ .vpr = 0x0000_FFFF }),
    vec("vctp.8 r0 = 0xffffffff is unsigned", .{ .hw1 = 0xF000, .rn = 0xFFFF_FFFF }, .{ .vpr = 0x0000_FFFF }),
    vec("vctp.16 r0 = 3", .{ .hw1 = 0xF010, .rn = 3 }, .{ .vpr = 0x0000_003F }),
    vec("vctp.16 r0 = 8", .{ .hw1 = 0xF010, .rn = 8 }, .{ .vpr = 0x0000_FFFF }),
    vec("vctp.32 r0 = 1", .{ .hw1 = 0xF020, .rn = 1 }, .{ .vpr = 0x0000_000F }),
    vec("vctp.32 r0 = 3", .{ .hw1 = 0xF020, .rn = 3 }, .{ .vpr = 0x0000_0FFF }),
    vec("vctp.64 r0 = 1", .{ .hw1 = 0xF030, .rn = 1 }, .{ .vpr = 0x0000_00FF }),
    vec("vctp.64 r0 = 2", .{ .hw1 = 0xF030, .rn = 2 }, .{ .vpr = 0x0000_FFFF }),
    vec("vctp.32 r7 = 2", .{ .hw1 = 0xF027, .rn = 2 }, .{ .vpr = 0x0000_00FF }),
    vec("vctp.8 lr = 9", .{ .hw1 = 0xF00E, .rn = 9 }, .{ .vpr = 0x0000_01FF }),
};

const predicated = [_]V{
    vec("vpt mask 1000 ands p0 then ends the block", .{ .hw1 = 0xF000, .rn = 16, .vpr = 0x0088_0F0F }, .{ .vpr = 0x0000_0F0F }),
    vec("vpt mask 0100 ands p0 and shifts", .{ .hw1 = 0xF000, .rn = 4, .vpr = 0x0044_00FF }, .{ .vpr = 0x0088_000F }),
    vec("vpt mask 1100 ands then inverts for the else", .{ .hw1 = 0xF000, .rn = 16, .vpr = 0x00CC_00FF }, .{ .vpr = 0x0088_FF00 }),
    vec("the loop tail ands p0", .{ .hw1 = 0xF000, .rn = 16, .ltpsize = 0, .lr = 3 }, .{ .vpr = 0x0000_0007 }),
    vec("eci a0a1 keeps the done beats' p0", .{ .hw1 = 0xF000, .rn = 12, .vpr = 0x0000_00AA, .it = 0x20 }, .{ .vpr = 0x0000_0FAA }),
    vec("eci a0a1a2b0 runs beat 3 and leaves a0", .{ .hw1 = 0xF000, .rn = 16, .it = 0x50 }, .{ .vpr = 0x0000_F000, .it = 0x10 }),
};

const unclaimed = [_]V{
    vec("rn = sp is unclaimed", .{ .hw1 = 0xF00D }, none),
    vec("rn = pc is unclaimed", .{ .hw1 = 0xF00F }, none),
    vec("hw2 0xe800 is unclaimed", .{ .hw1 = 0xF000, .hw2 = 0xE800 }, none),
    vec("hw2 0xe001 is unclaimed", .{ .hw1 = 0xF000, .hw2 = 0xE001 }, none),
    vec("hw1 0xf040 is unclaimed", .{ .hw1 = 0xF040 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF000, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
