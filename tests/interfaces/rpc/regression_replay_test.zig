//! Covers src/interfaces/rpc/regression_replay.zig: a rebuild that is the
//! recorded image replays compatible at every checkpoint, a rebuild with
//! one patched literal diverges at a named place, and the recorded
//! history is the same bytes after either.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");

const replay = ra8.rpc.regression_replay;

test "a non-default recorded board profile is applied to the replay" {
    const gpa = std.testing.allocator;
    const profile = "version=1\nmemory_window_cycles=17\n";
    const recorded = try rig.Recorded.openProfile(gpa, 3, profile);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try ra8.session.history_root.decode(bytes);
    try std.testing.expectEqualStrings(profile, root.board_profile);
    try std.testing.expectEqual(ra8.snapshot.file.version, root.snapshot_version);
    try std.testing.expect(!std.mem.allEqual(u8, &root.emulator_commit, 0));
    try std.testing.expectEqual(@as(usize, 64), root.model_version.len);
    try std.testing.expectEqualStrings("ra8p1", root.part);
    try std.testing.expectEqual(ra8.session.history_root.Pace.virtual, root.pace);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.image, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.compatible, result.verdict);
    try std.testing.expectEqual(@as(u32, 3), result.checkpoints);
    try std.testing.expectEqual(@as(u32, 3), result.matched);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "an empty root line refuses a vacuous compatible verdict without changing history" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    var dir = try recorded.base.dir.openDir(std.testing.io, recorded.sessionName(), .{});
    defer dir.close(std.testing.io);
    try dir.writeFile(std.testing.io, .{ .sub_path = "log/events-0", .data = "" });
    const before = try rig.hashTree(gpa, recorded.base.dir);
    try std.testing.expectError(error.NoRootCheckpoints, replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.image, .{}));
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "checkpoints only on another branch cannot make the root comparison compatible" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    try recorded.checkpointLog(.{ .branch = 1 }, null);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    try std.testing.expectError(error.NoRootCheckpoints, replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), "missing-rebuilt.elf", .{}));
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

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

test "two executed cores replay twice from frozen bytes with the original tree unchanged" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.openDual(gpa, 4);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try ra8.session.history_root.decode(bytes);
    try std.testing.expectEqualSlices(u8, rig.dual_second, root.elf1.?.bytes);
    try std.testing.expectEqualSlices(u8, &ra8.session.history_root.identity(rig.dual_second), &root.elf1.?.identity);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    for (0..2) |_| {
        var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.dual_image, .{});
        defer result.deinit();
        try std.testing.expectEqual(replay.Verdict.compatible, result.verdict);
        try std.testing.expect(result.checkpoints > 1);
        try std.testing.expectEqual(result.checkpoints, result.matched);
        try std.testing.expect(result.round > 0);
        try std.testing.expect(result.divergence == null);
        try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
    }
}

test "a rebuilt CPU0 reset loop diverges in an executed dual recording" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.openDual(gpa, 4);
    defer recorded.close(gpa);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rig.dual_image, gpa, .unlimited);
    defer gpa.free(bytes);
    const image = try ra8.board.image.elf.Image.init(bytes);
    const reset = ra8.session.symbols.addressOf(image, "Reset_Handler").? & ~@as(u32, 1);
    var patched = false;
    for (0..image.segmentCount()) |i| {
        const segment = image.loadSegment(@intCast(i)) orelse continue;
        if (reset < segment.paddr or reset - segment.paddr + 2 > segment.bytes.len) continue;
        const offset = @intFromPtr(segment.bytes.ptr) - @intFromPtr(bytes.ptr) + reset - segment.paddr;
        // Thumb B .: a valid executable rebuild that never leaves reset.
        @memcpy(bytes[offset..][0..2], &[_]u8{ 0xfe, 0xe7 });
        patched = true;
        break;
    }
    try std.testing.expect(patched);
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "reset-loop.elf", .data = bytes });
    const path = try temp.dir.realPathFileAlloc(std.testing.io, "reset-loop.elf", gpa);
    defer gpa.free(path);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), path, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, result.verdict);
    try std.testing.expectEqual(@as(u32, 1), result.matched);
    const d = result.divergence.?;
    try std.testing.expectEqual(@as(u8, 0), d.core);
    try std.testing.expectEqual(reset, d.pc_actual);
    try std.testing.expectEqualStrings("Reset_Handler", d.symbol.?.name);
    try std.testing.expectEqual(@as(u32, 0), d.symbol.?.offset);
    try std.testing.expect(d.place != null);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

const ChangeSecond = struct {
    pc: u32 = 0,
    fn prepare(context: *anyopaque, served: *ra8.rpc.served_setup.Served, _: []const u8) anyerror!void {
        const self: *ChangeSecond = @ptrCast(@alignCast(context));
        self.pc = served.second.?.cpu().regs.pc;
        served.second.?.cpu().regs.low[3] ^= 0x42;
    }
};

test "CPU1 state divergence reports its own PC and symbol without modifying history" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.openDual(gpa, 3);
    defer recorded.close(gpa);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var change: ChangeSecond = .{};
    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.dual_image, .{ .prepare = .{ .context = &change, .prepareFn = ChangeSecond.prepare } });
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, result.verdict);
    const d = result.divergence.?;
    try std.testing.expectEqual(@as(u32, 0), result.matched);
    try std.testing.expectEqual(@as(u8, 1), d.core);
    try std.testing.expectEqual(change.pc, d.pc_expected);
    try std.testing.expectEqual(change.pc, d.pc_actual);
    try std.testing.expectEqualStrings("r3", d.place.?.register.name);
    const image = try ra8.board.image.elf.Image.init(rig.dual_second);
    const symbol = ra8.session.symbols.inside(image, change.pc & ~@as(u32, 1)).?;
    try std.testing.expectEqualStrings(symbol.name, d.symbol.?.name);
    try std.testing.expectEqual(symbol.offset, d.symbol.?.offset);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}
