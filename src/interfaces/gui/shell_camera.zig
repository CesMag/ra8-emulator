//! The shell's camera leaf (RA8EMU-796): the camera panel (RA8EMU-500,
//! RA8EMU-677) drawn in the leaf, its clicks routed into the panel, and each
//! pick sent to the session with set_camera_source (RA8EMU-795). The webcam
//! passes the panel's own consent dialog first, so only then does the ask
//! carry allow_webcam. The panel's ring follows the source the session runs:
//! a refusal, or a kind that still needs a file, puts it back on the last
//! source the session took. The kind that needed a file is kept in `wants`
//! for the leaf's file field (RA8EMU-799).
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_link = @import("session_link.zig");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell_frame.zig");
const camera_panel = @import("camera_panel.zig");
const camera_view = @import("ui/camera_view.zig");
const camera_open = @import("camera_open.zig");
const Spec = @import("ra8_host").camera.source_spec.Spec;

const Kind = camera_panel.Kind;

/// Where the session's answer to the last pick stands.
pub const Status = enum { idle, asking, switched, refused, needs_file };

pub const Camera = struct {
    panel: camera_panel.Panel = .{},
    args: camera_open.Args = .{},
    /// The source the session runs, as far as the shell knows.
    running: Kind = .gradient,
    /// The panel's change count the last ask (or skip) answered.
    seen: u32 = 0,
    asked: ?u32 = null,
    asked_kind: Kind = .gradient,
    status: Status = .idle,
    /// The kind last picked without a file, waiting for its path.
    wants: ?Kind = null,

    /// Send the panel's newest pick, once per change, while connected.
    pub fn attach(self: *Camera, link: *session_link.Link) void {
        if (link.state != .connected or self.panel.changes == self.seen) return;
        self.seen = self.panel.changes;
        const spec = camera_open.spec(self.panel, self.args) catch {
            self.wants = self.panel.active;
            return self.back(.needs_file);
        };
        var buffer: [proto.CameraSource.max_len.text]u8 = undefined;
        const text = specText(&buffer, spec) catch return self.back(.refused);
        const args: proto.CameraSource = .{ .text = text, .allow_webcam = @intFromBool(spec.allow_webcam) };
        self.asked = link.send(proto.CameraSource, .set_camera_source, args) catch return;
        self.asked_kind = spec.kind;
        self.status = .asking;
    }

    /// Take the session's answer to our ask; ignore everything else.
    pub fn observe(self: *Camera, arrival: session_link.Arrival) void {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return,
        };
        if (self.asked != response.id) return;
        self.asked = null;
        switch (response.result) {
            .ok => {
                self.running = self.asked_kind;
                self.status = .switched;
            },
            .err => self.back(.refused),
        }
    }

    /// Put the ring back on the running source without asking again.
    fn back(self: *Camera, status: Status) void {
        self.panel.active = self.running;
        self.status = status;
    }

    /// What the leaf says under the panel, or null with nothing to say.
    pub fn note(self: *const Camera) ?[]const u8 {
        return switch (self.status) {
            .idle => null,
            .asking => "asking the session to switch",
            .switched => "the session switched source",
            .refused => "the session refused that source",
            .needs_file => "that source needs a file: type its path below, then Enter",
        };
    }

    /// Route a left press at (`x`, `y`) into the panel of the camera leaf
    /// it lands in. Returns whether a camera leaf took it.
    pub fn clickIn(self: *Camera, layout: *const pane_layout.Layout, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        for (solved.panes.items) |placed| {
            const leaf = switch (layout.node(placed.index).body) {
                .leaf => |leaf| leaf,
                else => continue,
            };
            if (leaf.kind != .camera) continue;
            const body = shell_frame.bodyOf(placed.area);
            if (body.contains(x, y)) return camera_view.click(&self.panel, layoutIn(body), x, y);
        }
        return false;
    }
};

/// Start the panel on `spec`, the `--camera-source` flag (RA8EMU-1095):
/// its argument goes where the panel looks for that kind's file, and the
/// pick goes to the session like any other once the shell connects. The
/// webcam still passes the panel's consent dialog.
pub fn start(camera: *Camera, spec: Spec) void {
    switch (spec.kind) {
        .gradient, .webcam => {},
        .image => camera.args.image = spec.arg,
        .video => camera.args.video = spec.arg,
        .pipe => camera.args.pipe = spec.arg,
    }
    if (spec.kind == .webcam) camera.args.webcam = spec.arg;
    camera.panel.pick(spec.kind);
}

/// The text set_camera_source takes: `KIND` or `KIND:ARG`, as on the
/// command line.
pub fn specText(buffer: []u8, spec: Spec) ![]const u8 {
    if (spec.arg.len == 0) return std.fmt.bufPrint(buffer, "{s}", .{@tagName(spec.kind)});
    return std.fmt.bufPrint(buffer, "{s}:{s}", .{ @tagName(spec.kind), spec.arg });
}

/// The panel's corner inside a leaf body.
pub fn layoutIn(body: draw_list.Rect) camera_view.Layout {
    return .{ .x = body.x + shell_frame.pad, .y = body.y + shell_frame.pad };
}

/// Draw the panel at the top of `body`, its note on the row below.
pub fn draw(list: *draw_list.DrawList, body: draw_list.Rect, camera: *const Camera) !void {
    const layout = layoutIn(body);
    try camera_view.draw(list, layout, camera.panel);
    const said = camera.note() orelse return;
    const area = layout.area();
    const y = area.y + area.h + shell_frame.pad;
    const room = body.w - 2 * shell_frame.pad;
    if (room <= 0 or y + font.glyph_h > body.y + body.h) return;
    try font.draw(list, layout.x, y, font.fit(said, @intCast(room)), shell_frame.muted);
}
