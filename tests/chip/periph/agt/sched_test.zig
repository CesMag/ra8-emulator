//! Covers src/chip/periph/agt/sched.zig: the PCLKB the per-boundary step
//! stands for, and the virtual time a channel's next underflow is due at.
const std = @import("std");
const ra8 = @import("ra8");

const agt = ra8.chip.periph.agt;
const sched = ra8.chip.periph.agt.clock.sched;
const cadence = ra8.chip.core.cadence;

/// One boundary of virtual time at the time base's default 1 GHz.
const boundary_ns: u64 = cadence.instructions;

fn started(counter: u16, mr1: u8) agt.Agt {
    var timer = agt.Agt.init();
    timer.channels[0].counter = counter;
    timer.channels[0].reload = 0xFFFF;
    timer.channels[0].mr1 = mr1;
    timer.channels[0].cr = agt.control.tstart;
    return timer;
}

/// The boundary the stepped model underflows channel 0 on.
fn steppedUnderflow(timer: *agt.Agt) u64 {
    var boundary: u64 = 1;
    while (boundary < 1000) : (boundary += 1) {
        timer.tick();
        if (timer.pending != 0) return boundary;
    }
    unreachable;
}

test "the step stands for 40.96 MHz of PCLKB" {
    try std.testing.expectEqual(@as(u64, 40_960_000), sched.pclkb_hz);
}

test "a queued underflow is due inside the boundary the step lands it on" {
    // Undivided, PCLKB/2 and PCLKB/8, from a count that spans boundaries.
    for ([_]u8{ 0x00, 0x30, 0x10 }) |mr1| {
        var timer = started(5000, mr1);
        const due = sched.dueAt(timer.channels[0], 0, 0).?;
        const landed = steppedUnderflow(&timer);
        try std.testing.expect(due > (landed - 1) * boundary_ns);
        try std.testing.expect(due <= landed * boundary_ns);
    }
}

test "a stopped or cascaded channel has nothing due" {
    var timer = started(100, 0x00);
    timer.channels[0].cr = 0;
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(timer.channels[0], 0, 0));
    timer = started(100, 0x50);
    timer.channels[1] = timer.channels[0];
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(timer.channels[1], 1, 0));
    // AGT0 cannot cascade, so the same byte counts undivided there.
    const undivided = ra8.chip.periph.agt.clock.underflowInNs(100, .pclkb, sched.pclkb_hz).?;
    try std.testing.expectEqual(@as(?u64, 2_000_000 + undivided), sched.dueAt(timer.channels[0], 0, 2_000_000));
}

test "a full boundary of virtual time counts exactly the old step" {
    for ([_]u8{ 0x00, 0x30, 0x10 }) |mr1| {
        var timed = started(60_000, mr1);
        var stepped = started(60_000, mr1);
        var at: u64 = 0;
        while (at < 20 * boundary_ns) : (at += boundary_ns) {
            sched.tickFor(&timed, at, at + boundary_ns);
            stepped.tick();
            try std.testing.expectEqual(stepped.channels[0].counter, timed.channels[0].counter);
        }
    }
}

test "a narrowed boundary counts its own stretch, and nothing is lost across them" {
    var timer = started(60_000, 0x00);
    // 25 boundaries of 2000 ns are one 50000 ns boundary: 2048 counts.
    var at: u64 = 0;
    while (at < boundary_ns) : (at += 2_000) sched.tickFor(&timer, at, at + 2_000);
    try std.testing.expectEqual(@as(u16, 60_000 - 2048), timer.channels[0].counter);
    try std.testing.expectEqual(@as(u16, 81), sched.countsBetween(0, 2_000, 1));
    try std.testing.expectEqual(@as(u16, 82), sched.countsBetween(2_000, 4_000, 1));
}

test "an AGT underflow fires at its virtual time" {
    var timer = started(999, 0x00);
    const due = sched.dueAt(timer.channels[0], 0, 0).?;
    // One ns-wide boundary at a time around the due time.
    var at: u64 = 0;
    while (at < due - 1) : (at += 1) sched.tickFor(&timer, at, at + 1);
    try std.testing.expectEqual(@as(u32, 0), timer.pending);
    sched.tickFor(&timer, due - 1, due);
    try std.testing.expectEqual(@as(u32, 1), timer.pending);
}

test "arm puts each running channel's underflow on the queue under its own id" {
    var queue = ra8.chip.periph.clocks.event_queue.EventQueue{};
    var timer = started(0x0100, 0);
    try sched.arm(&timer, &queue, 5_000);
    try std.testing.expectEqual(@as(usize, 1), queue.count);
    try std.testing.expectEqual(sched.dueAt(timer.channels[0], 0, 5_000), queue.next());
    try std.testing.expectEqual(sched.queueId(0), queue.items[0].id);
    // Re-arming replaces rather than stacks, and follows a rewritten counter.
    timer.channels[0].counter = 0x0010;
    try sched.arm(&timer, &queue, 6_000);
    try std.testing.expectEqual(@as(usize, 1), queue.count);
    try std.testing.expectEqual(sched.dueAt(timer.channels[0], 0, 6_000), queue.next());
    // A second running channel gets its own entry; a stopped one drops out.
    timer.channels[3] = timer.channels[0];
    try sched.arm(&timer, &queue, 6_000);
    try std.testing.expectEqual(@as(usize, 2), queue.count);
    timer.channels[0].cr = 0;
    timer.channels[3].cr = 0;
    try sched.arm(&timer, &queue, 7_000);
    try std.testing.expectEqual(@as(?u64, null), queue.next());
}
