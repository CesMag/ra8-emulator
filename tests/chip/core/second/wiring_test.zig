//! Tests for src/chip/core/second_wiring.zig: CPU1's hooks reach whatever board
//! handed over the wiring, with no board type in the chip (RA8EMU-1012).
const std = @import("std");
const ra8 = @import("ra8");
const Wiring = ra8.chip.core.second.core.Wiring;
const CoreWindows = ra8.board.wiring.CoreWindows;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

/// Stands in for the board: counts what CPU1 asked of it.
const Host = struct {
    primed: u32 = 0,
    identity: u32 = 0,
    resets: u32 = 0,

    fn prime(context: *anyopaque, memory: Guest, windows: CoreWindows) anyerror!void {
        _ = memory;
        const self: *Host = @ptrCast(@alignCast(context));
        self.primed += 1;
        self.identity = windows.identity;
    }

    fn reset(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.resets += 1;
    }
};

fn wiringFor(host: *Host, bus: *ra8.chip.periph.registry.Bus, slot: *?Guest) Wiring {
    const statics = struct {
        const dividers: u16 = 0;
        const reboot: ?*ra8.chip.core.reboot.Reboot = null;
        const release: ra8.chip.periph.cpu_ctrl.CpuCtrl = .{};
    };
    return .{
        .bus = bus,
        .dividers = &statics.dividers,
        .reboot = &statics.reboot,
        .release = &statics.release,
        .cpu1 = slot,
        .context = host,
        .primeFn = Host.prime,
        .resetFn = Host.reset,
    };
}

test "a reset request goes to the host behind the wiring" {
    var host: Host = .{};
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var slot: ?Guest = null;
    const wiring = wiringFor(&host, &bus, &slot);
    wiring.requestReset();
    wiring.requestReset();
    try std.testing.expectEqual(@as(u32, 2), host.resets);
}

test "priming hands the host CPU1's own windows" {
    var host: Host = .{};
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var slot: ?Guest = null;
    const wiring = wiringFor(&host, &bus, &slot);
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    var partitions = ra8.chip.periph.sau.Sau.init();
    var regions = ra8.chip.periph.mpu.Mpu.init();
    var guard = ra8.chip.core.mpu_guard.Guard.init();
    var control = ra8.chip.periph.scb.Scb.init();
    var clears = ra8.chip.core.cpu.board_bus.fault_clear.Clears.init();
    try wiring.prime(.{ .store = &store }, .{
        .partitions = &partitions,
        .regions = &regions,
        .guard = &guard,
        .identity = ra8.chip.periph.cpuid.cpu1,
        .control = &control,
        .clears = &clears,
    });
    try std.testing.expectEqual(@as(u32, 1), host.primed);
    try std.testing.expectEqual(ra8.chip.periph.cpuid.cpu1, host.identity);
}
