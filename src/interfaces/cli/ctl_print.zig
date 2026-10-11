//! What `ctl` prints for each answer (RA8EMU-747): one JSON object per
//! line with --json, one plain line without. Errors under --json go to
//! stdout too, so an agent reads a single stream.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;

pub const Reg = struct { register: proto.Register, value: u32 };

pub fn loaded(w: anytype, json: bool, path: []const u8, bytes: usize) !void {
    if (json) return w.print("{{\"loaded\":{f},\"bytes\":{d}}}\n", .{ std.json.fmt(path, .{}), bytes });
    try w.print("loaded {s} ({d} bytes)\n", .{ path, bytes });
}

pub fn stopped(w: anytype, json: bool, stop: proto.Stopped) !void {
    const core = @tagName(stop.core);
    const reason = @tagName(stop.reason);
    if (json) return w.print(
        "{{\"stopped\":{{\"core\":\"{s}\",\"reason\":\"{s}\",\"pc\":{d},\"detail\":{d}}}}}\n",
        .{ core, reason, stop.address, stop.detail },
    );
    try w.print("{s} stopped: {s} at 0x{x:0>8}\n", .{ core, reason, stop.address });
}

pub fn advanced(w: anytype, json: bool, moved: proto.Advanced) !void {
    const core = @tagName(moved.core);
    const reason = @tagName(moved.reason);
    if (json) return w.print(
        "{{\"advanced\":{{\"core\":\"{s}\",\"from_ns\":{d},\"to_ns\":{d},\"reason\":\"{s}\",\"pc\":{d}}}}}\n",
        .{ core, moved.from_ns, moved.to_ns, reason, moved.address },
    );
    try w.print("{s} advanced {d} ns to {d} ns: {s} at 0x{x:0>8}\n", .{ core, moved.to_ns - moved.from_ns, moved.to_ns, reason, moved.address });
}

pub fn paused(w: anytype, json: bool) !void {
    try w.writeAll(if (json) "{\"paused\":true}\n" else "paused\n");
}

pub fn registers(w: anytype, json: bool, regs: []const Reg) !void {
    if (json) try w.writeAll("{\"registers\":{");
    for (regs, 0..) |reg, index| {
        const name = @tagName(reg.register);
        if (json) {
            try w.print("{s}\"{s}\":{d}", .{ if (index == 0) "" else ",", name, reg.value });
        } else {
            try w.print("{s}{s}=0x{x:0>8}", .{ if (index == 0) "" else " ", name, reg.value });
        }
    }
    try w.writeAll(if (json) "}}\n" else "\n");
}

pub fn memory(w: anytype, json: bool, address: u32, bytes: []const u8) !void {
    if (json) return w.print("{{\"address\":{d},\"length\":{d},\"hex\":\"{x}\"}}\n", .{ address, bytes.len, bytes });
    try w.print("0x{x:0>8}: {x}\n", .{ address, bytes });
}

/// `milli` is thousandths of the default rate; zero is `max`.
pub fn speed(w: anytype, json: bool, milli: u64) !void {
    if (milli == 0) return w.writeAll(if (json) "{\"speed\":\"max\"}\n" else "speed max\n");
    const factor = @as(f64, @floatFromInt(milli)) / 1000.0;
    if (json) return w.print("{{\"speed\":{d}}}\n", .{factor});
    try w.print("speed {d}x\n", .{factor});
}

/// A breakpoint or watchpoint the server accepted, with its id.
pub fn point(w: anytype, json: bool, kind: []const u8, id: u32, address: u32, access: ?proto.Access) !void {
    if (json) {
        try w.print("{{\"{s}\":{d},\"address\":{d}", .{ kind, id, address });
        if (access) |how| try w.print(",\"access\":\"{s}\"", .{@tagName(how)});
        return w.writeAll("}\n");
    }
    try w.print("{s} {d} at 0x{x:0>8}", .{ kind, id, address });
    if (access) |how| try w.print(" on {s}", .{@tagName(how)});
    try w.writeAll("\n");
}

pub fn cleared(w: anytype, json: bool, id: u32) !void {
    if (json) return w.print("{{\"cleared\":{d}}}\n", .{id});
    try w.print("cleared {d}\n", .{id});
}

/// A plug, unplug or fault the server accepted, keyed by what changed.
pub fn part(w: anytype, json: bool, method: proto.Method, spec: []const u8) !void {
    const key = switch (method) {
        .plug => "plugged",
        .unplug => "unplugged",
        .set_fault => "fault_set",
        .clear_fault => "fault_cleared",
        else => unreachable,
    };
    if (json) return w.print("{{\"{s}\":{f}}}\n", .{ key, std.json.fmt(spec, .{}) });
    try w.print("{s} {s}\n", .{ key, spec });
}

pub fn files(w: anytype, json: bool, method: proto.Method, path: []const u8) !void {
    const key = if (method == .snapshot) "snapshot" else "restored";
    if (json) return w.print("{{\"{s}\":{f}}}\n", .{ key, std.json.fmt(path, .{}) });
    try w.print("{s} {s}\n", .{ key, path });
}

/// The memory map: the server's JSON object under "map", or its text as is.
pub fn map(w: anytype, json: bool, text: []const u8) !void {
    if (json) return w.print("{{\"map\":{s}}}\n", .{text});
    try w.writeAll(text);
}

/// The peripheral blocks, or one block's registers (RA8EMU-818).
pub fn periph(w: anytype, json: bool, text: []const u8) !void {
    if (json) return w.print("{{\"periph\":{s}}}\n", .{text});
    try w.writeAll(text);
}

/// Sampled stacks, one `frames;... count` row each (RA8EMU-833).
pub fn folded(w: anytype, json: bool, text: []const u8) !void {
    if (json) return w.print("{{\"folded\":{f}}}\n", .{std.json.fmt(text, .{})});
    try w.writeAll(text);
}

/// The stack pointers, their low marks and the reservation (RA8EMU-816).
pub fn stack(w: anytype, json: bool, r: proto.StackReport) !void {
    if (json) {
        try w.print("{{\"msp\":{d},\"psp\":{d},\"low_msp\":{d},\"low_psp\":{d},\"stack\":", .{ r.msp, r.psp, r.low_msp, r.low_psp });
        if (r.has_stack == 0) return w.writeAll("null}\n");
        return w.print("{{\"base\":{d},\"size\":{d},\"overflow\":{d}}}}}\n", .{ r.base, r.size, r.overflow });
    }
    try w.print("msp 0x{x:0>8} lowest 0x{x:0>8}\npsp 0x{x:0>8} lowest 0x{x:0>8}\n", .{ r.msp, r.low_msp, r.psp, r.low_psp });
    if (r.has_stack == 0) return w.writeAll("stack: the image names no reservation\n");
    try w.print("stack 0x{x:0>8}..0x{x:0>8} ", .{ r.base, r.base +% r.size });
    if (r.overflow == 0) return w.writeAll("within bounds\n");
    try w.print("overflowed by {d} bytes\n", .{r.overflow});
}

/// The RTC calendar as yyyy-mm-dd hh:mm:ss (RA8EMU-809).
pub fn rtc(w: anytype, json: bool, r: proto.RtcReport) !void {
    const state = if (r.running != 0) "running" else "stopped";
    if (r.valid == 0) {
        if (json) return w.print("{{\"running\":{},\"date\":null}}\n", .{r.running != 0});
        return w.print("rtc {s}: the counters hold no date\n", .{state});
    }
    const fmt = "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}";
    const args = .{ r.year, r.month, r.day, r.hour, r.minute, r.second };
    if (json) {
        try w.print("{{\"running\":{},\"date\":\"", .{r.running != 0});
        try w.print(fmt, args);
        return w.writeAll("\"}\n");
    }
    try w.print(fmt, args);
    try w.print(" ({s})\n", .{state});
}

/// Report `err` (with the server's refusal `code` when it refused) and
/// return ctl's failure exit code.
pub fn failed(io: std.Io, json: bool, err: anyerror, code: u16) u8 {
    const why = explain(err);
    if (json) {
        var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
        const w = &stdout.interface;
        w.print("{{\"error\":\"{s}\",\"code\":{d}", .{ @errorName(err), code }) catch {};
        if (why.len != 0) w.print(",\"message\":{f}", .{std.json.fmt(why, .{})}) catch {};
        w.writeAll("}\n") catch {};
    } else if (why.len != 0) {
        std.debug.print("ctl: {s} (code {d}): {s}\n", .{ @errorName(err), code, why });
    } else {
        std.debug.print("ctl: {s} (code {d})\n", .{ @errorName(err), code });
    }
    return 1;
}

/// A sentence for the failures a user can act on, else empty.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.VersionMismatch => "the server speaks another session protocol version; run the same ra8_emulator build on both ends",
        error.UnknownHost => "no profile of that name in the hosts file",
        error.BadHostsLine => "the hosts file has a malformed profile line",
        error.NoHostsFile => "no hosts file at --hosts FILE, $RA8_HOSTS or ~/.config/ra8_emulator/hosts",
        error.HostUnreachable => "ssh could not reach the host",
        error.CopyFailed => "copying the image to the host failed",
        error.ImageUnreadable => "cannot read the image",
        else => "",
    };
}

pub fn uart(w: anytype, json: bool, sent: proto.Uart) !void {
    if (!json) return w.writeAll(sent.bytes);
    try w.print("{{\"uart\":{{\"core\":\"{s}\",\"channel\":{d},\"virtual_ns\":{d},\"text\":{f}}}}}\n", .{ @tagName(sent.core), sent.channel, sent.virtual_ns, std.json.fmt(sent.bytes, .{}) });
}

/// One session event (RA8EMU-1139): its kind, core and address.
pub fn session(w: anytype, json: bool, event: proto.SessionEvent) !void {
    const core = @tagName(event.core);
    const kind = @tagName(event.kind);
    if (json) return w.print("{{\"session\":{{\"core\":\"{s}\",\"kind\":\"{s}\",\"address\":{d}}}}}\n", .{ core, kind, event.address });
    try w.print("{s} {s} 0x{x:0>8}\n", .{ core, kind, event.address });
}

pub fn timeout(w: anytype, json: bool, until: []const u8) !void {
    if (json) return w.print("{{\"timeout\":{{\"until\":{f}}}}}\n", .{std.json.fmt(until, .{})});
    try w.print("\ntimed out waiting for {s}\n", .{until});
}
