//! Touch on the board pane's panel (RA8EMU-812). A window pixel maps to a
//! panel pixel through the rect the panel image is drawn in (the pane's
//! panel area fitted to the image's aspect), clamped to the panel. A press
//! that starts on the image becomes one touch gesture on release: a tap,
//! a long press when it was held in place, or a swipe when it moved. The
//! wire carries whole gestures (RA8EMU-810), so the pane sends one `input`
//! request per release.
const proto = @import("ra8_rpc").session_rpc;
const draw_list = @import("ra8_render").draw_list;
const board_pane = @import("ui/board_pane.zig");
const fit = @import("ui/fit.zig");
const session_link = @import("session_link.zig");

const Rect = draw_list.Rect;

/// A release within this many panel pixels of the press is not a swipe.
pub const slop: u16 = 4;
/// A press held in place this long, in virtual time, is a long press.
pub const longpress_ns: u64 = 500_000_000;

pub const Point = struct { x: u16, y: u16 };

/// Where a panel of `width` x `height` pixels is drawn inside the pane.
pub fn shownIn(layout: board_pane.Layout, width: u32, height: u32) Rect {
    return fit.fitIn(layout.panel, width, height);
}

/// The panel pixel under window pixel (x, y), clamped to the panel.
pub fn toPanel(shown: Rect, width: u32, height: u32, x: i32, y: i32) Point {
    return .{ .x = axis(x - shown.x, shown.w, width), .y = axis(y - shown.y, shown.h, height) };
}

/// Ends map to ends, so the panel's last pixel is reachable at any scale.
fn axis(offset: i32, span: i32, pixels: u32) u16 {
    if (span <= 1 or pixels == 0) return 0;
    const inside: i64 = @min(@max(offset, 0), span - 1);
    return @intCast(@divTrunc(inside * (@as(i64, pixels) - 1), span - 1));
}

pub const Gesture = struct {
    kind: proto.InputKind,
    from: Point,
    to: Point,
    duration_ns: u64,
};

pub const Drag = struct {
    /// Where and when the press started on the panel, while it is down.
    start: ?Point = null,
    started_ns: u64 = 0,
    last: Point = .{ .x = 0, .y = 0 },

    pub fn down(self: *Drag, shown: Rect, width: u32, height: u32, x: i32, y: i32, now_ns: u64) void {
        if (!shown.contains(x, y)) return;
        const at = toPanel(shown, width, height, x, y);
        self.* = .{ .start = at, .started_ns = now_ns, .last = at };
    }

    pub fn move(self: *Drag, shown: Rect, width: u32, height: u32, x: i32, y: i32) void {
        if (self.start == null) return;
        self.last = toPanel(shown, width, height, x, y);
    }

    /// The gesture this release ends, if the press started on the panel.
    pub fn up(self: *Drag, shown: Rect, width: u32, height: u32, x: i32, y: i32, now_ns: u64) ?Gesture {
        const from = self.start orelse return null;
        self.move(shown, width, height, x, y);
        self.start = null;
        const held = now_ns -| self.started_ns;
        const moved = far(from.x, self.last.x) or far(from.y, self.last.y);
        const kind: proto.InputKind = if (moved) .swipe else if (held >= longpress_ns) .longpress else .tap;
        return .{ .kind = kind, .from = from, .to = if (moved) self.last else from, .duration_ns = held };
    }
};

fn far(a: u16, b: u16) bool {
    return (if (a > b) a - b else b - a) > slop;
}

/// The input request for `gesture` on `core` at virtual `at_ns`.
pub fn request(core: proto.Core, gesture: Gesture, at_ns: u64) proto.ScheduleInput {
    return .{
        .core = core,
        .at_ns = at_ns,
        .kind = gesture.kind,
        .x = gesture.from.x,
        .y = gesture.from.y,
        .to_x = gesture.to.x,
        .to_y = gesture.to.y,
        .duration_ns = gesture.duration_ns,
    };
}

pub fn send(link: *session_link.Link, core: proto.Core, gesture: Gesture, at_ns: u64) !u32 {
    return link.send(proto.ScheduleInput, .input, request(core, gesture, at_ns));
}
