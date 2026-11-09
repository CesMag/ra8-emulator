const std = @import("std");
const builtin = @import("builtin");
const relocation = @import("cli_app").host.relocation;
const test_paths = @import("test_paths");

test "CLI peer capability refuses a relative executable before root creation" {
    try std.testing.expectError(error.RelativePath, relocation.capability(std.testing.io, "peer.exe"));
}

test "owned host move peer checks its entry arguments" {
    const gpa = std.testing.allocator;
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_paths.host_move_peer, "unexpected" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, "error: BadArguments\n"));
}

test "owned host move peer rejects a missing request frame" {
    const gpa = std.testing.allocator;
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_paths.host_move_peer, "--internal-host-move" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    const expected = if (builtin.os.tag == .linux or builtin.os.tag == .windows) "error: EndOfStream\n" else "error: OperationUnsupported\n";
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, expected));
}

test "emulator internal host move route reaches the same frame check" {
    const gpa = std.testing.allocator;
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_paths.emulator, "--internal-host-move" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    const expected = if (builtin.os.tag == .linux or builtin.os.tag == .windows) "error: EndOfStream\n" else "error: OperationUnsupported\n";
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, expected));
}
