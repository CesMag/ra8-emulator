//! Answers session RPC requests against the core-addressed Session
//! (RA8EMU-735).
//!
//! Each route decodes one session_rpc message, makes the matching Session
//! call and encodes the reply. `run` and `step` reply once the run ends and
//! also queue a `stop` event, which `Host.poll` sends to a subscribed client
//! after any `uart` events the run produced (RA8EMU-758).
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const api = @import("ra8_session").api;
const handlers = @import("session_handlers.zig");
const uart_feed = @import("session_uart_feed.zig");
const event_feed = @import("session_event_feed.zig");
const lcd_feed = @import("session_lcd_feed.zig");
const parts = @import("session_parts.zig");
const session_camera = @import("session_camera.zig");
const session_advance = @import("session_advance.zig");
const session_files = @import("session_files.zig");
const session_map = @import("session_map.zig");
const session_stack = @import("session_stack.zig");
const session_backtrace = @import("session_backtrace.zig");
const session_rtc = @import("session_rtc.zig");
const session_input = @import("session_input.zig");

/// The framing library, for callers that only import the emulator.
pub const rpc_lib = rpc;

pub const Context = handlers.Context;
pub const app_codes = handlers.app_codes;

const M = proto.Method;
const routes = .{
    .{ @backingInt(M.load), handlers.load },
    .{ @backingInt(M.run), handlers.run },
    .{ @backingInt(M.pause), handlers.pause },
    .{ @backingInt(M.step), handlers.step },
    .{ @backingInt(M.set_speed), handlers.setSpeed },
    .{ @backingInt(M.read_register), handlers.readRegister },
    .{ @backingInt(M.write_register), handlers.writeRegister },
    .{ @backingInt(M.read_memory), handlers.readMemory },
    .{ @backingInt(M.write_memory), handlers.writeMemory },
    .{ @backingInt(M.set_breakpoint), handlers.setBreakpoint },
    .{ @backingInt(M.clear_breakpoint), handlers.clearBreakpoint },
    .{ @backingInt(M.set_watchpoint), handlers.setWatchpoint },
    .{ @backingInt(M.clear_watchpoint), handlers.clearWatchpoint },
    .{ @backingInt(M.subscribe), handlers.subscribe },
    .{ @backingInt(M.unsubscribe), handlers.unsubscribe },
    .{ @backingInt(M.now), handlers.now },
    .{ @backingInt(M.interrupt), handlers.interrupt },
    .{ @backingInt(M.set_run_budget), handlers.setRunBudget },
    .{ @backingInt(M.remove_point), handlers.removePoint },
    .{ @backingInt(M.plug), parts.plug },
    .{ @backingInt(M.unplug), parts.unplug },
    .{ @backingInt(M.set_fault), parts.setFault },
    .{ @backingInt(M.clear_fault), parts.clearFault },
    .{ @backingInt(M.list_parts), parts.listParts },
    .{ @backingInt(M.set_camera_source), session_camera.setCameraSource },
    .{ @backingInt(M.map), session_map.map },
    .{ @backingInt(M.stack), session_stack.stack },
    .{ @backingInt(M.backtrace), session_backtrace.backtrace },
    .{ @backingInt(M.rtc), session_rtc.rtc },
    .{ @backingInt(M.input), session_input.input },
    .{ @backingInt(M.advance), session_advance.advance },
    .{ @backingInt(M.snapshot), session_files.snapshot },
    .{ @backingInt(M.restore), session_files.restore },
};

pub const Server = rpc.Server(Context, proto.max_payload, routes);

/// One served connection: the route table plus the events it owes.
pub const Host = struct {
    server: Server,

    /// `rx` buffers incoming frames and `context` must outlive the host.
    /// The connection starts with no subscriptions.
    pub fn init(wire: rpc.Transport, rx: []u8, context: *Context) Host {
        handlers.forget(context);
        return .{ .server = Server.init(wire, rx, context, proto.capabilities) };
    }

    /// Answer at most one frame, then send the UART bytes, the LCD dirty
    /// rectangles, the session events and the stop event it produced, in
    /// that order.
    pub fn poll(self: *Host, tx: []u8) rpc.Error!rpc.Step {
        const step = try self.server.poll(tx);
        const context = self.server.context;
        try uart_feed.pump(context, &self.server, tx);
        try lcd_feed.pump(context, &self.server, tx);
        try event_feed.pump(context, &self.server, tx);
        if (context.pending) |stopped| {
            context.pending = null;
            if (context.wants(stopped.core, .stop)) {
                try self.server.emit(proto.Stopped, @backingInt(proto.Topic.stop), stopped, tx);
            }
        }
        return step;
    }
};
