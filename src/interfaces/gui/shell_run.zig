//! The shell's run (RA8EMU-1118): Run keeps a core going in slices, so the
//! window's thread never waits on a run it cannot stop. While Run is lit,
//! every window frame owes the board one frame of its own time at the speed
//! asked for, and `max` owes as much as fits. The frame pays in `advance`
//! requests (RA8EMU-654) of at most one unit each, and the next goes out
//! only once the last has answered, so a pause, a click or a redraw is never
//! further away than one slice. Board time a frame could not pay is dropped,
//! not carried to the next frame: a host that cannot keep up falls behind,
//! and the clock readout says by how much.
//!
//! A unit starts short and doubles while slices come back well inside the
//! frame's share of wall time, up to one frame of board time. A slice that
//! overruns the share shrinks it in proportion, which keeps the window at
//! its frame rate on a host too slow for the speed asked for.
//!
//! Every slice ends in a `count` stop. That is the slice's end and not the
//! run's, so `observe` names its stop event a boundary and nothing else
//! takes it for a stop. A pause is settled here: `halted` hands back where
//! the last slice left the core. A stop for any other reason ends the run,
//! and its stop event goes on to the status bar and the leaves.
//!
//! The sizing assumes a session that answers inside the frame, as the one
//! served in this process does.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_link = @import("session_link.zig");
const speed_field = @import("speed_field.zig");

const Link = session_link.Link;
const Arrival = session_link.Arrival;

/// One window frame: the board time a frame owes at 1x, and the longest unit.
pub const frame_ns: u64 = std.time.ns_per_s / 60;
/// The share of a frame's wall time its slices may take; the rest draws.
pub const share_ns: u64 = frame_ns * 3 / 4;
/// The unit a run starts from.
pub const first_unit_ns: u64 = 100 * std.time.ns_per_us;
/// The shortest unit a slow host is cut down to.
pub const least_unit_ns: u64 = 2 * std.time.ns_per_us;
/// The most slices one frame sends whatever the clock says, so a clock that
/// stands still cannot hold the frame.
pub const max_slices: u32 = 1024;

/// What `observe` made of an arrival.
pub const Seen = enum {
    /// Not the run's.
    other,
    /// The answer to the slice in flight.
    slice,
    /// The stop event that ends a slice: the run goes on, so nothing stopped.
    boundary,
};

pub const Run = struct {
    core: proto.Core = .cpu0,
    /// Run is lit: frames keep paying slices until a pause or a stop.
    lit: bool = false,
    /// The advance in flight, the board time it asked for and when it left.
    slice_id: ?u32 = null,
    asked_ns: u64 = 0,
    sent_ns: u64 = 0,
    /// Board time this frame still owes; null owes whatever fits (`max`).
    owed_ns: ?u64 = 0,
    /// The wall time this frame's slices stop by, and how many it has sent.
    until_ns: u64 = 0,
    sent: u32 = 0,
    unit_ns: u64 = first_unit_ns,
    /// Where the last slice left the core, or where Run found it.
    address: u32 = 0,
    /// Board time when the last slice ended.
    board_ns: ?u64 = null,
    /// The last slice's stop event is still to come.
    boundary_due: bool = false,
    /// A pause landed: where the core halted, until `halted` takes it.
    settled: ?u32 = null,
    /// The session refused the last slice.
    refused: bool = false,

    /// Light Run on a core halted at `address`.
    pub fn start(self: *Run, address: u32) void {
        if (self.lit) return;
        self.lit = true;
        self.refused = false;
        self.address = address;
        self.unit_ns = first_unit_ns;
        self.owed_ns = 0;
    }

    /// No further slice goes out. With none in flight the core is already
    /// halted where the last one left it.
    pub fn pause(self: *Run) void {
        if (!self.lit) return;
        self.lit = false;
        if (self.slice_id == null) self.settled = self.address;
    }

    /// Where a pause, or a refused slice, left the core; handed out once.
    pub fn halted(self: *Run) ?u32 {
        const at = self.settled orelse return null;
        self.settled = null;
        return at;
    }

    /// A new window frame at wall time `now_ns`. It owes one frame of board
    /// time at `milli` thousandths of real time, and nothing from before.
    pub fn frame(self: *Run, now_ns: u64, milli: u64) void {
        self.owed_ns = if (milli == speed_field.max_wire) null else @intCast(@as(u128, frame_ns) * milli / speed_field.real_time);
        self.until_ns = now_ns +| share_ns;
        self.sent = 0;
    }

    /// Send the frame's next slice. False when Run is not lit, a slice is
    /// still out, or the frame has paid what it owes or spent its share.
    pub fn next(self: *Run, link: *Link, now_ns: u64) bool {
        if (!self.lit or self.slice_id != null) return false;
        if (now_ns >= self.until_ns or self.sent == max_slices) return false;
        const want = if (self.owed_ns) |owed| @min(owed, self.unit_ns) else self.unit_ns;
        if (want == 0) return false;
        self.slice_id = link.send(proto.Advance, .advance, .{ .core = self.core, .ns = want }) catch return false;
        self.asked_ns = want;
        self.sent_ns = now_ns;
        self.sent += 1;
        return true;
    }

    /// Take an arrival at wall time `now_ns`.
    pub fn observe(self: *Run, arrival: Arrival, now_ns: u64) Seen {
        switch (arrival) {
            .response => |response| {
                if (self.slice_id == null or response.id != self.slice_id.?) return .other;
                self.slice_id = null;
                self.answered(response.result, now_ns);
                return .slice;
            },
            .event => |event| {
                if (!self.boundary_due or event.topic != @backingInt(proto.Topic.stop)) return .other;
                const stop = proto.decode(proto.Stopped, event.payload) catch return .other;
                if (stop.core != self.core or stop.reason != .count) return .other;
                self.boundary_due = false;
                return .boundary;
            },
        }
    }

    fn answered(self: *Run, result: proto.Client.Env.Result, now_ns: u64) void {
        const done = switch (result) {
            .ok => |bytes| proto.decode(proto.Advanced, bytes) catch return self.refuse(),
            .err => return self.refuse(),
        };
        const moved = done.to_ns -| done.from_ns;
        self.address = done.address;
        self.board_ns = done.to_ns;
        if (self.owed_ns) |owed| self.owed_ns = owed -| moved;
        // Board time that stands still has nothing more to pay this frame.
        if (moved == 0) self.until_ns = 0;
        self.resize(now_ns -| self.sent_ns);
        if (done.reason != .count) {
            self.lit = false;
            return;
        }
        self.boundary_due = true;
        if (!self.lit) self.settled = done.address;
    }

    fn refuse(self: *Run) void {
        self.lit = false;
        self.refused = true;
        self.settled = self.address;
    }

    /// Fit the unit to what the host just showed it can do.
    fn resize(self: *Run, took_ns: u64) void {
        if (took_ns > share_ns) {
            const fitted: u64 = @intCast(@as(u128, self.asked_ns) * share_ns / took_ns);
            self.unit_ns = @max(least_unit_ns, fitted);
        } else if (took_ns <= share_ns / 2 and self.asked_ns == self.unit_ns) {
            self.unit_ns = @min(frame_ns, self.unit_ns * 2);
        }
    }
};
