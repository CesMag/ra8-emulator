//! RA8EMU-658: a core run N instructions, snapshotted and restored into a
//! fresh core, runs the next M exactly as the original does.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const Fake = @import("exception/fake_source.zig").Fake;
const file = ra8.snapshot.file;
const snap = ra8.chip.core.cpu.snapshot;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

const pendsv: u9 = 14;

/// A loop that keeps r0..r3 changing: ADDS r0,#1; LSLS r1,r0,#1;
/// EORS r2,r1; ADDS r3,r2,r1; B back. PendSV runs NOPs then BX LR.
fn program(ram: *fixture.Ram) void {
    const loop = [_]u16{ 0x3001, 0x0041, 0x404A, 0x1853, 0xE7FA };
    for (loop, 0..) |half, i| ram.putHalf(fixture.code + 2 * @as(u32, @intCast(i)), half);
    for (0..6) |i| ram.putHalf(fixture.handler + 2 * @as(u32, @intCast(i)), 0xBF00);
    ram.putHalf(fixture.handler + 12, 0x4770);
    ram.putWord(fixture.base + 4 * @as(u32, pendsv), fixture.handler | 1);
}

fn snapshot(cpu: *const Cpu, core: u8, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try snap.save(cpu, core, &list.writer);
}

fn expectSame(want: *const Cpu, got: *const Cpu) !void {
    try std.testing.expectEqualDeep(want.regs, got.regs);
    try std.testing.expectEqualDeep(want.fp, got.fp);
    try std.testing.expectEqualDeep(want.banked, got.banked);
    try std.testing.expectEqual(want.retired, got.retired);
    try std.testing.expectEqual(want.active.depth, got.active.depth);
    try std.testing.expectEqualSlices(ra8.chip.core.cpu.exception.active.Entry, want.active.stack[0..want.active.depth], got.active.stack[0..got.active.depth]);
    try std.testing.expectEqual(want.waiting, got.waiting);
    try std.testing.expectEqual(want.exclusive, got.exclusive);
}

test "run N, snapshot inside a handler, restore, and the next M match" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var fake: Fake = .{};
    var cpu = try fixture.boot(&ram);
    cpu.source = fake.source();
    cpu.fp.bank.s[5] = 0x3F80_0000;
    _ = cpu.run(37);
    fake.pending = .{ .number = pendsv, .priority = 0x80 };
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&cpu, 0, &list);
    var copy = ram; // guest memory is RA8EMU-659's; the test copies it whole
    var fresh_fake = fake;
    var fresh = try fixture.boot(&copy);
    fresh.source = fresh_fake.source();
    try snap.load(&fresh, 0, list.written());
    try expectSame(&cpu, &fresh);
    _ = cpu.run(100);
    _ = fresh.run(100);
    try std.testing.expectEqual(@as(usize, 0), cpu.active.depth);
    try expectSame(&cpu, &fresh);
    try std.testing.expectEqualSlices(u8, &ram.bytes, &copy.bytes);
}

test "each core loads its own section" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var zero = try fixture.boot(&ram);
    var one = try fixture.boot(&ram);
    one.regs.low[7] = 0x1111_1111;
    zero.regs.low[7] = 0x0000_0001;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    try snap.save(&zero, 0, &list.writer);
    try snap.save(&one, 1, &list.writer);
    var target = try fixture.boot(&ram);
    try snap.load(&target, 1, list.written());
    try std.testing.expectEqual(@as(u32, 0x1111_1111), target.regs.low[7]);
    try snap.load(&target, 0, list.written());
    try std.testing.expectEqual(@as(u32, 0x0000_0001), target.regs.low[7]);
}

test "a missing core or a cut payload leaves the core untouched" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = 42;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&cpu, 0, &list);
    var target = try fixture.boot(&ram);
    target.regs.low[0] = 7;
    try std.testing.expectError(error.Missing, snap.load(&target, 1, list.written()));
    // Shrink the section's length so its payload ends before the stack.
    const len_at = file.magic.len + 4 + 4;
    const len = std.mem.readInt(u64, list.written()[len_at..][0..8], .little);
    std.mem.writeInt(u64, list.written()[len_at..][0..8], len - 1, .little);
    try std.testing.expectError(error.Truncated, snap.load(&target, 0, list.written()[0 .. list.written().len - 1]));
    try std.testing.expectEqual(@as(u32, 7), target.regs.low[0]);
}
