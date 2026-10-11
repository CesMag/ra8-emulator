//! Tests for src/session/rtos_report.zig: which flag prints what, how shares
//! are split, and the load table a known run prints.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_hook = ra8.session.step_hook.rtos.hook;
const report = rtos_hook.report;

const blink_a: u32 = 0x2200_10F0;
const blink_b: u32 = 0x2200_11A0;

/// Control blocks naming blink_a and blink_b, as threadx_blink lays them out.
const Blink = struct {
    pub fn read(_: Blink, address: u32, into: []u8) bool {
        const word: ?u32 = switch (address) {
            blink_a + 40 => 0x0200_1000,
            blink_b + 40 => 0x0200_1008,
            else => null,
        };
        if (word) |value| {
            if (into.len != 4) return false;
            std.mem.writeInt(u32, into[0..4], value, .little);
            return true;
        }
        const text = "blink_a\x00blink_b\x00";
        if (address < 0x0200_1000 or address + into.len > 0x0200_1000 + text.len) return false;
        @memcpy(into, text[address - 0x0200_1000 ..][0..into.len]);
        return true;
    }
};

const Flags = struct { trace_rtos: bool = false, cpu_load: bool = false };

fn run(clock: *u64) rtos_hook.Tracer {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC, .now = clock };
    clock.* = 10;
    tracer.onStore(0x2200_1ABC, 4, blink_a);
    clock.* = 40;
    tracer.trace.exception(0, clock.*, .enter, 15);
    clock.* = 50;
    tracer.trace.exception(0, clock.*, .leave, 15);
    clock.* = 100;
    tracer.onStore(0x2200_1ABC, 4, blink_b);
    clock.* = 200;
    return tracer;
}

test "shares add up to exactly 100.0% by largest remainder" {
    var into: [3]u64 = undefined;
    report.split(&.{ 1, 1, 1 }, 3, &into);
    try std.testing.expectEqualSlices(u64, &.{ 334, 333, 333 }, &into);
    report.split(&.{ 2, 1, 0 }, 3, &into);
    try std.testing.expectEqualSlices(u64, &.{ 667, 333, 0 }, &into);
}

test "the load table charges a known run to its owners" {
    var clock: u64 = 0;
    const tracer = run(&clock);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.all(&out.writer, std.testing.io, Flags{ .cpu_load = true }, &tracer, Blink{});
    const want =
        \\  cpu load cpu0 : 200 instruction(s)
        \\                    5.0%         10  before the first switch
        \\                   40.0%         80  0x220010F0 blink_a
        \\                    5.0%         10  SysTick
        \\                   50.0%        100  0x220011A0 blink_b
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}

test "neither flag prints nothing, and --trace-rtos alone prints no load" {
    var clock: u64 = 0;
    const tracer = run(&clock);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.all(&out.writer, std.testing.io, Flags{}, &tracer, Blink{});
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try report.all(&out.writer, std.testing.io, Flags{ .trace_rtos = true }, &tracer, Blink{});
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "cpu load") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "rtos trace") != null);
}

test "an attached tracer charges load in the instructions its hook saw" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    tracer.trace.fine = &tracer.steps;
    for (0..30) |_| tracer.onInstruction();
    tracer.onStore(0x2200_1ABC, 4, blink_a);
    for (0..70) |_| tracer.onInstruction();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.load(&out.writer, &tracer, Blink{});
    const want =
        \\  cpu load cpu0 : 100 instruction(s)
        \\                   30.0%         30  before the first switch
        \\                   70.0%         70  0x220010F0 blink_a
        \\
    ;
    try std.testing.expectEqualStrings(want, out.written());
}
