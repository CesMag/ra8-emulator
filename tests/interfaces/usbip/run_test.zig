//! Covers src/interfaces/usbip/run.zig: `--usbip` puts a live bridge
//! on the board's USB tick and reports what it does in plain lines.
const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.usbip.wire;
const exp = ra8.usbip.exported;

/// A CDC ACM device: class 0xEF/2/1 (IAD), VID 0x045B PID 0x5310, bcd 1.00.
const device = [_]u8{ 18, 1, 0x00, 0x02, 0xEF, 0x02, 0x01, 64, 0x5B, 0x04, 0x10, 0x53, 0x00, 0x01, 1, 2, 3, 1 };

/// Configuration 1: an IAD, a CDC communication interface with one
/// functional descriptor and an interrupt endpoint, a data interface with
/// two bulk endpoints, and an alternate setting that must not be listed.
const config = [_]u8{
    9,  2,  75,   0,    2,    1, 0,    0x80, 50,
    8,  11, 0,    2,    2,    2, 1,    0,    9,
    4,  0,  0,    1,    2,    2, 1,    0,    5,
    36, 0,  0x10, 0x01, 7,    5, 0x83, 3,    16,
    0,  16, 9,    4,    1,    0, 2,    0x0A, 0,
    0,  0,  7,    5,    0x81, 2, 0,    2,    0,
    7,  5,  0x01, 2,    0,    2, 0,    9,    4,
    1,  1,  0,    0x0A, 0,    0, 0,
};

const usbfs = ra8.chip.periph.usbfs;
const run = exp.run;

fn enumerated() usbfs.host.Host {
    var script = usbfs.host.Host{};
    script.device = device;
    @memcpy(script.config[0..config.len], &config);
    script.config_len = config.len;
    script.step = .configured;
    return script;
}

test "no port asked for leaves the USB tick alone" {
    var board = ra8.board.usb.Usb{};
    try run.install(&board, std.testing.allocator, std.testing.io, null);
    try std.testing.expect(board.bridge == null);
}

test "a port puts a bridge on the tick that waits for enumeration" {
    var board = ra8.board.usb.Usb{};
    try run.install(&board, std.testing.allocator, std.testing.io, 0);
    const hook = board.bridge.?;
    const live: *run.Live = @ptrCast(@alignCast(hook.context));
    defer {
        live.link.deinit(std.testing.allocator);
        std.testing.allocator.destroy(live);
    }
    board.tick();
    try std.testing.expectEqual(@as(?u16, null), live.link.port());
    try std.testing.expect(!live.stopped);
}

test "the events read as plain lines" {
    var link = try exp.bridge.Bridge.init(std.testing.allocator, std.testing.io, 0);
    defer link.deinit(std.testing.allocator);
    var board = usbfs.Device{};
    const script = enumerated();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run.report(&out.writer, try link.poll(&board, &script), &link);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "usbip: exporting 1-1 (045b:5310) on 127.0.0.1:"));
    out.clearRetainingCapacity();
    try run.report(&out.writer, .attached, &link);
    try std.testing.expectEqualStrings("usbip: a host imported 1-1\n", out.written());
    out.clearRetainingCapacity();
    try run.report(&out.writer, .none, &link);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
