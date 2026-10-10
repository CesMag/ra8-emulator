//! Covers src/chip/core/cpu/exception/dispatch.zig, through `Cpu.run`.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const Fake = @import("fake_source.zig").Fake;

const pendsv: u9 = 14;
const systick: u9 = 15;
const nop: u16 = 0xBF00;
const bx_lr: u16 = 0x4770;

/// Thread code is a run of NOPs; PendSV and SysTick both go to a handler
/// that is a NOP and BX LR.
fn setup(ram: *fixture.Ram, fake: *Fake) !ra8.chip.core.cpu.cpu.Cpu {
    var at = fixture.code;
    while (at < fixture.code + 0x40) : (at += 2) ram.putHalf(at, nop);
    ram.putHalf(fixture.handler, nop);
    ram.putHalf(fixture.handler + 2, bx_lr);
    ram.putWord(fixture.base + 4 * @as(u32, pendsv), fixture.handler | 1);
    ram.putWord(fixture.base + 4 * @as(u32, systick), fixture.handler | 1);
    var cpu = try fixture.boot(ram);
    cpu.source = fake.source();
    return cpu;
}

test "a pending exception is taken before the next instruction and returns to it" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake);
    _ = cpu.run(2);
    fake.pending = .{ .number = pendsv, .priority = 0xFF };
    _ = cpu.run(1); // taken, then the handler's NOP
    try std.testing.expectEqual(fixture.handler + 2, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, pendsv), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
    _ = cpu.run(1); // BX LR
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(@as(?u9, pendsv), fake.last_returned);
    try std.testing.expectEqual(@as(usize, 0), cpu.active.depth);
}

test "PRIMASK holds a pending exception until it clears" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = 0 } };
    var cpu = try setup(&ram, &fake);
    cpu.regs.primask = 1;
    _ = cpu.run(3);
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
    cpu.regs.primask = 0;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
}

test "BASEPRI holds what is no more urgent than it" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = systick, .priority = 0x40 } };
    var cpu = try setup(&ram, &fake);
    cpu.regs.basepri = 0x40;
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
    cpu.regs.basepri = 0x80;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
}

test "a running handler is preempted only by something more urgent" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = 0x80 } };
    var cpu = try setup(&ram, &fake);
    _ = cpu.run(1);
    fake.pending = .{ .number = systick, .priority = 0x80 };
    cpu.regs.pc = fixture.handler; // stay on the handler's NOP
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    fake.pending = .{ .number = systick, .priority = 0x40 };
    cpu.regs.pc = fixture.handler;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 2), cpu.active.depth);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF1), cpu.regs.lr);
}

test "a pend with no vector is left pending" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = 20, .priority = 0 } };
    var cpu = try setup(&ram, &fake);
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
}

test "SVC runs at the priority SHPR2 gives it and leaves the stack on return" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake);
    ram.putWord(0xE000_ED1C, 0x6000_0000);
    ram.putHalf(fixture.code, 0xDF00);
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(u8, 0x60), cpu.active.running().?.priority);
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(usize, 0), cpu.active.depth);
    try std.testing.expectEqual(@as(?u9, 11), fake.last_returned);
}

test "a step on its own never takes an asynchronous exception" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = 0 } };
    var cpu = try setup(&ram, &fake);
    _ = cpu.step();
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
}

/// The fixture RAM with AIRCR answered on top, so PRIGROUP can be set.
const WithAircr = struct {
    ram: *fixture.Ram,
    aircr: u32,

    fn view(self: *WithAircr) ra8.chip.core.cpu.bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *WithAircr = @ptrCast(@alignCast(ctx));
        if (address != ra8.chip.core.memmap.scb.aircr or into.len != 4) return self.ram.view().read(address, into);
        std.mem.writeInt(u32, into[0..4], self.aircr, .little);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *WithAircr = @ptrCast(@alignCast(ctx));
        return self.ram.view().write(address, bytes);
    }
};

test "under PRIGROUP a more urgent subpriority in the same group does not preempt" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = 0x60 } };
    var cpu = try setup(&ram, &fake);
    var split: WithAircr = .{ .ram = &ram, .aircr = 5 << 8 }; // bits [5:0] subpriority
    cpu.bus = split.view();
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    fake.pending = .{ .number = systick, .priority = 0x40 }; // group 0x40, same as 0x60
    cpu.regs.pc = fixture.handler;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    split.aircr = 0; // PRIGROUP 0: 0x40 beats 0x60
    cpu.regs.pc = fixture.handler;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 2), cpu.active.depth);
}

/// Runs `first`, then offers `second` from inside its handler under
/// `prigroup`, and gives the nesting depth that leaves.
fn depthAfter(prigroup: u3, first: u8, second: u8) !usize {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = first } };
    var cpu = try setup(&ram, &fake);
    var split: WithAircr = .{ .ram = &ram, .aircr = @as(u32, prigroup) << 8 };
    cpu.bus = split.view();
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    fake.pending = .{ .number = systick, .priority = second };
    cpu.regs.pc = fixture.handler;
    _ = cpu.run(1);
    return cpu.active.depth;
}

test "a more urgent subpriority in the same group never preempts, at several PRIGROUP values" {
    const Case = struct { prigroup: u3, running: u8, offered: u8 };
    const cases = [_]Case{
        .{ .prigroup = 0, .running = 0x61, .offered = 0x60 }, // group [7:1]
        .{ .prigroup = 3, .running = 0x6C, .offered = 0x60 }, // group [7:4]
        .{ .prigroup = 5, .running = 0x60, .offered = 0x40 }, // group [7:6]
        .{ .prigroup = 7, .running = 0xE0, .offered = 0x00 }, // no group bits
    };
    for (cases) |case| {
        try std.testing.expectEqual(@as(usize, 1), try depthAfter(case.prigroup, case.running, case.offered));
    }
}

test "a more urgent group still preempts, at several PRIGROUP values" {
    const Case = struct { prigroup: u3, running: u8, offered: u8 };
    const cases = [_]Case{
        .{ .prigroup = 0, .running = 0x62, .offered = 0x60 },
        .{ .prigroup = 3, .running = 0x70, .offered = 0x60 },
        .{ .prigroup = 5, .running = 0x80, .offered = 0x40 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(@as(usize, 2), try depthAfter(case.prigroup, case.running, case.offered));
    }
}

test "taking an exception and returning from it both set the event register" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake);
    try std.testing.expect(!cpu.event);
    fake.pending = .{ .number = pendsv, .priority = 0xFF };
    _ = cpu.run(1); // taken, then the handler's NOP
    try std.testing.expect(cpu.event);
    cpu.event = false;
    _ = cpu.run(1); // BX LR
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expect(cpu.event);
}
