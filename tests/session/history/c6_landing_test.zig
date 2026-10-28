//! Covers src/session/history/c6_landing.zig: a C6 landing round-trips
//! through its record body, and a damaged or short body is refused.
const std = @import("std");
const ra8 = @import("ra8");

const c6_landing = ra8.session.history_c6_landing;
const hosted = ra8.components.esp_hosted;
const gpa = std.testing.allocator;

test "a landing round-trips through its record body and a damaged one is refused" {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try c6_landing.encode(&buf.writer, .{ .kind = .answer, .site = .poll, .ordinal = 3, .frame = "abc" });
    const got = try c6_landing.decode(buf.written());
    try std.testing.expectEqual(hosted.hold.Kind.answer, got.kind);
    try std.testing.expectEqual(@as(u32, 3), got.ordinal);
    try std.testing.expectEqualStrings("abc", got.frame);
    try std.testing.expectEqual(ra8.session.history_record.Boundary.What.c6_answer, c6_landing.whatOf(.answer));
    const bad = try gpa.dupe(u8, buf.written());
    defer gpa.free(bad);
    bad[9] ^= 1;
    try std.testing.expectError(c6_landing.Error.BadCrc, c6_landing.decode(bad));
    try std.testing.expectError(c6_landing.Error.Truncated, c6_landing.decode(bad[0..5]));
}
