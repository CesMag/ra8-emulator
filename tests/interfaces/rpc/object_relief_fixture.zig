//! Native recovery/relief fixtures shared by the registered Bind tests.
const std = @import("std");
const ra8 = @import("ra8");
const h = ra8.host.history;
const Bind = ra8.rpc.history_bind.Bind;
const NativeProbe = @import("object_stage_fixture.zig").NativeProbe;
const gpa = std.testing.allocator;
const io = std.testing.io;
const note = h.layout.files.renaming;

fn relief(bind: *Bind) !void {
    const disk = bind.disk.?;
    try disk.relief.?(disk.context);
}

fn bytes(bind: *Bind, name: []const u8, expected: []const u8) !void {
    const read = try ra8.rpc.object_read.read(h.storage.Store.from(&bind.session), gpa, name);
    defer gpa.free(read);
    try std.testing.expectEqualStrings(expected, read);
}

fn orphan(bind: *Bind, name: []const u8) !void {
    const store = h.storage.Store.from(&bind.session);
    const file = try store.vtable.open(store.context, .objects, name, .create);
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, "orphan bytes");
    try file.vtable.sync(file.context);
}

pub fn abandoned() !void {
    const modes = [_]@FieldType(NativeProbe, "mode"){ .intent, .fallback_link, .fallback_unlink };
    const faults = [_]anyerror{ error.InjectedIntent, error.InjectedLinked, error.InjectedUnlinked };
    for (modes, faults, 0..) |mode, fault, index| {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        const bind = try Bind.open(gpa, io, root, .{});
        defer _ = bind.close() catch {};
        try orphan(bind, "object-put-unowned");
        var probe: NativeProbe = .{ .session = &bind.session, .mode = mode };
        bind.session.move_probe = probe.hook();
        try std.testing.expectError(fault, bind.objects.put(bind.objects.context, .data, "target", "complete bytes"));
        bind.session.move_probe = null;
        var pending = (try h.rename.pending(io, bind.session.dir)) orelse return error.LostRenameIntent;
        defer pending.deinit();
        const before = pending.parsed.value;
        try std.testing.expect(before.source.inode != 0);
        try std.testing.expect(before.top.inode != 0 and before.area.inode != 0);
        var dir = try h.paths.area(&bind.session, .objects);
        if (index < 2) try bytes(bind, probe.from[0..probe.len], "complete bytes");
        if (index == 0) try std.testing.expectError(error.FileNotFound, dir.access(io, "target", .{}));
        if (index > 0) try bytes(bind, "target", "complete bytes");
        // Remove live pending protection: the real sweep must independently
        // protect both names using the persisted identity, not the prefix.
        bind.pending.clear();
        try relief(bind);
        try std.testing.expectError(error.FileNotFound, dir.access(io, "object-put-unowned", .{}));
        var after = (try h.rename.pending(io, bind.session.dir)) orelse return error.LostRenameIntent;
        defer after.deinit();
        try std.testing.expectEqual(pending.inode, after.inode);
        if (index < 2) try bytes(bind, probe.from[0..probe.len], "complete bytes");
        if (index > 0) try bytes(bind, "target", "complete bytes");
        dir.close(io);
        try reopen(bind);
        try std.testing.expect((try h.rename.pending(io, bind.session.dir)) == null);
        if (index == 0) try bytes(bind, probe.from[0..probe.len], "complete bytes");
        if (index > 0) try bytes(bind, "target", "complete bytes");
        // No log acknowledges these bytes. Once the note is settled the
        // very next production relief reclaims every remaining loose file.
        try relief(bind);
        var final_dir = try h.paths.area(&bind.session, .objects);
        defer final_dir.close(io);
        try std.testing.expectError(error.FileNotFound, final_dir.access(io, probe.from[0..probe.len], .{}));
        try std.testing.expectError(error.FileNotFound, final_dir.access(io, "target", .{}));
    }
}

fn reopen(bind: *Bind) !void {
    const id = bind.session.id;
    bind.packs.close();
    bind.log.vtable.close(bind.log.context);
    bind.session.dir.close(io);
    bind.session.lock.close(io);
    bind.session = try h.session.Session.reopen(&bind.base, id);
    const store = h.storage.Store.from(&bind.session);
    bind.log = try store.vtable.open(store.context, .log, "events-0", .update);
    bind.sink.byte = bind.log;
    bind.packs = try ra8.rpc.pack_store.PackStore.open(gpa, &bind.session);
    bind.watch.?.packs = bind.packs;
}

pub fn invalid() !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const bind = try Bind.open(gpa, io, root, .{});
    defer _ = bind.close() catch {};
    try orphan(bind, "object-put-unowned");
    for ([_][]const u8{ "", "{\"version\":", "{}" }) |bad| {
        try bind.session.dir.writeFile(io, .{ .sub_path = note, .data = bad });
        try std.testing.expectError(error.BadMetadata, relief(bind));
        try bytes(bind, "object-put-unowned", "orphan bytes");
        const kept = try bind.session.dir.readFileAlloc(io, note, gpa, .unlimited);
        defer gpa.free(kept);
        try std.testing.expectEqualStrings(bad, kept);
    }
    try bind.session.dir.deleteFile(io, note);
    // A directory cannot be read as ordinary intent metadata, even as root.
    // This is deterministic across native Linux and Windows privileges.
    try bind.session.dir.createDir(io, note, .default_dir);
    try std.testing.expectError(error.OutsideRoot, relief(bind));
    try bytes(bind, "object-put-unowned", "orphan bytes");
    try bind.session.dir.deleteDir(io, note);
    try relief(bind);
    var dir = try h.paths.area(&bind.session, .objects);
    defer dir.close(io);
    try std.testing.expectError(error.FileNotFound, dir.access(io, "object-put-unowned", .{}));
}

pub fn conflicts() !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const bind = try Bind.open(gpa, io, root, .{});
    defer _ = bind.close() catch {};
    try orphan(bind, "object-put-unowned");
    var probe: NativeProbe = .{ .session = &bind.session, .mode = .intent };
    bind.session.move_probe = probe.hook();
    try std.testing.expectError(error.InjectedIntent, bind.objects.put(bind.objects.context, .data, "target", "complete bytes"));
    bind.session.move_probe = null;
    var held = (try h.rename.pending(io, bind.session.dir)).?;
    defer held.deinit();
    for (0..5) |index| {
        var wrong = held.parsed.value;
        switch (index) {
            0 => wrong.top.inode ^= 1,
            1 => wrong.area.inode ^= 1,
            2 => wrong.source.inode ^= 1,
            3 => wrong.version = 2,
            4 => wrong.source.links = 2,
            else => unreachable,
        }
        const encoded = try std.json.Stringify.valueAlloc(gpa, wrong, .{});
        defer gpa.free(encoded);
        try bind.session.dir.writeFile(io, .{ .sub_path = note, .data = encoded });
        try std.testing.expectError(if (index < 3) error.IdentityConflict else error.BadMetadata, relief(bind));
        try bytes(bind, "object-put-unowned", "orphan bytes");
        try bytes(bind, probe.from[0..probe.len], "complete bytes");
        const kept = try bind.session.dir.readFileAlloc(io, note, gpa, .unlimited);
        defer gpa.free(kept);
        try std.testing.expectEqualStrings(encoded, kept);
    }
    const encoded = try std.json.Stringify.valueAlloc(gpa, held.parsed.value, .{});
    defer gpa.free(encoded);
    try bind.session.dir.writeFile(io, .{ .sub_path = note, .data = encoded });
    try orphan(bind, "target");
    try std.testing.expectError(error.IdentityConflict, relief(bind));
    try bytes(bind, "object-put-unowned", "orphan bytes");
    try bytes(bind, "target", "orphan bytes");
    try bytes(bind, probe.from[0..probe.len], "complete bytes");
    var dir = try h.paths.area(&bind.session, .objects);
    defer dir.close(io);
    try dir.deleteFile(io, "target");
    try relief(bind);
    try bytes(bind, probe.from[0..probe.len], "complete bytes");
    try bind.objects.put(bind.objects.context, .data, "target", "complete bytes");
    try relief(bind);
    try bytes(bind, "target", "complete bytes");
}
