//! One session's directory in a history root, from its first byte to its
//! last. Its lease `ID.lease` is made and taken in the root first, it is
//! made as `ID.creating`, and only then is it moved to `ID`, so no sweep
//! ever finds an `ID` whose owner has not held the lease. The lease stays
//! where it was made. The session ends by being deleted, or, when kept, by
//! moving under the kept root or staying put behind a pointer file.
const std = @import("std");
const layout = @import("layout.zig");
const lock = @import("lock.zig");
const name = @import("name.zig");
const owner = @import("owner.zig");
const metadata = @import("metadata.zig");
const remove = @import("remove.zig");
const move = @import("move/root.zig");
const rename_file = @import("rename.zig");
const gates = @import("gates.zig");
const Base = @import("base.zig").Base;

/// How a closed session left its root.
pub const Outcome = enum { deleted, left, moved, pointed };

/// Where a kept session goes at exit: under the kept root when a rename
/// can take it there, or nowhere, behind a pointer file.
pub const Placement = enum { move, stay };

pub const Options = struct {
    /// The session's name; a fresh random one by default.
    id: ?name.Id = null,
    /// The owner record; this process's own by default.
    owner: ?owner.Record = null,
    move_probe: ?move.probe.Probe = null,
};

pub const Session = struct {
    base: *const Base,
    id: name.Id,
    dir: std.Io.Dir,
    /// Open, and locked, for as long as the session lives.
    lock: std.Io.File,
    kept: bool = false,
    move_probe: ?move.probe.Probe = null,

    /// Make a session in `base`. `IdTaken` when the name is in use.
    pub fn create(base: *const Base, options: Options) !Session {
        if (base.role != .cache) return error.WrongRole;
        const io = base.io;
        const id = options.id orelse name.newId(io);
        if (!name.isId(&id)) return error.BadName;
        var gate = try base.gate(.exclusive);
        defer gate.release();
        if (taken(base, &id)) return error.IdTaken;
        // The lease is the claim on the name. It is made first, where it
        // stays, so no sweep ever finds a directory of `ID` whose owner
        // has not held it.
        const held = lock.create(io, base.dir, &id) catch |err| switch (err) {
            error.PathAlreadyExists => return error.IdTaken,
            else => return err,
        };
        var buffer: name.Buffer = undefined;
        const draft = name.creating(&buffer, &id);
        base.dir.createDir(io, draft, layout.directory_permissions) catch |err| {
            try lock.retire(io, base.dir, &id, held);
            return if (err == error.PathAlreadyExists) error.IdTaken else err;
        };
        // Failed initialization leaves a draft for a marked, leased sweep.
        // Never recursively delete a partially initialized directory.
        errdefer held.close(io);
        try prepare(base, draft, options.owner);
        try rename(base, draft, &id, options.move_probe, &.{ gate.file, held });
        return .{ .base = base, .id = id, .dir = try base.dir.openDir(io, &id, .{ .iterate = true }), .lock = held, .move_probe = options.move_probe };
    }

    /// Take over a session that is in `base` and that nothing holds, as a
    /// kept one is after its owner has gone. `Locked` when it is live.
    pub fn reopen(base: *const Base, id: name.Id) !Session {
        return reopenWithSettlement(base, id, true);
    }

    /// Hold the lease without settling metadata. The caller must admit the
    /// recorded root and images before invoking rename recovery.
    pub fn reopenUnsettled(base: *const Base, id: name.Id) !Session {
        return reopenWithSettlement(base, id, false);
    }

    fn reopenWithSettlement(base: *const Base, id: name.Id, settle: bool) !Session {
        if (!name.isId(&id)) return error.BadName;
        const io = base.io;
        var gate = try base.gate(.shared);
        defer gate.release();
        try base.owns(&id);
        if (move.intent.pending(io, base.dir, &id)) return error.Moving;
        if (try move.tree.moving(io, base.dir, &id)) return error.Moving;
        var dir = try base.dir.openDir(io, &id, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);
        var buffer: [owner.max_bytes]u8 = undefined;
        _ = try owner.read(io, dir, &buffer);
        const held = (try lock.take(io, base.dir, &id)) orelse return error.Locked;
        errdefer held.close(io);
        if (settle) try rename_file.settle(io, dir);
        return .{ .base = base, .id = id, .dir = dir, .lock = held, .kept = present(io, dir, layout.files.kept) };
    }

    /// Mark the session kept. The directory stays where it is while live.
    pub fn keep(self: *Session) !void {
        try metadata.ensure(self.base.io, self.dir, layout.files.kept, "");
        self.kept = true;
    }

    /// End the session, with every file inside it already closed. An
    /// ephemeral session is deleted. A kept one moves under `kept_root`
    /// when a rename can take it there, and otherwise stays behind a
    /// pointer file; nothing is ever copied.
    pub fn close(self: *Session, kept_root: ?*const Base, placement: Placement) !Outcome {
        const io = self.base.io;
        if (self.kept) return finishKept(self, kept_root, placement);
        self.dir.close(io);
        remove.withHeld(self.base, &self.id, .{ .move_probe = self.move_probe }, self.lock) catch |err| switch (err) {
            error.NotFound => {},
            else => return err,
        };
        return .deleted;
    }

    fn finishKept(self: *Session, kept_root: ?*const Base, placement: Placement) !Outcome {
        const io = self.base.io;
        var gate = try gates.Pair.acquire(self.base, kept_root);
        defer gate.release();
        if (kept_root) |target| {
            if (target.role != .kept) return error.WrongRole;
        }
        try rename_file.settle(io, self.dir);
        self.dir.deleteFile(io, layout.files.incomplete) catch |err| if (err != error.FileNotFound) return err;
        self.dir.close(io);
        var held: ?std.Io.File = self.lock;
        defer if (held) |lease| lease.close(io);
        const target = kept_root orelse return .left;
        if (target == self.base) return .left;
        try self.base.owns(&self.id);
        if (placement == .move and try arrive(self, target, &gate)) {
            held = null;
            try lock.retire(io, self.base.dir, &self.id, self.lock);
            return .moved;
        }
        try point(self.base, target, &self.id);
        return .pointed;
    }
};

/// Move the closed session under `target`, where it has a lease before it
/// arrives. False when no rename can take it there; `PathAlreadyExists`
/// when the name is taken there, by a lease or by anything else.
fn arrive(self: *Session, target: *const Base, gate: *const gates.Pair) !bool {
    const io = self.base.io;
    var buffer: [move.tree.limits.receipt]u8 = undefined;
    const receipt = std.fmt.bufPrint(&buffer, layout.moves.keep ++ "{s}\n", .{target.path}) catch return false;
    const arrived = try lock.create(io, target.dir, &self.id);
    const authorities: []const std.Io.File = if (gate.second) |second| &[_]std.Io.File{ gate.first.file, second.file, self.lock, arrived } else &[_]std.Io.File{ gate.first.file, self.lock, arrived };
    move.dispatch.directory(.{ .source = self.base, .target = target, .authorities = authorities }, &self.id, &self.id, receipt, self.move_probe) catch |err| {
        // A move that began is carried on by recovery, under this lease.
        const began = move.tree.moving(io, self.base.dir, &self.id) catch true;
        if (began) arrived.close(io) else try lock.retire(io, target.dir, &self.id, arrived);
        if (began) return err;
        return switch (err) {
            error.CrossDevice => false,
            else => err,
        };
    };
    arrived.close(io);
    return true;
}

/// Open the draft directory and write what marks it.
fn prepare(base: *const Base, draft: []const u8, record: ?owner.Record) !void {
    const io = base.io;
    var dir = try base.dir.openDir(io, draft, .{});
    defer dir.close(io);
    var self: owner.Self = .{};
    try owner.write(io, dir, record orelse self.record(io));
    try metadata.ensure(io, dir, layout.files.incomplete, "");
    for (layout.spaces) |space| try dir.createDir(io, @tagName(space), layout.directory_permissions);
}

/// Give the draft its final name. The lease is not in it and does not move.
fn rename(base: *const Base, from: []const u8, to: []const u8, probe: ?move.probe.Probe, authorities: []const std.Io.File) !void {
    try base.owns(from);
    move.dispatch.directory(.{ .source = base, .target = base, .authorities = authorities }, from, to, layout.moves.publish, probe) catch |err| switch (err) {
        error.PathAlreadyExists => return error.IdTaken,
        else => return err,
    };
}

/// Leave `ID.pointer` in the kept root, naming where the session stayed.
fn point(from: *const Base, kept_root: *const Base, id: *const name.Id) !void {
    var buffer: name.Buffer = undefined;
    const path = try from.pathOf(from.allocator, id);
    defer from.allocator.free(path);
    const file = try kept_root.dir.createFile(kept_root.io, name.pointer(&buffer, id), .{ .exclusive = true });
    defer file.close(kept_root.io);
    try file.writeStreamingAll(kept_root.io, path);
    try file.sync(kept_root.io);
}

fn taken(base: *const Base, id: *const name.Id) bool {
    if (move.intent.pending(base.io, base.dir, id)) return true;
    var buffer: name.Buffer = undefined;
    for ([_][]const u8{ id, name.trash(&buffer, id) }) |entry| {
        if (present(base.io, base.dir, entry)) return true;
    }
    return present(base.io, base.dir, name.lease(&buffer, id));
}

fn present(io: std.Io, dir: std.Io.Dir, entry: []const u8) bool {
    _ = dir.statFile(io, entry, .{ .follow_symlinks = false }) catch return false;
    return true;
}
