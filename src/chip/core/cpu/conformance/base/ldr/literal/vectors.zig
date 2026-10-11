//! Conformance vectors for the decode group `ldr_literal` (RA8EMU-279):
//! LDR Rt, [PC, #imm8] (T1). Expected values are worked from the Arm ARM
//! (DDI0553): the literal sits at Align(PC, 4) + imm8 * 4 with PC reading
//! as the instruction's address plus 4, so a halfword-aligned instruction
//! reads from the same word as the one before it. A literal outside memory
//! faults and leaves Rt alone.
const vector = @import("../../../vector.zig");

/// The value every low register holds before the load, and the literal.
pub const fill: u32 = 0x5555_5555;
pub const literal: u32 = 0xC0DE_F00D;

/// The halfword, its size and address, which register Rt is, and where
/// the literal is placed (0 for nowhere).
pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    address: u32 = 0x2000_0100,
    rt: u3 = 0,
    at: u32 = 0,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, other };

/// Whether the group claims the encoding, how it ended, Rt afterwards and
/// whether every other low register kept `fill`.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    rt: u32 = literal,
    others_kept: bool = true,
};

const V = vector.Vector(In, Out);
const group = "ldr_literal";
const none: Out = .{ .claimed = false, .rt = 0, .others_kept = false };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("ldr r0, [pc, #0]", .{ .hw1 = 0x4800, .at = 0x2000_0104 }, .{}),
    vec("ldr r0, [pc, #4]", .{ .hw1 = 0x4801, .at = 0x2000_0108 }, .{}),
    vec("ldr r0, [pc, #0] from a halfword address aligns PC down", .{ .hw1 = 0x4800, .address = 0x2000_0102, .at = 0x2000_0104 }, .{}),
    vec("ldr r0, [pc, #4] from a halfword address", .{ .hw1 = 0x4801, .address = 0x2000_0102, .at = 0x2000_0108 }, .{}),
    vec("ldr r7, [pc, #8]", .{ .hw1 = 0x4F02, .rt = 7, .at = 0x2000_010C }, .{}),
    vec("ldr r3, [pc, #760] reaches the last word of RAM", .{ .hw1 = 0x4BBE, .rt = 3, .at = 0x2000_03FC }, .{}),
    vec("a literal past RAM faults and leaves rt", .{ .hw1 = 0x4BBF, .rt = 3 }, .{ .fault = .unmapped, .rt = fill }),
    vec("str rt, [rn, rm] belongs to the stores", .{ .hw1 = 0x5000 }, none),
    vec("add rd, rm belongs to special_data", .{ .hw1 = 0x4400 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0x4800, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
