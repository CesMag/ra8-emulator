//! Tests for src/session/rtos/load.zig's scheduler-wait rule (RA8EMU-303):
//! ThreadX idles inside PendSV_Handler, so time after an `idle` inside a
//! PendSV is idle, not PendSV, until a thread is switched in or it returns.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_load = ra8.session.step_hook.rtos.hook.load;

const blink_a: u32 = 0x2200_10F0;
const systick: u16 = 15;
const pendsv: u16 = rtos_load.pend_sv;
const idle: rtos_load.Owner = .{ .kind = .idle };

fn ticksOf(load: *const rtos_load.Load, core: u1, owner: rtos_load.Owner) u64 {
    for (load.rows(core)) |slot| {
        if (slot.owner.kind == owner.kind and slot.owner.id == owner.id) return slot.ticks;
    }
    return 0;
}

fn exception(number: u16) rtos_load.Owner {
    return .{ .kind = .exception, .id = number };
}

test "the wait inside PendSV after an idle store is charged to idle" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .switch_to, .thread = blink_a });
    load.feed(.{ .when = 100, .core = 0, .kind = .enter, .exception = pendsv });
    load.feed(.{ .when = 105, .core = 0, .kind = .idle });
    load.finish(1000);
    try std.testing.expectEqual(@as(u64, 5), ticksOf(&load, 0, exception(pendsv)));
    try std.testing.expectEqual(@as(u64, 895), ticksOf(&load, 0, idle));
}

test "a SysTick nested in the wait charges itself, then the wait resumes as idle" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .enter, .exception = pendsv });
    load.feed(.{ .when = 5, .core = 0, .kind = .idle });
    load.feed(.{ .when = 500, .core = 0, .kind = .enter, .exception = systick });
    load.feed(.{ .when = 540, .core = 0, .kind = .leave, .exception = systick });
    load.finish(1000);
    try std.testing.expectEqual(@as(u64, 40), ticksOf(&load, 0, exception(systick)));
    try std.testing.expectEqual(@as(u64, 955), ticksOf(&load, 0, idle));
    try std.testing.expectEqual(@as(u64, 5), ticksOf(&load, 0, exception(pendsv)));
}

test "a switch inside the PendSV ends the wait and its tail is PendSV again" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .enter, .exception = pendsv });
    load.feed(.{ .when = 5, .core = 0, .kind = .idle });
    load.feed(.{ .when = 18, .core = 0, .kind = .switch_to, .thread = blink_a });
    load.feed(.{ .when = 35, .core = 0, .kind = .leave, .exception = pendsv });
    load.finish(100);
    try std.testing.expectEqual(@as(u64, 22), ticksOf(&load, 0, exception(pendsv)));
    try std.testing.expectEqual(@as(u64, 13), ticksOf(&load, 0, idle));
    try std.testing.expectEqual(@as(u64, 65), ticksOf(&load, 0, .{ .kind = .thread, .id = blink_a }));
}

test "an idle store under a SysTick does not turn the SysTick into idle" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .enter, .exception = systick });
    load.feed(.{ .when = 10, .core = 0, .kind = .idle });
    load.feed(.{ .when = 40, .core = 0, .kind = .leave, .exception = systick });
    load.finish(100);
    try std.testing.expectEqual(@as(u64, 40), ticksOf(&load, 0, exception(systick)));
    try std.testing.expectEqual(@as(u64, 60), ticksOf(&load, 0, idle));
}

test "a PendSV entered again after the wait returned is charged as PendSV" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .enter, .exception = pendsv });
    load.feed(.{ .when = 5, .core = 0, .kind = .idle });
    load.feed(.{ .when = 50, .core = 0, .kind = .leave, .exception = pendsv });
    load.feed(.{ .when = 60, .core = 0, .kind = .enter, .exception = pendsv });
    load.feed(.{ .when = 70, .core = 0, .kind = .leave, .exception = pendsv });
    load.finish(100);
    try std.testing.expectEqual(@as(u64, 15), ticksOf(&load, 0, exception(pendsv)));
    try std.testing.expectEqual(@as(u64, 85), ticksOf(&load, 0, idle));
}

test "the wait is kept per core" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 1, .kind = .enter, .exception = pendsv });
    load.feed(.{ .when = 5, .core = 1, .kind = .idle });
    load.feed(.{ .when = 0, .core = 0, .kind = .enter, .exception = pendsv });
    load.finish(100);
    try std.testing.expectEqual(@as(u64, 95), ticksOf(&load, 1, idle));
    try std.testing.expectEqual(@as(u64, 100), ticksOf(&load, 0, exception(pendsv)));
}
