//! The camera source `--camera-source` and set_camera_source name, opened
//! for the board's CEU (RA8EMU-525, RA8EMU-1011): the camera model's own
//! gradient, or a host input from ra8_host wrapped as the camera's frame
//! source, which reads the sensor's FORMAT CONTROL byte at each capture.
const std = @import("std");
const source_spec = @import("ra8_host").camera.source_spec;
const source_open = @import("ra8_host").camera.source_open;
const frame_source = @import("../../chip/periph/camera/frame_source.zig");
const hosted = @import("../../components/camera_ov5640/hosted.zig");

/// The source `spec` names, ready to hand to the CEU. A picture that cannot
/// be read or decoded says why and refuses the run.
pub fn open(allocator: std.mem.Allocator, io: std.Io, spec: source_spec.Spec, format_control: *const u8) !frame_source.FrameSource {
    return hosted.wrap(allocator, try source_open.open(allocator, io, spec), format_control);
}
