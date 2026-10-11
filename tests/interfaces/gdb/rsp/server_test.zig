//! One connection served over in-memory streams: acknowledgements,
//! framing, a resend on request, a corrupt packet refused, and the ways a
//! connection ends.
const std = @import("std");
const ra8 = @import("ra8");

const dispatch = ra8.gdb.rsp.dispatch;
const packet = ra8.gdb.rsp.packet;
const server = dispatch.server;
const memmap = ra8.chip.core.memmap;
const Rig = @import("../../../session/view_ram.zig").Rig;

fn open(rig: *Rig) !void {
    rig.wire();
    try rig.view().write(memmap.sram_base, &[_]u8{ 0xca, 0xfe });
}

/// `payloads` framed the way gdb sends them, with `extra` after.
fn wire(buffer: []u8, payloads: []const []const u8, extra: []const u8) ![]const u8 {
    var at: usize = 0;
    for (payloads) |payload| at += (try packet.frame(buffer[at..], payload)).len;
    @memcpy(buffer[at..][0..extra.len], extra);
    return buffer[0 .. at + extra.len];
}

fn play(rig: *Rig, input: []const u8, sent: *std.Io.Writer.Allocating) !server.End {
    var reader: std.Io.Reader = .fixed(input);
    return server.serve(.{ .view = rig.view() }, &reader, &sent.writer);
}

// Each packet is acknowledged and answered, and D ends the connection.
test "packets are acknowledged and answered until detach" {
    var rig: Rig = .{};
    try open(&rig);
    var buffer: [128]u8 = undefined;
    const input = try wire(&buffer, &.{ "m22000000,2", "D" }, "");
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    try std.testing.expectEqual(server.End.detached, try play(&rig, input, &sent));
    try std.testing.expectEqualStrings("+$cafe#8f+$OK#9a", sent.written());
}

// A `-` gets the last reply again; a bad checksum gets `-`; k ends silently.
test "resend, a corrupt packet, and kill" {
    var rig: Rig = .{};
    try open(&rig);
    var buffer: [128]u8 = undefined;
    const input = try wire(&buffer, &.{"qAttached"}, "-$m0,1#00$k#6b");
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    try std.testing.expectEqual(server.End.killed, try play(&rig, input, &sent));
    try std.testing.expectEqualStrings("+$1#31$1#31-+", sent.written());
}

// The stream running dry ends the connection as closed.
test "the other end closing" {
    var rig: Rig = .{};
    try open(&rig);
    var sent: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sent.deinit();
    try std.testing.expectEqual(server.End.closed, try play(&rig, "+", &sent));
    try std.testing.expectEqual(@as(usize, 0), sent.written().len);
}
