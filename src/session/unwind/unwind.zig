//! Walking the call chain with .debug_frame: from one frame's registers to
//! its caller's, and on until the information runs out.
//!
//! A caller's pc is the return address its callee was given, so it is
//! looked up one byte back: a call that ends a function returns past its
//! last byte, into whatever comes next. An EXC_RETURN in the return
//! register means the frame is a handler: the walk steps out through the
//! stacked exception frame (unwind/exception.zig) to the interrupted pc,
//! which is looked up as it is, since nothing called from there.
const std = @import("std");
const core_view = @import("../core_view.zig");
const dwarf_frame = @import("../dwarf/frame.zig");
pub const exception = @import("exception.zig");

pub const limits = struct {
    /// The most frames one backtrace prints.
    pub const frames: usize = 32;
    /// A return address at or above this is an EXC_RETURN value, which
    /// tells the core how to leave a handler rather than where to go.
    pub const exc_return: u32 = 0xF000_0000;
    pub const sp: usize = 13;
    pub const pc: usize = 15;
};

/// One frame of a backtrace. `exact` says the pc is the instruction the
/// frame stopped on (the innermost, or one an exception interrupted)
/// rather than a return address, which belongs to the call before it.
pub const Frame = struct {
    pc: u32,
    exact: bool = false,
};

/// r0 to r15, indexed the way DWARF numbers them.
pub const Registers = [dwarf_frame.limits.registers]u32;

const order = [_]core_view.Cortex{ .r0, .r1, .r2, .r3, .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r11, .r12, .sp, .lr, .pc };

/// The core's registers, in DWARF order.
pub fn registersOf(core: core_view.View) core_view.Error!Registers {
    var registers: Registers = undefined;
    for (order, 0..) |which, index| registers[index] = try core.register(which);
    return registers;
}

/// The caller's registers, or null when no FDE covers this frame or the
/// compiler kept no return address. `innermost` is the frame the core is
/// stopped in, whose pc is the instruction itself rather than a return.
pub fn caller(frame: []const u8, registers: Registers, innermost: bool, memory: anytype) !?Registers {
    const pc = registers[limits.pc];
    const lookup = if (innermost) pc else pc -% 1;
    const fde = try dwarf_frame.find(frame, lookup) orelse return null;
    const row = try dwarf_frame.rowAt(fde, lookup);
    const returns = std.math.cast(u8, fde.cie.return_register) orelse return null;
    if (returns >= dwarf_frame.limits.registers) return null;
    const cfa = wrap(registers[row.cfa.register], row.cfa.offset);
    var next = registers;
    for (row.rules, 0..) |rule, index| switch (rule) {
        .same => {},
        .undefined => if (index == returns) return null,
        .offset => |offset| next[index] = try memory.readWord(wrap(cfa, offset)),
        .register => |from| next[index] = registers[from],
    };
    next[limits.sp] = cfa;
    next[limits.pc] = next[returns];
    return next;
}

fn wrap(base: u32, offset: i64) u32 {
    return base +% @as(u32, @truncate(@as(u64, @bitCast(offset))));
}

/// The call chain from `start`, innermost first, into `into`. How many
/// frames it found; one means the frame has no usable CFI. `psp` is the
/// live Process stack pointer, where a thread's exception frame sits.
pub fn walk(frame: []const u8, start: Registers, psp: u32, memory: anytype, into: []Frame) usize {
    if (into.len == 0) return 0;
    into[0] = .{ .pc = start[limits.pc], .exact = true };
    var registers = start;
    var count: usize = 1;
    while (count < into.len) : (count += 1) {
        var next = (caller(frame, registers, into[count - 1].exact, memory) catch null) orelse break;
        const exact = next[limits.pc] >= limits.exc_return;
        if (exact) next = exception.interrupted(next[limits.pc], next, psp, memory) catch break;
        const pc = next[limits.pc] & ~@as(u32, 1);
        if (pc == 0 or pc >= limits.exc_return) break;
        if (pc == registers[limits.pc] and next[limits.sp] == registers[limits.sp]) break;
        registers = next;
        registers[limits.pc] = pc;
        into[count] = .{ .pc = pc, .exact = exact };
    }
    return count;
}
