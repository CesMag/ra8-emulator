//! Tests for src/session/zig_cycles.zig, through the Zig session that runs it.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig_session;

const cyccnt: u32 = 0xE000_1004;
const dfsr: u32 = 0xE000_ED30;

/// 64 bytes of RAM at address 0, plus the DWT_CYCCNT and DFSR words.
const Rig = struct {
    bytes: [64]u8 = @splat(0),
    cycles: u32 = 0,
    dfsr: u32 = 0,

    fn view(self: *Rig) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn word(self: *Rig, address: u32) ?*u32 {
        if (address == cyccnt) return &self.cycles;
        if (address == dfsr) return &self.dfsr;
        return null;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        if (self.word(address)) |at| {
            if (into.len != 4) return bus.Error.Unmapped;
            std.mem.writeInt(u32, into[0..4], at.*, .little);
            return;
        }
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Rig = @ptrCast(@alignCast(ctx));
        if (self.word(address)) |at| {
            if (from.len != 4) return bus.Error.Unmapped;
            at.* = std.mem.readInt(u32, from[0..4], .little);
            return;
        }
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

// sp 0x40, reset 0x09 ; 0x08 e7fe b . : a loop that never stops on its own
fn rig() Rig {
    var r: Rig = .{};
    const image = [_]u8{ 0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0xFE, 0xE7 };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

/// COMP0 = `at`, FUNCTION0 = Cycle Counter match, debug event.
fn armCycles(machine: *Machine, at: u32) void {
    machine.dwt.trcena = true;
    _ = machine.dwt.write(0x20, at);
    _ = machine.dwt.write(0x28, 0x11);
}

test "a Cycle Counter comparator stops the Zig core on the count it names" {
    var memory = rig();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    armCycles(&machine, 40);
    var session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1000 };
    const ended = try session.go(.cont);
    try std.testing.expectEqual(.unit_watch, std.meta.activeTag(ended.stop));
    try std.testing.expectEqual(@as(u32, 40), memory.cycles);
    try std.testing.expectEqual(@as(u32, 0x4), memory.dfsr & 0x4);
}

test "without a Cycle Counter comparator nothing is counted, and a break latches DFSR.BKPT" {
    var memory = rig();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 50 };
    try std.testing.expect((try session.go(.cont)) == .count);
    try std.testing.expectEqual(@as(u32, 0), memory.cycles);
    _ = try machine.addBreak(.{ .address = 0x08 });
    try std.testing.expectEqual(.breakpoint, std.meta.activeTag((try session.go(.cont)).stop));
    try std.testing.expectEqual(@as(u32, 0x2), memory.dfsr & 0x2);
    try std.testing.expectEqual(@as(u32, 0), memory.cycles);
}
