//! Covers src/interfaces/cli/camera_source.zig: the source a spec opens
//! for the CEU and how the report names it.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const camera_source = cli_app.camera_source;
const source_spec = ra8.host.camera.source_spec;
const gradient = ra8.chip.periph.ceu.camera.gradient;
const allocator = std.testing.allocator;

/// The sensor's FORMAT CONTROL byte as the camera example leaves it.
var format_control: u8 = 0x30;

test "the gradient spec and the default spec open the gradient source" {
    const spec = try source_spec.parse("gradient");
    try std.testing.expectEqual(gradient.source().vtable, (try camera_source.open(allocator, std.testing.io, spec, &format_control)).vtable);
    const default = try camera_source.open(allocator, std.testing.io, .{}, &format_control);
    try std.testing.expectEqual(gradient.source().vtable, default.vtable);
    try std.testing.expectEqualStrings("synthetic gradient", default.label);
    try std.testing.expectEqualStrings("", default.detail);
}

test "an image or a clip that is not there refuses the run when it opens" {
    const image = try source_spec.parse("image:/nonexistent/ra8-camera.png");
    try std.testing.expectError(error.FileNotFound, camera_source.open(allocator, std.testing.io, image, &format_control));
    const video = try source_spec.parse("video:/nonexistent/ra8.y4m");
    try std.testing.expectError(error.FileNotFound, camera_source.open(allocator, std.testing.io, video, &format_control));
}

test "a picture is named a still image with its path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "frame.ppm", .data = "P6\n1 1\n255\n\xff\x00\x00" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "frame.ppm", allocator);
    defer allocator.free(path);
    const named = try camera_source.open(allocator, std.testing.io, .{ .kind = .image, .arg = path }, &format_control);
    defer named.close();
    try std.testing.expectEqualStrings("still image", named.label);
    try std.testing.expectEqualStrings(path, named.detail);
}

test "a clip is named video with its argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "walk.y4m", .data = "YUV4MPEG2 W2 H2 F25:1 Ip C420jpeg\nFRAME\n\x10\x10\x10\x10\x80\x80" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "walk.y4m", allocator);
    defer allocator.free(path);
    const arg = try std.mem.concat(allocator, u8, &.{ path, ",loop" });
    defer allocator.free(arg);
    const named = try camera_source.open(allocator, std.testing.io, .{ .kind = .video, .arg = arg }, &format_control);
    defer named.close();
    try std.testing.expectEqualStrings("video", named.label);
    try std.testing.expectEqualStrings(arg, named.detail);
}
