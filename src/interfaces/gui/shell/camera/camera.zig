//! The shell's camera leaf (RA8EMU-796): the camera panel (RA8EMU-500,
//! RA8EMU-677) drawn in the leaf, its clicks routed into the panel, and each
//! pick sent to the session with set_camera_source (RA8EMU-795). The webcam
//! passes the panel's own consent dialog first, so only then does the ask
//! carry allow_webcam. The panel's ring follows the source the session runs:
//! a refusal, or a kind that still needs a file, puts it back on the last
//! source the session took. The kind that needed a file is kept in `wants`
//! for the leaf's file field (RA8EMU-799). With a project to keep it in,
//! the dialog's Always outlasts the run (RA8EMU-1124, camera_always.zig).
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../../session_link.zig");
const Theme = @import("../../ui/colors.zig").Theme;
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const pane_layout = @import("../../ui/pane_layout.zig");
const shell_frame = @import("../../ui/shell/frame.zig");
const camera_panel = @import("../../camera/panel.zig");
const camera_view = @import("../../ui/camera_view.zig");
const camera_open = @import("../../camera/open.zig");
const camera_always = @import("../../camera/always.zig");
const camera_barrel = @import("../../camera/camera.zig");
const Listings = @import("listings.zig").Listings;
const Listed = @import("listings.zig").Listed;
const fit = @import("../../ui/fit.zig");
const Spec = @import("ra8_host").camera.source_spec.Spec;
pub const file = @import("file.zig");

const Kind = camera_panel.Kind;

/// Where the session's answer to the last pick stands.
pub const Status = enum { idle, asking, switched, refused, needs_file };

/// An RGB preview frame from the session camera source (RA8EMU-1180).
pub const PreviewFrame = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

pub const PreviewProvider = struct {
    context: *anyopaque,
    previewFn: *const fn (ctx: *anyopaque) ?PreviewFrame,
};

pub const Camera = struct {
    /// A camera whose panel keeps the consent Always for this run only.
    pub fn opened(io: std.Io) Camera {
        var camera: Camera = .{};
        camera.listings.io = io;
        camera.kept = .begin(io, std.Io.Dir.cwd(), &camera.panel);
        return camera;
    }

    panel: camera_panel.Panel = .{},
    /// Where the panel's Always is kept between runs; null keeps it for
    /// this run only.
    kept: ?camera_always.Kept = null,
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

    listings: Listings = .{},
    /// The webcam the device row picked; null opens the default one.
    device: ?u32 = null,

    preview_provider: ?PreviewProvider = null,
    preview_pixels: std.ArrayListUnmanaged(draw_list.Color) = .empty,
    preview_image: ?draw_list.Image = null,
    last_pace_ns: u64 = 0,

    pub fn deinit(self: *Camera, allocator: std.mem.Allocator) void {
        self.listings.clear(allocator);
        self.preview_pixels.deinit(allocator);
        self.preview_image = null;
    }

    /// Refresh the camera preview frame from the provider at ~30 fps.
    pub fn pace(self: *Camera, now_ns: u64, allocator: std.mem.Allocator) void {
        if (!self.listings.done) self.listings.refresh(allocator);
        const provider = self.preview_provider orelse return;
        if (now_ns -% self.last_pace_ns < 33_000_000 and self.preview_image != null) return;
        self.last_pace_ns = now_ns;
        const frame = provider.previewFn(provider.context) orelse return;
        if (frame.width == 0 or frame.height == 0) return;
        const count = @as(usize, frame.width) * frame.height;
        if (frame.pixels.len < count * 3) return;
        if (self.preview_pixels.items.len != count) {
            self.preview_pixels.resize(allocator, count) catch return;
        }
        const colors = self.preview_pixels.items;
        for (0..count) |i| {
            const rgb = frame.pixels[i * 3 ..][0..3];
            colors[i] = draw_list.Color.rgb(rgb[0], rgb[1], rgb[2]);
        }
        self.preview_image = .{
            .width = frame.width,
            .height = frame.height,
            .pixels = colors,
        };
    }

    /// The host's webcams; none when the host lists none.
    pub fn devices(self: *const Camera) []const u32 {
        return self.listings.devices();
    }

    /// The project's files of the active source's kind; none when the
    /// active source opens no file.
    pub fn mediaNames(self: *const Camera) []const []const u8 {
        return switch (self.panel.active) {
            .image => self.listings.picture_names,
            .video => self.listings.clip_names,
            .gradient, .pipe, .webcam => &[_][]const u8{},
        };
    }

    /// The listed entries behind `mediaNames`, previews included.
    pub fn listedEntries(self: *const Camera) []Listed {
        return switch (self.panel.active) {
            .image => self.listings.pictures,
            .video => self.listings.clips,
            .gradient, .pipe, .webcam => &.{},
        };
    }

    /// Makes `name` the active picture or clip source's file; a new file
    /// counts as a change so `attach` sends the ask.
    pub fn pickMedia(self: *Camera, name: []const u8) void {
        const slot = switch (self.panel.active) {
            .image => &self.args.image,
            .video => &self.args.video,
            else => return,
        };
        if (std.mem.eql(u8, slot.*, name)) return;
        slot.* = name;
        self.panel.changes += 1;
    }

    /// Names the webcam to open. While the webcam runs, the new device
    /// counts as a change so `attach` reopens it.
    pub fn pickDevice(self: *Camera, device: u32) void {
        if (self.device != null and self.device.? == device) return;
        self.device = device;
        if (self.panel.active == .webcam) self.panel.changes += 1;
    }

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
            .err => {
                self.wants = if (file.takesFile(self.asked_kind)) self.asked_kind else null;
                self.back(.refused);
            },
        }
    }

    /// Put the ring back on the running source without asking again.
    fn back(self: *Camera, status: Status) void {
        self.panel.active = self.running;
        self.status = status;
    }

    /// What the leaf says under the panel, or null with nothing to say. An
    /// Always the project did not keep or let go comes first.
    pub fn note(self: *const Camera) ?[]const u8 {
        if (self.kept) |kept| if (kept.note(&self.panel)) |said| return said;
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
            if (body.contains(x, y)) {
                defer if (self.kept) |*kept| kept.follow(&self.panel);
                if (camera_view.click(&self.panel, layoutIn(body), x, y)) return true;
                const names = self.mediaNames();
                const stack = camera_barrel.rows.stackFor(body, self.devices().len, names.len) orelse return false;
                if (stack.device()) |row| if (camera_barrel.rows.hitDevices(row, self.devices(), x, y)) |d| {
                    self.pickDevice(d);
                    return true;
                };
                if (stack.media()) |row| if (camera_barrel.rows.hitMedia(row, names, x, y)) |name| {
                    self.pickMedia(name);
                    return true;
                };
                return false;
            }
        }
        return false;
    }
};

/// Start the panel on `spec`, the `--camera-source` flag (RA8EMU-1095):
/// its argument goes where the panel looks for that kind's file, and the
/// pick goes to the session like any other once the shell connects. The
/// webcam still passes the panel's consent dialog, unless the project
/// already answered Always (`kept`, begun before this).
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
pub fn draw(table: *const widget.types.Paint, theme: *const Theme, body: draw_list.Rect, camera: *const Camera) !void {
    const layout = layoutIn(body);
    try camera_view.draw(table, theme, layout, camera.panel);
    const said = camera.note() orelse return;
    const area = layout.area();
    const y = area.y + area.h + shell_frame.pad;
    const room = body.w - 2 * shell_frame.pad;
    if (room <= 0 or y + font.glyph_h > body.y + body.h) return;
    drawText(table, layout.x, y, font.fit(said, @intCast(room)), word(theme.muted), word(theme.background));
}

/// Draw a live preview of the camera feed in the remaining body area (RA8EMU-1180).
pub fn drawPreview(list: *draw_list.DrawList, theme: *const Theme, body: draw_list.Rect, camera: *const Camera) !void {
    const layout = layoutIn(body);
    const panel_h: i32 = if (camera.panel.asking or camera.panel.always)
        layout.area().h
    else
        camera_view.button + 2 * camera_view.gap;
    var top = layout.y + panel_h + shell_frame.pad;
    if (camera.note() != null) {
        top += @as(i32, font.glyph_h) + shell_frame.pad;
    }
    var bottom = body.y + body.h - shell_frame.pad;
    if (camera.wants != null) bottom -= (24 + shell_frame.pad);
    const names = camera.mediaNames();
    var stack = camera_barrel.rows.stackFor(body, camera.devices().len, names.len);
    if (stack) |s| {
        if (bottom - s.height() - top < 16) stack = null else bottom -= s.height();
    }
    const room_w = body.w - 2 * shell_frame.pad;
    const room_h = bottom - top;
    if (room_w < 16 or room_h < 16) return;
    const area: draw_list.Rect = .{ .x = layout.x, .y = top, .w = room_w, .h = room_h };
    try list.fill(area, theme.border);
    const inner: draw_list.Rect = .{ .x = area.x + 1, .y = area.y + 1, .w = @max(0, area.w - 2), .h = @max(0, area.h - 2) };
    try list.fill(inner, theme.well);
    if (camera.preview_image) |img| {
        if (img.width > 0 and img.height > 0) {
            const shown = fit.fitIn(inner, img.width, img.height);
            try list.scaledImage(shown, img, false);
        }
    }
    const s = stack orelse return;
    if (s.device()) |row| try camera_barrel.rows.drawDevices(theme, list, row, camera.devices(), camera.device);
    if (s.media()) |row| try camera_barrel.rows.drawMedia(theme, list, row, names, camera.args.of(camera.panel.active), camera_view.colorOf(theme, camera.panel.active));
    for (camera.listedEntries(), 0..) |entry, index| {
        const t = entry.thumb orelse continue;
        const row = s.media() orelse break;
        try camera_barrel.thumb.draw(list, row.slot(index), t);
    }
}

/// `text` drawn at `x`, `y` through the shared Paint table.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [64]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = fg,
        .bg = bg,
        .pad = 0,
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{
        .x = x,
        .y = y,
        .w = @intCast(font.textWidth(text.len)),
        .h = @intCast(font.cell_h),
    };
    w.vt.?.render.?(&w);
}

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
