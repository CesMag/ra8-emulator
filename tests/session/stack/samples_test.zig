//! Tests for src/session/stack_samples.zig.
const std = @import("std");
const ra8 = @import("ra8");
const stack_samples = ra8.session.step_hook.stack.samples;
const Store = stack_samples.Store;

const main_fn: u32 = 0x100;
const work_fn: u32 = 0x200;
const leaf_fn: u32 = 0x300;
const idle_fn: u32 = 0x400;

fn nameOf(_: *const anyopaque, address: u32) ?[]const u8 {
    return switch (address) {
        main_fn => "main",
        work_fn => "work",
        leaf_fn => "leaf",
        idle_fn => "idle",
        else => null,
    };
}

const names: stack_samples.Names = .{ .context = undefined, .nameFn = nameOf };

/// Two cores, two threads on core 0, and samples on both sides of a window.
fn filled(store: *Store) void {
    store.push(0, 1, 10, &.{ leaf_fn, work_fn, main_fn });
    store.push(0, 1, 20, &.{ work_fn, main_fn });
    store.push(0, 2, 30, &.{ idle_fn, main_fn });
    store.push(0, 1, 40, &.{ leaf_fn, work_fn, main_fn });
    store.push(1, 0, 40, &.{ leaf_fn, main_fn });
    store.push(0, 2, 50, &.{ 0x1234, idle_fn, main_fn });
    store.push(0, 1, 90, &.{ leaf_fn, work_fn, main_fn });
}

fn folded(store: *const Store, filter: stack_samples.Filter, into: []u8) ![]const u8 {
    var scratch: [stack_samples.limits.samples]usize = undefined;
    var writer: std.Io.Writer = .fixed(into);
    try stack_samples.fold(store, filter, names, &writer, &scratch);
    return writer.buffered();
}

test "a fold merges identical stacks over a window, outermost frame first" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    filled(store);
    var text: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "main;work 1\nmain;work;leaf 2\nmain;idle 1\nmain;idle;0x00001234 1\n",
        try folded(store, .{ .core = 0, .from_ns = 10, .to_ns = 90 }, &text),
    );
}

test "a fold takes one core, and one thread when asked" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    filled(store);
    var text: [512]u8 = undefined;
    try std.testing.expectEqualStrings("main;leaf 1\n", try folded(store, .{ .core = 1 }, &text));
    try std.testing.expectEqualStrings(
        "main;idle 1\nmain;idle;0x00001234 1\n",
        try folded(store, .{ .core = 0, .thread = 2 }, &text),
    );
    try std.testing.expectEqualStrings(
        "main;work 1\nmain;work;leaf 3\n",
        try folded(store, .{ .core = 0, .thread = 1 }, &text),
    );
}

test "the same samples in another order fold to the same bytes" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    store.push(0, 0, 1, &.{ idle_fn, main_fn });
    store.push(0, 0, 2, &.{ work_fn, main_fn });
    store.push(0, 0, 3, &.{main_fn});
    var text: [256]u8 = undefined;
    try std.testing.expectEqualStrings("main 1\nmain;work 1\nmain;idle 1\n", try folded(store, .{ .core = 0 }, &text));
}

test "a full store drops the oldest sample and counts it" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    for (0..stack_samples.limits.samples + 3) |i| store.push(0, 0, i, &.{main_fn});
    try std.testing.expectEqual(stack_samples.limits.samples, store.count);
    try std.testing.expectEqual(@as(u64, 3), store.dropped);
    try std.testing.expectEqual(@as(u64, 3), store.at(0).at_ns);
    var text: [64]u8 = undefined;
    try std.testing.expectEqualStrings("main 5\n", try folded(store, .{ .core = 0, .from_ns = 0, .to_ns = 8 }, &text));
}

test "frames past the depth limit lose the outermost ones" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    var deep: [stack_samples.limits.depth + 2]u32 = undefined;
    for (&deep, 0..) |*address, i| address.* = @intCast(i);
    store.push(0, 0, 0, &deep);
    try std.testing.expectEqual(stack_samples.limits.depth, store.at(0).stack().len);
    try std.testing.expectEqual(@as(u32, 0), store.at(0).stack()[0]);
}
