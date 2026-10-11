//! Covers the fitted table in src/session/board_plug.zig (RA8EMU-791): the
//! run's asks start it, a plug adds or replaces its endpoint, an unplug
//! drops it, and each listed line parses back with the `--attach` parser.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.board.Board;
const model = ra8.components.model;
const api = ra8.session.api;
const session_plug = ra8.session.board.plug;
const Endpoint = model.endpoint.Endpoint;
const request = model.request;

const gauge_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const modem_at: Endpoint = .{ .uart = .{ .channel = 3 } };

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    plugs: session_plug.Plugs = undefined,
    session: api.Session = undefined,

    fn setUp(self: *Rig, asks: []const request.Request) void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.board = Board.init(std.testing.allocator);
        self.board.asks.keep(self.arena.allocator(), asks);
        self.plugs = session_plug.Plugs.init(&self.board, self.arena.allocator());
        self.session = .{ .live = undefined };
        self.session.attachEventClock(.{ .context = self, .nowFn = zero });
        self.session.attachPlugs(self.plugs.hook());
    }

    fn zero(_: *anyopaque) u64 {
        return 0;
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn expectList(self: *Rig, expected: []const u8) !void {
        var out: [256]u8 = undefined;
        try std.testing.expectEqualStrings(expected, try self.plugs.list(&out));
    }
};

test "the listing follows plugs and unplugs in the order parts went on" {
    var rig: Rig = undefined;
    rig.setUp(&.{});
    defer rig.tearDown();
    try rig.expectList("");
    try rig.session.plug(.cpu0, gauge_at, "max17048");
    try rig.session.plug(.cpu0, modem_at, "modem");
    try rig.expectList("max17048@i2c:riic@0x36\nmodem@uart:sci3\n");
    try rig.session.unplug(.cpu0, gauge_at);
    try rig.expectList("modem@uart:sci3\n");
    try rig.session.plug(.cpu0, gauge_at, "max17048");
    try rig.expectList("modem@uart:sci3\nmax17048@i2c:riic@0x36\n");
}

test "the run's asks start the listing, and a plug on an ask's endpoint replaces it in place" {
    var rig: Rig = undefined;
    rig.setUp(&.{ .{ .name = "max17048", .at = gauge_at }, .{ .name = "modem", .at = modem_at } });
    defer rig.tearDown();
    try rig.expectList("max17048@i2c:riic@0x36\nmodem@uart:sci3\n");
    try rig.session.plug(.cpu0, gauge_at, "max17048");
    try rig.session.unplug(.cpu0, gauge_at);
    try rig.expectList("modem@uart:sci3\n");
}

test "each listed line parses back with the --attach parser" {
    var rig: Rig = undefined;
    rig.setUp(&.{});
    defer rig.tearDown();
    try rig.session.plug(.cpu0, gauge_at, "max17048");
    try rig.session.plug(.cpu0, modem_at, "modem");
    var out: [256]u8 = undefined;
    var lines = std.mem.tokenizeScalar(u8, try rig.plugs.list(&out), '\n');
    const first = try request.parse(lines.next().?);
    try std.testing.expectEqualStrings("max17048", first.name);
    try std.testing.expectEqual(gauge_at, first.at);
    const second = try request.parse(lines.next().?);
    try std.testing.expectEqual(modem_at, second.at);
    try std.testing.expect(lines.next() == null);
}

test "a buffer too small for the listing says so" {
    var rig: Rig = undefined;
    rig.setUp(&.{});
    defer rig.tearDown();
    try rig.session.plug(.cpu0, gauge_at, "max17048");
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, rig.plugs.list(&out));
}

test "an endpoint's text reads back as the same endpoint" {
    const all = [_]Endpoint{
        gauge_at,
        .{ .i2c = .{ .line = .touch, .address = 0x6B } },
        .{ .spi = .{ .channel = 1, .select = 0 } },
        modem_at,
        .{ .gpio = .{ .port = 0xB, .pin = 6 } },
    };
    for (all) |at| {
        var out: [32]u8 = undefined;
        var stream: std.Io.Writer = .fixed(&out);
        try at.write(&stream);
        try std.testing.expectEqual(at, try model.endpoint.parse(stream.buffered()));
    }
}
