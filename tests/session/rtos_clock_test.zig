//! RA8EMU-292: the tracer's load clock is virtual time per
//! instruction. The run loop's idle skip (src/chip/core/idle.zig) charges a
//! stretch to the clocks without executing it, so the per-instruction hook
//! never sees it; the clock restarts from the run's elapsed count whenever
//! a chunk moves it, and the skipped time lands on whoever owned the core.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_hook = ra8.session.step_hook.rtos.hook;

const pointer: u32 = 0x2200_1ABC;
const thread_a: u32 = 0x2200_10F0;
const thread_b: u32 = 0x2200_11A0;

fn steps(tracer: *rtos_hook.Tracer, count: u32) void {
    for (0..count) |_| tracer.onInstruction();
}

fn ticksOf(load: *const rtos_hook.load.Load, thread: u32) u64 {
    for (load.rows(0)) |slot| {
        if (slot.owner.kind == .thread and slot.owner.id == thread) return slot.ticks;
    }
    return 0;
}

test "a chunk cut short by the idle skip charges its full width to the owner" {
    var elapsed: u64 = 0;
    var tracer = rtos_hook.Tracer{ .address = pointer, .elapsed = &elapsed };
    tracer.trace.fine = &tracer.clock;
    steps(&tracer, 10);
    tracer.onStore(pointer, 4, thread_a);
    steps(&tracer, 10);
    // The chunk was 100 wide: 20 executed, 80 skipped and charged.
    elapsed = 100;
    steps(&tracer, 5);
    tracer.onStore(pointer, 4, thread_b);
    steps(&tracer, 5);
    elapsed = 150;
    var load = tracer.trace.load;
    load.finish(tracer.loadClock());
    try std.testing.expectEqual(@as(u64, 150), load.total(0));
    try std.testing.expectEqual(@as(u64, 105 - 10), ticksOf(&load, thread_a));
    try std.testing.expectEqual(@as(u64, 150 - 105), ticksOf(&load, thread_b));
}

test "a chunk that ran to its edge carries on without a gap or a repeat" {
    var elapsed: u64 = 0;
    var tracer = rtos_hook.Tracer{ .address = pointer, .elapsed = &elapsed };
    steps(&tracer, 50);
    try std.testing.expectEqual(@as(u64, 50), tracer.clock);
    elapsed = 50;
    steps(&tracer, 1);
    try std.testing.expectEqual(@as(u64, 51), tracer.clock);
}

test "the clock never runs backwards when a chunk hooks more than it charged" {
    var elapsed: u64 = 0;
    var tracer = rtos_hook.Tracer{ .address = pointer, .elapsed = &elapsed };
    steps(&tracer, 60);
    elapsed = 50;
    steps(&tracer, 1);
    try std.testing.expectEqual(@as(u64, 60), tracer.clock);
    steps(&tracer, 20);
    try std.testing.expectEqual(@as(u64, 71), tracer.clock);
}

test "with no elapsed count the clock is the hooked steps, as before" {
    var tracer = rtos_hook.Tracer{ .address = pointer };
    steps(&tracer, 7);
    try std.testing.expectEqual(@as(u64, 7), tracer.clock);
    try std.testing.expectEqual(@as(u64, 0), tracer.loadClock());
}
