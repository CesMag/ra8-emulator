//! Covers src/session/history/checkpoint.zig: the policy fires on every
//! Nth closed round, the record's object holds the bound save stream and
//! is durable before its record, and arming refuses a second core.
const std = @import("std");
const ra8 = @import("ra8");
const checkpoint_mod = ra8.session.history_checkpoint;
const recorder_mod = ra8.session.history_recorder;
const format = ra8.session.history_format;
const record = ra8.session.history_record;
const scheduler = ra8.chip.core.scheduler;

const position: scheduler.Position = .{ .branch = 1, .r = 2, .phase = .cpu0, .o = 0, .gap = .retired };

/// The in-memory log storage a test fills: bytes land in one buffer and
/// every flush counts.
const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    flushes: usize = 0,

    fn append(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.gpa, data);
    }

    fn flush(context: *anyopaque) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.flushes += 1;
    }

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
    }

    fn storage(self: *Sink) recorder_mod.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }

    fn deinit(self: *Sink) void {
        self.bytes.deinit(self.gpa);
    }
};

/// The in-memory object space: names keep the bytes they were put with,
/// every sync counts.
const Objects = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Named) = .empty,
    syncs: usize = 0,

    const Named = struct { name: [32]u8, bytes: []u8 };

    fn put(context: *anyopaque, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *Objects = @ptrCast(@alignCast(context));
        var slot: Named = .{ .name = undefined, .bytes = try self.gpa.dupe(u8, bytes) };
        @memcpy(&slot.name, name);
        try self.items.append(self.gpa, slot);
    }

    fn sync(context: *anyopaque) anyerror!void {
        const self: *Objects = @ptrCast(@alignCast(context));
        self.syncs += 1;
    }

    fn objects(self: *Objects) recorder_mod.Objects {
        return .{ .context = self, .put = put, .sync = sync };
    }

    fn deinit(self: *Objects) void {
        for (self.items.items) |one| self.gpa.free(one.bytes);
        self.items.deinit(self.gpa);
    }
};

/// A fixed save stream, so tests know the object's bytes and hash.
fn saveFixed(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    _ = context;
    try writer.writeAll("ckpt");
}

fn controller(rec: *recorder_mod.Recorder, saved: *const scheduler.State, objects: *Objects, every: u32) checkpoint_mod.Checkpoint {
    return .{ .context = objects, .saveFn = saveFixed, .recorder = rec, .saved = saved, .every = every };
}

test "the policy checkpoints every Nth closed round" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = objects.objects();

    var saved: scheduler.State = .{};
    var cp = controller(&rec, &saved, &objects, 2);

    try cp.fire(1);
    try std.testing.expectEqual(@as(usize, 0), objects.syncs);
    try cp.fire(2);
    try std.testing.expectEqual(@as(u32, 1), cp.next_id);
    try std.testing.expectEqual(@as(usize, 1), objects.syncs);
    try std.testing.expect(sink.bytes.items.len > 0);
    try cp.fire(3);
    try std.testing.expectEqual(@as(u32, 1), cp.next_id);
    try cp.fire(4);
    try std.testing.expectEqual(@as(u32, 2), cp.next_id);
    cp.every = 0;
    try cp.fire(6);
    try std.testing.expectEqual(@as(u32, 2), cp.next_id);
}

test "a checkpoint's object holds the save stream and its record names it" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = objects.objects();

    var saved: scheduler.State = .{};
    saved.at = position;
    var cp = controller(&rec, &saved, &objects, 1);

    try cp.fire(2);
    try std.testing.expectEqual(@as(usize, 1), objects.syncs);
    try std.testing.expectEqual(@as(usize, 1), objects.items.items.len);
    try std.testing.expectEqualStrings("ckpt", objects.items.items[0].bytes);

    // The record committed with the object; decode it back out of the log.
    var hit: ?record.CheckpointRecord = null;
    var cursor: usize = 0;
    while (cursor < sink.bytes.items.len) {
        const frame = try format.decode(sink.bytes.items[cursor..]);
        if (frame.frame.kind == @backingInt(record.Kind.checkpoint)) {
            hit = try record.decodeCheckpoint(frame.frame.payload);
        }
        cursor += frame.consumed;
    }
    const found = hit orelse return error.MissingCheckpoint;
    try std.testing.expectEqual(position, found.header.position);
    try std.testing.expectEqual(@as(u32, 0), found.checkpoint.id);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("ckpt", &digest, .{});
    try std.testing.expectEqualSlices(u8, digest[0..16], &found.checkpoint.object);
}

test "arming refuses while a second core is attached" {
    var session: ra8.session.zig.session.ZigSession = .{
        .core = undefined,
        .machine = undefined,
        .budget = 1,
        .other = .{ .core = undefined, .machine = undefined },
    };
    var cp: checkpoint_mod.Checkpoint = undefined;
    try std.testing.expectError(error.SecondCore, session.armCheckpoints(&cp));
}

test "a projected total past the checkpoint cap thins the cadence" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = objects.objects();

    var saved: scheduler.State = .{};
    var cp = controller(&rec, &saved, &objects, 2);
    cp.object_cap = 5;

    // The first checkpoint lands; its 4-byte object fits the cap.
    try cp.fire(2);
    try std.testing.expectEqual(@as(u32, 1), cp.next_id);
    try std.testing.expectEqual(@as(u64, 4), cp.last_size);
    try std.testing.expectEqual(@as(usize, 1), objects.items.items.len);

    // The next hit's projection (4 + 4) is past the cap: the cadence
    // doubles and nothing lands.
    try cp.fire(4);
    try std.testing.expectEqual(@as(u32, 4), cp.every);
    try std.testing.expectEqual(@as(u32, 1), cp.next_id);
    try std.testing.expectEqual(@as(usize, 1), objects.items.items.len);

    // The next hit at the doubled cadence still projects over: it
    // doubles again.
    try cp.fire(8);
    try std.testing.expectEqual(@as(u32, 8), cp.every);
    try std.testing.expectEqual(@as(u32, 1), cp.next_id);
    try std.testing.expectEqual(@as(usize, 1), objects.items.items.len);
}

test "a checkpoint alone past the cap refuses the run" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = objects.objects();

    var saved: scheduler.State = .{};
    var cp = controller(&rec, &saved, &objects, 1);
    cp.object_cap = 3;

    // The first checkpoint lands at 4 bytes; the cap cannot take a
    // second one whatever cadence runs, so the next hit refuses.
    try cp.fire(1);
    try std.testing.expectEqual(@as(u64, 4), cp.last_size);
    try std.testing.expectError(error.HistoryFull, cp.fire(2));
    try std.testing.expectEqual(@as(u32, 1), cp.next_id);
    try std.testing.expectEqual(@as(usize, 1), objects.items.items.len);
}

test "a replayed or stopped history takes no checkpoint, object or count" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = objects.objects();
    var saved: scheduler.State = .{};
    var cp = controller(&rec, &saved, &objects, 2);
    try cp.fire(2);
    const bytes_before = sink.bytes.items.len;
    const object_bytes = rec.object_bytes;
    const history_bytes = rec.history_bytes;

    // A seek or a forward play over the recorded past passes the same rounds.
    rec.replaying = true;
    try cp.fire(4);
    try cp.fire(6);
    try rec.checkpoint(.{ .position = position, .seq = 0 }, 9, "ckpt");
    try rec.commit(1);
    try std.testing.expectEqual(@as(usize, 1), objects.items.items.len);
    try std.testing.expectEqual(@as(u32, 1), cp.next_id);
    try std.testing.expectEqual(object_bytes, rec.object_bytes);
    try std.testing.expectEqual(history_bytes, rec.history_bytes);
    try std.testing.expectEqual(bytes_before, sink.bytes.items.len);

    // Live again, the next round is checkpointed as before.
    rec.replaying = false;
    try cp.fire(8);
    try std.testing.expectEqual(@as(u32, 2), cp.next_id);

    rec.stopped = true;
    try cp.fire(10);
    try std.testing.expectEqual(@as(u32, 2), cp.next_id);
    try std.testing.expectEqual(@as(usize, 2), objects.items.items.len);
}

const FakeClock = struct {
    ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        return @as(*FakeClock, @ptrCast(@alignCast(context))).ns;
    }
};

test "caller clock groups complete checkpoints after durable CP0" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: Objects = .{ .gpa = gpa };
    defer objects.deinit();
    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    var clock = FakeClock{};
    // The same test compiles on the old production source for a red control.
    if (@hasField(recorder_mod.Recorder, "clock")) rec.clock = .{ .context = &clock, .nowFn = FakeClock.now };
    rec.observe(0);
    rec.objects = objects.objects();
    var saved: scheduler.State = .{};
    var cp = controller(&rec, &saved, &objects, 1);
    try cp.checkpointNow();
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    clock.ns = 249 * std.time.ns_per_ms;
    try cp.fire(1);
    try cp.fire(2);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expect(rec.pendingBytes() > 0);
    try std.testing.expectEqual(@as(usize, 3), objects.syncs);
    clock.ns = 250 * std.time.ns_per_ms;
    try cp.fire(3);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    const recovered = try logScan(sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 4), recovered);
}

fn logScan(bytes: []const u8) !usize {
    const Ignore = struct {
        fn visit(_: void, _: ra8.session.history_log.Boundary) void {}
    };
    return (try ra8.session.history_log.scan(bytes, {}, Ignore.visit)).frames;
}
