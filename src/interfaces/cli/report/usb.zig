//! What the scripted host on the USBFS jack got out of the device: how far
//! enumeration went, and the descriptors it was handed on the way.
const std = @import("std");
const usbfs_host = @import("ra8_chip").periph.usbfs_host;

/// Silent until the pull-up put a device on the jack.
pub fn section(host: *const usbfs_host.Host, out: anytype) !void {
    if (host.step == .waiting) return;
    try out.print("USBFS host: enumeration {s}", .{@tagName(host.step)});
    if (host.step == .failed) try out.print(" on {s}", .{@tagName(host.failed_on)});
    if (host.step != .configured) try out.print(" after {d} boundary(ies) on that step", .{host.waited});
    try out.writeAll("\n");
    try descriptor("device", &host.device, out);
    try descriptor("config", host.configuration(), out);
    try text("product", &host.product, out);
    if (host.step != .configured) return;
    try out.writeAll("USBFS host: configuration value ");
    if (host.config_answer == .stall) try out.writeAll("stall") else try out.print("{d}", .{host.config_value[0]});
    try out.writeAll(", status ");
    if (host.status_answer == .stall) try out.writeAll("stall") else try out.print("{x:0>2} {x:0>2}", .{ host.status[0], host.status[1] });
    try out.print(", SET_INTERFACE {s}\n", .{@tagName(host.interface)});
    if (host.halt_set == .none) return;
    try out.print("USBFS host: ENDPOINT_HALT set {s}, clear {s}\n", .{
        @tagName(host.halt_set), @tagName(host.halt_clear),
    });
}

/// The bytes as the host received them; nothing when none came back.
fn descriptor(name: []const u8, bytes: []const u8, out: anytype) !void {
    if (bytes[0] == 0) return;
    try out.print("USBFS host: {s} descriptor", .{name});
    for (bytes) |byte| try out.print(" {x:0>2}", .{byte});
    try out.writeAll("\n");
}

/// A string descriptor as text: the UTF-16LE code units after its header,
/// with anything outside printable ASCII shown as '?'. Nothing when none came.
fn text(name: []const u8, bytes: []const u8, out: anytype) !void {
    const length = @min(bytes[0], bytes.len);
    if (length < 2) return;
    try out.print("USBFS host: {s} \"", .{name});
    var i: usize = 2;
    while (i + 1 < length) : (i += 2) {
        const unit = std.mem.readInt(u16, bytes[i..][0..2], .little);
        try out.writeByte(if (unit >= 0x20 and unit < 0x7F) @intCast(unit) else '?');
    }
    try out.writeAll("\"\n");
}
