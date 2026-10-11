//! Tests for src/session/rtos_isr.zig: the NVIC model's counters read as
//! exception entry and return events.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_hook = ra8.session.step_hook.rtos_hook;
const isr = rtos_hook.isr;
const rtos_trace = ra8.session.step_hook.rtos_trace;

fn enter(controller: *isr.Nvic, number: u16) void {
    controller.active[controller.depth] = .{ .number = number, .priority = 0xFF };
    controller.depth += 1;
    controller.taken += 1;
}

fn leave(controller: *isr.Nvic) void {
    controller.depth -= 1;
    controller.returned += 1;
}

test "nothing entered before the watch started is traced" {
    var controller = isr.Nvic{};
    enter(&controller, 15);
    leave(&controller);
    var watcher = isr.Watcher.start(&controller);
    var trace = rtos_trace.Trace{};
    watcher.observe(&trace, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), trace.list().len);
}

test "an entry and its return are two events with the exception number" {
    var controller = isr.Nvic{};
    var watcher = isr.Watcher.start(&controller);
    var trace = rtos_trace.Trace{};
    enter(&controller, 15);
    watcher.observe(&trace, 0, 4);
    watcher.observe(&trace, 0, 4);
    leave(&controller);
    watcher.observe(&trace, 0, 5);
    const got = trace.list();
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(rtos_trace.Kind.enter, got[0].kind);
    try std.testing.expectEqual(@as(u16, 15), got[0].exception);
    try std.testing.expectEqual(@as(u64, 4), got[0].when);
    try std.testing.expectEqual(rtos_trace.Kind.leave, got[1].kind);
    try std.testing.expectEqual(@as(u16, 15), got[1].exception);
}

test "a tail chain reads as the return, then the next entry" {
    var controller = isr.Nvic{};
    var watcher = isr.Watcher.start(&controller);
    var trace = rtos_trace.Trace{};
    enter(&controller, 15);
    watcher.observe(&trace, 0, 1);
    leave(&controller);
    enter(&controller, 14);
    watcher.observe(&trace, 0, 2);
    const got = trace.list();
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(rtos_trace.Kind.leave, got[1].kind);
    try std.testing.expectEqual(@as(u16, 15), got[1].exception);
    try std.testing.expectEqual(rtos_trace.Kind.enter, got[2].kind);
    try std.testing.expectEqual(@as(u16, 14), got[2].exception);
}

test "a nested entry returns innermost first" {
    var controller = isr.Nvic{};
    var watcher = isr.Watcher.start(&controller);
    var trace = rtos_trace.Trace{};
    enter(&controller, 14);
    watcher.observe(&trace, 0, 1);
    enter(&controller, 16 + 3);
    watcher.observe(&trace, 0, 2);
    leave(&controller);
    watcher.observe(&trace, 0, 3);
    leave(&controller);
    watcher.observe(&trace, 0, 4);
    const got = trace.list();
    try std.testing.expectEqual(@as(u16, 19), got[2].exception);
    try std.testing.expectEqual(@as(u16, 14), got[3].exception);
}

test "names: system exceptions by name, IRQs by number" {
    try std.testing.expectEqualStrings("PendSV", isr.label(14).?);
    try std.testing.expectEqualStrings("SysTick", isr.label(15).?);
    try std.testing.expect(isr.label(19) == null);
}
