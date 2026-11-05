//! Pending object liveness through the live bind's actual relief callback.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;
const Bind = ra8.rpc.history_bind.Bind;
const recorder = ra8.session.history_recorder;
const manifest = ra8.session.history_manifest;
const ObjectId = ra8.session.history_object_id.ObjectId;
const gpa = std.testing.allocator;
fn pageId() ObjectId {
    return ObjectId.compute("pending page");
}
fn orphanId() ObjectId {
    return ObjectId.compute("orphan page");
}

fn relief(bind: *Bind) !void {
    const disk = bind.disk.?;
    try disk.relief.?(disk.context);
}

fn expectLoose(bind: *Bind, name: []const u8, bytes: []const u8) !void {
    const store = history.storage.Store.from(&bind.session);
    const file = try store.vtable.open(store.context, .objects, name, .read);
    defer file.vtable.close(file.context);
    const buffer = try gpa.alloc(u8, bytes.len);
    defer gpa.free(buffer);
    try std.testing.expectEqual(bytes.len, try file.vtable.read(file.context, 0, buffer));
    try std.testing.expectEqualStrings(bytes, buffer);
}

fn expectPack(bind: *Bind, id: ObjectId, bytes: []const u8) !void {
    const found = (try bind.packs.get(gpa, id)) orelse return error.ObjectMissing;
    defer gpa.free(found);
    try std.testing.expectEqualStrings(bytes, found);
}

fn manifestBytes() ![]u8 {
    var pages = [_]manifest.PageRef{.{ .space = .cpu0_sram, .page_index = 0, .object = pageId() }};
    const position: ra8.chip.core.scheduler.Position = .{ .r = 2 };
    const m: manifest.Manifest = .{
        .position = position,
        .checkpoint_id = 1,
        .pages = &pages,
        .blobs = &.{},
        .root_hash = manifest.computeMerkleRoot(position, 1, null, &pages, &.{}),
    };
    var bytes: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer bytes.deinit();
    try manifest.encode(&m, &bytes.writer);
    return gpa.dupe(u8, bytes.written());
}

fn stage(rec: *recorder.Recorder) !void {
    const header: ra8.session.history_record.Header = .{ .position = .{ .r = 2 }, .seq = 0 };
    const touched: ra8.session.history_touched_pages.Touched = .{ .allocator = gpa, .since = 0, .masks = @splat(&.{}) };
    const bytes = try manifestBytes();
    defer gpa.free(bytes);
    try rec.checkpointPicture(header, 1, "picture");
    try rec.checkpointRecords(header, 1, "machine", &touched, bytes);
}

const Failure = struct {
    original: recorder.Storage,
    fail: bool = true,

    fn append(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Failure = @ptrCast(@alignCast(context));
        try self.original.append(self.original.context, bytes);
    }
    fn flush(context: *anyopaque) anyerror!void {
        const self: *Failure = @ptrCast(@alignCast(context));
        if (self.fail) return error.InjectedFlush;
        try self.original.flush(self.original.context);
    }
    fn truncate(context: *anyopaque, length: u64) anyerror!void {
        const self: *Failure = @ptrCast(@alignCast(context));
        try self.original.truncate(self.original.context, length);
    }
};

fn exercise(bind: *Bind) !void {
    var failure: Failure = .{ .original = bind.storage };
    var rec = try recorder.Recorder.init(gpa, .{ .context = &failure, .append = &Failure.append, .flush = &Failure.flush, .truncate = &Failure.truncate }, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = bind.objects;
    // Objects may already be sealed before a checkpoint has staged any record.
    try bind.objects.put(bind.objects.context, .data, "prestage", "before records");
    try bind.objects.putPacked.?(bind.objects.context, pageId().bytes, "pending page");
    try bind.objects.putPacked.?(bind.objects.context, orphanId().bytes, "orphan page");
    try bind.objects.sync(bind.objects.context);
    try relief(bind);
    try expectLoose(bind, "prestage", "before records");
    try expectPack(bind, pageId(), "pending page");
    try std.testing.expectEqual(@as(u64, 0), try bind.logLength());
    try stage(&rec);
    try std.testing.expectEqual(@as(usize, 7), bind.pending.names.count());
    try relief(bind);
    try expectPendingLoose(bind);
    try expectPack(bind, pageId(), "pending page");
    try std.testing.expectEqual(@as(u64, 0), try bind.logLength());
    try std.testing.expectError(error.InjectedFlush, rec.commit(1));
    try std.testing.expectEqual(@as(u64, 0), try bind.logLength());
    try std.testing.expectEqual(@as(usize, 7), bind.pending.names.count());
    try relief(bind);
    try expectPendingLoose(bind);
    try expectPack(bind, orphanId(), "orphan page");
    failure.fail = false;
    try rec.commit(2);
    try std.testing.expectEqual(@as(usize, 2), bind.pending.names.count());
    try relief(bind);
    const store = history.storage.Store.from(&bind.session);
    try expectLoose(bind, "prestage", "before records");
    try expectPack(bind, orphanId(), "orphan page");
    try expectPack(bind, pageId(), "pending page");
    var names = std.StringHashMap(void).init(gpa);
    defer {
        var keys = names.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        names.deinit();
    }
    try ra8.rpc.history_bind.prune_referrer.collectAll(store, gpa, &names);
    try std.testing.expectEqual(@as(usize, 5), names.count());
    var keys = names.keyIterator();
    var page_name: [32]u8 = undefined;
    pageId().formatHex(&page_name);
    while (keys.next()) |key| {
        if (std.mem.eql(u8, key.*, &page_name)) continue;
        const file = try store.vtable.open(store.context, .objects, key.*, .read);
        file.vtable.close(file.context);
    }
}

fn expectPendingLoose(bind: *Bind) !void {
    const store = history.storage.Store.from(&bind.session);
    var page_name: [32]u8 = undefined;
    var orphan_name: [32]u8 = undefined;
    pageId().formatHex(&page_name);
    orphanId().formatHex(&orphan_name);
    var keys = bind.pending.names.keyIterator();
    while (keys.next()) |key| {
        if (std.mem.eql(u8, key.*, &page_name) or std.mem.eql(u8, key.*, &orphan_name)) continue;
        const file = try store.vtable.open(store.context, .objects, key.*, .read);
        file.vtable.close(file.context);
    }
}

test "live relief protects pre-staging and failed-flush objects until durable commit" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    try exercise(bind);
}

const Capture = struct {
    bind: *Bind,
    cp: *ra8.session.history_checkpoint.Checkpoint = undefined,
    seen: bool = false,
    fail: bool = true,

    fn save(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(context));
        if (!self.seen) {
            try self.bind.objects.putPacked.?(self.bind.objects.context, pageId().bytes, "pending page");
            self.seen = true;
        }
        self.cp.manifest_record = try manifestBytes();
        try writer.writeAll("machine");
    }

    fn put(context: *anyopaque, kind: recorder.Objects.Kind, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(context));
        if (self.fail and std.mem.eql(u8, bytes, "machine")) return error.InjectedCheckpoint;
        try self.bind.objects.put(self.bind.objects.context, kind, name, bytes);
    }

    fn sync(context: *anyopaque) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.bind.objects.sync(self.bind.objects.context);
    }

    fn picture(_: *anyopaque, allocator: std.mem.Allocator, at: ra8.chip.core.scheduler.Position) anyerror!?ra8.session.history_checkpoint_picture.Decoded {
        return .{ .position = at, .virtual_ns = 1, .width = 1, .height = 1, .pixels = try allocator.dupe(u8, &.{1}) };
    }
};

test "failed checkpoint pages survive an unrelated commit and capture seen-ID reuse" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var rec = try recorder.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    var capture: Capture = .{ .bind = bind };
    rec.objects = .{ .context = &capture, .put = &Capture.put, .sync = &Capture.sync };
    var saved: ra8.chip.core.scheduler.State = .{ .at = .{ .r = 2 } };
    var cp: ra8.session.history_checkpoint.Checkpoint = .{
        .context = &capture,
        .saveFn = &Capture.save,
        .recorder = &rec,
        .saved = &saved,
        .next_id = 1,
        .picture = .{ .context = &capture, .lastScanFn = &Capture.picture },
    };
    capture.cp = &cp;
    // Picture sync seals the page, then the machine pin fails. stagePair
    // rolls back the picture record while the capture keeps its seen ID.
    try std.testing.expectError(error.InjectedCheckpoint, cp.checkpointNow());
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    try std.testing.expectEqual(@as(usize, 2), bind.pending.names.count());
    try rec.recordIntervention(.{ .position = .{ .r = 2 }, .seq = 0 }, .{ .what = .tap, .body = "event" });
    try rec.commit(1);
    try std.testing.expectEqual(@as(usize, 2), bind.pending.names.count());
    try relief(bind);
    try expectPack(bind, pageId(), "pending page");
    try expectPendingLoose(bind);
    capture.fail = false;
    try cp.checkpointNow();
    try std.testing.expectEqual(@as(usize, 0), bind.pending.names.count());
    try relief(bind);
    try expectPack(bind, pageId(), "pending page");
}

const BatchStore = struct {
    original: history.storage.Store,
    old_log_accesses: usize = 0,
    fail_top: bool = false,

    const vtable: history.storage.Store.Vtable = .{ .open = &open, .list = &list, .remove = undefined, .rename = undefined };

    fn store(self: *BatchStore) history.storage.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn open(context: *anyopaque, space: history.layout.Space, name: []const u8, mode: history.storage.Mode) anyerror!history.storage.ByteFile {
        const self: *BatchStore = @ptrCast(@alignCast(context));
        if (space == .log) {
            self.old_log_accesses += 1;
            return error.OldLogReadForbidden;
        }
        if (space == .top and self.fail_top) return error.InjectedRootRead;
        return self.original.vtable.open(self.original.context, space, name, mode);
    }

    fn list(context: *anyopaque, _: history.layout.Space, _: history.storage.Visitor) anyerror!void {
        const self: *BatchStore = @ptrCast(@alignCast(context));
        self.old_log_accesses += 1;
        return error.OldLogListForbidden;
    }
};

test "batch acknowledgment succeeds with all prior log reads and listing forbidden" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var old = try recorder.Recorder.init(gpa, bind.storage, .{});
    defer old.deinit();
    old.objects = bind.objects;
    old.observe(0);
    try old.checkpoint(.{ .position = .{ .r = 1 }, .seq = 0 }, 0, "old machine");
    try old.commit(1);
    _ = try bind.storage.switchSegment.?(bind.storage.context, 1, 0);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("old machine", &digest, .{});
    var old_name: [32]u8 = undefined;
    (ObjectId{ .bytes = digest[0..16].* }).formatHex(&old_name);
    try bind.objects.put(bind.objects.context, .data, &old_name, "old machine");
    var rec = try recorder.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(1);
    rec.objects = bind.objects;
    try bind.objects.putPacked.?(bind.objects.context, pageId().bytes, "pending page");
    try stage(&rec);
    try bind.storage.append(bind.storage.context, rec.staging.writer.buffered());
    // Exercise the same preparation helper with a store that refuses all old
    // log access, then flush through the actual Bind storage callback.
    var bounded: BatchStore = .{ .original = history.storage.Store.from(&bind.session) };
    bind.sink.prepared.clear();
    bounded.fail_top = true;
    try std.testing.expect(bind.sink.prepared.prepare(bounded.store(), rec.staging.writer.buffered()));
    try std.testing.expectEqual(@as(usize, 0), bind.sink.prepared.names.count());
    try bind.storage.flush(bind.storage.context);
    try std.testing.expectEqual(@as(usize, 6), bind.pending.names.count());
    bounded.fail_top = false;
    try std.testing.expect(bind.sink.prepared.prepare(bounded.store(), rec.staging.writer.buffered()));
    try std.testing.expectEqual(@as(usize, 5), bind.sink.prepared.names.count());
    try bind.storage.flush(bind.storage.context);
    try std.testing.expectEqual(@as(usize, 0), bounded.old_log_accesses);
    try std.testing.expectEqual(@as(usize, 1), bind.pending.names.count());
    try std.testing.expect(bind.pending.names.contains(&old_name));
    try relief(bind);
    try expectPack(bind, pageId(), "pending page");
}

test "torn raw prefix prevents acknowledgment of a following complete batch" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var rec = try recorder.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = bind.objects;
    try bind.objects.putPacked.?(bind.objects.context, pageId().bytes, "pending page");
    try stage(&rec);
    const held = bind.pending.names.count();
    try bind.storage.append(bind.storage.context, "x");
    try bind.storage.append(bind.storage.context, rec.staging.writer.buffered());
    try bind.storage.flush(bind.storage.context);
    try std.testing.expectEqual(held, bind.pending.names.count());
    try bind.storage.truncate(bind.storage.context, 0);
    try rec.commit(1);
    try std.testing.expectEqual(@as(usize, 0), bind.pending.names.count());
    try relief(bind);
    try expectPack(bind, pageId(), "pending page");
}

test "existing segment certification releases new references and rejects a corrupt target" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var rec = try recorder.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = bind.objects;
    try rec.recordIntervention(.{ .position = .{ .r = 1 }, .seq = 0 }, .{ .what = .tap, .body = "old" });
    try rec.commit(1);
    const old_length = try bind.logLength();
    const switch_segment = bind.storage.switchSegment.?;
    _ = try switch_segment(bind.storage.context, 1, 0);
    try std.testing.expectEqual(old_length, try switch_segment(bind.storage.context, 0, 0));
    try bind.objects.putPacked.?(bind.objects.context, pageId().bytes, "pending page");
    try stage(&rec);
    try std.testing.expectEqual(@as(usize, 5), bind.pending.names.count());
    try rec.commit(2);
    try std.testing.expectEqual(@as(usize, 0), bind.pending.names.count());
    try relief(bind);
    try expectPack(bind, pageId(), "pending page");
    // A whole header with an oversized payload must be rejected before any
    // large allocation, even after a valid nonempty prefix.
    const safe_length = try bind.logLength();
    try bind.storage.append(bind.storage.context, &.{ 255, 255, 255, 255, 0, 0, 0, 0, 0, 0 });
    try bind.storage.flush(bind.storage.context);
    _ = try switch_segment(bind.storage.context, 2, 0);
    try std.testing.expectEqual(safe_length + 10, try switch_segment(bind.storage.context, 0, 0));
    try bind.objects.putPacked.?(bind.objects.context, pageId().bytes, "pending page");
    try stage(&rec);
    try rec.commit(3);
    try std.testing.expectEqual(@as(usize, 5), bind.pending.names.count());
    try expectPack(bind, pageId(), "pending page");
    try bind.storage.truncate(bind.storage.context, safe_length);
}
