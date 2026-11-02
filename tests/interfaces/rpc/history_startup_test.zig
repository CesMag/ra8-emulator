//! Tests for src/interfaces/rpc/history_startup.zig: a fresh served start
//! (Bind.open without reopen) sweeps stale ephemeral sessions, and
//! nothing else does. Live, kept and foreign entries stay byte-identical.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;
const fixture = @import("../../host/history/root_test.zig");
const bind_mod = ra8.rpc.history_bind;

fn readAll(dir: std.Io.Dir, leaf: []const u8, buf: []u8) ![]u8 {
    const bytes = try dir.readFile(fixture.io, leaf, buf);
    return bytes;
}

test "a fresh served start sweeps a stale session and keeps live, kept and foreign entries" {
    const gpa = std.testing.allocator;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    const sentinel = "sentinel";

    var stale = try f.create('7');
    const stale_id = stale.id;
    try stale.dir.writeFile(fixture.io, .{ .sub_path = "root.bin", .data = "dead data" });
    fixture.Fixture.abandon(&stale);

    var live = try f.create('8');
    defer _ = live.close(null, .stay) catch @panic("live session cleanup failed");
    try live.dir.writeFile(fixture.io, .{ .sub_path = "root.bin", .data = "live " ++ sentinel });

    var kept = try f.create('9');
    try kept.keep();
    try kept.dir.writeFile(fixture.io, .{ .sub_path = "root.bin", .data = "kept " ++ sentinel });
    const kept_id = kept.id;
    fixture.Fixture.abandon(&kept);

    var remote = try f.create('a');
    const remote_id = remote.id;
    try remote.dir.deleteFile(fixture.io, history.layout.files.owner);
    try history.owner.write(fixture.io, remote.dir, .{ .host = "owned-fixture-other-host", .pid = 0 });
    try remote.dir.writeFile(fixture.io, .{ .sub_path = "root.bin", .data = "remote " ++ sentinel });
    fixture.Fixture.abandon(&remote);

    try f.cache.dir.createDir(fixture.io, "foreign-dir", .default_dir);
    try f.cache.dir.writeFile(fixture.io, .{ .sub_path = "foreign-dir/note.txt", .data = "foreign " ++ sentinel });

    // Read-only maintenance and an existing-root open never sweep.
    var existing = try history.base.Base.existing(gpa, fixture.io, f.cache.path, .cache);
    existing.close();
    try f.cache.owns(&stale_id);

    const bind = try bind_mod.Bind.open(gpa, fixture.io, f.cache.path, .{});
    defer _ = bind.close() catch {};

    try std.testing.expectError(error.NotFound, f.cache.owns(&stale_id));
    var lease: history.name.Buffer = undefined;
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, history.name.lease(&lease, &stale_id), .{}));
    try f.cache.owns(&live.id);
    try f.cache.owns(&kept_id);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("live " ++ sentinel, try readAll(live.dir, "root.bin", &buf));
    var kept_dir = try f.cache.dir.openDir(fixture.io, &kept_id, .{});
    defer kept_dir.close(fixture.io);
    try std.testing.expectEqualStrings("kept " ++ sentinel, try readAll(kept_dir, "root.bin", &buf));
    var remote_dir = try f.cache.dir.openDir(fixture.io, &remote_id, .{});
    defer remote_dir.close(fixture.io);
    try std.testing.expectEqualStrings("remote " ++ sentinel, try readAll(remote_dir, "root.bin", &buf));
    try std.testing.expectEqualStrings("foreign " ++ sentinel, try readAll(f.cache.dir, "foreign-dir/note.txt", &buf));
}
