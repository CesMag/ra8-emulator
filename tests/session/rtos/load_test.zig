//! Tests for src/session/rtos/load.zig: who each stretch of virtual time is
//! charged to, how the window cuts it, and that cores are kept apart.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_load = ra8.session.step_hook.rtos.hook.load;
const Event = ra8.session.step_hook.rtos.hook.rtos.trace.Event;

const blink_a: u32 = 0x2200_10F0;
const blink_b: u32 = 0x2200_11A0;
const systick: u16 = 15;
const pendsv: u16 = 14;

fn ticksOf(load: *const rtos_load.Load, core: u1, owner: rtos_load.Owner) u64 {
    for (load.rows(core)) |slot| {
        if (slot.owner.kind == owner.kind and slot.owner.id == owner.id) return slot.ticks;
    }
    return 0;
}

fn thread(id: u32) rtos_load.Owner {
    return .{ .kind = .thread, .id = id };
}

fn exception(number: u16) rtos_load.Owner {
    return .{ .kind = .exception, .id = number };
}

test "threads are charged from their switch to the next one" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 10, .core = 0, .kind = .switch_to, .thread = blink_a });
    load.feed(.{ .when = 40, .core = 0, .kind = .switch_to, .thread = blink_b });
    load.finish(100);
    try std.testing.expectEqual(@as(u64, 10), ticksOf(&load, 0, .{ .kind = .before }));
    try std.testing.expectEqual(@as(u64, 30), ticksOf(&load, 0, thread(blink_a)));
    try std.testing.expectEqual(@as(u64, 60), ticksOf(&load, 0, thread(blink_b)));
    try std.testing.expectEqual(@as(u64, 100), load.total(0));
}

test "idle is its own owner" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .switch_to, .thread = blink_a });
    load.feed(.{ .when = 25, .core = 0, .kind = .idle });
    load.finish(100);
    try std.testing.expectEqual(@as(u64, 25), ticksOf(&load, 0, thread(blink_a)));
    try std.testing.expectEqual(@as(u64, 75), ticksOf(&load, 0, .{ .kind = .idle }));
}

test "nested exceptions charge the innermost, then hand back" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .switch_to, .thread = blink_a });
    load.feed(.{ .when = 10, .core = 0, .kind = .enter, .exception = systick });
    load.feed(.{ .when = 14, .core = 0, .kind = .enter, .exception = pendsv });
    load.feed(.{ .when = 20, .core = 0, .kind = .switch_to, .thread = blink_b });
    load.feed(.{ .when = 21, .core = 0, .kind = .leave, .exception = pendsv });
    load.feed(.{ .when = 23, .core = 0, .kind = .leave, .exception = systick });
    load.finish(50);
    try std.testing.expectEqual(@as(u64, 10), ticksOf(&load, 0, thread(blink_a)));
    try std.testing.expectEqual(@as(u64, 4 + 2), ticksOf(&load, 0, exception(systick)));
    try std.testing.expectEqual(@as(u64, 7), ticksOf(&load, 0, exception(pendsv)));
    try std.testing.expectEqual(@as(u64, 27), ticksOf(&load, 0, thread(blink_b)));
    try std.testing.expectEqual(@as(u64, 50), load.total(0));
}

test "the window cuts the intervals that cross it" {
    var load = rtos_load.Load{ .from = 20, .to = 60 };
    load.feed(.{ .when = 0, .core = 0, .kind = .switch_to, .thread = blink_a });
    load.feed(.{ .when = 30, .core = 0, .kind = .switch_to, .thread = blink_b });
    load.feed(.{ .when = 50, .core = 0, .kind = .idle });
    load.finish(100);
    try std.testing.expectEqual(@as(u64, 10), ticksOf(&load, 0, thread(blink_a)));
    try std.testing.expectEqual(@as(u64, 20), ticksOf(&load, 0, thread(blink_b)));
    try std.testing.expectEqual(@as(u64, 10), ticksOf(&load, 0, .{ .kind = .idle }));
    try std.testing.expectEqual(@as(u64, 40), load.total(0));
}

test "two cores keep their own owners and clocks" {
    var load = rtos_load.Load{};
    load.feed(.{ .when = 0, .core = 0, .kind = .switch_to, .thread = blink_a });
    load.feed(.{ .when = 5, .core = 1, .kind = .switch_to, .thread = blink_b });
    load.feed(.{ .when = 8, .core = 1, .kind = .enter, .exception = systick });
    load.feed(.{ .when = 9, .core = 1, .kind = .leave, .exception = systick });
    load.finish(20);
    try std.testing.expectEqual(@as(u64, 20), ticksOf(&load, 0, thread(blink_a)));
    try std.testing.expectEqual(@as(u64, 0), ticksOf(&load, 0, exception(systick)));
    try std.testing.expectEqual(@as(u64, 5), ticksOf(&load, 1, .{ .kind = .before }));
    try std.testing.expectEqual(@as(u64, 3 + 11), ticksOf(&load, 1, thread(blink_b)));
    try std.testing.expectEqual(@as(u64, 1), ticksOf(&load, 1, exception(systick)));
    try std.testing.expectEqual(@as(u64, 20), load.total(1));
}

test "owners past the slot limit go to other, and a stray leave is harmless" {
    var load = rtos_load.Load{};
    var when: u64 = 0;
    for (0..rtos_load.limits.slots + 2) |index| {
        load.feed(.{ .when = when, .core = 0, .kind = .switch_to, .thread = 0x2200_0000 + @as(u32, @intCast(index)) * 0x100 });
        when += 10;
    }
    load.feed(.{ .when = when, .core = 0, .kind = .leave, .exception = systick });
    load.finish(when + 10);
    try std.testing.expectEqual(rtos_load.limits.slots, load.rows(0).len);
    try std.testing.expect(load.cores[0].other > 0);
    try std.testing.expectEqual(when + 10, load.total(0));
}
