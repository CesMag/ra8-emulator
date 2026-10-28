//! Board event source wiring tests.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const api = ra8.session.api;
const sci = ra8.chip.periph.sci;

test "board UART GPIO LED and watchdog reset events use virtual time" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board.events.attach(&board, &session);
    const subscription = try session.subscribe();
    board.bus.issuer = .cpu1;
    board.serial.write(sci.win_base + 8 * sci.stride + sci.off_ccr0, 4, sci.ccr0.te);
    board.serial.write(sci.win_base + 8 * sci.stride + sci.off_tdr, 1, 'Q');
    board.pins.applyWrite(ra8.chip.periph.gpio.regAddress(6, ra8.chip.periph.gpio.pcntr1), 4, (@as(u32, 1) << 16) | 1);
    board.time.base.advance(12);
    const sink = board.event_sink.?;
    sink.observeFn(sink.context, board.bus.issuer, board.time.base.now(), ra8.session.board.events.current(&board));
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
    ra8.session.board.events.attach(&board, &session);
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
    ra8.session.board.events.attach(&board, &session);
    const subscription = try session.subscribe();
    const sink = board.event_sink.?;
    sink.observeFn(sink.context, .cpu1, board.time.base.now(), ra8.session.board.events.current(&board));

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
    ra8.session.board.events.attach(&board, &session);
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
    ra8.session.board.events.attach(&board, &session);
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

test "an LED follows its output latch, so a pin made an output through PmnPFS still reports it" {
    const gpio = ra8.chip.periph.gpio;
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board.events.attach(&board, &session);
    const subscription = try session.subscribe();
    // PCNTR3 sets then clears P600's latch. The port's direction bit stays
    // clear, as it does for firmware that configures the pin through PmnPFS,
    // so the pin's driven level never moves.
    const pcntr3 = gpio.regAddress(6, gpio.pcntr3);
    board.pins.applyWrite(pcntr3, 4, 1);
    board.pins.applyWrite(pcntr3, 4, 1);
    board.pins.applyWrite(pcntr3, 4, @as(u32, 1) << 16);
    try std.testing.expectEqual(@as(u16, 0), board.pins.portLevel(6));
    var events: [4]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 2), got.count);
    for (events[0..2], [_]bool{ true, false }) |event, level| {
        try std.testing.expectEqual(api.Event.Kind.led_changed, event.kind);
        try std.testing.expectEqual(@as(u8, 0), event.payload.led.index);
        try std.testing.expectEqual(level, event.payload.led.level);
    }
}

test "an LED lit before the session attached is not reported again until it changes" {
    const gpio = ra8.chip.periph.gpio;
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    const pcntr3 = gpio.regAddress(3, gpio.pcntr3);
    board.pins.applyWrite(pcntr3, 4, 1 << 3);
    var session: api.Session = .{ .live = undefined };
    ra8.session.board.events.attach(&board, &session);
    const subscription = try session.subscribe();
    board.pins.applyWrite(pcntr3, 4, 1 << 3);
    var events: [2]api.Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), session.pollEvents(subscription, &events).?.count);
    board.pins.applyWrite(pcntr3, 4, @as(u32, 1 << 3) << 16);
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 1), got.count);
    try std.testing.expectEqual(@as(u8, 1), events[0].payload.led.index);
    try std.testing.expectEqual(false, events[0].payload.led.level);
}

/// Counts what reaches the host from the pieces a session mutes in a replay.
const Heard = struct {
    var console_lines: u32 = 0;
    var sockets: u32 = 0;
    var usbip_polls: u32 = 0;

    fn reset() void {
        console_lines = 0;
        sockets = 0;
        usbip_polls = 0;
    }
    fn line(_: ?*anyopaque, _: []const u8) anyerror!void {
        console_lines += 1;
    }
    fn open(_: ra8.components.esp_hosted.host_net.Kind) anyerror!ra8.components.esp_hosted.host_net.Handle {
        sockets += 1;
        return error.Refused;
    }
    fn unused(_: ra8.components.esp_hosted.host_net.Handle) anyerror!void {}
    fn connect(_: ra8.components.esp_hosted.host_net.Handle, _: ra8.components.esp_hosted.host_net.Address) anyerror!ra8.components.esp_hosted.host_net.Connect {
        return .done;
    }
    fn writable(_: ra8.components.esp_hosted.host_net.Handle) anyerror!bool {
        return true;
    }
    fn io(_: ra8.components.esp_hosted.host_net.Handle, _: []u8, _: ra8.components.esp_hosted.host_net.Receive) anyerror!usize {
        return error.WouldBlock;
    }
    fn send(_: ra8.components.esp_hosted.host_net.Handle, bytes: []const u8) anyerror!usize {
        return bytes.len;
    }
    fn close(_: ra8.components.esp_hosted.host_net.Handle) void {}
    const net: ra8.components.esp_hosted.host_net.Net = .{
        .open = open,
        .connect = connect,
        .writable = writable,
        .finished = unused,
        .send = send,
        .recv = io,
        .shutdownSend = unused,
        .close = close,
    };

    fn poll(_: *anyopaque, _: *ra8.chip.periph.usbfs.Device, _: *const ra8.chip.periph.usbfs.host.Host) void {
        usbip_polls += 1;
    }
    fn tap(_: *anyopaque, _: ?ra8.board.usb.traffic.Sink) void {}
    fn feed(_: *anyopaque, _: *ra8.chip.periph.usbfs.Device, _: ra8.board.usb.traffic.Event) anyerror!void {}
    fn pump(_: *anyopaque, _: *ra8.chip.periph.usbfs.Device) void {}
    fn drop(_: *anyopaque) void {}
};

fn held(context: *anyopaque) bool {
    const session: *api.Session = @ptrCast(@alignCast(context));
    return session.outputMuted();
}

/// Everything the machine says to the host in one round: a console line, a
/// connection out of the C6, and a poll of the USB/IP bridge.
fn speak(board: *Board, bridge: *ra8.components.esp_hosted.net.Bridge, usb: *ra8.board.usb.Usb) void {
    const hosted = ra8.components.esp_hosted;
    const base = sci.win_base + sci.console_channel * sci.stride;
    board.serial.write(base + sci.off_ccr0, 4, sci.ccr0.te);
    for ("ok\n") |byte| board.serial.write(base + sci.off_tdr, 1, byte);
    var queue: hosted.queue.Queue = .{};
    var bytes: [hosted.frame.max_payload]u8 = undefined;
    const len = hosted.eth.tcpFrame(&bytes, .{
        .src_mac = hosted.station.mac,
        .dst_mac = hosted.station.bssid,
        .src_ip = hosted.dhcp.lease_ip,
        .dst_ip = hosted.dhcp.server_ip,
        .src_port = 40000,
        .dst_port = 80,
    }, 100, 0, hosted.eth.TcpFlag.syn, 1460, &.{}).?;
    _ = bridge.forward(&queue, bytes[0..len]);
    bridge.poll(&queue);
    var device: ra8.chip.periph.usbfs.Device = .{};
    const hook = usb.bridge.?;
    hook.pollFn(hook.context, &device, &usb.script);
}

test "a replay mutes every host-facing output: console, uart events, C6 sockets and USB/IP" {
    const hosted = ra8.components.esp_hosted;
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var session: api.Session = .{ .live = undefined };
    ra8.session.board.events.attach(&board, &session);
    const subscription = try session.subscribe();
    board.serial.line.setSink(.{ .writeFn = Heard.line });
    var bridge: hosted.net.Bridge = .{ .net = Heard.net };
    bridge.hold = .{ .context = &session, .heldFn = held };
    var dummy: u8 = 0;
    var usb: ra8.board.usb.Usb = .{};
    usb.bridge = .{ .context = &dummy, .pollFn = Heard.poll, .port = .{ .tapFn = Heard.tap, .feedFn = Heard.feed, .pumpFn = Heard.pump, .dropFn = Heard.drop } };
    try ra8.session.board.recorded_usbip.attach(std.testing.allocator, &session, &usb);
    defer ra8.session.board.recorded_usbip.release(&usb, &session);
    Heard.reset();
    var events: [16]api.Event = undefined;

    // Live, every channel reaches the host.
    speak(&board, &bridge, &usb);
    const live = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(u32, 1), Heard.console_lines);
    try std.testing.expectEqual(@as(u32, 1), Heard.sockets);
    try std.testing.expectEqual(@as(u32, 1), Heard.usbip_polls);
    try std.testing.expect(live.count >= 3);

    // Replaying, the same round writes nothing anywhere.
    session.setReplaying(true);
    defer session.setReplaying(false);
    Heard.reset();
    speak(&board, &bridge, &usb);
    const replayed = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(u32, 0), Heard.console_lines);
    try std.testing.expectEqual(@as(u32, 0), Heard.sockets);
    try std.testing.expectEqual(@as(u32, 0), Heard.usbip_polls);
    for (events[0..replayed.count]) |event| try std.testing.expect(event.kind != .uart_byte);
    // The guest still ran: the line it printed is captured for the run.
    try std.testing.expectEqualStrings("ok", board.serial.line.slice());
}
