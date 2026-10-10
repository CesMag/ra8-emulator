//! Covers src/interfaces/usbip/board.zig: the FS device exported from
//! the scripted host's enumeration, and nothing before it finishes.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const wire = cli_app.cli.usbip_wire;
const exp = cli_app.cli.usbip_export;

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
const board = exp.board;

/// A scripted host that has enumerated `device` and `config`.
fn enumerated() usbfs.host.Host {
    var script = usbfs.host.Host{};
    script.device = device;
    @memcpy(script.config[0..config.len], &config);
    script.config_len = config.len;
    script.step = .configured;
    return script;
}

test "nothing is exported before the FS jack has enumerated" {
    const script = usbfs.host.Host{};
    try std.testing.expectEqual(@as(?exp.Export, null), try board.fsExport(&script));
}

test "the enumerated FS device exports as 1-1 at full speed" {
    const script = enumerated();
    const item = (try board.fsExport(&script)).?;
    try std.testing.expectEqualStrings("1-1", item.device.busid);
    try std.testing.expectEqual(wire.Speed.full, item.device.speed);
    try std.testing.expectEqual(@as(u16, 0x045B), item.device.vendor);
    try std.testing.expectEqual(@as(u16, 0x5310), item.device.product);
    try std.testing.expectEqual(@as(u8, 2), item.count);
}

test "a device descriptor of the wrong type is refused" {
    var script = enumerated();
    script.device[1] = 2;
    try std.testing.expectError(error.BadDescriptor, board.fsExport(&script));
}
