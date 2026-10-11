//! Covers src/host/camera/webcam/always.zig: Always for this project kept
//! in a marker file in the project directory, found again by the next run,
//! taken back by `withdraw`, and read as consent only when it is the exact
//! marker: never when it is missing, unreadable, empty or anything else.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const always = ra8.host.camera.always;
const io = std.testing.io;

/// File modes stop nobody on Windows, which has none, and do not stop root.
fn modesBind() bool {
    return switch (builtin.os.tag) {
        .windows => false,
        .linux => std.os.linux.geteuid() != 0,
        else => std.c.geteuid() != 0,
    };
}

test "a project with no marker has not answered Always" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(!always.load(io, tmp.dir));
    try tmp.dir.createDirPath(io, always.dir_name);
    try std.testing.expect(!always.load(io, tmp.dir));
}

test "a saved Always loads in the next run, and saving twice is harmless" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try always.save(io, tmp.dir);
    try always.save(io, tmp.dir);
    try std.testing.expect(always.load(io, tmp.dir));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("always\n", try tmp.dir.readFile(io, ".ra8-emulator/webcam-always", &buf));
}

test "a withdrawn Always is gone from the next run, and can be given again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try always.save(io, tmp.dir);
    try always.withdraw(io, tmp.dir);
    try std.testing.expect(!always.load(io, tmp.dir));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, always.dir_name, .{}));
    try always.save(io, tmp.dir);
    try std.testing.expect(always.load(io, tmp.dir));
}

test "withdrawing with no marker is not an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try always.withdraw(io, tmp.dir);
    try tmp.dir.createDirPath(io, always.dir_name);
    try always.withdraw(io, tmp.dir);
    try always.withdraw(io, tmp.dir);
    try std.testing.expect(!always.load(io, tmp.dir));
}

test "withdraw removes the marker and leaves whatever else its directory holds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try always.save(io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = always.dir_name ++ "/other", .data = "kept" });
    try always.withdraw(io, tmp.dir);
    try std.testing.expect(!always.load(io, tmp.dir));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, always.path, .{}));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("kept", try tmp.dir.readFile(io, always.dir_name ++ "/other", &buf));
}

test "a marker that does not say always is not consent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, always.dir_name);
    const wrong = [_][]const u8{ "", "\n", "always", "alway", "always\nmore\n", "always\n\n", "always\r\n", " always\n", "ALWAYS\n", "Always\n", "never\n", "yes\n", "1\n", "always\x00", "always\nalways\n" };
    for (wrong) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = always.path, .data = data });
        try std.testing.expect(!always.load(io, tmp.dir));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = always.path, .data = always.contents });
    try std.testing.expect(always.load(io, tmp.dir));
}

test "a marker that is not a file is not consent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, always.path);
    try std.testing.expect(!always.load(io, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = always.path ++ "/inside", .data = always.contents });
    try std.testing.expect(!always.load(io, tmp.dir));
}

test "a marker directory that is a file is not consent, and keeps nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = always.dir_name, .data = always.contents });
    try std.testing.expect(!always.load(io, tmp.dir));
    try std.testing.expect(std.meta.isError(always.save(io, tmp.dir)));
    try std.testing.expect(!always.load(io, tmp.dir));
}

test "a marker the user may not read is not consent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!modesBind()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try always.save(io, tmp.dir);
    try tmp.dir.setFilePermissions(io, always.path, .fromMode(0o000), .{});
    try std.testing.expect(!always.load(io, tmp.dir));
    try tmp.dir.setFilePermissions(io, always.path, .fromMode(0o644), .{});
    try std.testing.expect(always.load(io, tmp.dir));
    try tmp.dir.setFilePermissions(io, always.dir_name, .fromMode(0o000), .{});
    defer tmp.dir.setFilePermissions(io, always.dir_name, .fromMode(0o755), .{}) catch {};
    try std.testing.expect(!always.load(io, tmp.dir));
}

test "a project that cannot be written keeps no Always" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!modesBind()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    var project = try tmp.dir.openDir(io, "project", .{});
    defer project.close(io);
    try tmp.dir.setFilePermissions(io, "project", .fromMode(0o555), .{});
    defer tmp.dir.setFilePermissions(io, "project", .fromMode(0o755), .{}) catch {};
    try std.testing.expect(std.meta.isError(always.save(io, project)));
    try std.testing.expect(!always.load(io, project));
}

test "a marker that will not go fails the withdraw and is still found" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!modesBind()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try always.save(io, tmp.dir);
    try tmp.dir.setFilePermissions(io, always.dir_name, .fromMode(0o555), .{});
    defer tmp.dir.setFilePermissions(io, always.dir_name, .fromMode(0o755), .{}) catch {};
    try std.testing.expect(std.meta.isError(always.withdraw(io, tmp.dir)));
    try std.testing.expect(always.load(io, tmp.dir));
    try tmp.dir.setFilePermissions(io, always.dir_name, .fromMode(0o755), .{});
    try always.withdraw(io, tmp.dir);
    try std.testing.expect(!always.load(io, tmp.dir));
}
