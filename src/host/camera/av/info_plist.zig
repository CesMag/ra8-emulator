//! The Info.plist a macOS build carries (RA8EMU-502). macOS kills a
//! command-line program that touches the camera unless the binary names why
//! in NSCameraUsageDescription. A plain executable has no bundle, so the
//! plist goes in the __TEXT,__info_plist section, which is where macOS
//! looks for an unbundled binary's Info.plist. Other hosts get nothing.
const builtin = @import("builtin");

pub const section = "__TEXT,__info_plist";

pub const text =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleIdentifier</key>
    \\  <string>io.github.bsikar.ra8-emulator</string>
    \\  <key>CFBundleName</key>
    \\  <string>ra8_emulator</string>
    \\  <key>CFBundleInfoDictionaryVersion</key>
    \\  <string>6.0</string>
    \\  <key>NSCameraUsageDescription</key>
    \\  <string>ra8_emulator feeds your webcam into the emulated board's camera when you run it with --camera-source webcam.</string>
    \\</dict>
    \\</plist>
    \\
;

const bytes: [text.len]u8 = text.*;

comptime {
    if (builtin.os.tag == .macos) @export(&bytes, .{ .name = "ra8_info_plist", .section = section });
}
