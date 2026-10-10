//! Covers src/chip/core/cpu/exception/sleep.zig, through `Cpu.run`.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const Fake = @import("fake_source.zig").Fake;
const sleep = ra8.chip.core.cpu.exception.sleep;

const pendsv: u9 = 14;
const nop: u16 = 0xBF00;
const wfi: u16 = 0xBF30;
const wfe: u16 = 0xBF20;
const bx_lr: u16 = 0x4770;

/// Thread code is `first` and then NOPs; PendSV goes to a NOP and BX LR.
fn setup(ram: *fixture.Ram, fake: *Fake, first: u16) !ra8.chip.core.cpu.cpu.Cpu {
    var at = fixture.code + 2;
    while (at < fixture.code + 0x40) : (at += 2) ram.putHalf(at, nop);
    ram.putHalf(fixture.code, first);
    ram.putHalf(fixture.handler, nop);
    ram.putHalf(fixture.handler + 2, bx_lr);
    ram.putWord(fixture.base + 4 * @as(u32, pendsv), fixture.handler | 1);
    var cpu = try fixture.boot(ram);
    cpu.source = fake.source();
    return cpu;
}

test "wfi with nothing pending sleeps and the rest of the stretch goes by" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, wfi);
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, cpu.run(100));
    try std.testing.expectEqual(@as(u64, 1), cpu.retired);
    try std.testing.expectEqual(@as(?sleep.Wait, .interrupt), cpu.waiting);
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    _ = cpu.run(100);
    try std.testing.expectEqual(@as(u64, 1), cpu.retired);
}

test "an interrupt wakes wfi, runs its handler and resumes after the wfi" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, wfi);
    _ = cpu.run(10);
    fake.pending = .{ .number = pendsv, .priority = 0x80 };
    _ = cpu.run(1); // taken, then the handler's NOP
    try std.testing.expectEqual(@as(?sleep.Wait, null), cpu.waiting);
    try std.testing.expectEqual(fixture.handler + 2, cpu.regs.pc);
    _ = cpu.run(1); // BX LR
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
}

test "PRIMASK holds the interrupt but still wakes wfi" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, wfi);
    cpu.regs.primask = 1;
    _ = cpu.run(10);
    fake.pending = .{ .number = pendsv, .priority = 0x80 };
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(?sleep.Wait, null), cpu.waiting);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
}

test "wfe with the event clear sleeps until an interrupt is taken" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, wfe);
    _ = cpu.run(10);
    try std.testing.expectEqual(@as(?sleep.Wait, .event), cpu.waiting);
    fake.pending = .{ .number = pendsv, .priority = 0x80 };
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(?sleep.Wait, null), cpu.waiting);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
}

test "a pend that cannot preempt wakes wfe only under SEVONPEND" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, wfe);
    cpu.regs.basepri = 0x40;
    _ = cpu.run(10);
    fake.pending = .{ .number = pendsv, .priority = 0x80 };
    _ = cpu.run(5);
    try std.testing.expectEqual(@as(?sleep.Wait, .event), cpu.waiting);
    ram.putWord(sleep.scr, sleep.sevonpend);
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(?sleep.Wait, null), cpu.waiting);
    try std.testing.expect(!cpu.event);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
}

test "wfe with the event already set does not sleep" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, wfe);
    cpu.event = true;
    _ = cpu.run(3);
    try std.testing.expectEqual(@as(?sleep.Wait, null), cpu.waiting);
    try std.testing.expectEqual(@as(u64, 3), cpu.retired);
}

test "with no exception source wfi completes at once" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake, wfi);
    cpu.source = null;
    _ = cpu.run(3);
    try std.testing.expectEqual(@as(u64, 3), cpu.retired);
}
