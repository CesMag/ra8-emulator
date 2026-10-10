//! The debugger on the Zig core (RA8EMU-117): `--cpu zig` with
//! `--debug-script` or `--debug`. The public harness owns CPU0 and its board;
//! this front adds the requested debugger mode and optional CPU1.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const cpu1_image = @import("cpu1_image.zig");
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const Board = @import("ra8_board").board.Board;
const board_wiring = @import("ra8_board").wiring;
const board_speed = @import("ra8_session").board_speed;
const pacing = @import("ra8_board").run.pacing;
const script = @import("ra8_session").script;
const stop_machine = @import("ra8_session").stop_machine;
const zig_script = @import("ra8_session").zig_script;
const session_api = @import("ra8_session").session_api;
const step_hook = @import("ra8_session").step_hook;
const watch_bus = @import("ra8_session").watch_bus;
const debug_front = @import("debug_front.zig");
const rsp_dispatch = @import("../gdb/rsp_dispatch.zig");
const rsp_poll = @import("../gdb/rsp_poll.zig");
const second_core = @import("ra8_chip").core.second_core;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const exclusive_peer = @import("ra8_chip").core.cpu.exclusive_peer;
const harness = @import("ra8_session").harness;

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
    var speed: board_speed.BoardSpeed = .{ .time = &opened.board().time, .paced = &opened.board().run.pacing, .clock = pacing.hostClock(io) };
    target.session.speed = speed.hook();
    var pair: second_core.zig_run.Driver = undefined;
    var other: Other = .{};
    const named = request.cpu1 orelse return serve(allocator, io, &target, request.mode, out);
    other.open(allocator, io, &pair, &opened, named, &target) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
        return 1;
    };
    defer other.close(allocator, &pair);
    return serve(allocator, io, &target, request.mode, out);
}

/// gdb on the port, or the script or terminal.
fn serve(allocator: std.mem.Allocator, io: std.Io, target: *zig_script.ZigScript, mode: debug_front.Mode, out: anytype) !u8 {
    if (mode == .gdb) return listen(io, target.session, mode.gdb);
    return drive(allocator, io, target, mode, out);
}

/// CPU1 under the debugger, parked in the session until `core 1`.
const Other = struct {
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    bytes: []u8 = &.{},
    paired: ?*cpu_mod.Cpu = null,

    fn open(self: *Other, allocator: std.mem.Allocator, io: std.Io, pair: *second_core.zig_run.Driver, opened: *harness.Harness, path: []const u8, target: *zig_script.ZigScript) !void {
        self.bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(second_core.limits.image_bytes));
        errdefer allocator.free(self.bytes);
        try cpu1_image.open(pair, allocator, io, board_wiring.cpu1(opened.board()), path, opened.guest());
        target.other_image = try elf.Image.init(self.bytes);
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = pair.core.cpu.bus, .driver = &self.driver };
        pair.core.cpu.bus = self.watching.view();
        exclusive_peer.pair(opened.primaryCpu(), &pair.core.cpu);
        self.paired = opened.primaryCpu();
        target.session.live.other = .{ .core = .{ .cpu = &pair.core.cpu }, .machine = &self.machine, .watch = &self.watching, .index = 1, .budget = target.session.live.budget };
        opened.attachCore(.cpu1, &pair.core.cpu, pair.guest());
        opened.bindSecond(&pair.second, pair.guest());
        try target.session.load(.cpu1, target.other_image.?.bytes);
        try target.session.switchTo(.cpu0);
    }

    fn close(self: *Other, allocator: std.mem.Allocator, pair: *second_core.zig_run.Driver) void {
        if (self.paired) |cpu0| exclusive_peer.unpair(cpu0, &pair.core.cpu);
        pair.close();
        allocator.free(self.bytes);
    }
};

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
