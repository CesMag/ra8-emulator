//! Spawns `ra8_emulator serve --listen` on a Unix path and on an
//! ephemeral localhost TCP port and drives a session over each (RA8EMU-736).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const test_paths = @import("test_paths");
const Connection = ra8.rpc.socket_transport.Connection;
const serve_peer = @import("serve_peer.zig");
const image_path = serve_peer.image_path;
const Term = std.process.Child.Term;

/// Drive one session over `connection`, hang up, then stop serve with SIGTERM.
fn session(gpa: std.mem.Allocator, child: *std.process.Child, connection: *Connection) !void {
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.drive();
    connection.close();
    try std.posix.kill(child.id.?, .TERM);
    try std.testing.expectEqual(Term{ .exited = 0 }, try child.wait(std.testing.io));
}

test "serve --listen tcp::0 binds localhost, serves a client and exits 0 on SIGTERM" {
    const gpa = std.testing.allocator;
    var line: [128]u8 = undefined;
    var started = try serve_peer.listen("tcp::0", &line);
    try std.testing.expect(std.mem.startsWith(u8, started.bound, "tcp:127.0.0.1:"));
    const colon = std.mem.lastIndexOfScalar(u8, started.bound, ':').?;
    const port = try std.fmt.parseInt(u16, started.bound[colon + 1 ..], 10);
    var connection = try Connection.tcp(std.testing.io, try std.Io.net.IpAddress.parse("127.0.0.1", port));
    try session(gpa, &started.child, &connection);
}

test "serve --listen unix:PATH serves a client and removes the path on SIGTERM" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/serve.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var started = try serve_peer.listen(spec, &line);
    try std.testing.expectEqualStrings(spec, started.bound);
    var connection = try Connection.unix(std.testing.io, path);
    try session(gpa, &started.child, &connection);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "serve.sock", .{}));
}

test "serve --listen with a bad spec prints its usage and exits 2" {
    const specs = [_][]const u8{ "tcp:nope", "tcp:host.example:1", "udp::1", "unix:" };
    for (specs) |spec| {
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{ test_paths.emulator, "serve", "--listen", spec, image_path },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(Term{ .exited = 2 }, result.term);
        try std.testing.expectEqualStrings(cli_app.serve_main.usage, result.stderr);
    }
}

test "listen specs: an empty host and localhost bind loopback, a bracketed v6 literal parses" {
    const Spec = cli_app.serve_listen.Spec;
    const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 7000);
    try std.testing.expect((try Spec.parse("tcp::7000")).tcp.eql(&loopback));
    try std.testing.expect((try Spec.parse("tcp:localhost:7000")).tcp.eql(&loopback));
    try std.testing.expect((try Spec.parse("tcp:[::1]:7000")).tcp.eql(&(try std.Io.net.IpAddress.parse("::1", 7000))));
    try std.testing.expectEqualStrings("/tmp/s", (try Spec.parse("unix:/tmp/s")).unix);
    try std.testing.expectError(error.BadListen, Spec.parse("tcp::70000"));
}
