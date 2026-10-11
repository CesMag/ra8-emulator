//! Covers src/host/camera/webcam/privacy.zig: the Windows camera
//! privacy setting blocks the webcam with the fix, other hosts pass.
const std = @import("std");
const ra8 = @import("ra8");
const privacy = ra8.host.camera.privacy;

test "Allow and Deny are read, anything else is unset" {
    try std.testing.expectEqual(privacy.Verdict.allowed, privacy.parse("Allow"));
    try std.testing.expectEqual(privacy.Verdict.denied, privacy.parse("Deny"));
    try std.testing.expectEqual(privacy.Verdict.unset, privacy.parse("Prompt"));
    try std.testing.expectEqual(privacy.Verdict.unset, privacy.parse(""));
}

test "a wide registry value stops at its NUL and refuses non-ASCII" {
    const deny = std.unicode.utf8ToUtf16LeStringLiteral("Deny");
    try std.testing.expectEqual(privacy.Verdict.denied, privacy.parseWide(deny[0 .. deny.len + 1]));
    const allow = std.unicode.utf8ToUtf16LeStringLiteral("Allow");
    try std.testing.expectEqual(privacy.Verdict.allowed, privacy.parseWide(allow));
    try std.testing.expectEqual(privacy.Verdict.unset, privacy.parseWide(&.{ 'D', 0xe9, 'n', 'y' }));
    try std.testing.expectEqual(privacy.Verdict.unset, privacy.parseWide(std.unicode.utf8ToUtf16LeStringLiteral("AllowAllow")));
}

test "either the machine or the user denying blocks the camera" {
    try std.testing.expectEqual(privacy.Verdict.denied, privacy.combine(.denied, .allowed));
    try std.testing.expectEqual(privacy.Verdict.denied, privacy.combine(.allowed, .denied));
    try std.testing.expectEqual(privacy.Verdict.allowed, privacy.combine(.unset, .allowed));
    try std.testing.expectEqual(privacy.Verdict.unset, privacy.combine(.unset, .unset));
}

test "a denied setting refuses with the fix, the rest pass quietly" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.PrivacyBlocked, privacy.gate(.denied, &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Let desktop apps access your camera") != null);
    out.clearRetainingCapacity();
    try privacy.gate(.allowed, &out.writer);
    try privacy.gate(.unset, &out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "hosts without the Windows setting are never blocked" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectEqual(privacy.Verdict.unset, privacy.host());
}
