//! Tests for src/board/run/soak_threads.zig.
const std = @import("std");
const ra8 = @import("ra8");
const soak = ra8.board.run.soak;
const soak_threads = soak.soak_threads;

const base: u32 = 0x2000_0000;
const head: u32 = base;
const count_at: u32 = base + 4;
const thread_a: u32 = base + 0x100;
const thread_b: u32 = base + 0x200;
const stack_a: u32 = base + 0x400;
const stack_b: u32 = base + 0x500;

/// 2 KiB of word memory at 0x2000_0000 holding a two-thread created list.
const Fake = struct {
    words: [512]u32 = @splat(0),

    fn at(self: *Fake, address: u32) *u32 {
        return &self.words[(address - base) / 4];
    }

    pub fn readWord(self: *const Fake, address: u32) !u32 {
        if (address < base or address >= base + 0x800) return error.Unmapped;
        return self.words[(address - base) / 4];
    }

    fn twoThreads() Fake {
        var memory: Fake = .{};
        memory.at(head).* = thread_a;
        memory.at(count_at).* = 2;
        memory.at(thread_a + soak_threads.stack_start_offset).* = stack_a;
        memory.at(thread_a + soak_threads.created_next_offset).* = thread_b;
        memory.at(thread_b + soak_threads.stack_start_offset).* = stack_b;
        memory.at(thread_b + soak_threads.created_next_offset).* = thread_a;
        memory.at(stack_a).* = soak_threads.fill;
        memory.at(stack_b).* = soak_threads.fill;
        return memory;
    }
};

fn armed() soak.Soak {
    var run: soak.Soak = .{ .armed = true };
    run.threads = .{ .head = head, .count_at = count_at };
    return run;
}

test "every created thread's filled stack start is watched" {
    var run = armed();
    var memory = Fake.twoThreads();
    run.check(&memory, 0);
    try std.testing.expectEqual(@as(usize, 2), run.watch.list().len);
    try std.testing.expectEqual(stack_a, run.watch.list()[0].address);
    try std.testing.expectEqual(stack_b, run.watch.list()[1].address);
    try std.testing.expect(run.event == null);
}

test "an overrun canary ends the soak naming its word" {
    var run = armed();
    var memory = Fake.twoThreads();
    run.check(&memory, 0);
    memory.at(stack_b).* = 0x1234_5678;
    run.check(&memory, 60_000_000_000);
    const event = run.event orelse return error.NoEvent;
    try std.testing.expectEqual(soak.Kind.stack_canary, event.kind);
    try std.testing.expectEqual(@as(?u32, stack_b), event.word);
    try std.testing.expectEqual(@as(u64, 60_000_000_000), event.at_ns);
}

test "a stack without the fill is not watched" {
    var run = armed();
    var memory = Fake.twoThreads();
    memory.at(stack_a).* = 0;
    run.check(&memory, 0);
    try std.testing.expectEqual(@as(usize, 1), run.watch.list().len);
    try std.testing.expectEqual(stack_b, run.watch.list()[0].address);
}

test "a deleted thread's stack is dropped when the count moves" {
    var run = armed();
    var memory = Fake.twoThreads();
    run.check(&memory, 0);
    memory.at(count_at).* = 1;
    memory.at(thread_a + soak_threads.created_next_offset).* = thread_a;
    run.check(&memory, 1);
    memory.at(stack_b).* = 0;
    run.check(&memory, 2);
    try std.testing.expect(run.event == null);
    try std.testing.expectEqual(@as(usize, 1), run.watch.list().len);
}

test "an unchanged count does not re-read the list" {
    var run = armed();
    var memory = Fake.twoThreads();
    run.check(&memory, 0);
    memory.at(head).* = 0;
    run.check(&memory, 1);
    try std.testing.expectEqual(@as(usize, 2), run.watch.list().len);
}

test "an empty list or no ThreadX watches nothing" {
    var none: soak.Soak = .{ .armed = true };
    var memory = Fake.twoThreads();
    none.check(&memory, 0);
    try std.testing.expectEqual(@as(usize, 0), none.watch.list().len);
    var run = armed();
    memory.at(head).* = 0;
    run.check(&memory, 0);
    try std.testing.expectEqual(@as(usize, 0), run.watch.list().len);
}
