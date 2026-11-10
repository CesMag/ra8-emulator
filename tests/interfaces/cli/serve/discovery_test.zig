//! The optional daemon discovery lifecycle uses real RPC, ctl and GDB peers.
const std = @import("std");
const ra8 = @import("ra8");
const app = @import("cli_app");
const paths = @import("test_paths");
const peer_mod = @import("../serve_peer.zig");
const helpers = @import("../../rpc/host_listener_helpers.zig");
const io = std.testing.io;
const ready = ra8.host.sock.ready;
const proto = ra8.rpc.session.rpc;

test "discover is opt-in and duplicate flags are refused" {
    const main = app.serve.main;
    try std.testing.expect(!main.parse(&.{ "emu", "serve", "--stdio", "app.elf" }).?.discover);
    try std.testing.expect(main.parse(&.{ "emu", "serve", "--discover", "--stdio", "app.elf" }).?.discover);
    try std.testing.expect(main.parse(&.{ "emu", "serve", "--discover", "--discover", "--stdio", "app.elf" }) == null);
}

fn started(child: *std.process.Child, line: []u8) ![]const u8 {
    var at: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        var slices = [_][]u8{&byte};
        if (try child.stderr.?.readStreaming(io, &slices) == 0) return error.ServerExited;
        if (byte[0] == '\n') {
            if (std.mem.startsWith(u8, line[0..at], "serve: listening on ")) return line["serve: listening on ".len..at];
            at = 0;
        } else {
            if (at == line.len) return error.LineTooLong;
            line[at] = byte[0];
            at += 1;
        }
    }
}

fn ctl(gpa: std.mem.Allocator, env: *std.process.Environ.Map, command: []const u8, success: bool) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ paths.emulator, "ctl", command, "--json" },
        .environ_map = env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = if (success) 0 else 1 }, result.term);
    if (!success) {
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "serve --discover") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "127.0.0.1:") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, peer_mod.image_path) != null);
    }
}

fn gdbPacket(client: std.Io.net.Stream, request: []const u8, output: []u8) ![]const u8 {
    var framed: [128]u8 = undefined;
    try ready.sendAll(io, client.socket.handle, try ra8.gdb.rsp.packet.frame(&framed, request), 1000);
    var incoming: [1024]u8 = undefined;
    var reader = ra8.gdb.rsp.packet.Reader.init(&incoming);
    const end = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 5000;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < end) {
        if (!(try ready.wait(io, client.socket.handle, 10)).any()) continue;
        var byte: [1]u8 = undefined;
        if ((ready.takeByte(io, client.socket.handle, &byte, false) orelse return error.LinkDown) == 0) return error.LinkDown;
        if (reader.push(byte[0])) |event| switch (event) {
            .packet => |packet| {
                if (packet.len > output.len) return error.Overflow;
                @memcpy(output[0..packet.len], packet);
                return output[0..packet.len];
            },
            else => {},
        };
    }
    return error.GdbSilent;
}

fn connect(text: []const u8) !ra8.rpc.socket_transport.Connection {
    return switch (try app.serve.listen.Spec.parse(text)) {
        .unix => |path| ra8.rpc.socket_transport.Connection.unix(io, path),
        .tcp => |ip| ra8.rpc.socket_transport.Connection.tcp(io, ip),
    };
}

fn exercise(gpa: std.mem.Allocator, env: *std.process.Environ.Map, discovery_path: []const u8, bound: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snapshot = (try app.ctl.discovery.read(arena.allocator(), io, env)).?;
    try std.testing.expectEqual(@as(usize, 1), snapshot.sessions.len);
    try ctl(gpa, env, "sessions", true);
    try ctl(gpa, env, "gdb-address", true);
    var primary = try connect(bound);
    defer primary.close();
    const main_peer = try peer_mod.Peer.init(gpa, primary.transport());
    defer main_peer.deinit();
    try main_peer.client.greet(main_peer.tx);
    _ = try main_peer.next();
    var rpc = try connect(snapshot.rpc);
    defer rpc.close();
    const peer = try peer_mod.Peer.init(gpa, rpc.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    _ = try peer.next();
    const pc = try peer.call(proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    try std.testing.expect(pc.value != 0);
    const gdb = try (std.Io.net.IpAddress{ .ip4 = .loopback(snapshot.sessions[0].port) }).connect(io, .{ .mode = .stream });
    defer gdb.close(io);
    var reply: [1024]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try gdbPacket(gdb, "qSupported", &reply), "PacketSize=") != null);
    const hex = try gdbPacket(gdb, "pf", &reply);
    var bytes: [4]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    try std.testing.expectEqual(pc.value, std.mem.readInt(u32, &bytes, .little));
    try std.Io.Dir.cwd().access(io, discovery_path, .{});
}

test "serve discovery is pumped alongside its primary RPC connection and removed on exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // graceful POSIX stop below
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |discover| {
        const home = try helpers.tempHome(gpa);
        defer gpa.free(home);
        defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
        var env = std.process.Environ.Map.init(gpa);
        defer env.deinit();
        try env.put("HOME", home);
        const discovery_path = try app.ctl.discovery.path(gpa, &env);
        defer gpa.free(discovery_path);
        const enabled = [_][]const u8{ paths.emulator, "serve", "--discover", "--listen", "tcp::0", peer_mod.image_path };
        const disabled = [_][]const u8{ paths.emulator, "serve", "--listen", "tcp::0", peer_mod.image_path };
        var child = try std.process.spawn(io, .{
            .argv = if (discover) &enabled else &disabled,
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        var running = true;
        defer if (running) child.kill(io);
        var line: [256]u8 = undefined;
        const bound = try started(&child, &line);
        if (discover) {
            try exercise(gpa, &env, discovery_path, bound);
        } else {
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, discovery_path, .{}));
            try ctl(gpa, &env, "sessions", false);
        }
        try std.posix.kill(child.id.?, .TERM);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
        running = false;
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, discovery_path, .{}));
        const socket = try std.fs.path.join(gpa, &.{ home, ".config", "ra8_emulator", "rpc.sock" });
        defer gpa.free(socket);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, socket, .{}));
    }
}

test "stdio discovery is released on EOF and graceful stop signals" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |signal| {
        if (@import("builtin").os.tag == .windows and signal) continue;
        const home = try helpers.tempHome(gpa);
        defer gpa.free(home);
        defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
        var env = std.process.Environ.Map.init(gpa);
        defer env.deinit();
        try env.put("HOME", home);
        var child = try std.process.spawn(io, .{
            .argv = &.{ paths.emulator, "serve", "--discover", "--stdio", peer_mod.image_path },
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        var running = true;
        defer if (running) child.kill(io);
        const path = try app.ctl.discovery.path(gpa, &env);
        defer gpa.free(path);
        const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 5000;
        while (true) {
            std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) return error.NoDiscovery;
                try io.sleep(.fromMilliseconds(10), .awake);
                continue;
            };
            break;
        }
        try ctl(gpa, &env, "gdb-address", true);
        if (@import("builtin").os.tag != .windows and signal) {
            try std.posix.kill(child.id.?, .TERM);
        } else {
            child.stdin.?.close(io);
            child.stdin = null;
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
        running = false;
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
        const socket = try std.fs.path.join(gpa, &.{ home, ".config", "ra8_emulator", "rpc.sock" });
        defer gpa.free(socket);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, socket, .{}));
    }
}
