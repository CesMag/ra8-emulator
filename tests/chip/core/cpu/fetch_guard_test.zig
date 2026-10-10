//! Covers src/chip/core/cpu/fetch_guard.zig: the check the core makes before
//! each instruction (RA8EMU-603, `--stop-on-undefined`).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const cpu_mod = ra8.chip.core.cpu.cpu;

/// Holds at one address, and counts every time it is asked about it.
const Watch = struct {
    at: u32,
    hold: bool,
    asked: u64 = 0,

    fn guard(self: *Watch) cpu_mod.FetchGuard {
        return .{ .context = self, .holdsFn = holds };
    }

    fn holds(context: *anyopaque, address: u32) bool {
        const self: *Watch = @ptrCast(@alignCast(context));
        if (address != self.at) return false;
        self.asked += 1;
        return self.hold;
    }
};

// NOP; B back to the NOP.
const park_loop = [_]u16{ 0xBF00, 0xE7FD };

fn boot(ram: *fixture.Ram) !cpu_mod.Cpu {
    for (park_loop, 0..) |half, i| ram.putHalf(fixture.code + @as(u32, @intCast(2 * i)), half);
    return fixture.boot(ram);
}

test "a held instruction ends the stretch before it runs" {
    var ram: fixture.Ram = .{};
    var cpu = try boot(&ram);
    var watch: Watch = .{ .at = fixture.code, .hold = true };
    cpu.fetch_guard = watch.guard();
    try std.testing.expectEqual(cpu_mod.Stop.count, cpu.run(100));
    try std.testing.expectEqual(@as(u64, 0), cpu.retired);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
}

test "a guard that never holds is asked on every trip" {
    var ram: fixture.Ram = .{};
    var cpu = try boot(&ram);
    var watch: Watch = .{ .at = fixture.code, .hold = false };
    cpu.fetch_guard = watch.guard();
    try std.testing.expectEqual(cpu_mod.Stop.count, cpu.run(100));
    try std.testing.expectEqual(@as(u64, 100), cpu.retired);
    try std.testing.expectEqual(@as(u64, 50), watch.asked);
}
