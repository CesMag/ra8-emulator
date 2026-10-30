//! Covers history_validity.zig through the read-only replay entry point:
//! every rejected family precedes image/host access and preserves bytes.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");
const root = ra8.session.history_root;
const validity = ra8.rpc.history_validity;
const gpa = std.testing.allocator;

fn changed(r: root.Root, comptime field: []const u8, value: anytype) root.Root {
    var copy = r;
    @field(copy, field) = value;
    return copy;
}

const Host = struct {
    called: bool = false,
    fn prepare(context: *anyopaque, _: *ra8.rpc.served_setup.Served, _: []const u8) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.called = true;
        return error.UnexpectedHostAccess;
    }
};

test "recorded validity and every unsupported configuration fail before image or host access" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const r = try root.decode(bytes);
    const Case = struct { value: root.Root, err: anyerror };
    const cases = [_]Case{
        .{ .value = changed(r, "emulator_commit", @as([20]u8, @splat(0))), .err = error.UnknownBuildIdentity },
        .{ .value = changed(r, "emulator_commit", @as([20]u8, @splat(7))), .err = error.BuildMismatch },
        .{ .value = changed(r, "model_version", ""), .err = error.ModelMismatch },
        .{ .value = changed(r, "model_version", "another-model"), .err = error.ModelMismatch },
        .{ .value = changed(r, "snapshot_version", 1), .err = error.SnapshotVersionMismatch },
        .{ .value = changed(r, "snapshot_version", validity.snapshot_version + 1), .err = error.SnapshotVersionMismatch },
        .{ .value = changed(r, "part", "ra8d2"), .err = error.UnsupportedRootPart },
        .{ .value = changed(r, "board_profile", ""), .err = error.MissingRootProfile },
        .{ .value = changed(r, "board_profile", "version=2\n"), .err = error.BadVersion },
        .{ .value = changed(r, "board_profile", "version=1\nospi=broken\n"), .err = error.BadMemory },
        .{ .value = changed(r, "memory_config", "snapshot memory payload"), .err = error.UnsupportedRootMemory },
        .{ .value = changed(r, "grid", "snapshot grid payload"), .err = error.UnsupportedRootGrid },
        .{ .value = changed(r, "idle_skip", false), .err = error.UnsupportedRootIdleSkip },
        .{ .value = changed(r, "panel_vsync", @as(?root.Vsync, .{ .phase_ns = 0, .period_ns = 1 })), .err = error.UnsupportedRootVsync },
        .{ .value = changed(r, "pace", root.Pace.boundary), .err = error.UnsupportedRootPace },
        .{ .value = changed(r, "rtc_start", @as(?root.Start, .{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 })), .err = error.UnsupportedRootRtcStart },
        .{ .value = changed(r, "attaches", "snapshot attaches"), .err = error.UnsupportedRootAttaches },
        .{ .value = changed(r, "faults", "snapshot faults"), .err = error.UnsupportedRootFaults },
        .{ .value = changed(changed(r, "input_script", "script"), "input_hash", root.identity("script")), .err = error.UnsupportedRootInput },
        .{ .value = changed(changed(r, "camera", "webcam:0"), "camera_hash", root.identity("webcam:0")), .err = error.UnsupportedRootCamera },
        .{ .value = changed(r, "skip_flags", 1), .err = error.UnsupportedRootSkipFlags },
        .{ .value = changed(r, "elf1", @as(?root.Image, r.elf0)), .err = error.SecondCoreRecorded },
    };
    for (cases) |case| {
        try recorded.writeRoot(case.value);
        const before = try rig.hashTree(gpa, recorded.base.dir);
        var host: Host = .{};
        try std.testing.expectError(case.err, ra8.rpc.regression_replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), "missing-rebuilt.elf", .{ .prepare = .{ .context = &host, .prepareFn = Host.prepare } }));
        try std.testing.expect(!host.called);
        try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
    }
}

test "historical placeholder provenance stays decodable but cannot authorize replay" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const image = (try root.decode(bytes)).elf0;
    try recorded.writeRoot(.{ .snapshot_version = 1, .elf0 = image });
    const legacy = try recorded.rootBytes(gpa);
    defer gpa.free(legacy);
    _ = try root.decode(legacy);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    try std.testing.expectError(error.UnknownBuildIdentity, ra8.rpc.regression_replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.image, .{}));
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "checkpoint format and original image gates precede rebuilt image and host access" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, rig.image, null, null);
    defer served.deinit();
    var stream: std.Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    try served.owner.session().history.?.files.writeTo(&stream.writer);
    const snapshot = stream.written();
    const file = ra8.snapshot.file;
    const part = (try file.Reader.find(snapshot, .part)).?;
    const image = (try file.Reader.find(snapshot, .image)).?;
    const Case = struct { offset: usize, err: anyerror };
    const cases = [_]Case{
        .{ .offset = file.magic.len, .err = error.BadVersion },
        .{ .offset = @intFromPtr(part.payload.ptr) - @intFromPtr(snapshot.ptr), .err = error.WrongPart },
        .{ .offset = @intFromPtr(image.payload.ptr) - @intFromPtr(snapshot.ptr) + 1, .err = error.ImageMismatch },
    };
    for (cases) |case| {
        snapshot[case.offset] ^= 1;
        try recorded.checkpointLog(.{}, snapshot);
        snapshot[case.offset] ^= 1;
        try expectRejection(recorded, case.err);
    }
    try recorded.checkpointLog(.{ .o = 1 }, null);
    try expectRejection(recorded, error.UnsupportedCheckpointPosition);
    try recorded.checkpointLog(.{}, null);
    try expectRejection(recorded, error.ObjectMissing);
    try recorded.checkpointLog(.{}, snapshot);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(snapshot, &hash, .{});
    const hex = std.fmt.bytesToHex(hash[0..16].*, .lower);
    var path: [40]u8 = undefined;
    try recorded.writeFile(try std.fmt.bufPrint(&path, "objects/{s}", .{hex}), "corrupted object");
    try expectRejection(recorded, error.CheckpointObjectMismatch);
}

fn expectRejection(recorded: *const rig.Recorded, expected: anyerror) !void {
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var host: Host = .{};
    try std.testing.expectError(expected, ra8.rpc.regression_replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), "missing-rebuilt.elf", .{ .prepare = .{ .context = &host, .prepareFn = Host.prepare } }));
    try std.testing.expect(!host.called);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}
