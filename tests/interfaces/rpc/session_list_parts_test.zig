//! Host tests for the list_parts handler (RA8EMU-791): it answers with what
//! the server's listing writes, refuses without a listing, and says
//! too_long when the parts do not fit one reply.
const std = @import("std");
const ra8 = @import("ra8");
const proto = ra8.rpc.session_rpc;
const server = ra8.rpc.session_server;
const parts = ra8.rpc.session_parts;
const api = ra8.session.session_api;

const Stub = struct {
    text: []const u8,

    fn list(context: *anyopaque, out: []u8) anyerror![]const u8 {
        const self: *Stub = @ptrCast(@alignCast(context));
        if (self.text.len > out.len) return error.NoSpaceLeft;
        @memcpy(out[0..self.text.len], self.text);
        return out[0..self.text.len];
    }
};

fn code(outcome: anytype) u16 {
    return switch (outcome) {
        .ok => 0,
        .err => |refused| @backingInt(refused),
    };
}

test "list_parts answers with the server's listing" {
    var session: api.Session = .{ .live = undefined };
    var scratch: [proto.max_payload]u8 = undefined;
    var stub: Stub = .{ .text = "max17048@i2c:riic@0x36\nmodem@uart:sci3\n" };
    var context: server.Context = .{ .session = &session, .scratch = &scratch, .listing = .{ .context = &stub, .listFn = Stub.list } };
    const outcome = parts.listParts(&context, .{ .core = .cpu0 });
    try std.testing.expectEqualStrings(stub.text, outcome.ok.text);
}

test "list_parts is refused without a listing and too_long past one reply" {
    var session: api.Session = .{ .live = undefined };
    var scratch: [proto.max_payload]u8 = undefined;
    var context: server.Context = .{ .session = &session, .scratch = &scratch };
    try std.testing.expectEqual(server.app_codes.refused, code(parts.listParts(&context, .{ .core = .cpu0 })));
    var stub: Stub = .{ .text = &(@as([proto.PartList.max_len.text + 1]u8, @splat('x'))) };
    context.listing = .{ .context = &stub, .listFn = Stub.list };
    try std.testing.expectEqual(server.app_codes.too_long, code(parts.listParts(&context, .{ .core = .cpu0 })));
}

test "a part list round-trips through the codec" {
    var bytes: [256]u8 = undefined;
    const payload = try proto.encode(proto.PartList, .{ .text = "modem@uart:sci3\n" }, &bytes);
    const back = try proto.decode(proto.PartList, payload);
    try std.testing.expectEqualStrings("modem@uart:sci3\n", back.text);
}
