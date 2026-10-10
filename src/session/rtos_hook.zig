//! `--trace-rtos` (RA8EMU-221): the tracer and its report.
//!
//! src/session/rtos_trace.zig turns stores to ThreadX's current-thread
//! pointer into switch events. This file finds `_tx_thread_current_ptr` in
//! the image, holds the Tracer that stamps each store with the run's own
//! clock, and prints the trace once the run is over.
//!
//! Each switch is printed with the thread's name, read from its TX_THREAD
//! once the run is over (src/session/rtos_names.zig, RA8EMU-223). Exception
//! entry and return are traced with them (src/session/rtos_isr.zig,
//! RA8EMU-224).
//!
//! The Zig core feeds the tracer through src/session/rtos_zig.zig, and CPU1
//! through src/session/rtos_second.zig.
const std = @import("std");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const elf = @import("../board/image/elf.zig");
const symbols = @import("symbols.zig");
const rtos_trace = @import("rtos_trace.zig");
pub const names = @import("rtos_names.zig");
pub const isr = @import("rtos_isr.zig");
pub const zig = @import("rtos_zig.zig");
pub const second = @import("rtos_second.zig");
pub const load = @import("rtos_load.zig");
pub const report = @import("rtos_report.zig");
/// `--trace-rtos-out FILE`: the trace as a file, and its reader (RA8EMU-345).
pub const file = @import("rtos_file.zig");

/// The word ThreadX keeps the running thread's control block in.
pub const symbol = "_tx_thread_current_ptr";

/// The pointer's address, the trace it feeds, and the clock it stamps from.
pub const Tracer = struct {
    address: u32,
    trace: rtos_trace.Trace = .{},
    /// The run's period counter, borrowed so a stamp is read as the store
    /// lands. Null stamps zero, which is every unit test.
    now: ?*const u64 = null,
    core: u1 = 0,
    /// Exception entry and return, when a controller was handed over.
    exceptions: ?isr.Watcher = null,
    /// Instructions seen through `onInstruction`: the load clock when no
    /// `elapsed` is lent.
    steps: u64 = 0,
    /// The run's virtual-instruction count, which also moves through
    /// stretches the idle skip charges without executing (src/chip/core/idle.zig).
    /// Null keeps the load clock on `steps`.
    elapsed: ?*const u64 = null,
    /// `elapsed` when the current chunk began, and instructions hooked since.
    base: u64 = 0,
    offset: u64 = 0,
    /// The load clock lent to the trace: virtual time, per instruction.
    clock: u64 = 0,

    /// One store that touched the pointer's word. Only a full word written
    /// to the word itself names a thread; a narrower store is a partial
    /// update no scheduler makes, and is not taken for a switch.
    pub fn onStore(self: *Tracer, address: u32, width: u8, value: u32) void {
        if (address != self.address or width != 4) return;
        self.trace.store(self.core, self.stamp(), value);
    }

    /// Before each instruction: anything entered or returned from since.
    pub fn onInstruction(self: *Tracer) void {
        self.steps += 1;
        self.advanceClock();
        if (self.exceptions) |*watcher| watcher.observe(&self.trace, self.core, self.stamp());
    }

    /// A new chunk shows as `elapsed` moving: what it charged, executed or
    /// skipped, is already in it, so the clock restarts from there.
    fn advanceClock(self: *Tracer) void {
        const now = self.elapsed orelse {
            self.clock = self.steps;
            return;
        };
        if (now.* != self.base) {
            self.base = now.*;
            self.offset = 0;
        }
        self.offset += 1;
        self.clock = @max(self.clock, self.base + self.offset);
    }

    /// The load clock as the run ends: a last stretch the idle skip charged
    /// has no instruction after it to move the clock.
    pub fn loadClock(self: *const Tracer) u64 {
        const fine = self.trace.loadNow(self.stamp());
        const now = self.elapsed orelse return fine;
        return @max(fine, now.*);
    }

    /// The run's clock now, or zero with none borrowed.
    pub fn stamp(self: *const Tracer) u64 {
        return if (self.now) |clock| clock.* else 0;
    }
};

/// Where the pointer is, when the flag asked for a trace. An image without
/// ThreadX is reported and traced as nothing.
pub fn resolve(image: elf.Image, wanted: ?load.Window) ?Tracer {
    return resolveOn(image, wanted, 0);
}

/// As `resolve`, for the image one core runs; CPU1's miss says whose it is.
/// `wanted` is the load window, null when no flag asked for a trace.
pub fn resolveOn(image: elf.Image, wanted: ?load.Window, core: u1) ?Tracer {
    const window = wanted orelse return null;
    const at = symbols.addressOf(image, symbol) orelse {
        const whose = if (core == 1) "cpu1 image has " else "";
        std.debug.print("--trace-rtos: {s}no symbol named {s}\n", .{ whose, symbol });
        return null;
    };
    var found: Tracer = .{ .address = at, .core = core };
    found.trace.load.from = window.from;
    found.trace.load.to = window.to;
    return found;
}

/// Target memory read through the shared guest handle, for the thread names.
pub const Memory = struct {
    guest: Guest,

    pub fn read(self: Memory, address: u32, into: []u8) bool {
        self.guest.read(address, into) catch return false;
        return true;
    }
};

/// The switches the run made, oldest first, each thread named through
/// `memory` where its control block says. Nothing when no trace was asked
/// for; a header with a count of zero when ThreadX never switched, because
/// that is an answer too.
pub fn print(out: anytype, tracer: ?*const Tracer, memory: anytype) !void {
    const one = tracer orelse return;
    const events = one.trace.list();
    try out.print(
        "  {s}: {s} @0x{X:0>8}, {d} event(s)\n",
        .{ if (one.core == 1) "rtos cpu1     " else "rtos trace    ", symbol, one.address, events.len + one.trace.dropped },
    );
    for (events) |event| try line(out, event, memory);
    if (one.trace.dropped > 0) {
        try out.print("                  and {d} more, not kept\n", .{one.trace.dropped});
    }
}

fn line(out: anytype, event: rtos_trace.Event, memory: anytype) !void {
    try out.print("                  tick {d} cpu{d} ", .{ event.when, event.core });
    switch (event.kind) {
        .idle => try out.print("idle\n", .{}),
        .enter, .leave => try exceptionLine(out, event),
        .switch_to => {
            try out.print("-> 0x{X:0>8}", .{event.thread});
            var buffer: [names.longest]u8 = undefined;
            if (names.name(memory, event.thread, &buffer)) |text| try out.print(" {s}", .{text});
            try out.print("\n", .{});
        },
    }
}

fn exceptionLine(out: anytype, event: rtos_trace.Event) !void {
    const verb = if (event.kind == .enter) "enter" else "leave";
    if (isr.label(event.exception)) |text| return out.print("{s} {s}\n", .{ verb, text });
    if (event.exception >= 16) return out.print("{s} IRQ{d}\n", .{ verb, event.exception - 16 });
    try out.print("{s} exception {d}\n", .{ verb, event.exception });
}
