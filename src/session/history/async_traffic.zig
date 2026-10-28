//! Asynchronous host traffic buffering and past-replay isolation (Slice 20.3).
//!
//! Routes incoming asynchronous host traffic (C6 network packets/answers, USB/IP
//! packets, camera frames). While the session cursor is in the recorded past,
//! traffic is queued into AsyncQueue without mutating the machine or creating forks.
//! When execution reaches the line's recorded end, the queue is drained in order.
//! When a past fork disconnects the network, the queue is cleared with a report.
const std = @import("std");
const api = @import("../api.zig");
const async_queue = @import("async_queue.zig");

pub const Source = async_queue.Source;
pub const AsyncQueue = async_queue.AsyncQueue;
pub const OverflowState = async_queue.OverflowState;
pub const DiscardReport = async_queue.DiscardReport;
pub const Item = async_queue.Item;

pub const C6BytesHook = struct {
    context: *anyopaque,
    deliverFn: *const fn (context: *anyopaque, data: []const u8) anyerror!void,
};

pub const C6AnswerHook = struct {
    context: *anyopaque,
    deliverFn: *const fn (context: *anyopaque, data: []const u8) anyerror!void,
};

pub const UsbipTrafficHook = struct {
    context: *anyopaque,
    deliverFn: *const fn (context: *anyopaque, data: []const u8) anyerror!void,
};

pub const CameraFrameHook = struct {
    context: *anyopaque,
    deliverFn: *const fn (context: *anyopaque, data: []const u8) anyerror!void,
};

pub const AsyncTraffic = struct {
    queue: ?AsyncQueue = null,
    last_discard_report: ?DiscardReport = null,
    c6_bytes_hook: ?C6BytesHook = null,
    c6_answer_hook: ?C6AnswerHook = null,
    usbip_hook: ?UsbipTrafficHook = null,
    camera_frame_hook: ?CameraFrameHook = null,
    /// How many times a restored machine had its replay reloaded; a
    /// recorded port that kept state of its own rebuilds it when it moves.
    seeks: u32 = 0,
};

/// Returns whether the machine cursor is strictly before the active line's recorded end.
pub fn isCursorInPast(session: *const api.Session) bool {
    return @import("../line.zig").inPast(session);
}

/// Ingests asynchronous host traffic. Queues if in past; delivers immediately if live.
pub fn inject(
    session: *api.Session,
    source: Source,
    now_ns: u64,
    data: []const u8,
) !void {
    if (isCursorInPast(session)) {
        if (session.async_traffic.queue) |*q| {
            _ = try q.push(source, now_ns, data);
            return;
        }
    }
    try deliver(session, source, data);
}

/// Delivers traffic directly to the appropriate registered subsystem hook.
pub fn deliver(session: *api.Session, source: Source, data: []const u8) !void {
    const st = &session.async_traffic;
    switch (source) {
        .c6_bytes => if (st.c6_bytes_hook) |h| try h.deliverFn(h.context, data),
        .c6_answer => if (st.c6_answer_hook) |h| try h.deliverFn(h.context, data),
        .usbip => if (st.usbip_hook) |h| try h.deliverFn(h.context, data),
        .camera => if (st.camera_frame_hook) |h| try h.deliverFn(h.context, data),
    }
}

const DrainVisitor = struct {
    session: *api.Session,
    pub fn visit(self: DrainVisitor, item: Item) !void {
        try deliver(self.session, item.source, item.data);
    }
};

/// Drains queued async traffic in arrival order if execution has reached recorded end.
pub fn drainIfNeeded(session: *api.Session) !usize {
    if (isCursorInPast(session)) return 0;
    const q = &(session.async_traffic.queue orelse return 0);
    if (q.isEmpty()) return 0;
    const visitor = DrainVisitor{ .session = session };
    return try q.drain(visitor);
}

/// Clears the queue when a past fork disconnects the network, recording the report.
pub fn clearOnFork(session: *api.Session) ?DiscardReport {
    const q = &(session.async_traffic.queue orelse return null);
    const report = q.clear();
    session.async_traffic.last_discard_report = report;
    return report;
}
