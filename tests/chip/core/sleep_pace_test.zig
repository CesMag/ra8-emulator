//! Covers src/chip/core/sleep_pace.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sleep_pace = ra8.chip.core.sleep_pace;
const fixture = @import("cpu/exception/ram.zig");
const Fake = @import("cpu/exception/fake_source.zig").Fake;

const wfi: u16 = 0xBF30;
const wfe: u16 = 0xBF20;
const nop: u16 = 0xBF00;

/// A core that ran `first` and then NOPs, with a source the test sets.
fn asleep(ram: *fixture.Ram, fake: *Fake, first: u16) !ra8.chip.core.cpu.cpu.Cpu {
    var at = fixture.code + 2;
    while (at < fixture.code + 0x40) : (at += 2) ram.putHalf(at, nop);
    ram.putHalf(fixture.code, first);
    var cpu = try fixture.boot(ram);
    cpu.source = fake.source();
    _ = cpu.run(10);
    return cpu;
}

test "an awake core keeps the width it had" {
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, false, &.{1_000_000}));
}

test "a sleeping core with no edge known keeps the width it had" {
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, true, &.{}));
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, true, &.{ 0, 0 }));
}

test "a sleeping core reaches straight to the nearest edge" {
    try std.testing.expectEqual(@as(u32, 250_000), sleep_pace.width(50_000, true, &.{ 1_000_000, 0, 250_000 }));
}

test "an edge inside the width never narrows it" {
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, true, &.{ 2_000, 1_000_000 }));
}

test "an edge past the counter's reach stops at the largest stretch" {
    try std.testing.expectEqual(@as(u32, 4_294_950_000), sleep_pace.width(50_000, true, &.{1 << 40}));
}

test "an edge between boundaries rounds up to the next whole stretch" {
    try std.testing.expectEqual(@as(u32, 300_000), sleep_pace.width(50_000, true, &.{260_000}));
    try std.testing.expectEqual(@as(u32, 250_000), sleep_pace.width(50_000, true, &.{250_000}));
}

test "a core in wfi with nothing pending is still" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try asleep(&ram, &fake, wfi);
    try std.testing.expect(sleep_pace.still(&cpu));
}

test "a pending exception, even a masked one, is not still" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try asleep(&ram, &fake, wfi);
    cpu.regs.primask = 1;
    fake.pending = .{ .number = 14, .priority = 0x80 };
    try std.testing.expect(!sleep_pace.still(&cpu));
}

test "a set event register keeps wfe from being still and is not taken" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try asleep(&ram, &fake, wfe);
    cpu.waiting = .event;
    cpu.event = true;
    try std.testing.expect(!sleep_pace.still(&cpu));
    try std.testing.expect(cpu.event);
}

test "an awake core is not still" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try asleep(&ram, &fake, nop);
    try std.testing.expect(!sleep_pace.still(&cpu));
}
