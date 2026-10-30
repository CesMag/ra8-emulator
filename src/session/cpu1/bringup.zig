//! CPU1 brought up beside an opened harness (RA8EMU-1147), shared by the
//! debug front and the session server. CPU1 reads its own image, runs on
//! its own Zig core paired with CPU0 for exclusive access, and waits
//! parked in the session until it is given the session or run by core.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const board_wiring = @import("ra8_board").wiring;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const exclusive_peer = @import("ra8_chip").core.cpu.exclusive_peer;
const second_core = @import("ra8_chip").core.second.core;
const cpu1_image = @import("image.zig");
const harness = @import("../harness/harness.zig");
const step_hook = @import("../step_hook.zig");
const stop_machine = @import("../stop_machine.zig");
const watch_bus = @import("../watch/bus.zig");
const rtos_hook = @import("../rtos/hook.zig");
const rtos_publish = @import("../rtos/publish.zig");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;

/// Holds what CPU1 runs on; it stays put while the session has it.
pub const Cpu1 = struct {
    pair: second_core.zig.run.Driver = undefined,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    bytes: []u8 = &.{},
    /// CPU1's image, for its names, frames and lines.
    image: ?elf.Image = null,
    paired: ?*cpu_mod.Cpu = null,
    /// CPU1's RTOS tracer, its bus listener and its publisher onto the
    /// session's event stream, once traceRtos arms them (RA8EMU-840).
    tracer: ?rtos_hook.Tracer = null,
    listener: rtos_hook.zig.Listener = undefined,
    publisher: rtos_publish.Publisher = undefined,

    /// Bring CPU1 up from the ELF at `path` under `dir` beside `opened`,
    /// park it in the session and give the session back to CPU0.
    pub fn open(self: *Cpu1, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, opened: *harness.Harness, path: []const u8) !void {
        if (opened.session().root != null) return error.HistoryAlreadyRooted;
        const bytes = try dir.readFileAlloc(io, path, allocator, .limited(second_core.limits.image_bytes));
        defer allocator.free(bytes);
        try self.openBytes(allocator, opened, bytes);
    }

    /// Initial CPU1 creation from offline bytes. Must precede a frozen root;
    /// this loads initial state directly, without a reload intervention.
    pub fn openBytes(self: *Cpu1, allocator: std.mem.Allocator, opened: *harness.Harness, bytes: []const u8) !void {
        if (opened.session().root != null) return error.HistoryAlreadyRooted;
        if (opened.session().live.other != null) return error.SecondCoreAlreadyOpen;
        errdefer self.* = .{};
        self.bytes = try allocator.dupe(u8, bytes);
        errdefer allocator.free(self.bytes);
        _ = try cpu1_image.openBytes(&self.pair, board_wiring.cpu1(opened.board()), self.bytes, opened.guest());
        errdefer self.pair.close();
        self.image = try elf.Image.init(self.bytes);
        // Allocate the loaded-image copy before publishing pointers into self.
        const loaded = try allocator.dupe(u8, self.bytes);
        opened.state.loading.loaded[1] = loaded;
        const cpu1 = &self.pair.core.cpu;
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = cpu1.bus, .driver = &self.driver };
        cpu1.bus = self.watching.view();
        exclusive_peer.pair(opened.primaryCpu(), cpu1);
        @import("ra8_chip").core.scheduler.pairEvents(opened.primaryCpu(), cpu1);
        self.paired = opened.primaryCpu();
        const live = opened.session();
        live.live.other = .{ .core = .{ .cpu = cpu1 }, .machine = &self.machine, .watch = &self.watching, .index = 1, .budget = live.live.budget };
        opened.attachCore(.cpu1, cpu1, self.pair.guest());
        opened.bindSecondDriver(&self.pair);
        opened.state.edge.pair = &self.pair;
        if (live.live.boundary) |*edge| edge.pair = &self.pair;
    }

    pub fn cpu(self: *Cpu1) *cpu_mod.Cpu {
        return &self.pair.core.cpu;
    }

    /// Publish CPU1's ThreadX switches and exception entry and return on
    /// the session's event stream (RA8EMU-840), the way Harness.traceRtos
    /// does for CPU0. The tracer resolves from CPU1's own image; stamps
    /// come from the shared board clock, the timeline the model folds
    /// both cores onto, and load from CPU1's retired count.
    /// False when CPU1's image has no current-thread pointer to trace.
    pub fn traceRtos(self: *Cpu1, opened: *harness.Harness) bool {
        const image = self.image orelse return false;
        self.tracer = rtos_hook.resolveOn(image, .{}, 1) orelse return false;
        const tracer = &self.tracer.?;
        tracer.now = &opened.board().time.base.retired;
        tracer.trace.fine = &self.pair.core.cpu.retired;
        self.listener = .{ .tracer = tracer };
        const cpu0 = &self.pair.core.cpu;
        cpu0.bus = self.listener.onBus(cpu0.bus);
        if (cpu0.source) |inner| cpu0.source = self.listener.onSource(inner);
        const live = opened.session();
        self.publisher = .{ .trace = &tracer.trace, .stream = &live.event_stream, .inner = live.live.boundary, .time = &opened.board().time.base };
        live.live.boundary = self.publisher.hook();
        return true;
    }

    /// Turn CPU1's RTOS tracing on unless it already is; false when its
    /// image has no current-thread pointer to trace.
    pub fn traceIfRtos(self: *Cpu1, opened: *harness.Harness) bool {
        if (self.tracer != null) return true;
        return self.traceRtos(opened);
    }

    /// CPU1's guest memory, for the trace topic's thread names.
    pub fn guest(self: *Cpu1) Guest {
        return self.pair.guest();
    }

    pub fn close(self: *Cpu1, allocator: std.mem.Allocator) void {
        if (self.paired) |cpu0| {
            exclusive_peer.unpair(cpu0, &self.pair.core.cpu);
            cpu0.event_sender = null;
        }
        if (self.image != null) self.pair.close();
        allocator.free(self.bytes);
        self.* = .{};
    }
};
