//! `--trace-rtos-out FILE`: the RTOS trace as a text file, and the reader
//! that takes it back (RA8EMU-345).
//!
//! Plain text so a trace diffs and greps with no tooling. A version header,
//! then one event per line, oldest first, then the count of events the
//! trace dropped past its cap:
//!
//!     # ra8 rtos trace v1
//!     1200 cpu0 switch 0x220010F0
//!     1350 cpu0 enter 14
//!     1360 cpu0 leave 14
//!     1400 cpu0 idle
//!     # dropped 0
//!
//! CPU0's tracer writes PATH and CPU1's writes PATH.cpu1, so the two cores
//! never race on one file.
const std = @import("std");
const rtos_trace = @import("trace.zig");

const Event = rtos_trace.Event;

pub const header = "# ra8 rtos trace v1";
const trailer = "# dropped ";

pub const Error = error{ BadHeader, BadLine, TooMany, Truncated };

/// What `read` took back: the events, in the caller's buffer, and the count
/// the trace dropped.
pub const Loaded = struct {
    events: []const Event,
    dropped: usize,
};

/// The whole trace, header to trailer.
pub fn write(out: anytype, trace: *const rtos_trace.Trace) !void {
    try out.print("{s}\n", .{header});
    for (trace.list()) |one| try line(out, one);
    try out.print("{s}{d}\n", .{ trailer, trace.dropped });
}

fn line(out: anytype, one: Event) !void {
    try out.print("{d} cpu{d} ", .{ one.when, one.core });
    switch (one.kind) {
        .switch_to => try out.print("switch 0x{X:0>8}\n", .{one.thread}),
        .idle => try out.print("idle\n", .{}),
        .enter => try out.print("enter {d}\n", .{one.exception}),
        .leave => try out.print("leave {d}\n", .{one.exception}),
    }
}

/// The file's name for `core`: PATH for CPU0, PATH.cpu1 for CPU1.
pub fn nameFor(path: []const u8, core: u1, buffer: []u8) ![]const u8 {
    if (core == 0) return path;
    return std.fmt.bufPrint(buffer, "{s}.cpu1", .{path});
}

/// Write `trace` to the file `nameFor` gives, replacing what was there.
pub fn save(io: std.Io, path: []const u8, core: u1, trace: *const rtos_trace.Trace) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try nameFor(path, core, &buffer);
    const file = try std.Io.Dir.cwd().createFile(io, name, .{});
    defer file.close(io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(io, &staging);
    try write(&writer.interface, trace);
    try writer.interface.flush();
}

/// Take a written trace back into `into`. Anything after the trailer, a
/// missing trailer, or a line that is not one event is refused.
pub fn read(text: []const u8, into: []Event) Error!Loaded {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return error.BadHeader;
    if (!std.mem.eql(u8, first, header)) return error.BadHeader;
    var count: usize = 0;
    var dropped: ?usize = null;
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        if (dropped != null) return error.BadLine;
        if (std.mem.startsWith(u8, raw, trailer)) {
            dropped = std.fmt.parseInt(usize, raw[trailer.len..], 10) catch return error.BadLine;
            continue;
        }
        if (count == into.len) return error.TooMany;
        into[count] = try parse(raw);
        count += 1;
    }
    return .{ .events = into[0..count], .dropped = dropped orelse return error.Truncated };
}

/// One event line: `<when> cpu<core> <kind> [<value>]`.
fn parse(raw: []const u8) Error!Event {
    var words = std.mem.tokenizeScalar(u8, raw, ' ');
    const when = number(u64, words.next(), 10) catch return error.BadLine;
    const core = try coreOf(words.next() orelse return error.BadLine);
    const kind = words.next() orelse return error.BadLine;
    var one = Event{ .when = when, .core = core, .kind = .idle };
    if (std.mem.eql(u8, kind, "switch")) {
        const text = words.next() orelse return error.BadLine;
        if (!std.mem.startsWith(u8, text, "0x")) return error.BadLine;
        one.kind = .switch_to;
        one.thread = number(u32, text[2..], 16) catch return error.BadLine;
    } else if (std.mem.eql(u8, kind, "enter") or std.mem.eql(u8, kind, "leave")) {
        one.kind = if (kind[0] == 'e') .enter else .leave;
        one.exception = number(u16, words.next(), 10) catch return error.BadLine;
    } else if (!std.mem.eql(u8, kind, "idle")) {
        return error.BadLine;
    }
    if (words.next() != null) return error.BadLine;
    return one;
}

fn coreOf(word: []const u8) Error!u1 {
    if (std.mem.eql(u8, word, "cpu0")) return 0;
    if (std.mem.eql(u8, word, "cpu1")) return 1;
    return error.BadLine;
}

fn number(comptime T: type, word: ?[]const u8, base: u8) !T {
    return std.fmt.parseInt(T, word orelse return error.BadLine, base);
}
