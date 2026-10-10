//! Connect board observations to the core-addressed session event stream (RA8EMU-192).
const Board = @import("ra8_board").board.Board;
const boundary = @import("ra8_board").boundary;
const api = @import("session_api.zig");

/// Attach non-blocking sources; each callback reads the board bus issuer.
pub fn attach(board: *Board, session: *api.Session) void {
    session.attachTimeBase(&board.time.base);
    session.event_sources.bindBoard(&board.bus.issuer, &board.pins, boundary.observation(board), &board.panel, &board.asks.attached_eink);
    board.pins.observeEvents(session.event_sources.gpioTap(&board.pins, null));
    board.event_sink = session.event_sources.boardEventSink();
    board.serial.tap = session.event_sources.uartTap(null);
    board.panel.event_hook = session.event_sources.einkHook();
    if (board.asks.attached_eink) |panel| panel.event_hook = session.event_sources.einkHook();
    board.display.event_hook = session.event_sources.glcdcHook();
    board.watchdog.event_hook = session.event_sources.watchdogHook();
    board.heartbeat.event_hook = session.event_sources.independentWatchdogHook();
}

pub fn current(board: *Board) @import("ra8_board").event_sink.Observation {
    return boundary.observation(board);
}
