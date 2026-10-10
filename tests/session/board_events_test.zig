//! Board event source wiring tests.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const api = ra8.session.session_api;
const sci = ra8.chip.periph.sci;

test "board UART GPIO LED and watchdog reset events use virtual time" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board_events.attach(&board, &session);
    const subscription = try session.subscribe();
    board.bus.issuer = .cpu1;
    board.serial.write(sci.win_base + 8 * sci.stride + sci.off_ccr0, 4, sci.ccr0.te);
    board.serial.write(sci.win_base + 8 * sci.stride + sci.off_tdr, 1, 'Q');
    board.pins.applyWrite(ra8.chip.periph.gpio.regAddress(6, ra8.chip.periph.gpio.pcntr1), 4, (@as(u32, 1) << 16) | 1);
    board.time.base.advance(12);
    const sink = board.event_sink.?;
    sink.observeFn(sink.context, board.bus.issuer, board.time.base.now(), ra8.session.board_events.current(&board));
    const watchdog_hook = board.watchdog.event_hook.?;
    watchdog_hook.underflowFn(watchdog_hook.context);
    board.requestResetFrom(.watchdog, .cpu1);
    var events: [8]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 5), got.count);
    try std.testing.expectEqual(api.Event.Kind.uart_byte, events[0].kind);
    try std.testing.expectEqual(@as(u8, 'Q'), events[0].payload.uart.byte);
    try std.testing.expectEqual(api.Event.Kind.gpio_changed, events[1].kind);
    try std.testing.expectEqual(api.Event.Kind.led_changed, events[2].kind);
    try std.testing.expectEqual(api.Event.Kind.watchdog, events[3].kind);
    try std.testing.expectEqual(api.Event.Kind.reset, events[4].kind);
    try std.testing.expectEqual(@as(u64, 12), events[3].virtual_ns);
    try std.testing.expectEqual(@as(u64, 12), events[4].virtual_ns);
    for (events[0..got.count]) |event| try std.testing.expectEqual(api.Core.cpu1, event.core);
}

test "GPIO baseline excludes unchanged pulled-up switch inputs" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board_events.attach(&board, &session);
    const subscription = try session.subscribe();
    board.pins.applyWrite(ra8.chip.periph.gpio.regAddress(0, ra8.chip.periph.gpio.pcntr1), 4, (@as(u32, 1) << 16) | 1);
    var events: [1]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 1), got.count);
    try std.testing.expectEqual(api.Event.Kind.gpio_changed, events[0].kind);
    try std.testing.expectEqual(@as(u16, 1), events[0].payload.gpio.changed);
}

test "external GPIO edges use the active core and one shared baseline" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board_events.attach(&board, &session);
    const subscription = try session.subscribe();
    const sink = board.event_sink.?;
    sink.observeFn(sink.context, .cpu1, board.time.base.now(), ra8.session.board_events.current(&board));

    board.pins.setInput(1, 2, true);
    board.bus.issuer = .cpu0;
    board.pins.applyWrite(ra8.chip.periph.gpio.regAddress(1, ra8.chip.periph.gpio.pcntr1), 4, 0);
    board.pins.setInput(1, 2, false);

    var events: [3]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 2), got.count);
    try std.testing.expectEqual(api.Event.Kind.gpio_changed, events[0].kind);
    try std.testing.expectEqual(api.Core.cpu1, events[0].core);
    try std.testing.expectEqual(@as(u16, 1 << 2), events[0].payload.gpio.changed);
    try std.testing.expectEqual(api.Core.cpu1, events[1].core);
    try std.testing.expectEqual(@as(u16, 0), events[1].payload.gpio.levels & (1 << 2));
}

test "a completed GLCDC frame publishes from its producer path" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board_events.attach(&board, &session);
    const subscription = try session.subscribe();
    board.bus.issuer = .cpu1;
    board.display.system.frames = 0;
    _ = board.display.frameLanded(.{ .hash = 1, .pixels = 1, .blank = 0, .colours = 1 });

    var events: [1]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 1), got.count);
    try std.testing.expectEqual(api.Event.Kind.lcd_frame, events[0].kind);
    try std.testing.expectEqual(api.Core.cpu0, events[0].core);
    try std.testing.expectEqual(@as(u64, 1), events[0].payload.frame.generation);
}

test "a watchdog refresh error publishes at the write that causes it" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board_events.attach(&board, &session);
    const subscription = try session.subscribe();
    board.bus.issuer = .cpu1;
    for (0..2) |_| {
        board.watchdog.write(ra8.chip.periph.wdt.win_base + ra8.chip.periph.wdt.off.wdtrr, 1, ra8.chip.periph.wdt.refresh.first);
        board.watchdog.write(ra8.chip.periph.wdt.win_base + ra8.chip.periph.wdt.off.wdtrr, 1, ra8.chip.periph.wdt.refresh.second);
    }

    var events: [1]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 1), got.count);
    try std.testing.expectEqual(api.Event.Kind.watchdog, events[0].kind);
    try std.testing.expectEqual(api.Core.cpu1, events[0].core);
    try std.testing.expectEqual(@as(u64, 0), events[0].virtual_ns);
}
