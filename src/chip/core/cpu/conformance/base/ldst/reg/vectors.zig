//! Conformance vectors for the decode group `ldst_reg` (RA8EMU-279):
//! STR/STRH/STRB, LDR/LDRH/LDRB and LDRSB/LDRSH [Rn, Rm] (T1). Expected
//! values are worked from the Arm ARM (DDI0553): the address is Rn + Rm
//! modulo 2^32 with no shift and no writeback, LDRH and LDRB zero-extend
//! while LDRSH and LDRSB sign-extend, stores write only their own bytes,
//! and with CCR.UNALIGN_TRP clear an unaligned word or halfword is done as
//! bytes, little-endian. An access outside memory faults and changes
//! nothing. Rn is r1 and Rm is r2 throughout.
const vector = @import("../../../vector.zig");

/// Where the two words of memory the vectors read and write sit.
pub const window: u32 = 0x2000_0200;

/// The halfword, its size, Rt, Rn's and Rm's values, Rt's value before
/// (what a store writes) and the two words at `window`. Rt is set first,
/// then Rn and Rm, so a vector naming Rt as Rn or Rm keeps the address.
pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    rt: u3 = 0,
    base: u32 = window,
    offset: u32 = 0,
    value: u32 = 0x8765_4321,
    mem: [2]u32 = initial,
};

pub const initial: [2]u32 = .{ 0x1122_3344, 0xAABB_CCDD };

/// How the instruction ended.
pub const Fault = enum { none, unmapped, other };

/// Whether the group claims the encoding, how it ended, Rt and the two
/// words afterwards.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    rt: u32 = 0x8765_4321,
    mem: [2]u32 = initial,
};

const V = vector.Vector(In, Out);
const group = "ldst_reg";
const none: Out = .{ .claimed = false, .rt = 0, .mem = .{ 0, 0 } };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("str r0, [r1, r2]", .{ .hw1 = 0x5088 }, .{ .mem = .{ 0x8765_4321, 0xAABB_CCDD } }),
    vec("str r0, [r1, r2] with r2 = 4", .{ .hw1 = 0x5088, .offset = 4 }, .{ .mem = .{ 0x1122_3344, 0x8765_4321 } }),
    vec("strh writes two bytes", .{ .hw1 = 0x5288, .offset = 2 }, .{ .mem = .{ 0x4321_3344, 0xAABB_CCDD } }),
    vec("strb writes one byte", .{ .hw1 = 0x5488, .offset = 5 }, .{ .mem = .{ 0x1122_3344, 0xAABB_21DD } }),
    vec("ldr r0, [r1, r2]", .{ .hw1 = 0x5888, .offset = 4 }, .{ .rt = 0xAABB_CCDD }),
    vec("ldrh r0, [r1, r2]", .{ .hw1 = 0x5A88, .offset = 2 }, .{ .rt = 0x0000_1122 }),
    vec("ldrh zero-extends", .{ .hw1 = 0x5A88, .offset = 4 }, .{ .rt = 0x0000_CCDD }),
    vec("ldrb zero-extends", .{ .hw1 = 0x5C88, .offset = 7 }, .{ .rt = 0x0000_00AA }),
    vec("ldrsb of a positive byte", .{ .hw1 = 0x5688, .offset = 3 }, .{ .rt = 0x0000_0011 }),
    vec("ldrsb sign-extends", .{ .hw1 = 0x5688, .offset = 4 }, .{ .rt = 0xFFFF_FFDD }),
    vec("ldrsh of a positive halfword", .{ .hw1 = 0x5E88, .offset = 2 }, .{ .rt = 0x0000_1122 }),
    vec("ldrsh sign-extends", .{ .hw1 = 0x5E88, .offset = 6 }, .{ .rt = 0xFFFF_AABB }),
    vec("a negative rm wraps the address", .{ .hw1 = 0x5888, .base = window + 8, .offset = 0xFFFF_FFF8 }, .{ .rt = 0x1122_3344 }),
    vec("rn of zero takes the whole address from rm", .{ .hw1 = 0x5888, .base = 0, .offset = window }, .{ .rt = 0x1122_3344 }),
    vec("an unaligned ldr is done as bytes", .{ .hw1 = 0x5888, .offset = 2 }, .{ .rt = 0xCCDD_1122 }),
    vec("an unaligned ldrsh sign-extends its bytes", .{ .hw1 = 0x5E88, .offset = 3 }, .{ .rt = 0xFFFF_DD11 }),
    vec("an unaligned str is done as bytes", .{ .hw1 = 0x5088, .offset = 1 }, .{ .mem = .{ 0x6543_2144, 0xAABB_CC87 } }),
    vec("ldr r1, [r1, r2] overwrites rn", .{ .hw1 = 0x5889, .rt = 1 }, .{ .rt = 0x1122_3344 }),
    vec("ldr r2, [r1, r2] overwrites rm", .{ .hw1 = 0x588A, .rt = 2 }, .{ .rt = 0x1122_3344 }),
    vec("a load past RAM faults and leaves rt", .{ .hw1 = 0x5888, .base = 0x2000_0400 }, .{ .fault = .unmapped }),
    vec("a store past RAM faults and writes nothing", .{ .hw1 = 0x5088, .base = 0x2000_0400 }, .{ .fault = .unmapped }),
    vec("str rt, [rn, #imm5] belongs to ldst_imm", .{ .hw1 = 0x6008 }, none),
    vec("ldr rt, [pc] belongs to ldr_literal", .{ .hw1 = 0x4888 }, none),
    vec("add rd, rm belongs to special_data", .{ .hw1 = 0x4400 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0x5888, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
