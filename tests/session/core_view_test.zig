//! Tests for src/session/core_view.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const zig_core = ra8.session.step_hook.zig_core;
const View = ra8.session.step_hook.core_view.View;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

/// Write a register and a word, then read both back, through `view`.
fn roundTrip(view: View, address: u32) !void {
    try view.setRegister(.r4, 0xCAFE_F00D);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), try view.register(.r4));
    try view.write(address, &[_]u8{ 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try view.readWord(address));
    var bytes: [2]u8 = undefined;
    try view.read(address + 2, &bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x34, 0x12 }, &bytes);
}

test "the Zig core reads and writes through the view" {
    var memory: Ram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    try roundTrip(.{ .zig = .{ .cpu = &cpu } }, 0x20);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.low[4]);
}

test "an unmapped read is an error on the Zig core" {
    var memory: Ram = .{};
    var cpu: Cpu = .{ .bus = memory.view() };
    const view: View = .{ .zig = .{ .cpu = &cpu } };
    try std.testing.expectError(bus.Error.Unmapped, view.readWord(0x1000));
}
