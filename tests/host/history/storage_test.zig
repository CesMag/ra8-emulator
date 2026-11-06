const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle injected byte store supports exact offsets sync truncate rename and listing" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('1');
    const store = history.storage.Store.from(&session);
    const file = try store.vtable.open(store.context, .log, "events-0", .create);
    try file.vtable.write(file.context, 0, "abcdef");
    try file.vtable.write(file.context, 2, "XY");
    try file.vtable.sync(file.context);
    try std.testing.expectEqual(@as(u64, 6), (try (try history.storage.native(file)).stat(std.testing.io)).size);
    var buffer: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try file.vtable.read(file.context, 0, &buffer));
    try std.testing.expectEqualStrings("abXYef", &buffer);
    try file.vtable.truncate(file.context, 4);
    try std.testing.expectEqual(@as(u64, 4), try file.vtable.length(file.context));
    file.vtable.close(file.context);
    try store.vtable.rename(store.context, .log, "events-0", "events-1");
    var seen: u64 = 0;
    const callback = struct {
        fn visit(context: *anyopaque, text: []const u8, size: u64) !void {
            const counter: *u64 = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("events-1", text);
            try std.testing.expectEqual(@as(u64, 4), size);
            counter.* += 1;
        }
    };
    try store.vtable.list(store.context, .log, .{ .context = &seen, .visit = callback.visit });
    try std.testing.expectEqual(@as(u64, 1), seen);
    try store.vtable.remove(store.context, .log, "events-1");
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
}

test "host lifecycle injected store refuses marker mutation traversal and replacement" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('2');
    defer _ = session.close(null, .stay) catch @panic("session cleanup failed");
    const store = history.storage.Store.from(&session);
    try std.testing.expectError(error.Reserved, store.vtable.open(store.context, .top, "owner.lock", .create));
    try std.testing.expectError(error.BadName, store.vtable.open(store.context, .objects, "../owner", .read));
    const first = try store.vtable.open(store.context, .objects, "hash1", .create);
    first.vtable.close(first.context);
    const second = try store.vtable.open(store.context, .objects, "hash2", .create);
    second.vtable.close(second.context);
    try std.testing.expectError(error.PathAlreadyExists, store.vtable.rename(store.context, .objects, "hash1", "hash2"));
    try std.testing.expectError(error.PathAlreadyExists, store.vtable.open(store.context, .objects, "hash1", .create));
    try std.testing.expectError(error.EphemeralOnly, store.vtable.open(store.context, .frames, "frame1", .read));
}

test "Linux owned cleanup retains a real prelink intent and abandoned session reopens for publication" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('3');
    const id = session.id;
    const store = history.storage.Store.from(&session);
    const held = try store.vtable.open(store.context, .objects, "object-put-held", .create);
    try held.vtable.write(held.context, 0, "complete bytes");
    try held.vtable.sync(held.context);
    var dir = try history.paths.area(&session, .objects);
    try history.rename.begin(std.testing.io, session.dir, dir, .objects, "object-put-held", "target");
    try history.storage.removeOwned(&session, "object-put-held", held);
    try std.testing.expectEqual(@as(u64, 14), (try dir.statFile(std.testing.io, "object-put-held", .{})).size);
    try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "target", .{}));
    dir.close(std.testing.io);
    held.vtable.close(held.context);
    fixture.Fixture.abandon(&session);
    var again = try history.session.Session.reopen(&f.cache, id);
    defer _ = again.close(null, .stay) catch @panic("session cleanup failed");
    try std.testing.expect((try history.rename.pending(std.testing.io, again.dir)) == null);
    const reopened = history.storage.Store.from(&again);
    const payload = try reopened.vtable.open(reopened.context, .objects, "object-put-held", .update);
    defer payload.vtable.close(payload.context);
    try history.storage.publishOwned(&again, "object-put-held", "target", payload);
    try payload.vtable.sync(payload.context);
    var final_dir = try history.paths.area(&again, .objects);
    defer final_dir.close(std.testing.io);
    try history.move.file.syncDir(final_dir);
    var bytes: [14]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try payload.vtable.read(payload.context, 0, &bytes));
    try std.testing.expectEqualStrings("complete bytes", &bytes);
}

test "native orphan sweep holds the lifecycle gate through its removal visitor" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('4');
    defer _ = session.close(null, .stay) catch @panic("session cleanup failed");
    const store = history.storage.Store.from(&session);
    const file = try store.vtable.open(store.context, .objects, "orphan", .create);
    file.vtable.close(file.context);
    var names = std.StringHashMap(void).init(std.testing.allocator);
    defer names.deinit();
    const Probe = struct {
        session: *history.session.Session,
        visited: bool = false,

        fn visit(context: *anyopaque, name: []const u8, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectError(error.GateBusy, self.session.base.gate(.exclusive));
            const native = history.storage.Store.from(self.session);
            try native.vtable.remove(native.context, .objects, name);
            self.visited = true;
        }
    };
    var probe: Probe = .{ .session = &session };
    try store.vtable.sweep.?(store.context, std.testing.allocator, &names, .{ .context = &probe, .visit = Probe.visit });
    try std.testing.expect(probe.visited);
    var gate = try session.base.gate(.exclusive);
    gate.release();
}
