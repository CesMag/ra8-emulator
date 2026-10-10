//! The shell's device list (RA8EMU-792): the parts fitted on each endpoint,
//! as the session lists them over the wire (list_parts, RA8EMU-791). Once the
//! link is connected it asks; the reply's `MODEL@ENDPOINT` lines are kept
//! and drawn one row each, the part's name then its endpoint, muted. Each
//! row ends in an unplug cell (RA8EMU-801): a click there sends unplug for
//! the row's endpoint, and once the session answers the list is asked for
//! again, so the rows follow the board.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_link = @import("session_link.zig");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell_frame.zig");

/// Rows sit this far apart, a glyph and a gap.
pub const row_h: i32 = font.glyph_h + 3;
/// The endpoint column starts past the longest catalog name (max17048).
pub const name_cells: usize = 9;
/// The unplug cell's mark, one cell wide at the row's right end.
pub const unplug_mark = "x";

pub const Devices = struct {
    text: [proto.PartList.max_len.text]u8 = undefined,
    len: usize = 0,
    /// The list ask in flight.
    asked: ?u32 = null,
    /// A list ask is due on the next attach.
    want: bool = true,
    answered: bool = false,
    refused: bool = false,
    /// The unplug ask in flight.
    unplugging: ?u32 = null,
    unplug_refused: bool = false,

    /// Ask for cpu0's parts after the session greets, and again after
    /// each unplug the session answers.
    pub fn attach(self: *Devices, link: *session_link.Link) void {
        if (!self.want or self.asked != null or link.state != .connected) return;
        self.asked = link.send(proto.CoreOnly, .list_parts, .{ .core = .cpu0 }) catch return;
        self.want = false;
    }

    /// Keep the listing from the response to our ask and note the answer
    /// to our unplug; ignore the rest.
    pub fn observe(self: *Devices, arrival: session_link.Arrival) void {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return,
        };
        if (self.unplugging != null and self.unplugging == response.id) {
            self.unplugging = null;
            self.unplug_refused = response.result == .err;
            self.want = true;
            return;
        }
        if (self.asked != response.id) return;
        self.asked = null;
        self.answered = true;
        self.refused = false;
        const body = switch (response.result) {
            .ok => |body| body,
            .err => return self.refuse(),
        };
        const list = proto.decode(proto.PartList, body) catch return self.refuse();
        const kept = @min(list.text.len, self.text.len);
        @memcpy(self.text[0..kept], list.text[0..kept]);
        self.len = kept;
    }

    fn refuse(self: *Devices) void {
        self.refused = true;
    }

    /// The listing's lines, one fitted part each.
    pub fn lines(self: *const Devices) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.text[0..self.len], '\n');
    }

    /// The listing's line at `row`, or null past the last.
    pub fn line(self: *const Devices, row: usize) ?[]const u8 {
        var rows = self.lines();
        var at: usize = 0;
        while (rows.next()) |found| : (at += 1) if (at == row) return found;
        return null;
    }

    /// Ask the session to unplug the part on `row`. False when there is no
    /// such row, an unplug is already in flight, or the send failed.
    pub fn unplug(self: *Devices, link: *session_link.Link, row: usize) bool {
        if (self.unplugging != null) return false;
        const part = split(self.line(row) orelse return false);
        const args: proto.PartSpec = .{ .core = .cpu0, .text = part.at };
        self.unplugging = link.send(proto.PartSpec, .unplug, args) catch return false;
        self.unplug_refused = false;
        return true;
    }

    /// Route a left press at (`x`, `y`) to the unplug cell of a devices
    /// leaf's row. Returns whether an unplug was asked.
    pub fn clickIn(self: *Devices, link: *session_link.Link, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        for (solved.panes.items) |placed| {
            const pane = layout.pane(placed.index) orelse continue;
            if (pane.kind != .devices) continue;
            const row = unplugRowAt(shell_frame.bodyOf(placed.area), x, y) orelse continue;
            return self.unplug(link, row);
        }
        return false;
    }

    /// The note the leaf shows instead of rows, or null when it has rows.
    pub fn note(self: *const Devices) ?[]const u8 {
        if (!self.answered) return null;
        if (self.refused) return "the session would not list its parts";
        if (self.len == 0) return "no parts fitted";
        return null;
    }
};

/// A listing line split into the part's name and its endpoint.
pub fn split(text: []const u8) struct { name: []const u8, at: []const u8 } {
    const mark = std.mem.indexOfScalar(u8, text, '@') orelse return .{ .name = "", .at = text };
    return .{ .name = text[0..mark], .at = text[mark + 1 ..] };
}

/// Row `row`'s unplug cell inside `body`.
pub fn unplugCell(body: draw_list.Rect, row: usize) draw_list.Rect {
    const w: i32 = @intCast(font.textWidth(1));
    const y = body.y + shell_frame.pad + @as(i32, @intCast(row)) * row_h;
    return .{ .x = body.x + body.w - shell_frame.pad - w, .y = y, .w = w, .h = font.glyph_h };
}

/// The row whose unplug cell holds (`x`, `y`) inside `body`, or null.
pub fn unplugRowAt(body: draw_list.Rect, x: i32, y: i32) ?usize {
    if (!body.contains(x, y) or y < body.y + shell_frame.pad) return null;
    const row: usize = @intCast(@divTrunc(y - body.y - shell_frame.pad, row_h));
    return if (unplugCell(body, row).contains(x, y)) row else null;
}

/// Draw one row per fitted part inside `body`, as many as fit, then the
/// unplug refusal when there was one.
pub fn draw(list: *draw_list.DrawList, body: draw_list.Rect, devices: *const Devices) !void {
    const room = body.w - 2 * shell_frame.pad;
    if (room <= 0) return;
    const x = body.x + shell_frame.pad;
    const column: i32 = @intCast(font.textWidth(name_cells));
    const mark: i32 = @intCast(font.textWidth(1));
    var y = body.y + shell_frame.pad;
    var row: usize = 0;
    var rows = devices.lines();
    while (rows.next()) |text| : ({
        y += row_h;
        row += 1;
    }) {
        if (y + font.glyph_h > body.y + body.h) return;
        const part = split(text);
        try font.draw(list, x, y, font.fit(part.name, @intCast(room)), shell_frame.ink);
        if (room > column + mark) try font.draw(list, x + column, y, font.fit(part.at, @intCast(room - column - mark)), shell_frame.muted);
        const cell = unplugCell(body, row);
        if (room > mark) try font.draw(list, cell.x, cell.y, unplug_mark, shell_frame.muted);
    }
    if (!devices.unplug_refused or y + font.glyph_h > body.y + body.h) return;
    try font.draw(list, x, y, font.fit("the session would not unplug that part", @intCast(room)), shell_frame.muted);
}
