//! Tests for src/interfaces/rpc/served_usbip.zig (row 24): a served session
//! that keeps a history puts the recorded port around the USB/IP bridge the
//! application put on the board, and gives the bridge back when it closes;
//! a session with no history leaves the bridge alone.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const run = ra8.usbip.exported.run;
const recorded = ra8.session.board.recorded_usbip;

const image = "tests/fixtures/dfu/dfu_bootloader.elf";

test "a session without a history leaves the bridge as it was" {
    const gpa = std.testing.allocator;
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, null);
    const usb = &served.owner.board().usb;
    try run.install(usb, gpa, std.testing.io, 0);
    const live: *run.Live = @ptrCast(@alignCast(usb.bridge.?.context));
    try served.attachUsbip();
    try std.testing.expect(recorded.from(usb) == null);
    try std.testing.expect(usb.bridge.?.context == @as(*anyopaque, live));
    served.deinit();
    live.link.deinit(gpa);
    gpa.destroy(live);
}

test "a served history wraps the bridge and releases it on close" {
    const gpa = std.testing.allocator;
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{});
    const usb = &served.owner.board().usb;
    try std.testing.expect(recorded.from(usb) == null);
    try served.attachUsbip();
    try std.testing.expect(usb.bridge == null);
    try run.install(usb, gpa, std.testing.io, 0);
    const live: *run.Live = @ptrCast(@alignCast(usb.bridge.?.context));
    try served.attachUsbip();
    const port = recorded.from(usb).?;
    try std.testing.expect(port.inner.context == @as(*anyopaque, live));
    // A second attach keeps the one port.
    try served.attachUsbip();
    try std.testing.expect(recorded.from(usb).? == port);
    served.deinit();
    live.link.deinit(gpa);
    gpa.destroy(live);
}
