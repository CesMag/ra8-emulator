//! One gdb connection, served: bytes in through the packet reader, each
//! packet answered by the dispatcher, each reply framed and sent, and a
//! reply gdb asks for again (`-`) sent again.
//!
//! The connection ends on `D` (detach, answered OK), `k` (kill, which gets
//! no reply) or the other end closing. Requests are answered one at a time.
//! An interrupt (0x03) sent while a resume runs is picked up between run
//! chunks by the session's poll (src/interfaces/gdb/rsp/poll.zig), not here.
//! What firmware printed through ITM port 0 during a resume goes out as
//! `O` packets just before its stop reply (src/interfaces/gdb/rsp/console.zig).
const std = @import("std");
const packet = @import("packet.zig");
const rsp_dispatch = @import("dispatch.zig");
const console = @import("console.zig");

pub const limits = struct {
    /// Bytes the connection's reader buffers per read.
    pub const chunk: usize = 512;
    /// A framed reply: every payload byte escaped, plus `$`, `#` and the sum.
    pub const framed: usize = rsp_dispatch.packet_size * 2 + 4;
};

/// How the connection ended.
pub const End = enum { detached, killed, closed };

/// Serve one connection until it ends.
pub fn serve(dispatch: rsp_dispatch.Dispatch, reader: *std.Io.Reader, writer: *std.Io.Writer) !End {
    var incoming: [rsp_dispatch.packet_size]u8 = undefined;
    var wire = packet.Reader.init(&incoming);
    var payload: [rsp_dispatch.packet_size]u8 = undefined;
    var framed: [limits.framed]u8 = undefined;
    var last: []const u8 = &.{};
    defer writer.flush() catch {};
    while (true) {
        try writer.flush();
        const got = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return .closed,
            else => |e| return e,
        };
        reader.toss(got.len);
        for (got) |byte| {
            const event = wire.push(byte) orelse continue;
            switch (event) {
                .ack, .interrupt => {},
                .resend => try writer.writeAll(last),
                .corrupt, .overflow => try writer.writeByte(packet.resend),
                .packet => |request| {
                    try writer.writeByte(packet.ack);
                    if (std.mem.eql(u8, request, "k")) return .killed;
                    const detach = request.len > 0 and request[0] == 'D';
                    const reply = if (detach) "OK" else try dispatch.answer(request, &payload);
                    if (dispatch.zig) |live| {
                        if (console.resumes(request)) {
                            const port = try live.session.itmPort(live.session.currentCore());
                            try console.send(writer, port, &framed);
                        }
                    }
                    last = try packet.frame(&framed, reply);
                    try writer.writeAll(last);
                    if (detach) return .detached;
                },
            }
        }
    }
}
