//! Covers src/session/history/checkpoint_picture.zig: the picture blob
//! round trip bit-exact at full panel size, the corruption refusals, the
//! capture ordering (picture before its checkpoint, both committed), the
//! index lookup of the newest picture at or before a position, the
//! display-off answer, and that the log walk names every picture object so
//! the orphan sweep keeps it.
const std = @import("std");
const ra8 = @import("ra8");
const pic = ra8.session.history_checkpoint_picture;
const checkpoint_mod = ra8.session.history_checkpoint;
const recorder_mod = ra8.session.history_recorder;
const refs = ra8.session.history_refs;
const replay_mod = ra8.session.history_replay;
const record = ra8.session.history_record;
const scheduler = ra8.chip.core.scheduler;
const cache_mod = ra8.session.history_frame_cache;
const fx = @import("frame_fixture.zig");

const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn append(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.gpa, data);
    }
    fn flush(context: *anyopaque) anyerror!void {
        _ = context;
    }
    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
    }
    fn storage(self: *Sink) recorder_mod.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }
};

/// Objects keyed by name, also the picture Reader.
const Objects = struct {
    gpa: std.mem.Allocator,
    items: std.StringHashMapUnmanaged([]u8) = .empty,
    puts: usize = 0,
    /// Failure injection: the put with this 1-based number fails.
    fail_put: ?usize = null,

    fn put(context: *anyopaque, _: @import("ra8").session.history_recorder.Objects.Kind, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *Objects = @ptrCast(@alignCast(context));
        self.puts += 1;
        if (self.fail_put == self.puts) return error.NoSpaceLeft;
        const key = try self.gpa.dupe(u8, name);
        const value = try self.gpa.dupe(u8, bytes);
        const slot = try self.items.getOrPut(self.gpa, key);
        if (slot.found_existing) {
            self.gpa.free(key);
            self.gpa.free(slot.value_ptr.*);
        }
        slot.value_ptr.* = value;
    }
    fn sync(context: *anyopaque) anyerror!void {
        _ = context;
    }
    fn get(context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]u8 {
        const self: *Objects = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.items.get(name) orelse return error.FileNotFound);
    }
    fn objects(self: *Objects) recorder_mod.Objects {
        return .{ .context = self, .put = put, .sync = sync };
    }
    fn reader(self: *Objects) pic.Reader {
        return .{ .context = self, .getFn = get };
    }
    fn deinit(self: *Objects) void {
        var it = self.items.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.free(kv.value_ptr.*);
        }
        self.items.deinit(self.gpa);
    }
};

const w: u16 = 64;
const h: u16 = 32;

fn gradient(allocator: std.mem.Allocator, width: u16, height: u16, seed: u8) ![]u8 {
    const px = try allocator.alloc(u8, @as(usize, width) * height);
    for (px, 0..) |*p, i| p.* = @truncate((i * 7 + seed) ^ (i >> 5));
    return px;
}

/// A source whose scan is a gradient seeded by the checkpoint's round,
/// stamped one round before the checkpoint it serves; null while `off`.
const Scan = struct {
    off: bool = false,
    calls: usize = 0,

    fn last(context: *anyopaque, allocator: std.mem.Allocator, at: pic.Position) anyerror!?pic.Decoded {
        const self: *Scan = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.off) return null;
        var where = at;
        where.r -= 1;
        return .{ .position = where, .virtual_ns = where.r * 1000, .width = w, .height = h, .pixels = try gradient(allocator, w, h, @truncate(at.r)) };
    }
    fn source(self: *Scan) pic.Source {
        return .{ .context = self, .lastScanFn = last };
    }
};

fn saveFixed(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    _ = context;
    try writer.writeAll("ckpt");
}

/// One recorder over fakes, with a checkpoint policy storing pictures.
const Rig = struct {
    sink: Sink,
    objects: Objects,
    rec: recorder_mod.Recorder,
    scan: Scan,
    saved: scheduler.State = .{},
    cp: checkpoint_mod.Checkpoint = undefined,

    fn start(self: *Rig, gpa: std.mem.Allocator, off: bool) !void {
        self.sink = .{ .gpa = gpa };
        self.objects = .{ .gpa = gpa };
        self.scan = .{ .off = off };
        self.rec = try recorder_mod.Recorder.init(gpa, self.sink.storage(), .{});
        self.rec.observe(0);
        self.rec.objects = self.objects.objects();
        self.cp = .{ .context = &self.objects, .saveFn = saveFixed, .recorder = &self.rec, .saved = &self.saved, .every = 1, .picture = self.scan.source() };
    }

    fn fire(self: *Rig, round: u64) !void {
        self.saved.at = .{ .r = round };
        try self.cp.fire(round);
    }

    fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
        self.rec.deinit();
        self.objects.deinit();
        self.sink.bytes.deinit(gpa);
    }
};

test "a full panel picture round trips bit-exact and compresses" {
    const gpa = std.testing.allocator;
    const px = try gradient(gpa, 1024, 600, 3);
    defer gpa.free(px);
    const at: pic.Position = .{ .branch = 2, .r = 9, .phase = .cpu1, .o = 4, .gap = .polled };
    const blob = try pic.encode(gpa, .{ .position = at, .virtual_ns = 777, .width = 1024, .height = 600, .pixels = px });
    defer gpa.free(blob);
    try std.testing.expect(blob.len < px.len);
    var back = try pic.decode(gpa, blob);
    defer back.deinit(gpa);
    try std.testing.expectEqualSlices(u8, px, back.pixels);
    try std.testing.expectEqual(at, back.position);
    try std.testing.expectEqual(@as(u64, 777), back.virtual_ns);
}

test "a corrupt picture blob is refused, never decoded wrong" {
    const gpa = std.testing.allocator;
    const px = try gradient(gpa, w, h, 1);
    defer gpa.free(px);
    const blob = try pic.encode(gpa, .{ .position = .{}, .virtual_ns = 0, .width = w, .height = h, .pixels = px });
    defer gpa.free(blob);

    const flipped = try gpa.dupe(u8, blob);
    defer gpa.free(flipped);
    flipped[flipped.len - 1] ^= 0xff;
    try std.testing.expectError(error.BadCrc, pic.decode(gpa, flipped));
    try std.testing.expectError(error.Truncated, pic.decode(gpa, blob[0 .. blob.len - 3]));
    try std.testing.expectError(error.Truncated, pic.decode(gpa, blob[0..10]));
    try std.testing.expectError(error.BadPixelCount, pic.encode(gpa, .{ .position = .{}, .virtual_ns = 0, .width = w, .height = h, .pixels = px[1..] }));

    const delta = try gpa.dupe(u8, blob);
    defer gpa.free(delta);
    delta[6] = 2;
    try std.testing.expectError(error.NotAKeyframe, pic.decode(gpa, delta));
}

test "every checkpoint pins its picture ahead of its own record" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa, false);
    defer rig.deinit(gpa);

    for ([_]u64{ 3, 5, 8 }) |round| try rig.fire(round);
    try std.testing.expectEqual(@as(usize, 3), rig.scan.calls);
    // Three pictures differ; the machine bytes are one shared object, put thrice.
    try std.testing.expectEqual(@as(usize, 6), rig.objects.puts);

    const Order = struct {
        kinds: [8]u8 = undefined,
        n: usize = 0,
        fn visit(self: *@This(), entry: replay_mod.Entry) anyerror!void {
            self.kinds[self.n] = switch (entry) {
                .checkpoint_picture => 'p',
                .checkpoint => 'c',
                else => '?',
            };
            self.n += 1;
        }
    };
    var order: Order = .{};
    _ = try replay_mod.replay(rig.sink.bytes.items, &order, Order.visit);
    try std.testing.expectEqualStrings("pcpcpc", order.kinds[0..order.n]);
}

test "the index answers the newest picture at or before a position" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa, false);
    defer rig.deinit(gpa);
    for ([_]u64{ 4, 8, 12 }) |round| try rig.fire(round);

    var index = pic.Index.init(gpa);
    defer index.deinit();
    try index.addFromLog(rig.sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 3), index.entries.items.len);

    try std.testing.expectEqual(@as(?pic.Entry, null), index.newestAtOrBefore(.{ .r = 3 }));
    try std.testing.expectEqual(@as(u32, 0), index.newestAtOrBefore(.{ .r = 4 }).?.id);
    try std.testing.expectEqual(@as(u32, 0), index.newestAtOrBefore(.{ .r = 7, .phase = .board, .o = 1 }).?.id);
    try std.testing.expectEqual(@as(u32, 1), index.newestAtOrBefore(.{ .r = 8 }).?.id);
    try std.testing.expectEqual(@as(u32, 2), index.newestAtOrBefore(.{ .r = 900 }).?.id);
    // Another line is incomparable: no answer, not a guess.
    try std.testing.expectEqual(@as(?pic.Entry, null), index.newestAtOrBefore(.{ .branch = 1, .r = 900 }));

    // The picture loads back bit-exact from the object space.
    const hit = index.newestAtOrBefore(.{ .r = 9 }).?;
    var loaded = try index.load(rig.objects.reader(), hit);
    defer loaded.deinit(gpa);
    const want = try gradient(gpa, w, h, 8);
    defer gpa.free(want);
    try std.testing.expectEqualSlices(u8, want, loaded.pixels);
    try std.testing.expectEqual(@as(u64, 7), loaded.position.r);
}

test "a display that never came up stores no picture" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa, true);
    defer rig.deinit(gpa);
    try rig.fire(2);
    try std.testing.expectEqual(@as(usize, 1), rig.objects.puts);
    var index = pic.Index.init(gpa);
    defer index.deinit();
    try index.addFromLog(rig.sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), index.entries.items.len);
    try std.testing.expectEqual(@as(?pic.Entry, null), index.newestAtOrBefore(.{ .r = 99 }));
}

test "the log walk names every picture object for the orphan sweep" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa, false);
    defer rig.deinit(gpa);
    try rig.fire(2);

    const Names = struct {
        count: usize = 0,
        fn visit(self: *@This(), name: refs.Name) void {
            _ = name;
            self.count += 1;
        }
    };
    var all: Names = .{};
    try refs.scanCheckpointObjects(rig.sink.bytes.items, &all, Names.visit);
    var pictures: Names = .{};
    try refs.scanPictureObjects(rig.sink.bytes.items, &pictures, Names.visit);
    // The machine with its touched pages and manifest, plus the picture,
    // are all committed objects; one of them a picture.
    try std.testing.expectEqual(@as(usize, 4), all.count);
    try std.testing.expectEqual(@as(usize, 1), pictures.count);
    try std.testing.expect(record.known(@backingInt(record.Kind.checkpoint_picture)));
}

/// A picture source over the frame cache's newest frame at or before a
/// checkpoint, standing in for the panel scan the harness binds.
fn cacheScan(context: *anyopaque, allocator: std.mem.Allocator, at: pic.Position) anyerror!?pic.Decoded {
    const cache: *cache_mod.FrameCache = @ptrCast(@alignCast(context));
    switch (try cache.lookup(allocator, at)) {
        .frame => |shown| return .{ .position = shown.position, .virtual_ns = shown.virtual_ns, .width = shown.width, .height = shown.height, .pixels = shown.pixels },
        else => return null,
    }
}

test "relief empties the frame cache and every checkpoint picture still loads" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa, false);
    defer rig.deinit(gpa);

    // The cache holds a keyframe at round 1 and a delta at round 3; the
    // checkpoints at rounds 2 and 4 pin whatever the cache shows then.
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 1 << 20 }, null);
    defer cache.deinit();
    const key = fx.picture(10, 0);
    const later = fx.picture(10, 77);
    try fx.put(&cache, gpa, try fx.keyRecord(gpa, fx.at(0, 1), &key));
    try fx.put(&cache, gpa, try fx.deltaRecord(gpa, fx.at(0, 3), &key, &later));
    rig.cp.picture = .{ .context = &cache, .lastScanFn = cacheScan };
    try rig.fire(2);
    try rig.fire(4);

    const dropped = cache.relieve();
    try std.testing.expectEqual(@as(usize, 2), dropped.frames);
    try std.testing.expectEqual(@as(usize, 0), cache.count());

    var index = pic.Index.init(gpa);
    defer index.deinit();
    try index.addFromLog(rig.sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), index.entries.items.len);
    var first = try index.load(rig.objects.reader(), index.newestAtOrBefore(.{ .r = 2 }).?);
    defer first.deinit(gpa);
    var second = try index.load(rig.objects.reader(), index.newestAtOrBefore(.{ .r = 4 }).?);
    defer second.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &key, first.pixels);
    try std.testing.expectEqualSlices(u8, &later, second.pixels);
    try std.testing.expectEqual(@as(u64, 1), first.position.r);
    try std.testing.expectEqual(@as(u64, 3), second.position.r);
}

test "a checkpoint that fails takes its staged picture with it" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    try rig.start(gpa, false);
    defer rig.deinit(gpa);
    // Put 1 is the picture, put 2 the machine object: the second fails.
    rig.objects.fail_put = 2;
    try std.testing.expectError(error.NoSpaceLeft, rig.fire(2));
    try std.testing.expectEqual(@as(usize, 0), rig.rec.pendingBytes());
    try std.testing.expectEqual(@as(u64, 0), rig.rec.object_bytes);
    try std.testing.expectEqual(@as(u32, 0), rig.cp.next_id);
    // The retry lands the pair under the same id, once.
    rig.objects.fail_put = null;
    try rig.fire(2);
    var index = pic.Index.init(gpa);
    defer index.deinit();
    try index.addFromLog(rig.sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), index.entries.items.len);
}

test "re-adding a checkpoint id at another position keeps the index ordered" {
    const gpa = std.testing.allocator;
    var index = pic.Index.init(gpa);
    defer index.deinit();
    const object: [16]u8 = @splat(1);
    try index.add(.{ .id = 1, .at = .{ .r = 10 }, .object = object });
    try index.add(.{ .id = 2, .at = .{ .r = 20 }, .object = object });
    try index.add(.{ .id = 1, .at = .{ .r = 30 }, .object = object });
    try std.testing.expectEqual(@as(usize, 2), index.entries.items.len);
    try std.testing.expectEqual(@as(u32, 2), index.entries.items[0].id);
    try std.testing.expectEqual(@as(u32, 1), index.entries.items[1].id);
    try std.testing.expectEqual(@as(u32, 2), index.newestAtOrBefore(.{ .r = 25 }).?.id);
    try std.testing.expectEqual(@as(u32, 1), index.newestAtOrBefore(.{ .r = 30 }).?.id);
}
