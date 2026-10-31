const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "an unsettled reopen holds the lease and leaves recovery to admission" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('8');
    const id = session.id;
    try session.keep();
    try session.dir.writeFile(fixture.io, .{ .sub_path = history.layout.files.renaming, .data = "unsettled metadata" });
    fixture.Fixture.abandon(&session);
    session = try history.session.Session.reopenUnsettled(&f.cache, id);
    defer fixture.Fixture.abandon(&session);
    try session.dir.access(fixture.io, history.layout.files.renaming, .{});
    try std.testing.expectEqual(history.lock.State.held, history.lock.probe(fixture.io, f.cache.dir, &id));
    try std.testing.expectError(error.BadMetadata, history.rename.settle(fixture.io, session.dir));
    try session.dir.access(fixture.io, history.layout.files.renaming, .{});
}

test "host lifecycle publishes a locked session and clean exit leaves zero session bytes" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('2');
    const id = session.id;
    try std.testing.expectEqual(history.lock.State.held, history.lock.probe(fixture.io, session.base.dir, &session.id));
    var buffer: history.name.Buffer = undefined;
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, history.name.creating(&buffer, &id), .{}));
    for (history.layout.spaces) |space| try session.dir.access(fixture.io, @tagName(space), .{});
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
    try std.testing.expectError(error.NotFound, f.cache.owns(&id));
    const report = try history.sweep.run(&f.cache, .{}, null);
    try std.testing.expectEqual(@as(u64, 0), report.removed);
}

test "host lifecycle rejects colliding IDs and reopening a live directory" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('3');
    defer _ = session.close(null, .stay) catch @panic("session cleanup failed");
    try std.testing.expectError(error.IdTaken, f.create('3'));
    try std.testing.expectError(error.Locked, history.session.Session.reopen(&f.cache, session.id));
    const bad: history.name.Id = @splat('z');
    try std.testing.expectError(error.BadName, history.session.Session.create(&f.cache, .{ .id = bad }));
}

test "host lifecycle keep marks in place then same-filesystem exit moves to data" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('4');
    const id = session.id;
    try session.keep();
    try f.cache.owns(&id);
    try std.testing.expectError(error.NotFound, f.kept.owns(&id));
    try std.testing.expectEqual(history.session.Outcome.moved, try session.close(&f.kept, .move));
    try std.testing.expectError(error.NotFound, f.cache.owns(&id));
    try f.kept.owns(&id);
    var reopened = try history.session.Session.reopen(&f.kept, id);
    try std.testing.expect(reopened.kept);
    try std.testing.expectEqual(history.session.Outcome.left, try reopened.close(null, .stay));
}

test "host lifecycle keep stay leaves an absolute pointer without copying bytes" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('5');
    const id = session.id;
    try session.dir.writeFile(fixture.io, .{ .sub_path = history.layout.files.root, .data = "root payload" });
    try session.keep();
    try std.testing.expectEqual(history.session.Outcome.pointed, try session.close(&f.kept, .stay));
    try f.cache.owns(&id);
    try std.testing.expectError(error.NotFound, f.kept.owns(&id));
    const expected = try f.cache.pathOf(fixture.allocator, &id);
    defer fixture.allocator.free(expected);
    var pointer_buffer: history.name.Buffer = undefined;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try f.kept.dir.readFile(fixture.io, history.name.pointer(&pointer_buffer, &id), &path_buffer));
    try std.testing.expectEqual(@as(u64, 0), (try history.sweep.run(&f.cache, .{}, null)).removed);
}

test "host lifecycle keep preserves its marker and refuses an outside hardlink" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('c');
    defer fixture.Fixture.abandon(&session);
    try session.keep();
    const before = try session.dir.statFile(fixture.io, history.layout.files.kept, .{});
    try session.keep();
    try std.testing.expectEqual(before.inode, (try session.dir.statFile(fixture.io, history.layout.files.kept, .{})).inode);
    try session.dir.deleteFile(fixture.io, history.layout.files.kept);
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "sentinel", .data = "preserved" });
    try f.hardLink("sentinel", session.dir, history.layout.files.kept);
    session.kept = false;
    try std.testing.expectError(error.OutsideRoot, session.keep());
    try std.testing.expect(!session.kept);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("preserved", try f.tmp.dir.readFile(fixture.io, "sentinel", &buffer));
}

test "host lifecycle keep refuses symlink dangling link and unexpected directory without outside writes" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('d');
    defer fixture.Fixture.abandon(&session);
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "sentinel", .data = "preserved" });
    const outside = try f.tmp.dir.realPathFileAlloc(fixture.io, "sentinel", fixture.allocator);
    defer fixture.allocator.free(outside);
    const missing = try std.fs.path.join(fixture.allocator, &.{ f.cache.path, "missing-sentinel" });
    defer fixture.allocator.free(missing);
    for ([_][]const u8{ outside, missing }) |target| {
        try fixture.symLink(session.dir, target, history.layout.files.kept);
        try std.testing.expectError(error.OutsideRoot, session.keep());
        try std.testing.expect(!session.kept);
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings("preserved", try f.tmp.dir.readFile(fixture.io, "sentinel", &buffer));
        try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, "missing-sentinel", .{}));
        try session.dir.deleteFile(fixture.io, history.layout.files.kept);
    }
    try session.dir.createDir(fixture.io, history.layout.files.kept, history.layout.directory_permissions);
    try std.testing.expectError(error.OutsideRoot, session.keep());
}
