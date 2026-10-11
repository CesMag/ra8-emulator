//! Covers src/session/board_faults/board_faults.zig through the session API: each fault
//! mode set and cleared mid-run on a part plugged on the RIIC line, with the
//! part's behaviour on the line following (RA8EMU-520).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.board.Board;
const plug = Board.plug;
const model = ra8.components.model;
const api = ra8.session.api;
const session_faults = ra8.session.board.faults;

const spec = "max17048@i2c:riic@0x37";

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    faults: session_faults.Faults = undefined,
    session: api.Session = .{ .live = undefined },
    at: model.endpoint.Endpoint = undefined,
    subscription: usize = undefined,

    fn setUp(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.board = Board.init(std.testing.allocator);
        const ask = try model.request.parse(spec);
        const made = try model.parts.all.make(self.arena.allocator(), ask.name, ask.at);
        try plug.one(&self.board, made.device, ask.at);
        self.at = ask.at;
        self.faults = session_faults.Faults.init(&self.board, self.arena.allocator());
        self.session.attachFaults(&self.faults);
        self.subscription = try self.session.subscribe();
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn registry(self: *Rig) *ra8.chip.periph.riic.bus.Registry {
        return &self.board.wire.controller.devices;
    }

    fn part(self: *Rig) ra8.chip.periph.riic.bus.Device {
        return self.registry().find(0x37).?.*;
    }

    fn readByte(self: *Rig) u8 {
        const device = self.part();
        device.write(0x08); // VERSION register
        var into = [_]u8{0};
        _ = device.read(&into);
        device.stop();
        return into[0];
    }

    fn set(self: *Rig, mode: api.FaultMode) !void {
        try self.session.setFault(.cpu0, self.at, mode);
    }

    fn clear(self: *Rig) !void {
        try self.session.clearFault(.cpu0, self.at);
    }
};

test "disconnected refuses the address phase, and clearing brings it back" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try std.testing.expect(rig.part().acks());
    try rig.set(.disconnected);
    try std.testing.expect(!rig.part().acks());
    try rig.clear();
    try std.testing.expect(rig.part().acks());
    var events: [2]api.Event = undefined;
    const got = rig.session.pollEvents(rig.subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 2), got.count);
    try std.testing.expectEqual(api.Event.Kind.fault_set, events[0].kind);
    try std.testing.expectEqual(api.Event.Kind.fault_cleared, events[1].kind);
}

test "stuck and garbage rewrite reads; clearing restores the part's own byte" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    const own = rig.readByte();
    try rig.set(.{ .stuck = 0xA5 });
    try std.testing.expectEqual(@as(u8, 0xA5), rig.readByte());
    try rig.set(.{ .garbage = 7 });
    const first = rig.readByte();
    try rig.set(.{ .garbage = 7 });
    try std.testing.expectEqual(first, rig.readByte()); // seeded: repeats
    try rig.clear();
    try std.testing.expectEqual(own, rig.readByte());
}

test "nack every second phase, then cleared" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.set(.{ .nack_every = 2 });
    var refused: u32 = 0;
    for (0..4) |_| {
        if (!rig.part().acks()) refused += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), refused);
    try rig.clear();
    for (0..4) |_| try std.testing.expect(rig.part().acks());
}

test "slow is busy after a write until virtual time passes" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.set(.{ .slow_ns = 1000 });
    const device = rig.part();
    _ = device.acks();
    device.write(0x06);
    device.write(0x00);
    device.stop();
    try std.testing.expect(!rig.part().acks());
    try rig.clear();
    try std.testing.expect(rig.part().acks());
}

test "stretch holds the clock, and clearing ends it" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.set(.{ .stretch_ns = 500 });
    try std.testing.expectEqual(@as(u64, 500), rig.part().stretch());
    try rig.clear();
    try std.testing.expectEqual(@as(u64, 0), rig.part().stretch());
}

test "bus_low holds the line; clearing releases it; set/clear never stacks wrappers" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.set(.bus_low);
    try std.testing.expect(rig.registry().held_low);
    try rig.clear();
    try std.testing.expect(!rig.registry().held_low);
    try rig.set(.disconnected);
    const wrapped = rig.part().context;
    try rig.set(.{ .stuck = 1 });
    try rig.clear();
    try std.testing.expectEqual(wrapped, rig.part().context);
}

test "no hook, a GPIO endpoint and an empty address are refused" {
    var bare: api.Session = .{ .live = undefined };
    const at = (try model.request.parse(spec)).at;
    try std.testing.expectError(api.Error.NoFaults, bare.setFault(.cpu0, at, .disconnected));
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    const pin: model.endpoint.Endpoint = .{ .gpio = .{ .port = 0, .pin = 0 } };
    try std.testing.expectError(session_faults.Error.WrongEndpoint, rig.session.setFault(.cpu0, pin, .disconnected));
    const empty = (try model.request.parse("max17048@i2c:riic@0x50")).at;
    try std.testing.expectError(session_faults.Error.NothingFitted, rig.session.setFault(.cpu0, empty, .disconnected));
}
