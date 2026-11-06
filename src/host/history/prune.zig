//! The host's share of the history budget's relief order: the orphans
//! step reclaims the object files no committed record names. The frames
//! step belongs to the ephemeral frame store and the checkpoint-thinning
//! step to the session's checkpoint controller. A live session supplies
//! extra references for object writes its next committed batch will name.
//! Without those references, pruning requires a quiescent session.

const std = @import("std");
const storage = @import("storage.zig");

/// The bridge that names the referenced objects. The session library
/// walks the committed frames; the applications wire it here, the same
/// callback shape the recorder's bind uses.
pub const Referrer = struct {
    /// Adds every object name the store's committed log names into
    /// `names`. The names' keys are allocated with `allocator`; the
    /// prune frees them.
    collect: *const Collect,
    /// Adds only the checkpoint pictures' object names. Those objects
    /// are protected on their own: the sweep unions them into the
    /// referenced set even when `collect` missed one, and the relief
    /// report counts them. Null for a history without pictures.
    pictures: ?*const Collect = null,
    /// Runtime objects not yet named by a committed log. The application
    /// owns the context; collected keys follow the same allocation contract.
    extra: ?Extra = null,

    pub const Extra = struct {
        context: *anyopaque,
        collect: *const fn (*anyopaque, std.mem.Allocator, *std.StringHashMap(void)) anyerror!void,
    };

    pub fn collectAll(self: Referrer, store: storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) !void {
        try self.collect(store, allocator, names);
        if (self.extra) |extra| try extra.collect(extra.context, allocator, names);
    }
};

pub const Collect = fn (store: storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void;

fn freeNames(allocator: std.mem.Allocator, names: *std.StringHashMap(void)) void {
    var it = names.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    names.deinit();
}

pub const Report = struct {
    /// Object files the objects space dropped.
    orphans: usize = 0,
    /// Bytes the orphan files held.
    orphan_bytes: u64 = 0,
};

/// Reclaims the object files the committed log does not name. A log the
/// referrer cannot fully read is a hard error, so the sweep never
/// deletes past an unreadable segment.
pub fn orphans(store: storage.Store, allocator: std.mem.Allocator, referrer: Referrer) !Report {
    var names = std.StringHashMap(void).init(allocator);
    defer freeNames(allocator, &names);
    try referrer.collectAll(store, allocator, &names);
    if (referrer.pictures) |pictures| try pictures(store, allocator, &names);

    var sweep = Sweep{ .store = store, .names = &names };
    const visitor: storage.Visitor = .{ .context = &sweep, .visit = &Sweep.visit };
    if (store.vtable.sweep) |guarded|
        try guarded(store.context, allocator, &names, visitor)
    else
        try store.vtable.list(store.context, .objects, visitor);
    return .{ .orphans = sweep.count, .orphan_bytes = sweep.bytes };
}

const Sweep = struct {
    store: storage.Store,
    names: *const std.StringHashMap(void),
    count: usize = 0,
    bytes: u64 = 0,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        const self: *Sweep = @ptrCast(@alignCast(context));
        if (self.names.contains(name)) return;
        // Pack files hold the page and blob objects; the pack store owns them.
        if (std.mem.startsWith(u8, name, "pack-")) return;
        try self.store.vtable.remove(self.store.context, .objects, name);
        self.count += 1;
        self.bytes += size;
    }
};

/// The frames step of the relief order. The frames space holds only the
/// frame cache: its files are delete-on-close (the open path unlinks the
/// name on POSIX and opens delete-on-close on Windows), so no record the
/// committed log carries names one, and a file still listed there is a
/// cache entry no handle holds or a leftover the close path never got to
/// remove. The sweep drops every file it lists and reports what it
/// reclaimed; a removal that fails is a hard error, so relief never
/// claims bytes it did not get back.
pub const FrameReport = struct {
    /// Frame-cache files the frames space dropped.
    frames: usize = 0,
    /// Bytes the dropped files held.
    frame_bytes: u64 = 0,
};

pub fn frames(store: storage.Store) !FrameReport {
    var sweep = FrameSweep{ .store = store };
    try store.vtable.list(store.context, .frames, .{ .context = &sweep, .visit = &FrameSweep.visit });
    return .{ .frames = sweep.count, .frame_bytes = sweep.bytes };
}

const FrameSweep = struct {
    store: storage.Store,
    count: usize = 0,
    bytes: u64 = 0,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        const self: *FrameSweep = @ptrCast(@alignCast(context));
        try self.store.vtable.remove(self.store.context, .frames, name);
        self.count += 1;
        self.bytes += size;
    }
};

/// What one pass of the relief order reclaimed, and what it protected.
pub const Relief = struct {
    orphans: usize = 0,
    orphan_bytes: u64 = 0,
    frames: usize = 0,
    frame_bytes: u64 = 0,
    /// Checkpoint picture objects still in the objects space.
    pictures_kept: usize = 0,
    /// Pictures the log names whose object is not there.
    pictures_missing: usize = 0,

    /// Whether every picture the log names is still there. Relief
    /// reports a lost picture and cannot repair one, so a caller that
    /// cares checks this and treats the history as damaged when false.
    pub fn intact(self: Relief) bool {
        return self.pictures_missing == 0;
    }
};

/// The host's steps of the relief order, in order: the orphans, then the
/// frame cache. Checkpoint pictures are committed objects, so neither
/// step can reach them; the pass proves it by counting them after the
/// sweeps and reporting any the log names but the space lost.
pub fn relief(store: storage.Store, allocator: std.mem.Allocator, referrer: Referrer) !Relief {
    var pinned = std.StringHashMap(void).init(allocator);
    defer freeNames(allocator, &pinned);
    if (referrer.pictures) |pictures| try pictures(store, allocator, &pinned);
    const dropped = try orphans(store, allocator, referrer);
    const cache = try frames(store);
    var check = PictureCount{ .pinned = &pinned };
    try store.vtable.list(store.context, .objects, .{ .context = &check, .visit = &PictureCount.visit });
    return .{
        .orphans = dropped.orphans,
        .orphan_bytes = dropped.orphan_bytes,
        .frames = cache.frames,
        .frame_bytes = cache.frame_bytes,
        .pictures_kept = check.kept,
        .pictures_missing = pinned.count() - check.kept,
    };
}

const PictureCount = struct {
    pinned: *const std.StringHashMap(void),
    kept: usize = 0,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *PictureCount = @ptrCast(@alignCast(context));
        if (self.pinned.contains(name)) self.kept += 1;
    }
};
