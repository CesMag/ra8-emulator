//! The machine the reverse-window tests drive: a minimal boot image with a
//! counting loop in SRAM (every iteration writes guest memory, and the
//! board ticks every 64 cycles), a small external memory so a whole save
//! stream is cheap, the joined trail armed on the machine store, and a
//! window port bound to the harness.

const std = @import("std");
const ra8 = @import("ra8");
const harness_mod = ra8.session.harness;
const trail = ra8.session.history_trail;
const port_mod = ra8.session.history_window_port;
const engine = ra8.session.history_window_engine;
const memmap = ra8.chip.core.memmap;

// Only the vector table boots this machine; countFixture replaces execution
// before any image instruction runs. Keep the image small: every full and
// side save hashes its immutable ELF identity, even for a single-slot step.
pub const image_path = "tests/fixtures/gpio/blink.elf";

pub const profile =
    \\# Window test board, profile format version 1.
    \\version=1
    \\ospi=size:1048576,width:8,clock_hz:166666667,latency_cycles:8,burst:incrementing16
    \\sdram=size:1048576,width:32,clock_hz:133000000,latency_cycles:3,burst:incrementing16
    \\memory_window_cycles=1000000
    \\panel=none
;

/// The counter the loop increments, above its code at +0x6000.
pub const counter_addr = memmap.sram_base + 0x6100;

pub const Rig = struct {
    gpa: std.mem.Allocator,
    opened: harness_mod.Harness,
    recording: trail.Recording,
    /// Added to the live line, so a test can move the machine to another.
    line_shift: u32 = 0,
    /// Slots the port has stepped, and the one that raises a structural
    /// barrier on the machine store, if any.
    steps: usize = 0,
    barrier_at: ?usize = null,
    /// Failure injection: the side save that fails (1-based, counted from
    /// `armSideFailure`), and whether the side load fails.
    fail_side_at: ?usize = null,
    side_calls: usize = 0,
    fail_load_side: bool = false,

    /// The `n`th side save from now on fails.
    pub fn armSideFailure(self: *Rig, n: usize) void {
        self.side_calls = 0;
        self.fail_side_at = n;
    }

    /// Opens the machine in place: the recording points at itself.
    pub fn open(self: *Rig, gpa: std.mem.Allocator) !void {
        self.gpa = gpa;
        self.line_shift = 0;
        self.steps = 0;
        self.barrier_at = null;
        self.fail_side_at = null;
        self.side_calls = 0;
        self.fail_load_side = false;
        self.opened = try harness_mod.open(gpa, std.testing.io, .{ .elf_path = image_path, .board_profile = profile });
        errdefer self.opened.deinit();
        try countFixture(&self.opened);
        const session = self.opened.session();
        try session.setRunBudget(.cpu0, 1);
        // One step first, so the run has a grid and a position.
        _ = try session.run(.cpu0, .cont);
        const cpu = self.opened.primaryCpu();
        self.recording = trail.Recording.init(gpa, .{ &cpu.slots, &cpu.slots }, &self.opened.state.cpu0.store.?);
        self.recording.arm();
    }

    pub fn deinit(self: *Rig) void {
        self.recording.deinit();
        self.opened.deinit();
    }

    pub fn window(self: *Rig, budget: usize) engine.ReverseWindow {
        return engine.ReverseWindow.init(self.gpa, self.port(), &self.recording, &self.opened.state.cpu0.store.?, budget);
    }

    pub fn port(self: *Rig) port_mod.Port {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn position(self: *Rig) port_mod.Position {
        return self.opened.session().grid.?.at;
    }

    /// One slot straight, outside any window; its writes are not kept.
    pub fn stepStraight(self: *Rig) !void {
        const mark = self.recording.record_count;
        try step(self, .cpu0);
        ra8.session.history_window_record.discardFrom(&self.recording, mark);
    }

    /// The whole machine's save stream, owned by the caller.
    pub fn full(self: *Rig) ![]u8 {
        return self.port().fullBytes(self.gpa);
    }

    /// The whole machine's save stream, hashed.
    pub fn digest(self: *Rig) ![32]u8 {
        const bytes = try self.full();
        defer self.gpa.free(bytes);
        var out: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &out, .{});
        return out;
    }

    const vtable: port_mod.Port.VTable = .{
        .position = vPosition,
        .line = vLine,
        .cpu = vCpu,
        .step = vStep,
        .saveFull = saveFull,
        .restoreFull = restoreFull,
        .saveSide = saveSide,
        .loadSide = loadSide,
    };

    fn of(context: *anyopaque) *Rig {
        return @ptrCast(@alignCast(context));
    }

    fn vPosition(context: *anyopaque) port_mod.Position {
        return of(context).position();
    }

    fn vLine(context: *anyopaque) u32 {
        const self = of(context);
        return self.position().branch + self.line_shift;
    }

    fn vCpu(context: *anyopaque, core: port_mod.Core) ?*port_mod.Cpu {
        return switch (core) {
            .cpu0 => of(context).opened.primaryCpu(),
            .cpu1 => null,
        };
    }

    fn vStep(context: *anyopaque, core: port_mod.Core) anyerror!void {
        return step(of(context), core);
    }

    fn step(self: *Rig, core: port_mod.Core) !void {
        const session = self.opened.session();
        session.setReplaying(true);
        defer session.setReplaying(false);
        const ended = try session.run(switch (core) {
            .cpu0 => .cpu0,
            .cpu1 => .cpu1,
        }, .cont);
        if (ended != .count) return error.UnexpectedStop;
        self.steps += 1;
        if (self.barrier_at == self.steps) self.opened.state.cpu0.store.?.barrier(.wipe);
    }

    fn saveFull(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try of(context).opened.state.files.writeTo(writer);
    }

    fn restoreFull(context: *anyopaque, bytes: []const u8) anyerror!void {
        try of(context).opened.history().restoreBytes(bytes);
    }

    fn saveSide(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        const self = of(context);
        self.side_calls += 1;
        if (self.fail_side_at == self.side_calls) return error.Injected;
        try self.opened.state.files.writeParts(writer, .{ .memory = false });
    }

    fn loadSide(context: *anyopaque, bytes: []const u8, board: bool) anyerror!void {
        if (of(context).fail_load_side) return error.Injected;
        try of(context).opened.state.files.readParts(bytes, .{ .memory = false, .board = board });
    }
};

/// The boot image's entry becomes `ldr r0,[r1]; adds r0,#1; str
/// r0,[r1]; b` back: every iteration writes guest memory and retires four
/// instructions, and the board ticks every 64 cycles.
pub fn countFixture(opened: *harness_mod.Harness) !void {
    opened.state.edge.idle_skip = false;
    opened.state.edge.timebase.per_chunk = 64;
    opened.session().live.boundary.?.chunk = 64;
    const at = memmap.sram_base + 0x6000;
    try opened.guest().write(at, &.{ 0x08, 0x68, 0x40, 0x1C, 0x08, 0x60, 0xFB, 0xE7 });
    try opened.guest().writeWord(counter_addr, 0);
    const cpu = opened.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.primask = 1;
    cpu.waiting = null;
    cpu.regs.low[0] = 0;
    cpu.regs.low[1] = counter_addr;
}

/// A straight run of `n` slots from the live state: the whole save stream
/// before them and the machine digest and position at each slot boundary.
pub const Straight = struct {
    gpa: std.mem.Allocator,
    base: []u8,
    digests: [][32]u8,
    positions: []port_mod.Position,

    pub fn record(rig: *Rig, n: usize) !Straight {
        const gpa = rig.gpa;
        const base = try rig.full();
        errdefer gpa.free(base);
        const digests = try gpa.alloc([32]u8, n + 1);
        errdefer gpa.free(digests);
        const positions = try gpa.alloc(port_mod.Position, n + 1);
        errdefer gpa.free(positions);
        for (0..n + 1) |i| {
            if (i > 0) try rig.stepStraight();
            digests[i] = try rig.digest();
            positions[i] = rig.position();
        }
        return .{ .gpa = gpa, .base = base, .digests = digests, .positions = positions };
    }

    pub fn deinit(self: *Straight) void {
        self.gpa.free(self.base);
        self.gpa.free(self.digests);
        self.gpa.free(self.positions);
    }
};

/// The whole machine's save stream of a harness, hashed.
pub fn digestOf(gpa: std.mem.Allocator, opened: *harness_mod.Harness) ![32]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try opened.state.files.writeTo(&out.writer);
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(out.written(), &hash, .{});
    return hash;
}

/// The counting-loop machine of the window tests, past its first step so
/// the run has a grid; with `window` it also records into a reverse
/// window of `budget` bytes, planted at that state.
pub fn openCounting(gpa: std.mem.Allocator, window: ?usize) !harness_mod.Harness {
    var opened = try harness_mod.open(gpa, std.testing.io, .{ .elf_path = image_path, .board_profile = profile });
    errdefer opened.deinit();
    try countFixture(&opened);
    const session = opened.session();
    try session.setRunBudget(.cpu0, 1);
    _ = try session.run(.cpu0, .cont);
    if (window) |budget| try opened.openWindow(budget);
    return opened;
}

/// Runs `count` instructions of the session's CPU0 in one command.
pub fn runCount(opened: *harness_mod.Harness, count: u64) !void {
    const session = opened.session();
    try session.setRunBudget(.cpu0, count);
    const ended = try session.run(.cpu0, .cont);
    if (ended != .count) return error.UnexpectedStop;
}
