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
//!
//! The hang-up when the cursor goes into the past is part of the line: the
//! live host was connected at the line's recorded end and the machine that
//! continues from there has no host. A disconnect is recorded at that end,
//! on that line, so a replay or restore past it drops the host there and
//! never pumps the URBs the run left behind. It is written at the first
//! poll that is not a replay (the run that carried the cursor back is one,
//! and a replay records nothing); a fork in between abandons it, as the
//! line it belongs to is no longer the one recording.
const std = @import("std");
const usb = @import("ra8_board").usb;
const usbfs = @import("ra8_chip").periph.usbfs;
const usbip_traffic = @import("../history/usbip_traffic.zig");
const async_traffic = @import("../history/async_traffic.zig");
const api = @import("../api.zig");
const line = @import("../line.zig");
const replay_feeder = @import("../history/replay_feeder.zig");

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
    /// The session's seek count when the replayed host was last rebuilt.
    seen_seeks: u32 = 0,
    /// The last poll ran in the past (or replaying).
    was_past: bool = false,
    /// The live bridge has a host connected, as it has told the port.
    live_connected: bool = false,
    /// A hang-up not yet written to the history.
    hangup: ?Hangup = null,

    const Hangup = struct { line: u32, at: line.Position };

    fn replaying(self: *const RecordedUsbip) bool {
        return self.session.replaying or line.inPast(self.session);
    }

    fn note(self: *RecordedUsbip, err: anyerror) void {
        if (self.failed == null) self.failed = err;
        if (self.replaying()) self.session.failReplay(.usbip, err);
    }

    fn poll(context: *anyopaque, device: *usbfs.Device, script: *const usbfs.host.Host) void {
        const self: *RecordedUsbip = @ptrCast(@alignCast(context));
        self.flush() catch |err| self.note(err);
        const past = self.replaying();
        if (past != self.was_past) self.crossed(past) catch |err| self.note(err);
        self.was_past = past;
        if (past) {
            self.replay(device) catch |err| self.note(err);
            // Muted: replaying the machine reads nothing from the host.
            // Past the end a queue lets the bridge hold what arrives.
            if (self.session.replaying or self.session.async_traffic.queue == null) return;
        } else if (self.held > 0 and self.queueEmpty()) {
            // The queue was cleared with the fork that left the past:
            // what the bridge holds was never recorded.
            self.inner.port.?.dropFn(self.inner.context);
            self.live_connected = false;
            self.held = 0;
        }
        self.inner.pollFn(self.inner.context, device, script);
    }

    fn queueEmpty(self: *const RecordedUsbip) bool {
        const queue = &(self.session.async_traffic.queue orelse return true);
        return queue.isEmpty();
    }

    /// The cursor went into the past or came back to the recorded end.
    /// Going in, a host still connected is hung up: the device is about
    /// to be put back, and the URBs the live bridge holds would run on a
    /// machine they were never meant for. The host may reconnect, and one
    /// that does is held until the end like any traffic that arrives in
    /// the past. Coming back, the replayed host is gone: its URBs are
    /// dropped so only the live bridge's drive the device from there.
    fn crossed(self: *RecordedUsbip, past: bool) !void {
        const port = self.inner.port.?;
        if (past) {
            if (self.live_connected) try self.hangUp();
            port.dropFn(self.inner.context);
            self.live_connected = false;
            // Events still queued stay counted; a queue a fork cleared left
            // nothing to wait for.
            if (self.queueEmpty()) self.held = 0;
            return;
        }
        try port.restoreFn(self.inner.context, .{ .kind = .disconnect });
    }

    /// Notes the disconnect the hang-up is: queued behind events still
    /// waiting for the end, otherwise due at the line's recorded end.
    fn hangUp(self: *RecordedUsbip) !void {
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        try usbip_traffic.encode(&body.writer, .{ .kind = .disconnect });
        if (self.held > 0) {
            const queue = &(self.session.async_traffic.queue orelse return);
            if (try queue.push(.usbip, 0, body.written())) {
                self.held += 1;
            } else {
                _ = queue.clear();
                self.held = 0;
            }
            return;
        }
        const router = self.session.fork_router orelse return;
        self.hangup = .{ .line = router.active_line, .at = router.recordedEnd() };
    }

    /// Writes a noted hang-up once the machine is not replaying.
    fn flush(self: *RecordedUsbip) !void {
        const hung = self.hangup orelse return;
        if (self.session.replaying) return;
        self.hangup = null;
        const router = self.session.fork_router orelse return;
        if (router.active_line != hung.line) return;
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        try usbip_traffic.encode(&body.writer, .{ .kind = .disconnect });
        try self.recordAt(hung.at, body.written());
    }

    /// Puts the replayed host back as the line left it before the cursor:
    /// the traffic the feeder has already taken, read from the start.
    fn rebuild(self: *RecordedUsbip, feeder: *const replay_feeder.ReplayFeeder) !void {
        const port = self.inner.port.?;
        try port.restoreFn(self.inner.context, .{ .kind = .disconnect });
        for (feeder.traffic.items[0..feeder.traffic_cursor]) |item| {
            try port.restoreFn(self.inner.context, try usbip_traffic.decode(item.body));
        }
    }

    fn replay(self: *RecordedUsbip, device: *usbfs.Device) !void {
        const port = self.inner.port.?;
        defer port.pumpFn(self.inner.context, device);
        const feeder = if (self.session.replay_feeder) |*f| f else return Error.UnrecordedTraffic;
        // A seek put the machine somewhere else: so is the replayed host.
        if (self.seen_seeks != self.session.async_traffic.seeks) {
            self.seen_seeks = self.session.async_traffic.seeks;
            try self.rebuild(feeder);
        }
        const now = self.session.currentPosition();
        while (feeder.takeTraffic(now)) |body| {
            const event = try usbip_traffic.decode(body);
            try port.feedFn(self.inner.context, device, event);
            // A journal entry only restores state; the device is not fed it.
            if (event.kind != .progress) self.replayed += 1;
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
        switch (event.kind) {
            .import => self.live_connected = true,
            .disconnect => self.live_connected = false,
            else => {},
        }
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
        self.live_connected = false;
    }

    fn record(self: *RecordedUsbip, body: []const u8) !void {
        try self.flush();
        try self.recordAt(self.session.currentPosition(), body);
    }

    fn recordAt(self: *RecordedUsbip, at: line.Position, body: []const u8) !void {
        const history = self.session.history orelse return;
        if (history.recorder == null) return;
        try history.recordLanding(at, .usbip_traffic, body);
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
