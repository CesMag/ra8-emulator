//! The application-side bridge from a host history session to the
//! harness's open options (RA8EMU-1196): the log storage and the object
//! space the persistent recorder writes through. The session library
//! defines the callback shapes and never opens a host file; the
//! applications own the history root and bridge it here, next to the
//! served sessions that use it. The bind holds the session's lease for
//! the run and deletes the ephemeral session on close, so no history
//! byte lands before the lifecycle is wired.
const std = @import("std");
const history = @import("ra8_host").history;
const session_recorder = @import("ra8_session").history_recorder;
const session_refs = @import("ra8_session").history_refs;
const session_branch = @import("ra8_session").history_branch;
const session_fork = @import("ra8_session").history_fork_router;
const session_fork_types = @import("ra8_session").fork;
const session_branches_codec = @import("ra8_session").history_branches_codec;
const branches_recover = @import("ra8_session").history_branches_recover;
const history_root = @import("ra8_session").history_root;
const history_segments = @import("history_segments.zig");
const object_read = @import("object_read.zig");
const pack_store = @import("pack_store.zig");
const history_live = @import("history_live.zig");
const session_compaction = @import("ra8_session").history_compaction;
const session_manifest = @import("ra8_session").history_manifest;
const session_object_id = @import("ra8_session").history_object_id;

/// Formats the segment leaf name for a given branch and segment index.
pub fn segmentName(buf: []u8, branch: u32, seg: u32) ![]const u8 {
    if (branch == 0 and seg == 0) return "events-0";
    return std.fmt.bufPrint(buf, "events-{d}-{d}", .{ branch, seg });
}

/// The first log segment; later segments number upward.
const log_leaf = "events-0";
pub const Bind = struct {
    gpa: std.mem.Allocator,
    base: history.base.Base,
    session: history.session.Session,
    log: history.storage.ByteFile,
    sink: *LogSink,
    /// The shapes the harness's open options take. Both point into this
    /// bind, which stays put until close.
    storage: session_recorder.Storage,
    objects: session_recorder.Objects,
    /// The pack store the checkpoint engine's page and blob objects go to.
    packs: *pack_store.PackStore = undefined,
    /// The disk budget the recorder checks before every commit and
    /// checkpoint: this history's share of the volume and a fresh
    /// free-space read per check.
    disk: ?session_recorder.Budget = null,
    watch: ?*VolumeWatch = null,
    /// The checkpoints partition's bytes, what the cadence projection
    /// keeps the checkpoint objects within.
    checkpoint_cap: u64 = 0,
    io: std.Io = undefined,
    graph: session_branch.BranchGraph = undefined,
    router: session_fork.ForkRouter = undefined,
    graph_sink: session_fork_types.GraphSink = undefined,
    root: ?history_root.Root = null,
    /// Owns every slice borrowed by a decoded root until the bind closes.
    root_bytes: ?[]u8 = null,
    media_bytes: ?[]u8 = null,
    /// Set when the session stopped recording into this history (a
    /// different image loaded): close leaves its branches.bin as it was,
    /// since the in-memory graph then describes the new program.
    detached: bool = false,
    /// Set when this bind took over a session an earlier run recorded.
    reopened: bool = false,

    /// Open a history root at `path`, made and marked when it is new,
    /// and make the run's session in it with the lease held.
    pub const Options = struct {
        /// An explicit session share cap in bytes, instead of the volume's
        /// computed share. The volume's free floor and the relief stay.
        cap: ?u64 = null,
        kept: bool = false,
        /// Take over this kept session instead of making a new one: its
        /// log, objects and caches are served again, and recording
        /// continues past the line's recorded end.
        reopen: ?history.name.Id = null,
        board_profile: ?[]const u8 = null,
        images: ?*@import("served_initial.zig").Images = null,
    };

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, opts: Options) !*Bind {
        const bind = try allocator.create(Bind);
        errdefer allocator.destroy(bind);
        bind.* = .{ .gpa = allocator, .base = undefined, .session = undefined, .log = undefined, .sink = undefined, .storage = undefined, .objects = undefined };
        bind.base = if (opts.reopen != null)
            try history.base.Base.existingConfigured(allocator, io, path, .cache, .{ .recover = false })
        else
            try history.base.Base.openConfigured(allocator, io, path, .cache, .{});
        errdefer bind.base.close();
        bind.session = if (opts.reopen) |id|
            try history.session.Session.reopenUnsettled(&bind.base, id)
        else
            try history.session.Session.create(&bind.base, .{});
        errdefer if (opts.reopen != null) {
            bind.session.dir.close(io);
            bind.session.lock.close(io);
        } else {
            _ = bind.session.close(null, .move) catch {};
        };
        errdefer if (bind.media_bytes) |bytes| allocator.free(bytes);
        errdefer if (bind.root_bytes) |bytes| allocator.free(bytes);
        try bind.readRoot(opts);
        if (opts.reopen != null) try history.rename.settle(io, bind.session.dir);
        if (opts.kept) {
            try bind.session.keep();
        }
        var candidates = try history.branches_file.readCandidates(io, bind.session.dir, allocator);
        defer candidates.deinit(allocator);
        // A reopened log may end in a commit a crash cut short: it is cut
        // off before anything reads the log or the recorder appends to it.
        if (opts.reopen != null) _ = try history_segments.repair(allocator, history.storage.Store.from(&bind.session));
        // The log is the last source: a graph rebuilt from its Branch
        // records when neither file decodes, recorded ends raised from it.
        const log_bytes = try history_segments.readAll(allocator, history.storage.Store.from(&bind.session));
        defer allocator.free(log_bytes);
        const rec = try branches_recover.recoverWithLog(allocator, candidates.current, candidates.temp, log_bytes);
        switch (rec.action) {
            .use_temp => history.branches_file.settle(io, bind.session.dir) catch {},
            else => history.branches_file.cleanupTemp(io, bind.session.dir),
        }
        bind.io = io;
        bind.graph = rec.graph;
        errdefer bind.graph.deinit();
        bind.router = session_fork.ForkRouter.init(allocator, &bind.graph);
        errdefer bind.router.deinit();
        bind.graph_sink = .{ .context = bind, .writeFn = &writeBranchesBin };
        const store = history.storage.Store.from(&bind.session);
        bind.reopened = opts.reopen != null;
        bind.log = try store.vtable.open(store.context, .log, log_leaf, if (bind.reopened) .update else .create);
        errdefer bind.log.vtable.close(bind.log.context);
        bind.sink = try allocator.create(LogSink);
        errdefer allocator.destroy(bind.sink);
        bind.sink.* = .{ .bind = bind, .byte = bind.log };
        bind.storage = .{
            .context = bind.sink,
            .append = &appendLog,
            .flush = &flushLog,
            .truncate = &truncateLog,
            .switchSegment = &switchSegmentLog,
        };
        bind.packs = try pack_store.PackStore.open(allocator, &bind.session);
        errdefer bind.packs.close();
        bind.objects = .{ .context = bind, .put = &putObject, .sync = &syncObjects, .putPacked = &putPacked };
        // The budget: one read at open sizes the share this history
        // takes, and every check reads the volume fresh.
        const volume = try history.resources.volume(allocator, io, bind.base.dir);
        const shares = if (opts.cap) |capped|
            try history.budget.diskCapped(volume.total, 1, capped)
        else
            history.budget.disk(volume.total, 1);
        const watch = try allocator.create(VolumeWatch);
        errdefer allocator.destroy(watch);
        watch.* = .{ .gpa = allocator, .io = io, .dir = bind.base.dir, .store = store };
        bind.watch = watch;
        watch.packs = bind.packs;
        bind.disk = .{ .context = watch, .free = &freeVolume, .cap = shares.session, .floor = shares.free_floor, .relief = &relieveVolume };
        bind.checkpoint_cap = shares.checkpoints;
        return bind;
    }

    /// End the run: the log closes first, then the session (an ephemeral
    /// one deletes, and every file inside it is closed by then), then
    /// the root.
    pub fn close(self: *Bind) !history.session.Outcome {
        const gpa = self.gpa;
        self.packs.close();
        self.log.vtable.close(self.log.context);
        self.disk = null;
        if (self.watch) |watch| gpa.destroy(watch);
        self.watch = null;
        // The graph's last state, recorded ends included, reaches
        // branches.bin; a write that fails is reported once the session
        // and the root are closed, not dropped.
        const saved: anyerror!void = if (self.detached) {} else self.saveGraph();
        self.router.deinit();
        self.graph.deinit();
        defer {
            self.base.close();
            if (self.root_bytes) |bytes| gpa.free(bytes);
            if (self.media_bytes) |bytes| gpa.free(bytes);
            gpa.destroy(self.sink);
            gpa.destroy(self);
        }
        const outcome = try self.session.close(null, .move);
        try saved;
        return outcome;
    }

    fn readRoot(self: *Bind, opts: Options) !void {
        if (opts.reopen != null) try @import("served_initial.zig").checkRootRename(self.base.io, self.session.dir);
        self.root_bytes = try history.branches_file.readAlloc(self.base.io, self.session.dir, history.layout.files.root, self.gpa);
        if (self.root_bytes) |bytes| self.root = history_root.decode(bytes) catch null;
        if (opts.reopen == null) return;
        const root = self.root orelse return error.NoRoot;
        try @import("history_validity.zig").check(root);
        if (opts.board_profile) |profile| {
            if (!std.mem.eql(u8, profile, root.board_profile)) return error.BoardProfileMismatch;
        }
        if (opts.images) |images| try images.check(root);
        if (root.media) |id| self.media_bytes = try @import("served_media.zig").read(self.gpa, history.storage.Store.from(&self.session), id);
    }

    fn saveGraph(self: *Bind) anyerror!void {
        const encoded = try session_branches_codec.encodeAlloc(&self.graph, self.gpa);
        defer self.gpa.free(encoded);
        try history.branches_file.writeAtomic(self.io, self.session.dir, encoded);
    }

    /// The log segment's length, where a reader's tail sits.
    pub fn logLength(self: *Bind) !u64 {
        return self.log.vtable.length(self.log.context);
    }
};

const LogSink = struct {
    bind: *Bind,
    byte: history.storage.ByteFile,
};

/// Reads the volume fresh for every budget check; the history root's
/// directory is the handle the read goes through. The store rides along
/// for the relief the budget's refusal path runs.
const VolumeWatch = struct { gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, store: history.storage.Store, packs: ?*pack_store.PackStore = null };

/// The relief a refused commit or checkpoint runs before the refusal
/// stands: the frames step only. The frames space holds pure
/// delete-on-close cache, so the sweep is safe while the session is
/// open. The orphan sweep needs a root no session holds open (a staged
/// checkpoint's object is on disk before its log record is), so it
/// stays a quiescent prune rather than live relief.
fn relieveVolume(context: *anyopaque) anyerror!void {
    const watch: *VolumeWatch = @ptrCast(@alignCast(context));
    _ = try history.prune.relief(watch.store, watch.gpa, prune_referrer);
    // The pack step: sealed packs that are mostly dead are rewritten. The
    // objects of a checkpoint still being taken wait unsealed, so they are
    // never mistaken for dead ones.
    if (watch.packs) |packs| _ = try history_live.compactPacks(watch.store, watch.gpa, packs, &collectReferenced);
}

fn freeVolume(context: *anyopaque) anyerror!u64 {
    const watch: *VolumeWatch = @ptrCast(@alignCast(context));
    const volume = try history.resources.volume(watch.gpa, watch.io, watch.dir);
    return volume.available;
}

fn sinkOf(context: *anyopaque) *LogSink {
    return @ptrCast(@alignCast(context));
}

fn writeBranchesBin(context: *anyopaque, encoded: []const u8) anyerror!void {
    const b: *Bind = @ptrCast(@alignCast(context));
    try history.branches_file.writeAtomic(b.io, b.session.dir, encoded);
}

fn appendLog(context: *anyopaque, bytes: []const u8) anyerror!void {
    const byte = sinkOf(context).byte;
    const end = try byte.vtable.length(byte.context);
    try byte.vtable.write(byte.context, end, bytes);
}

fn flushLog(context: *anyopaque) anyerror!void {
    const byte = sinkOf(context).byte;
    try byte.vtable.sync(byte.context);
}

fn truncateLog(context: *anyopaque, len: u64) anyerror!void {
    const byte = sinkOf(context).byte;
    try byte.vtable.truncate(byte.context, len);
}

/// Moves appends to segment `seg` of `branch`: the current segment is
/// made durable first (a failure leaves appends where they were), then
/// the target opens for update when it exists and is made when it does
/// not. Answers the bytes the target already holds.
fn switchSegmentLog(context: *anyopaque, branch: u32, seg: u32) anyerror!u64 {
    const sink = sinkOf(context);
    const bind = sink.bind;
    var buf: [64]u8 = undefined;
    const leaf = try segmentName(&buf, branch, seg);
    const store = history.storage.Store.from(&bind.session);
    try sink.byte.vtable.sync(sink.byte.context);
    const new_byte = store.vtable.open(store.context, .log, leaf, .create) catch |err| switch (err) {
        error.PathAlreadyExists => try store.vtable.open(store.context, .log, leaf, .update),
        else => return err,
    };
    errdefer new_byte.vtable.close(new_byte.context);
    const length = try new_byte.vtable.length(new_byte.context);
    sink.byte.vtable.close(sink.byte.context);
    sink.byte = new_byte;
    bind.log = new_byte;
    return length;
}

fn bindOf(context: *anyopaque) *Bind {
    return @ptrCast(@alignCast(context));
}

/// Store the bytes under the recorder's name. Names are content
/// addresses, so a repeat put of the same bytes is already durable.
fn putObject(context: *anyopaque, name: []const u8, bytes: []const u8) anyerror!void {
    const bind = bindOf(context);
    const store = history.storage.Store.from(&bind.session);
    var file = store.vtable.open(store.context, .objects, name, .create) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, bytes);
    try file.vtable.sync(file.context);
}

/// Every loose object synced its own file; the pack store's waiting
/// objects reach disk here, pack before index.
fn syncObjects(context: *anyopaque) anyerror!void {
    try bindOf(context).packs.seal();
}

/// A content-addressed page or blob joins the pack being built.
fn putPacked(context: *anyopaque, id: [16]u8, bytes: []const u8) anyerror!void {
    try bindOf(context).packs.put(.{ .bytes = id }, bytes);
}

/// The host prune's referrer: names every object the committed log
/// names. Reads the store's log segments and walks each one's committed
/// frames through the session library's scan; a segment the walk cannot
/// finish is a hard error, so the sweep never deletes past it.
pub const prune_referrer: history.prune.Referrer = .{ .collect = &collectReferenced, .pictures = &collectPictures };

const PruneGather = struct {
    allocator: std.mem.Allocator,
    names: *std.StringHashMap(void),
    failed: ?anyerror = null,

    fn add(self: *PruneGather, name: session_refs.Name) void {
        if (self.failed != null) return;
        const key = self.allocator.dupe(u8, &name) catch {
            self.failed = error.OutOfMemory;
            return;
        };
        const hit = self.names.getOrPut(key) catch {
            self.allocator.free(key);
            self.failed = error.OutOfMemory;
            return;
        };
        if (hit.found_existing) self.allocator.free(key);
    }
};

const PruneSegments = struct {
    store: history.storage.Store,
    gather: *PruneGather,
    /// Name only the checkpoint pictures, not every committed object.
    pictures_only: bool = false,

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        _ = size;
        const self: *PruneSegments = @ptrCast(@alignCast(context));
        const file = try self.store.vtable.open(self.store.context, .log, name, .read);
        defer file.vtable.close(file.context);
        const length: usize = @intCast(try file.vtable.length(file.context));
        const bytes = try self.gather.allocator.alloc(u8, length);
        defer self.gather.allocator.free(bytes);
        var got: usize = 0;
        while (got < bytes.len) {
            const read = try file.vtable.read(file.context, got, bytes[got..]);
            if (read == 0) break;
            got += read;
        }
        const walked = if (self.pictures_only)
            session_refs.scanPictureObjects(bytes[0..got], self.gather, PruneGather.add)
        else
            session_refs.scanCheckpointObjects(bytes[0..got], self.gather, PruneGather.add);
        walked catch |err| {
            self.gather.failed = err;
        };
    }
};

fn collectReferenced(store: history.storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void {
    return collect(store, allocator, names, false);
}

/// The checkpoint pictures' object names alone, which relief protects
/// by name and counts.
fn collectPictures(store: history.storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void {
    return collect(store, allocator, names, true);
}

fn collect(store: history.storage.Store, allocator: std.mem.Allocator, names: *std.StringHashMap(void), pictures_only: bool) anyerror!void {
    var gather = PruneGather{ .allocator = allocator, .names = names };
    var segments = PruneSegments{ .store = store, .gather = &gather, .pictures_only = pictures_only };
    try store.vtable.list(store.context, .log, .{ .context = &segments, .visit = &PruneSegments.visit });
    if (gather.failed) |err| return err;
    if (!pictures_only) try history_live.addManifestObjects(store, allocator, names);
}
