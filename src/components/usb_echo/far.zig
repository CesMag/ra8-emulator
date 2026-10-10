//! The echo device as the far end of the HS host jack, through the chip's
//! contract in usbhs/far.zig. The board plugs it in when no cable is laid.
//!
//! The device answers at once: a refused SETUP is a stall the moment it lands,
//! a control read has its reply staged by then, and an IN token finds a packet
//! or a NAK.
const std = @import("std");
const Device = @import("device.zig").Device;
const setup = @import("ra8_chip").periph.usbhs_setup;
const usbhs_far = @import("ra8_chip").periph.usbhs_far;

pub fn far(device: *Device) usbhs_far.Far {
    return .{ .context = device, .vtable = &vtable };
}

const vtable: usbhs_far.Far.VTable = .{
    .setupFn = setupOf,
    .statusStageFn = statusStageOf,
    .answerFn = answerOf,
    .takeInFn = takeInOf,
    .bulkInFn = bulkInOf,
    .bulkOutFn = bulkOutOf,
    .busResetFn = busResetOf,
};

fn cast(context: *anyopaque) *Device {
    return @ptrCast(@alignCast(context));
}

fn setupOf(context: *anyopaque, packet: [8]u8) void {
    const device = cast(context);
    const field = std.mem.readInt;
    const request = setup.Packet.fromRegisters(
        field(u16, packet[0..2], .little),
        field(u16, packet[2..4], .little),
        field(u16, packet[4..6], .little),
        field(u16, packet[6..8], .little),
    );
    device.stalled = !device.handle(request);
}

/// The status stage needs nothing from a device that answered at once.
fn statusStageOf(context: *anyopaque) void {
    _ = context;
}

fn answerOf(context: *anyopaque) usbhs_far.Answer {
    return if (cast(context).stalled) .stall else .ack;
}

fn takeInOf(context: *anyopaque, into: []u8) ?u16 {
    const device = cast(context);
    if (!device.reply_ready) return null;
    return device.takeReply(into);
}

/// One bulk endpoint pair, so the endpoint number does not pick anything.
fn bulkInOf(context: *anyopaque, endpoint: u4, into: []u8) ?u16 {
    _ = endpoint;
    const device = cast(context);
    if (!device.bulkPending()) return null;
    return device.takeIn(into);
}

fn bulkOutOf(context: *anyopaque, endpoint: u4, bytes: []const u8) bool {
    _ = endpoint;
    return cast(context).bulkOut(bytes);
}

fn busResetOf(context: *anyopaque) void {
    const device = cast(context);
    device.busReset();
    device.stalled = false;
}
