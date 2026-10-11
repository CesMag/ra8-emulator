//! Whether gdb sent an interrupt (0x03) while a resume runs.
//!
//! The session asks between run chunks (src/session/session.zig, `Poll`).
//! The check peeks at the connection without waiting. An interrupt byte is
//! taken; anything else is left for the packet reader once the run stops.
const std = @import("std");
const packet = @import("packet.zig");
const debug_session = @import("ra8_session").session;
const sock_ready = @import("ra8_host").sock.ready;

/// Instructions per run chunk under gdb: small enough that an interrupt
/// lands promptly, large enough that polling costs nothing measurable.
pub const chunk: usize = 200_000;

pub const Socket = struct {
    handle: std.posix.socket_t,

    pub fn poll(self: *Socket) debug_session.Poll {
        return .{ .context = self, .check = check };
    }

    fn check(context: *anyopaque) bool {
        const self: *Socket = @ptrCast(@alignCast(context));
        const ready = sock_ready.wait(self.handle, 0) catch return false;
        if (!ready.any()) return false;
        var byte: [1]u8 = undefined;
        const peeked = sock_ready.takeByte(self.handle, &byte, true) orelse return false;
        if (peeked == 0 or byte[0] != packet.interrupt) return false;
        _ = sock_ready.takeByte(self.handle, &byte, false) orelse return false;
        return true;
    }
};
