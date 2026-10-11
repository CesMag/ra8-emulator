//! The `fs_host` object inside `usb` of `--report json` (RA8EMU-364): how
//! far the scripted host on the USBFS jack got through enumeration, and the
//! descriptors it was handed, the same facts report/usb.zig prints.
//! Descriptors are lowercase hex strings, null when none came back.
const std = @import("std");
const usbfs_host = @import("ra8_chip").periph.usbfs.host;

/// The whole `fs_host` object, keyed inside `usb`.
pub fn section(j: anytype, host: *const usbfs_host.Host) !void {
    var hex: [256]u8 = undefined;
    var name: [128]u8 = undefined;
    try j.open("fs_host", '{');
    try j.field("step", @tagName(host.step));
    try j.field("waited", host.waited);
    try j.field("device_descriptor", hexOf(&host.device, &hex));
    try j.field("config_descriptor", hexOf(host.configuration(), &hex));
    try j.field("product", textOf(&host.product, &name));
    try j.field("configuration_value", host.config_value[0]);
    try j.field("status", @as(u16, host.status[0]) | @as(u16, host.status[1]) << 8);
    try j.field("set_interface", @tagName(host.interface));
    try j.field("halt_set", @tagName(host.halt_set));
    try j.field("halt_clear", @tagName(host.halt_clear));
    try j.close('}');
}

/// The bytes as hex into `buf`, null when the first byte is zero (none
/// came back) or the descriptor does not fit.
fn hexOf(bytes: []const u8, buf: []u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[0] == 0 or bytes.len * 2 > buf.len) return null;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        buf[i * 2] = digits[byte >> 4];
        buf[i * 2 + 1] = digits[byte & 0xF];
    }
    return buf[0 .. bytes.len * 2];
}

/// A string descriptor as text, '?' for anything outside printable ASCII,
/// as report/usb.zig prints it; null when none came back.
fn textOf(bytes: []const u8, buf: []u8) ?[]const u8 {
    const length = @min(bytes[0], bytes.len);
    if (length < 2) return null;
    var n: usize = 0;
    var i: usize = 2;
    while (i + 1 < length and n < buf.len) : (i += 2) {
        const unit = std.mem.readInt(u16, bytes[i..][0..2], .little);
        buf[n] = if (unit >= 0x20 and unit < 0x7F) @intCast(unit) else '?';
        n += 1;
    }
    return buf[0..n];
}
