//! Spawns `ra8_emulator serve --listen` on a Unix path and on an
//! ephemeral localhost TCP port and drives a session over each (RA8EMU-736).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const test_paths = @import("test_paths");
const Connection = ra8.rpc.socket_transport.Connection;
const serve_peer = @import("../serve_peer.zig");
const image_path = serve_peer.image_path;
const Term = std.process.Child.Term;
const on_windows = @import("builtin").os.tag == .windows;
const win32 = ra8.host.win32;

/// A hidden console belongs only to this child, so Ctrl+Break cannot reach
/// the build runner or another application. The std spawn API lacks this flag.
fn listen(spec: []const u8, line: []u8) !serve_peer.Listening {
    if (!on_windows) return serve_peer.listen(spec, line);
    const gpa = std.testing.allocator;
    const command = try std.fmt.allocPrint(gpa, "\"{s}\" serve --listen \"{s}\" \"{s}\"", .{ test_paths.emulator, spec, image_path });
    defer gpa.free(command);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, command);
    defer gpa.free(wide);
    const ends = try ra8.host.pipe_pair.create(.{});
    errdefer ra8.host.read.close(ends[0]);
    defer ra8.host.read.close(ends[1]);
    try std.testing.expect(win32.SetHandleInformation(ends[1], 1, 1).toBool());
    var startup: std.os.windows.STARTUPINFOW = std.mem.zeroes(std.os.windows.STARTUPINFOW);
    startup.cb = @sizeOf(@TypeOf(startup));
    startup.dwFlags = std.os.windows.STARTF_USESTDHANDLES | std.os.windows.STARTF_USESHOWWINDOW;
    startup.wShowWindow = 0;
    startup.hStdError = ends[1];
    var info: win32.ProcessInfo = undefined;
    try std.testing.expect(win32.CreateProcessW(null, wide, null, null, .TRUE, @bitCast(std.os.windows.CreateProcessFlags{ .create_new_console = true, .create_new_process_group = true }), null, null, &startup, &info).toBool());
    var child: std.process.Child = .{ .id = info.process, .thread_handle = info.thread, .stdin = null, .stdout = null, .stderr = .{ .handle = ends[0], .flags = .{ .nonblocking = false } }, .request_resource_usage_statistics = false };
    errdefer child.kill(std.testing.io);
    const prefix = "serve: listening on ";
    var at: usize = 0;
    while (true) {
        var one: [1]u8 = undefined;
        var slices = [_][]u8{&one};
        if (try child.stderr.?.readStreaming(std.testing.io, &slices) == 0) return error.EndOfStream;
        if (one[0] == '\n') {
            if (std.mem.startsWith(u8, line[0..at], prefix)) return .{ .child = child, .bound = line[prefix.len..at] };
            at = 0;
            continue;
        }
        if (at == line.len) return error.LineTooLong;
        line[at] = one[0];
        at += 1;
    }
}

/// Stop serve: `signal` on POSIX; Windows has only the console Ctrl+Break event.
fn stop(child: *std.process.Child, signal: std.posix.SIG) !void {
    if (!on_windows) return std.posix.kill(child.id.?, signal);
    const pid = win32.GetProcessId(child.id.?);
    try std.testing.expect(pid != 0);
    _ = win32.FreeConsole();
    try std.testing.expect(win32.AttachConsole(pid).toBool());
    defer {
        _ = win32.FreeConsole();
        _ = win32.AttachConsole(std.math.maxInt(u32));
    }
    try std.testing.expect(win32.GenerateConsoleCtrlEvent(1, pid).toBool());
}

/// Drive one session over `connection`, hang up, then stop serve with SIGTERM.
fn session(gpa: std.mem.Allocator, child: *std.process.Child, connection: *Connection) !void {
    return sessionStoppedBy(gpa, child, connection, .TERM);
}

/// Drive one session over `connection`, hang up, then stop serve with `signal`.
fn sessionStoppedBy(gpa: std.mem.Allocator, child: *std.process.Child, connection: *Connection, signal: std.posix.SIG) !void {
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.drive();
    connection.close();
    try stop(child, signal);
    try std.testing.expectEqual(Term{ .exited = 0 }, try child.wait(std.testing.io));
}

test "serve --listen tcp::0 binds localhost, serves a client and exits 0 on SIGTERM" {
    const gpa = std.testing.allocator;
    var line: [128]u8 = undefined;
    var started = try listen("tcp::0", &line);
    errdefer started.child.kill(std.testing.io);
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
    const path = try serve_peer.socketPath(gpa, &tmp.sub_path, "serve.sock");
    defer gpa.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var started = try listen(spec, &line);
    errdefer started.child.kill(std.testing.io);
    try std.testing.expectEqualStrings(spec, started.bound);
    var connection = try Connection.unix(std.testing.io, path);
    try session(gpa, &started.child, &connection);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
}

test "serve --listen unix:PATH exits 0 and removes the path on SIGHUP and SIGQUIT" {
    if (on_windows) return error.SkipZigTest; // POSIX signals do not exist on Windows
    const gpa = std.testing.allocator;
    for ([_]std.posix.SIG{ .HUP, .QUIT }) |signal| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try serve_peer.socketPath(gpa, &tmp.sub_path, "serve.sock");
        defer gpa.free(path);
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
        defer gpa.free(spec);
        var line: [256]u8 = undefined;
        var started = try listen(spec, &line);
        errdefer started.child.kill(std.testing.io);
        var connection = try Connection.unix(std.testing.io, path);
        try sessionStoppedBy(gpa, &started.child, &connection, signal);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
    }
}

test "serve --listen tcp::0 exits 0 on SIGHUP and SIGQUIT" {
    if (on_windows) return error.SkipZigTest; // POSIX signals do not exist on Windows
    const gpa = std.testing.allocator;
    for ([_]std.posix.SIG{ .HUP, .QUIT }) |signal| {
        var line: [128]u8 = undefined;
        var started = try listen("tcp::0", &line);
        errdefer started.child.kill(std.testing.io);
        const colon = std.mem.lastIndexOfScalar(u8, started.bound, ':').?;
        const port = try std.fmt.parseInt(u16, started.bound[colon + 1 ..], 10);
        var connection = try Connection.tcp(std.testing.io, try std.Io.net.IpAddress.parse("127.0.0.1", port));
        try sessionStoppedBy(gpa, &started.child, &connection, signal);
    }
}

fn logSize(root: std.Io.Dir) !u64 {
    var dir = try root.openDir(std.testing.io, "history", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var entries = dir.iterate();
    while (try entries.next(std.testing.io)) |entry| {
        if (entry.kind != .directory) continue;
        var path: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&path, "{s}/log/events-0", .{entry.name});
        return (try dir.statFile(std.testing.io, name, .{})).size;
    }
    return error.NoHistorySession;
}

test "idle listener commits staged console input after its last client disconnects" {
    if (on_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const root = try std.fs.path.join(gpa, &.{ base, "history" });
    defer gpa.free(root);
    const path = try serve_peer.socketPath(gpa, &tmp.sub_path, "idle.sock");
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var started = try serve_peer.listenArgs(&.{ test_paths.emulator, "serve", "--history", root, "--kept", "--listen", spec, "tests/fixtures/gpio/blink.elf" }, &line);
    errdefer started.child.kill(io);
    var connection = try Connection.unix(io, path);
    var connected = true;
    defer if (connected) connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    const proto = ra8.rpc.session.rpc;
    try peer.client.greet(peer.tx);
    _ = try peer.next();
    _ = try peer.call(proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
    const before = try logSize(tmp.dir);
    _ = try peer.call(proto.Ack, ra8.rpc.session.intervene.ConsoleInput, .console_input, .{ .core = .cpu0, .bytes = "idle input" });
    connection.close();
    connected = false;
    const end = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 5000;
    while (try logSize(tmp.dir) == before) {
        if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= end) return error.HistoryDeadlineMissed;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try stop(&started.child, .TERM);
    try std.testing.expectEqual(Term{ .exited = 0 }, try started.child.wait(io));
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
        try std.testing.expectEqualStrings(cli_app.serve.main.usage, result.stderr);
    }
}

test "listen specs: an empty host and localhost bind loopback, a bracketed v6 literal parses" {
    const Spec = cli_app.serve.listen.Spec;
    const loopback = try std.Io.net.IpAddress.parse("127.0.0.1", 7000);
    try std.testing.expect((try Spec.parse("tcp::7000")).tcp.eql(&loopback));
    try std.testing.expect((try Spec.parse("tcp:localhost:7000")).tcp.eql(&loopback));
    try std.testing.expect((try Spec.parse("tcp:[::1]:7000")).tcp.eql(&(try std.Io.net.IpAddress.parse("::1", 7000))));
    try std.testing.expectEqualStrings("/tmp/s", (try Spec.parse("unix:/tmp/s")).unix);
    try std.testing.expectError(error.BadListen, Spec.parse("tcp::70000"));
}

/// A state hook that counts the host-file calls it receives.
const CountingState = struct {
    saves: usize = 0,
    restores: usize = 0,
    path: ?[]const u8 = null,

    fn hook(self: *CountingState) ra8.session.board.state.Hook {
        return .{ .context = self, .saveFn = save, .restoreFn = restore };
    }

    fn save(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *CountingState = @ptrCast(@alignCast(context));
        self.saves += 1;
        self.path = path;
    }

    fn restore(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *CountingState = @ptrCast(@alignCast(context));
        self.restores += 1;
        self.path = path;
    }
};

/// The state hook a serve on `text` keeps, by the policy serve/main.zig applies.
fn keptState(text: []const u8, allow: bool, counting: *CountingState) !?ra8.session.board.state.Hook {
    const spec = try cli_app.serve.listen.Spec.parse(text);
    return if (cli_app.serve.listen.allowsState(spec, allow)) counting.hook() else null;
}

test "snapshot and restore are refused on non-loopback TCP listeners without host-file calls (RA8EMU-1175)" {
    const files = ra8.rpc.session.files;
    const refused: u16 = ra8.rpc.session.server.app_codes.refused;
    var scratch: [64]u8 = undefined;
    for ([_][]const u8{ "tcp:0.0.0.0:7000", "tcp:[::]:7000", "tcp:192.0.2.1:7000" }) |text| {
        var counting: CountingState = .{};
        var context: ra8.rpc.session.server.Context = .{ .session = undefined, .scratch = &scratch, .state = try keptState(text, false, &counting) };
        try std.testing.expect(context.state == null);
        const args: ra8.rpc.session.rpc.StatePath = .{ .path = "x.ra8snap" };
        const snapshot = files.snapshot(&context, args);
        try std.testing.expect(snapshot == .err);
        try std.testing.expectEqual(refused, @backingInt(snapshot.err));
        const restore = files.restore(&context, args);
        try std.testing.expect(restore == .err);
        try std.testing.expectEqual(refused, @backingInt(restore.err));
        try std.testing.expectEqual(@as(usize, 0), counting.saves);
        try std.testing.expectEqual(@as(usize, 0), counting.restores);
        try std.testing.expect(counting.path == null);
    }
}

test "snapshot and restore reach host hooks on loopback, unix and explicit override listeners (RA8EMU-1175)" {
    var scratch: [64]u8 = undefined;
    const cases = [_]struct { []const u8, bool }{ .{ "tcp::7000", false }, .{ "tcp:localhost:7000", false }, .{ "tcp:127.0.0.2:7000", false }, .{ "tcp:[::1]:7000", false }, .{ "unix:/tmp/s", false }, .{ "tcp:0.0.0.0:7000", true }, .{ "tcp:[::]:7000", true }, .{ "tcp:192.0.2.1:7000", true } };
    for (cases) |case| {
        var counting: CountingState = .{};
        var context: ra8.rpc.session.server.Context = .{ .session = undefined, .scratch = &scratch, .state = try keptState(case[0], case[1], &counting) };
        try std.testing.expect(context.state != null);
        try std.testing.expect(ra8.rpc.session.files.snapshot(&context, .{ .path = "save.ra8snap" }) == .ok);
        try std.testing.expectEqual(@as(usize, 1), counting.saves);
        try std.testing.expectEqual(@as(usize, 0), counting.restores);
        try std.testing.expectEqualStrings("save.ra8snap", counting.path.?);
        try std.testing.expect(ra8.rpc.session.files.restore(&context, .{ .path = "restore.ra8snap" }) == .ok);
        try std.testing.expectEqual(@as(usize, 1), counting.saves);
        try std.testing.expectEqual(@as(usize, 1), counting.restores);
        try std.testing.expectEqualStrings("restore.ra8snap", counting.path.?);
    }
}
