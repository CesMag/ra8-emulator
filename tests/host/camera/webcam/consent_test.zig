//! Covers src/host/camera/webcam/consent.zig: the webcam opens only on
//! an explicit yes or --allow-webcam.
const std = @import("std");
const ra8 = @import("ra8");
const consent = ra8.host.camera.consent;

fn ask(answer: []const u8, out: []u8) consent.Decision {
    var in = std.Io.Reader.fixed(answer);
    var prompt = std.Io.Writer.fixed(out);
    return consent.decide(.ask, "/dev/video0", &in, &prompt);
}

test "y and yes grant, in any case" {
    var out: [128]u8 = undefined;
    for ([_][]const u8{ "y\n", "Y\n", "yes\n", " YES \r\n", "y" }) |answer| {
        try std.testing.expectEqual(consent.Decision.granted, ask(answer, &out));
    }
}

test "anything else refuses, including no answer at all" {
    var out: [128]u8 = undefined;
    for ([_][]const u8{ "\n", "n\n", "no\n", "yep\n", "", "maybe\n" }) |answer| {
        try std.testing.expectEqual(consent.Decision.refused, ask(answer, &out));
    }
}

test "the question names the device" {
    var out: [128]u8 = undefined;
    var in = std.Io.Reader.fixed("n\n");
    var prompt = std.Io.Writer.fixed(&out);
    _ = consent.decide(.ask, "/dev/video2", &in, &prompt);
    try std.testing.expectEqualStrings(
        "--camera-source webcam: open the host camera /dev/video2? [y/N] ",
        prompt.buffered(),
    );
}

test "--allow-webcam grants without asking" {
    var out: [128]u8 = undefined;
    var in = std.Io.Reader.fixed("");
    var prompt = std.Io.Writer.fixed(&out);
    const got = consent.decide(.allowed, "/dev/video0", &in, &prompt);
    try std.testing.expectEqual(consent.Decision.granted, got);
    try std.testing.expectEqual(@as(usize, 0), prompt.buffered().len);
}

test "the device defaults, takes an index or a path, and refuses junk" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("/dev/video0", try consent.device(&buf, ""));
    try std.testing.expectEqualStrings("/dev/video3", try consent.device(&buf, "3"));
    try std.testing.expectEqualStrings("/dev/v4l/by-id/cam", try consent.device(&buf, "/dev/v4l/by-id/cam"));
    try std.testing.expectError(error.BadDevice, consent.device(&buf, "cam"));
    try std.testing.expectError(error.BadDevice, consent.device(&buf, "999"));
}

test "capture start and stop are logged" {
    var out: [128]u8 = undefined;
    var log = std.Io.Writer.fixed(&out);
    try consent.logStart(&log, "/dev/video0");
    try consent.logStop(&log, "/dev/video0");
    try std.testing.expectEqualStrings(
        "camera: webcam capture started on /dev/video0\ncamera: webcam capture stopped, /dev/video0 released\n",
        log.buffered(),
    );
}
