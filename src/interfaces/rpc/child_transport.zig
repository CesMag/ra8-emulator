//! The RPC byte transport over a child process's pipes (RA8EMU-196): the
//! child is a `serve --stdio`, run here or behind ssh.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const Stdio = @import("stdio_transport.zig").Stdio;

pub const Child = struct {
    process: std.process.Child,
    io: std.Io,
    pipes: Stdio = .{},

    /// Start `argv` with its stdin and stdout as the link. Its stderr stays
    /// ours, so a remote's complaint reaches the user. `argv` must outlive
    /// the child.
    pub fn spawn(self: *Child, io: std.Io, argv: []const []const u8) !void {
        self.* = .{ .io = io, .process = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) };
        self.pipes = .{ .input = self.process.stdout.?.handle, .output = self.process.stdin.?.handle };
    }

    pub fn transport(self: *Child) rpc.Transport {
        return self.pipes.transport();
    }

    /// Close the child's stdin, which ends `serve`, then wait for it.
    pub fn close(self: *Child) void {
        if (self.process.stdin) |file| file.close(self.io);
        self.process.stdin = null;
        _ = self.process.wait(self.io) catch {};
    }
};
