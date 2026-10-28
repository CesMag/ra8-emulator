//! Core-addressed debugger operations shared by script, GDB and embedders.
const std = @import("std");
const debug_session = @import("session.zig");
const stop_machine = @import("stop_machine.zig");
const itm = @import("ra8_chip").periph.itm;
const breakpoint = @import("breakpoint.zig");
const core_view = @import("core_view.zig");
const watch_table = @import("watch/table.zig");
const zig_drive = @import("zig/drive.zig");
const zig_session = @import("zig/session.zig");
const input_script = @import("ra8_components").input_script;
const gt911 = @import("ra8_components").gt911;
const BoardTick = @import("ra8_chip").core.tick.Tick;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const session_display = @import("display.zig");
const board_faults = @import("board/faults/faults.zig");
const endpoint = @import("ra8_components").endpoint;
const fault_spec = @import("ra8_components").fault.spec;
const TimeBase = @import("ra8_chip").periph.timebase.TimeBase;
const tap_part = @import("tap_part.zig");
const session_speed = @import("speed.zig");
const history_mod = @import("history.zig");
const event_sources = @import("event/sources.zig");
const session_input = @import("input.zig");
const session_points = @import("points.zig");
const session_fork = @import("fork.zig");
const session_control = @import("control.zig");
const history_recorder = @import("history/recorder.zig");
const history_position = @import("history/position.zig");
const history_root = @import("history/root.zig");
const history_async = @import("history/async_queue.zig");
const async_traffic = @import("history/async_traffic.zig");
const replay_feeder = @import("history/replay_feeder.zig");
const session_line = @import("line.zig");
const session_window = @import("window.zig");
const window_engine = @import("history/window_engine.zig");
const session_smooth_rewind = @import("smooth_rewind.zig");
const history_nav_index = @import("history/nav_index.zig");

const session_search = @import("search.zig");
pub const Core = @import("event/stream.zig").Core;
pub const EventStream = @import("event/stream.zig").Stream;
pub const Error = error{ CoreNotAttached, NoLoader, NoInput, NoFaults, NoPlugs, NoTime, TooManySubscribers, NoHistory };
pub const Run = zig_session.Command;
pub const Ended = zig_drive.Ended;
pub const BreakId = @import("breaks/table.zig").Id;
pub const WatchId = watch_table.Id;
pub const Register = core_view.Cortex;
pub const Button = input_script.Button;
pub const Frame = session_display.Frame;
pub const Display = session_display.Display;
pub const Widget = @import("widget_tree.zig").Widget;
pub const TapPart = tap_part.Part;
pub const Position = history_position.Position;
pub const AsyncSource = history_async.Source;
pub const AsyncQueue = history_async.AsyncQueue;
pub const OverflowState = history_async.OverflowState;
pub const DiscardReport = history_async.DiscardReport;
pub const Loader = struct {
    context: *anyopaque,
    loadFn: *const fn (*anyopaque, Core, []const u8) anyerror!void,
};
/// Puts the catalog part `name` on `at`, or clears it when null (RA8EMU-212); the board plugs.
pub const PlugHook = struct {
    context: *anyopaque,
    plugFn: *const fn (*anyopaque, endpoint.Endpoint, ?[]const u8) anyerror!void,
};
pub const NetHook = session_fork.NetHook;
pub const ConsoleHook = session_fork.ConsoleHook;
pub const CameraHook = session_fork.CameraHook;
pub const GraphSink = session_fork.GraphSink;
pub const Endpoint = endpoint.Endpoint;
pub const FaultMode = fault_spec.Mode;
pub const SpeedHook = session_speed.Hook;
pub const History = history_mod.History;
pub const EventClock = struct { context: *anyopaque, nowFn: *const fn (*anyopaque) u64 };
pub const Event = @import("event/stream.zig").Event;
const BoardRun = struct { tick: BoardTick, guest: Guest };
pub const Session = struct {
    live: zig_session.ZigSession,
    time_base: ?*const TimeBase = null,
    event_clock: ?EventClock = null,
    grid: ?*const @import("ra8_chip").core.scheduler.State = null,
    loader: ?Loader = null,
    input_script: ?*input_script.Script = null,
    board_ticks: [2]?BoardRun = .{ null, null },
    display: ?session_display.Display = null,
    /// Sets or clears a fault mode on a board part on an endpoint (RA8EMU-520).
    faults: ?*board_faults.Faults = null,
    plugs: ?PlugHook = null,
    speed: ?SpeedHook = null,
    widget_tree_addresses: [2]?u32 = .{ null, null },
    event_stream: EventStream = .{},
    event_sources: event_sources.Sources = .{},
    /// The rewind history (RA8EMU-1170), when the harness attached one.
    history: ?*history_mod.History = null,
    window: ?*window_engine.ReverseWindow = null,
    window_driver: ?session_window.Driver = null,
    fork_router: ?*session_fork.ForkRouter = null,
    image_identity: [2]?[16]u8 = .{ null, null },
    root: ?*const history_root.Root = null,
    graph_sink: ?GraphSink = null,
    /// Opens a new history when a different image loads (new_history.zig).
    new_history: ?session_fork.fork_types.NewHistoryHook = null,
    net_hook: ?NetHook = null,
    console_hook: ?ConsoleHook = null,
    camera_hook: ?CameraHook = null,
    persistent_recorder: ?*history_recorder.Recorder = null,
    async_traffic: async_traffic.AsyncTraffic = .{},
    replay_feeder: ?replay_feeder.ReplayFeeder = null,
    smooth_rewind: ?*session_smooth_rewind.SmoothRewindEngine = null,
    nav_index: ?*history_nav_index.NavIndex = null,
    /// Set while a job replays recorded history (RA8EMU-1196): the
    /// machine's states are the past's, not new stops, so the history
    /// ring records nothing while it holds.
    replaying: bool = false,
    /// The first replay determinism error, until a run slice reports it.
    replay_failure: ?stop_machine.ReplayFailure = null,
    prefetch_pool: ?*@import("history/prefetch.zig").Prefetch = null,
    pub fn attachLoader(self: *Session, loader: Loader) void {
        self.loader = loader;
    }
    pub fn attachTimeBase(self: *Session, time_base: *const TimeBase) void {
        self.time_base = time_base;
        self.event_sources.bind(&self.event_stream, time_base);
    }
    pub fn attachEventClock(self: *Session, clock: EventClock) void {
        self.event_clock = clock;
    }
    pub fn now(self: *const Session) Error!u64 {
        const time = self.time_base orelse return Error.NoTime;
        return time.nowAfter(if (self.grid) |grid| grid.stretch.carry else 0);
    }
    pub fn attachInputScript(self: *Session, script: *input_script.Script) void {
        self.input_script = script;
    }
    pub fn attachBoard(self: *Session, core: Core, tick: BoardTick, guest: Guest) void {
        self.board_ticks[@backingInt(core)] = .{ .tick = tick, .guest = guest };
    }
    pub fn attachDisplay(self: *Session, d: session_display.Display) void {
        self.display = d;
    }
    pub fn attachFaults(self: *Session, faults: *board_faults.Faults) void {
        self.faults = faults;
    }
    pub fn attachForkRouter(self: *Session, router: *session_fork.ForkRouter) void {
        self.fork_router = router;
    }
    pub fn attachGraphSink(self: *Session, sink: GraphSink) void {
        self.graph_sink = sink;
    }
    pub fn attachNewHistory(self: *Session, hook: session_fork.fork_types.NewHistoryHook) void {
        self.new_history = hook;
    }
    pub fn attachRoot(self: *Session, r: *const history_root.Root) void {
        self.root = r;
    }
    pub const setReplaying = session_fork.setReplaying;
    pub const failReplay = session_fork.failReplay;
    pub const outputMuted = session_fork.outputMuted;
    pub fn attachImageIdentity(self: *Session, core: Core, id: [16]u8) void {
        self.image_identity[@as(usize, @backingInt(core))] = id;
    }
    pub fn attachNet(self: *Session, hook: NetHook) void {
        self.net_hook = hook;
    }
    pub fn attachConsole(self: *Session, hook: ConsoleHook) void {
        self.console_hook = hook;
    }
    pub fn attachCamera(self: *Session, hook: CameraHook) void {
        self.camera_hook = hook;
    }
    pub fn attachPersistentRecorder(self: *Session, rec: *history_recorder.Recorder) void {
        self.persistent_recorder = rec;
    }
    pub fn attachAsyncQueue(self: *Session, queue: history_async.AsyncQueue) void {
        self.async_traffic.queue = queue;
    }
    pub fn injectAsync(self: *Session, source: history_async.Source, now_ns: u64, data: []const u8) anyerror!void {
        return async_traffic.inject(self, source, now_ns, data);
    }
    pub fn asyncOverflow(self: *const Session) ?history_async.OverflowState {
        if (self.async_traffic.queue) |*q| return q.overflowState();
        return null;
    }
    pub fn lastDiscardReport(self: *const Session) ?history_async.DiscardReport {
        return self.async_traffic.last_discard_report;
    }
    pub const comparePositions = session_fork.comparePositions;
    pub const loadReplayInterventions = session_fork.loadReplayInterventions;
    pub const currentPosition = session_fork.currentPosition;
    pub const notePosition = session_fork.notePosition;
    /// Puts the run's scheduler position on the active line (after a restore).
    pub const stampLine = session_line.stampLine;
    pub const switchLine = session_line.switchLine;
    pub const attachSmoothRewind = session_smooth_rewind.attachSmoothRewind;
    pub const startSmoothRewind = session_smooth_rewind.startSmoothRewind;
    pub const tickSmoothRewind = session_smooth_rewind.tickSmoothRewind;
    pub const pauseSmoothRewind = session_smooth_rewind.pauseSmoothRewind;
    pub const currentRewindFrame = session_smooth_rewind.currentRewindFrame;
    pub const setRewindSpeed = session_smooth_rewind.setRewindSpeed;
    pub const forkPending = session_fork.forkPending;
    pub const confirmFork = session_fork.confirmFork;
    pub const cancelFork = session_fork.cancelFork;
    pub const consoleInput = session_fork.consoleInput;
    pub const changeCamera = session_fork.changeCamera;
    pub const skipBkpt = session_fork.skipBkpt;
    /// Frees what replay holds for this session (the feeder); its owner
    /// calls this at teardown.
    pub const releaseReplay = replay_feeder.release;

    /// Put the part on `at` into `mode` from now on, mid-run included.
    pub const setFault = session_fork.setFault;

    /// Let the part on `at` behave like the part again.
    pub const clearFault = session_fork.clearFault;

    pub fn attachPlugs(self: *Session, hook: PlugHook) void {
        self.plugs = hook;
    }
    pub fn plug(self: *Session, core: Core, at: Endpoint, name: []const u8) anyerror!void {
        return session_fork.plug(self, core, at, name);
    }
    pub fn unplug(self: *Session, core: Core, at: Endpoint) anyerror!void {
        return session_fork.unplug(self, core, at);
    }
    pub fn waitSettled(self: *Session, timeout_ns: u64) anyerror!void {
        return session_control.waitSettled(self, timeout_ns);
    }
    pub fn frame(self: *Session, allocator: std.mem.Allocator) anyerror!Frame {
        return session_control.frame(self, allocator);
    }

    /// Load image bytes through the board-specific loader, then publish it.
    pub fn load(self: *Session, core: Core, image: []const u8) anyerror!void {
        return session_fork.load(self, core, image);
    }

    /// Read the latest visible widget snapshot published by ra8_widget.
    pub fn widgets(self: *Session, allocator: std.mem.Allocator, core: Core) anyerror![]Widget {
        return session_input.widgets(self, allocator, core);
    }

    /// Tap the center of the uniquely named widget at virtual time `at_ns`.
    pub fn tapWidget(self: *Session, allocator: std.mem.Allocator, core: Core, at_ns: u64, name: []const u8) anyerror!void {
        return session_input.tapWidget(self, allocator, core, at_ns, name);
    }

    /// Tap one part (cell, row, pager control, point) of a named widget.
    pub fn tapWidgetPart(self: *Session, allocator: std.mem.Allocator, core: Core, at_ns: u64, name: []const u8, part: TapPart) anyerror!void {
        return session_input.tapWidgetPart(self, allocator, core, at_ns, name, part);
    }

    /// Queue a panel-pixel tap for virtual board time `at_ns`.
    pub fn tap(self: *Session, core: Core, at_ns: u64, x: u16, y: u16) anyerror!void {
        return session_input.tap(self, core, at_ns, x, y);
    }

    /// Queue a swipe; intermediate reports use the input script's cadence.
    pub fn swipe(self: *Session, core: Core, at_ns: u64, from: gt911.Contact, to: gt911.Contact, duration_ns: u64) anyerror!void {
        return session_input.swipe(self, core, at_ns, from, to, duration_ns);
    }

    /// Queue repeated contact reports for a virtual-time long press.
    pub fn longpress(self: *Session, core: Core, at_ns: u64, point: gt911.Contact, duration_ns: u64) anyerror!void {
        return session_input.longpress(self, core, at_ns, point, duration_ns);
    }

    /// Queue an active-low board button press (released by the shared script).
    pub fn button(self: *Session, core: Core, at_ns: u64, which: Button) anyerror!void {
        return session_input.button(self, core, at_ns, which);
    }

    pub fn run(self: *Session, core: Core, command: Run) anyerror!Ended {
        return session_fork.run(self, core, command);
    }
    pub fn step(self: *Session, core: Core) anyerror!Ended {
        return self.run(core, .step);
    }

    /// Puts the run back `back` recorded stops; window-backed when covered.
    pub const rewind = session_window.rewind;
    pub const stepBack = session_window.stepBack;
    pub const attachWindow = session_window.attachWindow;
    pub const attachWindowDriver = session_window.attachWindowDriver;
    pub const dropWindow = session_window.dropWindow;
    pub const replantWindow = session_window.replantWindow;
    pub const windowStatus = session_window.windowStatus;
    pub fn interrupt(self: *Session, core: Core) anyerror!stop_machine.Stop {
        return session_control.interrupt(self, core);
    }
    pub fn pause(self: *Session, core: Core) anyerror!void {
        return session_control.pause(self, core);
    }

    pub fn setSpeed(self: *Session, core: Core, factor: ?f64) anyerror!void {
        return session_speed.setSpeed(self, core, factor);
    }

    pub fn setRunBudget(self: *Session, core: Core, instructions: u64) anyerror!void {
        return session_speed.setRunBudget(self, core, instructions);
    }

    pub fn register(self: *Session, core: Core, which: Register) anyerror!u32 {
        return (try self.view(core)).register(which);
    }

    pub fn setRegister(self: *Session, core: Core, which: Register, value: u32) anyerror!void {
        return session_fork.setRegister(self, core, which, value);
    }

    pub fn read(self: *Session, core: Core, address: u32, into: []u8) anyerror!void {
        try (try self.view(core)).read(address, into);
    }
    pub fn write(self: *Session, core: Core, address: u32, bytes: []const u8) anyerror!void {
        return session_fork.write(self, core, address, bytes);
    }
    pub const RemovedPoint = session_points.RemovedPoint;
    pub fn setBreakpoint(self: *Session, core: Core, point: breakpoint.Break) anyerror!BreakId {
        return session_points.setBreakpoint(self, core, point);
    }
    pub fn setWatchpoint(self: *Session, core: Core, point: watch_table.Watch) anyerror!WatchId {
        return session_points.setWatchpoint(self, core, point);
    }
    pub fn clearBreakpoint(self: *Session, core: Core, id: BreakId) anyerror!void {
        return session_points.clearBreakpoint(self, core, id);
    }
    pub fn clearWatchpoint(self: *Session, core: Core, id: WatchId) anyerror!void {
        return session_points.clearWatchpoint(self, core, id);
    }
    pub fn removePoint(self: *Session, core: Core, id: u32) anyerror!RemovedPoint {
        return session_points.removePoint(self, core, id);
    }
    pub fn breakpointExists(self: *Session, core: Core, id: BreakId) anyerror!bool {
        return session_points.breakpointExists(self, core, id);
    }
    pub fn watchKind(self: *Session, core: Core, id: WatchId) anyerror!?watch_table.Kind {
        return session_points.watchKind(self, core, id);
    }
    pub const matchingWatch = session_points.matchingWatch;
    pub const hasArmedWriteWatch = session_points.hasArmedWriteWatch;
    pub const attachPrefetch = session_search.attachPrefetch;
    pub const prefetch = session_search.prefetch;
    pub const prefetchCancel = session_search.prefetchCancel;
    pub const reverseWatch = session_search.reverseWatch;

    pub fn hasCore(self: *const Session, core: Core) bool {
        return @backingInt(core) == self.live.index or self.live.other != null;
    }

    pub fn currentCore(self: *const Session) Core {
        return @fromBackingInt(@intCast(self.live.index));
    }

    pub fn switchTo(self: *Session, core: Core) anyerror!void {
        try self.select(core);
    }

    pub fn view(self: *Session, core: Core) anyerror!core_view.View {
        if (@backingInt(core) == self.live.index) return self.live.view();
        const other = self.live.other orelse return Error.CoreNotAttached;
        return .{ .zig = other.core };
    }

    pub fn store(self: *Session) ?*@import("ra8_chip").core.cpu.memory.store.Store {
        return if (self.live.store()) |s| s else if (self.history) |h| h.files.store else null;
    }

    pub fn machine(self: *Session, core: Core) anyerror!*stop_machine.Machine {
        if (@backingInt(core) == self.live.index) return self.live.machine;
        return (self.live.other orelse return Error.CoreNotAttached).machine;
    }
    pub fn itmPort(self: *Session, core: Core) anyerror!*itm.Itm {
        return session_control.itmPort(self, core);
    }
    pub fn flushItm(self: *Session, core: Core, out: anytype, final: bool) anyerror!void {
        return session_control.flushItm(self, core, out, final);
    }

    pub fn subscribe(self: *Session) Error!usize {
        return session_control.subscribe(self);
    }
    pub fn unsubscribe(self: *Session, id: usize) void {
        session_control.unsubscribe(self, id);
    }
    pub fn pollEvents(self: *Session, id: usize, out: []Event) ?@import("event/stream.zig").Read {
        return session_control.pollEvents(self, id, out);
    }
    pub fn select(self: *Session, core: Core) anyerror!void {
        return self.live.switchTo(@backingInt(core));
    }
    pub fn dirty(self: *Session) void {
        session_control.dirty(self);
    }

    /// Publish a board observation into bounded subscriber queues.
    pub fn publish(self: *Session, event: Event) void {
        session_control.publish(self, event);
    }
};
