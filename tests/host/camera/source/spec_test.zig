//! Covers src/host/camera/source_spec.zig: the `--camera-source` kinds and
//! what each accepts.
const std = @import("std");
const ra8 = @import("ra8");

const source_spec = ra8.host.camera.source_spec;

test "gradient parses with no argument" {
    const spec = try source_spec.parse("gradient");
    try std.testing.expectEqual(source_spec.Kind.gradient, spec.kind);
    try std.testing.expectEqualStrings("", spec.arg);
    const empty = try source_spec.parse("gradient:");
    try std.testing.expectEqual(source_spec.Kind.gradient, empty.kind);
}

test "the default spec is the gradient the CEU always captured" {
    const spec = source_spec.Spec{};
    try std.testing.expectEqual(source_spec.Kind.gradient, spec.kind);
}

test "an unknown kind and a stray gradient argument are refused" {
    try std.testing.expectError(error.UnknownCameraSource, source_spec.parse("camera:0"));
    try std.testing.expectError(error.UnknownCameraSource, source_spec.parse(""));
    try std.testing.expectError(error.BadValue, source_spec.parse("gradient:x"));
}

test "image takes a path and refuses to go without one" {
    const spec = try source_spec.parse("image:shots/frame.png");
    try std.testing.expectEqual(source_spec.Kind.image, spec.kind);
    try std.testing.expectEqualStrings("shots/frame.png", spec.arg);
    try std.testing.expectError(error.BadValue, source_spec.parse("image"));
    try std.testing.expectError(error.BadValue, source_spec.parse("image:"));
}

test "video takes a path, optionally with loop" {
    const spec = try source_spec.parse("video:clips/walk.y4m,loop");
    try std.testing.expectEqual(source_spec.Kind.video, spec.kind);
    try std.testing.expectEqualStrings("clips/walk.y4m,loop", spec.arg);
    try std.testing.expectError(error.BadValue, source_spec.parse("video"));
}

test "pipe needs its path, size and format" {
    const spec = try source_spec.parse("pipe:-,2x1,rgb24");
    try std.testing.expectEqual(source_spec.Kind.pipe, spec.kind);
    try std.testing.expectError(error.BadValue, source_spec.parse("pipe:-"));
    try std.testing.expectError(error.BadValue, source_spec.parse("pipe"));
}

test "webcam takes nothing, a device number or a path, and refuses anything else" {
    try std.testing.expectEqual(source_spec.Kind.webcam, (try source_spec.parse("webcam")).kind);
    try std.testing.expectEqualStrings("2", (try source_spec.parse("webcam:2")).arg);
    try std.testing.expectEqualStrings("/dev/v4l/by-id/cam", (try source_spec.parse("webcam:/dev/v4l/by-id/cam")).arg);
    try std.testing.expectError(error.BadValue, source_spec.parse("webcam:front"));
    try std.testing.expect(!(try source_spec.parse("webcam")).allow_webcam);
}
