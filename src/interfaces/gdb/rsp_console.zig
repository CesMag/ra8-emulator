//! Firmware printf for gdb's console: what ITM port 0 was sent during a
//! resume goes to gdb as `O` packets, ahead of the stop reply.
//!
//! An `O` packet carries console text as hex, two digits a byte, and gdb
//! takes them only while the target runs, so they go out between a `c`,
//! `s` or `vCont` and its stop reply. The text is then forgotten, so the
//! session's own `itm:` lines do not repeat it when the connection ends.
const std = @import("std");
const packet = @import("rsp_packet.zig");
const itm = @import("ra8_chip").periph.itm;

pub const limits = struct {
    /// Text bytes per packet; its hex plus the `O` stays well inside the
    /// packet size gdb was told.
    pub const chunk: usize = 512;
};

const digits = "0123456789abcdef";

/// Whether `request` resumes the target, the one time gdb takes `O`.
pub fn resumes(request: []const u8) bool {
    if (request.len == 0) return false;
    if (std.mem.startsWith(u8, request, "vCont;")) return true;
    return request[0] == 'c' or request[0] == 's';
}

/// Send port 0's text, and a note of any characters it dropped, as framed
/// `O` packets, then clear it. `framed` is scratch for each frame.
pub fn send(writer: anytype, port: *itm.Itm, framed: []u8) !void {
    try text(writer, port.output(), framed);
    if (port.dropped != 0) {
        var note: [48]u8 = undefined;
        const said = std.fmt.bufPrint(&note, "({d} characters dropped)\n", .{port.dropped}) catch &note;
        try text(writer, said, framed);
    }
    port.clear();
}

fn text(writer: anytype, bytes: []const u8, framed: []u8) !void {
    var payload: [1 + 2 * limits.chunk]u8 = undefined;
    payload[0] = 'O';
    var rest = bytes;
    while (rest.len > 0) {
        const take: usize = @min(rest.len, limits.chunk);
        for (rest[0..take], 0..) |byte, index| {
            payload[1 + 2 * index] = digits[byte >> 4];
            payload[2 + 2 * index] = digits[byte & 0xf];
        }
        try writer.writeAll(try packet.frame(framed, payload[0 .. 1 + 2 * take]));
        rest = rest[take..];
    }
}
