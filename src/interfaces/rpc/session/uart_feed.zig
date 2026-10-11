//! UART bytes for subscribed clients (RA8EMU-758). The session event stream
//! (RA8EMU-192) already carries every byte the firmware writes to an SCI
//! channel; this drains it and sends each run of bytes on one core and
//! channel as one `uart` event, stamped with the virtual time of its last
//! byte (RA8EMU-774).
const std = @import("std");
const proto = @import("rpc.zig");
const api = @import("ra8_session").api;
const Context = @import("handlers.zig").Context;

/// Events read from the stream per pass, and so the most bytes one event carries.
const batch = 64;

const Run = struct { core: proto.Core = .cpu0, channel: u8 = 0, virtual_ns: u64 = 0, len: usize = 0 };

/// Send every queued UART byte a subscribed core wrote through `server`.
pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    const id = context.uart_feed orelse return;
    var events: [batch]api.Event = undefined;
    var bytes: [batch]u8 = undefined;
    while (true) {
        const read = context.session.pollEvents(id, &events) orelse return;
        if (read.dropped != 0) std.debug.print("serve: {d} session events dropped before a client read them\n", .{read.dropped});
        var run: Run = .{};
        for (events[0..read.count]) |event| {
            const uart = switch (event.payload) {
                .uart => |sent| sent,
                else => continue,
            };
            const of: proto.Core = @fromBackingInt(@intCast(@backingInt(event.core)));
            if (!context.wants(of, .uart)) continue;
            if (run.len != 0 and (run.core != of or run.channel != uart.channel)) {
                try send(server, run, &bytes, tx);
                run.len = 0;
            }
            run.core = of;
            run.channel = uart.channel;
            run.virtual_ns = event.virtual_ns;
            bytes[run.len] = uart.byte;
            run.len += 1;
        }
        if (run.len != 0) try send(server, run, &bytes, tx);
        if (read.count < batch) return;
    }
}

fn send(server: anytype, run: Run, bytes: *const [batch]u8, tx: []u8) !void {
    const event: proto.Uart = .{ .core = run.core, .channel = run.channel, .virtual_ns = run.virtual_ns, .bytes = bytes[0..run.len] };
    try server.emit(proto.Uart, @backingInt(proto.Topic.uart), event, tx);
}
