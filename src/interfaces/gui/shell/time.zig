//! The shell's time bar (RA8EMU-1118): the run, the speed field and the
//! clock readout behind the bar along the foot of the window. It takes the
//! bar's clicks and the speed field's typing, sets what each window frame
//! owes a lit run, and reads the session's clock: every `poll_ns` while the
//! image runs, and once after anything that may have moved it while it does
//! not. The bar itself (gui/ui/time_bar.zig) only lays out, paints and
//! hit-tests.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const draw_list = @import("ra8_render").draw_list;
const platform = @import("../platform.zig");
const time_bar = @import("../ui/time_bar.zig");
const time_bar_capture = @import("../time/bar_capture.zig");
const speed_field = @import("../speed_field.zig");
const time_readout = @import("../time/readout.zig");
const status_bar = @import("../status/bar.zig");
const session_link = @import("../session_link.zig");
const shell_run = @import("run.zig");

const Rect = draw_list.Rect;
const Link = session_link.Link;
const Status = status_bar.Status;

/// How often the clock is read while the image runs.
pub const poll_ns: u64 = 250 * std.time.ns_per_ms;

pub const Time = struct {
    run: shell_run.Run = .{},
    field: speed_field.Field = .{},
    readout: time_readout.Readout = .{},
    /// The speed field has the keyboard.
    editing: bool = false,
    /// The clock is to be read though nothing runs.
    stale: bool = true,
    polled_ns: u64 = 0,
    texts: time_bar_capture.Texts = .{},

    /// A left press at (`x`, `y`) with the bar drawn in `bar`. A press off
    /// the speed field lets the keyboard go. Returns whether the bar took it.
    pub fn press(self: *Time, bar: Rect, x: i32, y: i32, status: *Status, link: *Link) bool {
        const control = time_bar.hit(bar, x, y);
        self.editing = control != null and control.? == .field;
        const found = control orelse return bar.contains(x, y);
        const was_lit = self.run.lit;
        time_bar_capture.press(found, status, &self.run, link) catch {};
        // A run's speed is measured from where it starts, not across a halt.
        if (self.run.lit != was_lit) self.readout.achieved_milli = null;
        if (self.run.lit and !was_lit) self.readout.last = null;
        return true;
    }

    /// Typing and keys for the speed field while it has the keyboard.
    /// Returns whether the event was taken.
    pub fn handle(self: *Time, event: platform.Event, link: *Link) bool {
        if (!self.editing) return false;
        switch (event) {
            .text => |text| self.field.typed(text.slice()),
            .key => |key| if (key.down) {
                const outcome = self.field.key(link, key.code) catch return true;
                if (outcome == .sent or outcome == .cancel) self.editing = false;
            },
            else => return false,
        }
        return true;
    }

    /// Start a window frame at wall time `now_ns`: set what the frame owes
    /// the board, and read the clock when it is due.
    pub fn frame(self: *Time, link: *Link, now_ns: u64) void {
        self.run.frame(now_ns, self.field.applied);
        const due = self.stale or (self.run.lit and now_ns -| self.polled_ns >= poll_ns);
        if (!due or self.readout.waiting() or link.state != .connected) return;
        self.readout.poll(link) catch return;
        self.stale = false;
        self.polled_ns = now_ns;
    }

    /// Take an arrival at wall time `now_ns`. A slice boundary comes back as
    /// such, and the caller keeps it from everything that follows stops.
    pub fn observe(self: *Time, arrival: session_link.Arrival, now_ns: u64) shell_run.Seen {
        self.field.observe(arrival);
        self.readout.observe(arrival, now_ns);
        const seen = self.run.observe(arrival, now_ns);
        if (seen == .other and stops(arrival)) self.stale = true;
        return seen;
    }

    /// Hand a pause's halt to the status bar. Returns whether one landed, so
    /// the caller can have the core's leaves read it again.
    pub fn settle(self: *Time, status: *Status) bool {
        const at = self.run.halted() orelse return false;
        status.haltedAt(at);
        if (self.run.refused) status.refused = .run;
        self.stale = true;
        return true;
    }

    /// Board time as near as the shell knows it: where the last slice
    /// ended, or the last clock answer.
    pub fn boardNow(self: *const Time) u64 {
        return @max(self.run.board_ns orelse 0, self.readout.virtual_ns orelse 0);
    }

    /// The bar's view. Its text lives in `self` until the next call.
    pub fn view(self: *Time, status: *const Status) time_bar.View {
        return time_bar_capture.view(&self.texts, status, &self.field, &self.readout, self.editing);
    }
};

fn stops(arrival: session_link.Arrival) bool {
    return switch (arrival) {
        .event => |event| event.topic == @backingInt(proto.Topic.stop),
        .response => false,
    };
}
