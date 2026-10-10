//! RTOS switch and ISR events onto the session event stream (RA8EMU-346).
//!
//! The tracer's bounded trace never calls a subscriber. A Publisher drains
//! what it recorded since the last drain at the debugger's chunk boundary,
//! keeping each event's own core and stamp, so subscribers see the tracer's
//! order and times rather than the drain's.
const rtos_trace = @import("rtos_trace.zig");
const rtos_stream = @import("rtos_stream.zig");
const stream_mod = @import("event_stream.zig");
const zig_boundary = @import("zig_boundary.zig");
const timebase = @import("ra8_chip").periph.timebase;

/// The board's time base, named for tests.
pub const TimeBase = timebase.TimeBase;

/// Trace events copied per read; a drain loops until the cursor is caught up.
pub const batch = 32;

pub const Publisher = struct {
    trace: *const rtos_trace.Trace,
    stream: *stream_mod.Stream,
    /// The board's boundary, ticked before each drain; null ticks nothing.
    inner: ?zig_boundary.Boundary = null,
    cursor: rtos_stream.Cursor = .{},
    /// The board's time base. Trace stamps are retired cycles, turned into
    /// virtual nanoseconds at its rate; null publishes the raw stamp.
    time: ?*const TimeBase = null,

    /// Publish every event recorded since the last drain, in order.
    pub fn drain(self: *Publisher) void {
        var buffer: [batch]rtos_trace.Event = undefined;
        while (true) {
            const read = self.cursor.read(self.trace, &buffer);
            for (read) |one| self.stream.publish(eventAt(one, self.nsOf(one.when)));
            if (read.len < buffer.len) return;
        }
    }

    /// A trace stamp in virtual nanoseconds. A stamp from before the last
    /// rate change is charged to the moment the rate changed.
    pub fn nsOf(self: *const Publisher, cycles: u64) u64 {
        const time = self.time orelse return cycles;
        const start = time.retired - time.cycles;
        if (cycles < start) return time.base_ns;
        return time.base_ns + timebase.toNs(cycles - start, time.hz);
    }

    /// The inner boundary with a drain after every chunk.
    pub fn hook(self: *Publisher) zig_boundary.Boundary {
        const chunk = if (self.inner) |inner| inner.chunk else zig_boundary.default_chunk;
        return .{ .context = self, .tickFn = tick, .chunk = chunk };
    }

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Publisher = @ptrCast(@alignCast(context));
        if (self.inner) |inner| try inner.tickFn(inner.context, instructions);
        self.drain();
    }
};

/// One trace event as a stream event, stamped with the tracer's own time.
pub fn eventOf(one: rtos_trace.Event) stream_mod.Event {
    return eventAt(one, one.when);
}

/// One trace event as a stream event at `virtual_ns`.
pub fn eventAt(one: rtos_trace.Event, virtual_ns: u64) stream_mod.Event {
    return .{
        .core = if (one.core == 0) .cpu0 else .cpu1,
        .virtual_ns = virtual_ns,
        .kind = switch (one.kind) {
            .switch_to => .rtos_switch,
            .idle => .rtos_idle,
            .enter => .isr_enter,
            .leave => .isr_leave,
        },
        .payload = .{ .rtos = .{ .thread = one.thread, .exception = one.exception } },
    };
}
