//! Tests for src/session/panel_watch.zig (RA8EMU-1126): a watched GLCDC
//! panel is scanned at its frame boundary and reports its first picture
//! whole, a picture that holds still says nothing, a changed one reports
//! what changed, the session's frame comes from the kept picture without
//! another scan, and the boundary comes off with the last viewer.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("../interfaces/cli/store_board.zig");

const api = ra8.session.session_api;
const Board = ra8.board.board.Board;
const Host = ra8.session.board_display.Host;
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc_tcon;
const glcdc_sys = ra8.chip.periph.glcdc_sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const period_ns = ra8.chip.periph.glcdc_out.vsync.default_period_ns;

const Idle = struct {
    fn advance(_: *anyopaque, _: u64) anyerror!void {}
};

/// A board whose GLCDC shows a 2 by 1 panel of its background colour, with
/// a session listening to its events and a display host on it.
const Bench = struct {
    store: store_board.Store,
    board: Board,
    session: api.Session,
    host: Host,
    events: usize,
    idle: Idle,

    fn open(self: *Bench) !void {
        self.store = try store_board.Store.init(null);
        self.board = Board.init(std.testing.allocator);
        try store_board.attach(&self.board, .{ .store = &self.store });
        const board = &self.board;
        board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
        board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
        board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
        board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
        board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
        board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
        self.paint(0xFF11_2233);
        self.session = .{ .live = undefined };
        ra8.session.board_events.attach(board, &self.session);
        self.events = try self.session.subscribe();
        self.idle = .{};
        self.host = Host.init(std.testing.allocator, board, .{ .context = &self.idle, .advanceFn = Idle.advance });
        self.host.watch.events = &self.session.event_sources;
        self.session.attachDisplay(self.host.interface());
    }

    fn deinit(self: *Bench) void {
        self.host.deinit();
        self.board.deinit();
        self.store.deinit();
    }

    /// Set the colour the whole panel shows.
    fn paint(self: *Bench, argb: u32) void {
        self.board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, argb);
    }

    /// Let board time pass and hand it to the panel's frame boundary, as the
    /// board does after each chunk.
    fn pass(self: *Bench, ns: u64) void {
        self.board.time.base.advance(ns);
        if (self.board.display.output.vsync) |*frame| frame.tick(self.board.time.base.now());
    }

    /// The panel events published since the last call.
    fn frames(self: *Bench, out: []api.Event) []api.Event {
        var all: [16]api.Event = undefined;
        const got = self.session.pollEvents(self.events, &all).?;
        var count: usize = 0;
        for (all[0..got.count]) |event| if (event.kind == .lcd_frame) {
            out[count] = event;
            count += 1;
        };
        return out[0..count];
    }
};

test "a watched panel is scanned at its frame boundary and reports its first picture whole" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    var seen: [4]api.Event = undefined;
    bench.pass(period_ns);
    try std.testing.expectEqual(@as(u32, 0), bench.board.display.system.frames);

    bench.session.display.?.watch(true);
    try std.testing.expect(bench.board.display.output.vsync != null);
    bench.pass(1);
    try std.testing.expectEqual(@as(u32, 1), bench.board.display.system.frames);
    const first = bench.frames(&seen);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(api.Event.Rect{ .x = 0, .y = 0, .width = 2, .height = 1 }, first[0].payload.frame.dirty);
    try std.testing.expectEqual(@as(u32, 2), first[0].payload.frame.width);
    try std.testing.expectEqual(bench.board.time.base.now(), first[0].virtual_ns);
}

test "a picture that holds still is scanned and says nothing; a changed one reports itself" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    var seen: [4]api.Event = undefined;
    bench.session.display.?.watch(true);
    bench.pass(1);
    _ = bench.frames(&seen);

    bench.pass(period_ns);
    bench.pass(period_ns);
    try std.testing.expectEqual(@as(u32, 3), bench.board.display.system.frames);
    try std.testing.expectEqual(@as(usize, 0), bench.frames(&seen).len);
    // Short of a frame period nothing is scanned at all.
    bench.pass(period_ns / 2);
    try std.testing.expectEqual(@as(u32, 3), bench.board.display.system.frames);

    bench.paint(0xFF44_5566);
    bench.pass(period_ns);
    const changed = bench.frames(&seen);
    try std.testing.expectEqual(@as(usize, 1), changed.len);
    try std.testing.expectEqual(api.Event.Rect{ .x = 0, .y = 0, .width = 2, .height = 1 }, changed[0].payload.frame.dirty);
}

test "the session's frame is the kept picture, with no scan of its own while a viewer watches" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    var seen: [4]api.Event = undefined;
    const gpa = std.testing.allocator;
    bench.session.display.?.watch(true);
    bench.pass(1);
    const scanned_at = bench.board.time.base.now();
    bench.pass(period_ns / 2);
    _ = bench.frames(&seen);

    var frame = try bench.session.frame(gpa);
    defer frame.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), frame.width);
    try std.testing.expectEqual(@as(u32, 1), frame.height);
    const gray = ra8.session.session_display.grayscale(0xFF11_2233);
    try std.testing.expectEqualSlices(u8, &.{ gray, gray }, frame.pixels);
    try std.testing.expectEqual(scanned_at, frame.virtual_ns);
    try std.testing.expectEqual(@as(u32, 1), bench.board.display.system.frames);
    try std.testing.expectEqual(@as(usize, 0), bench.frames(&seen).len);
}

test "the frame boundary comes off with the last viewer, and a frame is scanned on demand again" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    const gpa = std.testing.allocator;
    const display = bench.session.display.?;
    display.watch(true);
    display.watch(true);
    bench.pass(1);
    display.watch(false);
    try std.testing.expect(bench.board.display.output.vsync != null);
    display.watch(false);
    try std.testing.expect(bench.board.display.output.vsync == null);
    display.watch(false);
    try std.testing.expectEqual(@as(u32, 0), bench.host.watch.viewers);

    bench.pass(4 * period_ns);
    try std.testing.expectEqual(@as(u32, 1), bench.board.display.system.frames);
    var frame = try bench.session.frame(gpa);
    defer frame.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), bench.board.display.system.frames);
}

fn otherSink(_: *anyopaque, _: u64) void {}

test "a frame boundary another viewer armed is left as it is" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    bench.board.display.output.vsync = .{ .sink = .{ .context = &bench, .frame = otherSink } };
    const display = bench.session.display.?;
    display.watch(true);
    try std.testing.expect(bench.board.display.output.vsync.?.sink.frame == otherSink);
    display.watch(false);
    try std.testing.expect(bench.board.display.output.vsync.?.sink.frame == otherSink);
}

test "a panel with no size is not scanned" {
    var store = try store_board.Store.init(null);
    defer store.deinit();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, .{ .store = &store });
    var idle: Idle = .{};
    var host = Host.init(std.testing.allocator, &board, .{ .context = &idle, .advanceFn = Idle.advance });
    defer host.deinit();
    host.watch.set(true);
    board.time.base.advance(period_ns);
    if (board.display.output.vsync) |*frame| frame.tick(board.time.base.now());
    try std.testing.expectEqual(@as(u32, 0), board.display.system.frames);
    try std.testing.expectEqual(@as(u32, 0), host.watch.width);
}
