//! Covers src/chip/core/cpu/reset.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const reset = ra8.chip.core.cpu.reset;

const Table = struct {
    words: []const u32,

    fn view(self: *Table) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Table = @ptrCast(@alignCast(ctx));
        const at = address / 4;
        if (into.len != 4 or address % 4 != 0 or at >= self.words.len) return bus.Error.Unmapped;
        std.mem.writeInt(u32, into[0..4], self.words[at], .little);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

test "reset loads MSP and the handler and sets T from bit 0" {
    var table: Table = .{ .words = &.{ 0x2200_0000, 0x0200_0401 } };
    var r: regs.Regs = .{ .psp = 0x1234, .control = 3 };
    try reset.fromVectorTable(&r, table.view(), 0);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), r.msp);
    try std.testing.expectEqual(@as(u32, 0x0200_0400), r.pc);
    try std.testing.expectEqual(regs.xpsr_bits.thumb, r.xpsr);
    try std.testing.expectEqual(reset.lr_at_reset, r.lr);
    try std.testing.expectEqual(@as(u32, 0), r.control);
    try std.testing.expectEqual(@as(u32, 0), r.psp);
}

test "an even reset handler leaves T clear" {
    var table: Table = .{ .words = &.{ 0x2200_0000, 0x0200_0400 } };
    var r: regs.Regs = .{};
    try reset.fromVectorTable(&r, table.view(), 0);
    try std.testing.expectEqual(@as(u32, 0), r.xpsr & regs.xpsr_bits.thumb);
}

test "a vector table nothing answers for fails the reset" {
    var table: Table = .{ .words = &.{0x2200_0000} };
    var r: regs.Regs = .{};
    try std.testing.expectError(bus.Error.Unmapped, reset.fromVectorTable(&r, table.view(), 0));
}

test "reset re-arms both stack low-water marks" {
    var table: Table = .{ .words = &.{ 0x2200_2000, 0x0200_0401 } };
    var r: regs.Regs = .{ .low_msp = 0x2200_0100, .low_psp = 0x2200_0200 };
    try reset.fromVectorTable(&r, table.view(), 0);
    try std.testing.expectEqual(@as(u32, 0x2200_2000), r.low_msp);
    try std.testing.expectEqual(regs.never_low, r.low_psp);
}
