//! Covers src/components/catalog.zig: finding a model by name, refusing a
//! wrong endpoint, and making and destroying independent instances.
const std = @import("std");
const ra8 = @import("ra8");
const model = ra8.components.model;
const catalog = model.catalog;
const endpoint = model.endpoint;
const riic_bus = ra8.chip.periph.riic.bus;

/// A one-register I2C part: a write stores the byte, a read returns it.
const Latch = struct {
    value: u8 = 0,

    fn write(context: *anyopaque, byte: u8) void {
        const self: *Latch = @ptrCast(@alignCast(context));
        self.value = byte;
    }

    fn read(context: *anyopaque, into: []u8) usize {
        const self: *Latch = @ptrCast(@alignCast(context));
        if (into.len == 0) return 0;
        into[0] = self.value;
        return 1;
    }

    fn stop(_: *anyopaque) void {}

    fn create(allocator: std.mem.Allocator) catalog.Error!*anyopaque {
        const self = try allocator.create(Latch);
        self.* = .{};
        return self;
    }

    fn bind(state: *anyopaque, at: endpoint.Endpoint) catalog.Device {
        const device: riic_bus.Device = .{
            .address = at.i2c.address,
            .context = state,
            .writeFn = write,
            .readFn = read,
            .stopFn = stop,
        };
        return .{ .i2c = device };
    }

    fn destroy(allocator: std.mem.Allocator, state: *anyopaque) void {
        allocator.destroy(@as(*Latch, @ptrCast(@alignCast(state))));
    }
};

const models = [_]catalog.Model{
    .{ .name = "latch", .kind = .i2c, .createFn = Latch.create, .destroyFn = Latch.destroy, .bindFn = Latch.bind },
};
const parts: catalog.Catalog = .{ .models = &models };

test "a model is found by its name and nothing else" {
    try std.testing.expect(parts.find("latch") != null);
    try std.testing.expect(parts.find("latc") == null);
    try std.testing.expect(parts.find("") == null);
}

test "an unknown name or a wrong-kind endpoint makes nothing" {
    const allocator = std.testing.allocator;
    const uart = try endpoint.parse("uart:sci3");
    const i2c = try endpoint.parse("i2c:touch@0x37");
    try std.testing.expectError(error.WrongEndpoint, parts.make(allocator, "latch", uart));
    try std.testing.expectError(error.UnknownModel, parts.make(allocator, "gauge", i2c));
}

test "two instances of one model keep their own state and address" {
    const allocator = std.testing.allocator;
    const first = try parts.make(allocator, "latch", try endpoint.parse("i2c:touch@0x36"));
    defer catalog.Catalog.destroy(allocator, first);
    const second = try parts.make(allocator, "latch", try endpoint.parse("i2c:touch@0x37"));
    defer catalog.Catalog.destroy(allocator, second);

    try std.testing.expectEqual(@as(u7, 0x36), first.device.i2c.address);
    try std.testing.expectEqual(@as(u7, 0x37), second.device.i2c.address);
    first.device.i2c.write(0xA5);
    second.device.i2c.write(0x5A);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), first.device.i2c.read(&byte));
    try std.testing.expectEqual(@as(u8, 0xA5), byte[0]);
    _ = second.device.i2c.read(&byte);
    try std.testing.expectEqual(@as(u8, 0x5A), byte[0]);
}

test "an instance attaches to the RIIC registry like any compiled-in part" {
    const allocator = std.testing.allocator;
    const made = try parts.make(allocator, "latch", try endpoint.parse("i2c:riic@0x50"));
    defer catalog.Catalog.destroy(allocator, made);
    var registry: riic_bus.Registry = .{};
    try registry.attach(made.device.i2c);
    try std.testing.expect(registry.find(0x50) != null);
}

test "binding puts a model on state the caller holds" {
    var held: Latch = .{};
    const at = try endpoint.parse("i2c:riic@0x51");
    const device = try parts.bind("latch", &held, at);
    device.i2c.write(0x3C);
    try std.testing.expectEqual(@as(u8, 0x3C), held.value);
    try std.testing.expectEqual(@as(u7, 0x51), device.i2c.address);
    try std.testing.expectError(error.WrongEndpoint, parts.bind("latch", &held, try endpoint.parse("uart:sci0")));
    try std.testing.expectError(error.UnknownModel, parts.bind("gauge", &held, at));
}
