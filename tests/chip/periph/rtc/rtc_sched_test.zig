//! Covers src/chip/periph/rtc/rtc_sched.zig: the second edge a virtual-time RTC
//! queues so its alarm is evaluated at the virtual time it matched.
const std = @import("std");
const ra8 = @import("ra8");

const rtc = ra8.chip.periph.rtc;
const sched = rtc.sched;
const EventQueue = ra8.chip.periph.clocks.event_queue.EventQueue;

fn write8(unit: *rtc.Rtc, offset: u32, value: u8) void {
    unit.write(rtc.win_base + offset, 1, value);
}

fn started(mode: rtc.pace.Mode, rcr1: u8) rtc.Rtc {
    var unit = rtc.Rtc.init();
    unit.pace.mode = mode;
    write8(&unit, rtc.off.rcr1, rcr1);
    write8(&unit, rtc.off.rcr2, 0x01);
    return unit;
}

test "a virtual clock with its periodic event on queues the next second edge" {
    var unit = started(.virtual, rtc.control.pie);
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), sched.dueAt(&unit, 0));
    unit.tickFor(250_000_000);
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), sched.dueAt(&unit, 250_000_000));
}

test "the edge after a whole second is a full second out" {
    var unit = started(.virtual, rtc.control.pie);
    unit.tickFor(1_000_000_000);
    try std.testing.expectEqual(@as(?u64, 2_000_000_000), sched.dueAt(&unit, 1_000_000_000));
}

test "an armed alarm queues the edge with no periodic event" {
    var unit = started(.virtual, rtc.control.aie);
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(&unit, 0));
    write8(&unit, rtc.off.secar, 0x85);
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), sched.dueAt(&unit, 0));
}

test "a geared, stopped or idle clock queues nothing" {
    var geared = started(.boundary, rtc.control.pie);
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(&geared, 0));
    var stopped = rtc.Rtc.init();
    stopped.pace.mode = .virtual;
    write8(&stopped, rtc.off.rcr1, rtc.control.pie);
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(&stopped, 0));
    var idle = started(.virtual, 0);
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(&idle, 0));
}

test "arm keeps one edge on the queue and drops it when nothing is due" {
    var queue = EventQueue{};
    var unit = started(.virtual, rtc.control.pie);
    try sched.arm(&unit, &queue, 0);
    try sched.arm(&unit, &queue, 0);
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), queue.next());
    try std.testing.expectEqual(@as(usize, 1), queue.cancel(sched.queue_id));
    try sched.arm(&unit, &queue, 0);
    write8(&unit, rtc.off.rcr2, 0);
    try sched.arm(&unit, &queue, 0);
    try std.testing.expectEqual(@as(?u64, null), queue.next());
}

test "a second-edge boundary raises the alarm at the virtual second it matched" {
    var unit = started(.virtual, rtc.control.aie);
    write8(&unit, rtc.off.secar, 0x82);
    unit.tickFor(1_000_000_000);
    try std.testing.expectEqual(@as(u32, 0), unit.alarms);
    unit.tickFor(999_999_999);
    try std.testing.expectEqual(@as(u32, 0), unit.alarms);
    unit.tickFor(1);
    try std.testing.expectEqual(@as(u32, 1), unit.alarms);
}
