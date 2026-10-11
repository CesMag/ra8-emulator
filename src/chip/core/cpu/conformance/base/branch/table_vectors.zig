//! Conformance vectors for the decode group `table_branch` (RA8EMU-278):
//! TBB and TBH (T1). Expected values are worked from the Arm ARM (DDI0553):
//! the branch target is the instruction's address plus 4 plus twice the
//! unsigned byte at Rn + Rm (TBB) or halfword at Rn + Rm * 2 (TBH), and an
//! Rn of PC reads as the address plus 4. They run over 1 KiB of RAM at
//! 0x2000_0000; a table outside it faults. Rn of SP, Rm of SP or PC, hw2
//! bits 11:5 other than 0, and the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

/// Where the RAM starts and where most tables sit in it.
pub const ram: u32 = 0x2000_0000;
pub const table: u32 = ram + 0x200;

pub const Fault = enum { none, unmapped, other };

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The instruction's address.
    address: u32 = 0x1000,
    /// Rn (unless it is PC) and Rm before the instruction.
    base: u32 = table,
    index: u32 = 0,
    /// A word of table placed at `at` in RAM; 0 places nothing.
    at: u32 = table,
    word: u32 = 0,
};

/// Whether the group claims the encoding, how it ended, then the PC.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    pc: u32 = 0,
};

const V = vector.Vector(In, Out);
const group = "table_branch";
const none: Out = .{ .claimed = false };

/// TBB [r0, r1] and TBH [r0, r1, lsl #1].
const r0 = 0xE8D0;
const tbb = 0xF001;
const tbh = 0xF011;
/// The same with Rn = PC.
const pc_rn = 0xE8DF;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn go(name: []const u8, hw2: u16, index: u32, word: u32, pc: u32) V {
    return vec(name, .{ .hw1 = r0, .hw2 = hw2, .index = index, .word = word }, .{ .pc = pc });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    go("tbb entry 0", tbb, 0, 0x0403_0201, 0x1006),
    go("tbb entry 3", tbb, 3, 0x0403_0201, 0x100C),
    go("tbb of 0 branches to the next instruction", tbb, 0, 0, 0x1004),
    go("tbb of 0xff is unsigned", tbb, 0, 0xFF, 0x1202),
    go("tbh entry 0", tbh, 0, 0x0002_0001, 0x1006),
    go("tbh entry 1 scales Rm by 2", tbh, 1, 0x0002_0001, 0x1008),
    go("tbh of 0xffff is unsigned", tbh, 0, 0xFFFF, 0x2_1002),
    vec("tbh entry 2 reads the next word", .{ .hw1 = r0, .hw2 = tbh, .index = 2, .at = table + 4, .word = 0x10 }, .{ .pc = 0x1024 }),
    vec("tbb at an odd address", .{ .hw1 = r0, .hw2 = tbb, .base = table + 2, .index = 1, .word = 0x7F00_0000 }, .{ .pc = 0x1102 }),
    vec("tbb on pc reads after the instruction", .{ .hw1 = pc_rn, .hw2 = tbb, .address = ram + 0x100, .at = ram + 0x104, .word = 3 }, .{ .pc = ram + 0x10A }),
    vec("tbh on pc reads after the instruction", .{ .hw1 = pc_rn, .hw2 = tbh, .address = ram + 0x100, .index = 1, .at = ram + 0x104, .word = 0x0005_0000 }, .{ .pc = ram + 0x10E }),
    vec("tbb on r12 and r3", .{ .hw1 = 0xE8DC, .hw2 = 0xF003, .index = 1, .word = 0x0900 }, .{ .pc = 0x1016 }),
    vec("tbb off the end of memory faults", .{ .hw1 = r0, .hw2 = tbb, .base = 0x1000_0000, .at = 0 }, .{ .fault = .unmapped }),
    vec("tbh off the end of memory faults", .{ .hw1 = r0, .hw2 = tbh, .base = 0x1000_0000, .at = 0 }, .{ .fault = .unmapped }),
    bad("Rn of sp is unclaimed", 0xE8DD, tbb),
    bad("Rm of sp is unclaimed", r0, 0xF00D),
    bad("Rm of pc is unclaimed", r0, 0xF00F),
    bad("hw2 bit 5 set is unclaimed", r0, 0xF021),
    bad("hw2 bit 6 set is unclaimed", r0, 0xF041),
    bad("hw2 bit 11 clear is unclaimed", r0, 0xF701),
    bad("hw2 bit 12 clear is unclaimed", r0, 0xE001),
    bad("hw1 E8C0 is unclaimed", 0xE8C0, tbb),
    vec("the 16-bit space is unclaimed", .{ .hw1 = r0, .hw2 = tbb, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
