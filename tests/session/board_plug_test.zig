//! Covers src/session/board_plug.zig through the session API: a gauge on
//! the RIIC line, a panel on SPI, a modem on SCI3 and buttons on GPIO pins
//! unplugged and plugged back mid-run, with each line behaving as a missing
//! part would while it is out (RA8EMU-212).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.board.Board;
const model = ra8.components.model;
const api = ra8.session.session_api;
const session_plug = ra8.session.board_plug;
const Endpoint = model.endpoint.Endpoint;

const gauge_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const panel_at: Endpoint = .{ .spi = .{ .channel = 1, .select = 0 } };
const modem_at: Endpoint = .{ .uart = .{ .channel = 3 } };

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    plugs: session_plug.Plugs = undefined,
    session: api.Session = .{ .live = undefined },
    subscription: usize = undefined,

    fn setUp(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.board = Board.init(std.testing.allocator);
        self.plugs = session_plug.Plugs.init(&self.board, self.arena.allocator());
        self.session.attachPlugs(self.plugs.hook());
        self.subscription = try self.session.subscribe();
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn gaugeAnswers(self: *Rig) bool {
        return self.board.wire.controller.devices.answering(0x36) != null;
    }

    fn panelLine(self: *Rig) ?ra8.chip.periph.spi.Device {
        return self.board.spi.channels[1].device;
    }

    fn modemLine(self: *Rig) ?ra8.chip.periph.sci_device.Device {
        return self.board.serial.channels[3].device;
    }
};

test "an unplugged gauge stops acknowledging, and comes back when plugged" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.session.plug(.cpu0, gauge_at, "max17048");
    try std.testing.expect(rig.gaugeAnswers());
    try rig.session.unplug(.cpu0, gauge_at);
    try std.testing.expect(!rig.gaugeAnswers());
    try rig.session.plug(.cpu0, gauge_at, "max17048");
    try std.testing.expect(rig.gaugeAnswers());
    var events: [3]api.Event = undefined;
    const got = rig.session.pollEvents(rig.subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 3), got.count);
    try std.testing.expectEqual(api.Event.Kind.plugged, events[0].kind);
    try std.testing.expectEqual(api.Event.Kind.unplugged, events[1].kind);
    try std.testing.expectEqual(api.Event.Kind.plugged, events[2].kind);
}

test "an unplugged panel leaves CIPO floating, and a new panel replaces it" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.session.plug(.cpu0, panel_at, "eink");
    const first = rig.panelLine().?.context;
    try rig.session.unplug(.cpu0, panel_at);
    const out = rig.panelLine().?;
    try std.testing.expect(session_plug.floating.holds(out));
    for (0..4) |_| try std.testing.expectEqual(@as(u8, 0xFF), out.exchange(0x12));
    try rig.session.plug(.cpu0, panel_at, "eink");
    const back = rig.panelLine().?;
    try std.testing.expect(!session_plug.floating.holds(back));
    try std.testing.expect(back.context != first);
}

test "an unplugged modem leaves the line silent until it is plugged again" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.session.plug(.cpu0, modem_at, "modem");
    try std.testing.expect(rig.modemLine() != null);
    try rig.session.unplug(.cpu0, modem_at);
    try std.testing.expect(rig.modemLine() == null);
    try rig.session.plug(.cpu0, modem_at, "modem");
    try std.testing.expect(rig.modemLine() != null);
}

test "an unplugged button lets its pin fall back to its pull state" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    const plain: Endpoint = .{ .gpio = .{ .port = 1, .pin = 6 } };
    try rig.session.plug(.cpu0, plain, "button");
    try std.testing.expect(rig.board.pins.pinLevel(1, 6));
    try rig.session.unplug(.cpu0, plain);
    try std.testing.expect(!rig.board.pins.pinLevel(1, 6));
    try std.testing.expectEqual(@as(usize, 0), rig.board.pins.wired.count);
    const sw1 = ra8.board.switches.user[0];
    const switch_pin: Endpoint = .{ .gpio = .{ .port = sw1.port, .pin = sw1.pin } };
    try rig.session.plug(.cpu0, switch_pin, "button");
    try rig.session.unplug(.cpu0, switch_pin);
    try std.testing.expect(rig.board.pins.pinLevel(sw1.port, sw1.pin));
    try rig.session.plug(.cpu0, plain, "button");
    try std.testing.expect(rig.board.pins.pinLevel(1, 6));
    try std.testing.expectEqual(@as(usize, 1), rig.board.pins.wired.count);
}

test "empty endpoints, taken endpoints, unknown parts and GPIO are refused" {
    var bare: api.Session = .{ .live = undefined };
    try std.testing.expectError(api.Error.NoPlugs, bare.unplug(.cpu0, gauge_at));
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    const empty = session_plug.Error.NothingFitted;
    try std.testing.expectError(empty, rig.session.unplug(.cpu0, gauge_at));
    try std.testing.expectError(empty, rig.session.unplug(.cpu0, panel_at));
    try std.testing.expectError(empty, rig.session.unplug(.cpu0, modem_at));
    try rig.session.plug(.cpu0, panel_at, "eink");
    try rig.session.unplug(.cpu0, panel_at);
    try std.testing.expectError(empty, rig.session.unplug(.cpu0, panel_at));
    try rig.session.plug(.cpu0, modem_at, "modem");
    try std.testing.expectError(error.ChannelTaken, rig.session.plug(.cpu0, modem_at, "modem"));
    try std.testing.expectError(error.UnknownModel, rig.session.plug(.cpu0, gauge_at, "nope"));
    const pin: Endpoint = .{ .gpio = .{ .port = 1, .pin = 6 } };
    try std.testing.expectError(empty, rig.session.unplug(.cpu0, pin));
    try std.testing.expectError(error.WrongEndpoint, rig.session.plug(.cpu0, gauge_at, "led"));
    var events: [3]api.Event = undefined;
    try std.testing.expectEqual(@as(usize, 3), rig.session.pollEvents(rig.subscription, &events).?.count);
}
