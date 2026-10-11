//! Covers src/host/camera/av_info_plist.zig: the plist names the camera
//! use and the bundle, is one well-formed plist document, and goes in the
//! section macOS reads for an unbundled binary.
const std = @import("std");
const ra8 = @import("ra8");
const plist = ra8.host.camera.av_info_plist;

test "the plist says why the camera is used and names the program" {
    try std.testing.expect(std.mem.indexOf(u8, plist.text, "<key>NSCameraUsageDescription</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist.text, "--camera-source webcam") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist.text, "<key>CFBundleIdentifier</key>") != null);
}

test "the plist is one document with balanced tags in the info_plist section" {
    try std.testing.expect(std.mem.startsWith(u8, plist.text, "<?xml"));
    try std.testing.expect(std.mem.endsWith(u8, plist.text, "</plist>\n"));
    try std.testing.expectEqual(std.mem.count(u8, plist.text, "<key>"), std.mem.count(u8, plist.text, "</key>"));
    try std.testing.expectEqual(std.mem.count(u8, plist.text, "<string>"), std.mem.count(u8, plist.text, "</string>"));
    try std.testing.expectEqualStrings("__TEXT,__info_plist", plist.section);
}
