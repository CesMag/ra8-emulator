//! Publishes new loose objects atomically and verifies existing loose bytes
//! before reuse. Linux synchronizes the containing directory after publication.
//! Windows uses a no-replace write-through move, then flushes the final file's
//! data and metadata. Neither platform bypasses the storage device's contract.
const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8_host").history;
const storage = history.storage;
const reuse = @import("ra8_session").history_object_reuse;

pub const prefix = "object-put-";
pub const max_attempts = 16;

pub const DirSync = struct {
    context: *anyopaque,
    sync: *const fn (*anyopaque) anyerror!void,
};

pub const TempGen = struct {
    context: *anyopaque,
    next: *const fn (*anyopaque, *[history.name.limits.component]u8) anyerror![]const u8,
};

pub const Options = struct {
    dir_sync: ?DirSync = null,
    temp_gen: ?TempGen = null,
    probe: ?history.move.probe.Probe = null,
};

pub fn putSession(gpa: std.mem.Allocator, session: *history.session.Session, name: []const u8, kind: reuse.Kind, bytes: []const u8) !void {
    const store = storage.Store.from(session);
    var syncer: SessionDirSync = .{ .session = session };
    var gen: RandomTemp = .{ .io = session.base.io };
    var check: SessionIdentity = .{ .session = session };
    return putFull(gpa, store, name, kind, bytes, .{
        .dir_sync = if (builtin.os.tag == .linux) .{ .context = &syncer, .sync = &SessionDirSync.sync } else null,
        .temp_gen = .{ .context = &gen, .next = &RandomTemp.next },
        .probe = session.move_probe,
    }, &check);
}

pub fn put(gpa: std.mem.Allocator, store: storage.Store, name: []const u8, kind: reuse.Kind, bytes: []const u8) !void {
    return putWith(gpa, store, name, kind, bytes, .{});
}

pub fn putWith(gpa: std.mem.Allocator, store: storage.Store, name: []const u8, kind: reuse.Kind, bytes: []const u8, options: Options) !void {
    return putFull(gpa, store, name, kind, bytes, options, null);
}

fn putFull(gpa: std.mem.Allocator, store: storage.Store, name: []const u8, kind: reuse.Kind, bytes: []const u8, options: Options, check: ?*SessionIdentity) !void {
    _ = try history.paths.leaf(.objects, name);
    var temp_buf: [history.name.limits.component]u8 = undefined;
    var opened = try createTemp(store, name, &temp_buf, options.temp_gen, check);
    defer closeOnce(&opened.file);
    writeAndSync(&opened.file, bytes) catch |err| {
        try cleanupTemp(store, opened.name, check);
        return err;
    };
    if (options.probe) |probe| reachObjectsProbe(probe, .native_before, check, opened.name, name) catch |err| {
        try cleanupTemp(store, opened.name, check);
        return err;
    };
    const publish = if (check) |c|
        storage.publishOwned(c.session, opened.name, name, opened.file.?)
    else
        store.vtable.rename(store.context, .objects, opened.name, name);
    publish catch |err| switch (err) {
        error.PathAlreadyExists => {
            const clean_res = cleanupTemp(store, opened.name, check);
            const reuse_res = existingWith(gpa, store, name, kind, bytes, options.dir_sync);
            try reuse_res;
            try clean_res;
            return;
        },
        else => {
            // A fallback may have persisted a rename intent or published a
            // second link. Cleanup must preserve those recovery inputs.
            try cleanupTemp(store, opened.name, check);
            return err;
        },
    };
    if (options.probe) |probe| try reachObjectsProbe(probe, .native_moved, check, opened.name, name);
    // Read the published name immediately, including after a concurrent move.
    // On Windows the subsequent file sync flushes post-rename metadata too.
    try existingWith(gpa, store, name, kind, bytes, options.dir_sync);
}

pub fn existing(gpa: std.mem.Allocator, store: storage.Store, name: []const u8, kind: reuse.Kind, bytes: []const u8) !void {
    return existingWith(gpa, store, name, kind, bytes, null);
}

pub fn existingWith(gpa: std.mem.Allocator, store: storage.Store, name: []const u8, kind: reuse.Kind, bytes: []const u8, dir_sync: ?DirSync) !void {
    const file = try store.vtable.open(store.context, .objects, name, .update);
    defer file.vtable.close(file.context);
    if (try file.vtable.length(file.context) != bytes.len) return error.ObjectConflict;
    if (kind == .data) {
        var buffer: [4096]u8 = undefined;
        var at: usize = 0;
        while (at < bytes.len) {
            const part = buffer[0..@min(buffer.len, bytes.len - at)];
            try readExact(file, at, part);
            if (!std.mem.eql(u8, part, bytes[at..][0..part.len])) return error.ObjectConflict;
            at += part.len;
        }
    } else {
        // Metadata is bounded by the incoming capture, not an on-disk count.
        const old = try gpa.alloc(u8, bytes.len);
        defer gpa.free(old);
        try readExact(file, 0, old);
        try reuse.validate(gpa, kind, old, bytes);
    }
    // A previous put may have written all bytes or renamed before syncing.
    try file.vtable.sync(file.context);
    if (dir_sync) |ds| try ds.sync(ds.context);
}

const OpenedTemp = struct {
    name: []const u8,
    file: ?storage.ByteFile,
};

fn createTemp(store: storage.Store, final: []const u8, buf: *[history.name.limits.component]u8, temp_gen: ?TempGen, check: ?*SessionIdentity) !OpenedTemp {
    var fallback: FallbackTemp = .{};
    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const candidate = if (temp_gen) |gen|
            try gen.next(gen.context, buf)
        else
            try fallback.next(buf);
        _ = try history.paths.leaf(.objects, candidate);
        if (!std.mem.startsWith(u8, candidate, prefix) or std.ascii.eqlIgnoreCase(candidate, final)) return error.BadName;
        const file = store.vtable.open(store.context, .objects, candidate, .create) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        if (check) |c| c.record(candidate, file) catch |err| {
            file.vtable.close(file.context);
            // No identity was established. Preserve the entry for diagnosis.
            return err;
        };
        return .{ .name = candidate, .file = file };
    }
    return error.PathAlreadyExists;
}

fn writeAndSync(file_slot: *?storage.ByteFile, bytes: []const u8) !void {
    const file = file_slot.*.?;
    try file.vtable.write(file.context, 0, bytes);
    try file.vtable.sync(file.context);
}

fn closeOnce(file_slot: *?storage.ByteFile) void {
    if (file_slot.*) |file| {
        file_slot.* = null;
        file.vtable.close(file.context);
    }
}

fn cleanupTemp(store: storage.Store, temp_name: []const u8, check: ?*SessionIdentity) !void {
    if (check) |c| return storage.removeOwned(c.session, temp_name, c.held.?);
    try store.vtable.remove(store.context, .objects, temp_name);
}

fn reachObjectsProbe(probe: history.move.probe.Probe, phase: history.move.probe.Phase, check: ?*SessionIdentity, from: []const u8, to: []const u8) !void {
    if (check) |c| {
        var dir = try history.paths.area(c.session, .objects);
        defer dir.close(c.session.base.io);
        try history.move.probe.reach(probe, phase, dir, from, dir, to);
        return;
    }
    try history.move.probe.reach(probe, phase, undefined, from, undefined, to);
}

const SessionDirSync = struct {
    session: *const history.session.Session,

    fn sync(ctx: *anyopaque) !void {
        const self: *SessionDirSync = @ptrCast(@alignCast(ctx));
        var dir = try history.paths.area(self.session, .objects);
        defer dir.close(self.session.base.io);
        try history.move.file.syncDir(dir);
    }
};

const RandomTemp = struct {
    io: std.Io,

    fn next(ctx: *anyopaque, buf: *[history.name.limits.component]u8) ![]const u8 {
        const self: *RandomTemp = @ptrCast(@alignCast(ctx));
        const id = history.name.newId(self.io);
        return std.fmt.bufPrint(buf, prefix ++ "{s}", .{&id});
    }
};

const FallbackTemp = struct {
    counter: u64 = 0,

    fn next(self: *FallbackTemp, buf: *[history.name.limits.component]u8) ![]const u8 {
        self.counter +%= 1;
        const mix = std.hash.Wyhash.hash(self.counter, std.mem.asBytes(&self));
        return std.fmt.bufPrint(buf, prefix ++ "{x:0>16}{x:0>16}", .{ mix, self.counter });
    }
};

const SessionIdentity = struct {
    session: *history.session.Session,
    held: ?storage.ByteFile = null,

    fn record(self: *SessionIdentity, temp_name: []const u8, byte: storage.ByteFile) !void {
        self.held = byte;
        try storage.verifyOwned(self.session, temp_name, byte);
    }
};

fn readExact(file: storage.ByteFile, offset: u64, bytes: []u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const count = try file.vtable.read(file.context, offset + at, bytes[at..]);
        if (count == 0) return error.ObjectConflict;
        if (count > bytes.len - at) return error.ObjectConflict;
        at += count;
    }
}
