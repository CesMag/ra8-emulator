//! Tests for src/components/esp32c6_hosted/rpc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const frame = hosted.frame;
const event = hosted.event;
const rpc = hosted.rpc;
const Link = hosted.link.Link;

const caps = [_]u8{ 0x22, 15, 0x44, 1, 0, 0x45, 1, 0x0D, 0x46, 1, 0, 0x47, 1, 80, 0x48, 1, 60 };

/// Builds the host's Req_GetCoprocessorFwVersion as serial TLVs.
fn fwRequest(buf: []u8, kind: event.Kind, uid: u32) ![]const u8 {
    var proto_buf: [32]u8 = undefined;
    var proto: event.Writer = .{ .buf = &proto_buf };
    try proto.key(1, 0);
    try proto.varint(@backingInt(kind));
    try proto.key(2, 0);
    try proto.varint(rpc.Id.req_fw_version);
    try proto.key(3, 0);
    try proto.varint(uid);
    try proto.field(rpc.Id.req_fw_version, &.{});
    var payload: event.Writer = .{ .buf = buf };
    try event.envelope(&payload, event.endpoint_response, proto.written());
    return payload.written();
}

/// Reads every varint field of `body` into `out`, indexed by field number.
fn varints(body: []const u8, out: []u64) !void {
    var r: rpc.Reader = .{ .buf = body };
    while (!r.done()) {
        const key = try r.varint();
        const wire: u3 = @truncate(key);
        if (wire == 0 and key >> 3 < out.len) {
            out[@intCast(key >> 3)] = try r.varint();
        } else try r.skip(wire);
    }
}

fn clock(link: *Link, sent: *const [frame.frame_size]u8, got: *[frame.frame_size]u8) void {
    for (sent, got) |byte, *out| out.* = link.exchange(byte);
}

test "the reader decodes a multi-byte varint and a length-delimited field" {
    var r: rpc.Reader = .{ .buf = &.{ 0x81, 0x06, 0x03, 'a', 'b', 'c' } };
    try std.testing.expectEqual(@as(u64, 769), try r.varint());
    try std.testing.expectEqualSlices(u8, "abc", try r.bytes());
    try std.testing.expect(r.done());
    try std.testing.expectError(rpc.Error.Truncated, r.varint());
}

test "the data TLV is found after the endpoint TLV" {
    var buf: [64]u8 = undefined;
    const payload = try fwRequest(&buf, .request, 1);
    const proto = rpc.tlvData(payload) orelse return error.TestUnexpectedResult;
    const req = try rpc.request(proto);
    try std.testing.expectEqual(rpc.Id.req_fw_version, req.id);
    try std.testing.expectEqual(@as(u32, 1), req.uid);
    try std.testing.expectEqual(@as(?[]const u8, null), rpc.tlvData(&.{ 0x01, 9, 0 }));
}

test "a response or event is not taken as a request" {
    var buf: [64]u8 = undefined;
    const payload = try fwRequest(&buf, .response, 1);
    try std.testing.expectError(rpc.Error.NotRequest, rpc.request(rpc.tlvData(payload).?));
}

test "the firmware version answer echoes the uid and reports 2.12.11 on an ESP32-C6" {
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(try rpc.answerFrame(&out, .{ .id = rpc.Id.req_fw_version, .uid = 7 }));
    const got = try frame.parse(&out);
    try std.testing.expectEqual(frame.Interface.serial, got.header.interface);
    const proto = rpc.tlvData(got.payload).?;
    var envelope = @as([4]u64, @splat(0));
    try varints(proto, &envelope);
    try std.testing.expectEqual(@as(u64, 2), envelope[1]);
    try std.testing.expectEqual(@as(u64, 606), envelope[2]);
    try std.testing.expectEqual(@as(u64, 7), envelope[3]);
    try std.testing.expect(std.mem.indexOf(u8, got.payload, event.endpoint_response) != null);
    try std.testing.expect(std.mem.indexOf(u8, proto, rpc.idf_target) != null);
}

test "the firmware version body carries version, chip id and target" {
    var buf: [32]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try rpc.fwVersion(&w);
    var fields = @as([9]u64, @splat(0));
    try varints(w.written(), &fields);
    try std.testing.expectEqual(@as(u64, 0), fields[1]);
    try std.testing.expectEqual(@as(u64, 2), fields[2]);
    try std.testing.expectEqual(@as(u64, 12), fields[3]);
    try std.testing.expectEqual(@as(u64, 11), fields[4]);
    try std.testing.expectEqual(@as(u64, 0x0D), fields[8]);
}

test "an unknown request gets no answer" {
    var out: [frame.frame_size]u8 = undefined;
    try std.testing.expect(!try rpc.answerFrame(&out, .{ .id = 999, .uid = 1 }));
}

test "the link answers the request only after the host announces itself" {
    var link: Link = .{};
    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    var buf: [64]u8 = undefined;
    const request = try fwRequest(&buf, .request, 1);

    try frame.build(&sent, .{ .interface = .serial }, request);
    clock(&link, &sent, &got);
    try std.testing.expect(!link.dataReady());

    try frame.build(&sent, .{ .interface = .priv }, &caps);
    clock(&link, &sent, &got);
    try frame.build(&sent, .{ .interface = .serial }, request);
    clock(&link, &sent, &got);
    try std.testing.expectEqual(@as(u32, 1), link.boots_sent);
    try std.testing.expect(link.dataReady());

    frame.filler(&sent);
    clock(&link, &sent, &got);
    try std.testing.expectEqual(@as(u32, 1), link.replies_sent);
    try std.testing.expect(!link.dataReady());
    const proto = rpc.tlvData((try frame.parse(&got)).payload).?;
    var envelope = @as([4]u64, @splat(0));
    try varints(proto, &envelope);
    try std.testing.expectEqual(@as(u64, 606), envelope[2]);
    try std.testing.expectEqual(@as(u64, 1), envelope[3]);
}

test "station requests get a bare acknowledgement echoing the uid" {
    for (rpc.bare) |id| {
        var out: [frame.frame_size]u8 = undefined;
        try std.testing.expect(try rpc.answerFrame(&out, .{ .id = id, .uid = 5 }));
        const proto = rpc.tlvData((try frame.parse(&out)).payload).?;
        var envelope = @as([4]u64, @splat(0));
        try varints(proto, &envelope);
        try std.testing.expectEqual(@as(u64, 2), envelope[1]);
        try std.testing.expectEqual(@as(u64, id + 256), envelope[2]);
        try std.testing.expectEqual(@as(u64, 5), envelope[3]);
    }
    try std.testing.expectEqual(@as(u32, 536), rpc.Id.responseTo(280));
    try std.testing.expect(!rpc.isBare(rpc.Id.req_fw_version));
}
