//! Conformance vectors for the decode group `ldst_imm` (RA8EMU-279):
//! STR/LDR, STRB/LDRB and STRH/LDRH [Rn, #imm5] (T1) and STR/LDR
//! [SP, #imm8] (T2). Expected values are worked from the Arm ARM (DDI0553):
//! imm5 scales by the access size and imm8 by 4, there is no writeback,
//! byte and halfword loads zero-extend, stores write only their own bytes,
//! and with CCR.UNALIGN_TRP clear an unaligned word or halfword is done as
//! bytes, little-endian. An access outside memory faults and changes
//! nothing. Rn is r1 throughout.
const vector = @import("../../vector.zig");

/// Where the two words of memory the vectors read and write sit.
pub const window: u32 = 0x2000_0200;

/// The halfword, its size, Rt, Rn's value, SP, Rt's value before (what a
/// store writes), and the two words at `window`.
pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    rt: u3 = 0,
    base: u32 = window,
    sp: u32 = window,
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
const group = "ldst_imm";
const none: Out = .{ .claimed = false, .rt = 0, .mem = .{ 0, 0 } };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("str r0, [r1]", .{ .hw1 = 0x6008 }, .{ .mem = .{ 0x8765_4321, 0xAABB_CCDD } }),
    vec("str r0, [r1, #4]", .{ .hw1 = 0x6048 }, .{ .mem = .{ 0x1122_3344, 0x8765_4321 } }),
    vec("ldr r0, [r1]", .{ .hw1 = 0x6808 }, .{ .rt = 0x1122_3344 }),
    vec("ldr r0, [r1, #4]", .{ .hw1 = 0x6848 }, .{ .rt = 0xAABB_CCDD }),
    vec("ldr r2, [r1, #124] scales imm5 by 4", .{ .hw1 = 0x6FCA, .rt = 2, .base = window - 124 }, .{ .rt = 0x1122_3344 }),
    vec("ldr r1, [r1] overwrites the base", .{ .hw1 = 0x6809, .rt = 1 }, .{ .rt = 0x1122_3344 }),
    vec("strb r0, [r1] writes one byte", .{ .hw1 = 0x7008 }, .{ .mem = .{ 0x1122_3321, 0xAABB_CCDD } }),
    vec("strb r0, [r1, #5]", .{ .hw1 = 0x7148 }, .{ .mem = .{ 0x1122_3344, 0xAABB_21DD } }),
    vec("ldrb r0, [r1, #3]", .{ .hw1 = 0x78C8 }, .{ .rt = 0x0000_0011 }),
    vec("ldrb r0, [r1, #7] zero-extends", .{ .hw1 = 0x79C8 }, .{ .rt = 0x0000_00AA }),
    vec("strh r0, [r1] writes two bytes", .{ .hw1 = 0x8008 }, .{ .mem = .{ 0x1122_4321, 0xAABB_CCDD } }),
    vec("strh r0, [r1, #2] scales imm5 by 2", .{ .hw1 = 0x8048 }, .{ .mem = .{ 0x4321_3344, 0xAABB_CCDD } }),
    vec("ldrh r0, [r1, #2]", .{ .hw1 = 0x8848 }, .{ .rt = 0x0000_1122 }),
    vec("ldrh r0, [r1, #6] zero-extends", .{ .hw1 = 0x88C8 }, .{ .rt = 0x0000_AABB }),
    vec("ldrh r0, [r1, #62] reaches the top of imm5", .{ .hw1 = 0x8FC8, .base = window - 56 }, .{ .rt = 0x0000_AABB }),
    vec("an unaligned ldr is done as bytes", .{ .hw1 = 0x6808, .base = window + 2 }, .{ .rt = 0xCCDD_1122 }),
    vec("an unaligned str is done as bytes", .{ .hw1 = 0x6008, .base = window + 1 }, .{ .mem = .{ 0x6543_2144, 0xAABB_CC87 } }),
    vec("an unaligned ldrh is done as bytes", .{ .hw1 = 0x8808, .base = window + 1 }, .{ .rt = 0x0000_2233 }),
    vec("str r0, [sp]", .{ .hw1 = 0x9000 }, .{ .mem = .{ 0x8765_4321, 0xAABB_CCDD } }),
    vec("str r3, [sp, #4]", .{ .hw1 = 0x9301, .rt = 3 }, .{ .mem = .{ 0x1122_3344, 0x8765_4321 } }),
    vec("ldr r0, [sp, #4]", .{ .hw1 = 0x9801 }, .{ .rt = 0xAABB_CCDD }),
    vec("ldr r7, [sp, #508] scales imm8 by 4", .{ .hw1 = 0x9F7F, .rt = 7, .sp = window - 508 }, .{ .rt = 0x1122_3344 }),
    vec("a load past RAM faults and leaves rt", .{ .hw1 = 0x6808, .base = 0x2000_0400 }, .{ .fault = .unmapped }),
    vec("a store past RAM faults and writes nothing", .{ .hw1 = 0x6008, .base = 0x2000_0400 }, .{ .fault = .unmapped }),
    vec("ldr rt, [rn, rm] belongs to ldst_reg", .{ .hw1 = 0x5800 }, none),
    vec("ldr rt, [pc] belongs to ldr_literal", .{ .hw1 = 0x4800 }, none),
    vec("adr belongs to sp_arith", .{ .hw1 = 0xA000 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0x6808, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
