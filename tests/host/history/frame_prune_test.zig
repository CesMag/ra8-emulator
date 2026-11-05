//! Covers src/host/history/prune.zig's relief pass: quota relief drops the
//! orphans and then the whole frame cache, and keeps every checkpoint
//! picture. The history is recorded for real (checkpoints with pictures
//! through the session's recorder into an in-memory store), the frame
//! cache spills real cold files into the frames space, and the relief
//! runs over the store the way the applications run it.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;
const refs = ra8.session.history_refs;
const recorder_mod = ra8.session.history_recorder;
const checkpoint_mod = ra8.session.history_checkpoint;
const pic = ra8.session.history_checkpoint_picture;
const cache_mod = ra8.session.history_frame_cache;
const types = ra8.session.history_frame_types;
const crop = ra8.session.history_frame_crop;
const scheduler = ra8.chip.core.scheduler;
const layout = history.layout;
const storage = history.storage;
const gpa = std.testing.allocator;

const w: u16 = 32;
const h: u16 = 16;

/// A store held in memory: one byte buffer per space and name.
const Mem = struct {
    files: std.StringHashMapUnmanaged(*std.ArrayList(u8)) = .empty,

    const Handle = struct { blob: *std.ArrayList(u8) };

    fn key(space: layout.Space, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ @tagName(space), name });
    }

    fn store(self: *Mem) storage.Store {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: storage.Store.Vtable = .{ .open = open, .remove = remove, .rename = rename, .list = list };
    const file_vtable: storage.ByteFile.Vtable = .{ .read = read, .write = write, .length = length, .truncate = truncate, .sync = sync, .close = close };

    fn open(context: *anyopaque, space: layout.Space, name: []const u8, mode: storage.Mode) anyerror!storage.ByteFile {
        const self: *Mem = @ptrCast(@alignCast(context));
        const k = try key(space, name);
        errdefer gpa.free(k);
        var blob: *std.ArrayList(u8) = undefined;
        if (self.files.getPtr(k)) |found| {
            if (mode == .create) return error.PathAlreadyExists;
            blob = found.*;
            gpa.free(k);
        } else {
            if (mode != .create) return error.FileNotFound;
            blob = try gpa.create(std.ArrayList(u8));
            blob.* = .empty;
            try self.files.put(gpa, k, blob);
        }
        const handle = try gpa.create(Handle);
        handle.* = .{ .blob = blob };
        return .{ .context = handle, .vtable = &file_vtable };
    }

    fn remove(context: *anyopaque, space: layout.Space, name: []const u8) anyerror!void {
        const self: *Mem = @ptrCast(@alignCast(context));
        const k = try key(space, name);
        defer gpa.free(k);
        const gone = self.files.fetchRemove(k) orelse return error.FileNotFound;
        gpa.free(gone.key);
        gone.value.deinit(gpa);
        gpa.destroy(gone.value);
    }

    fn rename(context: *anyopaque, space: layout.Space, from: []const u8, to: []const u8) anyerror!void {
        _ = context;
        _ = space;
        _ = from;
        _ = to;
        return error.Unsupported;
    }

    fn list(context: *anyopaque, space: layout.Space, visitor: storage.Visitor) anyerror!void {
        const self: *Mem = @ptrCast(@alignCast(context));
        // Collect first: the visitor removes entries.
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = self.files.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const slash = std.mem.indexOfScalar(u8, k, '/').?;
            if (!std.mem.eql(u8, k[0..slash], @tagName(space))) continue;
            try names.append(gpa, try gpa.dupe(u8, k[slash + 1 ..]));
        }
        for (names.items) |n| {
            const k = try key(space, n);
            defer gpa.free(k);
            try visitor.visit(visitor.context, n, self.files.get(k).?.items.len);
        }
    }

    fn handleOf(context: *anyopaque) *Handle {
        return @ptrCast(@alignCast(context));
    }

    fn read(context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
        const items = handleOf(context).blob.items;
        const start: usize = @intCast(offset);
        if (start >= items.len) return 0;
        const n = @min(buffer.len, items.len - start);
        @memcpy(buffer[0..n], items[start..][0..n]);
        return n;
    }

    fn write(context: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const blob = handleOf(context).blob;
        const end: usize = @intCast(offset + bytes.len);
        if (blob.items.len < end) try blob.resize(gpa, end);
        @memcpy(blob.items[@intCast(offset)..][0..bytes.len], bytes);
    }

    fn length(context: *anyopaque) anyerror!u64 {
        return handleOf(context).blob.items.len;
    }

    fn truncate(context: *anyopaque, size: u64) anyerror!void {
        handleOf(context).blob.shrinkRetainingCapacity(@intCast(size));
    }

    fn sync(context: *anyopaque) anyerror!void {
        _ = context;
    }

    fn close(context: *anyopaque) void {
        gpa.destroy(handleOf(context));
    }

    fn count(self: *Mem, space: layout.Space) usize {
        var n: usize = 0;
        var it = self.files.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, @tagName(space)) and k.*[@tagName(space).len] == '/') n += 1;
        }
        return n;
    }

    fn has(self: *Mem, space: layout.Space, name: []const u8) bool {
        const k = key(space, name) catch return false;
        defer gpa.free(k);
        return self.files.contains(k);
    }

    fn deinit(self: *Mem) void {
        var it = self.files.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(gpa);
            gpa.destroy(kv.value_ptr.*);
        }
        self.files.deinit(gpa);
    }
};

/// The recorder's storages over the in-memory store: the log segment and
/// the object space, the way history_bind fills them.
const Wire = struct {
    mem: *Mem,

    fn append(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Wire = @ptrCast(@alignCast(context));
        const st = self.mem.store();
        const file = st.vtable.open(st.context, .log, "events-0", .update) catch |err| switch (err) {
            error.FileNotFound => try st.vtable.open(st.context, .log, "events-0", .create),
            else => return err,
        };
        defer file.vtable.close(file.context);
        try file.vtable.write(file.context, try file.vtable.length(file.context), bytes);
    }
    fn flush(context: *anyopaque) anyerror!void {
        _ = context;
    }
    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        _ = context;
        _ = len;
    }
    fn put(context: *anyopaque, _: @import("ra8").session.history_recorder.Objects.Kind, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *Wire = @ptrCast(@alignCast(context));
        const st = self.mem.store();
        const file = st.vtable.open(st.context, .objects, name, .create) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
        defer file.vtable.close(file.context);
        try file.vtable.write(file.context, 0, bytes);
    }
    fn sync(context: *anyopaque) anyerror!void {
        _ = context;
    }
};

/// The referrer the applications wire: walk every log segment with the
/// session's refs, once for all objects and once for pictures only.
fn gather(comptime pictures_only: bool) *const history.prune.Collect {
    return &struct {
        fn collect(st: storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void {
            const file = try st.vtable.open(st.context, .log, "events-0", .read);
            defer file.vtable.close(file.context);
            const bytes = try allocator.alloc(u8, @intCast(try file.vtable.length(file.context)));
            defer allocator.free(bytes);
            _ = try file.vtable.read(file.context, 0, bytes);
            const Add = struct {
                allocator: std.mem.Allocator,
                names: *std.StringHashMap(void),
                failed: ?anyerror = null,
                fn add(self: *@This(), name: refs.Name) void {
                    const dup = self.allocator.dupe(u8, &name) catch {
                        self.failed = error.OutOfMemory;
                        return;
                    };
                    const hit = self.names.getOrPut(dup) catch {
                        self.allocator.free(dup);
                        self.failed = error.OutOfMemory;
                        return;
                    };
                    if (hit.found_existing) self.allocator.free(dup);
                }
            };
            var add: Add = .{ .allocator = allocator, .names = names };
            if (pictures_only) try refs.scanPictureObjects(bytes, &add, Add.add) else try refs.scanCheckpointObjects(bytes, &add, Add.add);
            if (add.failed) |err| return err;
        }
    }.collect;
}

fn gradient(seed: u8) [@as(usize, w) * h]u8 {
    var out: [@as(usize, w) * h]u8 = undefined;
    for (&out, 0..) |*p, i| p.* = seed +% @as(u8, @truncate(i * 3));
    return out;
}

const Scan = struct {
    fn last(context: *anyopaque, allocator: std.mem.Allocator, at: pic.Position) anyerror!?pic.Decoded {
        _ = context;
        const px = gradient(@truncate(at.r));
        return .{ .position = at, .virtual_ns = at.r, .width = w, .height = h, .pixels = try allocator.dupe(u8, &px) };
    }
};

fn saveRound(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    _ = context;
    try writer.writeAll("machine");
}

/// A cold file backing for the frame cache, over the store's frames space.
fn coldCreate(context: *anyopaque, name: []const u8) anyerror!cache_mod.File {
    const mem: *Mem = @ptrCast(@alignCast(context));
    const st = mem.store();
    const file = try st.vtable.open(st.context, .frames, name, .create);
    return .{ .context = file.context, .vtable = &cold_vtable };
}

const cold_vtable: cache_mod.File.Vtable = .{ .read = Mem.read, .write = Mem.write, .close = Mem.close };

/// Records `n` checkpoints, each with its picture.
fn record(mem: *Mem, n: u64) !void {
    var wire: Wire = .{ .mem = mem };
    var rec = try recorder_mod.Recorder.init(gpa, .{ .context = &wire, .append = Wire.append, .flush = Wire.flush, .truncate = Wire.truncate }, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = .{ .context = &wire, .put = Wire.put, .sync = Wire.sync };
    var saved: scheduler.State = .{};
    var scan_ctx: u8 = 0;
    var cp: checkpoint_mod.Checkpoint = .{
        .context = &scan_ctx,
        .saveFn = saveRound,
        .recorder = &rec,
        .saved = &saved,
        .every = 1,
        .picture = .{ .context = &scan_ctx, .lastScanFn = Scan.last },
    };
    var r: u64 = 1;
    while (r <= n) : (r += 1) {
        saved.at = .{ .r = r };
        try cp.fire(r);
    }
}

fn spillFrames(mem: *Mem) !void {
    var cache = cache_mod.FrameCache.init(gpa, std.testing.io, .{ .ram_bytes = 0, .disk_bytes = 1 << 20 }, .{ .context = mem, .createFn = coldCreate });
    defer cache.deinit();
    const key = gradient(1);
    for (1..4) |i| {
        const payload = try crop.compress(gpa, &key);
        var rec: types.FrameRecord = .{ .header = .{
            .kind = .keyframe,
            .position = .{ .r = i },
            .virtual_ns = i,
            .width = w,
            .height = h,
            .rect = .{ .x = 0, .y = 0, .width = w, .height = h },
            .uncompressed_len = key.len,
            .compressed_len = @intCast(payload.len),
            .crc32c = types.FrameHeader.computeCrc(payload),
        }, .payload = payload };
        defer rec.deinit(gpa);
        try cache.put(&rec);
    }
}

test "relief drops the frame cache and keeps every checkpoint picture" {
    var mem: Mem = .{};
    defer mem.deinit();
    try record(&mem, 5);
    // Five identical machine objects share one file; five pictures differ.
    try std.testing.expectEqual(@as(usize, 6), mem.count(.objects));

    // An orphan object and the cold frame files the cache spilled.
    {
        const st = mem.store();
        const file = try st.vtable.open(st.context, .objects, "ffffffffffffffffffffffffffffffff", .create);
        defer file.vtable.close(file.context);
        try file.vtable.write(file.context, 0, "stray");
    }
    try spillFrames(&mem);
    try std.testing.expectEqual(@as(usize, 3), mem.count(.frames));

    const report = try history.prune.relief(mem.store(), gpa, .{ .collect = gather(false), .pictures = gather(true) });
    try std.testing.expectEqual(@as(usize, 1), report.orphans);
    try std.testing.expectEqual(@as(usize, 3), report.frames);
    try std.testing.expect(report.frame_bytes > 0);
    try std.testing.expectEqual(@as(usize, 5), report.pictures_kept);
    try std.testing.expectEqual(@as(usize, 0), report.pictures_missing);
    try std.testing.expect(report.intact());
    try std.testing.expectEqual(@as(usize, 0), mem.count(.frames));
    // The machine object and all five pictures are all still there.
    try std.testing.expectEqual(@as(usize, 6), mem.count(.objects));
    try std.testing.expect(!mem.has(.objects, "ffffffffffffffffffffffffffffffff"));
}

test "a referrer that misses the pictures still cannot lose them" {
    var mem: Mem = .{};
    defer mem.deinit();
    try record(&mem, 3);

    // The broad collector sees only the machine objects; the picture
    // collector alone names the pictures.
    const machines_only = struct {
        fn collect(st: storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void {
            _ = st;
            _ = allocator;
            _ = names;
        }
    }.collect;
    const report = try history.prune.relief(mem.store(), gpa, .{ .collect = &machines_only, .pictures = gather(true) });
    try std.testing.expectEqual(@as(usize, 3), report.pictures_kept);
    // Only the machine object (named by neither collector here) went.
    try std.testing.expectEqual(@as(usize, 1), report.orphans);
    try std.testing.expectEqual(@as(usize, 3), mem.count(.objects));
}

test "a picture the log names but the space lost is reported missing" {
    var mem: Mem = .{};
    defer mem.deinit();
    try record(&mem, 2);

    var names = std.StringHashMap(void).init(gpa);
    defer {
        var it = names.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        names.deinit();
    }
    try gather(true)(mem.store(), gpa, &names);
    try std.testing.expectEqual(@as(u32, 2), names.count());
    var it = names.keyIterator();
    const victim = it.next().?.*;
    try mem.store().vtable.remove(mem.store().context, .objects, victim);

    const report = try history.prune.relief(mem.store(), gpa, .{ .collect = gather(false), .pictures = gather(true) });
    try std.testing.expectEqual(@as(usize, 1), report.pictures_kept);
    try std.testing.expectEqual(@as(usize, 1), report.pictures_missing);
    try std.testing.expect(!report.intact());
}

test "relief without a pictures collector is the old orphans-then-frames pass" {
    var mem: Mem = .{};
    defer mem.deinit();
    try record(&mem, 2);
    try spillFrames(&mem);
    const report = try history.prune.relief(mem.store(), gpa, .{ .collect = gather(false) });
    try std.testing.expectEqual(@as(usize, 0), report.orphans);
    try std.testing.expectEqual(@as(usize, 3), report.frames);
    try std.testing.expectEqual(@as(usize, 0), report.pictures_kept);
    try std.testing.expectEqual(@as(usize, 3), mem.count(.objects));
}
