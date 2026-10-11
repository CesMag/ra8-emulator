//! The GT911 touch panel: the register pointer, the frame, and the tap it
//! refuses to invent.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const gt911 = ra8.components.gt911;
const gpio = ra8.chip.periph.gpio;
const switches = ra8.board.switches;
const sw1 = switches.user[0];
const sw2 = switches.user[1];
const host_bytes = cli_app.cli.host.bytes;

/// Writes all of `bytes` to a pipe end, as the host side of the test.
fn send(fd: std.posix.fd_t, bytes: []const u8) !void {
    const end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    try end.writeStreamingAll(std.testing.io, bytes);
}

fn point(panel: *gt911.Panel) [gt911.record.bytes]u8 {
    var buffer: [gt911.record.bytes]u8 = undefined;
    _ = panel.read(buffer[0..]);
    return buffer;
}

test "the pointer arrives high byte first" {
    var panel = gt911.Panel{};
    panel.write(0x81);
    panel.write(0x40);
    try std.testing.expectEqual(gt911.reg.product, panel.pointer);
}

test "the product id is what a probe reads back" {
    var panel = gt911.Panel{};
    panel.write(0x81);
    panel.write(0x40);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), panel.read(buffer[0..]));
    try std.testing.expectEqualSlices(u8, &gt911.product_id, buffer[0..]);
}

test "a short read of the product id serves what fits" {
    var panel = gt911.Panel{};
    panel.write(0x81);
    panel.write(0x40);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), panel.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, '9'), buffer[0]);
}

test "status reads not ready with nothing armed" {
    var panel = gt911.Panel{};
    panel.write(0x81);
    panel.write(0x4E);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), panel.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
}

test "status reads ready with one contact once a tap is armed" {
    var panel = gt911.Panel{};
    panel.press(.{ .x = 100, .y = 200 });
    panel.write(0x81);
    panel.write(0x4E);
    var buffer: [1]u8 = undefined;
    _ = panel.read(buffer[0..]);
    try std.testing.expectEqual(gt911.status.ready | gt911.status.one_point, buffer[0]);
}

test "the point record carries the coordinate little endian" {
    var panel = gt911.Panel{};
    panel.press(.{ .x = 0x0123, .y = 0x0456 });
    panel.write(0x81);
    panel.write(0x4F);
    const record = point(&panel);
    try std.testing.expectEqual(@as(u8, 0x23), record[gt911.record.x_lsb]);
    try std.testing.expectEqual(@as(u8, 0x01), record[gt911.record.x_msb]);
    try std.testing.expectEqual(@as(u8, 0x56), record[gt911.record.y_lsb]);
    try std.testing.expectEqual(@as(u8, 0x04), record[gt911.record.y_msb]);
    try std.testing.expectEqual(gt911.record.pressure, record[gt911.record.size_lsb]);
}

test "a drained contact is counted once and not served again" {
    var panel = gt911.Panel{};
    panel.press(.{ .x = 7, .y = 9 });
    panel.write(0x81);
    panel.write(0x4F);
    var buffer: [gt911.record.bytes]u8 = undefined;
    try std.testing.expectEqual(gt911.record.bytes, panel.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 1), panel.reported);
    // dev served the same coordinates again and counted a second touch.
    try std.testing.expectEqual(@as(usize, 0), panel.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 1), panel.reported);
    try std.testing.expectEqual(@as(u32, 1), panel.phantom);
}

test "a point read with nothing armed reports no touch at all" {
    var panel = gt911.Panel{};
    panel.write(0x81);
    panel.write(0x4F);
    var buffer: [gt911.record.bytes]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), panel.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 0), panel.reported);
    try std.testing.expectEqual(@as(u32, 1), panel.phantom);
}

test "a point read into a buffer too short for the record serves nothing" {
    var panel = gt911.Panel{};
    panel.press(.{ .x = 1, .y = 2 });
    panel.write(0x81);
    panel.write(0x4F);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), panel.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 0), panel.reported);
}

test "writing zero to status acks the frame and drops the contact" {
    var panel = gt911.Panel{};
    panel.press(.{ .x = 3, .y = 4 });
    panel.write(0x81);
    panel.write(0x4E);
    panel.write(0x00);
    try std.testing.expect(panel.armed == null);
    try std.testing.expectEqual(@as(u32, 1), panel.acked);
}

test "a command write is accepted and changes nothing else" {
    var panel = gt911.Panel{};
    panel.press(.{ .x = 5, .y = 6 });
    panel.write(0x80);
    panel.write(0x40);
    panel.write(0x02);
    try std.testing.expect(panel.armed != null);
    try std.testing.expectEqual(@as(u32, 0), panel.acked);
}

test "a read at a register this model does not carry answers nothing" {
    var panel = gt911.Panel{};
    panel.write(0x90);
    panel.write(0x00);
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), panel.read(buffer[0..]));
    try std.testing.expectEqual(@as(u32, 1), panel.unknown);
}

test "stop ends the pointer capture so the next transfer names its own" {
    var panel = gt911.Panel{};
    panel.write(0x81);
    panel.write(0x40);
    panel.stop();
    panel.write(0x81);
    panel.write(0x4E);
    try std.testing.expectEqual(gt911.reg.status, panel.pointer);
}

test "a queued sequence arms one contact per status read" {
    var panel = gt911.Panel{};
    try panel.queue(.{ .x = 11, .y = 12 });
    try panel.queue(.{ .x = 21, .y = 22 });
    panel.write(0x81);
    panel.write(0x4E);
    var status: [1]u8 = undefined;
    _ = panel.read(status[0..]);
    panel.stop();
    panel.write(0x81);
    panel.write(0x4F);
    const first = point(&panel);
    try std.testing.expectEqual(@as(u8, 11), first[gt911.record.x_lsb]);
    panel.stop();
    panel.write(0x81);
    panel.write(0x4E);
    _ = panel.read(status[0..]);
    panel.stop();
    panel.write(0x81);
    panel.write(0x4F);
    const second = point(&panel);
    try std.testing.expectEqual(@as(u8, 21), second[gt911.record.x_lsb]);
    try std.testing.expectEqual(@as(u32, 2), panel.reported);
}

test "the queue is bounded and says so" {
    var panel = gt911.Panel{};
    for (0..gt911.queue_depth) |_| try panel.queue(.{ .x = 1, .y = 1 });
    try std.testing.expectError(gt911.Error.QueueFull, panel.queue(.{ .x = 2, .y = 2 }));
}

test "a panel nothing touched is quiet" {
    var panel = gt911.Panel{};
    try std.testing.expect(panel.quiet());
    panel.press(.{ .x = 1, .y = 1 });
    try std.testing.expect(panel.quiet());
    panel.write(0x81);
    panel.write(0x4F);
    var buffer: [gt911.record.bytes]u8 = undefined;
    _ = panel.read(buffer[0..]);
    try std.testing.expect(!panel.quiet());
}

/// Read status then the point record the way a driver frame does, and ack.
fn frame(panel: *gt911.Panel) ?gt911.Contact {
    panel.stop();
    panel.write(0x81);
    panel.write(0x4E);
    var state: [1]u8 = undefined;
    _ = panel.read(state[0..]);
    panel.stop();
    if (state[0] & gt911.status.ready == 0) return null;
    panel.write(0x81);
    panel.write(0x4F);
    const record = point(panel);
    panel.stop();
    return .{
        .x = @as(u16, record[gt911.record.x_msb]) << 8 | record[gt911.record.x_lsb],
        .y = @as(u16, record[gt911.record.y_msb]) << 8 | record[gt911.record.y_lsb],
    };
}

test "host touches on a pipe reach the panel's point reads during a run" {
    const ends = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
    defer std.Io.Threaded.closeFd(ends[1]);
    var input = gt911.host.Input{ .source = host_bytes.of(ends[0]) };
    defer std.Io.Threaded.closeFd(ends[0]);
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    try send(ends[1], "down 120,340\nmove 130,3");
    input.poll(&panel, &pins);
    try std.testing.expectEqual(gt911.Contact{ .x = 120, .y = 340 }, frame(&panel).?);
    try std.testing.expectEqual(@as(?gt911.Contact, null), frame(&panel));
    try send(ends[1], "50\nup\n\n");
    input.poll(&panel, &pins);
    try std.testing.expectEqual(gt911.Contact{ .x = 130, .y = 350 }, frame(&panel).?);
    try std.testing.expectEqual(@as(?gt911.Contact, null), frame(&panel));
    try std.testing.expectEqual(@as(u32, 2), input.taken);
    try std.testing.expectEqual(@as(u32, 0), input.refused);
    try std.testing.expect(input.source != null);
}

test "host touch lines that are not a contact are refused and counted" {
    var input = gt911.host.Input{};
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    input.feedLine(&panel, &pins, "tap");
    input.feedLine(&panel, &pins, "12,");
    input.feedLine(&panel, &pins, " 7 , 9 \r");
    try std.testing.expectEqual(@as(u32, 2), input.refused);
    try std.testing.expectEqual(gt911.Contact{ .x = 7, .y = 9 }, frame(&panel).?);
}

test "a drained queue starts over, so a live source never fills it" {
    var panel = gt911.Panel{};
    var n: u16 = 0;
    while (n < 3 * gt911.queue_depth) : (n += 1) {
        try panel.queue(.{ .x = n, .y = n });
        try std.testing.expectEqual(gt911.Contact{ .x = n, .y = n }, frame(&panel).?);
    }
}

test "the end of a host touch file stops the polling" {
    const ends = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
    var input = gt911.host.Input{ .source = host_bytes.of(ends[0]) };
    defer std.Io.Threaded.closeFd(ends[0]);
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    try send(ends[1], "1,2\n");
    std.Io.Threaded.closeFd(ends[1]);
    input.poll(&panel, &pins);
    try std.testing.expect(input.source == null);
    try std.testing.expectEqual(gt911.Contact{ .x = 1, .y = 2 }, frame(&panel).?);
}

test "host switch lines press and release SW1 and SW2 on their active-low pins" {
    var input = gt911.host.Input{ .switches = &switches.user };
    var panel = gt911.Panel{};
    var pins = switches.pulled();
    try std.testing.expect(pins.pinLevel(sw1.port, sw1.pin));
    input.feedLine(&panel, &pins, "sw1 down");
    try std.testing.expect(!pins.pinLevel(sw1.port, sw1.pin));
    try std.testing.expect(pins.pinLevel(sw2.port, sw2.pin));
    input.feedLine(&panel, &pins, "sw2 down");
    input.feedLine(&panel, &pins, "sw1 up");
    try std.testing.expect(pins.pinLevel(sw1.port, sw1.pin));
    try std.testing.expect(!pins.pinLevel(sw2.port, sw2.pin));
    input.feedLine(&panel, &pins, "sw2 sideways");
    try std.testing.expectEqual(@as(u32, 3), input.switched);
    try std.testing.expectEqual(@as(u32, 1), input.refused);
    try std.testing.expectEqual(@as(u32, 0), panel.queued_len);
}

test "a stream with no switches from the board refuses switch lines" {
    var input = gt911.host.Input{};
    var panel = gt911.Panel{};
    var pins = switches.pulled();
    input.feedLine(&panel, &pins, "sw1 down");
    try std.testing.expect(pins.pinLevel(sw1.port, sw1.pin));
    try std.testing.expectEqual(@as(u32, 0), input.switched);
    try std.testing.expectEqual(@as(u32, 1), input.refused);
}
