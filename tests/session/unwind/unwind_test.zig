//! Walking a call chain with .debug_frame: a leaf that keeps its return
//! address in lr, a caller that pushed lr and r4, and an outer frame.
const std = @import("std");
const ra8 = @import("ra8");

const unwind = ra8.session.unwind;

/// Words from `base` up; anything else is unreadable.
const Memory = struct {
    base: u32,
    words: []const u32,

    pub fn readWord(self: Memory, address: u32) !u32 {
        if (address < self.base or address % 4 != 0) return error.Unreadable;
        const index = (address - self.base) / 4;
        if (index >= self.words.len) return error.Unreadable;
        return self.words[index];
    }
};

/// The caller's saved r4, then its saved lr, at 0x100.
fn pushed(lr: u32) Memory {
    const words = std.testing.allocator.alloc(u32, 2) catch unreachable;
    words[0] = 0x44;
    words[1] = lr;
    return .{ .base = 0x100, .words = words };
}

fn expectFrames(expected: []const unwind.Frame, actual: []const unwind.Frame) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqual(want, got);
}

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
/// 0x1012; outer 0x1030..0x1040 that never moves sp; a handler
/// 0x1040..0x1050 that keeps its EXC_RETURN in lr.
fn build(list: *std.Io.Writer) !void {
    const cie_head = [_]u8{ 0xff, 0xff, 0xff, 0xff, 4, 0, 4, 0, 0x02, 0x7c, 0x0e };
    try entry(list, &cie_head, &.{ 0x0c, 0x0d, 0x00 });
    try fde(list, 0x1000, 0x10, &.{});
    try fde(list, 0x1010, 0x10, &.{ 0x41, 0x0e, 0x08, 0x8e, 0x01, 0x84, 0x02 });
    try fde(list, 0x1030, 0x10, &.{});
    try fde(list, 0x1040, 0x10, &.{});
}

fn stopped(pc: u32) unwind.Registers {
    var registers = std.mem.zeroes(unwind.Registers);
    registers[4] = 0x99;
    registers[13] = 0x100;
    registers[14] = 0x1021;
    registers[15] = pc;
    return registers;
}

test "the caller's sp is the CFA and its saved registers come off the stack" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try build(&list.writer);
    const memory = pushed(0x1035);
    defer std.testing.allocator.free(memory.words);
    var inner = stopped(0x1004);
    inner[15] = 0x1020;
    const outer = (try unwind.caller(list.written(), inner, false, memory)).?;
    try std.testing.expectEqual(@as(u32, 0x108), outer[13]);
    try std.testing.expectEqual(@as(u32, 0x44), outer[4]);
    try std.testing.expectEqual(@as(u32, 0x1035), outer[15]);
}

test "the walk looks a return address up one byte back and stops when nothing moves" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try build(&list.writer);
    var pcs: [unwind.limits.frames]unwind.Frame = undefined;
    const memory = pushed(0x1035);
    defer std.testing.allocator.free(memory.words);
    const count = unwind.walk(list.written(), stopped(0x1004), 0, memory, &pcs);
    try expectFrames(&.{ .{ .pc = 0x1004, .exact = true }, .{ .pc = 0x1020 }, .{ .pc = 0x1034 } }, pcs[0..count]);
}

test "a frame that cannot be unwound ends the walk" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try build(&list.writer);
    var pcs: [unwind.limits.frames]unwind.Frame = undefined;
    const lost = pushed(0);
    defer std.testing.allocator.free(lost.words);
    try std.testing.expectEqual(@as(usize, 2), unwind.walk(list.written(), stopped(0x1004), 0, lost, &pcs));
    try std.testing.expectEqual(@as(usize, 1), unwind.walk(list.written(), stopped(0x2000), 0, lost, &pcs));
    try std.testing.expectEqual(@as(usize, 0), unwind.walk(list.written(), stopped(0x1004), 0, lost, pcs[0..0]));
}

test "the walk steps out of a handler to the interrupted pc and on up its callers" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try build(&list.writer);
    // Exception frame at 0x200 (interrupted in the leaf, its lr pointing
    // into the caller), then the caller's pushed r4 and lr at 0x220.
    const words = [_]u32{ 1, 2, 3, 4, 0xC, 0x1021, 0x1004, 0x0100_0000, 0x44, 0x1035 };
    var registers = stopped(0x1044);
    registers[13] = 0x200;
    registers[14] = 0xFFFF_FFF9;
    var pcs: [unwind.limits.frames]unwind.Frame = undefined;
    const count = unwind.walk(list.written(), registers, 0, Memory{ .base = 0x200, .words = &words }, &pcs);
    const exact = true;
    try expectFrames(&.{ .{ .pc = 0x1044, .exact = exact }, .{ .pc = 0x1004, .exact = exact }, .{ .pc = 0x1020 }, .{ .pc = 0x1034 } }, pcs[0..count]);
}
