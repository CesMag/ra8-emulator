//! The shell's pump (RA8EMU-763): one frame drains the session link into the leaves and
//! takes its arrivals (RA8EMU-1189 moved it out of loop.zig beside the link fan-out).
const std = @import("std");
const loop = @import("loop.zig");
const execution = @import("execution.zig");
const Shell = loop.Shell;
const session_link = @import("../session_link.zig");
const timeline_feed = @import("../timeline_feed.zig");
const shell_memory = @import("memory.zig");

/// Pump the link into the leaves, then take the arrivals this frame allows.
pub fn pump(self: *Shell) !void {
    const link = self.link orelse return;
    if (self.console) |console| console.attach(link);
    if (self.board) |board| board.attach(link);
    if (self.devices) |devices| devices.attach(link);
    if (self.camera_file) |file| if (self.camera) |camera| {
        _ = file.apply(camera);
    };
    if (self.camera) |camera| camera.attach(link);
    if (self.plug) |plug| _ = plug.attach(link);
    if (self.timeline != null) timeline_feed.arm(link, &self.trace_armed);
    if (self.startup) |startup| if (self.loaded) startup.attach(link);
    if (self.breaks) |breaks| breaks.attach(link);
    if (self.stack) |stack| stack.attach(link);
    if (self.source) |source| source.attach(link);
    if (self.locals) |locals| locals.attach(link);
    if (self.branches) |feed| feed.attach(link, &self.layout);
    if (self.diff) |diff| diff.attach(link, &self.layout);
    if (self.filmstrip) |film| film.attach(link);
    if (self.registers) |registers| registers.attach(link);
    if (self.memory_field) |field| _ = field.submit(self.memory);
    if (self.memory) |memory| memory.attach(link);
    if (self.code) |code| code.attach(link);
    return drain(self, link);
}

/// Take the arrivals this frame allows without queueing new leaf reads.
pub fn drain(self: *Shell, link: *session_link.Link) !void {
    self.drained = false;
    var taken: usize = 0;
    while (taken < loop.max_arrivals) : (taken += 1) {
        const arrival = link.pump() orelse {
            self.drained = true;
            break;
        };
        if (self.timeline) |*model| try timeline_feed.take(model, arrival);
        self.snaps.observe(arrival);
        // A slice's end is not a stop: the run goes on.
        if (self.time) |time| if (time.observe(arrival, self.now()) == .boundary) continue;
        const loading = self.status.load_id;
        self.status.observe(link, arrival);
        const answered = loading != null and self.status.load_id == null;
        if (answered) self.loaded = true;
        if (answered) if (self.time) |time| time.loaded(&self.status);
        observeCore(self, answered, arrival);
        if (self.breaks) |breaks| breaks.observe(arrival);
        observeHistory(self, answered, arrival);
        if (self.console) |console| try console.observe(arrival);
        if (self.board) |board| try board.observe(arrival, self.now());
        if (self.devices) |devices| devices.observe(arrival);
        if (self.faults) |faults| if (faults.observe(arrival)) self.wants();
        if (self.camera) |camera| camera.observe(arrival);
        if (self.plug) |plug| if (plug.observe(arrival)) self.wants();
        if (self.startup) |startup| if (startup.observe(arrival)) self.wants();
    }
    execution.settle(self);
}

/// The stack, registers, memory and code leaves: start over after a
/// load, take the arrival, follow each core's fresh registers.
fn observeCore(self: *Shell, loaded: bool, arrival: session_link.Arrival) void {
    if (self.stack) |stack| {
        if (loaded) stack.reload();
        stack.observe(arrival);
    }
    if (self.source) |source| {
        if (loaded) source.reload();
        source.observe(arrival);
    }
    if (self.locals) |locals| {
        if (loaded) locals.reload();
        locals.observe(arrival);
    }
    const registers = self.registers orelse return;
    if (loaded) registers.reload();
    registers.observe(arrival);
    if (self.edit) |edit| _ = edit.observe(registers, arrival);
    for ([_]?*shell_memory.Pair{ self.memory, self.code }) |leaf| if (leaf) |memory| {
        if (loaded) memory.reload();
        memory.observe(arrival);
        memory.follow(registers);
    };
}

/// The branch tree and the state diff leaves: start over after a load, take
/// the arrival, and read the core's leaves again when a branch switch moved
/// the machine to another line.
fn observeHistory(self: *Shell, loaded: bool, arrival: session_link.Arrival) void {
    if (loaded) {
        if (self.branches) |feed| feed.reload();
        if (self.diff) |diff| diff.reload();
        if (self.filmstrip) |film| film.reload();
    }
    if (self.branches) |feed| if (feed.observe(arrival) == .switched) {
        if (self.registers) |registers| registers.refresh();
        if (self.stack) |stack| stack.refresh();
        if (self.source) |source| source.refresh();
        if (self.locals) |locals| locals.refresh();
        if (self.time) |time| time.stale = true;
        if (self.diff) |diff| diff.reload();
    };
    if (self.diff) |diff| _ = diff.observe(self.allocator, arrival);
    if (self.filmstrip) |film| film.observe(arrival);
}
