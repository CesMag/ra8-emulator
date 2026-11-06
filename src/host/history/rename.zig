//! One immutable closed-payload rename intent, resolved by exact identities.
const std = @import("std");
const h = @import("root.zig");
const file = h.move.file;
pub const limits = struct {
    pub const note = 4096;
};
pub const Note = struct { version: u32, space: h.layout.Space, from: []const u8, to: []const u8, top: file.State, area: file.State, source: file.State };
pub const Pending = struct {
    parsed: std.json.Parsed(Note),
    inode: std.Io.File.INode,

    pub fn deinit(self: *Pending) void {
        self.parsed.deinit();
    }
};

pub fn begin(io: std.Io, top: std.Io.Dir, dir: std.Io.Dir, space: h.layout.Space, from: []const u8, to: []const u8) !void {
    _ = try h.paths.leaf(space, from);
    _ = try h.paths.leaf(space, to);
    const source = try file.state(dir, from);
    if (source.kind != .file or source.links != 1) return error.UnexpectedLinkCount;
    const note: Note = .{ .version = 1, .space = space, .from = from, .to = to, .top = try file.here(top), .area = try file.here(dir), .source = source };
    const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, note, .{});
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len > limits.note) return error.BadMetadata;
    const held = try top.createFile(io, h.layout.files.renaming, .{ .read = true, .exclusive = true, .resolve_beneath = true });
    defer held.close(io);
    try h.metadata.ordinary(try held.stat(io));
    try held.writeStreamingAll(io, bytes);
    try held.sync(io);
    try file.syncDir(top);
}
pub fn linked(io: std.Io, top: std.Io.Dir, dir: std.Io.Dir, space: h.layout.Space, from: []const u8, to: []const u8) !void {
    return linkedProbed(io, top, dir, space, from, to, null);
}
pub fn linkedProbed(io: std.Io, top: std.Io.Dir, dir: std.Io.Dir, space: h.layout.Space, from: []const u8, to: []const u8, probe: ?h.move.probe.Probe) !void {
    try settle(io, top);
    try begin(io, top, dir, space, from, to);
    const inode = (try top.statFile(io, h.layout.files.renaming, .{ .follow_symlinks = false })).inode;
    file.carryProbed(dir, from, dir, to, probe) catch |err| {
        switch (err) {
            error.PathAlreadyExists, error.UnexpectedKind, error.UnexpectedLinkCount => try erase(io, top, inode),
            else => {},
        }
        return err;
    };
    try erase(io, top, inode);
}
/// Inspect an intent without settling it. The returned text is owned.
pub fn pending(io: std.Io, top: std.Io.Dir) !?Pending {
    const held = h.metadata.open(io, top, h.layout.files.renaming, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer held.close(io);
    const stat = try held.stat(io);
    if (stat.size == 0 or stat.size > limits.note) return error.BadMetadata;
    var bytes: [limits.note]u8 = undefined;
    const count = try held.readPositionalAll(io, bytes[0..@intCast(stat.size)], 0);
    if (count != stat.size) return error.BadMetadata;
    const parsed = std.json.parseFromSlice(Note, std.heap.page_allocator, bytes[0..count], .{ .allocate = .alloc_always }) catch return error.BadMetadata;
    return .{ .parsed = parsed, .inode = stat.inode };
}

pub fn settle(io: std.Io, top: std.Io.Dir) !void {
    var held = (try pending(io, top)) orelse return;
    defer held.deinit();
    const state = try inspect(io, top, held.parsed.value);
    defer state.dir.close(io);
    const note = held.parsed.value;
    if (state.source and state.target) try file.finish(state.dir, note.from, state.dir, note.to);
    try erase(io, top, held.inode);
}

/// Pin only the extant recovery inputs of one validated intent. The caller
/// holds the lifecycle gate until its object sweep finishes. Settlement on
/// retry/reopen clears the intent; any leftover source then becomes garbage.
pub fn protect(io: std.Io, top: std.Io.Dir, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) !void {
    var held = (try pending(io, top)) orelse return;
    defer held.deinit();
    const note = held.parsed.value;
    const state = try inspect(io, top, note);
    defer state.dir.close(io);
    if (note.space != .objects) return;
    if (state.source) try pin(allocator, names, note.from);
    if (state.target) try pin(allocator, names, note.to);
}

fn pin(allocator: std.mem.Allocator, names: *std.StringHashMap(void), text: []const u8) !void {
    if (names.contains(text)) return;
    const key = try allocator.dupe(u8, text);
    errdefer allocator.free(key);
    try names.put(key, {});
}

const Inspected = struct { dir: std.Io.Dir, source: bool, target: bool };

/// Inspection has no namespace effects. Both settlement and sweeping must
/// refuse the same incomplete, replaced or wrongly linked recovery inputs.
fn inspect(io: std.Io, top: std.Io.Dir, note: Note) !Inspected {
    if (note.version != 1 or note.source.kind != .file or note.source.links != 1) return error.BadMetadata;
    _ = try h.paths.leaf(note.space, note.from);
    _ = try h.paths.leaf(note.space, note.to);
    if (!note.top.same(try file.here(top))) return error.IdentityConflict;
    var dir = try top.openDir(io, if (note.space == .top) "." else @tagName(note.space), .{ .iterate = true, .follow_symlinks = false });
    errdefer dir.close(io);
    if (!note.area.same(try file.here(dir))) return error.IdentityConflict;
    const source = file.state(dir, note.from) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const target = file.state(dir, note.to) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (source) |old| {
        if (!note.source.same(old)) return error.IdentityConflict;
        if (target) |new| {
            if (!note.source.same(new)) return error.IdentityConflict;
            if (old.links != 2 or new.links != 2) return error.UnexpectedLinkCount;
        } else if (old.links != 1) return error.UnexpectedLinkCount;
    } else {
        const new = target orelse return error.IdentityConflict;
        if (!note.source.same(new) or new.links != 1) return error.IdentityConflict;
    }
    return .{ .dir = dir, .source = source != null, .target = target != null };
}
fn erase(io: std.Io, top: std.Io.Dir, inode: std.Io.File.INode) !void {
    const stat = try top.statFile(io, h.layout.files.renaming, .{ .follow_symlinks = false });
    try h.metadata.ordinary(stat);
    if (stat.inode != inode) return error.IdentityConflict;
    try top.deleteFile(io, h.layout.files.renaming);
    try file.syncDir(top);
}
