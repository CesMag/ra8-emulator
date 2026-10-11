//! The flame graph's per-thread trees (RA8EMU-1149, split from
//! RA8EMU-839): on a guest that switches ThreadX's current-thread pointer
//! between two control blocks, serve tags each sample with its thread, each
//! thread's flame tree holds only that thread's functions, and the threads'
//! sample totals add up to the unfiltered tree's.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");

const setup = ra8.rpc.served_setup;
const folded = ra8.rpc.session_folded;
const proto = ra8.rpc.session_rpc;
const flame_model = gui_app.flame_model;

fn ran(opened: *setup.Served) !void {
    try opened.open(std.testing.allocator, std.testing.io, test_paths.two_threads);
    errdefer opened.deinit();
    opened.owner.session().live.budget = 200_000;
    try opened.sampleStacks(200);
    _ = try opened.owner.session().run(.cpu0, .cont);
}

/// Every thread CPU0's samples carry, 0 (before the first switch) included.
fn threadsSeen(store: anytype, into: *[4]u32) []const u32 {
    var count: usize = 0;
    for (0..store.count) |at| {
        const thread = store.at(at).thread;
        if (std.mem.indexOfScalar(u32, into[0..count], thread) != null) continue;
        if (count == into.len) break;
        into[count] = thread;
        count += 1;
    }
    return into[0..count];
}

/// A thread's flame tree: its sample total, and whether its rows name
/// thread A's or thread B's functions.
const Tree = struct { total: u64, has_a: bool, has_b: bool };

fn treeOf(context: anytype, thread: u32) !Tree {
    const rows = switch (folded.folded(context, .{ .core = .cpu0, .thread = thread })) {
        .ok => |answer| answer.text,
        .err => return error.Refused,
    };
    var model = flame_model.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.load(rows);
    return .{
        .total = model.window(),
        .has_a = std.mem.indexOf(u8, rows, "thread_a_") != null,
        .has_b = std.mem.indexOf(u8, rows, "thread_b_") != null,
    };
}

test "serve tags samples with both threads' control blocks" {
    var opened: setup.Served = undefined;
    try ran(&opened);
    defer opened.deinit();
    var seen: [4]u32 = undefined;
    var named: usize = 0;
    for (threadsSeen(&opened.stacks.?.store, &seen)) |thread| {
        if (thread != 0) named += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), named);
}

test "each thread's tree has only its functions and the threads sum to the whole" {
    var opened: setup.Served = undefined;
    try ran(&opened);
    defer opened.deinit();
    const whole = try treeOf(&opened.context, proto.all_threads);
    try std.testing.expect(whole.has_a and whole.has_b);
    var seen: [4]u32 = undefined;
    var sum: u64 = 0;
    var only_a: usize = 0;
    var only_b: usize = 0;
    for (threadsSeen(&opened.stacks.?.store, &seen)) |thread| {
        const tree = try treeOf(&opened.context, thread);
        sum += tree.total;
        if (thread == 0) continue;
        try std.testing.expect(tree.total > 0);
        try std.testing.expect(tree.has_a != tree.has_b);
        if (tree.has_a) only_a += 1 else only_b += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), only_a);
    try std.testing.expectEqual(@as(usize, 1), only_b);
    try std.testing.expectEqual(whole.total, sum);
}
