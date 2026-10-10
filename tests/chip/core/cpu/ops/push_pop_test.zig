//! Covers src/chip/core/cpu/ops/push_pop.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const push_pop = ra8.chip.core.cpu.ops.push_pop;

/// 64 bytes of RAM at 0x2000_0000.
const Ram = struct {
    const base: u32 = 0x2000_0000;
    bytes: [64]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slot(self: *Ram, address: u32, len: usize) bus.Error![]u8 {
        if (address < base or address - base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slot(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slot(address, from.len), from);
    }

    fn word(self: *Ram, address: u32) u32 {
        return std.mem.readInt(u32, (self.slot(address, 4) catch unreachable)[0..4], .little);
    }
};

fn run(cpu: *Cpu, hw1: u16) !void {
    const exec = push_pop.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) orelse return error.NotClaimed;
    try exec(cpu, .{ .address = 0, .hw1 = hw1, .size = 2 });
}

test "the register list adds LR for PUSH and PC for POP" {
    try std.testing.expectEqual(@as(u16, 0x4080), push_pop.list(0xB580)); // push {r7, lr}
    try std.testing.expectEqual(@as(u16, 0x8080), push_pop.list(0xBD80)); // pop {r7, pc}
    try std.testing.expectEqual(@as(u16, 0x0011), push_pop.list(0xBC11)); // pop {r0, r4}
}

test "an empty list and other encodings are not claimed" {
    for ([_]u16{ 0xB400, 0xBC00, 0xBF00, 0xB080, 0xB600 }) |hw1| {
        try std.testing.expect(push_pop.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}

test "push {r7, lr} stores lowest register lowest and lowers SP by eight" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.msp = Ram.base + 64;
    cpu.regs.low[7] = 0x1111_7777;
    cpu.regs.lr = 0xFFFF_FFF9;
    try run(&cpu, 0xB580);
    try std.testing.expectEqual(Ram.base + 56, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0x1111_7777), ram.word(Ram.base + 56));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), ram.word(Ram.base + 60));
}

test "push then pop restores the registers and SP" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.msp = Ram.base + 64;
    cpu.regs.low[0] = 10;
    cpu.regs.low[4] = 44;
    try run(&cpu, 0xB411); // push {r0, r4}
    cpu.regs.low[0] = 0;
    cpu.regs.low[4] = 0;
    try run(&cpu, 0xBC11); // pop {r0, r4}
    try std.testing.expectEqual(@as(u32, 10), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 44), cpu.regs.low[4]);
    try std.testing.expectEqual(Ram.base + 64, cpu.regs.msp);
}

test "pop into the PC clears bit 0 into EPSR.T" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.msp = Ram.base + 56;
    cpu.regs.xpsr = 0;
    std.mem.writeInt(u32, ram.bytes[56..60], 0x0000_0042, .little);
    std.mem.writeInt(u32, ram.bytes[60..64], 0x0800_1235, .little);
    try run(&cpu, 0xBD80); // pop {r7, pc}
    try std.testing.expectEqual(@as(u32, 0x42), cpu.regs.low[7]);
    try std.testing.expectEqual(@as(u32, 0x0800_1234), cpu.regs.pc);
    try std.testing.expect(cpu.regs.xpsr & regs.xpsr_bits.thumb != 0);
    try std.testing.expectEqual(Ram.base + 64, cpu.regs.msp);
}

test "a push that faults leaves SP alone" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.msp = Ram.base + 4;
    try std.testing.expectError(bus.Error.Unmapped, run(&cpu, 0xB403)); // push {r0, r1}
    try std.testing.expectEqual(Ram.base + 4, cpu.regs.msp);
}

test "the process stack is used in Thread mode with SPSEL set" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.control = regs.control_bits.spsel;
    cpu.regs.psp = Ram.base + 32;
    cpu.regs.msp = Ram.base + 64;
    cpu.regs.low[1] = 0xAB;
    try run(&cpu, 0xB402); // push {r1}
    try std.testing.expectEqual(Ram.base + 28, cpu.regs.psp);
    try std.testing.expectEqual(Ram.base + 64, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xAB), ram.word(Ram.base + 28));
}
