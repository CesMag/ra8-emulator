//! The board's virtual time in a snapshot (RA8EMU-661): the time base
//! (base_ns, cycles, retired, hz) and the event queue's live events with
//! its next sequence number, so a restored board fires the same events in
//! the same order at the same virtual nanosecond.
//!
//! Host pacing and the soak watch are run options, not board state: they
//! stay as the run that loads the snapshot configured them.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;
const clocks = @import("../periph/clocks.zig");
const Event = clocks.event_queue.Event;

pub const Error = file.Error || fields.Error || error{Missing};

pub fn save(time: *const clocks.Time, writer: *std.Io.Writer) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(time, &counter.writer);
    try file.writeSectionHeader(writer, .time, counter.fullCount());
    try body(time, writer);
}

fn body(time: *const clocks.Time, writer: *std.Io.Writer) !void {
    try fields.write(writer, time.base);
    try fields.write(writer, time.queue.next_seq);
    // Only the live events: the rest of the array is undefined.
    const live = time.queue.items[0..time.queue.count];
    try fields.write(writer, @as(u8, @intCast(live.len)));
    for (live) |event| try fields.write(writer, event);
}

/// Restores the time section of a whole snapshot file. On any error `time`
/// is left exactly as it was.
pub fn load(time: *clocks.Time, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .time) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var next = time.*;
    next.base = try fields.read(@TypeOf(next.base), &cursor);
    next.queue.next_seq = try fields.read(u32, &cursor);
    const count = try fields.read(u8, &cursor);
    if (count > next.queue.items.len) return Error.BadValue;
    for (next.queue.items[0..count]) |*event| event.* = try fields.read(Event, &cursor);
    next.queue.count = count;
    if (!cursor.done()) return Error.BadValue;
    try ordered(next.queue.items[0..count]);
    time.* = next;
}

/// The queue keeps its events sorted by time; a file that is not would
/// fire them out of order, so it is refused rather than trusted.
fn ordered(events: []const Event) Error!void {
    if (events.len < 2) return;
    for (events[1..], events[0 .. events.len - 1]) |event, before| {
        if (event.at_ns < before.at_ns) return Error.BadValue;
    }
}
