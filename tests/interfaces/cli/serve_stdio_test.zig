//! Spawns `ra8_emulator serve --stdio` and drives it over its pipes
//! (RA8EMU-737): greet, load, run, pause, read registers, close stdin.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const test_paths = @import("test_paths");
const Stdio = ra8.rpc.stdio_transport.Stdio;
const serve_peer = @import("serve_peer.zig");
const image_path = serve_peer.image_path;

test "serve --stdio answers a client on its pipes and exits 0 once stdin closes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ test_paths.emulator, "serve", "--stdio", image_path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer child.kill(io);
    var pipes: Stdio = .{ .input = child.stdout.?.handle, .output = child.stdin.?.handle };
    const peer = try serve_peer.Peer.init(gpa, pipes.transport());
    defer peer.deinit();
    try peer.drive();

    child.stdin.?.close(io);
    child.stdin = null;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "serve without --stdio prints its usage and exits 2" {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ test_paths.emulator, "serve", image_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, result.term);
    try std.testing.expectEqualStrings(cli_app.serve.main.usage, result.stderr);
    try std.testing.expectEqualStrings("", result.stdout);
}
