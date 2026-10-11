//! The debugger on the Zig core (RA8EMU-117): `--cpu zig` with
//! `--debug-script` or `--debug`. The public harness owns CPU0 and its board;
//! this front adds the requested debugger mode and optional CPU1.
const std = @import("std");
const board_speed = @import("ra8_session").board.speed;
const pacing = @import("ra8_session").run.pacing;
const RunPolicy = @import("ra8_session").run.policy.RunPolicy;
const script = @import("ra8_session").script;
const zig_script = @import("ra8_session").zig.script;
const session_api = @import("ra8_session").api;
const debug_front = @import("../debug_front.zig");
const rsp_dispatch = @import("ra8_gdb").rsp.dispatch;
const rsp_poll = @import("ra8_gdb").rsp.poll;
const harness = @import("ra8_session").harness;
const cpu1_bringup = @import("ra8_session").cpu1.bringup;

/// Why a request cannot run on the Zig core's debugger yet, or null when it can.
pub fn refusal(request: debug_front.Request) ?[]const u8 {
    if (request.cpu != .zig) return "the debugger runs on --cpu zig";
    return null;
}

/// Open `request.image` through the public harness and serve its debugger.
pub fn run(allocator: std.mem.Allocator, io: std.Io, request: debug_front.Request, out: anytype) !u8 {
    if (refusal(request)) |why| {
        std.debug.print("{s}\n", .{why});
        return 2;
    }
    var opened = harness.open(allocator, io, .{ .elf_path = request.image, .device = .ra8d2 }) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ request.image, @errorName(err) });
        return 1;
    };
    defer opened.deinit();
    var target: zig_script.ZigScript = .{ .image = opened.image(), .session = opened.session() };
    var asked: RunPolicy = .{};
    asked.attach(opened.board());
    var speed: board_speed.BoardSpeed = .{ .time = &opened.board().time, .paced = &asked.pacing, .clock = pacing.hostClock(io) };
    target.session.speed = speed.hook();
    var other: cpu1_bringup.Cpu1 = .{};
    const named = request.cpu1 orelse return serve(allocator, io, &target, request.mode, out);
    other.open(allocator, io, &opened, named) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
        return 1;
    };
    defer other.close(allocator);
    target.other_image = other.image;
    return serve(allocator, io, &target, request.mode, out);
}

/// gdb on the port, or the script or terminal.
fn serve(allocator: std.mem.Allocator, io: std.Io, target: *zig_script.ZigScript, mode: debug_front.Mode, out: anytype) !u8 {
    if (mode == .gdb) return listen(io, target.session, mode.gdb);
    return drive(allocator, io, target, mode, out);
}

/// Play the script or talk to the terminal.
fn drive(allocator: std.mem.Allocator, io: std.Io, target: *zig_script.ZigScript, mode: debug_front.Mode, out: anytype) !u8 {
    switch (mode) {
        .script => |path| {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(debug_front.limits.max_file)) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
                return 1;
            };
            defer allocator.free(text);
            _ = try script.play(target, text, out, true);
        },
        .interactive => try debug_front.converse(io, target, out),
        .gdb => unreachable,
    }
    try target.session.flushItm(target.session.currentCore(), out, true);
    return 0;
}

/// Wait for gdb on the loopback port and serve it from the Zig core.
fn listen(io: std.Io, live: *session_api.Session, port: u16) !u8 {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("cannot listen on 127.0.0.1:{d}: {s}\n", .{ port, @errorName(err) });
        return 1;
    };
    defer server.deinit(io);
    std.debug.print("gdb: listening on 127.0.0.1:{d}\n", .{port});
    const stream = try server.accept(io);
    defer stream.close(io);
    var socket = rsp_poll.Socket{ .handle = stream.socket.handle };
    try live.setRunBudget(live.currentCore(), rsp_poll.chunk);
    var target: rsp_dispatch.zig_run.Target = .{ .session = live, .poll = socket.poll() };
    const stub = rsp_dispatch.Dispatch{ .zig = &target };
    var in: [rsp_dispatch.server.limits.chunk]u8 = undefined;
    var out: [rsp_dispatch.server.limits.framed]u8 = undefined;
    var reader = stream.reader(io, &in);
    var writer = stream.writer(io, &out);
    const end = try rsp_dispatch.server.serve(stub, &reader.interface, &writer.interface);
    std.debug.print("gdb: {s}\n", .{@tagName(end)});
    return 0;
}
