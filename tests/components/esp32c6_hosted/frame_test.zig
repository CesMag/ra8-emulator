//! Tests for src/components/esp32c6_hosted/frame.zig.
const std = @import("std");
const ra8 = @import("ra8");
const frame = ra8.components.esp_hosted.frame;

test "filler frame matches the model's idle header" {
    try std.testing.expectEqual(ra8.components.esp_hosted.idle_header, @as(u8, @backingInt(frame.Interface.max_if)) | 0xF0);
}

test "filler frame is 0xF8 then zeros and parses as filler" {
    var buf: [frame.frame_size]u8 = undefined;
    frame.filler(&buf);
    try std.testing.expectEqual(@as(u8, 0xF8), buf[0]);
    for (buf[1..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const got = try frame.parse(&buf);
    try std.testing.expect(got.header.isFiller());
    try std.testing.expectEqual(@as(usize, 0), got.payload.len);
}

test "header round trips through encode and decode" {
    const h: frame.Header = .{
        .interface = .serial,
        .if_num = 3,
        .flags = 0x81,
        .len = 0x1234,
        .offset = 12,
        .checksum = 0xBEEF,
        .seq = 0xA55A,
        .throttle = 2,
        .pkt_type = 0x22,
    };
    var bytes: [frame.header_size]u8 = undefined;
    h.encode(&bytes);
    try std.testing.expectEqualSlices(u8, &.{
        0x33, 0x81, 0x34, 0x12, 0x0C, 0x00, 0xEF, 0xBE, 0x5A, 0xA5, 0x02, 0x22,
    }, &bytes);
    try std.testing.expectEqualDeep(h, frame.Header.decode(&bytes));
}

test "checksum is a wrapping byte sum that skips the checksum field" {
    var bytes = @as([300]u8, @splat(0xFF));
    bytes[6] = 0x12;
    bytes[7] = 0x34;
    try std.testing.expectEqual(@as(u16, @truncate(298 * 0xFF)), frame.checksum(&bytes));
}

test "built frame parses back to the same payload" {
    var buf: [frame.frame_size]u8 = undefined;
    const payload = [_]u8{ 0x01, 0x02, 0x03, 0xFE };
    try frame.build(&buf, .{ .interface = .priv, .pkt_type = 0x22 }, &payload);
    const got = try frame.parse(&buf);
    try std.testing.expectEqual(frame.Interface.priv, got.header.interface);
    try std.testing.expectEqual(@as(u16, 12), got.header.offset);
    try std.testing.expectEqualSlices(u8, &payload, got.payload);
    const sum: u16 = 0x05 + 0x04 + 0x0C + 0x22 + 0x01 + 0x02 + 0x03 + 0xFE;
    try std.testing.expectEqual(sum, got.header.checksum);
}

test "a corrupted payload byte fails the checksum" {
    var buf: [frame.frame_size]u8 = undefined;
    try frame.build(&buf, .{ .interface = .serial }, "abc");
    buf[13] ^= 1;
    try std.testing.expectError(frame.Error.BadChecksum, frame.parse(&buf));
}

test "parse rejects short frames, low offsets and overruns" {
    try std.testing.expectError(frame.Error.ShortFrame, frame.parse(&@as([4]u8, @splat(0))));
    var buf: [frame.frame_size]u8 = undefined;
    try frame.build(&buf, .{ .interface = .serial }, "abc");
    buf[4] = 2;
    try std.testing.expectError(frame.Error.BadOffset, frame.parse(&buf));
    buf[4] = 12;
    buf[3] = 0x07;
    try std.testing.expectError(frame.Error.BadLength, frame.parse(&buf));
}

test "build refuses a payload larger than one frame holds" {
    var buf: [frame.frame_size]u8 = undefined;
    const big = @as([frame.max_payload + 1]u8, @splat(0));
    try std.testing.expectError(frame.Error.BadLength, frame.build(&buf, .{}, &big));
}
