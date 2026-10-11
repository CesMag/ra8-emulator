//! The remote protocol's framing: checksums, escapes, and the reader that
//! turns a byte stream from gdb into acks, interrupts and packets.
const std = @import("std");
const ra8 = @import("ra8");
const packet = ra8.gdb.rsp.packet;

fn readAll(reader: *packet.Reader, bytes: []const u8) ?packet.Event {
    var last: ?packet.Event = null;
    for (bytes) |byte| {
        if (reader.push(byte)) |event| last = event;
    }
    return last;
}

// gdb's own examples: `$OK#9a` and the empty reply `$#00`.
test "a frame carries the payload's byte sum in lower-case hex" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("$OK#9a", try packet.frame(&out, "OK"));
    try std.testing.expectEqualStrings("$#00", try packet.frame(&out, ""));
    try std.testing.expectEqual(@as(u8, 0x9a), packet.checksum("OK"));
}

// `#` is 0x23 and goes out as `}` then 0x03; the sum covers what was sent.
test "framing escapes the four reserved bytes" {
    var out: [32]u8 = undefined;
    const framed = try packet.frame(&out, "a#b$c}d*");
    try std.testing.expectEqualStrings("$a}\x03b}\x04c}]d}\x0a#", framed[0 .. framed.len - 2]);
    const body = framed[1 .. framed.len - 3];
    const digits = std.fmt.hex(packet.checksum(body));
    try std.testing.expectEqualSlices(u8, &digits, framed[framed.len - 2 ..]);
}

test "a frame that does not fit reports no space" {
    var out: [5]u8 = undefined;
    try std.testing.expectError(error.NoSpace, packet.frame(&out, "OK"));
}

test "the reader returns a packet whose checksum holds" {
    var buffer: [64]u8 = undefined;
    var reader = packet.Reader.init(&buffer);
    const event = readAll(&reader, "$qSupported:multiprocess+#c6").?;
    try std.testing.expectEqualStrings("qSupported:multiprocess+", event.packet);
}

test "the reader flags a packet whose checksum is wrong" {
    var buffer: [64]u8 = undefined;
    var reader = packet.Reader.init(&buffer);
    try std.testing.expectEqual(packet.Event.corrupt, readAll(&reader, "$OK#9b").?);
    try std.testing.expectEqual(packet.Event.corrupt, readAll(&reader, "$OK#9z").?);
}

test "the reader unescapes what frame escaped" {
    var out: [64]u8 = undefined;
    var buffer: [64]u8 = undefined;
    var reader = packet.Reader.init(&buffer);
    const raw = "X22000054,4:\x23\x24\x7d\x2a";
    const event = readAll(&reader, try packet.frame(&out, raw)).?;
    try std.testing.expectEqualStrings(raw, event.packet);
}

test "single bytes outside a packet are acks, resends and interrupts" {
    var buffer: [8]u8 = undefined;
    var reader = packet.Reader.init(&buffer);
    try std.testing.expectEqual(packet.Event.ack, reader.push('+').?);
    try std.testing.expectEqual(packet.Event.resend, reader.push('-').?);
    try std.testing.expectEqual(packet.Event.interrupt, reader.push(0x03).?);
    try std.testing.expectEqual(@as(?packet.Event, null), reader.push('x'));
}

test "an ack and a packet in one read come out in order" {
    var buffer: [16]u8 = undefined;
    var reader = packet.Reader.init(&buffer);
    var seen: [2]packet.Event = undefined;
    var count: usize = 0;
    for ("+$?#3f") |byte| {
        if (reader.push(byte)) |event| {
            seen[count] = event;
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(packet.Event.ack, seen[0]);
    try std.testing.expectEqualStrings("?", seen[1].packet);
}

test "a packet longer than the buffer is an overflow, and the next one reads" {
    var buffer: [4]u8 = undefined;
    var reader = packet.Reader.init(&buffer);
    var out: [32]u8 = undefined;
    try std.testing.expectEqual(packet.Event.overflow, readAll(&reader, try packet.frame(&out, "m22000000,40")).?);
    try std.testing.expectEqualStrings("g", readAll(&reader, "$g#67").?.packet);
}
