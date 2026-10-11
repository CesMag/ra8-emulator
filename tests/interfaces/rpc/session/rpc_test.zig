const std = @import("std");
const ra8 = @import("ra8");
const protocol = ra8.rpc.session.rpc;

fn roundTrip(comptime T: type, value: T) !void {
    var bytes: [protocol.max_payload]u8 = undefined;
    const encoded = try protocol.encode(T, value, &bytes);
    const decoded = try protocol.decode(T, encoded);
    try std.testing.expectEqualDeep(value, decoded);
}

test "every request, result, and event message round-trips" {
    try roundTrip(protocol.Load, .{ .core = .cpu0, .image = "elf" });
    try roundTrip(protocol.Run, .{ .core = .cpu0, .mode = .next, .budget = 123 });
    try roundTrip(protocol.CoreOnly, .{ .core = .cpu1 });
    try roundTrip(protocol.SetSpeed, .{ .core = .cpu0, .milli = 2500 });
    try roundTrip(protocol.ReadRegister, .{ .core = .cpu0, .register = .pc });
    try roundTrip(protocol.WriteRegister, .{ .core = .cpu1, .register = .r3, .value = 77 });
    try roundTrip(protocol.ReadMemory, .{ .core = .cpu0, .address = 0x1000, .length = 16 });
    try roundTrip(protocol.Memory, .{ .bytes = "memory" });
    try roundTrip(protocol.WriteMemory, .{ .core = .cpu0, .address = 0x1000, .bytes = "data" });
    try roundTrip(protocol.Point, .{ .core = .cpu0, .address = 0x2000 });
    try roundTrip(protocol.Watch, .{ .core = .cpu1, .first = 1, .last = 8, .access = .write });
    try roundTrip(protocol.Subscription, .{ .core = .cpu1, .topic = .lcd_dirty });
    try roundTrip(protocol.Now, .{ .core = .cpu0 });
    try roundTrip(protocol.RunBudget, .{ .core = .cpu1, .instructions = 100 });
    try roundTrip(protocol.PointId, .{ .core = .cpu0, .id = 12 });
    try roundTrip(protocol.U64, .{ .value = 123456 });
    try roundTrip(protocol.U32, .{ .value = 456 });
    try roundTrip(protocol.Bool, .{ .value = 1 });
    try roundTrip(protocol.Ack, .{ .accepted = 1 });
    try roundTrip(protocol.Stopped, .{ .core = .cpu0, .reason = .breakpoint, .address = 0x1234, .detail = 7 });
    try roundTrip(protocol.Uart, .{ .core = .cpu1, .channel = 2, .virtual_ns = 5, .bytes = "uart" });
    try roundTrip(protocol.DirtyRect, .{ .core = .cpu0, .x = 1, .y = 2, .width = 2, .height = 2, .virtual_ns = 9, .pixels = "gray" });
    try roundTrip(protocol.SessionEvent, .{ .core = .cpu1, .kind = .loaded, .address = 0x1000 });
    try roundTrip(protocol.Trace, .{ .core = .cpu1, .bytes = "trace" });
}

const fuzzed = .{
    protocol.Load,         protocol.Run,           protocol.CoreOnly,     protocol.SetSpeed,
    protocol.ReadRegister, protocol.WriteRegister, protocol.ReadMemory,   protocol.Memory,
    protocol.WriteMemory,  protocol.Point,         protocol.Watch,        protocol.Subscription,
    protocol.Now,          protocol.RunBudget,     protocol.PointId,      protocol.U64,
    protocol.U32,          protocol.Bool,          protocol.Ack,          protocol.Stopped,
    protocol.Uart,         protocol.DirtyRect,     protocol.SessionEvent, protocol.Trace,
};

test "random bytes decode to an error or a value for every message, never a crash" {
    var prng = std.Random.DefaultPrng.init(0x194);
    const random = prng.random();
    var bytes: [48]u8 = undefined;
    for (0..4000) |_| {
        const len = random.uintLessThan(usize, bytes.len + 1);
        random.bytes(bytes[0..len]);
        inline for (fuzzed) |T| {
            if (protocol.decode(T, bytes[0..len])) |_| {} else |_| {}
        }
    }
}

test "every strict prefix of a valid frame body is rejected" {
    var bytes: [protocol.max_payload]u8 = undefined;
    const value: protocol.DirtyRect = .{ .core = .cpu1, .x = 3, .y = 4, .width = 2, .height = 1, .virtual_ns = 77, .pixels = "ab" };
    const encoded = try protocol.encode(protocol.DirtyRect, value, &bytes);
    for (0..encoded.len) |cut| {
        try std.testing.expect(std.meta.isError(protocol.decode(protocol.DirtyRect, encoded[0..cut])));
    }
}
