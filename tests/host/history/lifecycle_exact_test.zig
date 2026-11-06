//! The byte-exact lifecycle acceptance (RA8EMU-1196, slice 16): a
//! session's exit leaves the root holding exactly the entries it held
//! before, and a kept session's recorded bytes survive the move
//! unchanged. Real files behind the fixture, never a fake store.
const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

const io = fixture.io;
const allocator = fixture.allocator;

/// Every path under one directory, recursively, as sorted names.
const Listing = struct {
    names: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Listing) void {
        for (self.names.items) |item| allocator.free(item);
        self.names.deinit(allocator);
    }
};

fn snapshot(dir: std.Io.Dir, prefix: []const u8, out: *Listing) anyerror!void {
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ prefix, std.fs.path.sep, entry.name });
        try out.names.append(allocator, path);
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .directory) continue;
        var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
        defer child.close(io);
        try snapshot(child, path, out);
    }
}

fn expectSameListing(wanted: *const Listing, actual: *const Listing) !void {
    try std.testing.expectEqual(wanted.names.items.len, actual.names.items.len);
    for (wanted.names.items, actual.names.items) |a, b| {
        try std.testing.expectEqualStrings(a, b);
    }
}

fn sorted(listing: *Listing) !void {
    std.mem.sort([]u8, listing.names.items, {}, lessThan);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Records two known files into the session: one log segment and one
/// object, each synced.
fn record(session: *history.session.Session) !void {
    var store = history.storage.Store.from(session);
    var file = try store.vtable.open(store.context, .log, "events-0", .create);
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, "recorded log bytes 0123456789");
    try file.vtable.sync(file.context);
    var object = try store.vtable.open(store.context, .objects, "obj-a", .create);
    defer object.vtable.close(object.context);
    try object.vtable.write(object.context, 0, "object bytes abcdef");
    try object.vtable.sync(object.context);
}

test "an ephemeral session's exit leaves the cache root with exactly its original entries" {
    var f = try fixture.Fixture.init();
    defer f.deinit();

    var before: Listing = .{};
    defer before.deinit();
    try snapshot(f.cache.dir, "", &before);
    try sorted(&before);

    var session = try f.create('1');
    const id = session.id;
    try record(&session);
    var session_listing: Listing = .{};
    defer session_listing.deinit();
    try snapshot(session.dir, &id, &session_listing);
    try sorted(&session_listing);
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));

    var after: Listing = .{};
    defer after.deinit();
    try snapshot(f.cache.dir, "", &after);
    try sorted(&after);
    try expectSameListing(&before, &after);
}

test "a kept session's exit moves it whole and every recorded byte survives exactly" {
    var f = try fixture.Fixture.init();
    defer f.deinit();

    var before: Listing = .{};
    defer before.deinit();
    try snapshot(f.cache.dir, "", &before);
    try sorted(&before);

    var session = try f.create('2');
    const id = session.id;
    try record(&session);
    var session_listing: Listing = .{};
    defer session_listing.deinit();
    try snapshot(session.dir, &id, &session_listing);
    try sorted(&session_listing);
    try session.keep();
    try std.testing.expectEqual(history.session.Outcome.moved, try session.close(&f.kept, .move));

    // The cache root carries no residue of the exit.
    var after: Listing = .{};
    defer after.deinit();
    try snapshot(f.cache.dir, "", &after);
    try sorted(&after);
    try expectSameListing(&before, &after);

    // The kept root holds the moved session and nothing else: the root
    // marker, the gate, the parked lease and the session itself.
    var kept: Listing = .{};
    defer kept.deinit();
    try snapshot(f.kept.dir, "", &kept);
    try sorted(&kept);
    var top: usize = 0;
    for (kept.names.items) |path| {
        if (std.mem.indexOfScalar(u8, path, std.fs.path.sep) != null) continue;
        top += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), top);
    var id_text: [64]u8 = undefined;
    const id_name = try std.fmt.bufPrint(&id_text, "{s}", .{&id});
    var lease_text: [64]u8 = undefined;
    const lease_name = try std.fmt.bufPrint(&lease_text, "{s}.lease", .{id_name});
    const count = kept.names.items.len;
    try std.testing.expectEqualStrings(id_name, kept.names.items[0]);
    try std.testing.expectEqualStrings(lease_name, kept.names.items[1]);
    try std.testing.expectEqualStrings(history.layout.root.gate, kept.names.items[count - 2]);
    try std.testing.expectEqualStrings(history.layout.root.marker, kept.names.items[count - 1]);

    // The moved subtree holds exactly the tree the session had, with one
    // intended difference: the unpublished marker is replaced by the kept
    // marker. The destination receipts persist by design, so every
    // other path, including them, matches byte for byte.
    var expected: Listing = .{};
    defer expected.deinit();
    for (session_listing.names.items) |path| {
        if (std.mem.eql(u8, std.fs.path.basename(path), history.layout.files.incomplete)) {
            const cut = std.mem.lastIndexOfScalar(u8, path, std.fs.path.sep).?;
            try expected.names.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ path[0..cut], std.fs.path.sep, history.layout.files.kept }));
            continue;
        }
        try expected.names.append(allocator, try allocator.dupe(u8, path));
    }
    try sorted(&expected);
    var moved: Listing = .{};
    defer moved.deinit();
    for (kept.names.items) |path| {
        if (std.mem.indexOfScalar(u8, path, std.fs.path.sep) == null) continue;
        try moved.names.append(allocator, try allocator.dupe(u8, path));
    }
    try sorted(&moved);
    try expectSameListing(&expected, &moved);

    // The recorded bytes themselves are unchanged.
    var buffer: [64]u8 = undefined;
    var log_path: [128]u8 = undefined;
    const log = try std.fmt.bufPrint(&log_path, "{s}/log/events-0", .{id_name});
    try std.testing.expectEqualStrings("recorded log bytes 0123456789", try f.kept.dir.readFile(io, log, &buffer));
    var object_path: [128]u8 = undefined;
    const object = try std.fmt.bufPrint(&object_path, "{s}/objects/obj-a", .{id_name});
    try std.testing.expectEqualStrings("object bytes abcdef", try f.kept.dir.readFile(io, object, &buffer));
}
