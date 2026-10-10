//! Tests for host-backed DNS response framing.
const std = @import("std");
const ra8 = @import("ra8");
const dns = ra8.components.esp_hosted.dns;

fn query(out: []u8, qtype: u16) []const u8 {
    @memset(out, 0);
    out[0] = 0x12;
    out[1] = 0x34;
    out[2] = 0x01;
    out[5] = 1;
    out[12] = 4;
    @memcpy(out[13..17], "host");
    out[17] = 3;
    @memcpy(out[18..21], "ra8");
    std.mem.writeInt(u16, out[22..24], qtype, .big);
    std.mem.writeInt(u16, out[24..26], 1, .big);
    return out[0..26];
}

fn lookup(_: ?*anyopaque, _: ?std.Io, name: []const u8, out: *[dns.max_answers][4]u8) !u8 {
    try std.testing.expectEqualSlices(u8, "host.ra8", name);
    out[0] = .{ 192, 0, 2, 7 };
    out[1] = .{ 198, 51, 100, 9 };
    return 2;
}

fn fail(_: ?*anyopaque, _: ?std.Io, _: []const u8, _: *[dns.max_answers][4]u8) !u8 {
    return error.NoResolver;
}

test "an A query gets deterministic host resolver answers" {
    var request: [64]u8 = undefined;
    var response: [256]u8 = undefined;
    const len = dns.answer(&response, query(&request, 1), .{ .lookupFn = lookup }).?;
    try std.testing.expectEqual(@as(usize, 58), len);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, response[0..2]);
    try std.testing.expectEqual(@as(u16, 0x8180), std.mem.readInt(u16, response[2..4], .big));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, response[6..8], .big));
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 7 }, response[38..42]);
    try std.testing.expectEqualSlices(u8, &.{ 198, 51, 100, 9 }, response[54..58]);
}

test "AAAA is NODATA and resolver failure is SERVFAIL" {
    var request: [64]u8 = undefined;
    var response: [256]u8 = undefined;
    const nodata = dns.answer(&response, query(&request, 28), .{}).?;
    try std.testing.expectEqual(@as(usize, 26), nodata);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, response[6..8], .big));
    _ = dns.answer(&response, query(&request, 1), .{ .lookupFn = fail }).?;
    try std.testing.expectEqual(@as(u16, 0x8182), std.mem.readInt(u16, response[2..4], .big));
}

test "compressed truncated and multi-question requests are ignored" {
    var request: [64]u8 = undefined;
    var response: [256]u8 = undefined;
    const valid = query(&request, 1);
    request[12] = 0xC0;
    try std.testing.expect(dns.answer(&response, valid, .{}) == null);
    _ = query(&request, 1);
    request[5] = 2;
    try std.testing.expect(dns.answer(&response, valid, .{}) == null);
    try std.testing.expect(dns.answer(&response, valid[0..10], .{}) == null);
}
