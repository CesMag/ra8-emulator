//! The shell's console feed (RA8EMU-787): the session's UART output, kept
//! in a console log stamped with board time. Once the link is connected it
//! subscribes both cores' uart topic; each uart event's bytes land in the
//! log at the event's own virtual time (RA8EMU-774).
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_link = @import("session_link.zig");
const console_log = @import("console_log.zig");

/// Lines the shell's console keeps before the oldest falls off.
pub const scrollback: usize = 2000;

pub const Console = struct {
    log: console_log.Log,
    subscribed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Console {
        return .{ .log = console_log.Log.init(allocator, scrollback) };
    }

    pub fn deinit(self: *Console) void {
        self.log.deinit();
    }

    /// Subscribe both cores' UART output, once, after the session greets.
    pub fn attach(self: *Console, link: *session_link.Link) void {
        if (self.subscribed or link.state != .connected) return;
        for ([_]proto.Core{ .cpu0, .cpu1 }) |core| {
            _ = link.send(proto.Subscription, .subscribe, .{ .core = core, .topic = .uart }) catch return;
        }
        self.subscribed = true;
    }

    /// Feed a uart event's bytes into the log at its board time.
    pub fn observe(self: *Console, arrival: session_link.Arrival) error{OutOfMemory}!void {
        const event = switch (arrival) {
            .event => |event| event,
            .response => return,
        };
        if (event.topic != @backingInt(proto.Topic.uart)) return;
        const sent = proto.decode(proto.Uart, event.payload) catch return;
        try self.log.feedAll(sent.bytes, sent.virtual_ns);
    }

    /// Whether the log holds anything to show yet.
    pub fn hasOutput(self: *const Console) bool {
        return self.log.lines().len > 0 or self.log.partial().len > 0;
    }
};
