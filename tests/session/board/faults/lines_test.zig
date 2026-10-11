//! Covers src/session/board_faults/lines.zig through the session API: the
//! three line modes set and cleared mid-run on a modem on SCI3 and on a part
//! on SPI channel 0, plus the modes these lines refuse (RA8EMU-520).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.board.Board;
const plug = Board.plug;
const model = ra8.components.model;
const api = ra8.session.api;
const session_faults = ra8.session.board.faults;

const modem_at = "modem@uart:sci3";
const spi_at: model.endpoint.Endpoint = .{ .spi = .{ .channel = 0, .select = 0 } };

/// An SPI part that answers each byte with its complement.
const Echo = struct {
    var unused: u8 = 0;
    fn exchange(_: *anyopaque, byte: u8) u8 {
        return ~byte;
    }
    fn device() ra8.chip.periph.spi.Device {
        return .{ .context = &unused, .exchangeFn = exchange };
    }
};

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    faults: session_faults.Faults = undefined,
    session: api.Session = .{ .live = undefined },
    uart_at: model.endpoint.Endpoint = undefined,

    fn setUp(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.board = Board.init(std.testing.allocator);
        const ask = try model.request.parse(modem_at);
        const made = try model.parts.all.make(self.arena.allocator(), ask.name, ask.at);
        try plug.one(&self.board, made.device, ask.at);
        self.uart_at = ask.at;
        self.board.spi.attachDevice(0, Echo.device());
        self.faults = session_faults.Faults.init(&self.board, self.arena.allocator());
        self.session.attachFaults(&self.faults);
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn modem(self: *Rig) ra8.chip.periph.sci.device.Device {
        return self.board.serial.channels[3].device.?;
    }

    fn sayAt(self: *Rig) []const u8 {
        const device = self.modem();
        _ = device.feed('A');
        _ = device.feed('T');
        return device.feed('\r');
    }

    fn panel(self: *Rig) ra8.chip.periph.spi.Device {
        return self.board.spi.channels[0].device.?;
    }
};

test "a disconnected modem goes silent, and clearing brings its answer back" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    const own = try std.testing.allocator.dupe(u8, rig.sayAt());
    defer std.testing.allocator.free(own);
    try std.testing.expect(own.len > 0);
    try rig.session.setFault(.cpu0, rig.uart_at, .disconnected);
    try std.testing.expectEqual(@as(usize, 0), rig.sayAt().len);
    try rig.session.clearFault(.cpu0, rig.uart_at);
    try std.testing.expectEqualSlices(u8, own, rig.sayAt());
}

test "a stuck modem answers one byte throughout; garbage is seeded" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.session.setFault(.cpu0, rig.uart_at, .{ .stuck = 0xA5 });
    for (rig.sayAt()) |byte| try std.testing.expectEqual(@as(u8, 0xA5), byte);
    try rig.session.setFault(.cpu0, rig.uart_at, .{ .garbage = 9 });
    const first = try std.testing.allocator.dupe(u8, rig.sayAt());
    defer std.testing.allocator.free(first);
    try rig.session.setFault(.cpu0, rig.uart_at, .{ .garbage = 9 });
    try std.testing.expectEqualSlices(u8, first, rig.sayAt());
}

test "an SPI part floats when disconnected, reads stuck, then answers again" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try std.testing.expectEqual(@as(u8, 0xED), rig.panel().exchange(0x12));
    try rig.session.setFault(.cpu0, spi_at, .disconnected);
    try std.testing.expectEqual(@as(u8, 0xFF), rig.panel().exchange(0x12));
    try rig.session.setFault(.cpu0, spi_at, .{ .stuck = 0x5A });
    try std.testing.expectEqual(@as(u8, 0x5A), rig.panel().exchange(0x12));
    try rig.session.clearFault(.cpu0, spi_at);
    try std.testing.expectEqual(@as(u8, 0xED), rig.panel().exchange(0x12));
}

test "set and clear never stack wrappers on a line" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.session.setFault(.cpu0, spi_at, .disconnected);
    const wrapped = rig.panel().context;
    try rig.session.setFault(.cpu0, spi_at, .{ .stuck = 1 });
    try rig.session.clearFault(.cpu0, spi_at);
    try rig.session.setFault(.cpu0, spi_at, .{ .garbage = 3 });
    try std.testing.expectEqual(wrapped, rig.panel().context);
}

test "I2C-only modes and empty channels are refused on these lines" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    const refused = session_faults.Error.WrongMode;
    try std.testing.expectError(refused, rig.session.setFault(.cpu0, rig.uart_at, .{ .nack_every = 2 }));
    try std.testing.expectError(refused, rig.session.setFault(.cpu0, spi_at, .bus_low));
    const empty: model.endpoint.Endpoint = .{ .uart = .{ .channel = 5 } };
    try std.testing.expectError(session_faults.Error.NothingFitted, rig.session.setFault(.cpu0, empty, .disconnected));
    const free_spi: model.endpoint.Endpoint = .{ .spi = .{ .channel = 1, .select = 0 } };
    try std.testing.expectError(session_faults.Error.NothingFitted, rig.session.clearFault(.cpu0, free_spi));
}
