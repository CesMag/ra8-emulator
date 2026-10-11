//! The remote protocol's run control and threads on the Zig core
//! (RA8EMU-118).
//!
//! Each core is a thread: CPU0 is thread 1 and, with CPU1 attached
//! (RA8EMU-338), CPU1 is thread 2. `Hg`, `Hc` and a vCont action's thread
//! give the session to that core, so `g`, `m`, `s` and `c` act on it while
//! the other holds where it stopped (all-stop, scheduler locked). `c` runs budget
//! after budget, asking the poll between them whether gdb sent an
//! interrupt, and `s` runs one instruction. The stop replies are the same
//! as gdb expects: `T05` for a break or a step, `T05watch:` and friends
//! for a watch, `T02` for an interrupt and `T0b` when the core faulted.
const std = @import("std");
const debug_session = @import("ra8_session").session;
const watch_table = @import("ra8_session").watch.table;
const zig_drive = @import("ra8_session").zig.drive;
const session_api = @import("ra8_session").api;

pub const Error = error{NoSpace};

const request_error = "E00";
const vcont_actions = "vCont;c;C;s;S";
const sigint: u8 = 0x02;
const sigtrap: u8 = 0x05;
const sigsegv: u8 = 0x0b;

/// The Zig session gdb drives, with why it last stopped.
pub const Target = struct {
    session: *session_api.Session,
    /// Asked between budgets while a continue runs; null runs one budget.
    poll: ?debug_session.Poll = null,
    last: ?zig_drive.Ended = null,
    /// Pump mode (RA8EMU-1156): a resume runs one budget per pump and
    /// sends no reply while it still runs, so the pump's host (the GUI
    /// loop) keeps painting and serves its other clients between budgets.
    pump: bool = false,
    /// True while a pumped continue has run budgets but not stopped yet.
    pending: bool = false,
};

/// Whether `request` is one this file answers.
pub fn handles(request: []const u8) bool {
    if (request.len == 0) return false;
    if (std.mem.startsWith(u8, request, "vCont")) return true;
    if (std.mem.eql(u8, request, "qfThreadInfo") or std.mem.eql(u8, request, "qsThreadInfo")) return true;
    if (std.mem.eql(u8, request, "qC")) return true;
    return switch (request[0]) {
        'c', 's', '?', 'H', 'T' => true,
        else => false,
    };
}

/// The reply to a run-control or thread request (`handles` says which).
pub fn answer(target: *Target, request: []const u8, out: []u8) Error![]const u8 {
    if (std.mem.eql(u8, request, "vCont?")) return copy(out, vcont_actions);
    if (std.mem.startsWith(u8, request, "vCont;")) return vcont(target, request["vCont;".len..], out);
    if (std.mem.eql(u8, request, "qfThreadInfo")) return copy(out, if (!target.session.hasCore(.cpu1)) "m1" else "m1,2");
    if (std.mem.eql(u8, request, "qsThreadInfo")) return copy(out, "l");
    if (std.mem.eql(u8, request, "qC")) return print(out, "QC{d}", .{thread(target)});
    return switch (request[0]) {
        'c' => resume_(target, .cont, out),
        's' => resume_(target, .step, out),
        '?' => stopReply(target, out),
        'H' => copy(out, if (request.len > 1 and select(target, request[2..])) "OK" else request_error),
        'T' => copy(out, if (alive(target, request[1..])) "OK" else request_error),
        else => out[0..0],
    };
}

/// Only the first action matters: one core runs at a time, and a thread
/// on it selects that core first.
fn vcont(target: *Target, actions: []const u8, out: []u8) Error![]const u8 {
    const first = actions[0 .. std.mem.indexOfScalar(u8, actions, ';') orelse actions.len];
    if (first.len == 0) return copy(out, request_error);
    if (std.mem.indexOfScalar(u8, first, ':')) |colon| {
        if (!select(target, first[colon + 1 ..])) return copy(out, request_error);
    }
    return switch (first[0]) {
        'c', 'C' => resume_(target, .cont, out),
        's', 'S' => resume_(target, .step, out),
        else => copy(out, request_error),
    };
}

fn resume_(target: *Target, command: session_api.Run, out: []u8) Error![]const u8 {
    if (target.pump) return pumpResume(target, command, out);
    var ended = target.session.run(target.session.currentCore(), command) catch return copy(out, request_error);
    while (command == .cont and ended == .count) {
        const poll = target.poll orelse break;
        if (poll.check(poll.context)) {
            const stopped = target.session.interrupt(target.session.currentCore()) catch return copy(out, request_error);
            ended = .{ .stop = stopped };
            break;
        }
        ended = target.session.run(target.session.currentCore(), .cont) catch return copy(out, request_error);
    }
    target.last = ended;
    return stopReply(target, out);
}

/// Why the core last stopped, as gdb reads it.
fn stopReply(target: *Target, out: []u8) Error![]const u8 {
    const ended = target.last orelse return reply(target, out, sigtrap);
    return switch (ended) {
        .count => reply(target, out, sigtrap),
        .core => reply(target, out, sigsegv),
        .stop => |stop| switch (stop) {
            .watchpoint => |hit| print(out, "T{x:0>2}{s}:{x:0>8};thread:{d};", .{
                sigtrap, watchName(target, hit), hit.address, thread(target),
            }),
            .halt_requested => reply(target, out, sigint),
            else => reply(target, out, sigtrap),
        },
    };
}

/// gdb names a watch by what it was set to catch, so the kind comes from
/// the table when the watch is still there.
fn watchName(target: *Target, hit: watch_table.Hit) []const u8 {
    const kind = (target.session.watchKind(target.session.currentCore(), hit.id) catch null) orelse switch (hit.access) {
        .read => watch_table.Kind.read,
        .write => watch_table.Kind.write,
    };
    return switch (kind) {
        .write => "watch",
        .read => "rwatch",
        .access => "awatch",
    };
}

/// The selected core's thread id: CPU0 is 1, CPU1 is 2.
fn thread(target: *const Target) u32 {
    return @as(u32, @backingInt(target.session.currentCore())) + 1;
}

/// Thread `0` and `-1` mean any thread, so the selected one stands.
fn anyThread(text: []const u8) bool {
    return std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "-1");
}

/// Thread 1 is always there; thread 2 only with CPU1 attached.
fn alive(target: *const Target, text: []const u8) bool {
    if (anyThread(text)) return true;
    const id = std.fmt.parseInt(u32, text, 16) catch return false;
    return id == 1 or (id == 2 and target.session.hasCore(.cpu1));
}

/// Give the session to the core behind thread `text`; false when there is none.
fn select(target: *Target, text: []const u8) bool {
    if (!alive(target, text)) return false;
    if (anyThread(text)) return true;
    const id = std.fmt.parseInt(u8, text, 16) catch return false;
    target.session.switchTo(@fromBackingInt(@intCast(id - 1))) catch return false;
    return true;
}

fn reply(target: *const Target, out: []u8, signal: u8) Error![]const u8 {
    return print(out, "T{x:0>2}thread:{d};", .{ signal, thread(target) });
}

fn print(out: []u8, comptime format: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.bufPrint(out, format, args) catch Error.NoSpace;
}

fn copy(out: []u8, text: []const u8) Error![]const u8 {
    if (text.len > out.len) return Error.NoSpace;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}
/// A pumped resume: one budget now, and the stop reply only once the run
/// has ended. gdb waits for the stop reply, so an empty payload here means
/// "nothing to send this frame" and the pump sends nothing.
fn pumpResume(target: *Target, command: session_api.Run, out: []u8) Error![]const u8 {
    if (target.pending) return out[0..0];
    const ended = target.session.run(target.session.currentCore(), command) catch return copy(out, request_error);
    if (command == .cont and ended == .count) {
        target.pending = true;
        return out[0..0];
    }
    target.last = ended;
    return stopReply(target, out);
}

/// Keep a pumped continue going: one more budget, an interrupt check, and
/// the stop reply once the run ends. Empty payload while still running.
pub fn pumpTick(target: *Target, out: []u8) Error![]const u8 {
    if (!target.pending) return out[0..0];
    const ended = target.session.run(target.session.currentCore(), .cont) catch {
        target.pending = false;
        return copy(out, request_error);
    };
    if (ended == .count) {
        const poll = target.poll orelse return out[0..0];
        if (poll.check(poll.context)) {
            const stopped = target.session.interrupt(target.session.currentCore()) catch return copy(out, request_error);
            target.pending = false;
            target.last = .{ .stop = stopped };
            return stopReply(target, out);
        }
        return out[0..0];
    }
    target.pending = false;
    target.last = ended;
    return stopReply(target, out);
}
