//! Covers src/interfaces/usbip/attach.zig: each step reads the reply
//! the server writes, and what it sends is what the server reads.
const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.usbip.wire;
const exp = ra8.usbip.exported;
const attach = wire.client.attach;

/// usb_printer_vendor's descriptors, as the scripted host read them.
const device = [_]u8{ 0x12, 1, 0, 2, 0, 0, 0, 0x40, 0x09, 0x12, 0x01, 0, 0, 1, 0, 0, 0, 1 };
const config = [_]u8{
    9, 2,    0x37, 0, 2,    1, 0, 0x80, 0x32, 9,    4, 0,    0, 2, 7,    1, 2,    0,
    7, 5,    0x01, 2, 0x40, 0, 0, 7,    5,    0x82, 2, 0x40, 0, 0, 9,    4, 1,    0,
    2, 0xFF, 0,    0, 0,    7, 5, 0x81, 2,    0x40, 0, 0,    7, 5, 0x02, 2, 0x40, 0,
    0,
};
/// Swallows what a step sends when the test only checks what it reads.
var discard: std.Io.Writer.Discarding = .init(&.{});
const place = exp.Place{ .path = "/sys/devices/ra8/usbfs", .busid = "1-1", .speed = .full };

test "first reads the device list the server writes and returns its export" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var reply: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reply.deinit();
    try exp.writeDevlist(&reply.writer, &items);
    var stream: std.Io.Reader = .fixed(reply.written());
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    var record: [wire.device_len]u8 = undefined;
    const listed = (try attach.first(&stream, &sent.writer, &record)).?;
    try std.testing.expectEqualStrings("1-1", listed.busid);
    try std.testing.expectEqual(@as(u16, 0x1209), listed.vendor);
    try std.testing.expectEqual(@as(u16, 0x0001), listed.product);
    try std.testing.expectEqual(reply.written().len, stream.seek);
    var request: std.Io.Reader = .fixed(sent.written());
    const served = try exp.server.answer(&request, &discard.writer, &items);
    try std.testing.expect(served.? == .listed);
}

test "an empty list is null" {
    var reply: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reply.deinit();
    try exp.writeDevlist(&reply.writer, &.{});
    var stream: std.Io.Reader = .fixed(reply.written());
    var record: [wire.device_len]u8 = undefined;
    try std.testing.expectEqual(null, try attach.first(&stream, &discard.writer, &record));
}

test "import sends the busid the server finds and reads its record" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var reply: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reply.deinit();
    try exp.writeImport(&reply.writer, &items[0]);
    var stream: std.Io.Reader = .fixed(reply.written());
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    var record: [wire.device_len]u8 = undefined;
    const listed = try attach.import(&stream, &sent.writer, "1-1", &record);
    try std.testing.expectEqual(@as(u16, 0x1209), listed.vendor);
    var request: std.Io.Reader = .fixed(sent.written());
    const served = try exp.server.answer(&request, &discard.writer, &items);
    try std.testing.expectEqual(&items[0], served.?.imported);
}

test "a refused import is an error" {
    var reply: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer reply.deinit();
    try exp.writeImport(&reply.writer, null);
    var stream: std.Io.Reader = .fixed(reply.written());
    var record: [wire.device_len]u8 = undefined;
    try std.testing.expectError(error.Refused, attach.import(&stream, &discard.writer, "9-9", &record));
}

test "an IN transfer reads the data its reply counts" {
    var reply: [wire.basic_len + device.len]u8 = undefined;
    wire.retSubmit(reply[0..wire.basic_len], 3, 0, device.len);
    @memcpy(reply[wire.basic_len..], &device);
    var stream: std.Io.Reader = .fixed(&reply);
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    var in_buf: [64]u8 = undefined;
    const urb = wire.client.Urb{ .seqnum = 3, .devid = 0x10002, .direction = .in, .ep = 0, .length = 18, .setup = wire.client.getDescriptor(1, 0, 18) };
    const back = try attach.transfer(&stream, &sent.writer, urb, &.{}, &in_buf);
    try std.testing.expectEqual(@as(u32, 18), back.actual);
    try std.testing.expectEqualSlices(u8, &device, in_buf[0..18]);
    try std.testing.expectEqual(wire.basic_len, sent.written().len);
    try std.testing.expectEqual(@as(u32, 3), (try wire.Submit.decode(sent.written())).seqnum);
}

test "an OUT transfer sends its data after the header and reads no data back" {
    var reply: [wire.basic_len]u8 = undefined;
    wire.retSubmit(&reply, 4, 0, 4);
    var stream: std.Io.Reader = .fixed(&reply);
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    const urb = wire.client.Urb{ .seqnum = 4, .devid = 0x10002, .direction = .out, .ep = 2, .length = 4 };
    _ = try attach.transfer(&stream, &sent.writer, urb, "ping", &.{});
    try std.testing.expectEqualStrings("ping", sent.written()[wire.basic_len..]);
}

test "a reply for another URB or with too much data is refused" {
    var reply: [wire.basic_len]u8 = undefined;
    wire.retSubmit(&reply, 9, 0, 0);
    var stream: std.Io.Reader = .fixed(&reply);
    const urb = wire.client.Urb{ .seqnum = 5, .devid = 1, .direction = .in, .ep = 1, .length = 8 };
    try std.testing.expectError(error.Unexpected, attach.transfer(&stream, &discard.writer, urb, &.{}, &.{}));
    wire.retSubmit(&reply, 5, 0, 8);
    stream.seek = 0;
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.Overflow, attach.transfer(&stream, &discard.writer, urb, &.{}, &small));
}
