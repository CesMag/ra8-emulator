//! The fault cell on each row of the shell's devices leaf (RA8EMU-817). A
//! click steps the row's part through a fixed cycle of fault modes: the step
//! to a mode sends set_fault `@ENDPOINT=MODE`, and the step back to none
//! sends clear_fault `ENDPOINT`. list_parts carries no mode, so the active
//! mode is kept here per endpoint and moves only when the session answers
//! ok. A refusal leaves the mode alone and becomes a note; the next click
//! still moves on, so a mode the part cannot carry never stalls the cycle.
const std = @import("std");
const proto = @import("../rpc/session_rpc.zig");
const session_link = @import("session_link.zig");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell_frame.zig");
const shell_devices = @import("shell_devices.zig");

/// The cycle after none. Each takes an argument the session parses and fits
/// any I2C part; SPI and UART parts refuse nack, which the note shows.
pub const modes = [_][]const u8{ "disconnected", "nack:2", "stuck:0xff", "garbage:1" };
/// The cell is as wide as the longest mode, just left of the unplug cell.
pub const cells: usize = 12;
pub const none_mark = "-";
pub const refused_note = "the session would not fault that part";
/// Endpoints whose mode is remembered; one per fitted part is plenty.
pub const max_parts: usize = 16;
const max_at: usize = 48;

/// The step after `mode`, where 0 is none and 1.. index `modes`.
pub fn next(mode: usize) usize {
    return (mode + 1) % (modes.len + 1);
}

pub fn label(mode: usize) []const u8 {
    return if (mode == 0) none_mark else modes[mode - 1];
}

pub const Ask = struct { method: proto.Method, text: []const u8 };

/// The ask that moves the part on `at` to `mode`, spelled into `buf`.
pub fn ask(buf: []u8, at: []const u8, mode: usize) error{NoSpaceLeft}!Ask {
    if (mode == 0) return .{ .method = .clear_fault, .text = at };
    const text = try std.fmt.bufPrint(buf, "@{s}={s}", .{ at, modes[mode - 1] });
    return .{ .method = .set_fault, .text = text };
}

const Slot = struct {
    at: [max_at]u8 = undefined,
    len: usize = 0,
    mode: usize = 0,
};

pub const Faults = struct {
    slots: [max_parts]Slot = @splat(Slot{}),
    used: usize = 0,
    /// The ask in flight, the endpoint it names and the mode it moves to.
    asked: ?u32 = null,
    pending: Slot = .{},
    refused: bool = false,

    /// The active mode of the part on `at`; none when never faulted.
    pub fn modeOf(self: *const Faults, at: []const u8) usize {
        for (self.slots[0..self.used]) |*slot| {
            if (std.mem.eql(u8, slot.at[0..slot.len], at)) return slot.mode;
        }
        return 0;
    }

    /// Step the part on `at` to its next mode. False when an ask is already
    /// in flight, the endpoint is too long to keep, or the send failed.
    pub fn cycle(self: *Faults, link: *session_link.Link, at: []const u8) bool {
        if (self.asked != null or at.len > max_at) return false;
        const mode = next(self.modeOf(at));
        var buf: [proto.PartSpec.max_len.text]u8 = undefined;
        const wanted = ask(&buf, at, mode) catch return false;
        self.asked = link.send(proto.PartSpec, wanted.method, .{ .core = .cpu0, .text = wanted.text }) catch return false;
        self.pending = .{ .len = at.len, .mode = mode };
        @memcpy(self.pending.at[0..at.len], at);
        self.refused = false;
        return true;
    }

    /// Note the answer to our ask. Returns whether it was ours, so the
    /// caller can ask for the list again.
    pub fn observe(self: *Faults, arrival: session_link.Arrival) bool {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return false,
        };
        if (self.asked == null or self.asked != response.id) return false;
        self.asked = null;
        if (response.result == .err) {
            self.refused = true;
            return true;
        }
        self.keep(self.pending);
        return true;
    }

    fn keep(self: *Faults, moved: Slot) void {
        const at = moved.at[0..moved.len];
        for (self.slots[0..self.used]) |*slot| {
            if (std.mem.eql(u8, slot.at[0..slot.len], at)) {
                slot.mode = moved.mode;
                return;
            }
        }
        if (self.used == max_parts) return;
        self.slots[self.used] = moved;
        self.used += 1;
    }

    /// Route a left press at (`x`, `y`) to the fault cell of a devices
    /// leaf's row. Returns whether a fault ask was sent.
    pub fn clickIn(self: *Faults, link: *session_link.Link, devices: *const shell_devices.Devices, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .devices) continue;
            const row = rowAt(shell_frame.bodyOf(placed.area), x, y) orelse continue;
            const line = devices.line(row) orelse return false;
            return self.cycle(link, shell_devices.split(line).at);
        }
        return false;
    }
};

/// Row `row`'s fault cell inside `body`, just left of its unplug cell.
pub fn cell(body: draw_list.Rect, row: usize) draw_list.Rect {
    const unplug = shell_devices.unplugCell(body, row);
    const w: i32 = @intCast(font.textWidth(cells));
    const gap: i32 = @intCast(font.textWidth(1));
    return .{ .x = unplug.x - gap - w, .y = unplug.y, .w = w, .h = unplug.h };
}

/// The row whose fault cell holds (`x`, `y`) inside `body`, or null.
pub fn rowAt(body: draw_list.Rect, x: i32, y: i32) ?usize {
    if (!body.contains(x, y) or y < body.y + shell_frame.pad) return null;
    const row: usize = @intCast(@divTrunc(y - body.y - shell_frame.pad, shell_devices.row_h));
    return if (cell(body, row).contains(x, y)) row else null;
}

/// Draw each listed row's mode in its fault cell: a mode in ink, none muted.
/// A refused ask leaves its note on the line under the rows (and under the
/// unplug refusal when that is up too).
pub fn draw(list: *draw_list.DrawList, body: draw_list.Rect, devices: *const shell_devices.Devices, faults: *const Faults) !void {
    var rows = devices.lines();
    var row: usize = 0;
    while (rows.next()) |text| : (row += 1) {
        const at = cell(body, row);
        if (at.x < body.x + shell_frame.pad or at.y + font.glyph_h > body.y + body.h) return;
        const mode = faults.modeOf(shell_devices.split(text).at);
        const color = if (mode == 0) shell_frame.muted else shell_frame.ink;
        try font.draw(list, at.x, at.y, label(mode), color);
    }
    if (!faults.refused) return;
    if (devices.unplug_refused) row += 1;
    const y = body.y + shell_frame.pad + @as(i32, @intCast(row)) * shell_devices.row_h;
    const room = body.w - 2 * shell_frame.pad;
    if (room <= 0 or y + font.glyph_h > body.y + body.h) return;
    try font.draw(list, body.x + shell_frame.pad, y, font.fit(refused_note, @intCast(room)), shell_frame.muted);
}
