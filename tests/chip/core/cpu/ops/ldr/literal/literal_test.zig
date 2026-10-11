//! Covers src/chip/core/cpu/ops/ldr/literal/literal.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const ldr_literal = ra8.chip.core.cpu.ops.ldr.literal;

/// 64 bytes of flash at 0x0800_0000, read-only.
const Flash = struct {
    const base: u32 = 0x0800_0000;
    bytes: [64]u8 = @splat(0),

    fn view(self: *Flash) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Flash = @ptrCast(@alignCast(ctx));
        if (address < base or address - base + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address - base ..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

fn run(cpu: *Cpu, instr: Instr) !void {
    const exec = ldr_literal.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "the literal address aligns the PC down before adding" {
    try std.testing.expectEqual(@as(u32, 0x0800_0008), ldr_literal.address(.{ .address = 0x0800_0002, .hw1 = 0x4B01, .size = 2 }));
    try std.testing.expectEqual(@as(u32, 0x0800_0008), ldr_literal.address(.{ .address = 0x0800_0000, .hw1 = 0x4B01, .size = 2 }));
    try std.testing.expectEqual(@as(u32, 0x0800_0004 + 1020), ldr_literal.address(.{ .address = 0x0800_0000, .hw1 = 0x48FF, .size = 2 }));
}

test "ldr r3, [pc, #4] loads the word from the pool" {
    var flash: Flash = .{};
    std.mem.writeInt(u32, flash.bytes[8..12], 0x4001_E000, .little);
    var cpu: Cpu = .{ .bus = flash.view() };
    try run(&cpu, .{ .address = 0x0800_0002, .hw1 = 0x4B01, .size = 2 });
    try std.testing.expectEqual(@as(u32, 0x4001_E000), cpu.regs.low[3]);
}

test "a pool beyond mapped memory faults and leaves Rt alone" {
    var flash: Flash = .{};
    var cpu: Cpu = .{ .bus = flash.view() };
    cpu.regs.low[0] = 7;
    try std.testing.expectError(bus.Error.Unmapped, run(&cpu, .{ .address = 0x0800_0000, .hw1 = 0x48FF, .size = 2 }));
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.low[0]);
}

test "neighbouring encodings are not claimed" {
    // 4700 bx r0, 5800 ldr reg, 9800 ldr sp-rel, 4000 ands
    for ([_]u16{ 0x4700, 0x5800, 0x9800, 0x4000 }) |hw1| {
        try std.testing.expect(ldr_literal.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
