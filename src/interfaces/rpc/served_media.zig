//! Freeze and restore the existing complete SD snapshot, independently of ELF memory.
const std = @import("std");
const session = @import("ra8_session");
const history = @import("ra8_host").history;
const snapshot = @import("ra8_board").snapshot;
const objects = @import("object_read.zig");

/// Sparse SD snapshot input cap; never allocate from an unchecked object length.
pub const max_bytes = 256 * 1024 * 1024;

pub fn save(gpa: std.mem.Allocator, board: anytype, recorder: *session.history_recorder.Recorder) ![16]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try snapshot.run.file.writeHeader(&out.writer);
    try snapshot.sd.save(board, &out.writer);
    if (out.written().len > max_bytes) return error.ObjectTooLarge;
    const id = session.history_object_id.ObjectId.compute(out.written());
    var name: [32]u8 = undefined;
    id.formatHex(&name);
    // Objects are durable before root.bin can name them. Loose objects use the
    // same content-addressed store read by history restore and prune.
    try recorder.putRootObject(&name, out.written());
    return id.bytes;
}

pub fn read(gpa: std.mem.Allocator, store: history.storage.Store, id: [16]u8) ![]u8 {
    var name: [32]u8 = undefined;
    (session.history_object_id.ObjectId{ .bytes = id }).formatHex(&name);
    const bytes = try objects.readLimited(store, gpa, &name, max_bytes);
    errdefer gpa.free(bytes);
    const got = session.history_object_id.ObjectId.compute(bytes);
    if (!std.mem.eql(u8, &got.bytes, &id)) return error.InitialMediaMismatch;
    try snapshot.sd.validate(bytes);
    return bytes;
}

pub fn load(board: anytype, bytes: []const u8) !void {
    if (bytes.len > max_bytes) return error.ObjectTooLarge;
    try snapshot.sd.load(board, bytes);
}
