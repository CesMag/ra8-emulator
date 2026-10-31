//! Persisted dual roots and reopen startup use both initial images.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");
const gpa = std.testing.allocator;
const root_mod = ra8.session.history_root;

fn changed(r: root_mod.Root, comptime field: []const u8, value: anytype) root_mod.Root {
    var copy = r;
    @field(copy, field) = value;
    return copy;
}

fn pendingRename(recorded: *rig.Recorded) !void {
    const dir = try recorded.base.dir.openDir(std.testing.io, recorded.sessionName(), .{ .iterate = true });
    defer dir.close(std.testing.io);
    const index = try dir.openDir(std.testing.io, "index", .{});
    defer index.close(std.testing.io);
    try index.writeFile(std.testing.io, .{ .sub_path = "admission.part", .data = "pending cache" });
    try ra8.host.history.rename.begin(std.testing.io, dir, index, .index, "admission.part", "admission");
}

test "a missing reopen container is never created as a new history" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const parent = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(parent);
    const path = try std.fs.path.join(gpa, &.{ parent, "missing" });
    defer gpa.free(path);
    const id: ra8.host.history.name.Id = @splat('a');
    var served: ra8.rpc.served_setup.Served = undefined;
    try std.testing.expectError(error.FileNotFound, served.open(gpa, std.testing.io, "missing-image.elf", null, .{ .root = path, .reopen = &id }));
    try std.testing.expectError(error.FileNotFound, temp.dir.access(std.testing.io, "missing", .{}));
}

test "ordinary reopen refuses invalid provenance before image access or log repair" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try root_mod.decode(bytes);
    const Case = struct { value: root_mod.Root, err: anyerror };
    const cases = [_]Case{
        .{ .value = changed(root, "emulator_commit", @as([20]u8, @splat(0))), .err = error.UnknownBuildIdentity },
        .{ .value = changed(root, "emulator_commit", @as([20]u8, @splat(7))), .err = error.BuildMismatch },
        .{ .value = changed(root, "model_version", "different model"), .err = error.ModelMismatch },
        .{ .value = changed(root, "snapshot_version", root.snapshot_version + 1), .err = error.SnapshotVersionMismatch },
        .{ .value = changed(root, "board_profile", "version=2\n"), .err = error.BadVersion },
        .{ .value = changed(root, "grid", "unsupported grid"), .err = error.UnsupportedRootGrid },
        .{ .value = changed(root, "idle_skip", false), .err = error.UnsupportedRootIdleSkip },
    };
    // An unauthorized reopen must not even repair a torn log tail.
    try recorded.writeFile("log/events-0", "torn-tail");
    try recorded.writeFile("incomplete", "unfinished recording");
    if (builtin.os.tag == .linux) try pendingRename(recorded);
    for (cases) |case| {
        try recorded.writeRoot(case.value);
        const before = try rig.hashTree(gpa, recorded.base.dir);
        var served: ra8.rpc.served_setup.Served = undefined;
        try std.testing.expectError(case.err, served.open(gpa, std.testing.io, "missing-image.elf", null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
        try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
    }
}

test "ordinary reopen applies its frozen profile and keeps borrowed root bytes alive" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const before = try recorded.rootBytes(gpa);
    defer gpa.free(before);
    const root = try root_mod.decode(before);
    {
        var served: ra8.rpc.served_setup.Served = undefined;
        try served.open(gpa, std.testing.io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() });
        defer served.deinit();
        const bound = served.history.?.root.?;
        try std.testing.expectEqualStrings(root.model_version, bound.model_version);
        try std.testing.expectEqualStrings(root.board_profile, bound.board_profile);
        try std.testing.expectEqualSlices(u8, root.elf0.bytes, bound.elf0.bytes);
        try std.testing.expectEqual(@as(u32, 1024 * 1024), served.owner.state.profile.memory.sdram.size);
        try std.testing.expectEqualStrings(root.board_profile, served.root.board_profile);
    }
    const after = try recorded.rootBytes(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "an explicit conflicting reopen profile refuses before image access" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var served: ra8.rpc.served_setup.Served = undefined;
    try std.testing.expectError(error.BoardProfileMismatch, served.open(gpa, std.testing.io, "missing-image.elf", ra8.board.profile.ek_ra8d2, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
}

test "missing and mismatched images cannot repair or rewrite a rejected history" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const patched = try rig.patched(gpa, recorded.temp.dir, "patched.elf");
    defer gpa.free(patched);
    const session_dir = try recorded.base.dir.openDir(std.testing.io, recorded.sessionName(), .{});
    defer session_dir.close(std.testing.io);
    const log = try session_dir.readFileAlloc(std.testing.io, "log/events-0", gpa, .unlimited);
    defer gpa.free(log);
    const torn = try std.mem.concat(gpa, u8, &.{ log, "x" });
    defer gpa.free(torn);
    try recorded.writeFile("log/events-0", torn);
    try recorded.writeFile("incomplete", "unfinished recording");
    if (builtin.os.tag == .linux) try pendingRename(recorded);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var served: ra8.rpc.served_setup.Served = undefined;
    try std.testing.expectError(error.FileNotFound, served.open(gpa, std.testing.io, "missing-image.elf", null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
    try std.testing.expectError(error.ImageMismatch, served.open(gpa, std.testing.io, patched, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
    try std.testing.expectError(error.ImageMismatch, served.openInitial(gpa, std.testing.io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }, .{ .bytes = rig.dual_second }));
    try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
}

test "an admitted reopen settles a pending cache rename after checking its images" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    try pendingRename(recorded);
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() });
    defer served.deinit();
    try std.testing.expectError(error.FileNotFound, served.history.?.session.dir.access(std.testing.io, "renaming", .{}));
    try served.history.?.session.dir.access(std.testing.io, "index/admission.part", .{});
}

test "reopen refuses a pending rename of the immutable root without settling it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const dir = try recorded.base.dir.openDir(std.testing.io, recorded.sessionName(), .{ .iterate = true });
    defer dir.close(std.testing.io);
    try ra8.host.history.rename.begin(std.testing.io, dir, dir, .top, "root.bin", "branches.bin");
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var served: ra8.rpc.served_setup.Served = undefined;
    try std.testing.expectError(error.RootRenamePending, served.open(gpa, std.testing.io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
}

test "dual reopen preserves frozen root and the initial checkpoint" {
    const recorded = try rig.Recorded.openDual(gpa, 3);
    defer recorded.close(gpa);
    const before = try recorded.rootBytes(gpa);
    defer gpa.free(before);
    const root = try ra8.session.history_root.decode(before);
    {
        var served: ra8.rpc.served_setup.Served = undefined;
        try served.openInitial(gpa, std.testing.io, "absent-original-cpu0.elf", null, .{ .root = recorded.root, .reopen = recorded.sessionName(), .elf_bytes = root.elf0.bytes }, .{ .bytes = root.elf1.?.bytes });
        defer served.deinit();
        try std.testing.expect(served.second != null);
        try std.testing.expect(served.owner.session().persistent_recorder != null);
        const bridge = served.owner.transport().history.?;
        const facts = try bridge.facts(bridge.context);
        try std.testing.expectEqual(@as(usize, 3), facts.checkpoints.len);
        try std.testing.expectEqual(@as(u64, 0), served.owner.session().currentPosition().r);
        try std.testing.expectEqual(@as(u64, 0), served.second.?.cpu().slots);
        try std.testing.expectError(error.SecondCoreAlreadyOpen, served.openSecond("absent-original-cpu1.elf"));
    }
    const after = try recorded.rootBytes(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "reopen cannot silently add or remove CPU1 or replace a missing root" {
    const recorded = try rig.Recorded.openDual(gpa, 3);
    defer recorded.close(gpa);
    const before = try recorded.rootBytes(gpa);
    defer gpa.free(before);
    try recorded.writeFile("log/events-0", "torn-tail");
    const tree = try rig.hashTree(gpa, recorded.base.dir);
    var served: ra8.rpc.served_setup.Served = undefined;
    try std.testing.expectError(error.ImageMismatch, served.open(gpa, std.testing.io, rig.dual_image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    try std.testing.expectEqual(tree, try rig.hashTree(gpa, recorded.base.dir));
    try std.testing.expectError(error.ImageMismatch, served.openInitial(gpa, std.testing.io, rig.dual_image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }, .{ .bytes = "wrong CPU1" }));
    try std.testing.expectEqual(tree, try rig.hashTree(gpa, recorded.base.dir));
    const after = try recorded.rootBytes(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try recorded.writeFile("root.bin", "invalid root");
    try std.testing.expectError(error.NoRoot, served.open(gpa, std.testing.io, rig.dual_image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    const invalid = try recorded.rootBytes(gpa);
    defer gpa.free(invalid);
    try std.testing.expectEqualStrings("invalid root", invalid);
}
