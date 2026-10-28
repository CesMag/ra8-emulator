//! Covers src/interfaces/rpc/regression_replay.zig: a rebuild that is the
//! recorded image replays compatible at every checkpoint, a rebuild with
//! one patched literal diverges at a named place, and the recorded
//! history is the same bytes after either.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");

const replay = ra8.rpc.regression_replay;

test "the recorded image replays compatible and leaves the history untouched" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const before = try rig.hashTree(gpa, recorded.base.dir);

    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.image, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.compatible, result.verdict);
    try std.testing.expectEqual(@as(u32, 3), result.checkpoints);
    try std.testing.expectEqual(@as(u32, 3), result.matched);
    try std.testing.expectEqual(@as(u64, 2), result.round);
    try std.testing.expect(result.divergence == null);
    try std.testing.expect(result.elf.identical());
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "one patched literal diverges at the memory it moved and leaves the history untouched" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try rig.patched(gpa, scratch.dir, "variant.elf");
    defer gpa.free(path);
    const before = try rig.hashTree(gpa, recorded.base.dir);

    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), path, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, result.verdict);
    try std.testing.expectEqual(@as(u32, 3), result.checkpoints);
    try std.testing.expectEqual(@as(u32, 1), result.matched);
    try std.testing.expect(!result.elf.identical());
    try std.testing.expectEqual(@as(u32, 1), result.elf.segments_changed);
    try std.testing.expectEqual(@as(?u32, 0x2000041), result.elf.first_changed_address);

    const d = result.divergence.?;
    try std.testing.expectEqual(@as(u64, 1), d.position.r);
    try std.testing.expectEqual(@as(u8, 0), d.core);
    try std.testing.expectEqual(@as(u32, 0x200003c), d.pc_expected);
    try std.testing.expectEqual(@as(u32, 0x200003c), d.pc_actual);
    try std.testing.expect(d.stopped == null);
    try std.testing.expect(d.symbol == null);
    const spot = d.place.?.memory;
    try std.testing.expectEqual(@as(u32, 0x22000100), spot.address);
    try std.testing.expectEqual(@as(u8, 4), spot.expected);
    try std.testing.expectEqual(@as(u8, 0), spot.actual);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}
