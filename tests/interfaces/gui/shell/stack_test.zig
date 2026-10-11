//! Host tests for the shell's call stack leaf (src/interfaces/gui/
//! shell/stack.zig, RA8EMU-1125): one backtrace asks only once due, its
//! answer becomes the shown chain, a stop of the bound core makes an ask
//! due, a refused ask keeps the last chain with a note, an answer sent
//! before a load is dropped, and a packed list whose count disagrees is
//! refused.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const proto = ra8.rpc.session.rpc;
const backtrace_wire = ra8.rpc.backtrace_wire;
const shell_stack = gui_app.shell.stack;
const Stack = shell_stack.Stack;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const Env = proto.Client.Env;

/// A link that has finished its greeting, writing into a pipe nobody answers.
const Wire = struct {
    link: session_link.Link = undefined,
    io: Stdio = .{},
    fds: [4]std.posix.fd_t = undefined,
    rx: [2 * Env.max_frame]u8 = undefined,
    tx: [Env.max_frame]u8 = undefined,

    fn open(self: *Wire) !void {
        const down = try std.Io.Threaded.pipe2(.{});
        const up = try std.Io.Threaded.pipe2(.{});
        self.fds = .{ down[0], down[1], up[0], up[1] };
        self.io = .{ .input = up[0], .output = down[1] };
        self.link.open(self.io.transport(), &self.rx, &self.tx);
        self.link.state = .{ .connected = .{ .version = proto.protocol_version, .caps = proto.capabilities } };
        self.link.client.peer_caps = proto.capabilities;
    }

    fn close(self: *Wire) void {
        for (self.fds) |fd| std.Io.Threaded.closeFd(fd);
    }
};

const main_frame: proto.StackFrame = .{ .pc = 0x0200_0100, .interrupted = 0, .offset = 0, .line = 12, .name = "main", .file = "main.c" };
const reset_frame: proto.StackFrame = .{ .pc = 0x0200_0040, .interrupted = 1, .offset = 8, .line = 0, .name = "Reset_Handler", .file = "" };

/// Answer `id` with `count` and the two frames above packed.
fn answer(model: *Stack, id: u32, count: u8) !void {
    var frames: [proto.backtrace_bytes]u8 = undefined;
    var at: usize = 0;
    try backtrace_wire.put(&frames, &at, main_frame);
    try backtrace_wire.put(&frames, &at, reset_frame);
    var bytes: [proto.backtrace_bytes + 16]u8 = undefined;
    const payload = try proto.encode(proto.Backtrace, .{ .core = model.core, .count = count, .frames = frames[0..at] }, &bytes);
    model.observe(.{ .response = .{ .id = id, .result = .{ .ok = payload } } });
}

fn stop(model: *Stack, core: proto.Core) !void {
    var bytes: [32]u8 = undefined;
    const payload = try proto.encode(proto.Stopped, .{ .core = core, .reason = .stepped, .address = 0x100, .detail = 0 }, &bytes);
    model.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.stop), .payload = payload } });
}

test "an ask goes out only once due, and one at a time" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var model: Stack = .{ .core = .cpu0 };
    model.attach(&wire.link);
    try std.testing.expectEqual(@as(?u32, null), model.asked);
    model.reload();
    model.attach(&wire.link);
    const first = model.asked.?;
    model.want = true;
    model.attach(&wire.link);
    try std.testing.expectEqual(first, model.asked.?);
    try std.testing.expect(model.want);
}

test "the answer becomes the shown chain with names and files copied" {
    var model: Stack = .{ .core = .cpu1, .asked = 7 };
    try std.testing.expectEqualStrings("waiting for the call stack", model.note().?);
    try answer(&model, 7, 2);
    const now = model.now.?;
    try std.testing.expectEqual(@as(usize, 2), now.count);
    try std.testing.expectEqualStrings("main", now.frames[0].name());
    try std.testing.expectEqualStrings("main.c", now.frames[0].file());
    try std.testing.expectEqual(@as(u32, 12), now.frames[0].line);
    try std.testing.expect(now.frames[1].interrupted);
    try std.testing.expectEqual(@as(u32, 8), now.frames[1].offset);
    try std.testing.expectEqual(@as(?[]const u8, null), model.note());
    try std.testing.expectEqual(@as(?u32, null), model.asked);
}

test "an answer to another ask is ignored" {
    var model: Stack = .{ .core = .cpu0, .asked = 3 };
    try answer(&model, 4, 2);
    try std.testing.expectEqual(@as(?shell_stack.Snapshot, null), model.now);
    try std.testing.expectEqual(@as(?u32, 3), model.asked);
}

test "a stop of the bound core makes an ask due, another core's does not" {
    var model: Stack = .{ .core = .cpu1 };
    try stop(&model, .cpu0);
    try std.testing.expect(!model.want);
    try stop(&model, .cpu1);
    try std.testing.expect(model.want);
}

test "a refused ask keeps the last chain with a note" {
    var model: Stack = .{ .core = .cpu0, .asked = 1 };
    try answer(&model, 1, 2);
    model.asked = 2;
    model.observe(.{ .response = .{ .id = 2, .result = .{ .err = @fromBackingInt(@intCast(proto.app_codes.refused)) } } });
    try std.testing.expectEqual(@as(usize, 2), model.now.?.count);
    try std.testing.expectEqualStrings("the session would not walk the stack", model.note().?);
}

test "an answer sent before a load is dropped and a fresh ask follows" {
    var model: Stack = .{ .core = .cpu0, .asked = 5 };
    model.reload();
    try answer(&model, 5, 2);
    try std.testing.expectEqual(@as(?shell_stack.Snapshot, null), model.now);
    try std.testing.expect(model.want);
    try std.testing.expect(!model.stale);
}

test "a packed list whose count disagrees is refused" {
    var model: Stack = .{ .core = .cpu0, .asked = 9 };
    try answer(&model, 9, 3);
    try std.testing.expectEqual(@as(?shell_stack.Snapshot, null), model.now);
    try std.testing.expect(model.refused);
}
