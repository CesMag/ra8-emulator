//! Complete SD-codec startup, offline replay and immutable-object admission.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");
const gpa = std.testing.allocator;
const io = std.testing.io;
const setup = ra8.rpc.served_setup;

test "root media observes the recorder's share and free floor before storing bytes" {
    var opened: setup.Served = undefined;
    try opened.open(gpa, io, rig.image, rig.small_profile, .{ .ram_budget = 256 * 1024 * 1024 });
    defer opened.deinit();
    const recorder = opened.owner.session().persistent_recorder.?;
    const held = opened.ram_history.?.objects.items.len;
    const accounted = recorder.root_bytes;
    const Free = struct {
        bytes: u64,
        fn read(context: *anyopaque) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.bytes;
        }
    };
    var free: Free = .{ .bytes = 1 };
    const original = recorder.disk;
    defer recorder.disk = original;
    recorder.disk = .{ .context = &free, .free = Free.read, .cap = std.math.maxInt(u64), .floor = 1 };
    try std.testing.expectError(error.HistoryFull, ra8.rpc.served_media.save(gpa, opened.owner.board(), recorder));
    try std.testing.expectEqual(held, opened.ram_history.?.objects.items.len);
    try std.testing.expectEqual(accounted, recorder.root_bytes);
    free.bytes = std.math.maxInt(u64);
    recorder.disk.?.cap = accounted + 1;
    try std.testing.expectError(error.HistoryFull, ra8.rpc.served_media.save(gpa, opened.owner.board(), recorder));
    try std.testing.expectEqual(held, opened.ram_history.?.objects.items.len);
    try std.testing.expectEqual(accounted, recorder.root_bytes);
}

test "root media uses the overall share without suppressing a required checkpoint" {
    var opened: setup.Served = undefined;
    try opened.open(gpa, io, rig.image, rig.small_profile, .{ .ram_budget = 256 * 1024 * 1024 });
    defer opened.deinit();
    const recorder = opened.owner.session().persistent_recorder.?;
    const checkpoint = opened.owner.session().live.checkpoints.?;
    const bridge = opened.owner.transport().history.?;
    const before = (try bridge.facts(bridge.context)).checkpoints.len;
    checkpoint.object_cap = recorder.object_bytes + checkpoint.last_size;
    recorder.root_bytes = checkpoint.object_cap + 1;
    try checkpoint.checkpointNow();
    try std.testing.expectEqual(before + 1, (try bridge.facts(bridge.context)).checkpoints.len);
    checkpoint.object_cap = 0;
    recorder.disk.?.cap = recorder.history_bytes + recorder.object_bytes + recorder.root_bytes + 1;
    try std.testing.expectError(error.HistoryFull, checkpoint.checkpointNow());
    try std.testing.expectEqual(before + 1, (try bridge.facts(bridge.context)).checkpoints.len);
}

fn sd(bytes: []const u8) ![]const u8 {
    return (try ra8.snapshot.file.Reader.find(bytes, .sd)).?.payload;
}

fn saved(opened: *setup.Served) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try opened.owner.session().history.?.files.writeTo(&out.writer);
    return out.toOwnedSlice();
}

fn app() [ra8.board.image.ra8app.header_len + 24]u8 {
    const fmt = ra8.board.image.ra8app;
    var bytes: [fmt.header_len + 24]u8 = @splat(0);
    const words = [_]u32{ fmt.magic, fmt.version, 4, 16, 8, 0x800, 1, fmt.Capability.display };
    for (words, 0..) |word, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], word, .little);
    @memcpy(bytes[32..][0..9], "com.hello");
    @memcpy(bytes[64..][0..5], "Hello");
    @memcpy(bytes[fmt.header_len..][0..24], "original-app-code-and-ram"[0..24]);
    return bytes;
}

fn paths(temp: std.testing.TmpDir) !struct { dir: [:0]u8, image: [:0]u8, app: [:0]u8 } {
    try temp.dir.createDir(io, "card", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "card/sentinel.txt", .data = "original directory input bytes" });
    try temp.dir.writeFile(io, .{ .sub_path = "hello.ra8app", .data = &app() });
    const raw = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(raw);
    for (raw, 0..) |*byte, i| byte.* = @truncate(i *% 73 +% 11);
    try temp.dir.writeFile(io, .{ .sub_path = "card.img", .data = raw });
    return .{
        .dir = try temp.dir.realPathFileAlloc(io, "card", gpa),
        .image = try temp.dir.realPathFileAlloc(io, "card.img", gpa),
        .app = try temp.dir.realPathFileAlloc(io, "hello.ra8app", gpa),
    };
}

test "raw image directory and app startup seed exact boot checkpoint and reverse window" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const inputs = try paths(temp);
    defer gpa.free(inputs.dir);
    defer gpa.free(inputs.image);
    defer gpa.free(inputs.app);
    var apps: ra8.rpc.served_card.Options = .{};
    try apps.addApp(inputs.app);
    const cards = [_]ra8.rpc.served_card.Options{ .{ .image = inputs.image }, .{ .dir = inputs.dir }, apps };
    for (cards) |card| {
        var opened: setup.Served = undefined;
        try opened.openInputs(gpa, io, rig.image, rig.small_profile, .{ .ram_budget = 256 * 1024 * 1024 }, null, .{ .card = card });
        defer opened.deinit();
        const live = try saved(&opened);
        defer gpa.free(live);
        const expected = try sd(live);
        try std.testing.expect(expected.len > 512);
        try std.testing.expectEqualSlices(u8, expected, try sd(opened.owner.session().window.?.hot));
        const plane = opened.owner.transport();
        const bridge = plane.history.?;
        const facts = try bridge.facts(bridge.context);
        try std.testing.expectEqual(@as(usize, 1), facts.checkpoints.len);
        const cp = facts.checkpoints[0];
        const garbage: [512]u8 = @splat(0xff);
        try std.testing.expect(opened.owner.board().host_card.write(0, &garbage));
        try plane.restoreBase(.{ .checkpoint = .{ .id = cp.id, .object = cp.object, .position = cp.position } });
        const restored = try saved(&opened);
        defer gpa.free(restored);
        try std.testing.expectEqualSlices(u8, expected, try sd(restored));
    }
}

test "cold reopen and rebuilt replay use frozen directory app and image after sources disappear" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const inputs = try paths(temp);
    defer gpa.free(inputs.dir);
    defer gpa.free(inputs.image);
    defer gpa.free(inputs.app);
    var combined: ra8.rpc.served_card.Options = .{ .dir = inputs.dir };
    try combined.addApp(inputs.app);
    const cards = [_]ra8.rpc.served_card.Options{ .{ .image = inputs.image }, combined };
    for (cards, 0..) |card, i| {
        const recorded = try rig.Recorded.openStartup(gpa, 3, rig.small_profile, rig.image, null, .{ .card = card });
        defer recorded.close(gpa);
        if (i == 0) try temp.dir.deleteFile(io, "card.img") else {
            try temp.dir.deleteFile(io, "card/sentinel.txt");
            try temp.dir.deleteFile(io, "hello.ra8app");
        }
        const bytes = try recorded.rootBytes(gpa);
        defer gpa.free(bytes);
        const root = try ra8.session.history_root.decode(bytes);
        var opened: setup.Served = undefined;
        try opened.openInputs(gpa, io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }, null, .{ .card = card });
        const live = try saved(&opened);
        defer gpa.free(live);
        try std.testing.expectEqual(root.media.?, opened.root.media.?);
        const frozen = opened.history.?.media_bytes.?;
        try std.testing.expectEqualSlices(u8, try sd(frozen), try sd(live));
        opened.deinit();
        const before = try rig.hashTree(gpa, recorded.base.dir);
        var result = try ra8.rpc.regression_replay.run(gpa, io, &recorded.base, recorded.sessionName(), rig.image, .{});
        defer result.deinit();
        try std.testing.expectEqual(ra8.rpc.regression_replay.Verdict.compatible, result.verdict);
        try std.testing.expectEqual(@as(u32, 3), result.matched);
        try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
        const changed = try rig.patched(gpa, temp.dir, "rebuilt.elf");
        defer gpa.free(changed);
        var divergent = try ra8.rpc.regression_replay.run(gpa, io, &recorded.base, recorded.sessionName(), changed, .{});
        defer divergent.deinit();
        try std.testing.expectEqual(ra8.rpc.regression_replay.Verdict.diverged, divergent.verdict);
        try std.testing.expect(divergent.matched >= 1);
        try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
    }
}

test "missing or corrupt root media rejects before log recovery and rebuilt host access" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try ra8.session.history_root.decode(bytes);
    const name = std.fmt.bytesToHex(root.media.?, .lower);
    var leaf: [40]u8 = undefined;
    const object = try std.fmt.bufPrint(&leaf, "objects/{s}", .{name});
    try recorded.writeFile(object, "corrupted SD bytes");
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var opened: setup.Served = undefined;
    try std.testing.expectError(error.InitialMediaMismatch, opened.open(gpa, io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
    try std.testing.expectError(error.InitialMediaMismatch, ra8.rpc.regression_replay.run(gpa, io, &recorded.base, recorded.sessionName(), "missing-rebuilt.elf", .{}));
    try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
    const dir = try recorded.base.dir.openDir(io, recorded.sessionName(), .{});
    defer dir.close(io);
    try dir.deleteFile(io, object);
    const missing = try rig.hashTree(gpa, recorded.base.dir);
    try std.testing.expectError(error.FileNotFound, opened.open(gpa, io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    try std.testing.expectEqual(missing, try rig.hashTree(gpa, recorded.base.dir));
    try std.testing.expectError(error.FileNotFound, ra8.rpc.regression_replay.run(gpa, io, &recorded.base, recorded.sessionName(), "missing-rebuilt.elf", .{}));
    try std.testing.expectEqual(missing, try rig.hashTree(gpa, recorded.base.dir));
}

test "root media remains live for prune with no retained checkpoint references" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try ra8.session.history_root.decode(bytes);
    const bind = try ra8.rpc.history_bind.Bind.open(gpa, io, recorded.root, .{ .reopen = try ra8.host.history.name.id(recorded.sessionName()) });
    defer _ = bind.close() catch {};
    var names = std.StringHashMap(void).init(gpa);
    defer {
        var keys = names.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        names.deinit();
    }
    try ra8.rpc.history_live.addManifestObjects(ra8.host.history.storage.Store.from(&bind.session), gpa, &names);
    const name = std.fmt.bytesToHex(root.media.?, .lower);
    try std.testing.expect(names.contains(&name));
}

test "hash-correct malformed media refuses before repairing the original log" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    var root = try ra8.session.history_root.decode(bytes);
    var header: std.Io.Writer.Allocating = .init(gpa);
    defer header.deinit();
    try ra8.snapshot.file.writeHeader(&header.writer);
    const cases = [_]struct { bytes: []const u8, err: anyerror }{
        .{ .bytes = header.written(), .err = error.Missing },
        .{ .bytes = "not a snapshot", .err = error.BadMagic },
    };
    for (cases) |case| {
        const id = ra8.session.history_object_id.ObjectId.compute(case.bytes);
        root.media = id.bytes;
        try recorded.writeRoot(root);
        const name = std.fmt.bytesToHex(id.bytes, .lower);
        var path: [40]u8 = undefined;
        try recorded.writeFile(try std.fmt.bufPrint(&path, "objects/{s}", .{name}), case.bytes);
        try recorded.writeFile("log/events-0", "torn tail must survive");
        try recorded.writeFile("incomplete", "unfinished recording");
        const before = try rig.hashTree(gpa, recorded.base.dir);
        var opened: setup.Served = undefined;
        try std.testing.expectError(case.err, opened.open(gpa, io, rig.image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
        try std.testing.expectEqual(before, try rig.hashTree(gpa, recorded.base.dir));
    }
}

test "host card failure leaves no kept partial session and rooted late staging refuses" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var opened: setup.Served = undefined;
    try std.testing.expectError(error.FileNotFound, opened.openInputs(gpa, io, rig.image, rig.small_profile, .{ .root = path, .kept = true }, null, .{ .card = .{ .image = "absent-startup.img" } }));
    var base = try ra8.host.history.base.Base.existing(gpa, io, path, .cache);
    defer base.close();
    var entries = try ra8.host.history.catalog.Iterator.init(&base);
    while (try entries.next()) |entry| try std.testing.expect(entry.kind != .session);
    try opened.open(gpa, io, rig.image, rig.small_profile, .{ .ram_budget = 256 * 1024 * 1024 });
    defer opened.deinit();
    try std.testing.expectError(error.HistoryAlreadyRooted, opened.stageApps(io, gpa, &.{"absent.ra8app"}));
}
