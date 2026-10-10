//! Tests for src/components/esp32c6_hosted/link.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const frame = hosted.frame;
const Link = hosted.link.Link;

/// The host capabilities announcement the firmware sends first.
const caps = [_]u8{ 0x22, 15, 0x44, 1, 0, 0x45, 1, 0x0D, 0x46, 1, 0, 0x47, 1, 80, 0x48, 1, 60 };

fn clock(link: *Link, sent: *const [frame.frame_size]u8, got: *[frame.frame_size]u8) void {
    for (sent, got) |byte, *out| out.* = link.exchange(byte);
}

fn hostFrame(out: *[frame.frame_size]u8, interface: frame.Interface, payload: []const u8) !void {
    try frame.build(out, .{ .interface = interface }, payload);
}

test "an idle link answers with filler and keeps DATA_READY low" {
    var link: Link = .{};
    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    frame.filler(&sent);
    clock(&link, &sent, &got);
    try std.testing.expect((try frame.parse(&got)).header.isFiller());
    try std.testing.expect(!link.dataReady());
    try std.testing.expect(!link.caps_seen);
}

test "the caps announcement queues the boot event" {
    var link: Link = .{};
    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    try hostFrame(&sent, .priv, &caps);
    clock(&link, &sent, &got);
    try std.testing.expect(link.caps_seen);
    try std.testing.expectEqualSlices(u8, &caps, link.caps[0..link.caps_len]);
    try std.testing.expect(link.dataReady());

    frame.filler(&sent);
    clock(&link, &sent, &got);
    const reply = try frame.parse(&got);
    try std.testing.expectEqual(frame.Interface.serial, reply.header.interface);
    try std.testing.expectEqualSlices(u8, "RPCEvt", reply.payload[3..9]);
    try std.testing.expect(!link.dataReady());
    try std.testing.expectEqual(@as(u32, 1), link.boots_sent);

    clock(&link, &sent, &got);
    try std.testing.expect((try frame.parse(&got)).header.isFiller());
}

test "a frame on another interface leaves the link silent" {
    var link: Link = .{};
    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    try hostFrame(&sent, .serial, &.{ 1, 2, 3 });
    clock(&link, &sent, &got);
    try std.testing.expect(!link.caps_seen);
    try std.testing.expect(!link.dataReady());
}

test "a frame with a bad checksum is ignored" {
    var link: Link = .{};
    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    try hostFrame(&sent, .priv, &caps);
    sent[6] +%= 1;
    clock(&link, &sent, &got);
    try std.testing.expect(!link.caps_seen);
}
