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
const history_strip = @import("../ui/history_strip.zig");
const history_track = @import("../history_track.zig");
const time_bar_capture = @import("../time/bar_capture.zig");
const speed_field = @import("../speed_field.zig");
const seek_field = @import("../seek_field.zig");
const time_readout = @import("../time/readout.zig");
const status_bar = @import("../status/bar.zig");
const session_link = @import("../session_link.zig");
const shell_run = @import("run.zig");

const geom = @import("../geom.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const Rect = geom.Rect;
const Link = session_link.Link;
const Status = status_bar.Status;

/// How often the clock is read while the image runs.
pub const poll_ns: u64 = 250 * std.time.ns_per_ms;

pub const Time = struct {
    run: shell_run.Run = .{},
    field: speed_field.Field = .{},
    /// The bar's seek field: a target the transport's grammar names, sent
    /// on Enter (slice 19).
    seek: seek_field.Field = .{},
    /// The seek field has the keyboard. Never on with `editing`: each
    /// focus change lets the other field go.
    seek_editing: bool = false,
    readout: time_readout.Readout = .{},
    /// The speed field has the keyboard.
    editing: bool = false,
    /// Whether the speed preset dropdown popover is open.
    open: bool = false,
    /// The clock is to be read though nothing runs.
    stale: bool = true,
    polled_ns: u64 = 0,
    texts: time_bar_capture.Texts = .{},

    /// A left press at (`x`, `y`) with the bar drawn in `bar`. A press off
    /// the speed field lets the keyboard go. Returns whether the bar took it.
    /// The machine-history track's model so far; filled from the link's
    /// history facts once the session answers them.
    track: history_track.Track = .{},

    pub fn press(self: *Time, bar: Rect, x: i32, y: i32, status: *Status, link: *Link) bool {
        const control = time_bar.hit(shell_frame.toList(bar), x, y);
        if (control) |c| {
            switch (c) {
                .drop => {
                    self.open = !self.open;
                    self.editing = false;
                    self.field.cancel();
                    self.seek_editing = false;
                    self.seek.cancel();
                    return true;
                },
                .field => {
                    self.open = false;
                    self.seek_editing = false;
                    self.seek.cancel();
                    if (!self.editing) {
                        self.editing = true;
                        self.field.startEditing();
                    }
                    return true;
                },
                .seek => {
                    self.open = false;
                    self.editing = false;
                    self.field.cancel();
                    if (!self.seek_editing) {
                        self.seek_editing = true;
                        self.seek.startEditing();
                    }
                    return true;
                },
                else => {
                    self.open = false;
                    self.editing = false;
                    self.field.cancel();
                    self.seek_editing = false;
                    self.seek.cancel();
                    self.pressCommand(c, link, status);
                    return true;
                },
            }
        }
        self.open = false;
        if (self.editing) {
            self.editing = false;
            self.field.cancel();
        }
        if (self.seek_editing) {
            self.seek_editing = false;
            self.seek.cancel();
        }
        return geom.contains(bar, x, y);
    }

    /// Check whether a press hit the open speed dropdown popover or dismissed it.
    pub fn pressDropdown(self: *Time, bar: Rect, x: i32, y: i32, link: *Link) bool {
        if (!self.open) return false;
        const layout = time_bar.Layout.of(shell_frame.toList(bar));
        if (time_bar.hitDropdown(layout.field, self.open, x, y)) |row_index| {
            const preset = speed_field.presets[row_index];
            _ = self.field.choose(link, preset.milli) catch {};
            self.open = false;
            return true;
        }
        if (time_bar.dropBox(layout.field).contains(x, y)) {
            self.open = false;
            return true;
        }
        if (layout.field.contains(x, y)) {
            self.open = false;
            self.seek_editing = false;
            self.seek.cancel();
            self.editing = true;
            self.field.startEditing();
            return true;
        }
        if (layout.seek.contains(x, y)) {
            self.open = false;
            self.editing = false;
            self.field.cancel();
            self.seek_editing = true;
            self.seek.startEditing();
            return true;
        }
        self.open = false;
        return true;
    }

    /// One of the bar's commands from the menu strip or a shortcut key
    /// (RA8EMU-957): the button's press without the hit test.
    pub fn pressCommand(self: *Time, control: time_bar.Control, link: *Link, status: *Status) void {
        const was_lit = self.run.lit;
        time_bar_capture.press(control, status, &self.run, link) catch |err| {
            // A Step that never reached the session can be tried again.
            if (err == error.TableFull) return;
            status.refused = .run;
            return;
        };
        if (self.run.lit != was_lit) self.readout.achieved_milli = null;
        if (self.run.lit and !was_lit) self.readout.last = null;
    }

    /// A debugger step key over a source or disassembly pane (RA8EMU-1188):
    /// F10 over, F11 into, shift+F11 out, under the bar's one policy.
    pub fn stepKey(self: *Time, code: u32, shift: bool, status: *Status, link: *Link) bool {
        if (code == time_bar_capture.key_f5 and shift) {
            time_bar_capture.rcont(status, &self.run, link) catch {
                status.refused = .run;
                return true;
            };
            status.refused = null;
            return true;
        }
        const control = time_bar_capture.keyControl(code, shift) orelse return false;
        if (!time_bar_capture.enabled(control, status, &self.run)) return false;
        self.pressCommand(control, link, status);
        return true;
    }

    /// Typing and keys for the speed field while it has the keyboard.
    /// Returns whether the event was taken.
    pub fn handle(self: *Time, event: platform.Event, link: *Link, status: *Status) bool {
        if (self.open) {
            switch (event) {
                .key => |key| if (key.down and key.code == speed_field.codes.escape) {
                    self.open = false;
                    return true;
                },
                else => {},
            }
        }
        if (!self.editing and !self.seek_editing) {
            switch (event) {
                .key => |key| {
                    if (!key.down) return false;
                    return self.trackKeyFull(key.code, key.shift, status, link);
                },
                else => return false,
            }
        }
        switch (event) {
            .text => |text| if (self.seek_editing)
                self.seek.typed(text.slice())
            else
                self.field.typed(text.slice()),
            .key => |key| if (key.down) {
                if (self.seek_editing) {
                    const outcome = self.seek.key(status, &self.run, link, key.code) catch {
                        status.refused = .seek;
                        return true;
                    };
                    if (outcome == .sent or outcome == .cancel) self.seek_editing = false;
                } else {
                    const outcome = self.field.key(link, key.code) catch return true;
                    if (outcome == .sent or outcome == .cancel) self.editing = false;
                }
            },
            else => return false,
        }
        return true;
    }

    /// Start a window frame at wall time `now_ns`: set what the frame owes
    /// the board, and read the clock when it is due.
    pub fn frame(self: *Time, link: *Link, now_ns: u64) void {
        self.field.retry(link);
        self.run.frame(now_ns, self.field.applied);
        const due = self.stale or ((self.run.lit or self.run.turbo_out) and now_ns -| self.polled_ns >= poll_ns);
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
        if (self.run.takeTurboArrival()) self.stale = true;
        if (seen == .other and stops(arrival)) self.stale = true;
        return seen;
    }

    /// Hand a pause's halt to the status bar. Returns whether one landed, so
    /// the caller can have the core's leaves read it again.
    pub fn settle(self: *Time, status: *Status) bool {
        if (self.run.turbo_refused) {
            self.run.turbo_refused = false;
            status.refused = .advance;
        }
        const at = self.run.halted() orelse return false;
        status.haltedAt(at);
        if (self.run.refused) status.refused = .run;
        self.stale = true;
        return true;
    }

    /// The session answered a load (RA8EMU-959). An image it took starts
    /// halted at its reset vector, so a lit Run goes dark with no halt of
    /// the old image to hand on, and the clock is read again; an image it
    /// refused leaves the run as it was.
    pub fn loaded(self: *Time, status: *const Status) void {
        if (status.refused != null and status.refused.? == .load) return;
        self.run.replaced();
        self.readout.achieved_milli = null;
        self.readout.last = null;
        self.stale = true;
    }

    /// Board time as near as the shell knows it: where the last slice
    /// ended, or the last clock answer.
    /// The strip's view from this controller's track so far.
    pub fn trackView(self: *const Time) history_strip.View {
        return .{ .track = self.track };
    }

    /// A click on the history strip (slice 19): the x resolves through
    /// the strip's geometry and the track's click model into a virtual
    /// time, and the seek goes to the transport. A press that hit the
    /// strip is consumed even when the transport refuses, which the
    /// status bar names. A click past the recorded end is the turbo
    /// run's to start; until that lands it is consumed without a
    /// dispatch.
    pub fn pressTrack(self: *Time, strip: Rect, x: i32, status: *Status, link: *Link) bool {
        const fraction = history_strip.xToFraction(shell_frame.toList(strip), x) orelse return false;
        const hit = self.track.click(fraction) orelse return false;
        const ns = switch (hit) {
            .recorded => |ns| ns,
            .unrun => |ns| {
                // Past the recorded end: a turbo run to the clicked time.
                // Without a clock reading the aim cannot be sized, so the
                // click takes nothing; a click behind the clock is stale.
                const current = self.readout.virtual_ns orelse return true;
                if (ns <= current) return true;
                self.run.turbo(link, ns - current) catch {
                    status.refused = .advance;
                    return true;
                };
                status.refused = null;
                return true;
            },
        };
        var text: [40]u8 = undefined;
        const target = timeText(&text, ns) orelse return true;
        time_bar_capture.seek(status, &self.run, link, target) catch {
            status.refused = .seek;
            return true;
        };
        status.refused = null;
        return true;
    }

    /// A key while the bar's field has no keyboard (Slice 22.4): Home
    /// seeks to start, End to recorded end, Left/Right prev/next frame,
    /// and Space/Shift+Space play forward/back.
    pub fn trackKeyFull(self: *Time, code: u32, shift: bool, status: *Status, link: *Link) bool {
        if (code == time_bar_capture.key_space) {
            if (self.run.lit) {
                self.pressCommand(.pause, link, status);
                return true;
            }
            if (shift) {
                time_bar_capture.play(status, &self.run, link, .back) catch {
                    status.refused = .run;
                    return true;
                };
                self.run.lit = true;
                status.refused = null;
                return true;
            }
            self.pressCommand(.run, link, status);
            return true;
        }
        if (code == time_bar_capture.key_left) {
            time_bar_capture.seek(status, &self.run, link, "prev") catch {
                status.refused = .seek;
                return true;
            };
            status.refused = null;
            return true;
        }
        if (code == time_bar_capture.key_right) {
            time_bar_capture.seek(status, &self.run, link, "next") catch {
                status.refused = .seek;
                return true;
            };
            status.refused = null;
            return true;
        }
        const end = self.track.end_ns orelse return false;
        if (end == 0) return false;
        const target_ns: u64 = switch (code) {
            time_bar_capture.key_home => 0,
            time_bar_capture.key_end => end,
            else => return false,
        };
        var text: [40]u8 = undefined;
        const target = timeText(&text, target_ns) orelse return true;
        time_bar_capture.seek(status, &self.run, link, target) catch {
            status.refused = .seek;
            return true;
        };
        status.refused = null;
        return true;
    }

    /// The seek target's text for a virtual time: whole seconds, then
    /// the milliseconds a click's resolution carries.
    pub fn timeText(buffer: *[40]u8, ns: u64) ?[]const u8 {
        const seconds = ns / 1_000_000_000;
        const millis = (ns % 1_000_000_000) / 1_000_000;
        return std.fmt.bufPrint(buffer, "{d}.{d:0>3}s", .{ seconds, millis }) catch null;
    }

    pub fn boardNow(self: *const Time) u64 {
        return @max(self.run.board_ns orelse 0, self.readout.virtual_ns orelse 0);
    }

    /// The bar's view. Its text lives in `self` until the next call.
    pub fn view(self: *Time, status: *const Status) time_bar.View {
        return time_bar_capture.view(&self.texts, status, &self.field, &self.seek, &self.readout, &self.run, self.editing, self.seek_editing, self.open);
    }
};

fn stops(arrival: session_link.Arrival) bool {
    return switch (arrival) {
        .event => |event| event.topic == @backingInt(proto.Topic.stop),
        .response => false,
    };
}
