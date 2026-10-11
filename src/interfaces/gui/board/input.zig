//! Clicks on the board pane's user switches (RA8EMU-814). A press that is
//! released over the button it started on is one click; the pane sends it as
//! a single `input` button request, because the board input script releases
//! the switch itself after its fixed press length. A release anywhere else
//! cancels the click.
const proto = @import("ra8_rpc").session.rpc;
const board_pane = @import("../ui/board_pane.zig");
const session_link = @import("../session_link.zig");

pub const Press = struct {
    /// The switch under the pointer since it went down, drawn pressed.
    held: ?usize = null,

    pub fn down(self: *Press, layout: board_pane.Layout, x: i32, y: i32) void {
        self.held = layout.hit(x, y);
    }

    /// The switch clicked by this release, if any.
    pub fn up(self: *Press, layout: board_pane.Layout, x: i32, y: i32) ?usize {
        const held = self.held orelse return null;
        self.held = null;
        const over = layout.hit(x, y) orelse return null;
        return if (over == held) held else null;
    }
};

/// Queues a click of switch `index` (0 = SW1, 1 = SW2) at virtual `at_ns`.
pub fn send(link: *session_link.Link, core: proto.Core, index: usize, at_ns: u64) !u32 {
    const args: proto.ScheduleInput = .{ .core = core, .at_ns = at_ns, .kind = .button, .button = @intCast(index) };
    return link.send(proto.ScheduleInput, .input, args);
}
