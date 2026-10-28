//! Covers src/session/history/usbip_traffic.zig: every kind of USB/IP
//! traffic round-trips through its record body, and a body that was
//! altered or does not fit its kind is refused.
const std = @import("std");
const ra8 = @import("ra8");

const codec = ra8.session.history_usbip_traffic;
const traffic = ra8.board.usb.traffic;
const record = ra8.session.history_record;

fn encoded(buf: *std.Io.Writer.Allocating, event: codec.Event) ![]const u8 {
    buf.clearRetainingCapacity();
    try codec.encode(&buf.writer, event);
    return buf.written();
}

test "the traffic record is the next free boundary kind after the camera's" {
    try std.testing.expectEqual(@as(u16, 12), @backingInt(record.Boundary.What.usbip_traffic));
    try std.testing.expect(@backingInt(record.Boundary.What.usbip_traffic) > @backingInt(record.Boundary.What.camera_frame));
}

test "import, submit, unlink and disconnect round-trip" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var header: [traffic.header_len]u8 = undefined;
    for (&header, 0..) |*b, i| b.* = @truncate(i * 3);
    const cases = [_]codec.Event{
        .{ .kind = .import, .head = "1-1" },
        .{ .kind = .submit, .head = &header, .data = "hello world" },
        .{ .kind = .submit, .head = &header },
        .{ .kind = .unlink, .head = &header },
        .{ .kind = .disconnect },
        .{ .kind = .disconnect, .pumped = true },
    };
    for (cases) |case| {
        const got = try codec.decode(try encoded(&buf, case));
        try std.testing.expectEqual(case.kind, got.kind);
        try std.testing.expectEqual(case.pumped, got.pumped);
        try std.testing.expectEqualSlices(u8, case.head, got.head);
        try std.testing.expectEqualSlices(u8, case.data, got.data);
    }
}

test "a record with a flipped bit, a short body or a lying length is refused" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var header = @as([traffic.header_len]u8, @splat(7));
    const body = try std.testing.allocator.dupe(u8, try encoded(&buf, .{ .kind = .submit, .head = &header, .data = "abcdef" }));
    defer std.testing.allocator.free(body);
    for (0..body.len) |at| {
        body[at] ^= 0x10;
        defer body[at] ^= 0x10;
        try std.testing.expect(std.meta.isError(codec.decode(body)));
    }
    try std.testing.expectError(codec.Error.BadCrc, blk: {
        body[body.len - 1] ^= 1;
        defer body[body.len - 1] ^= 1;
        break :blk codec.decode(body);
    });
    for (0..body.len) |n| try std.testing.expect(std.meta.isError(codec.decode(body[0..n])));
}

test "a record that does not fit its kind is refused on both sides" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const short = @as([8]u8, @splat(0));
    const header = @as([traffic.header_len]u8, @splat(0));
    const huge = try std.testing.allocator.alloc(u8, traffic.max_data + 1);
    defer std.testing.allocator.free(huge);
    const bad = [_]codec.Event{
        .{ .kind = .submit, .head = &short },
        .{ .kind = .submit, .head = &header, .data = huge },
        .{ .kind = .unlink, .head = &header, .data = "x" },
        .{ .kind = .import },
        .{ .kind = .disconnect, .head = "x" },
        .{ .kind = .submit, .head = &header, .pumped = true },
    };
    for (bad) |case| try std.testing.expectError(error.BadValue, codec.encode(&buf.writer, case));
    // The same shapes forged past the encoder still fail the decoder.
    var forged: [codec.fixed_len + 4]u8 = @splat(0);
    forged[0] = 9;
    std.mem.writeInt(u32, forged[8..12], std.hash.crc.@"CRC-32/ISCSI".hash(forged[0..8]), .little);
    try std.testing.expectError(codec.Error.BadValue, codec.decode(&forged));
}

test "a progress entry round-trips and one of the wrong size is refused" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var head: [traffic.Progress.len]u8 = undefined;
    const progress: traffic.Progress = .{ .seqnum = 7, .moved = 64, .stage = 2, .done = false };
    progress.encode(&head);
    const got = try codec.decode(try encoded(&buf, .{ .kind = .progress, .head = &head }));
    try std.testing.expectEqual(progress, try traffic.Progress.decode(got.head));
    try std.testing.expectError(error.BadValue, encoded(&buf, .{ .kind = .progress, .head = head[0..4] }));
    try std.testing.expectError(error.BadValue, encoded(&buf, .{ .kind = .progress, .head = &head, .data = "x" }));
}
