//! The remote protocol's breakpoint and watchpoint requests, `Z` to set
//! and `z` to clear, answered against one core's stop machine.
//!
//! `Z0` and `Z1` (software and hardware breaks) are the same thing here:
//! an address execution stops at, kept in the break table. `Z2`, `Z3` and
//! `Z4` are write, read and access watchpoints over `length` bytes, kept
//! in the watch table. The requests are `Ztype,address,length`.
const std = @import("std");
const stop_machine = @import("ra8_session").stop_machine;
const watch_table = @import("ra8_session").watch_table;

pub const Error = error{NoSpace};

const request_error = "E00";
const table_full = "E0E";

const Request = struct {
    kind: u8,
    address: u32,
    length: u32,
};

/// The reply to a `Z` or `z` request. A type this stub does not know gets
/// the empty reply so gdb falls back.
pub fn answer(machine: *stop_machine.Machine, request: []const u8, out: []u8) Error![]const u8 {
    const parsed = parse(request) orelse return copy(out, request_error);
    const set = request[0] == 'Z';
    return switch (parsed.kind) {
        '0', '1' => if (set) addBreak(machine, parsed, out) else removeBreak(machine, parsed, out),
        '2', '3', '4' => if (set) addWatch(machine, parsed, out) else removeWatch(machine, parsed, out),
        else => out[0..0],
    };
}

fn parse(request: []const u8) ?Request {
    if (request.len < 2) return null;
    var fields = std.mem.splitScalar(u8, request[1..], ',');
    const kind = fields.next() orelse return null;
    const address = fields.next() orelse return null;
    const length = fields.next() orelse return null;
    if (kind.len != 1) return null;
    const end = std.mem.indexOfScalar(u8, length, ';') orelse length.len;
    return .{
        .kind = kind[0],
        .address = std.fmt.parseInt(u32, address, 16) catch return null,
        .length = std.fmt.parseInt(u32, length[0..end], 16) catch return null,
    };
}

/// gdb re-inserts its breaks on every resume, so a second set on the same
/// address is already true and answered OK.
fn addBreak(machine: *stop_machine.Machine, request: Request, out: []u8) Error![]const u8 {
    _ = machine.addBreak(.{ .address = request.address }) catch |err| return switch (err) {
        error.AlreadySet => copy(out, "OK"),
        error.TableFull => copy(out, table_full),
        error.NoSuchBreak => copy(out, request_error),
    };
    return copy(out, "OK");
}

fn removeBreak(machine: *stop_machine.Machine, request: Request, out: []u8) Error![]const u8 {
    const id = machine.breaks.find(request.address) orelse return copy(out, request_error);
    machine.breaks.remove(id) catch return copy(out, request_error);
    return copy(out, "OK");
}

fn addWatch(machine: *stop_machine.Machine, request: Request, out: []u8) Error![]const u8 {
    const span = watch_table.Watch.span(request.address, request.length, kindOf(request.kind)) catch return copy(out, request_error);
    _ = machine.addWatch(span) catch return copy(out, table_full);
    return copy(out, "OK");
}

fn removeWatch(machine: *stop_machine.Machine, request: Request, out: []u8) Error![]const u8 {
    const span = watch_table.Watch.span(request.address, request.length, kindOf(request.kind)) catch return copy(out, request_error);
    for (machine.watches.entries()) |slot| {
        if (slot.watch.first != span.first or slot.watch.last != span.last or slot.watch.kind != span.kind) continue;
        machine.watches.remove(slot.id) catch return copy(out, request_error);
        return copy(out, "OK");
    }
    return copy(out, request_error);
}

fn kindOf(kind: u8) watch_table.Kind {
    return switch (kind) {
        '2' => .write,
        '3' => .read,
        else => .access,
    };
}

fn copy(out: []u8, text: []const u8) Error![]const u8 {
    if (text.len > out.len) return Error.NoSpace;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}
