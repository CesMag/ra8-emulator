//! ctl's view of the daemon's discovery file (RA8EMU-1155).
//! `serve --discover` publishes its per-user RPC address and loopback GDB
//! session port. No file, or no rpc line, means no discoverable daemon.
//!
//! `ctl sessions` lists the sessions; `ctl gdb-address [SESSION]` prints a
//! ready gdb target. With no running app both say to start ra8_emulator serve --discover first.
//! Nothing here talks to the app: the file is the whole story.
const std = @import("std");

/// One session line in the discovery file.
pub const Session = struct {
    /// The session's loopback gdb port.
    port: u16,
    /// The ELF the session was booted from, as the app wrote it.
    elf: []const u8,
};

/// What the discovery file said on the read. The rpc line and the
/// sessions' paths point into `text`.
pub const Snapshot = struct {
    /// The app's RPC address in `serve --listen` textual form.
    rpc: []const u8,
    sessions: []Session,
};

/// The discovery file's path: $HOME/.config/ra8_emulator/discovery (or
/// %USERPROFILE%\.config\ra8_emulator\discovery), the same place the app
/// writes it.
pub fn path(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".config", "ra8_emulator", "discovery" });
}

/// Read and parse the discovery file. null when no app is running.
pub fn read(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?Snapshot {
    const file_path = try path(allocator, env);
    defer allocator.free(file_path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var rpc: ?[]const u8 = null;
    var sessions: []Session = &.{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.trim(u8, line, " \r");
        if (std.mem.startsWith(u8, rest, "rpc ")) {
            rpc = std.mem.trim(u8, rest["rpc ".len..], " ");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "session ")) sessions = try parseSession(allocator, rest, sessions);
    }
    // announce writes the rpc line first, so a file without one is not
    // an app's file.
    if (rpc == null) {
        if (sessions.len > 0) allocator.free(sessions);
        allocator.free(text);
        return null;
    }
    return .{ .rpc = rpc.?, .sessions = sessions };
}

/// One `session PORT ELF` line; the ELF may contain spaces.
fn parseSession(allocator: std.mem.Allocator, line: []const u8, sessions: []Session) ![]Session {
    const rest = std.mem.trim(u8, line["session ".len..], " ");
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadDiscovery;
    const port = try std.fmt.parseInt(u16, rest[0..space], 10);
    var grown = try allocator.alloc(Session, sessions.len + 1);
    @memcpy(grown[0..sessions.len], sessions);
    grown[sessions.len] = .{ .port = port, .elf = std.mem.trim(u8, rest[space + 1 ..], " ") };
    return grown;
}

/// `ctl sessions` and `ctl gdb-address [SESSION] [--json]`. Both exit 1
/// with "start ra8_emulator serve --discover first" when the discovery file is missing.
pub fn run(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) !u8 {
    const command = argv[2];
    var json = false;
    var asked: ?[]const u8 = null;
    for (argv[3..]) |word| {
        if (std.mem.eql(u8, word, "--json")) json = true else asked = word;
    }
    const snapshot = read(allocator, io, env) catch null;
    if (snapshot == null) {
        try say(io, json, "start ra8_emulator serve --discover first");
        return 1;
    }
    if (std.mem.eql(u8, command, "sessions")) return list(io, json, snapshot.?);
    const session = pick(snapshot.?.sessions, asked) orelse {
        try say(io, json, "no such session");
        return 1;
    };
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    if (json) {
        try w.print("{{\"gdb\":\"127.0.0.1:{d}\",\"elf\":{f}}}\n", .{ session.port, std.json.fmt(session.elf, .{}) });
    } else try w.print("target extended-remote 127.0.0.1:{d}\n", .{session.port});
    try w.flush();
    return 0;
}

/// One line per session, the RPC address first.
fn list(io: std.Io, json: bool, snapshot: Snapshot) !u8 {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    if (json) {
        try w.print("{{\"rpc\":\"{s}\",\"sessions\":[", .{snapshot.rpc});
        for (snapshot.sessions, 0..) |session, at| {
            if (at > 0) try w.writeAll(",");
            try w.print("{{\"gdb\":\"127.0.0.1:{d}\",\"elf\":{f}}}", .{ session.port, std.json.fmt(session.elf, .{}) });
        }
        try w.writeAll("]}\n");
        try w.flush();
        return 0;
    }
    try w.print("ra8_emulator serve is running at {s}\n", .{snapshot.rpc});
    for (snapshot.sessions) |session| {
        try w.print("127.0.0.1:{d} {s}\n", .{ session.port, session.elf });
    }
    try w.flush();
    return 0;
}

/// The asked session: no argument means the first; a number means a
/// port, anything else a path equal to or ending the ELF.
fn pick(sessions: []const Session, asked: ?[]const u8) ?Session {
    if (asked == null) return if (sessions.len > 0) sessions[0] else null;
    const port = std.fmt.parseInt(u16, asked.?, 10) catch null;
    for (sessions) |session| {
        if (port != null and session.port == port.?) return session;
        if (std.mem.eql(u8, session.elf, asked.?) or std.mem.endsWith(u8, session.elf, asked.?)) return session;
    }
    return null;
}

fn say(io: std.Io, json: bool, text: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    if (json) {
        try w.print("{{\"error\":{f}}}\n", .{std.json.fmt(text, .{})});
    } else try w.print("{s}\n", .{text});
    try w.flush();
}
