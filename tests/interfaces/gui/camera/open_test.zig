//! Covers src/interfaces/gui/camera_open.zig: the panel's pick and its argument make
//! the same spec `--camera-source` would.
const std = @import("std");
const gui_app = @import("gui_app");
const camera_open = gui_app.camera.open;
const Panel = gui_app.camera.panel.Panel;

test "the gradient needs no argument" {
    const panel = Panel{};
    const spec = try camera_open.spec(panel, .{});
    try std.testing.expectEqual(.gradient, spec.kind);
    try std.testing.expectEqualStrings("", spec.arg);
}

test "each kind takes its own argument" {
    const args = camera_open.Args{ .image = "a.png", .video = "b.y4m", .pipe = "-,64x48,rgb565", .webcam = "2" };
    var panel = Panel{};
    panel.pick(.image);
    try std.testing.expectEqualStrings("a.png", (try camera_open.spec(panel, args)).arg);
    panel.pick(.video);
    try std.testing.expectEqualStrings("b.y4m", (try camera_open.spec(panel, args)).arg);
    panel.pick(.pipe);
    try std.testing.expectEqualStrings("-,64x48,rgb565", (try camera_open.spec(panel, args)).arg);
}

test "a file source with nothing chosen has no spec" {
    var panel = Panel{};
    panel.pick(.image);
    try std.testing.expectError(error.NeedsArgument, camera_open.spec(panel, .{}));
    panel.pick(.pipe);
    try std.testing.expectError(error.NeedsArgument, camera_open.spec(panel, .{}));
}

test "only an accepted webcam yields a webcam spec, carrying the consent" {
    var panel = Panel{};
    panel.pick(.webcam);
    try std.testing.expectEqual(.gradient, (try camera_open.spec(panel, .{ .webcam = "1" })).kind);
    panel.answer(.allow_once);
    const spec = try camera_open.spec(panel, .{ .webcam = "1" });
    try std.testing.expectEqual(.webcam, spec.kind);
    try std.testing.expectEqualStrings("1", spec.arg);
    try std.testing.expect(spec.allow_webcam);
}
