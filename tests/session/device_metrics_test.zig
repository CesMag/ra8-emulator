const std = @import("std");
const metrics = @import("ra8").session.device_metrics;

test "device metrics interval distinguishes pinned, sleeping, stopped and reset" {
    var window: metrics.Window = .{};
    var snapshot: metrics.Snapshot = .{ .attached = true, .active = 100 };
    window.sample(&snapshot);
    try std.testing.expect(!window.pinned);
    snapshot.active = 200;
    window.sample(&snapshot);
    try std.testing.expectEqual(@as(u8, 100), window.percent);
    try std.testing.expect(window.pinned);
    snapshot.active = 250;
    snapshot.idle = 50;
    window.sample(&snapshot);
    try std.testing.expectEqual(@as(u8, 50), window.percent);
    try std.testing.expect(!window.pinned);
    window.sample(&snapshot);
    try std.testing.expect(!window.pinned);
    snapshot.active = 0;
    snapshot.idle = 0;
    window.sample(&snapshot);
    try std.testing.expect(!window.pinned);
}

test "stack headroom warns below ten percent and outside bounds" {
    var stack: metrics.Stack = .{ .limit = 1000, .top = 2000, .pointer = 1100 };
    try std.testing.expect(!stack.warning());
    stack.pointer = 1099;
    try std.testing.expect(stack.warning());
    try std.testing.expectEqual(@as(u32, 901), stack.used());
    stack.pointer = 900;
    try std.testing.expect(stack.warning());
    stack.pointer = 2001;
    try std.testing.expect(stack.warning());
    try std.testing.expect(!(metrics.Stack{}).warning());
}

test "stack gauges compare Secure and Non-secure SRAM aliases by backing address" {
    const map = @import("ra8").chip.core.memmap;
    const stack: metrics.Stack = .{ .limit = map.sram_base + 0x1000, .top = map.sram_base + 0x2000, .pointer = map.ns_sram_base + 0x1800 };
    try std.testing.expectEqual(@as(u32, 0x800), stack.used());
    try std.testing.expect(!stack.warning());
    var low = stack;
    low.pointer = map.ns_sram_base + 0x1001;
    try std.testing.expect(low.warning());
}

test "restore epoch resets pinned window even replay passed prior sampled counters" {
    var window: metrics.Window = .{};
    var snapshot: metrics.Snapshot = .{ .attached = true, .active = 100 };
    window.sample(&snapshot);
    snapshot.active = 200;
    window.sample(&snapshot);
    try std.testing.expect(window.pinned);
    snapshot.epoch = 1;
    snapshot.active = 300;
    window.sample(&snapshot);
    try std.testing.expect(!window.pinned);
    try std.testing.expectEqual(@as(u8, 0), window.percent);
}

test "ELF stack limits require both symbols for each stack independently" {
    const ra8 = @import("ra8");
    const Builder = @import("symbol_image.zig").Builder;
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = undefined };
    cpu.regs.msp = 1500;
    cpu.regs.psp = 1500;
    for (0..4) |case| {
        var buffer: [1024]u8 = undefined;
        const names: []const []const u8 = switch (case) {
            0 => &.{"__StackTop"},
            1 => &.{"__StackLimit"},
            2 => &.{ "__StackLimit", "__StackTop" },
            else => &.{ "__ProcessStackLimit", "__ProcessStackTop" },
        };
        const values: []const u32 = switch (case) {
            0 => &.{2000},
            1 => &.{1000},
            else => &.{ 1000, 2000 },
        };
        const image = try ra8.session.symbols.Image.init(Builder.build(&buffer, names, values));
        const snapshot = metrics.collect(&cpu, null, image, null, 0);
        try std.testing.expectEqual(case == 2, snapshot.msp.known());
        try std.testing.expectEqual(case == 3, snapshot.psp.known());
    }
}
