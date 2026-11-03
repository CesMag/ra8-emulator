const std = @import("std");
const ra8 = @import("ra8");
const recorder = ra8.session.history_recorder;
const gpa = std.testing.allocator;

const Sink = @import("commit_sink.zig").Sink;

fn stage(rec: *recorder.Recorder, sequence: u32, body: []const u8) !void {
    try rec.recordBoundary(.{ .position = .{}, .seq = sequence }, .{ .what = .c6_bytes, .body = body });
}

fn failedCommit(fail_append: bool) !void {
    var sink: Sink = .{};
    defer sink.bytes.deinit(gpa);
    var rec = try recorder.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    try stage(&rec, 0, "prefix");
    try rec.commit(10);
    const prefix = try gpa.dupe(u8, sink.bytes.items);
    defer gpa.free(prefix);
    try stage(&rec, 1, "retry this whole frame");
    const staged = try gpa.dupe(u8, rec.staging.writer.buffered());
    defer gpa.free(staged);
    const pending = rec.log.pending_bytes;
    sink.fail_append = fail_append;
    sink.fail_flush = !fail_append;
    if (fail_append) {
        try std.testing.expectError(error.AppendFailed, rec.commit(250_000_010));
    } else {
        try std.testing.expectError(error.FlushFailed, rec.commit(250_000_010));
    }
    try std.testing.expectEqualSlices(u8, prefix, sink.bytes.items);
    try std.testing.expectEqualSlices(u8, staged, rec.staging.writer.buffered());
    try std.testing.expectEqual(pending, rec.log.pending_bytes);
    try std.testing.expectEqual(@as(u64, 10), rec.log.last_commit_ns);
    try rec.maybeCommit(250_000_010);
    try std.testing.expectEqualSlices(u8, prefix, sink.bytes.items[0..prefix.len]);
    try std.testing.expectEqualSlices(u8, staged, sink.bytes.items[prefix.len..]);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    try std.testing.expectEqual(@as(usize, 0), rec.log.pending_bytes);
    try std.testing.expectEqual(@as(u64, 250_000_010), rec.log.last_commit_ns);
}

test "partial append preserves the complete batch and deadline for retry" {
    try failedCommit(true);
}

test "failed durable flush preserves the complete batch and deadline for retry" {
    try failedCommit(false);
}

test "failed rollback blocks another append until truncation succeeds" {
    var sink: Sink = .{};
    defer sink.bytes.deinit(gpa);
    var rec = try recorder.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    try stage(&rec, 0, "only one copy may become durable");
    const staged = try gpa.dupe(u8, rec.staging.writer.buffered());
    defer gpa.free(staged);
    sink.fail_append = true;
    sink.fail_truncate = true;
    try std.testing.expectError(error.AppendFailed, rec.commit(250_000_000));
    const appends = sink.appends;
    const partial = sink.bytes.items.len;
    try std.testing.expectError(error.TruncateFailed, rec.commit(250_000_000));
    try std.testing.expectEqual(appends, sink.appends);
    try std.testing.expectEqual(partial, sink.bytes.items.len);
    sink.fail_truncate = false;
    try rec.commit(250_000_000);
    try std.testing.expectEqualSlices(u8, staged, sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
}

test "one MiB threshold commits before the time deadline and replay does not flush" {
    var sink: Sink = .{};
    defer sink.bytes.deinit(gpa);
    var rec = try recorder.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();
    rec.observe(0);
    const body = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(body);
    @memset(body, 0x35);
    try stage(&rec, 0, body);
    try rec.maybeCommit(1);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
    try stage(&rec, 1, "pending before replay");
    const pending = rec.pendingBytes();
    rec.replaying = true;
    try rec.commit(500_000_000);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(pending, rec.pendingBytes());
}
