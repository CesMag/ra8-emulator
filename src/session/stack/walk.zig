//! One sampled call stack, innermost first, as code addresses with the
//! Thumb bit cleared (RA8EMU-956, for the sampler of RA8EMU-953).
//!
//! Where an FDE covers the pc the stack is what unwind.walk finds. Where
//! none does it follows the AAPCS frame record Zig and clang keep with
//! frame pointers on Thumb (push {r7, lr}; mov r7, sp): [r7] is the
//! caller's r7 and [r7+4] the return address. A leaf keeps no record, so
//! lr names its caller, except when lr is the record's own saved lr (a
//! non-leaf past its prologue) or falls in the pc's own function (a stale
//! lr left by a call that already returned), which only a function-start
//! lookup can tell.
const dwarf_frame = @import("../dwarf/frame.zig");
const unwind = @import("../unwind/unwind.zig");

pub const limits = struct {
    pub const fp: usize = 7;
    pub const lr: usize = 14;
};

/// Where the function holding an address starts, or null when none does.
pub const Starts = struct {
    context: *const anyopaque,
    startFn: *const fn (context: *const anyopaque, address: u32) ?u32,

    fn same(self: Starts, a: u32, b: u32) bool {
        const first = self.startFn(self.context, a) orelse return false;
        const second = self.startFn(self.context, b) orelse return false;
        return first == second;
    }
};

/// Write the stack into `into` and say how many frames it holds. `psp` is
/// the live Process stack pointer, for a walk out of a handler.
pub fn stackOf(frame: []const u8, registers: unwind.Registers, psp: u32, memory: anytype, starts: ?Starts, into: []u32) usize {
    if (into.len == 0) return 0;
    const covered = (dwarf_frame.find(frame, registers[unwind.limits.pc]) catch null) != null;
    if (!covered) return framePointer(registers, memory, starts, into);
    var walked: [unwind.limits.frames]unwind.Frame = undefined;
    const count = unwind.walk(frame, registers, psp, memory, walked[0..@min(into.len, walked.len)]);
    for (walked[0..count], into[0..count]) |found, *address| address.* = found.pc & ~@as(u32, 1);
    return count;
}

fn framePointer(registers: unwind.Registers, memory: anytype, starts: ?Starts, into: []u32) usize {
    const pc = registers[unwind.limits.pc] & ~@as(u32, 1);
    into[0] = pc;
    var count: usize = 1;
    var fp = registers[limits.fp];
    if (code(registers[limits.lr])) |lr| {
        const pushed = if (record(memory, fp)) |own| own.ret == lr else false;
        const stale = if (starts) |lookup| lookup.same(pc, lr) or calledElsewhere(memory, lookup, lr, pc) else false;
        if (!pushed and !stale and count < into.len) {
            into[count] = lr;
            count += 1;
        }
    }
    while (count < into.len) {
        const found = record(memory, fp) orelse break;
        into[count] = found.ret;
        count += 1;
        if (found.next <= fp) break;
        fp = found.next;
    }
    return count;
}

/// lr sits just after a direct BL whose target is a function other than the
/// pc's: that call already returned, so lr is left over from it
/// (RA8EMU-971). An indirect call can't be checked and keeps lr.
fn calledElsewhere(memory: anytype, starts: Starts, lr: u32, pc: u32) bool {
    const first = halfAt(memory, lr -% 4) orelse return false;
    const second = halfAt(memory, lr -% 2) orelse return false;
    if (first & 0xF800 != 0xF000 or second & 0xD000 != 0xD000) return false;
    const called = starts.startFn(starts.context, lr +% branchOffset(first, second)) orelse return false;
    const own = starts.startFn(starts.context, pc) orelse return false;
    return called != own;
}

/// The signed offset a 32-bit BL adds to the address after it.
fn branchOffset(first: u16, second: u16) u32 {
    const s: u32 = (first >> 10) & 1;
    const j1: u32 = (second >> 13) & 1;
    const j2: u32 = (second >> 11) & 1;
    const imm10: u32 = first & 0x3FF;
    const imm11: u32 = second & 0x7FF;
    const imm = s << 24 | (~(j1 ^ s) & 1) << 23 | (~(j2 ^ s) & 1) << 22 | imm10 << 12 | imm11 << 1;
    return @bitCast(@as(i32, @bitCast(imm << 7)) >> 7);
}

fn halfAt(memory: anytype, address: u32) ?u16 {
    const word = memory.readWord(address & ~@as(u32, 3)) catch return null;
    return @truncate(if (address & 2 != 0) word >> 16 else word);
}

const Record = struct { next: u32, ret: u32 };

fn record(memory: anytype, fp: u32) ?Record {
    if (fp == 0 or fp % 4 != 0) return null;
    const next = memory.readWord(fp) catch return null;
    const ret = code(memory.readWord(fp +% 4) catch return null) orelse return null;
    return .{ .next = next, .ret = ret };
}

/// A return address as code, or null for zero and EXC_RETURN values.
fn code(address: u32) ?u32 {
    const cleared = address & ~@as(u32, 1);
    if (cleared == 0 or address >= unwind.limits.exc_return) return null;
    return cleared;
}
