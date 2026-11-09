//! The reverse window of a real session (section 2.5): one window per
//! harness, owning the joined trail on the machine's store, the machine
//! port over the live session, and the driver that records the live run.
//!
//! While the machine runs live, past the line's recorded end, every slot
//! of a step, or of a continue of at most `live_slots_max` slots, is run
//! through the window, so the window grows at its end and the oldest
//! slots leave as its byte budget fills. A longer continue is not
//! recorded, and a reverse step then builds the window by replay. A run
//! the window cannot follow (replaying, a sleeping core, step-over,
//! finish, a seek's replay, a restore, a load, a write made outside a
//! run) leaves it stale, and it starts over at the next live slot with a
//! hot checkpoint planted at the machine's state then.
const std = @import("std");
const api = @import("../api.zig");
const state = @import("../board/state.zig");
const trail = @import("../history/trail.zig");
const engine = @import("../history/window_engine.zig");
const record = @import("../history/window_record.zig");
const machine_mod = @import("window_machine.zig");
const BoardBus = @import("ra8_chip").core.cpu.board_bus.BoardBus;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;

const Machine = machine_mod.Machine;

/// The most slots one continue may run and still be recorded live. Recording
/// costs a save and diff of the machine per slot, so a longer run goes at
/// full speed and the window is built by replay when a reverse step asks
/// for it (transport/back_window.zig).
pub const live_slots_max: u64 = 4096;

pub const Window = struct {
    gpa: std.mem.Allocator,
    machine: Machine,
    recording: trail.Recording,
    window: engine.ReverseWindow,

    /// Builds the window of `budget` bytes, plants it at the loaded
    /// machine and attaches it, with its driver, to `session`. The result
    /// points into itself, so it is heap-stable until `destroy`.
    pub fn create(gpa: std.mem.Allocator, session: *api.Session, files: *state.Files, store: *Store, bus: *BoardBus, slots: *const u64, budget: usize) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.machine = .{ .session = session, .files = files, .bus = bus };
        bus.touched = .{ .context = &self.machine, .touchFn = Machine.touch };
        errdefer bus.touched = null;
        self.recording = trail.Recording.init(gpa, .{ slots, slots }, store);
        self.recording.arm();
        errdefer self.recording.deinit();
        self.window = engine.ReverseWindow.init(gpa, self.machine.port(), &self.recording, store, budget);
        errdefer self.window.deinit();
        try self.window.plant();
        session.attachWindow(&self.window);
        session.attachWindowDriver(.{ .context = self, .enterFn = enter, .goFn = go, .settleFn = settle, .resetFn = reset });
        return self;
    }

    pub fn destroy(self: *Window) void {
        const session = self.machine.session;
        session.window = null;
        session.window_driver = null;
        self.machine.bus.touched = null;
        self.window.deinit();
        self.recording.deinit();
        self.gpa.destroy(self);
    }

    /// CPU1's slot counter, once a second core is attached.
    pub fn attachSecond(self: *Window, slots: *const u64) void {
        self.recording.slots[1] = slots;
    }

    fn of(context: *anyopaque) *Window {
        return @ptrCast(@alignCast(context));
    }

    /// Whether the window can take the slot the machine is about to run:
    /// it is built and stands where the machine does. A window that does
    /// not starts over from the machine's state now.
    fn current(self: *Window) bool {
        const w = &self.window;
        if (w.rebuild != null) return false;
        const rec = &self.recording;
        const stale = w.line == null or rec.record_count != 0 or !rec.healthy() or
            !std.meta.eql(w.at().?, self.machine.position());
        if (!stale) return true;
        record.discardFrom(rec, 0);
        rec.poisoned = false;
        w.drop();
        w.plant() catch {
            w.drop();
            return false;
        };
        return true;
    }

    /// Whether `core` only lets time pass: a sleeping core runs no
    /// instruction, which the window has no slot for.
    fn asleep(self: *Window, core: engine.Core) bool {
        const cpu = self.machine.cpuOf(core) orelse return true;
        return cpu.waiting != null;
    }

    /// One slot through the window. A window that cannot take it leaves
    /// the slot to run unrecorded; one that fails after the slot ran has
    /// dropped itself and the run goes on.
    fn slot(self: *Window, core: engine.Core) !api.Ended {
        self.machine.ran = false;
        record.extendLive(&self.window, core) catch |err| {
            if (err == error.NoSlot or self.machine.ran) return self.machine.ended;
            return self.machine.raw();
        };
        return self.machine.ended;
    }

    fn enter(context: *anyopaque, session: *api.Session) void {
        _ = session;
        const self = of(context);
        const w = &self.window;
        if (self.machine.muted or w.rebuild != null or w.line == null) return;
        if (w.cursor() < w.count()) w.walkTo(w.count()) catch w.drop();
    }

    /// A run the window does not record: the trail is off for it, since it
    /// would only keep a pre-image of every store to throw away.
    fn plain(self: *Window, command: api.Run) !api.Ended {
        self.recording.disarm();
        defer self.recording.arm();
        return self.machine.session.live.go(command);
    }

    fn go(context: *anyopaque, session: *api.Session, command: api.Run) anyerror!api.Ended {
        const self = of(context);
        const live = &session.live;
        const recorded = command == .step or (!session.advancing and command == .cont and live.budget <= live_slots_max);
        if (self.machine.muted) return live.go(command);
        if (session.replaying or !recorded) return self.plain(command);
        if (self.asleep(self.machine.coreAt()) or !self.current()) return self.plain(command);
        self.machine.begin(command);
        if (command == .step) return self.slot(self.machine.coreAt());
        const budget = live.budget;
        defer live.budget = budget;
        var left = budget;
        while (left > 0) {
            const core = self.machine.coreAt();
            if (self.window.line == null or self.asleep(core)) {
                live.budget = left;
                self.recording.disarm();
                defer self.recording.arm();
                return self.machine.raw();
            }
            live.budget = 1;
            const ended = try self.slot(core);
            if (ended != .count) return ended;
            left -= 1;
        }
        return .count;
    }

    /// The machine was put back from a saved state: the window forgets the
    /// run before it, and plants again when asked. Its own restore (a
    /// rebuild's) keeps it.
    fn reset(context: *anyopaque, session: *api.Session, plant: bool) void {
        _ = session;
        const self = of(context);
        const w = &self.window;
        if (w.rebuild != null) return;
        record.discardFrom(&self.recording, 0);
        self.recording.poisoned = false;
        w.drop();
        if (plant) w.plant() catch w.drop();
    }

    /// Ends a run slice: a window the machine moved away from, or one a
    /// write outside the slots touched, is dropped.
    fn settle(context: *anyopaque, session: *api.Session) void {
        _ = session;
        const self = of(context);
        const w = &self.window;
        if (self.machine.muted or w.rebuild != null) return;
        if (self.recording.record_count != 0) {
            record.discardFrom(&self.recording, 0);
            w.drop();
            return;
        }
        const at = w.at() orelse return;
        if (!std.meta.eql(at, self.machine.position())) w.drop();
    }
};
