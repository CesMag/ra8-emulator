//! The SETUP packet: what the four staging registers mean once they are read
//! as one request.
const std = @import("std");
const ra8 = @import("ra8");
const setup = ra8.chip.periph.usbhs.setup;

test "the packet comes out of the four staging registers" {
    // GET_DESCRIPTOR(device), 18 bytes.
    const packet = setup.Packet.fromRegisters(0x0680, 0x0100, 0x0000, 18);
    try std.testing.expectEqual(@as(u8, 0x80), packet.request_type);
    try std.testing.expectEqual(setup.request.get_descriptor, packet.code);
    try std.testing.expectEqual(@as(u16, 0x0100), packet.value);
    try std.testing.expectEqual(@as(u16, 18), packet.length);
}

test "a control read runs device to host and owes bytes" {
    const read = setup.Packet.fromRegisters(0x0680, 0x0100, 0, 18);
    try std.testing.expect(read.deviceToHost());
    try std.testing.expect(read.controlRead());
}

test "a device-to-host request with no data stage is not a control read" {
    const empty = setup.Packet.fromRegisters(0x0680, 0x0100, 0, 0);
    try std.testing.expect(empty.deviceToHost());
    try std.testing.expect(!empty.controlRead());
}

test "a host-to-device request is never a control read" {
    // SET_ADDRESS 5.
    const write = setup.Packet.fromRegisters(0x0500, 0x0005, 0, 0);
    try std.testing.expect(!write.deviceToHost());
    try std.testing.expect(!write.controlRead());
    try std.testing.expectEqual(@as(u8, 5), write.requestedAddress());
}

test "wValue's high byte names the descriptor" {
    const config = setup.Packet.fromRegisters(0x0680, 0x0200, 0, 9);
    try std.testing.expectEqual(setup.descriptor.configuration, config.descriptorType());
}
