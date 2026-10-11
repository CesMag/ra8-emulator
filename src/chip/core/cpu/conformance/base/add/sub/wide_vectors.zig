//! Conformance vectors for the decode group `add_sub_wide` (RA8EMU-280):
//! ADDW and SUBW (ADD T4, SUB T4), their SP forms, and ADR T3 and T2 (Rn =
//! PC). Expected values are worked from the Arm ARM (DDI0553): imm12 is
//! i:imm3:imm8 with no rotation, the result wraps, no flag changes, and ADR
//! starts from Align(PC, 4). Rd of PC, Rd of SP with any Rn but SP, a set
//! hw2[15] and the neighbouring MOVW and ADD (modified immediate) are left
//! unclaimed.
const vector = @import("../../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    address: u32 = 0x1000,
    /// Rn (or SP) before the instruction.
    n: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "add_sub_wide";
const none: Out = .{ .claimed = false, .flags = 0 };

/// ADDW and SUBW with Rn r1, and their Rn = PC (ADR) and Rn = SP forms.
const addw = 0xF201;
const subw = 0xF2A1;
const adr_add = 0xF20F;
const adr_sub = 0xF2AF;
const add_sp = 0xF20D;
const sub_sp = 0xF2AD;
const sp: u32 = 0x2000_0400;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("addw r0, r1, #0", .{ .hw1 = addw, .hw2 = 0x0000, .n = 5 }, .{ .rd = 5 }),
    vec("addw #0xfff sets every imm field", .{ .hw1 = 0xF601, .hw2 = 0x70FF, .n = 1 }, .{ .rd = 0x1000 }),
    vec("addw #0x800 from i", .{ .hw1 = 0xF601, .hw2 = 0x0000 }, .{ .rd = 0x800 }),
    vec("addw #0x700 from imm3", .{ .hw1 = addw, .hw2 = 0x7000 }, .{ .rd = 0x700 }),
    vec("addw wraps", .{ .hw1 = addw, .hw2 = 0x0001, .n = 0xFFFF_FFFF }, .{ .rd = 0 }),
    vec("addw leaves the flags on overflow", .{ .hw1 = addw, .hw2 = 0x0001, .n = 0x7FFF_FFFF }, .{ .rd = 0x8000_0000 }),
    vec("subw r0, r1, #1 wraps", .{ .hw1 = subw, .hw2 = 0x0001 }, .{ .rd = 0xFFFF_FFFF }),
    vec("subw #0xfff", .{ .hw1 = 0xF6A1, .hw2 = 0x70FF, .n = 0x1000 }, .{ .rd = 1 }),
    vec("subw #0x123", .{ .hw1 = subw, .hw2 = 0x1023, .n = 0x200 }, .{ .rd = 0xDD }),
    vec("adr r0, #0x10 at a word address", .{ .hw1 = adr_add, .hw2 = 0x0010 }, .{ .rd = 0x1014 }),
    vec("adr aligns the pc down", .{ .hw1 = adr_add, .hw2 = 0x0010, .address = 0x1002 }, .{ .rd = 0x1014 }),
    vec("adr subtracting", .{ .hw1 = adr_sub, .hw2 = 0x0004, .address = 0x1002 }, .{ .rd = 0x1000 }),
    vec("addw sp, sp, #8", .{ .hw1 = add_sp, .hw2 = 0x0D08, .n = sp }, .{ .rd = sp + 8 }),
    vec("subw sp, sp, #0x100", .{ .hw1 = sub_sp, .hw2 = 0x1D00, .n = sp }, .{ .rd = sp - 0x100 }),
    vec("addw r0, sp, #4", .{ .hw1 = add_sp, .hw2 = 0x0004, .n = sp }, .{ .rd = sp + 4 }),
    vec("addw r12, lr, #5", .{ .hw1 = 0xF20E, .hw2 = 0x0C05, .n = 10 }, .{ .rd = 15 }),
    vec("Rd of pc is unclaimed", .{ .hw1 = addw, .hw2 = 0x0F00 }, none),
    vec("Rd of sp from r1 is unclaimed", .{ .hw1 = addw, .hw2 = 0x0D00 }, none),
    vec("a set hw2[15] is unclaimed", .{ .hw1 = addw, .hw2 = 0x8000 }, none),
    vec("movw belongs to mov_wide", .{ .hw1 = 0xF240, .hw2 = 0x0000 }, none),
    vec("add.w with a modified immediate belongs to imm_arith", .{ .hw1 = 0xF101, .hw2 = 0x0000 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = addw, .hw2 = 0x0000, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
