//! Covers src/session/history/log.zig: group commit on the caller's
//! clock, and the scan that separates a torn final tail from rot.
const std = @import("std");
const ra8 = @import("ra8");
const log_mod = ra8.session.history_log;
const format = ra8.session.history_format;

/// A sink that counts its flushes, so a test can see whether staged bytes
/// have left the writer's hands.
const Sink = struct {
    data: [256]u8 = undefined,
    len: usize = 0,
    flushes: usize = 0,
    scratch: [64]u8 = undefined,
    interface: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };

    fn init(self: *Sink) void {
        self.* = .{ .interface = undefined };
        self.interface = .{ .vtable = &vtable, .buffer = &self.scratch, .end = 0 };
    }

    fn drain(w: *std.Io.Writer, source: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        _ = splat;
        var moved: usize = 0;
        if (w.end != 0) {
            try self.take(w.buffer[0..w.end]);
            w.end = 0;
        }
        for (source) |slice| {
            try self.take(slice);
            moved += slice.len;
        }
        return moved;
    }

    fn take(self: *Sink, bytes: []const u8) std.Io.Writer.Error!void {
        if (self.len + bytes.len > self.data.len) return error.WriteFailed;
        @memcpy(self.data[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", w));
        self.flushes += 1;
        while (w.end != 0) _ = try drain(w, &.{""}, 1);
    }
};

test "group commit fires at the first of its two thresholds, exactly" {
    var sink: Sink = undefined;
    sink.init();
    var log: log_mod.Log = .{ .writer = &sink.interface };
    // Nothing staged and no time handed over: nothing commits.
    try std.testing.expectEqual(.no, log.shouldCommit(0));
    // The byte threshold fires at the cap, not one byte before it.
    log.pending_bytes = log.policy.max_bytes;
    try std.testing.expectEqual(.bytes, log.shouldCommit(0));
    log.pending_bytes = log.policy.max_bytes - 1;
    try std.testing.expectEqual(.no, log.shouldCommit(0));
    // The time threshold fires at exactly 250 ms, not one before it.
    log.observe(1_000);
    try std.testing.expectEqual(.no, log.shouldCommit(1_000 + std.time.ns_per_ms * 249));
    try std.testing.expectEqual(.time, log.shouldCommit(1_000 + std.time.ns_per_ms * 250));
    // Before the caller hands over a first time sample, only bytes commit.
    var fresh: log_mod.Log = .{ .writer = &sink.interface };
    fresh.pending_bytes = fresh.policy.max_bytes - 1;
    try std.testing.expectEqual(.no, fresh.shouldCommit(std.time.ns_per_ms * 100_000));
}

test "a commit flushes the staged frames and restarts both thresholds" {
    var sink: Sink = undefined;
    sink.init();
    var log: log_mod.Log = .{ .writer = &sink.interface };
    var frame: [20]u8 = undefined;
    @memset(&frame, 0xAA);
    try log.append(&frame);
    try log.append(&frame);
    try std.testing.expectEqual(@as(usize, 40), log.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), sink.flushes);
    try log.commit(5_000);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(@as(usize, 40), sink.len);
    try std.testing.expectEqual(@as(usize, 0), log.pending_bytes);
    // The clock anchor moved to the commit's own time.
    try std.testing.expectEqual(.no, log.shouldCommit(5_000 + std.time.ns_per_ms * 249));
    try std.testing.expectEqual(.time, log.shouldCommit(5_000 + std.time.ns_per_ms * 250));
    // maybeCommit only acts at a threshold.
    try log.maybeCommit(5_000 + std.time.ns_per_ms * 100);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try log.maybeCommit(5_000 + std.time.ns_per_ms * 250);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
}

const Visitor = struct {
    kinds: [8]u16 = undefined,
    offsets: [8]usize = undefined,
    n: usize = 0,

    fn visit(self: *Visitor, boundary: log_mod.Boundary) void {
        self.kinds[self.n] = boundary.kind;
        self.offsets[self.n] = boundary.offset;
        self.n += 1;
    }
};

fn threeFrames() !std.Io.Writer.Allocating {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try format.encode(&buf.writer, 1, "a");
    try format.encode(&buf.writer, 2, "bb");
    try format.encode(&buf.writer, 3, "ccc");
    return buf;
}

test "a scan of a whole segment visits every frame in order" {
    var buf = try threeFrames();
    defer buf.deinit();
    var seen = Visitor{};
    const recovery = try log_mod.scan(buf.written(), &seen, Visitor.visit);
    try std.testing.expectEqual(@as(usize, 3), recovery.frames);
    try std.testing.expectEqual(buf.written().len, recovery.complete_end);
    try std.testing.expect(!recovery.torn);
    try std.testing.expectEqual(@as(u16, 1), seen.kinds[0]);
    try std.testing.expectEqual(@as(u16, 2), seen.kinds[1]);
    try std.testing.expectEqual(@as(u16, 3), seen.kinds[2]);
    // The offsets are where each frame starts.
    try std.testing.expectEqual(@as(usize, 0), seen.offsets[0]);
    try std.testing.expectEqual(@as(usize, 11), seen.offsets[1]);
}

test "a torn final tail recovers to the last whole frame's boundary" {
    var buf = try threeFrames();
    defer buf.deinit();
    const bytes = buf.written();
    const third_at = 11 + 12; // frame 1 is 11 bytes, frame 2 is 12
    var seen = Visitor{};
    const recovery = try log_mod.scan(bytes[0 .. third_at + 4], &seen, Visitor.visit);
    try std.testing.expectEqual(@as(usize, 2), recovery.frames);
    try std.testing.expectEqual(third_at, recovery.complete_end);
    try std.testing.expect(recovery.torn);
    // A cut that leaves the third frame whole recovers nothing: all three.
    var whole_seen = Visitor{};
    const whole = try log_mod.scan(bytes, &whole_seen, Visitor.visit);
    try std.testing.expectEqual(@as(usize, 3), whole.frames);
    try std.testing.expect(!whole.torn);
}

test "a whole frame that lies or rots is hard, wherever it sits" {
    var buf = try threeFrames();
    defer buf.deinit();
    const bytes = buf.written();
    // Interior: flip the first frame's kind byte; the later frames are
    // intact, and the scan still fails.
    var broken = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(broken);
    broken[4] ^= 0xFF;
    var seen = Visitor{};
    try std.testing.expectError(error.BadCrc, log_mod.scan(broken, &seen, Visitor.visit));
    // The final frame, complete but bad, is hard too, not a torn tail.
    var tail = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(tail);
    tail[bytes.len - 1] ^= 0x01;
    try std.testing.expectError(error.BadCrc, log_mod.scan(tail, &seen, Visitor.visit));
}

test "deadline subtraction handles backward samples and near overflow" {
    var sink: Sink = undefined;
    sink.init();
    var log: log_mod.Log = .{ .writer = &sink.interface };
    log.pending_bytes = 1;
    const top = std.math.maxInt(u64);
    log.observe(top - 100);
    try std.testing.expectEqual(.no, log.shouldCommit(top));
    try std.testing.expectEqual(.no, log.shouldCommit(top - 101));
    log.observe(0);
    try std.testing.expectEqual(top - 100, log.last_commit_ns);
    log.policy.max_delay_ns = 100;
    try std.testing.expectEqual(.time, log.shouldCommit(top));
}
