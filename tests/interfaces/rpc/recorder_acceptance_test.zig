//! The slice's acceptance scenarios on the real host store behind the
//! RPC bind: a crash's torn tail recovers to the last whole frame, a
//! whole frame that fails its CRC refuses the reopen, a closed session
//! leaves the root's catalog with nothing of it left, a commit the
//! volume cannot take refuses and stays staged until the relief lands
//! it, and an unmeasured history runs with no budget at all.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;
const recorder_mod = ra8.session.history_recorder;
const record = ra8.session.history_record;
const format = ra8.session.history_format;
const scheduler = ra8.chip.core.scheduler;

const bind_mod = ra8.rpc.history_bind;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn header(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

/// The storage a reopen drive hands recoverSegment: it only ever
/// records the shortening the recovery asks for.
const Trim = struct {
    cuts: std.ArrayList(u64) = .empty,

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Trim = @ptrCast(@alignCast(context));
        try self.cuts.append(std.testing.allocator, len);
    }

    fn storage(self: *Trim) recorder_mod.Storage {
        return .{ .context = self, .append = undefined, .flush = undefined, .truncate = truncate };
    }
};

/// The controllable free-space source the budget scenarios drive: the
/// volume holds whatever the test sets, and the relief it supplies
/// counts its runs and reclaims the bytes the test names.
const Volume = struct {
    free_now: u64 = 0,
    reclaim: u64 = 0,
    reliefs: usize = 0,

    fn free(context: *anyopaque) anyerror!u64 {
        const self: *Volume = @ptrCast(@alignCast(context));
        return self.free_now;
    }

    fn relieve(context: *anyopaque) anyerror!void {
        const self: *Volume = @ptrCast(@alignCast(context));
        self.reliefs += 1;
        self.free_now += self.reclaim;
    }

    fn budget(self: *Volume) recorder_mod.Budget {
        return .{
            .context = self,
            .free = free,
            .cap = 1024 * 1024,
            .floor = 512 * 1024,
            .relief = relieve,
        };
    }
};

fn segmentLength(store: anytype) !u64 {
    const log = try store.vtable.open(store.context, .log, "events-0", .read);
    defer log.vtable.close(log.context);
    return try log.vtable.length(log.context);
}

test "acceptance: a torn tail recovers to the last whole frame on the real store" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer {
        rec.deinit();
        _ = bind.close() catch {};
    }
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.recordIntervention(header(2), .{ .what = .tap, .body = "xy" });
    try rec.commit(1);
    try rec.recordBoundary(header(3), .{ .what = .c6_bytes, .body = "tail" });
    try rec.commit(2);

    const store = history.storage.Store.from(&bind.session);
    const log = try store.vtable.open(store.context, .log, "events-0", .read);
    const len = try log.vtable.length(log.context);
    const bytes = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(bytes);
    _ = try log.vtable.read(log.context, 0, bytes);
    log.vtable.close(log.context);
    try std.testing.expect(len > 3);

    // A crash that landed part of the third frame: the reopen keeps
    // the two whole frames and cuts the torn tail at the torn
    // frame's start, which the decode walk places.
    var cursor: usize = 0;
    var ends: [2]u64 = undefined;
    for (&ends) |*end| {
        const hit = try format.decode(bytes[cursor..]);
        cursor += hit.consumed;
        end.* = cursor;
    }
    var trim: Trim = .{};
    defer trim.cuts.deinit(gpa);
    const recovery = try recorder_mod.recoverSegment(bytes[0 .. len - 3], trim.storage());
    try std.testing.expect(recovery.torn);
    try std.testing.expectEqual(@as(usize, 2), recovery.frames);
    try std.testing.expectEqual(ends[1], recovery.complete_end);
    try std.testing.expectEqual(@as(usize, 1), trim.cuts.items.len);
    try std.testing.expectEqual(ends[1], trim.cuts.items[0]);
}

test "acceptance: a reopened history cuts a torn tail before it appends" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var id: history.name.Id = undefined;
    var whole: u64 = 0;
    {
        // Reopen admission requires a real frozen root and its initial media.
        var opened: ra8.rpc.served_setup.Served = undefined;
        try opened.open(gpa, std.testing.io, "tests/fixtures/gpio/blink.elf", @import("regression_rig.zig").small_profile, .{ .root = root, .kept = true });
        defer opened.deinit();
        const bind = opened.history.?;
        id = bind.session.id;
        var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
        defer rec.deinit();
        rec.observe(0);
        try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
        try rec.commit(1);
        whole = try bind.logLength();
        try rec.recordBoundary(header(2), .{ .what = .c6_bytes, .body = "tail" });
        try rec.commit(2);
        // The crash: the last commit landed in part.
        try bind.storage.truncate(bind.storage.context, try bind.logLength() - 3);
    }
    const again = try bind_mod.Bind.open(gpa, std.testing.io, root, .{ .reopen = id });
    defer _ = again.close() catch {};
    try std.testing.expectEqual(whole, try again.logLength());
}

test "acceptance: a whole frame that fails its crc refuses the reopen" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.recordIntervention(header(2), .{ .what = .tap, .body = "xy" });
    try rec.commit(1);

    // One flipped byte inside the first frame's payload: a whole
    // frame whose CRC no longer matches refuses the reopen rather
    // than being cut away.
    const store = history.storage.Store.from(&bind.session);
    const log = try store.vtable.open(store.context, .log, "events-0", .read);
    const len = try log.vtable.length(log.context);
    const bytes = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(bytes);
    _ = try log.vtable.read(log.context, 0, bytes);
    log.vtable.close(log.context);
    const back = try store.vtable.open(store.context, .log, "events-0", .update);
    bytes[12] ^= 0xFF;
    try back.vtable.write(back.context, 12, @as(*const [1]u8, &bytes[12]));
    back.vtable.close(back.context);

    var trim: Trim = .{};
    defer trim.cuts.deinit(gpa);
    try std.testing.expectError(error.BadCrc, recorder_mod.recoverSegment(bytes, trim.storage()));
    try std.testing.expectEqual(@as(usize, 0), trim.cuts.items.len);
    try std.testing.expectEqual(history.session.Outcome.deleted, try bind.close());
}

test "acceptance: a closed session leaves the root's catalog empty" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var base_root = try history.base.Base.open(gpa, std.testing.io, root, .cache);
    defer base_root.close();
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    try bind.storage.append(bind.storage.context, "recorded bytes");
    try bind.objects.put(bind.objects.context, .data, "0123456789abcdef", "object bytes");
    var entries = try history.catalog.Iterator.init(&base_root);
    const entry = (try entries.next()).?;
    const held = try history.catalog.du(&base_root, entry.name);
    try std.testing.expect(held > 0);
    try std.testing.expectEqual(history.session.Outcome.deleted, try bind.close());
    var after = try history.catalog.Iterator.init(&base_root);
    try std.testing.expect((try after.next()) == null);
}

test "acceptance: a commit the volume cannot take refuses, then relief lands it" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer {
        rec.deinit();
        _ = bind.close() catch {};
    }
    var volume: Volume = .{ .free_now = 8 * 1024 * 1024 };
    rec.disk = volume.budget();
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "abc" });
    try rec.recordIntervention(header(2), .{ .what = .tap, .body = "xy" });
    try rec.commit(1);

    const store = history.storage.Store.from(&bind.session);
    const landed = try segmentLength(&store);

    // The volume empties under the session: the commit refuses with
    // HistoryFull, its bytes stay staged for a later retry, the
    // segment on disk holds nothing new, and the relief the
    // application supplied ran exactly once before the refusal stood.
    volume.free_now = 0;
    try rec.recordBoundary(header(3), .{ .what = .c6_bytes, .body = "tail" });
    try std.testing.expectError(error.HistoryFull, rec.commit(2));
    try std.testing.expect(rec.pendingBytes() > 0);
    try std.testing.expectEqual(landed, try segmentLength(&store));
    try std.testing.expectEqual(@as(usize, 1), volume.reliefs);

    // A relief that reclaims bytes makes the retry land: the staged
    // frame leaves in one append, and the re-check's answer stands.
    volume.reclaim = 8 * 1024 * 1024;
    try rec.commit(3);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    try std.testing.expect(try segmentLength(&store) > landed);
    try std.testing.expectEqual(@as(usize, 2), volume.reliefs);
}

test "acceptance: an unmeasured history runs with no disk budget at all" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    var rec = try recorder_mod.Recorder.init(gpa, bind.storage, .{});
    defer {
        rec.deinit();
        _ = bind.close() catch {};
    }

    // No budget filled: the way an in-RAM session runs. Every commit
    // lands without a disk check, and the pressure the application
    // would read never leaves normal.
    rec.observe(0);
    for (0..64) |seq| {
        try rec.recordBoundary(header(@intCast(seq + 1)), .{ .what = .c6_bytes, .body = "abc" });
        try rec.commit(@intCast(seq + 1));
        try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
        try std.testing.expect(rec.last_pressure == .normal);
    }
    const store = history.storage.Store.from(&bind.session);
    try std.testing.expect(try segmentLength(&store) > 0);
}
