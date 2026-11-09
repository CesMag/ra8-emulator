//! Which objects a disk history's committed checkpoints are made of: the
//! page, blob and picture objects their manifests name, and the live set
//! the pack compaction keeps. Applications bind the log walk in.
const std = @import("std");
const history = @import("ra8_host").history;
const session_manifest = @import("ra8_session").history_manifest;
const session_object_id = @import("ra8_session").history_object_id;
const session_compaction = @import("ra8_session").history_compaction;
const object_read = @import("object_read.zig");
const pack_store = @import("pack_store.zig");

pub const Collect = history.prune.Collect;

/// Names the page, blob and picture objects every checkpoint's manifest
/// holds, so the sweep keeps what a kept checkpoint is made of. A
/// checkpoint without a manifest (a history from before they were kept)
/// names nothing more.
pub fn addManifestObjects(store: history.storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) !void {
    // Immutable startup media belongs to the root, even when checkpoint zero
    // has been thinned or the retained line starts later.
    const root_bytes = @import("object_read.zig").readTopRoot(store, allocator) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (root_bytes) |bytes| {
        defer allocator.free(bytes);
        const root = try @import("ra8_session").history_root.decode(bytes);
        if (root.media) |id| try addObject(allocator, names, .{ .bytes = id });
    }
    var held: std.ArrayList([]const u8) = .empty;
    defer held.deinit(allocator);
    var keys = names.keyIterator();
    while (keys.next()) |key| try held.append(allocator, key.*);
    for (held.items) |hex| {
        const object = session_object_id.ObjectId.fromHex(hex) catch continue;
        const manifest_name = session_manifest.objectName(object.bytes);
        const bytes = object_read.read(store, allocator, &manifest_name) catch continue;
        defer allocator.free(bytes);
        var decoded = session_manifest.decode(allocator, bytes) catch continue;
        defer decoded.deinit(allocator);
        var last_page: ?session_object_id.ObjectId = null;
        for (decoded.pages) |page| {
            if (last_page) |prev| if (prev.eql(page.object)) continue;
            last_page = page.object;
            try addObject(allocator, names, page.object);
        }
        for (decoded.blobs) |blob| try addObject(allocator, names, blob.object);
        if (decoded.picture) |pic| try addObject(allocator, names, pic);
    }
}

fn addObject(allocator: std.mem.Allocator, names: *std.StringHashMap(void), object: session_object_id.ObjectId) !void {
    var name: [session_object_id.ObjectId.hex_len]u8 = undefined;
    object.formatHex(&name);
    if (names.contains(&name)) return;
    const key = try allocator.dupe(u8, &name);
    errdefer allocator.free(key);
    try names.put(key, {});
}

/// Compacts `packs` against every object the committed log's manifests
/// reach, on every line.
pub fn compactPacks(store: history.storage.Store, allocator: std.mem.Allocator, packs: *pack_store.PackStore, collect: *const history.prune.Collect) !pack_store.Report {
    return compactPacksWithReferrer(store, allocator, packs, .{ .collect = collect });
}

pub fn compactPacksWithReferrer(store: history.storage.Store, allocator: std.mem.Allocator, packs: *pack_store.PackStore, referrer: history.prune.Referrer) !pack_store.Report {
    var names = std.StringHashMap(void).init(allocator);
    defer freeNames(allocator, &names);
    try referrer.collectAll(store, allocator, &names);
    var live = session_compaction.LiveSet.init(allocator);
    defer live.deinit();
    var keys = names.keyIterator();
    while (keys.next()) |key| {
        const id = session_object_id.ObjectId.fromHex(key.*) catch continue;
        try live.put(id.bytes, {});
    }
    return packs.compact(&live);
}

fn freeNames(allocator: std.mem.Allocator, names: *std.StringHashMap(void)) void {
    var it = names.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    names.deinit();
}
