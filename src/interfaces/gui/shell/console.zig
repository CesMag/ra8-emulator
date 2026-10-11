//! The shell's console feed (RA8EMU-787): the session's UART output, kept
//! in a console log stamped with board time. Once the link is connected it
//! subscribes both cores' uart topic; each uart event's bytes land in the
//! log at the event's own virtual time (RA8EMU-774). The leaf scrolls back
//! and saves the log to a file (RA8EMU-1122).
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const console_log = @import("../console/log.zig");
const console_scroll = @import("../console/scroll.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const console_pane = @import("../ui/console_pane.zig");
const console_strip = @import("../ui/console_strip.zig");
const console_save = @import("../console/save.zig");

/// Lines the shell's console keeps before the oldest falls off.
pub const scrollback: usize = 2000;

pub const Console = struct {
    log: console_log.Log,
    subscribed: bool = false,
    /// How far back the console leaves are scrolled (RA8EMU-1122).
    scroll: console_scroll.Scroll = .{},
    /// Where the save tab writes the log; null leaves the tab inert.
    save_to: ?console_save.Target = null,
    /// What the last save did, shown on the save tab.
    saved: console_save.Outcome = .none,

    pub fn init(allocator: std.mem.Allocator) Console {
        return .{ .log = console_log.Log.init(allocator, scrollback) };
    }

    pub fn deinit(self: *Console) void {
        self.log.deinit();
    }

    /// Subscribe both cores' UART output, once, after the session greets.
    pub fn attach(self: *Console, link: *session_link.Link) void {
        if (self.subscribed or link.state != .connected) return;
        for ([_]proto.Core{ .cpu0, .cpu1 }) |core| {
            _ = link.send(proto.Subscription, .subscribe, .{ .core = core, .topic = .uart }) catch return;
        }
        self.subscribed = true;
    }

    /// Feed a uart event's bytes into the log at its board time.
    pub fn observe(self: *Console, arrival: session_link.Arrival) error{OutOfMemory}!void {
        const event = switch (arrival) {
            .event => |event| event,
            .response => return,
        };
        if (event.topic != @backingInt(proto.Topic.uart)) return;
        const sent = proto.decode(proto.Uart, event.payload) catch return;
        try self.log.feedAll(sent.bytes, sent.virtual_ns);
        self.scroll.follow(&self.log);
    }

    /// A wheel turn with the pointer at `x`, `y`: scrolls when it is over
    /// a console leaf.
    pub fn wheelIn(self: *Console, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32, dy: f32) bool {
        _ = bodyAt(layout, solved, x, y) orelse return false;
        self.scroll.wheel(dy, &self.log);
        return true;
    }

    /// Page Up or Page Down with the pointer at `x`, `y` over a console
    /// leaf: moves by the rows that leaf shows.
    pub fn pageIn(self: *Console, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32, code: u32) bool {
        const body = bodyAt(layout, solved, x, y) orelse return false;
        return self.scroll.page(code, console_pane.rows(console_strip.below(body)), &self.log);
    }

    /// A left press at `x`, `y`: true when it fell on a console leaf's
    /// save tab, which writes the log to the project directory.
    pub fn clickIn(self: *Console, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        if (!self.hasOutput()) return false;
        const body = bodyAt(layout, solved, x, y) orelse return false;
        if (!console_strip.saveTab(body).contains(x, y)) return false;
        const target = self.save_to orelse return true;
        self.saved = console_save.attempt(target, &self.log);
        return true;
    }

    /// Whether the log holds anything to show yet.
    pub fn hasOutput(self: *const Console) bool {
        return self.log.lines().len > 0 or self.log.partial().len > 0;
    }
};

/// The body of the console leaf under a point, if any.
fn bodyAt(layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) ?pane_layout.Rect {
    for (solved.panes.items) |placed| {
        const pane = layout.pane(placed.index) orelse continue;
        if (pane.kind != .console) continue;
        const body = shell_frame.bodyOf(placed.area);
        if (body.contains(x, y)) return body;
    }
    return null;
}
