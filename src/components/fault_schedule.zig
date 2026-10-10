//! A `--faults FILE` schedule (RA8EMU-207): hardware changes at virtual
//! times, so an unattended soak run can lose and regain parts on cue.
//!
//! One event per line, `AT ACTION ENDPOINT [ARG]`:
//!
//!     3d12h      unplug i2c:riic@0x36
//!     3d12h05m   plug   i2c:riic@0x36 max17048
//!     90s        fault  spi:spi1@ssl0 stuck:0xFF
//!     95s        clear  spi:spi1@ssl0
//!
//! AT is a virtual time: whole numbers each followed by a unit, biggest
//! unit first, each unit at most once (d, h, m, s, ms, us, ns). ACTION is
//! `fault MODE` (the `--fault` modes), `clear`, `unplug`, or `plug NAME`.
//! Blank lines and `#` comments are skipped. Times never go backwards, so
//! the file reads in the order it runs; two events may share a time and
//! then run in file order.
//!
//! Everything a run could refuse is refused here instead: an unknown part,
//! a part on the wrong kind of endpoint, a mode the bus cannot do. Errors
//! carry the 1-based line through `Diagnostic`. Plug names are borrowed
//! from the text, so the text has to outlive the schedule.
const std = @import("std");
const catalog = @import("catalog.zig");
const endpoint = @import("endpoint.zig");
const fault_spec = @import("fault_spec.zig");
const parts = @import("parts.zig");
const timebase = @import("ra8_chip").periph.timebase;

pub const Action = union(enum) {
    fault: fault_spec.Mode,
    clear,
    unplug,
    plug: []const u8,
};

pub const Event = struct {
    at_ns: u64,
    target: endpoint.Endpoint,
    action: Action,
    line: u32,
};

pub const Schedule = struct {
    events: []Event,

    pub fn deinit(self: Schedule, gpa: std.mem.Allocator) void {
        gpa.free(self.events);
    }
};

/// Where a parse failed; zero until it does.
pub const Diagnostic = struct {
    line: u32 = 0,
};

pub const Error = error{
    BadTime,
    UnknownAction,
    MissingField,
    ExtraField,
    TimeBackwards,
    WrongBus,
} || endpoint.Error || fault_spec.Error || catalog.Error;

const Unit = struct { name: []const u8, ns: u64 };

const units = [_]Unit{
    .{ .name = "d", .ns = 86_400 * timebase.ns_per_s },
    .{ .name = "h", .ns = 3_600 * timebase.ns_per_s },
    .{ .name = "m", .ns = 60 * timebase.ns_per_s },
    .{ .name = "s", .ns = timebase.ns_per_s },
    .{ .name = "ms", .ns = 1_000_000 },
    .{ .name = "us", .ns = 1_000 },
    .{ .name = "ns", .ns = 1 },
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8, diag: *Diagnostic) Error!Schedule {
    var events: std.ArrayList(Event) = .empty;
    errdefer events.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: u32 = 0;
    var last_ns: u64 = 0;
    while (lines.next()) |line| {
        number += 1;
        diag.line = number;
        const event = try parseLine(line) orelse continue;
        if (event.at_ns < last_ns) return Error.TimeBackwards;
        last_ns = event.at_ns;
        try events.append(gpa, .{
            .at_ns = event.at_ns,
            .target = event.target,
            .action = event.action,
            .line = number,
        });
    }
    diag.line = 0;
    return .{ .events = try events.toOwnedSlice(gpa) };
}

const Parsed = struct {
    at_ns: u64,
    target: endpoint.Endpoint,
    action: Action,
};

/// One line's event, or null for a blank or comment-only line.
fn parseLine(line: []const u8) Error!?Parsed {
    const body = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
    var words = std.mem.tokenizeAny(u8, body, " \t\r");
    const at_word = words.next() orelse return null;
    const at_ns = try parseTime(at_word);
    const verb = words.next() orelse return Error.MissingField;
    const where = words.next() orelse return Error.MissingField;
    const target = try endpoint.parse(where);
    const arg = words.next();
    if (words.next() != null) return Error.ExtraField;
    return .{ .at_ns = at_ns, .target = target, .action = try parseAction(verb, target, arg) };
}

fn parseAction(verb: []const u8, target: endpoint.Endpoint, arg: ?[]const u8) Error!Action {
    if (std.mem.eql(u8, verb, "fault")) {
        const mode = try fault_spec.parseMode(arg orelse return Error.MissingField);
        if (!fits(mode, target.kind())) return Error.WrongBus;
        return .{ .fault = mode };
    }
    if (std.mem.eql(u8, verb, "clear")) {
        if (arg != null) return Error.ExtraField;
        if (target.kind() == .gpio) return Error.WrongBus;
        return .clear;
    }
    if (std.mem.eql(u8, verb, "unplug")) {
        if (arg != null) return Error.ExtraField;
        return .unplug;
    }
    if (std.mem.eql(u8, verb, "plug")) {
        const name = arg orelse return Error.MissingField;
        const model = parts.all.find(name) orelse return Error.UnknownModel;
        if (model.kind != target.kind()) return Error.WrongEndpoint;
        return .{ .plug = name };
    }
    return Error.UnknownAction;
}

/// The `fault_spec.fits` rule by endpoint kind, since no part is made yet.
fn fits(mode: fault_spec.Mode, kind: endpoint.Kind) bool {
    return switch (kind) {
        .i2c => true,
        .spi, .uart => switch (mode) {
            .disconnected, .stuck, .garbage => true,
            else => false,
        },
        .gpio => false,
    };
}

/// A virtual time such as `3d12h05m`, `90s` or `250ms`, in nanoseconds.
pub fn parseTime(text: []const u8) Error!u64 {
    if (text.len == 0) return Error.BadTime;
    var rest = text;
    var total: u64 = 0;
    var next_unit: usize = 0;
    while (rest.len != 0) {
        const digits = run(rest, std.ascii.isDigit);
        if (digits == 0) return Error.BadTime;
        const value = std.fmt.parseInt(u64, rest[0..digits], 10) catch return Error.BadTime;
        rest = rest[digits..];
        const letters = run(rest, std.ascii.isAlphabetic);
        const unit = try unitAfter(rest[0..letters], next_unit);
        rest = rest[letters..];
        next_unit = unit + 1;
        const part = std.math.mul(u64, value, units[unit].ns) catch return Error.BadTime;
        total = std.math.add(u64, total, part) catch return Error.BadTime;
    }
    return total;
}

/// The unit called `word`, only if it is smaller than the last one used.
fn unitAfter(word: []const u8, from: usize) Error!usize {
    for (units[from..], from..) |unit, index| {
        if (std.mem.eql(u8, unit.name, word)) return index;
    }
    return Error.BadTime;
}

fn run(text: []const u8, comptime keep: fn (u8) bool) usize {
    for (text, 0..) |c, index| {
        if (!keep(c)) return index;
    }
    return text.len;
}
