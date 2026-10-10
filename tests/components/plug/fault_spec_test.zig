//! Covers src/components/fault_spec.zig: the `--fault` grammar, the fit
//! rules, and wrapping a made device in its fault.
const std = @import("std");
const ra8 = @import("ra8");
const model = ra8.components.model;
const spec = model.fault_spec;
const endpoint = model.endpoint;
const parts = model.parts;
const TimeBase = ra8.chip.periph.clocks.timebase.TimeBase;

test "a fault splits at the last '=' and keeps the endpoint whole" {
    const ask = try spec.parse("max17048@i2c:riic@0x37=nack:3");
    try std.testing.expectEqualStrings("max17048", ask.target.name);
    try std.testing.expectEqual(@as(u32, 3), ask.mode.nack_every);
    const line = try spec.parse("modem@uart:sci3=stuck:0xA5");
    try std.testing.expectEqual(@as(u8, 0xA5), line.mode.stuck);
}

test "every mode parses, with its argument where it has one" {
    try std.testing.expect(try spec.parseMode("disconnected") == .disconnected);
    try std.testing.expect(try spec.parseMode("bus_low") == .bus_low);
    try std.testing.expectEqual(@as(u32, 7), (try spec.parseMode("garbage:7")).garbage);
    try std.testing.expectEqual(@as(u64, 5000), (try spec.parseMode("slow:5000")).slow_ns);
}

test "a bad fault is refused, and says why" {
    try std.testing.expectError(spec.Error.NoMode, spec.parse("max17048@i2c:riic@0x37"));
    try std.testing.expectError(spec.Error.NoMode, spec.parse("max17048@i2c:riic@0x37="));
    try std.testing.expectError(spec.Error.UnknownMode, spec.parseMode("melt"));
    try std.testing.expectError(spec.Error.BadArgument, spec.parseMode("nack:0"));
    try std.testing.expectError(spec.Error.BadArgument, spec.parseMode("stuck:0x100"));
    try std.testing.expectError(spec.Error.BadArgument, spec.parseMode("slow"));
    try std.testing.expectError(spec.Error.BadArgument, spec.parseMode("disconnected:1"));
    try std.testing.expectError(spec.Error.UnknownModel, spec.parse("nope@i2c:riic@0x37=disconnected"));
}

test "a disconnected I2C model stops acknowledging once applied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var clock = TimeBase{};
    const made = try parts.all.make(arena.allocator(), "max17048", try endpoint.parse("i2c:riic@0x37"));
    try std.testing.expect(made.device.i2c.acks());
    const faulty = try spec.apply(arena.allocator(), made.device, .disconnected, &clock);
    try std.testing.expect(!faulty.i2c.acks());
}

test "a mode that does not fit the bus is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var clock = TimeBase{};
    const modem = try parts.all.make(arena.allocator(), "modem", try endpoint.parse("uart:sci3"));
    try std.testing.expectError(spec.Error.WrongBus, spec.apply(arena.allocator(), modem.device, .{ .nack_every = 2 }, &clock));
    try std.testing.expectError(spec.Error.WrongBus, spec.apply(arena.allocator(), modem.device, .bus_low, &clock));
    const button = try parts.all.make(arena.allocator(), "button", try endpoint.parse("gpio:P006"));
    try std.testing.expectError(spec.Error.WrongBus, spec.apply(arena.allocator(), button.device, .disconnected, &clock));
}

test "a stuck UART model answers with the stuck byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var clock = TimeBase{};
    const made = try parts.all.make(arena.allocator(), "modem", try endpoint.parse("uart:sci3"));
    const faulty = try spec.apply(arena.allocator(), made.device, .{ .stuck = '#' }, &clock);
    _ = faulty.uart.feed('A');
    _ = faulty.uart.feed('T');
    try std.testing.expectEqualStrings("######", faulty.uart.feed('\r'));
}

test "bus_low leaves an I2C part as it was, for the caller to hold the bus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var clock = TimeBase{};
    const made = try parts.all.make(arena.allocator(), "max17048", try endpoint.parse("i2c:riic@0x37"));
    const same = try spec.apply(arena.allocator(), made.device, .bus_low, &clock);
    try std.testing.expectEqual(made.device.i2c.context, same.i2c.context);
}

test "a fault lands on the --attach ask that names the same part" {
    var asks = [_]model.request.Request{
        try model.request.parse("max17048@i2c:riic@0x37"),
        try model.request.parse("modem@uart:sci3"),
    };
    try spec.place(&asks, try spec.parse("modem@uart:sci3=garbage:9"));
    try std.testing.expect(asks[0].fault == null);
    try std.testing.expectEqual(@as(u32, 9), asks[1].fault.?.garbage);
}

test "a fault with no matching --attach is refused" {
    var asks = [_]model.request.Request{try model.request.parse("max17048@i2c:riic@0x37")};
    try std.testing.expectError(spec.Error.NoSuchAttach, spec.place(&asks, try spec.parse("max17048@i2c:riic@0x36=disconnected")));
    try std.testing.expectError(spec.Error.NoSuchAttach, spec.place(asks[0..0], try spec.parse("max17048@i2c:riic@0x37=disconnected")));
}

test "stretch parses and wraps an I2C part that stretches" {
    try std.testing.expectEqual(@as(u64, 900), (try spec.parseMode("stretch:900")).stretch_ns);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var clock = TimeBase{};
    const made = try parts.all.make(arena.allocator(), "max17048", try endpoint.parse("i2c:riic@0x37"));
    const faulty = try spec.apply(arena.allocator(), made.device, .{ .stretch_ns = 900 }, &clock);
    try std.testing.expectEqual(@as(u64, 900), faulty.i2c.stretch());
}

test "a fault with no model name targets the part fitted at that I2C endpoint" {
    const ask = try spec.parse("@i2c:touch@0x5D=disconnected");
    try std.testing.expectEqualStrings("", ask.target.name);
    try std.testing.expectEqual(@as(u7, 0x5D), ask.target.at.i2c.address);
    try std.testing.expect(ask.target.at.i2c.line == .touch);
    try std.testing.expect(ask.mode == .disconnected);
    try std.testing.expectError(spec.Error.WrongBus, spec.parse("@uart:sci3=disconnected"));
}
