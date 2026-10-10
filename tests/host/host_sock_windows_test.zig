const std = @import("std");
const win = @import("ra8").interfaces.host_sock_windows;

test "winsock codes map onto the bridge's socket errors" {
    try std.testing.expectEqual(error.WouldBlock, win.mapCode(10035));
    try std.testing.expectEqual(error.WouldBlock, win.mapCode(10036));
    try std.testing.expectEqual(error.ConnectionRefused, win.mapCode(10061));
    try std.testing.expectEqual(error.ConnectionReset, win.mapCode(10054));
    try std.testing.expectEqual(error.BrokenPipe, win.mapCode(10058));
    try std.testing.expectEqual(error.HostUnreachable, win.mapCode(10065));
    try std.testing.expectEqual(error.TimedOut, win.mapCode(10060));
    try std.testing.expectEqual(error.MessageTooBig, win.mapCode(10040));
    try std.testing.expectEqual(error.Unexpected, win.mapCode(1));
}
