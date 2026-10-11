//! The camera leaf's file field (RA8EMU-799): a text field (RA8EMU-803)
//! along the foot of the camera leaf for the path an image, video or pipe
//! source opens. Enter stores the path as that kind's argument
//! (camera_open.Args) and picks the kind, so the leaf's next ask sends
//! set_camera_source with `KIND:PATH` (RA8EMU-796). The kind is the one last
//! picked without a file, else the running file kind, whose source is then
//! opened again with the new path. With neither, Enter does nothing.
const Theme = @import("ui/colors.zig").Theme;
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const platform = @import("platform.zig");
const shell_frame = @import("ui/shell_frame.zig");
const shell_field = @import("ui/shell_field.zig");
const shell_camera = @import("shell_camera.zig");
const camera_panel = @import("camera_panel.zig");

const Rect = draw_list.Rect;
const Kind = camera_panel.Kind;

pub const placeholder = "path for image, video or pipe, then Enter";

pub const CameraFile = struct {
    field: shell_field.Field = .{},
    /// Each file kind's path, so a new one never changes another's.
    paths: [3][shell_field.capacity]u8 = undefined,

    /// Set the field up in place; it must not move afterwards.
    pub fn init(self: *CameraFile) !void {
        try self.field.init(placeholder);
    }

    /// Feed a window event to the field. Returns whether it was taken.
    pub fn handle(self: *CameraFile, event: platform.Event) bool {
        return self.field.handle(event);
    }

    /// A left press: focus the field inside it, let it go outside.
    pub fn press(self: *CameraFile, x: i32, y: i32) bool {
        return self.field.press(x, y);
    }

    /// Hand a submitted path to `camera`. False when nothing changed.
    pub fn apply(self: *CameraFile, camera: *shell_camera.Camera) bool {
        if (!self.field.takeSubmit()) return false;
        const text = self.field.value();
        const kind = target(camera) orelse return false;
        if (text.len == 0) return false;
        const slot = &self.paths[slotOf(kind)];
        @memcpy(slot[0..text.len], text);
        const path = slot[0..text.len];
        switch (kind) {
            .image => camera.args.image = path,
            .video => camera.args.video = path,
            else => camera.args.pipe = path,
        }
        camera.wants = null;
        if (camera.panel.active == kind) camera.panel.reopen() else camera.panel.pick(kind);
        self.field.clear();
        return true;
    }
};

/// The kind a path is for: the one waiting for a file, else the running
/// file kind. Null when no file kind is in play.
pub fn target(camera: *const shell_camera.Camera) ?Kind {
    const kind = camera.wants orelse camera.panel.active;
    return if (takesFile(kind)) kind else null;
}

pub fn takesFile(kind: Kind) bool {
    return switch (kind) {
        .image, .video, .pipe => true,
        .gradient, .webcam => false,
    };
}

fn slotOf(kind: Kind) usize {
    return switch (kind) {
        .image => 0,
        .video => 1,
        else => 2,
    };
}

/// The field's rect along the foot of a camera leaf `body`.
pub fn fieldRect(body: Rect) Rect {
    const w = @max(body.w - 2 * shell_frame.pad, 0);
    return .{ .x = body.x + shell_frame.pad, .y = body.y + body.h - shell_frame.pad - shell_field.height, .w = w, .h = shell_field.height };
}

/// Whether `body` has room for the field under the panel and its note.
pub fn fits(body: Rect) bool {
    const area = shell_camera.layoutIn(body).area();
    const below = area.y + area.h + 2 * shell_frame.pad + @as(i32, font.glyph_h);
    return fieldRect(body).y >= below and body.w > 2 * shell_frame.pad;
}

/// Draw the camera leaf with its file field: the panel and note, then the
/// field at the foot when it fits.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, body: Rect, camera: *const shell_camera.Camera, file: *CameraFile) !void {
    try shell_camera.draw(list, theme, body, camera);
    if (fits(body)) try file.field.draw(list, theme, fieldRect(body));
}
