//! Tests for src/session/zig/core.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const zig_core = ra8.session.step_hook.zig.core;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8,

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

// sp 0x00000040, reset 0x09 ; bf00 nop ; bf00 nop ; bf00 nop ; ba80 (unallocated)
fn ram() Ram {
    var r: Ram = .{ .bytes = @as([64]u8, @splat(0)) };
    const image = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
        0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF, 0x80, 0xBA,
    };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

test "registers read and write by the engine's names" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try std.testing.expectEqual(@as(u32, 0x08), core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x40), core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), core.register(.lr));
    core.setRegister(.r7, 0x1234);
    core.setRegister(.r12, 0x5678);
    try std.testing.expectEqual(@as(u32, 0x1234), core.register(.r7));
    try std.testing.expectEqual(@as(u32, 0x5678), cpu.regs.low[12]);
}

test "the stack limits read back with bits 2:0 cleared, as MSR writes them" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    core.setRegister(.msplim, 0x2000_0107);
    core.setRegister(.psplim, 0x2000_0FFF);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), core.register(.msplim));
    try std.testing.expectEqual(@as(u32, 0x2000_0FF8), core.register(.psplim));
    try std.testing.expectEqual(@as(u32, 0x2000_0100), cpu.regs.msplim);
}

test "the single-precision bank reads and writes raw bits, one S register at a time" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    core.setRegister(.s0, 0x3F80_0000);
    core.setRegister(.s31, 0x7FC0_0001);
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), core.register(.s0));
    try std.testing.expectEqual(@as(u32, 0x7FC0_0001), core.register(.s31));
    try std.testing.expectEqual(@as(u32, 0), core.register(.s1));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.s[0]);
}

test "VPR reads and writes as its raw 32 bits: P0, then the two VPT masks" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    core.setRegister(.vpr, 0x0012_00FF);
    try std.testing.expectEqual(@as(u32, 0x0012_00FF), core.register(.vpr));
    try std.testing.expectEqual(@as(u16, 0x00FF), cpu.fp.vpr.p0);
    try std.testing.expectEqual(@as(u4, 2), cpu.fp.vpr.mask01);
    try std.testing.expectEqual(@as(u4, 1), cpu.fp.vpr.mask23);
}

test "memory goes through the core's bus" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try core.write(0x30, &[_]u8{ 0xEF, 0xBE, 0xAD, 0xDE });
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try core.readWord(0x30));
    try std.testing.expectError(bus.Error.Unmapped, core.readWord(0x100));
}

test "a step retires one instruction" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), core.step());
    try std.testing.expectEqual(@as(u32, 0x0A), core.register(.pc));
    try std.testing.expectEqual(@as(u64, 1), cpu.retired);
}

test "a run stops on a breakpoint and moves off it when continued" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    const breaks = [_]u32{ 0x0B, 0x0C };
    try std.testing.expectEqual(@as(u32, 0x0A), core.runUntil(&breaks, 100).breakpoint);
    try std.testing.expectEqual(@as(u32, 0x0C), core.runUntil(&breaks, 100).breakpoint);
}

test "a run reports the core's own stop and its count" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try std.testing.expectEqual(zig_core.Stop.count, core.runUntil(&.{}, 2));
    const stopped = core.runUntil(&.{}, 100);
    try std.testing.expectEqual(@as(u32, 0x0E), stopped.core.unknown.address);
}

test "stack reports both pointers and the lowest each reached" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    core.setRegister(.msp, 0x20);
    core.setRegister(.msp, 0x30);
    core.setRegister(.psp, 0x18);
    const marks = core.stack();
    try std.testing.expectEqual(@as(u32, 0x30), marks.msp);
    try std.testing.expectEqual(@as(u32, 0x20), marks.low_msp);
    try std.testing.expectEqual(@as(u32, 0x18), marks.psp);
    try std.testing.expectEqual(@as(u32, 0x18), marks.low_psp);
}
