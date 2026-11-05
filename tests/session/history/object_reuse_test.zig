//! Collision validation distinguishes immutable data from snapshot-keyed metadata.
const std = @import("std");
const ra8 = @import("ra8");
const reuse = ra8.session.history_object_reuse;
const manifest = ra8.session.history_manifest;
const touched = ra8.session.history_touched_pages;
const gpa = std.testing.allocator;

test "immutable objects require every byte including length" {
    try reuse.validate(gpa, .data, "", "");
    try reuse.validate(gpa, .data, "complete", "complete");
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .data, "co", "complete"));
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .data, "Complete", "complete"));
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .data, "complete!", "complete"));
}

fn manifestBytes(id: u32, round: u64) ![]u8 {
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

test "manifest aliases permit checkpoint IDs while verifying state and integrity" {
    const a = try manifestBytes(1, 4);
    defer gpa.free(a);
    const b = try manifestBytes(2, 4);
    defer gpa.free(b);
    const other = try manifestBytes(3, 5);
    defer gpa.free(other);
    try reuse.validate(gpa, .manifest, a, a);
    try reuse.validate(gpa, .manifest, a, b);
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .manifest, a, other));
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .manifest, a[0 .. a.len - 1], b));
    a[a.len - 1] ^= 1;
    try std.testing.expectError(error.BadCrc, reuse.validate(gpa, .manifest, a, b));
    try std.testing.expectError(error.BadCrc, reuse.validate(gpa, .manifest, a, a));
}

fn touchedBytes(since: u32, words: []const u64) ![]u8 {
    var value: touched.Touched = .{ .allocator = gpa, .since = since, .masks = @splat(&.{}) };
    value.masks[0] = @constCast(words);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer out.deinit();
    try value.encode(&out.writer);
    return gpa.dupe(u8, out.written());
}

test "touched aliases retain first-writer intervals and reject malformed or conflicting masks" {
    const a = try touchedBytes(0, &.{1});
    defer gpa.free(a);
    const later = try touchedBytes(1, &.{0});
    defer gpa.free(later);
    const conflict = try touchedBytes(0, &.{0});
    defer gpa.free(conflict);
    try reuse.validate(gpa, .touched, a, a);
    try reuse.validate(gpa, .touched, a, later);
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .touched, a, conflict));
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .touched, a[0 .. a.len - 1], later));
    std.mem.writeInt(u32, a[4..8], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .touched, a, later));
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .touched, a, a));
}

test "metadata shape checks reject trailing bytes and impossible counts before allocation" {
    const original = try manifestBytes(1, 4);
    defer gpa.free(original);
    const extra = try std.mem.concat(gpa, u8, &.{ original, "x" });
    defer gpa.free(extra);
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .manifest, extra, extra));
    const count_at = manifest.magic.len + 4 + ra8.session.history_position.encoded_len + 5;
    std.mem.writeInt(u32, original[count_at..][0..4], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .manifest, original, original));
    const t = try touchedBytes(0, &.{1});
    defer gpa.free(t);
    const t_extra = try std.mem.concat(gpa, u8, &.{ t, "x" });
    defer gpa.free(t_extra);
    try std.testing.expectError(error.ObjectConflict, reuse.validate(gpa, .touched, t_extra, t_extra));
}
