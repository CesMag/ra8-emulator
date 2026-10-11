//! Opening the host input a `--camera-source` spec names (RA8EMU-1011): a
//! still picture, a clip, a raw pipe or a webcam. The application wraps the
//! input as the camera's frame source, so the camera never opens a host file
//! or device itself. The gradient needs no host input.
const std = @import("std");
const decoded = @import("../decoded_image.zig");
const image_file = @import("../image_file.zig");
const video_file = @import("../video_file.zig");
const pipe_input = @import("../pipe/input.zig");
const opener = @import("../webcam/open.zig");
const webcam_capture = @import("../webcam/input.zig");
const source_spec = @import("spec.zig");

/// One opened host input. `picture(when)` returns packed RGB888 for a
/// capture armed at `when` emulated ns.
pub const Input = struct {
    allocator: std.mem.Allocator,
    host: Host,
    /// The spec's argument, which the report prints after the label.
    arg: []const u8,

    pub const Host = union(enum) {
        still: *image_file.Still,
        clip: *video_file.Clip,
        pipe: *pipe_input.Pipe,
        webcam: *webcam_capture.Webcam,
    };

    pub fn picture(self: *Input, when: u64) decoded.Image {
        return switch (self.host) {
            inline else => |input| input.picture(when),
        };
    }

    /// Closes the host input and frees this.
    pub fn close(self: *Input) void {
        closeHost(self.host);
        self.allocator.destroy(self);
    }

    /// What the report calls the source.
    pub fn label(self: *const Input) []const u8 {
        return switch (self.host) {
            .still => "still image",
            .clip => "video",
            .pipe => "pipe",
            .webcam => "webcam",
        };
    }

    /// The device a webcam opened, otherwise the spec's argument.
    pub fn detail(self: *const Input) []const u8 {
        return switch (self.host) {
            .webcam => |input| input.device_path,
            else => self.arg,
        };
    }
};

/// The input `spec` names, or null for the gradient. An input that cannot
/// be read or decoded says why on stderr and refuses the run.
pub fn open(allocator: std.mem.Allocator, io: std.Io, spec: source_spec.Spec) !?*Input {
    const host: Input.Host = switch (spec.kind) {
        .gradient => return null,
        .image => .{ .still = image_file.Still.load(allocator, io, spec.arg) catch |err| return refuse(spec, err) },
        .video => .{ .clip = video_file.Clip.load(allocator, io, spec.arg) catch |err| return refuse(spec, err) },
        .pipe => .{ .pipe = pipe_input.Pipe.load(allocator, io, spec.arg) catch |err| return refuse(spec, err) },
        .webcam => .{ .webcam = opener.open(allocator, io, spec.arg, spec.allow_webcam) catch |err| return refuse(spec, err) },
    };
    errdefer closeHost(host);
    const self = try allocator.create(Input);
    self.* = .{ .allocator = allocator, .host = host, .arg = spec.arg };
    return self;
}

fn refuse(spec: source_spec.Spec, err: anyerror) anyerror {
    std.debug.print("--camera-source {s}:{s}: {s}\n", .{ @tagName(spec.kind), spec.arg, @errorName(err) });
    return err;
}

fn closeHost(host: Input.Host) void {
    switch (host) {
        inline else => |input| input.close(),
    }
}
