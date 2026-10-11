//! Conformance vectors for the decode group `ldst.wide` (RA8EMU-278): the
//! 32-bit single-register loads and stores with an immediate offset, in the
//! imm12 forms and the imm8 offset, pre-indexed, post-indexed and
//! unprivileged (LDRT family) forms. Expected values are worked from the
//! Arm ARM (DDI0553): the address is Rn +/- imm (Rn itself when
//! post-indexed), writeback leaves Rn at the offset address, bytes and
//! halfwords zero- or sign-extend, an unaligned word goes through as bytes
//! with CCR.UNALIGN_TRP clear, and an access outside memory faults with Rt
//! and Rn kept. Rn = PC, the register-offset space, P = 0 with W = 0, the
//! preloads, a store of PC, a narrow SP, SP or PC as an unprivileged Rt,
//! writeback with Rn = Rt, signed stores and words, size 11 and the 16-bit
//! space are left unclaimed.
const vector = @import("../../vector.zig");

/// Rn = r0 points at `base`; Rt = r1 holds `src`; the word placed at `at`
/// is `literal` (bytes A9 C3 65 87 in memory order) unless `lit` says.
pub const base: u32 = 0x2000_0200;
pub const src: u32 = 0x1122_3344;
pub const fill: u32 = 0x5555_5555;
pub const literal: u32 = 0x8765_C3A9;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    at: u32 = 0,
    lit: u32 = literal,
    /// The word read back after the instruction (0 for none).
    probe: u32 = 0,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, other };

/// Whether the group claims the encoding, how it ended, Rt (SP for 13, the
/// PC for 15) and Rn afterwards, and the probed word.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    rt: u32 = src,
    rn: u32 = base,
    mem: u32 = 0,
};

const V = vector.Vector(In, Out);
const group = "ldst_wide";
const none: Out = .{ .claimed = false, .rt = 0, .rn = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ld(name: []const u8, hw1: u16, hw2: u16, at: u32, rt: u32, rn: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .at = at }, .{ .rt = rt, .rn = rn });
}

fn st(name: []const u8, hw1: u16, hw2: u16, at: u32, probe: u32, mem: u32, rn: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .at = at, .probe = probe }, .{ .rn = rn, .mem = mem });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = loads ++ stores ++ unclaimed;

const loads = [_]V{
    ld("ldr.w r1, [r0, #4]", 0xF8D0, 0x1004, 0x2000_0204, literal, base),
    ld("ldrb.w r1, [r0, #5]", 0xF890, 0x1005, 0x2000_0204, 0xC3, base),
    ld("ldrh.w r1, [r0, #6]", 0xF8B0, 0x1006, 0x2000_0204, 0x8765, base),
    ld("ldrsb.w r1, [r0, #4]", 0xF990, 0x1004, 0x2000_0204, 0xFFFF_FFA9, base),
    ld("ldrsh.w r1, [r0, #4]", 0xF9B0, 0x1004, 0x2000_0204, 0xFFFF_C3A9, base),
    ld("ldr r1, [r0, #-4]", 0xF850, 0x1C04, 0x2000_01FC, literal, base),
    ld("ldr r1, [r0, #4]! writes back", 0xF850, 0x1F04, 0x2000_0204, literal, 0x2000_0204),
    ld("ldr r1, [r0, #-8]! writes back", 0xF850, 0x1D08, 0x2000_01F8, literal, 0x2000_01F8),
    ld("ldr r1, [r0], #4 reads at rn", 0xF850, 0x1B04, 0x2000_0200, literal, 0x2000_0204),
    ld("ldr r1, [r0], #-255", 0xF850, 0x19FF, 0x2000_0200, literal, 0x2000_0101),
    ld("ldrb r1, [r0], #1", 0xF810, 0x1B01, 0x2000_0200, 0xA9, 0x2000_0201),
    ld("ldrsh r1, [r0, #-2]! reads the high half", 0xF930, 0x1D02, 0x2000_01FC, 0xFFFF_8765, 0x2000_01FE),
    ld("ldrt r1, [r0, #4]", 0xF850, 0x1E04, 0x2000_0204, literal, base),
    ld("ldrbt r1, [r0, #5]", 0xF810, 0x1E05, 0x2000_0204, 0xC3, base),
    ld("ldrsht r1, [r0, #6]", 0xF930, 0x1E06, 0x2000_0204, 0xFFFF_8765, base),
    ld("an unaligned ldr.w goes through as bytes", 0xF8D0, 0x1002, 0x2000_0200, 0x0000_8765, base),
    vec("ldr.w pc, [r0, #4] branches to the Thumb target", .{ .hw1 = 0xF8D0, .hw2 = 0xF004, .at = 0x2000_0204, .lit = 0x2000_0301 }, .{ .rt = 0x2000_0300 }),
    vec("ldr.w sp, [r0, #4] loads sp", .{ .hw1 = 0xF8D0, .hw2 = 0xD004, .at = 0x2000_0204, .lit = 0x2000_0300 }, .{ .rt = 0x2000_0300 }),
    vec("ldr.w past RAM faults and keeps rt", .{ .hw1 = 0xF8D0, .hw2 = 0x1FFF }, .{ .fault = .unmapped }),
    vec("ldr post-indexed past RAM keeps rn", .{ .hw1 = 0xF850, .hw2 = 0x1BFF, .lit = 0 }, .{ .rt = 0, .rn = 0x2000_02FF }),
};

const stores = [_]V{
    st("str.w r1, [r0, #4]", 0xF8C0, 0x1004, 0, 0x2000_0204, src, base),
    st("strb.w r1, [r0, #5] writes one byte", 0xF880, 0x1005, 0x2000_0204, 0x2000_0204, 0x8765_44A9, base),
    st("strh.w r1, [r0, #6] writes the high half", 0xF8A0, 0x1006, 0x2000_0204, 0x2000_0204, 0x3344_C3A9, base),
    st("str r1, [r0, #-4]", 0xF840, 0x1C04, 0, 0x2000_01FC, src, base),
    st("str r1, [r0, #8]! writes back", 0xF840, 0x1F08, 0, 0x2000_0208, src, 0x2000_0208),
    st("str r1, [r0], #-4 writes at rn", 0xF840, 0x1904, 0, 0x2000_0200, src, 0x2000_01FC),
    st("strb r1, [r0], #1", 0xF800, 0x1B01, 0, 0x2000_0200, 0x44, 0x2000_0201),
    st("strh r1, [r0, #-2]!", 0xF820, 0x1D02, 0, 0x2000_01FC, 0x3344_0000, 0x2000_01FE),
    st("strt r1, [r0, #4]", 0xF840, 0x1E04, 0, 0x2000_0204, src, base),
    st("strht r1, [r0, #4]", 0xF820, 0x1E04, 0, 0x2000_0204, 0x3344, base),
    st("an unaligned str.w goes through as bytes", 0xF8C0, 0x1001, 0, 0x2000_0200, 0x2233_4400, base),
    vec("str.w sp, [r0, #4] stores sp", .{ .hw1 = 0xF8C0, .hw2 = 0xD004, .probe = 0x2000_0204 }, .{ .rt = fill & ~@as(u32, 3), .mem = fill & ~@as(u32, 3) }),
    vec("str.w past RAM faults and keeps rn", .{ .hw1 = 0xF8C0, .hw2 = 0x1FFF }, .{ .fault = .unmapped }),
};

const unclaimed = [_]V{
    bad("rn = pc is the literal group", 0xF8DF, 0x1004),
    bad("the register-offset space is unclaimed", 0xF850, 0x1000),
    bad("P = 0 W = 0 is unclaimed", 0xF850, 0x1804),
    bad("P = 0 U = 1 W = 0 is unclaimed", 0xF850, 0x1A04),
    bad("ldrb with rt = pc is pld", 0xF890, 0xF004),
    bad("a store of pc is unclaimed", 0xF8C0, 0xF004),
    bad("ldrb into sp is unclaimed", 0xF890, 0xD004),
    bad("ldrt into pc is unclaimed", 0xF850, 0xFE04),
    bad("ldrt into sp is unclaimed", 0xF850, 0xDE04),
    bad("writeback with rn = rt is unclaimed", 0xF850, 0x0F04),
    bad("a signed store is unclaimed", 0xF980, 0x1004),
    bad("a signed word is unclaimed", 0xF9D0, 0x1004),
    bad("size 11 is unclaimed", 0xF8F0, 0x1004),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF8D0, .hw2 = 0x1004, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
