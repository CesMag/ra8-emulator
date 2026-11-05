//! Covers src/session/history/recorder.zig: boundary and intervention
//! frames reach the storage in order, a torn final tail recovers to the
//! last whole frame, group commit fires on both thresholds, and a
//! checkpoint's object is durable before its record is staged.
const std = @import("std");
const ra8 = @import("ra8");
const recorder_mod = ra8.session.history_recorder;
const format = ra8.session.history_format;
const log_mod = ra8.session.history_log;
const budget_mod = ra8.session.history_budget;
const record = ra8.session.history_record;
const scheduler = ra8.chip.core.scheduler;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn header(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

/// The in-memory storage a test fills: bytes land in one buffer, every
/// flush counts, and every truncation records the length it cut to.
const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    flushes: usize = 0,
    truncations: std.ArrayList(usize) = .empty,

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
        try self.truncations.append(self.gpa, @intCast(len));
    }

    fn storage(self: *Sink) recorder_mod.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }
};

test "boundary and intervention frames land in order and decode back" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.recordIntervention(header(2), .{ .what = .tap, .body = "xy" });
    try std.testing.expectEqual(@as(usize, 0), sink.flushes);
    try rec.commit(1);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());

    var kinds: [8]u16 = undefined;
    var seqs: [8]u32 = undefined;
    var index: usize = 0;
    var cursor: usize = 0;
    while (cursor < sink.bytes.items.len) {
        const hit = try format.decode(sink.bytes.items[cursor..]);
        const frame = hit.frame;
        const payload = frame.payload;
        switch (frame.kind) {
            @backingInt(record.Kind.boundary) => {
                const boundary = try record.decodeBoundary(payload);
                kinds[index] = frame.kind;
                seqs[index] = boundary.header.seq;
                try std.testing.expectEqualStrings("abc", boundary.boundary.body);
            },
            @backingInt(record.Kind.intervention) => {
                const intervention = try record.decodeIntervention(payload);
                kinds[index] = frame.kind;
                seqs[index] = intervention.header.seq;
                try std.testing.expectEqualStrings("xy", intervention.intervention.body);
            },
            else => return error.UnexpectedKind,
        }
        index += 1;
        cursor += hit.consumed;
    }
    try std.testing.expectEqual(@as(usize, 2), index);
    try std.testing.expectEqual(@backingInt(record.Kind.boundary), kinds[0]);
    try std.testing.expectEqual(@as(u32, 1), seqs[0]);
    try std.testing.expectEqual(@backingInt(record.Kind.intervention), kinds[1]);
    try std.testing.expectEqual(@as(u32, 2), seqs[1]);
}

test "a torn final tail recovers to the last whole frame" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    defer sink.truncations.deinit(gpa);

    // One whole frame, then half of a second one's header.
    var whole: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer whole.deinit();
    try format.encode(&whole.writer, @backingInt(record.Kind.boundary), "\x00\x01ab");
    try sink.bytes.appendSlice(gpa, whole.writer.buffered());
    try sink.bytes.appendSlice(gpa, &[_]u8{ 0x09, 0x00, 0x00, 0x00, 0x01 });

    const recovery = try recorder_mod.recoverSegment(sink.bytes.items, sink.storage());
    try std.testing.expect(recovery.torn);
    try std.testing.expectEqual(@as(usize, 1), sink.truncations.items.len);
    try std.testing.expectEqual(whole.writer.buffered().len, sink.bytes.items.len);
    const hit = try format.decode(sink.bytes.items);
    try std.testing.expectEqual(@backingInt(record.Kind.boundary), hit.frame.kind);
}

test "group commit fires on the byte threshold and on the clock" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    // A one-frame byte threshold commits on the frame's back.
    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{ .max_bytes = 16, .max_delay_ns = std.math.maxInt(u64) });
    defer rec.deinit();
    try rec.recordBoundary(header(1), .{ .what = .camera_change, .body = "x" });
    try std.testing.expect(rec.pendingBytes() > 0);
    try rec.maybeCommit(0);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);

    // A time threshold commits once the caller's clock crosses it.
    var timed = try recorder_mod.Recorder.init(gpa, sink.storage(), .{ .max_bytes = std.math.maxInt(usize), .max_delay_ns = 1_000 });
    defer timed.deinit();
    timed.observe(0);
    try timed.recordIntervention(header(1), .{ .what = .rpc_mutation, .body = "" });
    try timed.maybeCommit(500);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try timed.maybeCommit(1_100);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
}

test "the input landing adapter records an intervention at the grid position" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);

    var history = try ra8.session.history.History.init(gpa, undefined, 4);
    defer history.deinit();
    history.attachRecorder(&rec);

    const grid: scheduler.State = .{ .at = .{ .branch = 2, .r = 9, .phase = .board, .o = 0, .gap = .retired } };
    var landing = ra8.session.history.Landing{ .history = &history, .grid = &grid };
    const observer = landing.observer();
    observer.notify(observer.context, .{ .tap = .{ .x = 0x1234, .y = 0x5678 } }, 1_000);
    observer.notify(observer.context, .{ .button = .{ .down = true, .button_id = .sw2 } }, 2_000);
    try std.testing.expectEqual(@as(?anyerror, null), landing.failed);
    try rec.commit(1);

    // Two boundary frames in order: the tap's landing at the grid position
    // with the tap's own bytes, then the button's. A landing is an
    // observation; the intervention that scheduled it is what replay applies.
    var index: usize = 0;
    var cursor: usize = 0;
    var positions: [2]record.Position = undefined;
    var whats: [2]record.Boundary.What = undefined;
    var bodies: [2]?[]const u8 = .{ null, null };
    while (cursor < sink.bytes.items.len) {
        const hit = try format.decode(sink.bytes.items[cursor..]);
        try std.testing.expectEqual(@backingInt(record.Kind.boundary), hit.frame.kind);
        const landed = try record.decodeBoundary(hit.frame.payload);
        positions[index] = landed.header.position;
        whats[index] = landed.boundary.what;
        bodies[index] = landed.boundary.body;
        cursor += hit.consumed;
        index += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), index);
    try std.testing.expect(std.meta.eql(positions[0], grid.at));
    try std.testing.expectEqual(record.Boundary.What.tap_landed, whats[0]);
    try std.testing.expectEqualStrings(&.{ 1, 0x34, 0x12, 0x78, 0x56 }, bodies[0].?);
    try std.testing.expectEqual(record.Boundary.What.button_landed, whats[1]);
    try std.testing.expectEqualStrings(&.{ 4, 1, 1 }, bodies[1].?);
}

/// One harness over both spaces: the order list proves object-before-log.
const Both = struct {
    gpa: std.mem.Allocator,
    log_bytes: std.ArrayList(u8) = .empty,
    order: std.ArrayList(u8) = .empty,
    name: [32]u8 = undefined,
    object: std.ArrayList(u8) = .empty,
    syncs: usize = 0,

    fn append(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Both = @ptrCast(@alignCast(context));
        try self.order.append(self.gpa, 'l');
        try self.log_bytes.appendSlice(self.gpa, data);
    }

    fn flush(context: *anyopaque) anyerror!void {
        const self: *Both = @ptrCast(@alignCast(context));
        try self.order.append(self.gpa, 'f');
    }

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Both = @ptrCast(@alignCast(context));
        self.log_bytes.shrinkRetainingCapacity(@intCast(len));
    }

    fn put(context: *anyopaque, _: @import("ra8").session.history_recorder.Objects.Kind, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *Both = @ptrCast(@alignCast(context));
        try self.order.append(self.gpa, 'o');
        @memcpy(self.name[0..name.len], name);
        try self.object.appendSlice(self.gpa, bytes);
    }

    fn sync(context: *anyopaque) anyerror!void {
        const self: *Both = @ptrCast(@alignCast(context));
        self.syncs += 1;
        try self.order.append(self.gpa, 's');
    }

    fn storage(self: *Both) recorder_mod.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }

    fn objects(self: *Both) recorder_mod.Objects {
        return .{ .context = self, .put = put, .sync = sync };
    }
};

test "a checkpoint writes its object before any log byte and the record decodes back" {
    const gpa = std.testing.allocator;
    var both: Both = .{ .gpa = gpa };
    defer both.log_bytes.deinit(gpa);
    defer both.order.deinit(gpa);
    defer both.object.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, both.storage(), .{});
    defer rec.deinit();
    rec.objects = both.objects();
    rec.observe(0);
    try rec.checkpoint(header(1), 7, "machine bytes");
    try std.testing.expectEqualStrings("os", both.order.items);
    try std.testing.expectEqualStrings("machine bytes", both.object.items);
    try std.testing.expectEqual(@as(usize, 0), both.log_bytes.items.len);

    try rec.commit(1);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    var rest: []const u8 = both.log_bytes.items;
    var frames: usize = 0;
    while (rest.len > 0) {
        const hit = try format.decode(rest);
        if (hit.frame.kind == @backingInt(record.Kind.checkpoint)) {
            const got = try record.decodeCheckpoint(hit.frame.payload);
            try std.testing.expectEqual(@as(u32, 7), got.checkpoint.id);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash("machine bytes", &digest, .{});
            try std.testing.expectEqual(digest[0..16].*, got.checkpoint.object);
        }
        rest = rest[hit.consumed..];
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), frames);
}

test "a checkpoint refuses when no object space is attached" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    try std.testing.expectError(error.NoObjects, rec.checkpoint(header(1), 7, "x"));
}

/// The disk-side budget a test fills: a fixed free-space answer, every
/// read counted.
const Watch = struct {
    free_bytes: u64,
    reads: usize = 0,
    /// How many bytes each relief run adds to the free-space answer,
    /// and how many times the relief ran.
    relief_bytes: u64 = 0,
    reliefs: usize = 0,

    fn free(context: *anyopaque) anyerror!u64 {
        const self: *Watch = @ptrCast(@alignCast(context));
        self.reads += 1;
        return self.free_bytes;
    }

    fn budget(self: *Watch, cap: u64, floor: u64) recorder_mod.Budget {
        return .{ .context = self, .free = free, .cap = cap, .floor = floor };
    }

    /// The same budget with the test's relief attached: a refusal frees
    /// `relief_bytes` and re-checks once.
    fn reliefBudget(self: *Watch, cap: u64, floor: u64) recorder_mod.Budget {
        return .{ .context = self, .free = free, .cap = cap, .floor = floor, .relief = &relief };
    }

    fn relief(context: *anyopaque) anyerror!void {
        const self: *Watch = @ptrCast(@alignCast(context));
        self.reliefs += 1;
        self.free_bytes += self.relief_bytes;
    }
};

test "a commit the share cannot take refuses and keeps its bytes staged" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    var watch: Watch = .{ .free_bytes = 1_000_000 };

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.disk = watch.budget(1_000, 0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.commit(0);
    const first = rec.committed_bytes;
    try std.testing.expect(first > 0);

    // A share already exactly spent refuses the next commit, and the
    // refused bytes stay staged for a later retry.
    rec.disk = watch.budget(first, 0);
    try rec.recordBoundary(header(2), .{ .what = .camera_change, .body = "x" });
    try std.testing.expectError(error.HistoryFull, rec.commit(1));
    try std.testing.expect(rec.pendingBytes() > 0);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(@as(usize, 2), watch.reads);

    // With the share raised past the spent bytes into the warning band on
    // purpose (20% headroom over what the retry will spend), the same
    // bytes go out, and the pressure the commit leaves behind is the
    // warning band.
    const spent = first + rec.pendingBytes();
    rec.disk = watch.budget(spent + spent / 5, 0);
    try rec.commit(2);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
    try std.testing.expectEqual(budget_mod.Pressure.warning, rec.last_pressure);
}

test "a refused commit runs the application's relief and lands on the re-check" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    var watch: Watch = .{ .free_bytes = 1_000_000 };

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.disk = watch.budget(1_000, 0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.commit(0);
    const first = rec.committed_bytes;

    // The volume, not the share, is what refuses: the free-space read
    // holds almost nothing. The relief frees enough for the re-check,
    // so the same bytes go out without a second commit call.
    watch.free_bytes = 10;
    watch.relief_bytes = 10_000;
    rec.disk = watch.reliefBudget(1_000, 0);
    try rec.recordBoundary(header(2), .{ .what = .camera_change, .body = "def" });
    try rec.commit(1);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    try std.testing.expect(rec.committed_bytes > first);
    try std.testing.expectEqual(@as(usize, 1), watch.reliefs);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
}

test "a relief that frees nothing keeps the refusal" {
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    var watch: Watch = .{ .free_bytes = 10 };

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.disk = watch.reliefBudget(1_000, 0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try std.testing.expectError(error.HistoryFull, rec.commit(0));
    // The relief ran once and the re-check refused again, so the bytes
    // stay staged for a later retry.
    try std.testing.expectEqual(@as(usize, 1), watch.reliefs);
    try std.testing.expect(rec.pendingBytes() > 0);
    try std.testing.expectEqual(@as(usize, 2), watch.reads);
    try std.testing.expectEqual(@as(usize, 0), sink.flushes);
}
