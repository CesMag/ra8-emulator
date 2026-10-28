//! The recorded C6 port (row 24): a landing hook on the ESP32-C6 bridge so
//! the host frames its sockets and DNS lookups put on the guest's queue are
//! part of the history.
//!
//! Live, the bridge runs as it always did and tells the port each frame as
//! it lands; the port records it as a `c6_bytes` (or `c6_answer`) boundary
//! at the position and the bridge call that landed it. Replaying, or
//! playing along a line before its recorded end, the bridge's hold is up:
//! it opens no socket, reads none and writes none, and the port lands the
//! frames recorded for the same call on the queue instead, so the guest
//! hears exactly what it heard. A recorded frame the replay never reached,
//! or that no longer fits the queue, is a determinism error: `failed`
//! holds it.
//!
//! A call is named by the position it ran at and its ordinal among the
//! calls of its site at that position, because one stretch can forward
//! several guest frames before the board ticks.
const std = @import("std");
const hosted = @import("ra8_components").esp_hosted;
const c6_landing = @import("../history/c6_landing.zig");
const api = @import("../api.zig");
const line = @import("../line.zig");
const branch = @import("../history/branch.zig");
const Position = @import("../history/position.zig").Position;

const hold = hosted.hold;

pub const Error = error{
    /// A frame recorded for a call the replay passed without landing it.
    MissedLanding,
    /// A recorded frame did not fit the queue it was recorded on.
    QueueFull,
};

pub const RecordedC6 = struct {
    gpa: std.mem.Allocator,
    session: *api.Session,
    /// The first error a landing hit; the application reads it.
    failed: ?anyerror = null,
    /// How many recorded frames were landed from the history.
    replayed: u64 = 0,
    /// Where the last call ran, and how many calls of each site ran there.
    last: ?Position = null,
    /// The session's seek count at the last call.
    seen_seeks: u32 = 0,
    counts: [2]u32 = .{ 0, 0 },
    /// The ordinal of the call in progress, for each site.
    call: [2]u32 = .{ 0, 0 },

    fn replaying(self: *const RecordedC6) bool {
        return line.outputMuted(self.session);
    }

    fn note(self: *RecordedC6, err: anyerror) void {
        if (self.failed == null) self.failed = err;
        if (self.replaying()) self.session.failReplay(.c6, err);
    }

    fn enter(context: *anyopaque, site: hold.Site) void {
        const self: *RecordedC6 = @ptrCast(@alignCast(context));
        const now = self.session.currentPosition();
        // A seek lands the machine on a position `last` may already hold.
        const moved = self.seen_seeks != self.session.async_traffic.seeks;
        self.seen_seeks = self.session.async_traffic.seeks;
        if (moved or self.last == null or branch.scalarOrder(now, self.last.?) != .eq) {
            self.last = now;
            self.counts = .{ 0, 0 };
        }
        const at = @backingInt(site);
        self.call[at] = self.counts[at];
        self.counts[at] += 1;
    }

    fn landed(context: *anyopaque, site: hold.Site, kind: hold.Kind, frame: []const u8) void {
        const self: *RecordedC6 = @ptrCast(@alignCast(context));
        self.record(site, kind, frame) catch |err| self.note(err);
    }

    fn record(self: *RecordedC6, site: hold.Site, kind: hold.Kind, frame: []const u8) !void {
        const history = self.session.history orelse return;
        if (history.recorder == null) return;
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        try c6_landing.encode(&body.writer, .{ .kind = kind, .site = site, .ordinal = self.call[@backingInt(site)], .frame = frame });
        try history.recordLanding(self.session.currentPosition(), c6_landing.whatOf(kind), body.written());
    }

    fn due(context: *anyopaque, site: hold.Site, out: []u8) ?hold.Due {
        const self: *RecordedC6 = @ptrCast(@alignCast(context));
        const feeder = if (self.session.replay_feeder) |*f| f else return null;
        while (feeder.takeLanding(self.session.currentPosition(), @backingInt(site), self.call[@backingInt(site)])) |taken| {
            if (taken.missed) {
                self.note(Error.MissedLanding);
                continue;
            }
            const landing = c6_landing.decode(taken.body) catch |err| return self.refuse(err);
            if (landing.frame.len > out.len) return self.refuse(Error.QueueFull);
            @memcpy(out[0..landing.frame.len], landing.frame);
            self.replayed += 1;
            return .{ .kind = landing.kind, .len = landing.frame.len };
        }
        return null;
    }

    fn refuse(self: *RecordedC6, err: anyerror) ?hold.Due {
        self.note(err);
        return null;
    }

    fn full(context: *anyopaque) void {
        const self: *RecordedC6 = @ptrCast(@alignCast(context));
        self.note(Error.QueueFull);
    }
};

/// Puts the recorded port on `bridge`. A bridge already recorded stays as it
/// is. Call it on the thread that steps the board.
pub fn attach(gpa: std.mem.Allocator, session: *api.Session, bridge: *hosted.net.Bridge) !void {
    if (from(bridge) != null) return;
    const self = try gpa.create(RecordedC6);
    self.* = .{ .gpa = gpa, .session = session };
    bridge.landing = .{
        .context = self,
        .enterFn = RecordedC6.enter,
        .landedFn = RecordedC6.landed,
        .dueFn = RecordedC6.due,
        .failFn = RecordedC6.full,
    };
}

/// The recorded port on `bridge`, or null when it is not recorded.
pub fn from(bridge: *const hosted.net.Bridge) ?*RecordedC6 {
    const landing = bridge.landing orelse return null;
    if (landing.enterFn != &RecordedC6.enter) return null;
    return @ptrCast(@alignCast(landing.context));
}

/// Takes the recorded port off `bridge`.
pub fn release(bridge: *hosted.net.Bridge) void {
    const self = from(bridge) orelse return;
    bridge.landing = null;
    self.gpa.destroy(self);
}
