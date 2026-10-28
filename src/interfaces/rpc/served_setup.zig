//! The session server's state for one opened image (RA8EMU-1093): the
//! harness, the reply scratch, the frame buffers and the served Context with
//! list_parts, map, stack and rtc filled in. `ra8_emulator serve` answers on
//! it over a pipe or a socket; an application can answer on it in-process.
//! set_camera_source is answered here too (RA8EMU-1114): the source is
//! opened from the host, which this adapter may reach, and handed to the
//! session to install, so neither application carries a copy of that.
const std = @import("std");
const harness = @import("ra8_session").harness;
const served_camera = @import("served_camera.zig");
const served_usbip = @import("served_usbip.zig");
const board_rtc = @import("ra8_session").board.rtc;
const session_plug = @import("ra8_session").board.plug;
const cpu1_bringup = @import("ra8_session").cpu1.bringup;
const session_api = @import("ra8_session").api;
const region_map = @import("ra8_session").region.map;
const region_map_json = @import("ra8_session").region.map.json;
const region_map_text = @import("ra8_session").region.map.text;
const symbols = @import("ra8_session").symbols;
const rtos_names = @import("ra8_session").rtos.names;
const rtos_hook = @import("ra8_session").rtos.hook;
const periph_list = @import("ra8_session").periph_list;
const stack_samples = @import("ra8_session").stack.samples;
const stack_profile = @import("ra8_session").stack.profile;
const card_apps = @import("card_apps.zig");
const txm_debug = @import("ra8_session").txm.debug;
const proto = @import("session/rpc.zig");
const served = @import("session/server.zig");

const history_bind = @import("history_bind.zig");
const history_ram = @import("history_ram.zig");
const history_bridge = @import("history_bridge.zig");
const history_resources = @import("ra8_host").history.resources;
const history_budget = @import("ra8_host").history.budget;
const session_branch = @import("ra8_session").history_branch;
const session_fork = @import("ra8_session").history_fork_router;
const session_async = @import("ra8_session").history_async_queue;
const session_async_traffic = @import("ra8_session").history_async_traffic;
const history_root = @import("ra8_session").history_root;
const served_history = @import("served_history.zig");
const history = @import("ra8_host").history;
const history_marker_store = @import("history_marker_store.zig");
const frame_pipeline = @import("frame_pipeline.zig");
const served_frames = @import("served_frames.zig");
const served_prefetch = @import("served_prefetch.zig");
const frame_tap = @import("ra8_session").history_frame_tap;
const frame_cache = @import("ra8_session").history_frame_cache;

/// How a served session's persistent history is rooted, when the caller
/// asks for one (RA8EMU-1196). A root puts every record on the host's
/// disk through the application-owned bind; a null root keeps the
/// history RAM-only through history_ram, capped by the RAM share, so
/// nothing it writes lands on the disk. No options at all records
/// nothing.
pub const HistoryOpts = struct {
    root: ?[]const u8 = null,
    checkpoint_every: u32 = 64,
    /// An explicit cap on the served session's disk history share, in
    /// bytes; only with a root.
    budget: ?u64 = null,
    /// An explicit cap on the RAM-only history's share, in bytes; only
    /// without a root. Null sizes the share from the host's RAM.
    ram_budget: ?u64 = null,
    kept: bool = false,
    /// The kept session to take over instead of making a new one.
    reopen: ?[]const u8 = null,
    /// Frame tap captures per host second; zero captures every change.
    frame_hz: ?u32 = null,
};

pub const Served = struct {
    owner: harness.Harness,
    context: served.Context,
    /// Incoming frames (two frames long) and one outgoing frame.
    rx: []u8,
    tx: []u8,
    gpa: std.mem.Allocator,
    /// What camera sources are opened with.
    io: std.Io,
    /// CPU0's sampled call stacks, once sampleStacks asked (RA8EMU-833).
    stacks: ?*harness.stacks.Stacks = null,
    /// CPU1, once openSecond brought it up (RA8EMU-1147).
    second: ?*cpu1_bringup.Cpu1 = null,
    /// The persistent history's host side, once history asked for a root
    /// (RA8EMU-1196). The harness's armed checkpoints write through it.
    history: ?*history_bind.Bind = null,
    /// The RAM-only history's host side, once history asked to stay off
    /// disk (RA8EMU-1196). The harness's armed checkpoints write through it.
    ram_history: ?*history_ram.RamHistory = null,
    ram_graph: ?*session_branch.BranchGraph = null,
    ram_router: ?*session_fork.ForkRouter = null,
    root: history_root.Root = undefined,
    /// The transport's history bridge (RA8EMU-1196, slice 17), once
    /// history records: a seek plans from the committed log and restores
    /// through the checkpoint objects. Points into `self`.
    bridge: ?history_bridge.Bridge = null,
    /// Passive frame pipeline (milestone M7): tap, worker and cache.
    frames: ?*frame_pipeline.FramePipeline = null,
    markers: ?*history_marker_store.MarkerStore = null,
    feed: ?*@import("ra8_session").history_nav_feed.NavFeed = null,
    nav: ?*@import("ra8_session").history_nav_index.NavIndex = null,
    rewind: ?*@import("ra8_session").smooth_rewind.SmoothRewindEngine = null,
    /// The prefetch pool and its transport hook, once a disk history opened one.
    prefetch: ?*served_prefetch.Wired = null,

    /// Open `elf_path` and fill the context. The context points into
    /// `self`, so `self` stays put until `deinit`.
    pub fn open(self: *Served, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8, board_profile: ?[]const u8, history_opts: ?HistoryOpts) !void {
        // The history outlives the harness: the armed checkpoints write
        // through its shapes until the harness's teardown disarms, so on
        // an error the harness goes first and the history closes second.
        var bind: ?*history_bind.Bind = null;
        errdefer if (bind) |b| if (b.close()) |_| {} else |_| {};
        var ram: ?*history_ram.RamHistory = null;
        errdefer if (ram) |r| r.deinit();
        if (history_opts) |opts| {
            if (opts.root) |root| {
                const id = if (opts.reopen) |text| try history.name.id(text) else null;
                bind = try history_bind.Bind.open(allocator, io, root, .{ .cap = opts.budget, .kept = opts.kept, .reopen = id });
            } else {
                ram = try history_ram.RamHistory.open(allocator, try history_resources.ramBudget(opts.ram_budget));
            }
        }
        var owner = try harness.open(allocator, io, .{
            .elf_path = elf_path,
            .board_profile = board_profile,
            .history_storage = if (bind) |b| b.storage else if (ram) |r| r.storage else null,
            .history_objects = if (bind) |b| b.objects else if (ram) |r| r.object_space else null,
            .history_disk = if (bind) |b| b.disk else if (ram) |r| r.budget else null,
            .history_checkpoint_cap = if (bind) |b| b.checkpoint_cap else 0,
            .checkpoint_every = if (history_opts) |opts| opts.checkpoint_every else 64,
        });
        errdefer owner.deinit();
        _ = owner.watchModules();
        // A session that records history also keeps the reverse window: the
        // host budget table's window share, planted at the loaded machine.
        if (history_opts) |opts| try owner.openWindow(try windowBytes(opts));
        const Env = served.Server.Env;
        const rx = try allocator.alloc(u8, 2 * Env.max_frame);
        errdefer allocator.free(rx);
        const tx = try allocator.alloc(u8, Env.max_frame);
        errdefer allocator.free(tx);
        const scratch = try allocator.alloc(u8, proto.max_payload);
        errdefer allocator.free(scratch);
        self.* = .{ .owner = owner, .context = undefined, .rx = rx, .tx = tx, .gpa = allocator, .io = io, .history = bind, .ram_history = ram };
        self.context = .{ .session = self.owner.session(), .scratch = scratch, .state = self.owner.stateFiles(), .gpa = allocator };
        // The transport rides the context so run-control methods route through it (slice 14).
        self.context.transport = self.owner.transport();
        // The history bridge (RA8EMU-1196, slice 17): a session that
        // records history binds it, so a seek plans from the committed
        // log and puts the machine back through the checkpoint objects.
        // The bridge points into `self`, which stays put until deinit.
        if (self.history != null or self.ram_history != null) {
            self.bridge = .{ .gpa = allocator, .session = self.owner.session(), .disk = self.history, .ram = self.ram_history };
            self.context.transport.?.history = .{
                .context = &self.bridge.?,
                .facts = &history_bridge.Bridge.facts,
                .restore = &history_bridge.Bridge.restore,
                .logBytes = &history_bridge.Bridge.logBytes,
                .readObject = &history_bridge.Bridge.readObject,
            };
            try served_frames.init(self, allocator, io, self.history, history_opts);
        }
        errdefer if (self.frames) |p| {
            p.deinit();
            self.frames = null;
        };
        errdefer served_prefetch.detach(self);
        try served_prefetch.attach(self, if (history_opts) |o| o.ram_budget else null);
        self.context.wall = .{ .context = self, .nowFn = hostClock };
        self.context.listing = .{ .context = self.owner.plugs(), .listFn = listParts };
        self.context.board_profile = self.owner.boardProfile();
        self.context.mapping = .{ .context = &self.owner, .mapFn = mapImage, .stackFn = stackOf, .imageFn = imageOf };
        self.context.clock = board_rtc.clock(self.owner.board());
        self.context.peripherals = .{ .context = &self.owner, .listFn = listPeriph };
        self.context.camera = .{ .context = self, .setFn = served_camera.set };
        self.owner.session().attachCamera(.{ .context = self, .changeFn = served_camera.setDirect });
        try served_camera.attach(self);
        try served_history.attach(self, allocator);
        self.owner.session().attachNet(.{ .context = self, .closeFlowsFn = closeC6 });
        self.owner.session().attachConsole(.{ .context = self, .feedFn = feedConsoleDirect });
        self.context.trace_on = .{ .context = self, .onFn = traceOn };
        self.context.thread_names = .{ .context = self, .nameFn = threadName };
        self.context.host_clock = .{ .context = self, .nowFn = hostClock };
    }

    /// Records the USB/IP bridge the application has put on the board's USB
    /// tick, when the session keeps a history.
    pub fn attachUsbip(self: *Served) !void {
        try served_usbip.attach(self);
    }

    /// Sample CPU0's call stacks every `every` instructions and answer `folded`
    /// from them (RA8EMU-833), tagged with the ThreadX thread when the image has one.
    /// Name loaded ThreadX modules from their paired ELFs (RA8EMU-1141);
    /// `pairs` outlives the server.
    pub fn pairModules(self: *Served, pairs: []const @import("ra8_session").txm.debug.Pair) void {
        self.context.modules = self.owner.pairModules(pairs);
    }

    /// Fill the board's SDHI card with the apps in `app_paths` and pair each
    /// app's module ELF with the loaded-module table (RA8EMU-1142), the way
    /// the CLI's serve does for `--app`. Call once, after open.
    pub fn stageApps(self: *Served, io: std.Io, allocator: std.mem.Allocator, app_paths: []const []const u8) !void {
        if (app_paths.len == 0) return;
        try card_apps.fillCard(self.owner.board(), io, allocator, app_paths);
        var staged: [card_apps.max_apps]card_apps.Staged = undefined;
        const apps = try card_apps.paired(io, allocator, app_paths, &staged);
        defer card_apps.unload(allocator, apps);
        var pairs: [card_apps.max_apps]txm_debug.Pair = undefined;
        self.pairModules(try card_apps.pairs(apps, &pairs));
    }

    pub fn sampleStacks(self: *Served, every: u32) !void {
        const stacks = try self.gpa.create(harness.stacks.Stacks);
        stacks.* = .{ .every = @max(every, 1) };
        self.stacks = stacks;
        // A ThreadX image tags each sample with its thread (RA8EMU-1149).
        if (symbols.addressOf(self.owner.image(), "_tx_thread_current_ptr") != null) _ = self.owner.traceRtos();
        self.owner.sampleStacks(stacks);
        if (self.second) |cpu1| stacks.watch(1, cpu1.cpu(), &cpu1.image.?, &self.owner.board().time.base, null);
        self.context.folding = .{ .context = self, .foldFn = foldStacks };
    }

    /// Bring CPU1 up from the ELF at `path`, parked until a request runs
    /// it (RA8EMU-1147). Call once, after open and before sampleStacks.
    pub fn openSecond(self: *Served, path: []const u8) !void {
        const cpu1 = try self.gpa.create(cpu1_bringup.Cpu1);
        errdefer self.gpa.destroy(cpu1);
        cpu1.* = .{};
        try cpu1.open(self.gpa, self.io, std.Io.Dir.cwd(), &self.owner, path);
        self.second = cpu1;
        served_history.attachSecond(self, cpu1);
    }

    /// The host clock the lcd_dirty rate measures against (RA8EMU-822).
    fn hostClock(context: *anyopaque) u64 {
        const self: *Served = @ptrCast(@alignCast(context));
        return @intCast(@max(0, std.Io.Timestamp.now(self.io, .awake).nanoseconds));
    }

    fn traceOn(context: *anyopaque) bool {
        const self: *Served = @ptrCast(@alignCast(context));
        const first = self.owner.traceIfRtos();
        const second = if (self.second) |cpu1| cpu1.traceIfRtos(&self.owner) else false;
        return first or second;
    }

    /// The name of the thread whose control block is at `thread` on `core`,
    /// read from its TX_THREAD.
    fn threadName(context: *anyopaque, core: usize, thread: u32, buffer: []u8) ?[]const u8 {
        if (thread == 0) return null;
        const self: *Served = @ptrCast(@alignCast(context));
        const memory = if (core == 0)
            rtos_hook.Memory{ .guest = self.owner.guest() }
        else
            rtos_hook.Memory{ .guest = (self.second orelse return null).guest() };
        return rtos_names.name(memory, thread, buffer[0..rtos_names.longest]);
    }

    pub fn frameCache(self: *Served) ?*frame_cache.FrameCache {
        return if (self.frames) |f| &f.cache else null;
    }

    pub fn deinit(self: *Served) void {
        served_prefetch.detach(self);
        served_history.deinitNav(self);
        if (self.frames) |p| {
            p.deinit();
            self.frames = null;
        }
        served_usbip.release(self);
        if (self.bridge) |*b| b.deinit();
        if (self.stacks) |stacks| {
            self.owner.unsampleStacks(stacks);
            if (self.second) |cpu1| stacks.unwatch(1, cpu1.cpu());
            self.gpa.destroy(stacks);
        }
        if (self.second) |cpu1| {
            cpu1.close(self.gpa);
            self.gpa.destroy(cpu1);
        }
        self.context.chunks.drop();
        self.gpa.free(self.context.scratch);
        self.gpa.free(self.tx);
        self.gpa.free(self.rx);
        // A session that stopped recording into its history (a different
        // image loaded) leaves that history's branches.bin as it was.
        if (self.history) |b| b.detached = self.owner.session().graph_sink == null;
        if (self.owner.session().async_traffic.queue) |*q| q.deinit();
        self.owner.deinit();
        if (self.ram_router) |r| {
            r.deinit();
            self.gpa.destroy(r);
        }
        if (self.ram_graph) |g| {
            g.deinit();
            self.gpa.destroy(g);
        }
        if (self.history) |bind| if (bind.close()) |_| {} else |_| {};
        if (self.ram_history) |ram| ram.deinit();
    }
};

/// The reverse window's byte budget: the window share of the RAM budget, the
/// 128 MiB floor's share when the host's RAM cannot be measured.
fn windowBytes(opts: HistoryOpts) !usize {
    const ram = history_resources.ramBudget(opts.ram_budget) catch |err| switch (err) {
        error.MeasurementUnavailable => history_budget.bytes.floor,
        else => return err,
    };
    return @intCast((try history_budget.partition(ram)).window);
}

fn closeC6(context: *anyopaque) void {
    const self: *Served = @ptrCast(@alignCast(context));
    self.owner.board().c6.wire.bridge.closeFlows();
}

fn feedConsoleDirect(context: *anyopaque, bytes: []const u8) anyerror!void {
    const self: *Served = @ptrCast(@alignCast(context));
    self.owner.board().serial.feed(@import("ra8_chip").periph.sci.console_channel, bytes);
}

fn listParts(context: *anyopaque, out: []u8) anyerror![]const u8 {
    const plugs: *session_plug.Plugs = @ptrCast(@alignCast(context));
    return plugs.list(out);
}

/// The map of a core's last loaded image, as `--map` text or JSON.
fn mapImage(context: *anyopaque, core: usize, json: bool, out: []u8) anyerror![]const u8 {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return error.NoImage;
    var w: std.Io.Writer = .fixed(out);
    if (json) {
        try region_map_json.write(&w, image, &region_map.ek_ra8d2);
    } else {
        try region_map_text.render(&w, image, &region_map.ek_ra8d2);
    }
    return w.buffered();
}

/// The blocks on the board's bus, or one block's registers (RA8EMU-818).
/// Both cores share the one peripheral bus.
fn listPeriph(context: *anyopaque, core: usize, block: []const u8, json: bool, out: []u8) anyerror![]const u8 {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    return periph_list.list(&owner.board().bus, core, block, json, out);
}

/// A core's sampled stacks over [from_ns, to_ns), named by the image they
/// were walked with; a window, thread or core that took none is refused.
fn foldStacks(context: *anyopaque, core: usize, thread: ?u32, from_ns: u64, to_ns: u64, out: []u8) anyerror![]const u8 {
    const self: *Served = @ptrCast(@alignCast(context));
    const stacks = self.stacks orelse return error.NothingSampled;
    const image = if (core == 0) self.owner.image() else (self.second orelse return error.NothingSampled).image.?;
    var w: std.Io.Writer = .fixed(out);
    var scratch: [stack_samples.limits.samples]usize = undefined;
    const filter: stack_samples.Filter = .{ .core = @intCast(core), .from_ns = from_ns, .to_ns = to_ns, .thread = thread };
    try stack_samples.fold(&stacks.store, filter, stack_profile.names(&image), &w, &scratch);
    if (w.end == 0) return error.NothingSampled;
    return w.buffered();
}

/// The main stack reservation of a core's last loaded image, if it names one.
fn stackOf(context: *anyopaque, core: usize) ?region_map.Stack {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    const which: session_api.Core = if (core == 0) .cpu0 else .cpu1;
    const image = owner.loadedImage(which) orelse return null;
    return region_map.stackOf(image, &region_map.ek_ra8d2);
}

/// A core's last loaded image, for the backtrace's names and lines.
fn imageOf(context: *anyopaque, core: usize) ?symbols.Image {
    const owner: *harness.Harness = @ptrCast(@alignCast(context));
    return owner.loadedImage(if (core == 0) .cpu0 else .cpu1);
}
