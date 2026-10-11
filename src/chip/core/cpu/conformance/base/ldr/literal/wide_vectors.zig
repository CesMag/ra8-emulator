//! Conformance vectors for the decode group `ldr_literal_wide`
//! (RA8EMU-278): LDR.W, LDRB, LDRH, LDRSB and LDRSH with Rn = PC. Expected
//! values are worked from the Arm ARM (DDI0553): the address is
//! Align(PC, 4) +/- imm12 with PC reading as the instruction's address plus
//! 4; bytes and halfwords zero- or sign-extend; LDR with Rt = SP loads SP
//! and with Rt = PC branches with interworking. A literal outside memory
//! faults and leaves Rt alone. A byte or halfword form with Rt = PC (the
//! preloads) or Rt = SP, size 11, a signed word, Rn other than PC, stores
//! and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

/// The value every register holds before the load, and the default literal
/// (bytes A9 C3 65 87 in memory order).
pub const fill: u32 = 0x5555_5555;
pub const literal: u32 = 0x8765_C3A9;

/// The instruction and its address, and the word placed at `at` (0 for
/// nowhere).
pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    address: u32 = 0x2000_0100,
    at: u32 = 0,
    lit: u32 = literal,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, other };

/// Whether the group claims the encoding, how it ended, and Rt afterwards
/// (SP for Rt = 13, the PC for Rt = 15).
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    rt: u32,
};

const V = vector.Vector(In, Out);
const group = "ldr_literal_wide";
const none: Out = .{ .claimed = false, .rt = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn load(name: []const u8, hw1: u16, hw2: u16, at: u32, rt: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .at = at }, .{ .rt = rt });
}

fn faults(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, .{ .fault = .unmapped, .rt = fill });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = words ++ narrow ++ unclaimed;

const words = [_]V{
    load("ldr.w r0, [pc, #0]", 0xF8DF, 0x0000, 0x2000_0104, literal),
    load("ldr.w r5, [pc, #256]", 0xF8DF, 0x5100, 0x2000_0204, literal),
    load("ldr.w r0, [pc, #-4] reads its own word", 0xF85F, 0x0004, 0x2000_0100, literal),
    vec("ldr.w r0, [pc, #4] from a halfword address aligns PC down", .{ .hw1 = 0xF8DF, .hw2 = 0x0004, .address = 0x2000_0102, .at = 0x2000_0108 }, .{ .rt = literal }),
    load("ldr.w r12, [pc, #760] reaches the last word of RAM", 0xF8DF, 0xC2F8, 0x2000_03FC, literal),
    load("ldr.w lr, [pc, #8]", 0xF8DF, 0xE008, 0x2000_010C, literal),
    vec("ldr.w sp, [pc, #0] loads SP", .{ .hw1 = 0xF8DF, .hw2 = 0xD000, .at = 0x2000_0104, .lit = 0x2000_0300 }, .{ .rt = 0x2000_0300 }),
    vec("ldr.w pc, [pc, #0] branches to the Thumb target", .{ .hw1 = 0xF8DF, .hw2 = 0xF000, .at = 0x2000_0104, .lit = 0x2000_0201 }, .{ .rt = 0x2000_0200 }),
    faults("ldr.w past RAM faults and leaves rt", 0xF8DF, 0xC2FC),
    faults("ldr.w back below RAM faults and leaves rt", 0xF85F, 0x0108),
};

const narrow = [_]V{
    load("ldrb r1, [pc, #4] zero-extends byte 0", 0xF89F, 0x1004, 0x2000_0108, 0xA9),
    load("ldrb r1, [pc, #5] reads byte 1", 0xF89F, 0x1005, 0x2000_0108, 0xC3),
    load("ldrb r1, [pc, #7] reads byte 3", 0xF89F, 0x1007, 0x2000_0108, 0x87),
    load("ldrb r1, [pc, #-4] is a load, not a preload", 0xF81F, 0x1004, 0x2000_0100, 0xA9),
    load("ldrsb r2, [pc, #4] sign-extends a negative byte", 0xF99F, 0x2004, 0x2000_0108, 0xFFFF_FFA9),
    load("ldrsb r2, [pc, #6] keeps a positive byte", 0xF99F, 0x2006, 0x2000_0108, 0x65),
    load("ldrsb r2, [pc, #-1] reads backwards", 0xF91F, 0x2001, 0x2000_0100, 0xFFFF_FF87),
    load("ldrh r3, [pc, #4] zero-extends the low half", 0xF8BF, 0x3004, 0x2000_0108, 0xC3A9),
    load("ldrh r3, [pc, #6] reads the high half", 0xF8BF, 0x3006, 0x2000_0108, 0x8765),
    load("ldrh r3, [pc, #-4] reads backwards", 0xF83F, 0x3004, 0x2000_0100, 0xC3A9),
    load("ldrsh r4, [pc, #4] sign-extends a negative half", 0xF9BF, 0x4004, 0x2000_0108, 0xFFFF_C3A9),
    vec("ldrsh r4, [pc, #4] keeps a positive half", .{ .hw1 = 0xF9BF, .hw2 = 0x4004, .at = 0x2000_0108, .lit = 0x1234_5678 }, .{ .rt = 0x5678 }),
    load("ldrsh r4, [pc, #-2] reads backwards", 0xF93F, 0x4002, 0x2000_0100, 0xFFFF_8765),
    faults("ldrh past RAM faults and leaves rt", 0xF8BF, 0x32FC),
};

const unclaimed = [_]V{
    bad("ldrb with Rt = pc is pld", 0xF89F, 0xF004),
    bad("ldrsb with Rt = pc is pli", 0xF99F, 0xF004),
    bad("ldrh with Rt = sp is unclaimed", 0xF8BF, 0xD004),
    bad("ldrsb with Rt = sp is unclaimed", 0xF99F, 0xD004),
    bad("size 11 is unclaimed", 0xF8FF, 0x0004),
    bad("a signed word is unclaimed", 0xF9DF, 0x0004),
    bad("Rn other than pc is unclaimed", 0xF8D0, 0x0004),
    bad("a store is unclaimed", 0xF8CF, 0x0004),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF8DF, .hw2 = 0x0000, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
