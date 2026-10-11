//! Covers src/session/harness/stacks.zig (RA8EMU-833, part 1): a served
//! session samples CPU0's call stacks only once asked, stamps them with the
//! board's virtual time, and gives the retire path back when told.
//! The fixture is the real DFU bootloader (tests/fixtures/dfu/README.md).
const std = @import("std");
const ra8 = @import("ra8");

const harness = ra8.session.harness;
const image_path = "tests/fixtures/dfu/dfu_bootloader.elf";

fn runFor(opened: *harness.Harness, instructions: u64) !void {
    const session = opened.session();
    session.live.budget = instructions;
    _ = try session.run(.cpu0, .cont);
}

test "a session nobody asked samples nothing and keeps its retire path" {
    var opened = try harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try std.testing.expect(opened.primaryCpu().retire_listener == null);
    try runFor(&opened, 50_000);
    try std.testing.expect(opened.primaryCpu().retire_listener == null);
}

test "sampled stacks are CPU0's, in virtual-time order, inside the run" {
    var opened = try harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    const stacks = try std.testing.allocator.create(harness.stacks.Stacks);
    defer std.testing.allocator.destroy(stacks);
    stacks.* = .{};
    opened.sampleStacks(stacks);
    try std.testing.expect(stacks.watching(0));
    const started = opened.board().time.base.now();
    try runFor(&opened, 200_000);
    const ended = opened.board().time.base.now();
    const store = &stacks.store;
    try std.testing.expect(store.count >= 100);
    var last: u64 = started;
    for (0..store.count) |index| {
        const sample = store.at(index);
        try std.testing.expectEqual(@as(u8, 0), sample.core);
        try std.testing.expectEqual(@as(u32, 0), sample.thread);
        try std.testing.expect(sample.len > 0);
        try std.testing.expect(sample.at_ns >= last and sample.at_ns <= ended);
        last = sample.at_ns;
    }
}

test "unsampling gives the retire path back and stops the samples" {
    var opened = try harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    const stacks = try std.testing.allocator.create(harness.stacks.Stacks);
    defer std.testing.allocator.destroy(stacks);
    stacks.* = .{};
    opened.sampleStacks(stacks);
    try runFor(&opened, 20_000);
    opened.unsampleStacks(stacks);
    try std.testing.expect(!stacks.watching(0));
    try std.testing.expect(opened.primaryCpu().retire_listener == null);
    const kept = stacks.store.count;
    try runFor(&opened, 20_000);
    try std.testing.expectEqual(kept, stacks.store.count);
}
