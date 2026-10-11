//! A pull reader for RTOS events as a trace is produced.
//!
//! The session loop can copy new events at its boundaries. The bounded
//! trace never calls a subscriber or waits for one to consume an event.
const trace = @import("trace.zig");

pub const Cursor = struct {
    next_index: usize = 0,

    /// Copy newly recorded events into caller-owned storage, preserving order.
    pub fn read(self: *Cursor, source: *const trace.Trace, into: []trace.Event) []const trace.Event {
        const events = source.list();
        const start = @min(self.next_index, events.len);
        const count = @min(events.len - start, into.len);
        @memcpy(into[0..count], events[start..][0..count]);
        self.next_index += count;
        return into[0..count];
    }
};
