const ra8 = @import("ra8");
test "stdio adapter exposes the shared byte transport" {
    var io: ra8.rpc.stdio_transport.Stdio = .{};
    const wire = io.transport();
    try @import("std").testing.expect(wire.poll() <= 1);
}

test "process stdio on a posix host is stdin and stdout" {
    const std = @import("std");
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = ra8.rpc.stdio_transport.Stdio.process();
    try std.testing.expectEqual(@as(std.posix.fd_t, 0), io.input);
    try std.testing.expectEqual(@as(std.posix.fd_t, 1), io.output);
}
