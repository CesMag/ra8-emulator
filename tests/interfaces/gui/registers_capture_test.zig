//! Covers src/interfaces/gui/registers_capture.zig (RA8EMU-1078): each of
//! the pane's names is the tag of the session register read for it, and
//! capture reads CPU0 and CPU1 separately through a real session.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig_session;
const api = ra8.session.api;
const pane = gui_app.registers_pane;
const capture = gui_app.registers_capture;

test "each shown register is the one the pane names" {
    for (capture.shown, pane.names) |which, name| try std.testing.expectEqualStrings(name, @tagName(which));
}

/// A RAM image holding a vector table: initial sp 0x40, reset at 0x08.
const Ram = struct {
    bytes: [256]u8 = @splat(0),

    fn init() Ram {
        var memory: Ram = .{};
        @memcpy(memory.bytes[0..8], &[_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0 });
        return memory;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

test "capture reads each core's registers through the session" {
    var memory0 = Ram.init();
    var memory1 = Ram.init();
    var cpu0: Cpu = .{ .bus = memory0.view() };
    var cpu1: Cpu = .{ .bus = memory1.view() };
    try cpu0.reset(0);
    try cpu1.reset(0);
    var machine0 = Machine{};
    var machine1 = Machine{};
    var live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu0 }, .machine = &machine0, .budget = 100 };
    live.other = .{ .core = .{ .cpu = &cpu1 }, .machine = &machine1, .budget = 100, .index = 1 };
    var session: api.Session = .{ .live = live };
    try session.setRegister(.cpu0, .r0, 0xCAFE_0000);
    try session.setRegister(.cpu1, .r0, 0x0000_BEEF);
    const zero = try capture.capture(&session, .cpu0);
    const one = try capture.capture(&session, .cpu1);
    try std.testing.expectEqual(@as(u32, 0xCAFE_0000), zero.values[0]);
    try std.testing.expectEqual(@as(u32, 0x0000_BEEF), one.values[0]);
    try std.testing.expectEqual(@as(u32, 0x40), zero.values[13]);
    try std.testing.expect(one.changedAt(zero, 0));
    try std.testing.expect(!one.changedAt(zero, 13));
    try std.testing.expect(zero.mve);
    try std.testing.expect(!one.mve);
}
