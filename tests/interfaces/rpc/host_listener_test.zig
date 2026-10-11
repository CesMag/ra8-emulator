//! Tests for src/interfaces/rpc/host_listener.zig (RA8EMU-1156): the
//! discovery file round-trips the address through ctl's listen spec, a
//! client over the socket is served on the same Served context the panes
//! use, and a hung-up client is dropped for the next one.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const serve_peer = @import("../cli/serve_peer.zig");
const listener_mod = ra8.rpc.host_listener;
const Connection = ra8.rpc.socket_transport.Connection;
const served_setup = ra8.rpc.served_setup;
const proto = ra8.rpc.session.rpc;

const image = serve_peer.image_path;
const Env = proto.Client.Env;

/// A fresh home under /tmp for one test.
fn tempHome(gpa: std.mem.Allocator) ![]u8 {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds()));
    const path = try std.fmt.allocPrint(gpa, "/tmp/ra8_listener_{d}", .{prng.random().int(u64)});
    errdefer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    return path;
}

fn envWithHome(gpa: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    try env.put("HOME", home);
    return env;
}

test "the discovery file lists the rpc address and the sessions" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);

    const sessions = [_]listener_mod.Session{.{ .gdb_port = null, .elf = "/some/image.elf" }};
    try bound.announce(&sessions);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}", .{bound.discovery_path});
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(4096));
    defer gpa.free(text);

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, "\n"), '\n');
    const rpc_line = lines.next().?;
    try std.testing.expect(std.mem.endsWith(u8, rpc_line, "rpc.sock"));
    const spec = try cli_app.serve.listen.Spec.parse(rpc_line["rpc ".len..]);
    try std.testing.expectEqualStrings(bound.socket_path.?, spec.unix);
    try std.testing.expectEqualStrings("session - /some/image.elf", lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());

    bound.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(16)));
}

test "a client over the socket is served on the opened session" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try Connection.unix(std.testing.io, bound.socket_path.?);
    defer connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();

    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    try std.testing.expectEqual(proto.capabilities, (try next(peer, &bound, &opened.context, tx)).ready);
    try loadAndRead(peer, &bound, &opened.context, tx);
}

test "a hung-up client is dropped and the next one is taken" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var first = try Connection.unix(std.testing.io, bound.socket_path.?);
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client != null);
    first.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client == null);

    var second = try Connection.unix(std.testing.io, bound.socket_path.?);
    defer second.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client != null);
}

/// The next frame from the server, serving the listener between polls.
fn next(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8) !proto.Client.Incoming {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        if (try peer.client.poll(peer.tx)) |incoming| return incoming;
        try bound.answer(context, tx);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.ServerSilent;
}

/// One call, its reply taken off the wire through `next`.
fn call(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
    _ = try peer.client.call(Args, @backingInt(method), args, 0, peer.tx);
    while (true) switch (try next(peer, bound, context, tx)) {
        .response => |response| return switch (response.result) {
            .ok => |bytes| try proto.decode(Reply, bytes),
            .err => error.Refused,
        },
        else => {},
    };
}

/// Load the fixture over the wire, run, pause and read pc.
fn loadAndRead(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, peer.gpa, .limited(1 << 20));
    defer peer.gpa.free(bytes);
    _ = try call(peer, bound, context, tx, proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = bytes });
    _ = try call(peer, bound, context, tx, proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 1000 });
    _ = try call(peer, bound, context, tx, proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
    const pc = try call(peer, bound, context, tx, proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    try std.testing.expect(pc.value != 0);
}
