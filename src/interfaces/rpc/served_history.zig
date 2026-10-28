//! History and choke point attachments for a served session (time-travel
//! design section 11).
//!
//! Attaches the router and branches.bin's sink, the opened image's frozen
//! root and identity, the new-history hook for program reloads, the bounded
//! queue for host traffic during rewinds, the C6 hold, and console stdin
//! routing through the fork router choke point.
const std = @import("std");
const history = @import("ra8_host").history;
const session_api = @import("ra8_session").api;
const session_branch = @import("ra8_session").history_branch;
const session_fork = @import("ra8_session").history_fork_router;
const session_async = @import("ra8_session").history_async_queue;
const session_async_traffic = @import("ra8_session").history_async_traffic;
const history_root = @import("ra8_session").history_root;
const cpu1_bringup = @import("ra8_session").cpu1.bringup;
const session_nav = @import("ra8_session").history_nav_index;
const session_feed = @import("ra8_session").history_nav_feed;
const session_smooth_rewind = @import("ra8_session").smooth_rewind;
const symbols = @import("ra8_session").symbols;
const late_marker = @import("ra8_session").history_late_marker;
const history_segments = @import("history_segments.zig");
const marker_store = @import("history_marker_store.zig");
const nav_marker = @import("session/nav_marker.zig");
const served_rewind = @import("served_rewind.zig");
const frame_tap = @import("ra8_session").history_frame_tap;
const served_setup = @import("served_setup.zig");
const board_c6 = @import("ra8_session").board.recorded_c6;

/// The camera source a served session starts with; later changes are
/// recorded as interventions, and the frames it captures as boundaries.
const initial_camera = "gradient";

/// Binds the recording session's lines: router, graph sink, image root,
/// identities, new-history hook, bounded async queue, C6 hold, and console stdin.
pub fn attach(self: *served_setup.Served, allocator: std.mem.Allocator) !void {
    if (self.history == null and self.ram_history == null) return;
    const session = self.owner.session();
    self.root = .{
        .snapshot_version = 1,
        .camera = initial_camera,
        .camera_hash = history_root.identity(initial_camera),
        .elf0 = .{
            .identity = history_root.identity(self.owner.image().bytes),
            .bytes = self.owner.image().bytes,
        },
    };
    session.attachRoot(&self.root);
    session.attachImageIdentity(.cpu0, self.root.elf0.identity);
    session.attachNewHistory(.{ .context = self, .startFn = handleNewHistory });
    session.attachAsyncQueue(session_async.AsyncQueue.init(allocator, 0));
    self.owner.board().c6.wire.bridge.hold = .{ .context = session, .heldFn = hostHeld };
    try board_c6.attach(self.gpa, session, &self.owner.board().c6.wire.bridge);
    self.owner.board().console_input.hook = .{ .context = session, .feedFn = routeConsoleStdin, .heldFn = hostHeld };

    if (self.history) |b| {
        session.attachForkRouter(&b.router);
        session.attachGraphSink(b.graph_sink);
        if (b.root == null) {
            b.root = self.root;
            saveRoot(self.io, b.session.dir, allocator, &self.root) catch {};
        }
    } else {
        const graph = try allocator.create(session_branch.BranchGraph);
        errdefer allocator.destroy(graph);
        graph.* = try session_branch.BranchGraph.init(allocator);
        errdefer graph.deinit();
        const router = try allocator.create(session_fork.ForkRouter);
        errdefer allocator.destroy(router);
        router.* = session_fork.ForkRouter.init(allocator, graph);
        self.ram_graph = graph;
        self.ram_router = router;
        session.attachForkRouter(router);
    }
    errdefer {
        if (self.ram_router) |r| {
            r.deinit();
            allocator.destroy(r);
            self.ram_router = null;
        }
        if (self.ram_graph) |g| {
            g.deinit();
            allocator.destroy(g);
            self.ram_graph = null;
        }
    }
    try attachNav(self, allocator);
}

pub fn attachNav(self: *served_setup.Served, allocator: std.mem.Allocator) !void {
    const nav = try allocator.create(session_nav.NavIndex);
    errdefer allocator.destroy(nav);
    nav.* = session_nav.NavIndex.init(allocator);
    errdefer nav.deinit();

    const rewind = try allocator.create(session_smooth_rewind.SmoothRewindEngine);
    errdefer allocator.destroy(rewind);
    rewind.* = session_smooth_rewind.SmoothRewindEngine.init(allocator, self.owner.session());
    errdefer rewind.deinit();

    errdefer {
        self.nav = null;
        self.rewind = null;
        self.owner.session().nav_index = null;
        self.owner.session().smooth_rewind = null;
        if (self.frames) |f| f.bindNav(null);
    }

    self.nav = nav;
    self.owner.session().nav_index = nav;
    self.rewind = rewind;
    self.owner.session().smooth_rewind = rewind;

    if (self.owner.session().window) |w| {
        rewind.attachWindow(w);
    }
    if (self.frames) |f| f.bindNav(nav);
    served_rewind.attach(self, rewind);
    if (self.frames) |f| {
        if (self.owner.session().fork_router) |router| router.switch_observer = .{ .context = &f.tap, .switchedFn = &frame_tap.FrameTap.lineSwitched };
    }

    const reopened = if (self.history) |b| b.reopened else false;
    // A reopened history already holds its first checkpoint.
    if (!reopened) {
        if (self.owner.session().live.checkpoints) |cp| cp.checkpointNow() catch {};
    }

    const cur = self.owner.session().currentPosition();
    _ = nav.addFrame(cur, 0) catch {};
    _ = nav.addIteration(cur) catch {};
    const boot_addr = symbols.addressOf(self.owner.image(), "Reset_Handler") orelse 0;
    _ = nav.addMarkerArrival("boot", boot_addr, cur) catch {};
    nav.setBookmark("boot", cur) catch {};
    attachMarkers(self, allocator, nav, reopened);
    attachFeed(self, allocator, nav);
}

/// The run feeds the index as it goes: every closed round is an iteration,
/// and a ThreadX image's switches and exceptions are stamped with their
/// positions. Without ThreadX only the iterations are fed.
fn attachFeed(self: *served_setup.Served, allocator: std.mem.Allocator, nav: *session_nav.NavIndex) void {
    const session = self.owner.session();
    const feed = allocator.create(session_feed.NavFeed) catch return;
    feed.* = .{ .nav = nav, .session = session, .saved = self.owner.grid(), .slots = &self.owner.primaryCpu().slots };
    feed.base_slots = feed.slots.*;
    self.feed = feed;
    if (session.live.checkpoints) |cp| cp.rounds = .{ .context = feed, .roundFn = &session_feed.NavFeed.onRound };
    if (symbols.addressOf(self.owner.image(), "_tx_thread_current_ptr") != null and self.owner.traceIfRtos()) {
        _ = self.owner.observeRtos(feed.observer());
    }
}

/// A reopened machine has never run, so it has no position to seek from.
/// Restoring the history's first checkpoint puts it on the line's grid.
fn standAtFirstCheckpoint(self: *served_setup.Served) void {
    const plane = self.owner.transport();
    const bridge = plane.history orelse return;
    const facts = bridge.facts(bridge.context) catch return;
    var first: ?@TypeOf(facts.checkpoints[0]) = null;
    for (facts.checkpoints) |c| {
        if (first == null or c.position.r < first.?.position.r) first = c;
    }
    const c = first orelse return;
    plane.restoreBase(.{ .checkpoint = .{ .id = c.id, .object = c.object, .position = c.position } }) catch {};
}

/// Binds the late-marker cache to the history's index space. A reopened
/// history loads its cached arrivals back, so `seek marker` needs no
/// replay, and has its recorded interventions due again from the start.
fn attachMarkers(self: *served_setup.Served, allocator: std.mem.Allocator, nav: *session_nav.NavIndex, reopened: bool) void {
    const bind = self.history orelse return;
    const cache = allocator.create(marker_store.MarkerStore) catch return;
    cache.* = .{ .gpa = allocator, .store = history.storage.Store.from(&bind.session) };
    self.markers = cache;
    self.context.nav.markers = cache.storage();
    if (!reopened) return;
    standAtFirstCheckpoint(self);
    const end = nav_marker.historyEnd(self.owner.transport());
    late_marker.loadInto(allocator, cache.storage(), nav_marker.cache_file, end, nav) catch {};
    const log = history_segments.readAll(allocator, cache.store) catch return;
    defer allocator.free(log);
    self.owner.session().loadReplayInterventions(log) catch {};
}

pub fn deinitNav(self: *served_setup.Served) void {
    if (self.owner.session().fork_router) |router| router.switch_observer = null;
    if (self.feed) |feed| {
        if (self.owner.session().live.checkpoints) |cp| cp.rounds = null;
        _ = self.owner.observeRtos(null);
        feed.deinit();
        self.gpa.destroy(feed);
        self.feed = null;
    }
    if (self.markers) |cache| {
        self.gpa.destroy(cache);
        self.markers = null;
        self.context.nav.markers = null;
    }
    if (self.rewind) |rewind| {
        rewind.deinit();
        self.gpa.destroy(rewind);
        self.rewind = null;
        self.owner.session().smooth_rewind = null;
    }
    if (self.nav) |nav| {
        nav.deinit();
        self.gpa.destroy(nav);
        self.nav = null;
        self.owner.session().nav_index = null;
    }
}

/// When CPU1 is brought up, updates root and identity for core 1.
pub fn attachSecond(self: *served_setup.Served, cpu1: *cpu1_bringup.Cpu1) void {
    if (cpu1.image) |img| {
        self.root.elf1 = .{
            .identity = history_root.identity(img.bytes),
            .bytes = img.bytes,
        };
        self.owner.session().attachImageIdentity(.cpu1, self.root.elf1.?.identity);
    }
}

/// The C6 hold: host traffic waits while the session replays or stands
/// before the active line's recorded end.
pub fn hostHeld(context: *anyopaque) bool {
    const session: *session_api.Session = @ptrCast(@alignCast(context));
    return session.replaying or session_async_traffic.isCursorInPast(session);
}

/// Routes console keystrokes from stdin through the fork router choke point.
pub fn routeConsoleStdin(context: *anyopaque, bytes: []const u8) void {
    const session: *session_api.Session = @ptrCast(@alignCast(context));
    session.consoleInput(.cpu0, bytes) catch {};
}

/// A different program was loaded: marks the old history detached so its
/// branches.bin is never overwritten by the new program's line graph.
pub fn handleNewHistory(context: *anyopaque, core: session_api.Core, image_bytes: []const u8) anyerror!void {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    _ = image_bytes;
    _ = core;
    if (self.history) |b| b.detached = true;
}

fn saveRoot(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, r: *const history_root.Root) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try history_root.encode(r, &buf.writer);
    const file = try dir.createFile(io, history.layout.files.root, .{ .truncate = true, .resolve_beneath = true });
    defer file.close(io);
    try file.writeStreamingAll(io, buf.written());
    try file.sync(io);
}
