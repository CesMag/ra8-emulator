//! Answers session RPC requests against the core-addressed Session
//! (RA8EMU-735).
//!
//! Each route decodes one session_rpc message, makes the matching Session
//! call and encodes the reply. `run` and `step` reply once the run ends and
//! also queue a `stop` event, which `Host.poll` sends to a subscribed client
//! after any `uart` events the run produced (RA8EMU-758).
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const api = @import("ra8_session").api;
const transport_mod = @import("ra8_session").transport;
const handlers = @import("handlers.zig");
const uart_feed = @import("uart_feed.zig");
const event_feed = @import("event_feed.zig");
const lcd_feed = @import("lcd_feed.zig");
const trace_feed = @import("trace_feed.zig");
const parts = @import("parts.zig");
const session_camera = @import("camera.zig");
const session_advance = @import("advance.zig");
const session_seek = @import("seek.zig");
const session_rcont = @import("rcont.zig");
const session_files = @import("files.zig");
const session_map = @import("map.zig");
const session_stack = @import("stack.zig");
const session_rtc = @import("rtc.zig");
const session_input = @import("input.zig");
const session_backtrace = @import("backtrace.zig");
const session_source_line = @import("source_line.zig");
const session_locals = @import("locals.zig");
const session_periph = @import("periph.zig");
const session_folded = @import("folded.zig");
const session_chunks = @import("load_chunks.zig");
const session_branch = @import("branch.zig");
const session_intervene = @import("intervene.zig");
const session_nav = @import("nav_handlers.zig");
const rewind_feed = @import("rewind_feed.zig");
const session_marker = @import("nav_marker.zig");
const session_diff = @import("diff.zig");

/// The framing library, for callers that only import the emulator.
pub const rpc_lib = rpc;

pub const Context = handlers.Context;
pub const app_codes = handlers.app_codes;
/// Release one connection's subscriptions, pending stop and lcd state (RA8EMU-1196).
pub const forget = handlers.forget;

const M = proto.Method;
pub const routes = .{
    .{ @backingInt(M.load), handlers.load },
    .{ @backingInt(M.load_begin), session_chunks.loadBegin },
    .{ @backingInt(M.load_chunk), session_chunks.loadChunk },
    .{ @backingInt(M.load_end), session_chunks.loadEnd },
    .{ @backingInt(M.run), handlers.run },
    .{ @backingInt(M.pause), handlers.pause },
    .{ @backingInt(M.step), handlers.step },
    .{ @backingInt(M.set_speed), handlers.setSpeed },
    .{ @backingInt(M.read_register), handlers.readRegister },
    .{ @backingInt(M.write_register), handlers.writeRegister },
    .{ @backingInt(M.read_memory), handlers.readMemory },
    .{ @backingInt(M.write_memory), handlers.writeMemory },
    .{ @backingInt(M.set_breakpoint), handlers.setBreakpoint },
    .{ @backingInt(M.set_breakpoint_name), handlers.setBreakpointNamed },
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
    .{ @backingInt(M.board_parts), parts.boardParts },
    .{ @backingInt(M.set_camera_source), session_camera.setCameraSource },
    .{ @backingInt(M.map), session_map.map },
    .{ @backingInt(M.stack), session_stack.stack },
    .{ @backingInt(M.backtrace), session_backtrace.backtrace },
    .{ @backingInt(M.source_line), session_source_line.sourceLine },
    .{ @backingInt(M.locals), session_locals.locals },
    .{ @backingInt(M.locals_at), session_locals.localsAt },
    .{ @backingInt(M.periph), session_periph.periph },
    .{ @backingInt(M.folded), session_folded.folded },
    .{ @backingInt(M.rtc), session_rtc.rtc },
    .{ @backingInt(M.input), session_input.input },
    .{ @backingInt(M.advance), session_advance.advance },
    .{ @backingInt(M.advance_async), session_advance.advanceQueued },
    .{ @backingInt(M.seek), session_seek.seek },
    .{ @backingInt(M.rcont), session_rcont.rcont },
    .{ @backingInt(M.snapshot), session_files.snapshot },
    .{ @backingInt(M.restore), session_files.restore },
    .{ @backingInt(M.branch_list), session_branch.branchList },
    .{ @backingInt(M.branch_switch), session_branch.branchSwitch },
    .{ @backingInt(M.branch_delete), session_branch.branchDelete },
    .{ @backingInt(M.branch_confirm_fork), session_branch.branchConfirmFork },
    .{ @backingInt(M.branch_cancel_fork), session_branch.branchCancelFork },
    .{ @backingInt(M.branch_status), session_branch.branchStatus },
    .{ @backingInt(M.console_input), session_intervene.consoleInput },
    .{ @backingInt(M.skip_bkpt), session_intervene.skipBkpt },
    .{ @backingInt(M.play), session_nav.play },
    .{ @backingInt(M.nav_query), session_nav.navQuery },
    .{ @backingInt(M.marker_set), session_marker.markerSet },
    .{ @backingInt(M.frame_status), session_nav.frameStatus },
    .{ @backingInt(M.diff), session_diff.diff },
};

pub const Server = rpc.Server(Context, proto.max_payload, routes);

/// One Host.poll drives an active transport job at most this much host
/// time, so a frame that answers a long advance stays a frame
/// (RA8EMU-1196, slice 14).
const pump_slice_ns: u64 = 10_000_000;

/// One served connection: the route table plus the events it owes.
pub const Host = struct {
    server: Server,

    /// `rx` buffers incoming frames and `context` must outlive the host.
    /// The connection starts with no subscriptions.
    pub fn init(wire: rpc.Transport, rx: []u8, context: *Context) Host {
        handlers.forget(context);
        // A host whose own loop pumps between frames advertises bit 15, so
        // its clients know `advance_async` queues and completes on the
        // transport topic (RA8EMU-1196, slice 14).
        const caps = proto.capabilities | (if (context.transport_async) proto.transport_cap else 0);
        return .{ .server = Server.init(wire, rx, context, caps) };
    }

    /// Answer at most one frame, then send the UART bytes, the LCD dirty
    /// rectangles, the session events, the RTOS events and the stop event it
    /// produced, in that order.
    pub fn poll(self: *Host, tx: []u8) anyerror!rpc.Step {
        const step = try self.server.poll(tx);
        const context = self.server.context;
        try pumpFeeds(context, &self.server, tx);
        if (context.pending) |stopped| {
            context.pending = null;
            if (context.wants(stopped.core, .stop)) {
                try self.server.emit(proto.Stopped, @backingInt(proto.Topic.stop), stopped, tx);
            }
        }
        return step;
    }
};

/// Send everything the connection owes between frames: the UART bytes, the
/// LCD dirty rectangles, the session events, the RTOS events, and one
/// bounded pump of the transport plane's active job. `Host.poll` and the
/// native local GUI link (slice 15) both use this order.
pub fn pumpFeeds(context: *Context, server: anytype, tx: []u8) !void {
    try uart_feed.pump(context, server, tx);
    try lcd_feed.pump(context, server, tx);
    try event_feed.pump(context, server, tx);
    try trace_feed.pump(context, server, tx);
    try pumpTransport(context, server, tx);
    try rewind_feed.pump(context, server, tx);
}

/// Drive the transport's active job one bounded slice and report on the
/// transport topic (RA8EMU-1196, slice 14): a `TransportEvent` when a
/// command changed the plane's epoch, and the completion of the advance
/// this connection queued with `advance_async`, whether it finished or a
/// newer command preempted it.
pub fn pumpTransport(context: *Context, server: anytype, tx: []u8) !void {
    const plane = context.transport orelse return;
    if (context.session.persistent_recorder) |rec| try rec.maybeCommit(rec.now());
    if (plane.job == null and context.advance_ticket == null) return;
    const wall = context.wall orelse return;
    const now = wall.nowFn(wall.context);
    const pumped = try plane.pump(wall, now + pump_slice_ns);
    const subscriber = context.wants(.cpu0, .transport) or context.wants(.cpu1, .transport);
    if (pumped.finished == null and pumped.report.epoch != context.transport_epoch and subscriber) {
        context.transport_epoch = pumped.report.epoch;
        try server.emit(proto.TransportEvent, @backingInt(proto.Topic.transport), eventOf(pumped.report, null), tx);
    }
    const ticket = context.advance_ticket orelse return;
    if (pumped.finished) |fin| {
        if (fin.ticket == ticket) {
            const target = context.advance_target_ns;
            context.advance_ticket = null;
            context.advance_target_ns = 0;
            if (subscriber) {
                const stop = handlers.stopped(context.session, coreOf(fin.core), fin.ended);
                // A completion that ended by count is the run keeping its
                // word: no halt happened, so the stop topic hears nothing.
                // Only a real end parks the stop for `poll` to emit.
                if (fin.ended != .count) context.pending = stop;
                const to = context.session.now() catch context.advance_from_ns;
                var event = eventOf(pumped.report, coreOf(fin.core));
                event.finished = 1;
                event.from_ns = context.advance_from_ns;
                event.target_ns = target;
                event.to_ns = to;
                event.reason = stop.reason;
                event.address = stop.address;
                try server.emit(proto.TransportEvent, @backingInt(proto.Topic.transport), event, tx);
            }
            return;
        }
    }
    // The job is neither running under our ticket nor the plane's newest
    // finished one: a newer command preempted it, so it stopped where it
    // got to, halted like any front end's interrupt.
    const active = plane.job != null and plane.job.?.ticket == ticket;
    const newest = plane.done != null and plane.done.?.ticket == ticket;
    if (!active and !newest) {
        const target = context.advance_target_ns;
        context.advance_ticket = null;
        context.advance_target_ns = 0;
        if (subscriber) {
            const to = context.session.now() catch context.advance_from_ns;
            var event = eventOf(pumped.report, context.advance_core);
            event.finished = 1;
            event.from_ns = context.advance_from_ns;
            event.target_ns = target;
            event.to_ns = to;
            event.reason = .halt_requested;
            try server.emit(proto.TransportEvent, @backingInt(proto.Topic.transport), event, tx);
        }
    }
}

/// The wire form of one transport report; the completion fields stay zero
/// until the caller fills them for a finished job.
fn eventOf(report: transport_mod.Report, finished_core: ?proto.Core) proto.TransportEvent {
    return .{
        .epoch = report.epoch,
        .phase = @backingInt(report.phase),
        .target_ns = report.progress.target_ns orelse 0,
        .reached_ns = report.progress.reached_ns orelse 0,
        .slices = report.progress.slices,
        .finished = 0,
        .core = finished_core orelse .cpu0,
        .from_ns = 0,
        .to_ns = 0,
        .reason = .count,
        .address = 0,
    };
}

/// The wire's core for a session core.
fn coreOf(core: api.Core) proto.Core {
    return @fromBackingInt(@intCast(@backingInt(core)));
}
