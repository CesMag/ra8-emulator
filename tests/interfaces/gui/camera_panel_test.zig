//! Covers src/interfaces/gui/camera_panel.zig: the selection state and the consent
//! gate the webcam passes before it becomes the source.
const std = @import("std");
const gui_app = @import("gui_app");
const Panel = gui_app.camera_panel.Panel;

test "a run starts on the gradient with the camera off" {
    const panel = Panel{};
    try std.testing.expectEqual(.gradient, panel.active);
    try std.testing.expect(!panel.cameraOn());
    try std.testing.expect(!panel.asking);
}

test "files and the pipe switch at once and count each change" {
    var panel = Panel{};
    panel.pick(.image);
    try std.testing.expectEqual(.image, panel.active);
    panel.pick(.video);
    panel.pick(.pipe);
    try std.testing.expectEqual(.pipe, panel.active);
    try std.testing.expectEqual(@as(u32, 3), panel.changes);
    panel.pick(.pipe);
    try std.testing.expectEqual(@as(u32, 3), panel.changes);
}

test "picking the webcam asks first and keeps the old source" {
    var panel = Panel{};
    panel.pick(.image);
    panel.pick(.webcam);
    try std.testing.expect(panel.asking);
    try std.testing.expectEqual(.image, panel.active);
    try std.testing.expect(!panel.cameraOn());
}

test "cancel closes the dialog and the webcam never opens" {
    var panel = Panel{};
    panel.pick(.webcam);
    panel.answer(.cancel);
    try std.testing.expect(!panel.asking);
    try std.testing.expectEqual(.gradient, panel.active);
    try std.testing.expectEqual(@as(u32, 0), panel.changes);
}

test "allow once turns the camera on and asks again next time" {
    var panel = Panel{};
    panel.pick(.webcam);
    panel.answer(.allow_once);
    try std.testing.expect(panel.cameraOn());
    panel.pick(.gradient);
    try std.testing.expect(!panel.cameraOn());
    panel.pick(.webcam);
    try std.testing.expect(panel.asking);
    try std.testing.expect(!panel.cameraOn());
}

test "always skips the dialog for the rest of the run" {
    var panel = Panel{};
    panel.pick(.webcam);
    panel.answer(.always);
    try std.testing.expect(panel.cameraOn());
    panel.pick(.video);
    panel.pick(.webcam);
    try std.testing.expect(!panel.asking);
    try std.testing.expect(panel.cameraOn());
}

test "an answer with no dialog open changes nothing" {
    var panel = Panel{};
    panel.answer(.always);
    try std.testing.expect(!panel.always);
    try std.testing.expectEqual(.gradient, panel.active);
}

test "picking another source while asked closes the dialog" {
    var panel = Panel{};
    panel.pick(.webcam);
    panel.pick(.image);
    try std.testing.expect(!panel.asking);
    try std.testing.expectEqual(.image, panel.active);
    panel.answer(.allow_once);
    try std.testing.expect(!panel.cameraOn());
}
