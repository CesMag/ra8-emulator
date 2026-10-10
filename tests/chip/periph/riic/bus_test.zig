//! The RIIC device seam: who may sit on the bus, and who answers an address.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.periph.riic_bus;

/// A device that only records what it was given.
const Echo = struct {
    address: u7,
    last: u8 = 0,
    stops: u32 = 0,

    fn write(context: *anyopaque, byte: u8) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.last = byte;
    }

    fn read(context: *anyopaque, into: []u8) usize {
        const self: *Echo = @ptrCast(@alignCast(context));
        if (into.len == 0) return 0;
        into[0] = self.last;
        return 1;
    }

    fn stop(context: *anyopaque) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.stops += 1;
    }

    fn device(self: *Echo) bus.Device {
        return .{
            .address = self.address,
            .context = self,
            .writeFn = write,
            .readFn = read,
            .stopFn = stop,
        };
    }
};

test "an address byte carries the address and the direction" {
    try std.testing.expectEqual(@as(u8, 0x86), bus.wire.byte(0x43, false));
    try std.testing.expectEqual(@as(u8, 0x87), bus.wire.byte(0x43, true));
    try std.testing.expectEqual(@as(u7, 0x43), bus.wire.addressOf(0x87));
    try std.testing.expect(bus.wire.readingOf(0x87));
    try std.testing.expect(!bus.wire.readingOf(0x86));
}

test "the reserved ranges are reserved" {
    try std.testing.expect(bus.reserved.holds(0x00));
    try std.testing.expect(bus.reserved.holds(0x78));
    try std.testing.expect(bus.reserved.holds(0x7F));
    try std.testing.expect(!bus.reserved.holds(0x43));
    try std.testing.expect(!bus.reserved.holds(0x3C));
}

test "a device answers its own address and nothing else" {
    var echo = Echo{ .address = 0x43 };
    var registry = bus.Registry{};
    try registry.attach(echo.device());
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.find(0x43) != null);
    try std.testing.expect(registry.find(0x44) == null);
}

test "nothing may sit on a reserved address" {
    var echo = Echo{ .address = 0x00 };
    var registry = bus.Registry{};
    try std.testing.expectError(bus.Error.ReservedAddress, registry.attach(echo.device()));
    var high = Echo{ .address = 0x7A };
    try std.testing.expectError(bus.Error.ReservedAddress, registry.attach(high.device()));
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "two devices may not share an address" {
    var first = Echo{ .address = 0x43 };
    var second = Echo{ .address = 0x43 };
    var registry = bus.Registry{};
    try registry.attach(first.device());
    try std.testing.expectError(bus.Error.AddressTaken, registry.attach(second.device()));
}

test "the registry is bounded" {
    var registry = bus.Registry{};
    var devices: [bus.max_devices + 1]Echo = undefined;
    for (&devices, 0..) |*echo, i| echo.* = .{ .address = @intCast(0x10 + i) };
    for (devices[0..bus.max_devices]) |*echo| try registry.attach(echo.device());
    try std.testing.expectError(bus.Error.BusFull, registry.attach(devices[bus.max_devices].device()));
    try std.testing.expectEqual(bus.max_devices, registry.count());
}

test "the seam carries bytes both ways and ends a transfer" {
    var echo = Echo{ .address = 0x43 };
    var registry = bus.Registry{};
    try registry.attach(echo.device());
    const device = registry.find(0x43).?;
    device.write(0x5A);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), device.read(buffer[0..]));
    try std.testing.expectEqual(@as(u8, 0x5A), buffer[0]);
    device.stop();
    try std.testing.expectEqual(@as(u32, 1), echo.stops);
}
