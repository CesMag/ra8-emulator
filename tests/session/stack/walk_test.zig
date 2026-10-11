//! Tests for src/session/stack/walk.zig: a stack with CFI, and leaves and
//! non-leaves without it walked along the r7 frame records.
const std = @import("std");
const ra8 = @import("ra8");
const unwind = ra8.session.unwind;
const stack_walk = ra8.session.step_hook.stack.walk;

/// Words at a few places; anything else is unreadable.
const Memory = struct {
    regions: []const Region,

    const Region = struct { base: u32, words: []const u32 };

    pub fn readWord(self: Memory, address: u32) !u32 {
        for (self.regions) |region| {
            if (address < region.base or address % 4 != 0) continue;
            const index = (address - region.base) / 4;
            if (index < region.words.len) return region.words[index];
        }
        return error.Unreadable;
    }
};

fn entry(list: *std.Io.Writer, head: []const u8, program: []const u8) !void {
    try list.writeInt(u32, @intCast(head.len + program.len), .little);
    try list.writeAll(head);
    try list.writeAll(program);
}

fn fde(list: *std.Io.Writer, start: u32, range: u32, program: []const u8) !void {
    var head: [12]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], 0, .little);
    std.mem.writeInt(u32, head[4..8], start, .little);
    std.mem.writeInt(u32, head[8..12], range, .little);
    try entry(list, &head, program);
}

/// Leaf 0x1000..0x1010; caller 0x1010..0x1020 that pushes {r4, lr} at
/// 0x1012; outer 0x1030..0x1040 that never moves sp. Nothing covers 0x2000.
fn table(into: []u8) ![]const u8 {
    var list: std.Io.Writer = .fixed(into);
    const cie_head = [_]u8{ 0xff, 0xff, 0xff, 0xff, 4, 0, 4, 0, 0x02, 0x7c, 0x0e };
    try entry(&list, &cie_head, &.{ 0x0c, 0x0d, 0x00 });
    try fde(&list, 0x1000, 0x10, &.{});
    try fde(&list, 0x1010, 0x10, &.{ 0x41, 0x0e, 0x08, 0x8e, 0x01, 0x84, 0x02 });
    try fde(&list, 0x1030, 0x10, &.{});
    return list.buffered();
}

fn stopped(pc: u32, lr: u32, fp: u32, sp: u32) unwind.Registers {
    var registers = std.mem.zeroes(unwind.Registers);
    registers[unwind.limits.pc] = pc;
    registers[stack_walk.limits.lr] = lr;
    registers[stack_walk.limits.fp] = fp;
    registers[unwind.limits.sp] = sp;
    return registers;
}

/// Two frame records: one at 0x200 returning to 0x2200, whose caller's
/// record at 0x210 returns to 0x2300 and ends the chain.
const chain: Memory = .{ .regions = &.{
    .{ .base = 0x200, .words = &.{ 0x210, 0x2201 } },
    .{ .base = 0x210, .words = &.{ 0, 0x2301 } },
} };

fn walked(registers: unwind.Registers, memory: Memory, starts: ?stack_walk.Starts, into: []u32) ![]const u32 {
    var bytes: [128]u8 = undefined;
    const frame = try table(&bytes);
    return into[0..stack_walk.stackOf(frame, registers, 0, memory, starts, into)];
}

test "where CFI covers the pc the stack is what the unwinder walks" {
    const pushed: Memory = .{ .regions = &.{.{ .base = 0x100, .words = &.{ 0x44, 0x1035 } }} };
    var into: [8]u32 = undefined;
    const stack = try walked(stopped(0x1004, 0x1015, 0, 0x100), pushed, null, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x1004, 0x1014, 0x1034 }, stack);
}

test "a leaf without CFI names its caller by lr, then the frame records" {
    var into: [8]u32 = undefined;
    const stack = try walked(stopped(0x2004, 0x2101, 0x200, 0x1f0), chain, null, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x2004, 0x2100, 0x2200, 0x2300 }, stack);
}

test "a non-leaf past its prologue is not named twice through lr" {
    var into: [8]u32 = undefined;
    const stack = try walked(stopped(0x2004, 0x2201, 0x200, 0x1f0), chain, null, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x2004, 0x2200, 0x2300 }, stack);
}

fn startOf(_: *const anyopaque, address: u32) ?u32 {
    if (address >= 0x2000 and address < 0x2100) return 0x2000;
    return null;
}

test "a stale lr inside the pc's own function is dropped" {
    const starts: stack_walk.Starts = .{ .context = undefined, .startFn = startOf };
    var into: [8]u32 = undefined;
    const stack = try walked(stopped(0x2040, 0x2009, 0x200, 0x1f0), chain, starts, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x2040, 0x2200, 0x2300 }, stack);
}

fn startsOf(_: *const anyopaque, address: u32) ?u32 {
    if (address >= 0x2000 and address < 0x2600) return address & ~@as(u32, 0xFF);
    return null;
}

/// The chain, plus a `bl 0x2400` at 0x2104 (so returning to 0x2108).
const called: Memory = .{ .regions = &.{
    .{ .base = 0x200, .words = &.{ 0x210, 0x2201 } },
    .{ .base = 0x210, .words = &.{ 0, 0x2301 } },
    .{ .base = 0x2104, .words = &.{0xF97C_F000} },
} };

test "an lr left over from a call that already returned is dropped" {
    const starts: stack_walk.Starts = .{ .context = undefined, .startFn = startsOf };
    var into: [8]u32 = undefined;
    const back = try walked(stopped(0x2040, 0x2109, 0x200, 0x1f0), called, starts, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x2040, 0x2200, 0x2300 }, back);
    const inside = try walked(stopped(0x2404, 0x2109, 0x200, 0x1f0), called, starts, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x2404, 0x2108, 0x2200, 0x2300 }, inside);
}

test "an EXC_RETURN lr is no caller, and a bad frame pointer ends the walk" {
    var into: [8]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ 0x2004, 0x2200, 0x2300 },
        try walked(stopped(0x2004, 0xFFFF_FFFD, 0x200, 0x1f0), chain, null, &into),
    );
    try std.testing.expectEqualSlices(
        u32,
        &.{ 0x2004, 0x2100 },
        try walked(stopped(0x2004, 0x2101, 0x202, 0x1f0), chain, null, &into),
    );
}

test "a short buffer keeps the innermost frames" {
    var into: [2]u32 = undefined;
    const stack = try walked(stopped(0x2004, 0x2101, 0x200, 0x1f0), chain, null, &into);
    try std.testing.expectEqualSlices(u32, &.{ 0x2004, 0x2100 }, stack);
}
