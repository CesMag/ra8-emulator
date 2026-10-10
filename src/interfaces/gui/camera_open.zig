//! Turning the camera panel's pick into the source the CEU captures from
//! (RA8EMU-500).
//!
//! The panel holds which kind is active; `Args` holds what each kind opens
//! (the picture or clip path the file picker chose, the pipe's
//! `<path|->,<w>x<h>,<format>`, the webcam device). `spec` pairs the two
//! into the same `source_spec.Spec` `--camera-source` builds, so the GUI
//! and the command line open sources the same way. The webcam only becomes
//! the panel's active kind after its permission dialog was accepted, so the
//! spec it yields carries that consent and the terminal is never asked.
const std = @import("std");
const source_spec = @import("ra8_host").camera.source_spec;
const source_open = @import("ra8_host").camera.source_open;
const frame_source = @import("ra8_chip").periph.frame_source;
const hosted = @import("ra8_components").camera.hosted;
const Panel = @import("camera_panel.zig").Panel;

/// What each source kind opens. The gradient takes nothing, and an empty
/// webcam device means the default one.
pub const Args = struct {
    image: []const u8 = "",
    video: []const u8 = "",
    pipe: []const u8 = "",
    webcam: []const u8 = "",

    pub fn of(self: Args, kind: source_spec.Kind) []const u8 {
        return switch (kind) {
            .gradient => "",
            .image => self.image,
            .video => self.video,
            .pipe => self.pipe,
            .webcam => self.webcam,
        };
    }
};

pub const SpecError = error{NeedsArgument};

/// The spec for the panel's active source. An image, video or pipe with
/// nothing chosen yet has no spec.
pub fn spec(panel: Panel, args: Args) SpecError!source_spec.Spec {
    const kind = panel.active;
    const arg = args.of(kind);
    switch (kind) {
        .image, .video, .pipe => if (arg.len == 0) return error.NeedsArgument,
        .gradient, .webcam => {},
    }
    return .{ .kind = kind, .arg = arg, .allow_webcam = kind == .webcam };
}

/// Opens the panel's active source, ready for `Switcher.apply`. A failure
/// says why on stderr and leaves the running source to `Switcher.skip`.
pub fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    panel: Panel,
    args: Args,
    format_control: *const u8,
) !frame_source.FrameSource {
    const picked = try spec(panel, args);
    return hosted.wrap(allocator, try source_open.open(allocator, io, picked), format_control);
}
