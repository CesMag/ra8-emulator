//! Tests for src/components/esp32c6_hosted/event.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const event = hosted.event;
const frame = hosted.frame;

test "varint packs 769 as two octets" {
    var buf: [4]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try w.varint(769);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x06 }, w.written());
}

test "default ESPInit event packs as protobuf-c does" {
    var buf: [16]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try event.espInit(&w, 0);
    // msg_type Event, msg_id 769, field 769 present and empty.
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x03, 0x10, 0x81, 0x06, 0x8A, 0x30, 0x00 }, w.written());
}

test "a reset reason lands in field 2 of the body" {
    var buf: [16]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try event.espInit(&w, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x03, 0x10, 0x81, 0x06, 0x8A, 0x30, 0x02, 0x10, 0x01 }, w.written());
}

test "envelope carries the endpoint then the protobuf" {
    var buf: [32]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try event.envelope(&w, event.endpoint_event, &.{ 0xAA, 0xBB });
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 6, 0, 'R', 'P', 'C', 'E', 'v', 't', 0x02, 2, 0, 0xAA, 0xBB }, w.written());
}

test "ESPInit frame parses on the serial interface" {
    var buf: [frame.frame_size]u8 = undefined;
    try event.espInitFrame(&buf, 0);
    const got = try frame.parse(&buf);
    try std.testing.expectEqual(frame.Interface.serial, got.header.interface);
    try std.testing.expectEqual(@as(u4, 0), got.header.if_num);
    try std.testing.expectEqual(@as(usize, 9 + 3 + 8), got.payload.len);
    try std.testing.expectEqualSlices(u8, "RPCEvt", got.payload[3..9]);
    try std.testing.expectEqual(@as(u8, 0x02), got.payload[9]);
}

test "a full buffer reports NoRoom" {
    var buf: [3]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try std.testing.expectError(error.NoRoom, event.espInit(&w, 0));
}
