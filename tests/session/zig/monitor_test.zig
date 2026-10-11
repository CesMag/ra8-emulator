//! Tests for src/session/zig_monitor.zig: a unit event held with halting
//! debug off pends DebugMonitor on the Zig core
//! (RA8EMU-673).
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const zig_monitor = ra8.session.step_hook.zig.drive.zig_monitor;
const ZigCore = ra8.session.step_hook.zig.core.ZigCore;
const dcb = ra8.chip.periph.dcb;

/// Just the DEMCR and DFSR words.
const Rig = struct {
    demcr: u32 = 0,
    dfsr: u32 = 0,
    cpu: Cpu = undefined,

    fn core(self: *Rig) ZigCore {
        self.cpu = .{ .bus = .{ .ctx = self, .vtable = &.{ .read = read, .write = write } } };
        return .{ .cpu = &self.cpu };
    }

    fn word(self: *Rig, address: u32) bus.Error!*u32 {
        if (address == dcb.demcr_address) return &self.demcr;
        if (address == dcb.dfsr_address) return &self.dfsr;
        return bus.Error.Unmapped;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        if (into.len != 4) return bus.Error.Unmapped;
        std.mem.writeInt(u32, into[0..4], (try self.word(address)).*, .little);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        if (from.len != 4) return bus.Error.Unmapped;
        (try self.word(address)).* = std.mem.readInt(u32, from[0..4], .little);
    }
};

test "a breakpoint event with MON_EN set pends DebugMonitor and latches DFSR.BKPT" {
    var rig: Rig = .{ .demcr = dcb.demcr_bits.mon_en };
    var machine: Machine = .{ .halting = false };
    zig_monitor.pend(rig.core(), &machine, .breakpoint);
    try std.testing.expectEqual(dcb.demcr_bits.mon_en | dcb.demcr_bits.mon_pend, rig.demcr);
    try std.testing.expect(rig.dfsr & dcb.dfsr_bits.bkpt != 0);
    try std.testing.expectEqual(machine.dcb.dfsr, rig.dfsr);
}

test "a watchpoint event with MON_EN set latches DFSR.DWTTRAP" {
    var rig: Rig = .{ .demcr = dcb.demcr_bits.mon_en };
    var machine: Machine = .{ .halting = false };
    zig_monitor.pend(rig.core(), &machine, .watchpoint);
    try std.testing.expect(rig.demcr & dcb.demcr_bits.mon_pend != 0);
    try std.testing.expect(rig.dfsr & dcb.dfsr_bits.dwttrap != 0);
    try std.testing.expect(rig.dfsr & dcb.dfsr_bits.bkpt == 0);
}

test "with MON_EN clear the event is dropped" {
    var rig: Rig = .{};
    var machine: Machine = .{ .halting = false };
    zig_monitor.pend(rig.core(), &machine, .breakpoint);
    try std.testing.expectEqual(@as(u32, 0), rig.demcr);
    try std.testing.expectEqual(@as(u32, 0), rig.dfsr);
}

test "take pends only when the machine holds an event, and only once" {
    var rig: Rig = .{ .demcr = dcb.demcr_bits.mon_en };
    var machine: Machine = .{ .halting = false };
    zig_monitor.take(rig.core(), &machine);
    try std.testing.expectEqual(dcb.demcr_bits.mon_en, rig.demcr);
    machine.monitor_pending = .breakpoint;
    zig_monitor.take(rig.core(), &machine);
    try std.testing.expect(rig.demcr & dcb.demcr_bits.mon_pend != 0);
    try std.testing.expectEqual(@as(?ra8.session.stop_machine.Monitor, null), machine.monitor_pending);
}
