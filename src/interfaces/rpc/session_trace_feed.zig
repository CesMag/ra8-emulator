//! RTOS switch and ISR events for subscribed clients (RA8EMU-832). The
//! session event stream publishes them in-process (RA8EMU-346); this drains
//! its own queue and sends each one the wire names as a `trace` event, with
//! the thread's name read from its TX_THREAD when the server can read it.
const std = @import("std");
const proto = @import("session_rpc.zig");
const api = @import("ra8_session").api;
const Context = @import("session_handlers.zig").Context;

/// Events read from the stream per pass.
const batch = 64;

/// Send every queued RTOS event a subscribed core produced through `server`.
pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    const id = context.trace_feed orelse return;
    var events: [batch]api.Event = undefined;
    var name_buf: [proto.TraceEvent.max_len.name]u8 = undefined;
    while (true) {
        const read = context.session.pollEvents(id, &events) orelse return;
        if (read.dropped != 0) std.debug.print("serve: {d} trace events dropped before a client read them\n", .{read.dropped});
        for (events[0..read.count]) |event| {
            const kind: proto.EventKind = switch (event.kind) {
                .rtos_switch => .rtos_switch,
                .rtos_idle => .rtos_idle,
                .isr_enter => .isr_enter,
                .isr_leave => .isr_leave,
                else => continue,
            };
            const of: proto.Core = @fromBackingInt(@intCast(@backingInt(event.core)));
            if (!context.wants(of, .trace)) continue;
            const rtos: @FieldType(api.Event.Payload, "rtos") = switch (event.payload) {
                .rtos => |rtos| rtos,
                else => .{},
            };
            var name: []const u8 = "";
            if (context.thread_names) |names| {
                if (names.nameFn(names.context, @backingInt(event.core), rtos.thread, &name_buf)) |found| name = found;
            }
            const sent: proto.TraceEvent = .{
                .core = of,
                .kind = kind,
                .virtual_ns = event.virtual_ns,
                .thread = rtos.thread,
                .exception = rtos.exception,
                .name = name,
            };
            try server.emit(proto.TraceEvent, @backingInt(proto.Topic.trace), sent, tx);
        }
        if (read.count < batch) return;
    }
}
