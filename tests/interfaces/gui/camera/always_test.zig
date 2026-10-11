//! Covers src/interfaces/gui/camera_always.zig: the panel starts from the
//! project's marker and asks unless it is the exact one, the marker follows
//! the panel's Always, and a project that will not keep the marker or let it
//! go says so.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const store = ra8.host.camera.always;
const camera_always = gui_app.camera.always;
const Kept = camera_always.Kept;
const Panel = gui_app.camera.panel.Panel;
const io = std.testing.io;

fn expectNote(wanted: ?[]const u8, kept: *const Kept, panel: *const Panel) !void {
    const said = kept.note(panel);
    if (wanted) |text| return std.testing.expectEqualStrings(text, said orelse return error.TestExpectedEqual);
    try std.testing.expectEqual(@as(?[]const u8, null), said);
}

test "a start with no marker asks before the webcam" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var panel = Panel{};
    const kept = Kept.begin(io, tmp.dir, &panel);
    try std.testing.expect(!panel.always);
    panel.pick(.webcam);
    try std.testing.expect(panel.asking);
    try std.testing.expect(!panel.cameraOn());
    try expectNote(null, &kept, &panel);
}

test "a start with the marker comes up already allowing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try store.save(io, tmp.dir);
    var panel = Panel{};
    const kept = Kept.begin(io, tmp.dir, &panel);
    try std.testing.expect(panel.always);
    panel.pick(.webcam);
    try std.testing.expect(!panel.asking);
    try std.testing.expect(panel.cameraOn());
    try expectNote(null, &kept, &panel);
}

test "a start with a marker that is not the exact one still asks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, store.dir_name);
    for ([_][]const u8{ "", "always", "always\nmore\n", "ALWAYS\n", "yes\n" }) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = store.path, .data = data });
        var panel = Panel{};
        _ = Kept.begin(io, tmp.dir, &panel);
        try std.testing.expect(!panel.always);
        panel.pick(.webcam);
        try std.testing.expect(panel.asking);
        try std.testing.expect(!panel.cameraOn());
    }
}

test "Always answered is found by the next start, and taken back it asks again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = Panel{};
    var kept = Kept.begin(io, tmp.dir, &first);
    first.pick(.webcam);
    first.answer(.always);
    kept.follow(&first);
    try std.testing.expect(store.load(io, tmp.dir));

    var second = Panel{};
    kept = Kept.begin(io, tmp.dir, &second);
    second.pick(.webcam);
    try std.testing.expect(second.cameraOn());
    second.withdraw();
    kept.follow(&second);
    try expectNote(null, &kept, &second);
    try std.testing.expect(!store.load(io, tmp.dir));

    var third = Panel{};
    _ = Kept.begin(io, tmp.dir, &third);
    third.pick(.webcam);
    try std.testing.expect(third.asking);
}

test "allow once and cancel leave nothing in the project" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var panel = Panel{};
    var kept = Kept.begin(io, tmp.dir, &panel);
    panel.pick(.webcam);
    panel.answer(.cancel);
    kept.follow(&panel);
    panel.pick(.webcam);
    panel.answer(.allow_once);
    kept.follow(&panel);
    try std.testing.expect(panel.cameraOn());
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, store.dir_name, .{}));
}

test "a project that will not take the marker says so, holds Always for the run and asks next run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The marker's directory is taken by a file, so nothing can be written.
    try tmp.dir.writeFile(io, .{ .sub_path = store.dir_name, .data = "" });
    var panel = Panel{};
    var kept = Kept.begin(io, tmp.dir, &panel);
    panel.pick(.webcam);
    panel.answer(.always);
    kept.follow(&panel);
    try std.testing.expect(panel.always);
    try expectNote(camera_always.not_kept, &kept, &panel);
    var next = Panel{};
    _ = Kept.begin(io, tmp.dir, &next);
    try std.testing.expect(!next.always);
    // Once the project takes it, the next click keeps it.
    try tmp.dir.deleteFile(io, store.dir_name);
    kept.follow(&panel);
    try expectNote(null, &kept, &panel);
    try std.testing.expect(store.load(io, tmp.dir));
}

test "a marker that will not go names the file to delete, and goes on a later click" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try store.save(io, tmp.dir);
    var panel = Panel{};
    var kept = Kept.begin(io, tmp.dir, &panel);
    try tmp.dir.setFilePermissions(io, store.dir_name, .fromMode(0o555), .{});
    defer tmp.dir.setFilePermissions(io, store.dir_name, .fromMode(0o755), .{}) catch {};
    panel.withdraw();
    kept.follow(&panel);
    // Root removes it anyway, and then there is nothing to say.
    if (!store.load(io, tmp.dir)) return error.SkipZigTest;
    try std.testing.expect(!panel.always);
    try expectNote(camera_always.not_withdrawn, &kept, &panel);
    try std.testing.expect(std.mem.endsWith(u8, camera_always.not_withdrawn, ".ra8-emulator/webcam-always"));
    try tmp.dir.setFilePermissions(io, store.dir_name, .fromMode(0o755), .{});
    kept.follow(&panel);
    try expectNote(null, &kept, &panel);
    try std.testing.expect(!store.load(io, tmp.dir));
}
