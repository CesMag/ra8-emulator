//! Covers src/interfaces/usbip/client.zig: every client request
//! decodes on the server side, and every server reply decodes here.
const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.usbip.wire;
const client = wire.client;

test "OP_REQ_DEVLIST is the header the server reads as a devlist request" {
    var out: [wire.op_header_len]u8 = undefined;
    client.devlist(&out);
    try std.testing.expectEqual(wire.op.req_devlist, (try wire.OpHeader.decode(&out)).code);
}

test "OP_REQ_IMPORT carries the busid the server reads back" {
    var out: [client.import_len]u8 = undefined;
    try client.importRequest(&out, "1-1");
    try std.testing.expectEqual(wire.op.req_import, (try wire.OpHeader.decode(&out)).code);
    try std.testing.expectEqualStrings("1-1", try wire.importBusid(out[wire.op_header_len..]));
    try std.testing.expectError(error.TooLong, client.importRequest(&out, &@as([32:0]u8, @splat('x'))));
}

test "a listed device decodes from the record the server encodes" {
    var out: [wire.device_len]u8 = undefined;
    try (wire.Device{ .path = "/sys/ra8", .busid = "1-1", .busnum = 1, .devnum = 2, .speed = .full, .vendor = 0x1209, .product = 0x0001, .bcd_device = 0x0100 }).encode(&out);
    const listed = try client.Listed.decode(&out);
    try std.testing.expectEqualStrings("1-1", listed.busid);
    try std.testing.expectEqual(@as(u16, 0x1209), listed.vendor);
    try std.testing.expectEqual(@as(u16, 0x0001), listed.product);
    try std.testing.expectEqual(@as(u32, 0x0001_0002), listed.devid());
    try std.testing.expectError(error.Short, client.Listed.decode(out[0..300]));
}

test "a submitted URB decodes to the same fields on the server" {
    var out: [wire.basic_len]u8 = undefined;
    const setup = client.getDescriptor(1, 0, 18);
    client.submit(&out, .{ .seqnum = 7, .devid = 0x0001_0002, .direction = .in, .ep = 0, .length = 18, .setup = setup });
    const back = try wire.Submit.decode(&out);
    try std.testing.expectEqual(@as(u32, 7), back.seqnum);
    try std.testing.expectEqual(@as(u32, 0x0001_0002), back.devid);
    try std.testing.expectEqual(wire.Direction.in, back.direction);
    try std.testing.expectEqual(@as(u32, 18), back.length);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 6, 0, 1, 0, 0, 18, 0 }, &back.setup);
    try std.testing.expectEqual(@as(u32, 0), back.outBytes());
}

test "a RET_SUBMIT decodes to seqnum, status and actual length" {
    var out: [wire.basic_len]u8 = undefined;
    wire.retSubmit(&out, 7, -32, 18);
    const back = try client.Returned.decode(&out);
    try std.testing.expectEqual(@as(u32, 7), back.seqnum);
    try std.testing.expectEqual(@as(i32, -32), back.status);
    try std.testing.expectEqual(@as(u32, 18), back.actual);
    wire.retUnlink(&out, 7, 0);
    try std.testing.expectError(error.BadCommand, client.Returned.decode(&out));
}

test {
    _ = @import("attach_test.zig");
}
