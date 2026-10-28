//! The recorded USB/IP port (row 24): a hook on the board's USB tick that
//! wraps the live bridge so the host traffic the guest's USBFS device was
//! served is part of the history.
//!
//! Live, the bridge runs as it always did and reports each command it takes
//! off its socket; the port records it as a `usbip_traffic` boundary at the
//! position it landed. Replaying, or playing along a line before its
//! recorded end, the recorded traffic is fed to the device at the same
//! polls through the bridge's own URB code, every reply discarded, and the
//! bridge is not polled: no socket is opened, read or written. A replay
//! with no recording to read from is a determinism error, `failed` holds
//! it, and the host is not read as a stand-in.
//!
//! Traffic that arrives while the cursor is in the past never reaches the
//! device and never forks. The bridge reads it and holds it; it waits in
//! the session's async queue and is recorded, and the held URBs let go, when
//! the run is back at the recorded end. A queue that overflows is cleared
//! with the connection dropped, so the host sees a hang-up and nothing it
//! sent is half-applied.
const std = @import("std");
const usb = @import("ra8_board").usb;
const usbfs = @import("ra8_chip").periph.usbfs;
const usbip_traffic = @import("../history/usbip_traffic.zig");
const async_traffic = @import("../history/async_traffic.zig");
const api = @import("../api.zig");
const line = @import("../line.zig");
const branch = @import("../history/branch.zig");
const Position = @import("../history/position.zig").Position;

const traffic = usb.traffic;

pub const Error = error{
    /// A replay found nothing recorded to read.
    UnrecordedTraffic,
};

pub const RecordedUsbip = struct {
    gpa: std.mem.Allocator,
    session: *api.Session,
    /// The bridge being recorded; never polled while replaying.
    inner: usb.Hook,
    /// The first error a poll hit; the application reads it.
    failed: ?anyerror = null,
    /// How many recorded events were fed to the device.
    replayed: u64 = 0,
    /// Events waiting in the async queue for the run to reach the end.
    held: usize = 0,
    /// Where the last replayed poll stood; a poll before it is a new replay.
    last: ?Position = null,

    fn replaying(self: *const RecordedUsbip) bool {
        return self.session.replaying or line.inPast(self.session);
    }

    fn note(self: *RecordedUsbip, err: anyerror) void {
        if (self.failed == null) self.failed = err;
    }

    fn poll(context: *anyopaque, device: *usbfs.Device, script: *const usbfs.host.Host) void {
        const self: *RecordedUsbip = @ptrCast(@alignCast(context));
        if (self.replaying()) {
            self.replay(device) catch |err| self.note(err);
            // Muted: replaying the machine reads nothing from the host.
            // Past the end a queue lets the bridge hold what arrives.
            if (self.session.replaying or self.session.async_traffic.queue == null) return;
        } else if (self.held > 0 and self.queueEmpty()) {
            // The queue was cleared with the fork that left the past:
            // what the bridge holds was never recorded.
            self.inner.port.?.dropFn(self.inner.context);
            self.held = 0;
        }
        self.inner.pollFn(self.inner.context, device, script);
    }

    fn queueEmpty(self: *const RecordedUsbip) bool {
        const queue = &(self.session.async_traffic.queue orelse return true);
        return queue.isEmpty();
    }

    fn replay(self: *RecordedUsbip, device: *usbfs.Device) !void {
        const port = self.inner.port.?;
        defer port.pumpFn(self.inner.context, device);
        const now = self.session.currentPosition();
        // A replay that starts over finds the replayed host gone.
        if (self.last) |before| if (branch.scalarOrder(now, before) == .lt)
            try port.feedFn(self.inner.context, device, .{ .kind = .disconnect });
        self.last = now;
        const feeder = if (self.session.replay_feeder) |*f| f else return Error.UnrecordedTraffic;
        while (feeder.takeTraffic(now)) |body| {
            try port.feedFn(self.inner.context, device, try usbip_traffic.decode(body));
            self.replayed += 1;
        }
    }

    fn hold(context: *anyopaque) bool {
        const self: *RecordedUsbip = @ptrCast(@alignCast(context));
        return line.inPast(self.session) or self.held > 0;
    }

    fn heard(context: *anyopaque, event: traffic.Event) void {
        const self: *RecordedUsbip = @ptrCast(@alignCast(context));
        self.hear(event) catch |err| self.note(err);
    }

    fn hear(self: *RecordedUsbip, event: traffic.Event) !void {
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        try usbip_traffic.encode(&body.writer, event);
        if (!hold(self)) return self.record(body.written());
        const queue = &(self.session.async_traffic.queue orelse return Error.UnrecordedTraffic);
        if (try queue.push(.usbip, 0, body.written())) {
            self.held += 1;
            return;
        }
        // Refused: the host is cut off with all it had in flight.
        _ = queue.clear();
        self.held = 0;
        self.inner.port.?.dropFn(self.inner.context);
    }

    fn record(self: *RecordedUsbip, body: []const u8) !void {
        const history = self.session.history orelse return;
        if (history.recorder == null) return;
        try history.recordLanding(self.session.currentPosition(), .usbip_traffic, body);
    }

    /// The async queue let go of one held event: it lands now.
    fn landed(context: *anyopaque, body: []const u8) anyerror!void {
        const self: *RecordedUsbip = @ptrCast(@alignCast(context));
        self.held -|= 1;
        try self.record(body);
    }
};

/// Puts the recorded port around `target`'s USB/IP bridge, when it has one a
/// session can record. A bridge already recorded stays as it is. Call it on
/// the thread that steps the board.
pub fn attach(gpa: std.mem.Allocator, session: *api.Session, target: *usb.Usb) !void {
    const inner = target.bridge orelse return;
    const port = inner.port orelse return;
    if (from(target) != null) return;
    const self = try gpa.create(RecordedUsbip);
    self.* = .{ .gpa = gpa, .session = session, .inner = inner };
    target.bridge = .{ .context = self, .pollFn = RecordedUsbip.poll };
    session.async_traffic.usbip_hook = .{ .context = self, .deliverFn = RecordedUsbip.landed };
    port.tapFn(inner.context, .{ .context = self, .noteFn = RecordedUsbip.heard, .holdFn = RecordedUsbip.hold });
}

/// The recorded port on `target`, or null when the bridge is not recorded.
pub fn from(target: *const usb.Usb) ?*RecordedUsbip {
    const hook = target.bridge orelse return null;
    if (hook.pollFn != &RecordedUsbip.poll) return null;
    return @ptrCast(@alignCast(hook.context));
}

/// Takes the recorded port off `target`, putting the bridge back as it was.
pub fn release(target: *usb.Usb, session: *api.Session) void {
    const self = from(target) orelse return;
    self.inner.port.?.tapFn(self.inner.context, null);
    target.bridge = self.inner;
    session.async_traffic.usbip_hook = null;
    self.gpa.destroy(self);
}
