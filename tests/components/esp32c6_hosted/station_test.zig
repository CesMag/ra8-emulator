//! Tests for src/components/esp32c6_hosted/station.zig and the link's events.
const std = @import("std");
const ra8 = @import("ra8");
const hosted = ra8.components.esp_hosted;
const frame = hosted.frame;
const event = hosted.event;
const rpc = hosted.rpc;
const station = hosted.station;
const Link = hosted.link.Link;

const caps = [_]u8{ 0x22, 15, 0x44, 1, 0, 0x45, 1, 0x0D, 0x46, 1, 0, 0x47, 1, 80, 0x48, 1, 60 };

/// One decoded protobuf field: its varint value or its bytes.
const Field = struct { number: u64, value: u64 = 0, bytes: []const u8 = &.{} };

fn fields(buf: []const u8, out: []Field) !usize {
    var r: rpc.Reader = .{ .buf = buf };
    var n: usize = 0;
    while (!r.done()) : (n += 1) {
        const key = try r.varint();
        out[n] = .{ .number = key >> 3 };
        switch (@as(u3, @truncate(key))) {
            0 => out[n].value = try r.varint(),
            2 => out[n].bytes = try r.bytes(),
            else => return error.TestUnexpectedResult,
        }
    }
    return n;
}

fn request(buf: []u8, id: u32, uid: u32) ![]const u8 {
    var proto_buf: [32]u8 = undefined;
    var proto: event.Writer = .{ .buf = &proto_buf };
    try proto.key(1, 0);
    try proto.varint(@backingInt(event.Kind.request));
    try proto.key(2, 0);
    try proto.varint(id);
    try proto.key(3, 0);
    try proto.varint(uid);
    try proto.field(id, &.{});
    var payload: event.Writer = .{ .buf = buf };
    try event.envelope(&payload, event.endpoint_response, proto.written());
    return payload.written();
}

fn clock(link: *Link, sent: *const [frame.frame_size]u8, got: *[frame.frame_size]u8) void {
    for (sent, got) |byte, *out| out.* = link.exchange(byte);
}

/// The msg_id of the RPC carried by a frame the link sent.
fn msgId(got: *const [frame.frame_size]u8) !u64 {
    var list: [8]Field = undefined;
    const n = try fields(rpc.tlvData((try frame.parse(got)).payload).?, &list);
    for (list[0..n]) |f| if (f.number == 2) return f.value;
    return error.TestUnexpectedResult;
}

test "GetMACAddress answers the scripted station address" {
    var buf: [64]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try std.testing.expect(try station.body(&w, station.Id.req_mac));
    var list: [4]Field = undefined;
    try std.testing.expectEqual(@as(usize, 1), try fields(w.written(), &list));
    try std.testing.expectEqualSlices(u8, &station.mac, list[0].bytes);
}

test "WifiStaGetApInfo carries the scripted access point record" {
    var buf: [64]u8 = undefined;
    var w: event.Writer = .{ .buf = &buf };
    try std.testing.expect(try station.body(&w, station.Id.req_ap_info));
    var outer: [2]Field = undefined;
    _ = try fields(w.written(), &outer);
    try std.testing.expectEqual(@as(u64, 2), outer[0].number);
    var record: [4]Field = undefined;
    try std.testing.expectEqual(@as(usize, 4), try fields(outer[0].bytes, &record));
    try std.testing.expectEqualSlices(u8, &station.bssid, record[0].bytes);
    try std.testing.expectEqualSlices(u8, "benc", record[1].bytes);
    try std.testing.expectEqual(@as(u64, 6), record[2].value);
    try std.testing.expectEqual(@as(i64, -55), @as(i64, @bitCast(record[3].value)));
    try std.testing.expect(!try station.body(&w, 999));
}

test "station start and connect raise their events" {
    try std.testing.expectEqual(@as(?u32, station.Id.event_no_args), station.followUp(station.Id.req_start));
    try std.testing.expectEqual(@as(?u32, station.Id.event_connected), station.followUp(station.Id.req_connect));
    try std.testing.expectEqual(@as(?u32, null), station.followUp(station.Id.req_mac));

    var out: [frame.frame_size]u8 = undefined;
    try station.eventFrame(&out, station.Id.event_connected);
    const got = try frame.parse(&out);
    try std.testing.expectEqualSlices(u8, "RPCEvt", got.payload[3..9]);
    var list: [4]Field = undefined;
    const n = try fields(rpc.tlvData(got.payload).?, &list);
    try std.testing.expectEqual(@as(u64, 3), list[0].value);
    try std.testing.expectEqual(@as(u64, 775), list[1].value);
    var body: [2]Field = undefined;
    _ = try fields(list[n - 1].bytes, &body);
    var inner: [4]Field = undefined;
    _ = try fields(body[0].bytes, &inner);
    try std.testing.expectEqualSlices(u8, "benc", inner[0].bytes);
    try std.testing.expectEqual(@as(u64, 4), inner[1].value);
    try std.testing.expectEqual(@as(u64, 6), inner[3].value);
}

test "the link sends the WifiStart answer and then STA_START" {
    var link: Link = .{};
    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    var buf: [64]u8 = undefined;
    try frame.build(&sent, .{ .interface = .priv }, &caps);
    clock(&link, &sent, &got);
    frame.filler(&sent);
    clock(&link, &sent, &got);
    try std.testing.expect(!link.dataReady());

    try frame.build(&sent, .{ .interface = .serial }, try request(&buf, station.Id.req_start, 3));
    clock(&link, &sent, &got);
    try std.testing.expect(link.dataReady());
    frame.filler(&sent);
    clock(&link, &sent, &got);
    try std.testing.expectEqual(@as(u64, 536), try msgId(&got));
    try std.testing.expect(link.dataReady());
    clock(&link, &sent, &got);
    try std.testing.expectEqual(@as(u64, 773), try msgId(&got));
    try std.testing.expect(!link.dataReady());
}
