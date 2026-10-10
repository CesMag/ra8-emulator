//! Pointer input on the shell's board leaf (RA8EMU-1119): a click on SW1 or
//! SW2 and a touch on the panel, sent to the session as `input` requests
//! (gui/board_input.zig, gui/board_touch.zig). A press grabs the board leaf
//! it lands in, and the moves and the release that follow are read against
//! that leaf until the button comes up, wherever the pointer has gone.
//!
//! The session refuses an input timed before its own clock, so each request
//! carries the board time the shell last knew: the end of the last slice, or
//! the last clock answer (gui/shell_time.zig).
const draw_list = @import("ra8_render").draw_list;
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell_frame.zig");
const board_pane = @import("ui/board_pane.zig");
const board_input = @import("board_input.zig");
const board_touch = @import("board_touch.zig");
const shell_board = @import("shell_board.zig");
const session_link = @import("session_link.zig");

const Rect = draw_list.Rect;
const Board = shell_board.Board;

pub const Pointer = struct {
    press: board_input.Press = .{},
    drag: board_touch.Drag = .{},
    /// The board leaf's body the button went down in, until it comes up.
    grabbed: ?Rect = null,

    /// A left press at (`x`, `y`) at board time `now_ns`. Returns whether it
    /// landed on a switch or on the panel image of a board leaf.
    pub fn down(self: *Pointer, board: *const Board, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32, now_ns: u64) bool {
        const body = bodyAt(layout, solved, x, y) orelse return false;
        const parts = board_pane.Layout.of(body);
        self.press.down(parts, x, y);
        if (board.hasFrame()) self.drag.down(board_touch.shownIn(parts, board.width, board.height), board.width, board.height, x, y, now_ns);
        if (self.press.held == null and self.drag.start == null) return false;
        self.grabbed = body;
        return true;
    }

    /// The pointer moved to (`x`, `y`) with the button still down.
    pub fn move(self: *Pointer, board: *const Board, x: i32, y: i32) void {
        const body = self.grabbed orelse return;
        if (!board.hasFrame()) return;
        const parts = board_pane.Layout.of(body);
        self.drag.move(board_touch.shownIn(parts, board.width, board.height), board.width, board.height, x, y);
    }

    /// The button came up at (`x`, `y`) at board time `now_ns`: send the
    /// switch click or the touch gesture this release ends, if it ends one.
    pub fn up(self: *Pointer, board: *const Board, link: *session_link.Link, x: i32, y: i32, now_ns: u64) void {
        const body = self.grabbed orelse return;
        self.grabbed = null;
        const parts = board_pane.Layout.of(body);
        if (self.press.up(parts, x, y)) |index| {
            _ = board_input.send(link, .cpu0, index, now_ns) catch {};
        }
        if (!board.hasFrame()) {
            self.drag.start = null;
            return;
        }
        const shown = board_touch.shownIn(parts, board.width, board.height);
        const gesture = self.drag.up(shown, board.width, board.height, x, y, now_ns) orelse return;
        _ = board_touch.send(link, .cpu0, gesture, now_ns) catch {};
    }
};

/// The body of the board leaf holding (`x`, `y`), or null.
pub fn bodyAt(layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) ?Rect {
    for (solved.panes.items) |placed| {
        const pane = layout.pane(placed.index) orelse continue;
        if (pane.kind != .board) continue;
        const body = shell_frame.bodyOf(placed.area);
        if (body.contains(x, y)) return body;
    }
    return null;
}
