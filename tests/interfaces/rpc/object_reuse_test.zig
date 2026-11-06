//! Existing-file verification never mutates a collision and closes on all paths.
const std = @import("std");
const ra8 = @import("ra8");
const storage = ra8.host.history.storage;
const reuse = ra8.rpc.object_reuse;
const gpa = std.testing.allocator;

const Fake = struct {
    bytes: []const u8,
    fault: enum { none, open, length, read, sync, eof } = .none,
    closes: usize = 0,
    syncs: usize = 0,
    max_read: usize = 3,

    fn cast(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn store(self: *Fake) storage.Store {
        return .{ .context = self, .vtable = &.{ .open = open, .remove = remove, .rename = rename, .list = list } };
    }
    fn open(ctx: *anyopaque, space: ra8.host.history.layout.Space, name: []const u8, mode: storage.Mode) !storage.ByteFile {
        try std.testing.expectEqual(.objects, space);
        try std.testing.expectEqualStrings("object", name);
        try std.testing.expectEqual(.update, mode);
        if (cast(ctx).fault == .open) return error.Injected;
        return .{ .context = ctx, .vtable = &.{ .read = read, .write = write, .length = length, .truncate = truncate, .sync = sync, .close = close } };
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) !usize {
        const self = cast(ctx);
        if (self.fault == .read) return error.Injected;
        if (self.fault == .eof) return 0;
        const at: usize = @intCast(offset);
        const count = @min(out.len, self.bytes.len - at, self.max_read);
        @memcpy(out[0..count], self.bytes[at..][0..count]);
        return count;
    }
    fn length(ctx: *anyopaque) !u64 {
        if (cast(ctx).fault == .length) return error.Injected;
        return cast(ctx).bytes.len;
    }
    fn sync(ctx: *anyopaque) !void {
        const self = cast(ctx);
        self.syncs += 1;
        if (self.fault == .sync) return error.Injected;
    }
    fn close(ctx: *anyopaque) void {
        cast(ctx).closes += 1;
    }
    fn write(_: *anyopaque, _: u64, _: []const u8) !void {
        return error.UnexpectedMutation;
    }
    fn truncate(_: *anyopaque, _: u64) !void {
        return error.UnexpectedMutation;
    }
    fn remove(_: *anyopaque, _: ra8.host.history.layout.Space, _: []const u8) !void {
        return error.UnexpectedMutation;
    }
    fn rename(_: *anyopaque, _: ra8.host.history.layout.Space, _: []const u8, _: []const u8) !void {
        return error.UnexpectedMutation;
    }
    fn list(_: *anyopaque, _: ra8.host.history.layout.Space, _: storage.Visitor) !void {
        return error.UnexpectedOperation;
    }
};

test "existing data handles short reads multiple chunks and zero bytes before syncing" {
    var bytes: [8193]u8 = @splat(42);
    var fake: Fake = .{ .bytes = &bytes };
    try reuse.existing(gpa, fake.store(), "object", .data, &bytes);
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
    try std.testing.expectEqual(@as(usize, 1), fake.syncs);
    var empty: Fake = .{ .bytes = "" };
    try reuse.existing(gpa, empty.store(), "object", .data, "");
    try std.testing.expectEqual(@as(usize, 1), empty.syncs);
}

test "partial and same-size corrupted existing data are refused without repair" {
    for ([_][]const u8{ "pa", "Partial" }) |old| {
        var fake: Fake = .{ .bytes = old };
        try std.testing.expectError(error.ObjectConflict, reuse.existing(gpa, fake.store(), "object", .data, "partial"));
        try std.testing.expectEqual(@as(usize, 1), fake.closes);
        try std.testing.expectEqual(@as(usize, 0), fake.syncs);
        try std.testing.expectEqualStrings(old, fake.bytes);
    }
}

test "existing-file IO failures propagate and close once including failed sync retry" {
    const faults = [_]@FieldType(Fake, "fault"){ .open, .length, .read, .sync };
    for (faults) |fault| {
        var fake: Fake = .{ .bytes = "partial", .fault = fault };
        try std.testing.expectError(error.Injected, reuse.existing(gpa, fake.store(), "object", .data, "partial"));
        try std.testing.expectEqual(@as(usize, if (fault == .open) 0 else 1), fake.closes);
        if (fault == .sync) {
            fake.fault = .none;
            try reuse.existing(gpa, fake.store(), "object", .data, "partial");
            try std.testing.expectEqual(@as(usize, 2), fake.syncs);
            try std.testing.expectEqual(@as(usize, 2), fake.closes);
        }
    }
    var short: Fake = .{ .bytes = "partial", .fault = .eof };
    try std.testing.expectError(error.ObjectConflict, reuse.existing(gpa, short.store(), "object", .data, "partial"));
    try std.testing.expectEqual(@as(usize, 1), short.closes);
    try std.testing.expectEqual(@as(usize, 0), short.syncs);
}

const StageStore = @import("object_stage_fixture.zig").StageStore;

fn makeManifest(id: u32, round: u64) ![]u8 {
    const manifest = ra8.session.history_manifest;
    const position: ra8.session.history_position.Position = .{ .r = round };
    var pages = [_]manifest.PageRef{.{ .space = .cpu0_sram, .page_index = 0, .object = .compute("page") }};
    const value: manifest.Manifest = .{
        .position = position,
        .checkpoint_id = id,
        .pages = &pages,
        .blobs = &.{},
        .root_hash = manifest.computeMerkleRoot(position, id, null, &pages, &.{}),
    };
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer out.deinit();
    try manifest.encode(&value, &out.writer);
    return gpa.dupe(u8, out.written());
}

fn makeTouched(since: u32, words: []const u64) ![]u8 {
    const touched = ra8.session.history_touched_pages;
    var value: touched.Touched = .{ .allocator = gpa, .since = since, .masks = @splat(&.{}) };
    value.masks[0] = @constCast(words);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer out.deinit();
    try value.encode(&out.writer);
    return gpa.dupe(u8, out.written());
}

test "atomic put stages and syncs temp before rename and retries cleanly after write sync or rename failure" {
    var stage: StageStore = .{};
    defer stage.deinit();
    stage.write_limit = 2;
    try std.testing.expectError(error.InjectedWrite, reuse.putWith(gpa, stage.store(), "target", .data, "complete", .{ .dir_sync = stage.dirSync() }));
    try std.testing.expect(!stage.final_live);
    try std.testing.expect(!stage.temp_live);
    try std.testing.expectEqual(@as(usize, 0), stage.open_handles);
    try std.testing.expectEqual(@as(usize, 0), stage.renames);

    stage.write_limit = null;
    stage.fail_sync_temp = true;
    try std.testing.expectError(error.InjectedSync, reuse.putWith(gpa, stage.store(), "target", .data, "complete", .{ .dir_sync = stage.dirSync() }));
    try std.testing.expect(!stage.final_live);
    try std.testing.expect(!stage.temp_live);
    try std.testing.expectEqual(@as(usize, 0), stage.renames);

    stage.fail_sync_temp = false;
    stage.fail_rename = error.InjectedRename;
    try std.testing.expectError(error.InjectedRename, reuse.putWith(gpa, stage.store(), "target", .data, "complete", .{ .dir_sync = stage.dirSync() }));
    try std.testing.expect(!stage.final_live);
    try std.testing.expect(!stage.temp_live);
    try std.testing.expectEqual(@as(usize, 1), stage.renames);

    stage.fail_rename = null;
    stage.fail_dir_sync = true;
    try std.testing.expectError(error.InjectedDirSync, reuse.putWith(gpa, stage.store(), "target", .data, "complete", .{ .dir_sync = stage.dirSync() }));
    try std.testing.expect(stage.final_live);
    try std.testing.expectEqualStrings("complete", stage.finalSlice());
    try std.testing.expect(!stage.temp_live);

    stage.fail_dir_sync = false;
    try reuse.putWith(gpa, stage.store(), "target", .data, "complete", .{ .dir_sync = stage.dirSync() });
    try std.testing.expectEqualStrings("complete", stage.finalSlice());
    try std.testing.expectEqual(@as(usize, 2), stage.final_syncs);
    try std.testing.expectEqual(@as(usize, 2), stage.dir_syncs);
}

test "rename collision preserves first valid data manifest and touched aliases and rejects conflicts while removing owned temp" {
    var stage: StageStore = .{};
    defer stage.deinit();
    const m1 = try makeManifest(1, 4);
    defer gpa.free(m1);
    const m2 = try makeManifest(2, 4);
    defer gpa.free(m2);
    const m_bad = try makeManifest(3, 5);
    defer gpa.free(m_bad);
    try stage.seedFinal("manifest-obj", m1);
    try reuse.putWith(gpa, stage.store(), "manifest-obj", .manifest, m2, .{ .dir_sync = stage.dirSync() });
    try std.testing.expectEqualSlices(u8, m1, stage.finalSlice());
    try std.testing.expect(!stage.temp_live);
    try std.testing.expectError(error.ObjectConflict, reuse.putWith(gpa, stage.store(), "manifest-obj", .manifest, m_bad, .{ .dir_sync = stage.dirSync() }));
    try std.testing.expectEqualSlices(u8, m1, stage.finalSlice());
    try std.testing.expect(!stage.temp_live);

    const t1 = try makeTouched(0, &.{1});
    defer gpa.free(t1);
    const t2 = try makeTouched(1, &.{0});
    defer gpa.free(t2);
    const t_bad = try makeTouched(0, &.{0});
    defer gpa.free(t_bad);
    try stage.seedFinal("touched-obj", t1);
    try reuse.putWith(gpa, stage.store(), "touched-obj", .touched, t2, .{ .dir_sync = stage.dirSync() });
    try std.testing.expectEqualSlices(u8, t1, stage.finalSlice());
    try std.testing.expect(!stage.temp_live);
    try std.testing.expectError(error.ObjectConflict, reuse.putWith(gpa, stage.store(), "touched-obj", .touched, t_bad, .{ .dir_sync = stage.dirSync() }));
    try std.testing.expectEqualSlices(u8, t1, stage.finalSlice());
    try std.testing.expect(!stage.temp_live);
}

test "temp collision never touches foreign temp and cleanup failure propagates with boundary sizes" {
    var stage: StageStore = .{ .foreign_name = "object-put-00000000000000000000000000000001" };
    defer stage.deinit();
    const SeqGen = struct {
        step: usize = 0,
        exhaust: bool = false,
        fn next(ctx: *anyopaque, buf: *[ra8.host.history.name.limits.component]u8) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer self.step += 1;
            if (self.exhaust or self.step == 0) {
                return std.fmt.bufPrint(buf, "object-put-00000000000000000000000000000001", .{});
            }
            return std.fmt.bufPrint(buf, "object-put-00000000000000000000000000000002", .{});
        }
    };
    var gen: SeqGen = .{};
    const max_leaf: [ra8.host.history.name.limits.component]u8 = @splat('a');
    var large: [8193]u8 = @splat(0x5a);
    try reuse.putWith(gpa, stage.store(), &max_leaf, .data, &large, .{ .temp_gen = .{ .context = &gen, .next = SeqGen.next } });
    try std.testing.expect(!stage.foreign_removed);
    try std.testing.expectEqualSlices(u8, &large, stage.finalSlice());

    try reuse.put(gpa, stage.store(), "empty-obj", .data, "");
    try std.testing.expectEqualStrings("", stage.finalSlice());

    var exhausted: SeqGen = .{ .exhaust = true };
    try std.testing.expectError(error.PathAlreadyExists, reuse.putWith(gpa, stage.store(), "never", .data, "x", .{ .temp_gen = .{ .context = &exhausted, .next = SeqGen.next } }));
    try std.testing.expect(!stage.foreign_removed);

    stage.fail_rename = error.InjectedRename;
    stage.fail_remove = error.InjectedCleanup;
    try std.testing.expectError(error.InjectedCleanup, reuse.put(gpa, stage.store(), "cleanup-err", .data, "x"));
    try std.testing.expect(stage.temp_live);
    try std.testing.expectEqual(@as(usize, 0), stage.open_handles);
}

test "every partial write prefix leaves no canonical object and leaks no handles" {
    const bytes = "complete payload";
    for (0..bytes.len + 1) |prefix_len| {
        var stage: StageStore = .{ .write_limit = prefix_len };
        defer stage.deinit();
        try std.testing.expectError(error.InjectedWrite, reuse.put(gpa, stage.store(), "target", .data, bytes));
        try std.testing.expect(!stage.final_live);
        try std.testing.expect(!stage.temp_live);
        try std.testing.expectEqual(@as(usize, 0), stage.open_handles);
        try std.testing.expectEqual(@as(usize, 0), stage.renames);
        stage.write_limit = null;
        try reuse.put(gpa, stage.store(), "target", .data, bytes);
        try std.testing.expectEqualStrings(bytes, stage.finalSlice());
        try std.testing.expect(stage.final_reads > 0);
        try std.testing.expectEqual(@as(usize, 1), stage.final_syncs);
        try std.testing.expectEqual(@as(usize, 0), stage.open_handles);
    }
}

test "post-publication final flush failure is returned before the directory barrier and retries" {
    var stage: StageStore = .{ .fail_sync_final = true };
    defer stage.deinit();
    try std.testing.expectError(error.InjectedFinalSync, reuse.put(gpa, stage.store(), "target", .data, "complete"));
    try std.testing.expect(stage.final_live);
    try std.testing.expect(!stage.temp_live);
    try std.testing.expect(stage.final_reads > 0);
    try std.testing.expectEqual(@as(usize, 0), stage.dir_syncs);
    try std.testing.expectEqual(@as(usize, 0), stage.open_handles);
    stage.fail_sync_final = false;
    try reuse.putWith(gpa, stage.store(), "target", .data, "complete", .{ .dir_sync = stage.dirSync() });
    try std.testing.expectEqualStrings("complete", stage.finalSlice());
    try std.testing.expectEqual(@as(usize, 1), stage.dir_syncs);
}
